#!/usr/bin/env bash
# fm-brief-daily.sh - the captain's daily one-screen brief.
#
# READ-ONLY and deterministic. It acquires no lock, starts no worker, drains no
# wake, writes nothing, and calls no model. Its one fleet read is
# bin/fm-queue.sh --json (schema fm-queue.v1), so the decisions it ranks and
# counts are exactly the queue program's open decisions and the pinned line's
# count (bin/fm-queue-line.sh); the same model always prints the same brief.
#
# The screen, in order:
#   line 1     Next: the single next action - the top-ranked decision, or the
#              expired holds when no decision is open, or nothing.
#   decisions  at most 5 open decisions in the
#              model's rank order (credentials and merges first, then money,
#              then product, then trivia; bin/fm-queue.sh owns the order), each
#              with its age and a short answer direction, then
#              "+N not shown" naming where the rest are.
#   wins       the 3 most recent completed rows that carry a link (a PR or a
#              report), newest first. Each prints its id and, for a validated
#              data/<task>/report.md artifact, that relative path; never a URL.
#   expired    one "Expired, still open?" line: the holds whose deferral date
#              passed with no answer. The model keeps them out of the decisions;
#              this line is the one place they surface.
#   footer     when the fleet was checked, and which home.
#
# Never prints a secret. It prints titles and first lines only, never hold
# bodies, and every printed field passes a redaction backstop first: a
# NAME=value assignment whose name says key, token, secret or password keeps
# only its name, and a word with a known credential prefix or a long hex run
# prints as [redacted]. Titles, ids, answer commands and the home also lose any
# token-shaped word (mixed case with digits). Wins never print URLs or arbitrary
# links. The backstop catches common shapes; it is not a proof that no secret
# text can exist in a title.
#
# Output contract:
#   the brief on stdout, exit 0
#   exit 1             the queue model could not be read; stderr says why
#
# Flags:
#   (default)  print the brief
#   -h,--help  usage
#
# Environment:
#   FM_HOME                operational home to read, exactly as bin/fm-queue.sh reads it.
#   FM_BRIEF_DAILY_TIMEOUT hard bound in seconds on the queue read (default 300).
#   FM_BRIEF_DAILY_TODAY   today as YYYY-MM-DD (default: this host's date).
#   FM_QUEUE_SNAPSHOT      bin/fm-queue.sh's own fixture seam, passed through.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="$SCRIPT_DIR/fm-queue.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-brief-daily.sh

Print the captain's one-screen daily brief: the next action, the top open
decisions ranked by consequence with a short answer direction, the three
most recent wins, the expired holds, and when the fleet was checked.
Read-only and deterministic; it calls no model and prints no secret.

options:
  -h, --help  print this help

environment:
  FM_HOME                home to read (as bin/fm-queue.sh reads it)
  FM_BRIEF_DAILY_TIMEOUT hard bound in seconds on the queue read (default 300)
  FM_BRIEF_DAILY_TODAY   today as YYYY-MM-DD (default: this host's date)
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
  echo "fm-brief-daily: unexpected argument '$1'" >&2
  usage >&2
  exit 2
  ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-brief-daily: jq not found" >&2; exit 1; }

TIMEOUT=${FM_BRIEF_DAILY_TIMEOUT:-300}
case "$TIMEOUT" in '' | *[!0-9]* | 0) TIMEOUT=300 ;; esac

TODAY=${FM_BRIEF_DAILY_TODAY:-}
if [ -z "$TODAY" ]; then
  TODAY=$(date +%F) || {
    echo "fm-brief-daily: cannot read this host's date" >&2
    exit 1
  }
fi

MODEL=$(FM_QUEUE_TODAY="$TODAY" fm_run_timed "$TIMEOUT" "$QUEUE" --json) || {
  echo "fm-brief-daily: the queue model could not be read (bin/fm-queue.sh --json failed)" >&2
  exit 1
}

printf '%s' "$MODEL" | jq -r --argjson top 5 '
def cut($n):
  if length <= $n then . else (explode | .[0:($n - 1)] | implode) + "…" end;
