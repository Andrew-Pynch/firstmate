#!/usr/bin/env bash
# fm-queue-line.sh - one bounded line: what is waiting on the captain right now.
#
# READ-ONLY. It acquires no lock, starts no worker, drains no wake, and writes
# nothing. Its one fleet read is bin/fm-queue.sh --json, the canonical queue model
# (schema fm-queue.v1), so this line and the queue program can never disagree
# about how many things are waiting: both count the same rows of the same model,
# and this command holds no second copy of the counting rule.
#
# What it counts: the rows that model reads `waiting on you`, which is
# bin/fm-queue.sh's own state for a live, undated, question-bearing captain hold.
# A hold the captain deferred to a later date reads `deferred` and a hold with no
# question behind it reads `tracking`; neither is counted here, and both stay
# visible under those labels in bin/fm-queue.sh. Fleet maintenance is never
# counted, because the model already groups those rows as not the captain's
# request.
#
# Which one it names first, and why that order is the urgency order:
#   1. a hold the captain deferred to a date that has arrived or passed
#      (`hold.until <= today`), because he asked to be reminded then;
#   2. otherwise the hold that has been waiting longest (`hold.age_days`, largest
#      first, and a row with no recorded age last);
#   3. ties by row id, so the printed order is deterministic.
#
# The line is one line because it is pinned above an editor. The item text is
# what gets cut to fit FM_QUEUE_LINE_WIDTH; the two counts are never cut.
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

Print one bounded line naming the most urgent thing waiting on the captain and
how many more are waiting, or print nothing when nothing waits. Read-only: the
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

LINE=$(printf '%s' "$MODEL" | jq -r --argjson width "$WIDTH" --arg today "$TODAY" '
def cut($s; $n):
  if ($s | length) <= $n then $s else ($s | explode | .[0:($n - 1)] | implode) + "…" end;
def first_line: ((.text // "") | split("\n") | .[0]) // "";
# A deferred hold is due once the date the captain named has arrived, so the
# comparison is inclusive and the rows are all ISO dates.
def due_rank: if ((.hold.until // "") != "" and (.hold.until <= $today)) then 0 else 1 end;
def age_rank: if (.hold.age_days // null) == null then 1 else 0 end;
def age_key: ((.hold.age_days // 0) * -1);
.schema as $schema
| if $schema != "fm-queue.v1" then
    error("fm-queue-line: expected the fm-queue.v1 model, got \($schema // "none")")
  else . end
| [ .projects[]? | .rows[]? | select(.state == "waiting on you") ] as $waiting
| ($waiting | length) as $waiting_count
| if $waiting_count == 0 then empty
  else
    ($waiting | sort_by([due_rank, age_rank, age_key, .id]) | .[0]) as $top
    | ($waiting_count - 1) as $rest
    | ("⧗ waiting on you (\($waiting_count)): ") as $head
    | (if $rest > 0 then " (+\($rest) more)" else "" end) as $tail
    | ($head | length) as $head_len
    | ($tail | length) as $tail_len
    | (($top.id // "?") + " - " + ($top | first_line)) as $item
    | ($width - $head_len - $tail_len) as $budget
    | $head + (if $budget > 0 then cut($item; $budget) else "" end) + $tail
  end
') || {
  echo "fm-queue-line: the queue model could not be rendered" >&2
  exit 1
}

[ -n "$LINE" ] || exit 0
printf '%s\n' "$LINE"
