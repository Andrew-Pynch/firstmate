#!/usr/bin/env bash
# fm-pr-board.sh - one read-only line per pull request with its live state and
# a bounded wait for GitHub's mergeability computation.
#
# Usage: fm-pr-board.sh [--wait SECONDS] [<task-id> | <pr-url>]...
#
# With no operands it boards every state/*.meta in this home that records a
# pr= URL. A task-id operand reads that task's recorded pr=; a URL operand is
# boarded as given. Each GitHub pull request prints one line:
#
#   <task|-> <url> state=<OPEN|MERGED|CLOSED> draft=<yes|no>
#     mergeable=<MERGEABLE|CONFLICTING|UNKNOWN> merge_state=<status>
#     checks=<n> failing=<n> pending=<n> head=<sha12> [merged_at=<time>]
#
# GitHub reports mergeable=UNKNOWN while it recomputes after a push or a base
# move. Only open pull requests reading UNKNOWN are re-read, every
# FM_PR_BOARD_POLL seconds (default 3), until --wait SECONDS (default 30,
# capped at 120) has elapsed; one still UNKNOWN then prints
# "mergeable=UNKNOWN(after <n>s)". A merged pull request is reported as merged
# with its merge time, whatever its last mergeability read said.
#
# The check columns are a display of the forge's own conclusions, not a merge
# verdict: bin/fm-pr-merge.sh alone decides whether a pull request is green and
# mergeable, at merge time, and bin/fm-pr-state.sh names one pull request's
# individual blockers. This script never records, arms, merges, or edits
# anything, and a GitLab or Gerrit URL prints "unsupported" rather than a guess.
# An unreadable pull request prints "unreadable" and the exit status is 1 when
# any line was unreadable or unsupported, else 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-pr-board.sh [--wait SECONDS] [<task-id> | <pr-url>]..." >&2
  exit 2
}

WAIT=30
POLL=${FM_PR_BOARD_POLL:-3}
case "$POLL" in ''|*[!0-9]*|0) POLL=3 ;; esac
READ_TIMEOUT=${FM_PR_BOARD_READ_TIMEOUT:-20}
case "$READ_TIMEOUT" in ''|*[!0-9]*|0) READ_TIMEOUT=20 ;; esac

OPERANDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --wait)
      [ "$#" -ge 2 ] || usage
      case "$2" in ''|*[!0-9]*) usage ;; esac
      WAIT=$2
      [ "$WAIT" -le 120 ] || WAIT=120
      shift 2
      ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) OPERANDS+=("$1"); shift ;;
  esac
done

