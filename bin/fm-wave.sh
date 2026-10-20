#!/usr/bin/env bash
# fm-wave.sh - each project's next wave, and which tickets may start now.
#
# Usage:
#   fm-wave.sh next [--project <name>] [--snapshot <file|->]
#   fm-wave.sh plan [--project <name>] [--snapshot <file|->]
#   fm-wave.sh summary --packet <json> [--snapshot <file|->]
#   fm-wave.sh --help
#
# The dispatch rule itself is owned once by bin/fm-wave-lib.sh; this command is
# how the agent applies it, and that library's header carries the rule, the row
# contract, and the gate tokens. In one line: a ticket starts as soon as its own
# declared blockers have landed, every project's graph is computed on its own,
# and an item waiting on the captain holds only the tickets that declare it.
#
# Rows come from bin/fm-fleet-snapshot.sh --json, which is the single owner of
# the backlog row contract, so this command never parses a backlog itself. Each
# row's project is the one the snapshot already resolved through
# bin/fm-project-lib.sh; a row whose project does not resolve is grouped under
# its recorded repo and reported with the resolver's own reason, never silently
# relabelled.
#
# The declared blocker edges are the backlog owner's own graph, so both ends of
# every edge read the way tasks-axi derives them: a blocker that exists and has
# not landed blocks, a blocker whose row is gone counts as resolved, and a
# public-followup obligation is never dispatchable work.
#
# `next` prints one line per project that has a ticket ready to start:
#
#   project=<name> wave=<n> start=<id>[,<id>...] [unresolved=<reason>]
#
# wave is the lowest layer among the ids printed, and each project is computed
# independently of every other, so two projects appear on the same run. With
# nothing to start it prints `none: no project has a dispatchable wave` and exits
# 3, so a caller branches on the status rather than on prose.
#
# `plan` prints the graph the same computation used: every queued and in-flight
# row, plus every landed row that some row declares,
#
#   project=<name> [unresolved=<reason>]
#     wave <n> <id> <state> <gate>
#
# Test seam: `--snapshot <file>` reads an existing snapshot, and `-` reads one
# from stdin. A caller that already holds a snapshot (bin/fm-fleet-view.sh
# --json) passes it instead of paying for a second observation of the same home.
#
#
# At landing, the supervisor supplies one packet for the wave rather than a
# notification per ticket. Packet fields: id (stable wave label), project,
# items (distinct landed task ids in one project layer), proves, not_done,
# unblocks, ask (one plain line), and optional needs_review (default true).
# Evidence prose comes from the supervisor, never inferred from task titles.
# `summary` validates landing against the snapshot, writes one immutable
# data/fm-wave-<project>-<id>/report.md artifact, and parks its ask as one
# captain-held queue row. needs_review=false records a completed packet instead.
# Only explicitly declared packet dependents wait; no dependency is added.
# The one printed line is the wave's chat outcome; successful retries are silent.
# A repeated id with changed content refuses rather than replacing its evidence.
# Exit status:
#   0  the report was printed
#   1  an operational failure that names itself
#   2  a usage error, or jq is missing
#   3  `next` only: this home has no dispatchable wave right now
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wave-lib.sh
. "$SCRIPT_DIR/fm-wave-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-wave: %s\n' "$*" >&2
  exit 1
}

