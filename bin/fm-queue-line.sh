#!/usr/bin/env bash
# fm-queue-line.sh - one bounded line: the top decision waiting on the captain.
#
# READ-ONLY. It acquires no lock, starts no worker, drains no wake, and writes
# nothing. Its one fleet read is bin/fm-queue.sh --json, the canonical queue model
# (schema fm-queue.v1), so this line and the queue program can never disagree
# about how many decisions are open: both read the same `decisions` list of the
# same model, and this command holds no second copy of the counting or ranking rule.
#
# What it counts: the model's open decisions, one per call. Several held rows that
# name the same call are one decision; an answered, expired, deferred, aged,
# tracking or agent-chore row is none. bin/fm-queue.sh's header owns those rules. Fleet
# maintenance is never counted.
#
# Which one it names: the model's rank 1, its most consequential decision
# (bin/fm-queue.sh owns the order: credentials, then merges, then money, then
# product, then trivia).
#
# The line is one line because it is pinned above an editor. The item text is
# what gets cut to fit FM_QUEUE_LINE_WIDTH; the count is never cut.
#
# Output contract - a caller must not confuse the middle case with the last:
#   one line of text   something is waiting on the captain
#   no output, exit 0  nothing is waiting
#   exit 1             the queue model could not be read; stderr says why
#
# Flags:
#   (default)  print the line, or nothing
#   -h,--help  usage
#
# Environment:
#   FM_HOME                operational home to read, exactly as bin/fm-queue.sh reads it.
#   FM_QUEUE_LINE_WIDTH    line bound in characters (default 100, minimum 40).
#   FM_QUEUE_LINE_TIMEOUT  hard bound in seconds on the queue read (default 300).
#   FM_QUEUE_LINE_TODAY    today as YYYY-MM-DD (default: this host's date). A caller
#                          with a fixed clock, such as a test, sets it.
#   FM_QUEUE_SNAPSHOT      bin/fm-queue.sh's own fixture seam, passed through.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="$SCRIPT_DIR/fm-queue.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-queue-line.sh

Print one bounded line naming the top-ranked decision waiting on the captain
and how many decisions are open, or print nothing when none is. Read-only: the
line is rendered from bin/fm-queue.sh's own model, so the two cannot disagree.

options:
  -h, --help  print this help

environment:
  FM_HOME                home to read (as bin/fm-queue.sh reads it)
  FM_QUEUE_LINE_WIDTH    line bound in characters (default 100, minimum 40)
  FM_QUEUE_LINE_TIMEOUT  hard bound in seconds on the queue read (default 300)
  FM_QUEUE_LINE_TODAY    today as YYYY-MM-DD (default: this host's date)
  FM_QUEUE_SNAPSHOT      bin/fm-queue.sh fixture seam, passed through
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
"") ;;
*)
  echo "fm-queue-line: unexpected argument '$1'" >&2
  usage >&2
  exit 2
  ;;
esac

WIDTH=${FM_QUEUE_LINE_WIDTH:-100}
case "$WIDTH" in '' | *[!0-9]*) WIDTH=100 ;; esac
[ "$WIDTH" -ge 40 ] || WIDTH=100

TIMEOUT=${FM_QUEUE_LINE_TIMEOUT:-300}
case "$TIMEOUT" in '' | *[!0-9]* | 0) TIMEOUT=300 ;; esac

TODAY=${FM_QUEUE_LINE_TODAY:-}
if [ -z "$TODAY" ]; then
  TODAY=$(date +%F) || {
    echo "fm-queue-line: cannot read this host's date" >&2
    exit 1
  }
fi

MODEL=$(FM_QUEUE_TODAY="$TODAY" fm_run_timed "$TIMEOUT" "$QUEUE" --json) || {
  echo "fm-queue-line: the queue model could not be read (bin/fm-queue.sh --json failed)" >&2
  exit 1
}

LINE=$(printf '%s' "$MODEL" | jq -r --argjson width "$WIDTH" '
def cut($s; $n):
  if ($s | length) <= $n then $s else ($s | explode | .[0:($n - 1)] | implode) + "…" end;
.schema as $schema
| if $schema != "fm-queue.v1" then
    error("fm-queue-line: expected the fm-queue.v1 model, got \($schema // "none")")
  else . end
| if (.decisions | type) != "array" then
    error("fm-queue-line: the queue model carries no decisions list")
  else . end
| (.decisions | length) as $count
| if $count == 0 then empty
  else
    .decisions[0] as $top
    | ("⧗ \($count) decision\(if $count == 1 then "" else "s" end), top: ") as $head
    | ("[\($top.tier // "?")] \($top.id // "?") - \((($top.text // "") | split("\n") | .[0]) // "")") as $item
    | ($width - ($head | length)) as $budget
    | $head + (if $budget > 0 then cut($item; $budget) else "" end)
  end
') || {
  echo "fm-queue-line: the queue model could not be rendered" >&2
  exit 1
}

[ -n "$LINE" ] || exit 0
printf '%s\n' "$LINE"
