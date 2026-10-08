#!/usr/bin/env bash
# fm-dead-records.sh - read-only inventory of this home's task records whose
# endpoint is gone, classified for the owning supervisor's guarded teardown.
#
# Usage: fm-dead-records.sh [--snapshot FILE] [--all]
#
# Input is bin/fm-fleet-snapshot.sh --json for the effective FM_HOME (or a saved
# copy via --snapshot), so record discovery, endpoint presence, backlog rows,
# holds, open decisions, and recorded PRs all come from that one owner; this
# script adds only two read-only facts: the recorded copy's uncommitted file
# count (git --no-optional-locks status) and each recorded PR's forge state
# (bin/fm-pr-board.sh --wait 0). It never tears down, edits a record, closes a
# row, or touches an endpoint. bin/fm-teardown.sh stays the only landed-work
# gate; a "candidate" is a record worth handing to it, never proof of landing.
#
# One line per record whose endpoint is gone (--all also prints live ones):
#   <verdict> <id> kind=<kind> backlog=<state> pr=<url|-> <detail>
# Verdicts, first match wins:
#   live            the endpoint still exists (printed only with --all)
#   remote          a remote secondmate or a secondmate record (not inventoried)
#   held            the backlog row carries a hold (captain, external, ...)
#   open-decision   the record has an open keyed decision or blocker
#   dirty           the recorded copy has uncommitted files
#   pr-open         the recorded PR is still open
#   pr-closed       the recorded PR was closed without merging
#   pr-unreadable   the recorded PR's state could not be read
#   candidate       not held, clean, and the PR merged or the backlog row is Done
#   done-unproven   no PR and only a done status event: endpoint absence plus a
#                   done event proves neither landing nor acceptance, so the
#                   owner checks the landing or report first (no teardown line)
#   undetermined    none of the above: no done or merged evidence
# Then one "teardown:" line per candidate with the exact guarded command (never
# --force), and a "summary:" line with counts per verdict.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

usage() {
  echo "usage: fm-dead-records.sh [--snapshot FILE] [--all]" >&2
  exit 2
}

SNAPSHOT=
ALL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) [ "$#" -ge 2 ] || usage; SNAPSHOT=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ -n "$SNAPSHOT" ]; then
  json=$(cat -- "$SNAPSHOT") || { echo "error: cannot read snapshot $SNAPSHOT" >&2; exit 1; }
else
  json=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
    echo "error: bin/fm-fleet-snapshot.sh --json failed; nothing was inventoried" >&2
    exit 1
  }
fi
printf '%s' "$json" | jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | type) == "array"' >/dev/null 2>&1 \
  || { echo "error: input is not an fm-fleet-snapshot.v1 document" >&2; exit 1; }

# One TSV row per task: the snapshot facts this inventory classifies on.
rows=$(printf '%s' "$json" | jq -r '
  .tasks[] | [
    .id,
    (.kind // "-"),
    (if .endpoint.exists == true then "yes" else "no" end),
    (if .remote != null or .kind == "secondmate" then "yes" else "no" end),
    (.backlog.state // "none"),
    (.backlog.hold_kind // "-"),
    (((.hints.open_decisions // []) | length) | tostring),
    (.paths.worktree.path // "-"),
    (if .paths.worktree.present == true then "yes" else "no" end),
    (.pr.url // .backlog.pr_url // "-"),
    (.paths.status_log.last_event.state // "-")
  ] | map(if . == "" then "-" else tostring end) | @tsv')

# Forge state for every recorded PR on a record whose endpoint is gone.
declare -A PR_STATE=()
pr_urls=$(printf '%s\n' "$rows" | awk -F '\t' '$3 == "no" && $4 == "no" && $10 ~ /^https:\/\// { print $10 }' | sort -u)
if [ -n "$pr_urls" ]; then
  mapfile -t pr_list <<<"$pr_urls"
  board=$("$SCRIPT_DIR/fm-pr-board.sh" --wait 0 "${pr_list[@]}" 2>/dev/null || true)
  while read -r _task url field _rest; do
    [ -n "${url:-}" ] || continue
    case "${field:-}" in
      state=*) PR_STATE[$url]=${field#state=} ;;
      *) PR_STATE[$url]=unreadable ;;
    esac
  done <<<"$board"
fi

declare -A COUNT=()
CANDIDATES=()
while IFS=$'\t' read -r id kind alive remote bstate hold decisions wt wt_present pr last; do
  [ -n "${id:-}" ] || continue
  detail=
  pstate=-
  [ "$pr" = - ] || [ "$alive" = yes ] || [ "$remote" = yes ] || pstate=${PR_STATE[$pr]:-unreadable}
  if [ "$alive" = yes ]; then
    verdict=live
  elif [ "$remote" = yes ]; then
    verdict=remote
  elif [ "$hold" != - ]; then
    # A hold is the owner's call even when its PR already merged; the PR state
    # is shown so a stale hold is visible, never so it is overridden.
    verdict=held; detail="hold=$hold pr_state=$pstate"
  elif [ "$decisions" != 0 ]; then
    verdict=open-decision; detail="open=$decisions pr_state=$pstate"
  else
    dirty=0
    if [ "$wt" != - ] && [ "$wt_present" = yes ]; then
      dirty=$(git --no-optional-locks -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$dirty" != 0 ]; then
      verdict=dirty; detail="uncommitted=$dirty pr_state=$pstate copy=$wt"
    elif [ "$pstate" = OPEN ]; then
      verdict='pr-open'
    elif [ "$pstate" = CLOSED ]; then
      verdict='pr-closed'
    elif [ "$pstate" = unreadable ]; then
      verdict='pr-unreadable'
    elif [ "$pstate" = MERGED ]; then
      verdict=candidate; detail="pr merged"
    elif [ "$bstate" = 'done' ]; then
      verdict=candidate; detail="backlog done"
    elif [ "$pr" = - ] && [ "$last" = 'done' ]; then
      verdict='done-unproven'; detail="last event done, no PR"
    else
      verdict=undetermined; detail="last_event=$last"
    fi
  fi
  COUNT[$verdict]=$(( ${COUNT[$verdict]:-0} + 1 ))
  [ "$verdict" != candidate ] || CANDIDATES+=("$id")
  if [ "$verdict" != live ] || [ "$ALL" = 1 ]; then
    printf '%s %s kind=%s backlog=%s pr=%s%s\n' "$verdict" "$id" "$kind" "$bstate" "$pr" "${detail:+ $detail}"
  fi
done <<<"$rows"

for id in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
  printf 'teardown: bin/fm-teardown.sh %s\n' "$id"
done
summary=
for v in live remote held open-decision dirty pr-open pr-closed pr-unreadable candidate done-unproven undetermined; do
  [ -z "${COUNT[$v]:-}" ] || summary="$summary $v=${COUNT[$v]}"
done
printf 'summary:%s\n' "${summary:- no records}"