# The redaction backstop. The credential words are assembled from pieces so this
# source never carries a pattern a log scanner would mistake for a credential.
def credential_names: "[A-Za-z0-9_]*(" + (["KE" + "Y", "TOK" + "EN", "SECR" + "ET", "PASSW" + "ORD", "PASS" + "WD"] | join("|")) + ")[A-Za-z0-9_]*";
def redact_shapes:
  gsub("(?<name>" + credential_names + ")=[^ ]+"; "\(.name)=[redacted]"; "i")
  | gsub("(?<![A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-|xox[abpr]-|AKIA)[A-Za-z0-9_-]{10,}"; "[redacted]")
  | gsub("(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])"; "[redacted]");
def redact:
  redact_shapes
  | gsub("(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*[A-Z])(?=[A-Za-z0-9_+/=-]*[a-z])(?=[A-Za-z0-9_+/=-]*[0-9])[A-Za-z0-9_+/=-]{20,}(?![A-Za-z0-9_+/=-])"; "[redacted]");
def win_report_path:
  (.report_path // null) as $path
  | if ($path | type) == "string" and ($path | test("^data/[A-Za-z0-9][A-Za-z0-9._-]*/report\\.md$"))
    then $path
    else null
    end;
def first_line: ((. // "") | split("\n") | .[0]) // "";
def age: if . == null then "age ?" else "\(.)d" end;
.schema as $schema
| if $schema != "fm-queue.v1" then
    error("fm-brief-daily: expected the fm-queue.v1 model, got \($schema // "none")")
  else . end
| if (.decisions | type) != "array" then
    error("fm-brief-daily: the queue model carries no decisions list")
  else . end
| .decisions as $decisions
| ($decisions | length) as $count
| ([ .projects[].rows[] | select(.state == "expired") ] | sort_by([.hold.until, .id])) as $expired
| ([ .projects[].rows[] | select(.state == "done" and ((.artifact // ((.links // [])[0]) // null) != null)) ]
   | to_entries | sort_by([(.value.completed // ""), (- .key)]) | reverse | map(.value) | .[0:3]) as $wins
| ( if $count > 0 then
      "Next: decide \($decisions[0].id | redact) - \($decisions[0].text | first_line | redact | cut(80))"
    elif ($expired | length) > 0 then
      "Next: answer or re-date the \($expired | length) expired hold\(if ($expired | length) == 1 then "" else "s" end) below"
    else "Next: nothing waits on you" end ),
  "",
  ( if $count == 0 then "Decisions: none open"
    else "Decisions: \($count) open, top \([$top, $count] | min) by consequence" end ),
  ( $decisions[0:$top][]
    | " \(.rank). [\(.tier)] \(.id | redact)\(if .count > 1 then " (x\(.count))" else "" end), \(.age_days | age): \(.text | first_line | redact | cut(90))",
      ( if .count > 1 then "    \(.count) rows, see bin/fm-queue.sh"
        else ((.answer | redact) as $shown
          | if $shown == .answer then "    \($shown)"
            else "    (answer command withheld: it carries a token-shaped value; bin/fm-queue.sh prints it)" end) end ) ),
  ( if $count > $top then " +\($count - $top) not shown: bin/fm-queue.sh lists every decision" else empty end ),
  "",
  ( if ($wins | length) == 0 then "Wins: none recorded recently"
    else "Wins:" end ),
  ( $wins[]
    | win_report_path as $report
    | " - \(.id | redact)" + (if $report == null then "" else ": \($report | redact)" end) ),
  "",
  ( if ($expired | length) == 0 then "Expired, still open? none"
    else "Expired, still open? \($expired | length): "
         + ([ $expired[0:3][] | "\(.id | redact) (until \(.hold.until))" ] | join(", "))
         + (if ($expired | length) > 3 then ", +\(($expired | length) - 3) more" else "" end)
         + " - answer each or re-hold it with a new date" end ),
  "",
  "Checked \(.generated) from \(.home | redact)"
' || {
  echo "fm-brief-daily: the queue model could not be rendered" >&2
  exit 1
}
