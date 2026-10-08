#!/usr/bin/env bash
# fm-wave.sh - each project's next wave, and which tickets may start now.
#
# Usage:
#   fm-wave.sh next [--project <name>] [--snapshot <file|->]
#   fm-wave.sh plan [--project <name>] [--snapshot <file|->]
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

MODE=next
PROJECT_FILTER=''
SNAPSHOT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    next | plan) MODE=$1 ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECT_FILTER=$2
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