# The backlog rows this home records, as the library's row contract reads them.
# `all` keeps every structured record, which the dependency gate needs because a
# landed blocker still decides a dependent; `current` keeps the rows worth
# showing a human, which is everything that has not landed plus every landed row
# some row still declares.
wave_rows() { # <snapshot-file> <all|current>
  jq -r --arg scope "$2" '
    ([ .backlog.records[]? | .blocked_by_ids[]? ] | unique) as $referenced
    | .backlog.records[]?
    | select(.structured == true)
    | . as $r
    | select(($scope == "all") or $r.state != "done" or ($referenced | index($r.id) != null))
    | [ ($r.id // ""),
        (if ($r.project_resolution.status // "") == "resolved"
          then $r.project_resolution.project
          else ($r.repo // "-") end),
        ($r.state // ""),
        (if $r.hold_kind == "captain" then "captain" else "none" end),
        ($r.kind // ""),
        (($r.blocked_by_ids // []) | join(",")),
        (if ($r.project_resolution.status // "") == "resolved" then ""
          else ($r.project_resolution.reason // "project could not be resolved") end)
      ]
    | @tsv
  ' "$1"
}

publish_summary() {
  local packet=$1 snapshot=$2 id project row artifact relative staged plan announced review result canonical
  jq -e '
    (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.project | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.items | type == "array" and length > 0 and length == (unique | length)
      and all(.[]; type == "string")) and
    ([.proves,.not_done,.unblocks,.ask] | all(.[]; type == "string" and length > 0)) and
    (.ask | test("[\r\n]") | not) and
    (if has("needs_review") then (.needs_review | type == "boolean") else true end)
  ' "$packet" >/dev/null || fail "invalid summary packet"
  id=$(jq -r .id "$packet")
  project=$(jq -r .project "$packet")
  row="fm-wave-$project-$id"
  relative="data/$row/report.md"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$FM_HOME/data/$row" "$STATE" || fail "cannot create summary directory"
  fm_lock_acquire_wait "$STATE/.$row.lock" || fail "cannot lock summary"
  artifact="$FM_HOME/$relative"
  announced="$STATE/.$row.announced"
  canonical=$(jq -Sc . "$packet")
  if [ -f "$announced" ] && [ -f "$artifact" ]; then
    [ "$(cat "$announced")" = "$canonical" ] || fail "wave id already has different evidence"
    fm_lock_release "$STATE/.$row.lock"
    return 0
  fi
  staged=$(mktemp "$STATE/.$row.content.XXXXXX") || fail "cannot stage summary"
  plan=$(wave_rows "$snapshot" all | fm_wave_plan)
  if ! printf '%s\n' "$plan" | jq -Rse --slurpfile packet "$packet" '
    $packet[0] as $p |
    [split("\n")[] | split("\t") | select(length >= 5)
      | select(.[2] as $id | $p.items | index($id) != null)] as $rows |
    ($rows | length) == ($p.items | length) and
    all($rows[]; .[0] == $p.project and .[3] == "done" and .[4] == "landed") and
    ([$rows[][1]] | unique | length) == 1
  ' >/dev/null; then
    rm -f "$staged"
    fail "summary items must have landed in one project wave"
  fi
  if ! jq -er --slurpfile packet "$packet" '
    $packet[0] as $p |
    [.backlog.records[] | select(.id as $id | $p.items | index($id) != null)
      | {id, title, link:(.pr_url // .report_path // .local_note)}] as $items |
    if any($items[]; .link == null or .link == "") then
      error("every landed item needs a recorded link")
    else
      "# Wave \($p.project)/\($p.id)\n\n## Landed\n" +
      ($items | sort_by(.id) | map("- [\(.id)](\(.link)): \(.title)") | join("\n")) +
      "\n\n## Proves\n\($p.proves)\n\n## Deliberately not done\n\($p.not_done)" +
      "\n\n## Unblocks\n\($p.unblocks)\n\n## Ask\n\($p.ask)\n"
    end
  ' "$snapshot" > "$staged"; then
    rm -f "$staged"
    fail "could not render summary evidence"
  fi
  if [ -f "$artifact" ]; then
    cmp -s "$artifact" "$staged" || { rm -f "$staged"; fail "wave id already has different evidence"; }
    rm -f "$staged"
  else
    chmod 0600 "$staged"
    mv "$staged" "$artifact"
  fi
  if ! "$SCRIPT_DIR/fm-tasks-axi.sh" show "$row" >/dev/null 2>&1; then
    result=$("$SCRIPT_DIR/fm-tasks-axi.sh" add "$row" "Review wave $project/$id" \
      --repo "$project" --kind captain --report "$relative" --body-file "$artifact") \
      || fail "could not record wave packet: $result"
  fi
  review=$(jq -r 'if .needs_review == false then "false" else "true" end' "$packet")
  if [ "$review" = true ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$row" --reason "$(jq -r .ask "$packet")" >/dev/null \
      || fail "could not park wave ask"
  else
    "$SCRIPT_DIR/fm-tasks-axi.sh" 'done' "$row" --report "$relative" >/dev/null \
      || fail "could not close action-free wave packet"
  fi
  printf 'Wave %s/%s landed: %s. Next: %s\n' "$project" "$id" "$artifact" "$(jq -r .ask "$packet")"
  staged=$(mktemp "$STATE/.$row.receipt.XXXXXX") || fail "cannot stage summary receipt"
  printf '%s\n' "$canonical" > "$staged"
  _fm_atomic_replace "$staged" "$announced" || fail "cannot record summary receipt"
  fm_lock_release "$STATE/.$row.lock"
}

MODE=next
PROJECT_FILTER=''
SNAPSHOT=''
PACKET=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    next | plan | summary) MODE=$1 ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECT_FILTER=$2
      shift
      ;;
    --packet)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PACKET=$2
      shift
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SNAPSHOT=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'fm-wave: unknown argument %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || {
  printf 'fm-wave: jq not found (required to read the fleet snapshot)\n' >&2
  exit 2
}

tmp=''
snapshot_file=''
STAGED=0
if [ -n "$SNAPSHOT" ]; then
  if [ "$SNAPSHOT" = - ]; then
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-wave-snapshot.XXXXXX") || fail "cannot stage the snapshot"
    STAGED=1
    cat > "$tmp" || fail "cannot read the snapshot from stdin"
    snapshot_file=$tmp
  else
    [ -f "$SNAPSHOT" ] || fail "no snapshot at $SNAPSHOT"
    snapshot_file=$SNAPSHOT
  fi
else
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-wave-snapshot.XXXXXX") || fail "cannot stage the snapshot"
  STAGED=1
  if ! "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$tmp"; then
    fail "could not read this home's fleet snapshot"
  fi
  snapshot_file=$tmp
fi

cleanup() {
  if [ "$STAGED" -eq 1 ] && [ -n "$tmp" ]; then
    rm -f -- "$tmp"
  fi
  return 0
}
trap cleanup EXIT
if [ "$MODE" = summary ]; then
  [ -n "$PACKET" ] && [ -f "$PACKET" ] || fail "summary requires --packet <json>"
  publish_summary "$PACKET" "$snapshot_file"
  exit 0
fi

if [ "$MODE" = plan ]; then
  wave_rows "$snapshot_file" current | fm_wave_plan | awk -v want="$PROJECT_FILTER" '
    BEGIN { FS = "\t"; last = "" }
    {
      if (want != "" && $1 != want) next
      if ($1 != last) {
        printf "project=%s", $1
        if ($6 != "") printf " unresolved=%s", $6
        printf "\n"
        last = $1
      }
      printf "  wave %s %s %s %s\n", $2, $3, $4, $5
    }
    END {
      if (last == "") print "none: no backlog row to plan"
    }
  '
else
  wave_rows "$snapshot_file" all | fm_wave_plan | awk -v want="$PROJECT_FILTER" '
    BEGIN { FS = "\t"; n = 0 }
    {
      if (want != "" && $1 != want) next
      if ($5 != "ready") next
      key = $1
      if (!(key in seen)) {
        seen[key] = 1
        order[++n] = key
        wave[key] = $2 + 0
        start[key] = $3
      } else {
        if ($2 + 0 < wave[key]) wave[key] = $2 + 0
        start[key] = start[key] "," $3
      }
      if (reason[key] == "" && $6 != "") reason[key] = $6
    }
    END {
      if (n == 0) {
        print "none: no project has a dispatchable wave"
        exit 3
      }
      for (i = 1; i <= n; i++) {
        k = order[i]
        printf "project=%s wave=%d start=%s", k, wave[k], start[k]
        if (reason[k] != "") printf " unresolved=%s", reason[k]
        printf "\n"
      }
    }
  '
fi