meta_pr() {  # <meta-file>
  grep '^pr=' "$1" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# Resolve operands into parallel arrays of task labels and URLs.
TASKS=()
URLS=()
if [ "${#OPERANDS[@]}" -eq 0 ]; then
  [ -d "$STATE" ] || { echo "error: state directory is unavailable: $STATE" >&2; exit 1; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    url=$(meta_pr "$meta")
    [ -n "$url" ] || continue
    TASKS+=("$(basename "$meta" .meta)")
    URLS+=("$url")
  done
  if [ "${#URLS[@]}" -eq 0 ]; then
    echo "no recorded pull requests in $STATE"
    exit 0
  fi
else
  for op in "${OPERANDS[@]}"; do
    case "$op" in
      https://*) TASKS+=(-); URLS+=("$op") ;;
      *)
        fm_pr_task_id_valid "$op" || { echo "error: invalid task id: $op" >&2; exit 2; }
        url=$(meta_pr "$STATE/$op.meta")
        [ -n "$url" ] || { echo "error: task $op records no pr= in $STATE/$op.meta" >&2; exit 1; }
        TASKS+=("$op")
        URLS+=("$url")
        ;;
    esac
  done
fi

# read_pr <url>: one live read; sets the R_* fields, returns 1 when unreadable.
read_pr() {
  local json
  R_STATE='' R_DRAFT='' R_MERGEABLE='' R_MERGE_STATE='' R_HEAD='' R_MERGED_AT='' R_CHECKS='' R_FAILING='' R_PENDING=''
  json=$(fm_run_timed "$READ_TIMEOUT" gh pr view "$1" \
    --json state,isDraft,mergeable,mergeStateStatus,headRefOid,mergedAt,statusCheckRollup 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  # One tab-separated record; the check buckets read each entry's own
  # conclusion (check runs) or state (commit statuses).
  IFS=$'\t' read -r R_STATE R_DRAFT R_MERGEABLE R_MERGE_STATE R_HEAD R_MERGED_AT R_CHECKS R_FAILING R_PENDING < <(
    printf '%s' "$json" | jq -r '
      def verdict: ((.conclusion // .state // "") | ascii_upcase);
      [ (.state // ""), (if .isDraft then "yes" else "no" end), (.mergeable // ""),
        (.mergeStateStatus // ""), ((.headRefOid // "")[0:12]), (.mergedAt // "-"),
        ((.statusCheckRollup // []) | length | tostring),
        ([(.statusCheckRollup // [])[] | select(verdict | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"))] | length | tostring),
        ([(.statusCheckRollup // [])[] | select(verdict | IN("","PENDING","EXPECTED","QUEUED","IN_PROGRESS","WAITING","REQUESTED"))] | length | tostring)
      ] | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null
  ) || return 1
  [ -n "$R_STATE" ] && [ "$R_STATE" != - ] || return 1
  # Mergeability only means something for an open pull request; GitHub keeps
  # answering UNKNOWN for a merged one, which reads like a pending refusal.
  if [ "$R_STATE" != OPEN ]; then
    R_MERGEABLE=n/a
    R_MERGE_STATE=n/a
  fi
  return 0
}

rc=0
n=${#URLS[@]}
LINES=()
UNKNOWN_IDX=()
for ((i = 0; i < n; i++)); do
  url=${URLS[$i]}
  if ! fm_pr_url_parse "$url" || [ "$FM_PR_PROVIDER" != github ]; then
    LINES[i]="${TASKS[$i]} $url unsupported (GitHub pull request URLs only)"
    rc=1
    continue
  fi
  if ! read_pr "$url"; then
    LINES[i]="${TASKS[$i]} $url unreadable"
    rc=1
    continue
  fi
  if [ "$R_STATE" = OPEN ] && [ "$R_MERGEABLE" = UNKNOWN ]; then
    UNKNOWN_IDX+=("$i")
  fi
  LINES[i]=$(printf '%s %s state=%s draft=%s mergeable=%s merge_state=%s checks=%s failing=%s pending=%s head=%s' \
    "${TASKS[$i]}" "$url" "$R_STATE" "$R_DRAFT" "$R_MERGEABLE" "$R_MERGE_STATE" "$R_CHECKS" "$R_FAILING" "$R_PENDING" "$R_HEAD")
  [ "$R_STATE" != MERGED ] || LINES[i]="${LINES[$i]} merged_at=$R_MERGED_AT"
done

waited=0
while [ "${#UNKNOWN_IDX[@]}" -gt 0 ] && [ "$waited" -lt "$WAIT" ]; do
  step=$POLL
  [ $((waited + step)) -le "$WAIT" ] || step=$((WAIT - waited))
  sleep "$step"
  waited=$((waited + step))
  still=()
  for i in "${UNKNOWN_IDX[@]}"; do
    url=${URLS[$i]}
    if ! read_pr "$url"; then
      still+=("$i")
      continue
    fi
    LINES[i]=$(printf '%s %s state=%s draft=%s mergeable=%s merge_state=%s checks=%s failing=%s pending=%s head=%s' \
      "${TASKS[$i]}" "$url" "$R_STATE" "$R_DRAFT" "$R_MERGEABLE" "$R_MERGE_STATE" "$R_CHECKS" "$R_FAILING" "$R_PENDING" "$R_HEAD")
    [ "$R_STATE" != MERGED ] || LINES[i]="${LINES[$i]} merged_at=$R_MERGED_AT"
    if [ "$R_STATE" = OPEN ] && [ "$R_MERGEABLE" = UNKNOWN ]; then
      still+=("$i")
    fi
  done
  UNKNOWN_IDX=("${still[@]+"${still[@]}"}")
done
for i in "${UNKNOWN_IDX[@]+"${UNKNOWN_IDX[@]}"}"; do
  LINES[i]=${LINES[$i]/mergeable=UNKNOWN/mergeable=UNKNOWN(after ${waited}s)}
done

for ((i = 0; i < n; i++)); do
  printf '%s\n' "${LINES[$i]}"
done
exit "$rc"
