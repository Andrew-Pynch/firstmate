#!/usr/bin/env bash
# fm-queue.sh - the queue: what the captain asked for, and what the fleet needs.
#
# The human view and --json are READ-ONLY. They acquire no lock, start no
# worker, drain no wake, write no record, and mutate nothing.
# bin/fm-fleet-snapshot.sh's own observational parent-side ledger cache refresh is
# the only fleet-state write in that call path, exactly as it is for every other
# snapshot consumer.
#
# `answer` is the ONE writing subcommand, and it hands the captain's answer off
# through exactly two existing owners, never a third:
#   - a row that reads `waiting on you` is a KEYED captain hold, so the answer is
#     recorded and the decision closed at answer time through
#     bin/fm-captain-hold.sh's `answer` path - the same resolution path every
#     other channel's keyed answer reaches through that owner's `answers` intake,
#     used here because the captain's words may run to more than one line and
#     `--decision-file` preserves them exactly where the line-oriented form would
#     not. The intake's reserved `reconcile` value is refused before either owner
#     is called, so this channel can never record it as a decision.
#   - the answer is then handed off through bin/fm-inbox.sh `note`, which writes
#     the durable record into the home's inbox and arms exactly ONE wake. That is
#     the whole transport: this command never discovers which session is live
#     (bin/fm-lock.sh already guarantees one owning session per home), never
#     takes the session lock itself, and never starts a worker. An answer given
#     while firstmate is stopped therefore waits durably for the next session to
#     drain it. Its first body line is a stable marker - `queue-answer row=<id>
#     project=<project> keyed=<0|1> close=<done|release>` - so the session that
#     drains the inbox can route the answer without reading prose.
#
# One read model. It shells out ONCE to bin/fm-fleet-snapshot.sh --json (the
# canonical fleet snapshot: task metadata, parsed backlog records with full body
# text, live secondmate ledgers, structured captain-hold classification) and
# renders it. It never parses state/<id>.status itself and never infers a row
# state from the last recorded status event: a status line is an append-only wake
# event, so the only current-state source here is the snapshot per-task
# current_state, which bin/fm-crew-state.sh owns. A row whose worker is gone
# reads `unknown` with that source named, never `done`.
#
# Rows are grouped by project. Each row carries its state, its wave (the
# dependency layer computed from the declared blocked_by edges inside that
# project), the tickets dispatched for it, the rows it unblocks, its
# authoritative source, freshness, owner, next action and full text. Fleet
# maintenance is a separate group labelled as not the captain request.
#
# States, and nothing else: `queued`, `in flight`, `blocked`, `done`,
# `waiting on you`, `answered, close pending`, `expired`, `deferred`, `aged`,
# `agent chore`, `tracking`, `unknown`.
#   done            the queue row is recorded Done, or the worker reads done.
#   waiting on you  a live captain hold (hold_kind=captain) the captain has not
#                   answered that is undated (or dated today) and carries a
#                   question, except one bucketed `blocked`, whose concrete wait
#                   is the unresolved blocker.
#   answered, close pending
#                   a live captain hold carrying the durable resolution block
#                   from an interrupted close. It is cleanup, not a decision.
#   expired         the same captain hold, deferred by the captain to a date that
#                   has passed without an answer. It is shown once, on the daily
#                   brief's one "expired, still open?" line, and otherwise stays
#                   out of the decisions: re-hold it with a new date or answer it.
#   deferred        the same captain hold, deferred by the captain to a date
#                   after today; it rejoins `waiting on you` on that date.
#   aged            an undated captain hold whose structured snapshot bucket is
#                   aged. It remains visible but outside the open decisions.
#   agent chore     the same captain hold whose own words say it is routine fleet
#                   housekeeping (cleanup after a merged PR, a stale state/data
#                   or task record, an empty fleet copy). It is firstmate's to
#                   do, never a captain call.
#                   bin/fm-classify-lib.sh's captain-call text classes own that
#                   vocabulary; a cleanup that refused over unlanded work is NOT
#                   a chore, because only the captain may approve discarding it.
#   tracking        the same captain hold with no question behind it: an empty
#                   hold reason, or a reason that marks the row as tracking or
#                   routing only (contains "tracking", or starts "routed to").
#   unknown         nothing establishes a state: an in-flight row with no worker
#                   record, a worker record with no proof either way, an
#                   unreadable home. Never `done`, because a missing worker is an
#                   absence of proof rather than a result.
#   blocked         an unresolved declared blocker, a failed worker, a worker
#                   that declared itself blocked, or a non-captain hold.
#   in flight       a live worker (working, parked at a pipeline gate, or paused).
#   queued          recorded and not yet dispatched.
#
# Decisions. The model also carries `decisions`: the open-decisions set, the one
# list every captain-facing count reads (bin/fm-queue-line.sh, bin/fm-brief-daily.sh).
# It is built from the rows reading `waiting on you` and nothing else, so an
# answered, expired, deferred, aged, tracking or chore row can never be counted in it.
#   - One decision per explicit call identity, not per row or matching prose.
#     A key is a row id qualified by the home that holds it (`main:<id>`,
#     `<mate>:<id>`), so two homes reusing one id never share a decision; a parent
#     mirror `captain-hold-<id>-<n>` takes the key of the secondmate call it mirrors
#     only when exactly one mate row published that parent key; otherwise the
#     mirror keeps its own main-home identity. Every cleanup that refused over
#     unlanded work and was held with `bin/fm-captain-hold.sh hold --discard`
#     (class `discard`, from that marker alone, never from the wording) groups
#     under ONE decision, key `discard-approval`, so the captain rules once on
#     all of those copies.
#     A decision carries its key, member rows and their count.
#   - An answered call leaves: before grouping, a waiting row drops out when a
#     row of the same key reads done and carries a recorded answer
#     (bin/fm-captain-hold.sh's resolution block), so a mirror left open after
#     the call was answered and its work finished is not asked again, and its
#     answer never hides another call that shares its words.
#   - Every decision carries the exact command that answers it, with FM_HOME set:
#     `answer <key> --group --members <list>` for a decision of several rows (the
#     list is the home-qualified members it showed), `answer <row-id>` for one row
#     this home holds, or bin/fm-send.sh (with the parent decision key when the
#     secondmate published one, and the row id in the text) for one secondmate call.
# `counts.hygiene` states how many rows each of those rules took out.
#
# No silent caps. Every list is printed whole: no row is dropped, no bucket is
# bounded, and no row text is clipped. Where a producer upstream cut text - a
# secondmate home ledger bounds its own fields per field, at 40, 70, 90, 120, 160
# or 500 characters - the row names the field and the bound that applied and says
# where the full text lives, instead of passing a cut sentence off as complete.
# `bounds:` states every such bound. This home own backlog text is never cut by
# the snapshot, so only a secondmate ledger row can carry a cut field.
#
# Project grouping has one owner: the snapshot project_resolution field, which
# bin/fm-project-lib.sh resolves against data/projects.md (firstmate patch 0014).
# This command consumes that field and never parses the registry itself. Where the
# snapshot carries no resolution - a build older than that patch - it groups by
# the raw repo label and says so, rather than growing a second registry parser.
#
# Flags:
#   (default)  the human view
#   --json     the same model as JSON (schema fm-queue.v1) for other surfaces
#   answer <row-id> [--group --members <list>] [--close done|release] [--text <answer>]
#              record the captain's answer for one row. A captain hold
#              (`waiting on you`, `expired`, `deferred`, `aged`, `agent chore`, `tracking`)
#              closes through bin/fm-captain-hold.sh first; the answer is then
#              handed off through the home's durable inbox (bin/fm-inbox.sh note)
#              and exactly one wake is armed. The answer text comes from --text,
#              or from stdin when --text is absent.
#              `--group` takes a decision key (or the id of a row this home holds
#              in that decision) and applies the one answer to every row of the
#              decision: each row this home holds closes through the captain-hold
#              owner, and the single hand-off names every row, including the
#              secondmate rows for firstmate to route to their homes.
#              `--members` is required with it: the comma-separated,
#              home-qualified member list (`main:<id>`, `<mate>:<id>`) the
#              decision showed. When the decision now holds any other set, the
#              answer is refused and nothing closes, so a row that joined later
#              never inherits the answer.
#              `--close release` lifts a held decision so its gated work resumes
#              instead of closing the task; it is refused on a row that is not a
#              captain hold.
#   -h,--help  usage
#
# Environment:
#   FM_HOME           operational home whose state/, data/ and backlog are read,
#                     and the home the answer is handed off in.
#   FM_QUEUE_TIMEOUT  hard bound in seconds on the snapshot read (default 300).
#   FM_QUEUE_TODAY    today as YYYY-MM-DD (default: this host's date); a hold
#                     dated after it reads `deferred`, one dated before it `expired`.
#   FM_QUEUE_SNAPSHOT when set to a readable path, read the snapshot JSON from
#                     that file instead of invoking the canonical snapshot, so a
#                     fixture can drive the renderer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_QUEUE_TIMEOUT=${FM_QUEUE_TIMEOUT:-300}
case "$FM_QUEUE_TIMEOUT" in ''|*[!0-9]*|0) FM_QUEUE_TIMEOUT=300 ;; esac
FM_QUEUE_TODAY=${FM_QUEUE_TODAY:-$(date +%F)}

usage() {
  cat <<'EOF'
usage: fm-queue.sh [--json]
       fm-queue.sh answer <row-id> [--group --members <list>] [--close done|release] [--text <answer>]

The queue: things the captain asked for, grouped by project, plus fleet
maintenance grouped apart. The listing is read-only; it starts nothing.

  --json     print the same model as JSON (schema fm-queue.v1)
  answer     record the captain's answer for one row. A captain hold closes
             through bin/fm-captain-hold.sh first; the answer is then handed
             off through the home's durable inbox and one wake is armed. The
             answer text comes from --text, or from stdin when --text is absent.
             --group takes a decision key (or a row of it this home holds)
             and applies the one answer to every row of that decision; it
             needs --members, the member list the decision showed, and is
             refused when the decision has changed since. This
             command starts no worker: whichever session holds
             the home drains the hand-off and acts.
  -h,--help  this help

Every row carries its state (queued, in flight, blocked, done, waiting on you,
answered, close pending, expired, deferred, aged, agent chore, tracking,
unknown), its wave, its tickets, its authoritative source, freshness, owner and
next action, plus its full text. Nothing is clipped and no bucket is capped.
The decisions list groups the rows waiting on you into one entry per call, each
with the command that answers it.
EOF
}

MODE=human
ROW_ID=""
CLOSE_MODE="done"
GROUP=0
MEMBERS=""
ANSWER_TEXT=""
ANSWER_TEXT_SET=0
case "${1:-}" in
  "") ;;
  --json) MODE=json ;;
  answer)
    MODE=answer
    shift
    ROW_ID=${1:-}
    [ -n "$ROW_ID" ] || { usage >&2; exit 2; }
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --group) GROUP=1 ;;
        --members)
          shift
          MEMBERS=${1:-}
          [ -n "$MEMBERS" ] || { usage >&2; exit 2; }
          ;;
        --close)
          shift
          CLOSE_MODE=${1:-}
          [ -n "$CLOSE_MODE" ] || { usage >&2; exit 2; }
          ;;
        --text)
          shift
          [ "$#" -ge 1 ] || { usage >&2; exit 2; }
          ANSWER_TEXT=$1
          ANSWER_TEXT_SET=1
          ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done
    case "$CLOSE_MODE" in
      done|release) ;;
      *) echo "fm-queue: --close must be done or release" >&2; exit 2 ;;
    esac
    # A group answer is bound to the members the captain was shown, so a row
    # that joined the decision later can never inherit his answer.
    if [ "$GROUP" = 1 ] && [ -z "$MEMBERS" ]; then
      echo "fm-queue: --group needs --members, the member list the decision showed (bin/fm-queue.sh prints it in the answer command)" >&2
      exit 2
    fi
    [ "$GROUP" = 1 ] || [ -z "$MEMBERS" ] || { echo "fm-queue: --members applies only with --group" >&2; exit 2; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$MODE" != answer ] && [ "$#" -gt 1 ]; then usage >&2; exit 2; fi

command -v jq >/dev/null 2>&1 || { echo "fm-queue: jq not found" >&2; exit 1; }

if [ -n "${FM_QUEUE_SNAPSHOT:-}" ]; then
  [ -r "$FM_QUEUE_SNAPSHOT" ] || { echo "fm-queue: cannot read $FM_QUEUE_SNAPSHOT" >&2; exit 1; }
  SNAP=$(cat "$FM_QUEUE_SNAPSHOT")
else
  [ -x "$SNAPSHOT" ] || { echo "fm-queue: missing $SNAPSHOT" >&2; exit 1; }
  SNAP=$(fm_run_timed "$FM_QUEUE_TIMEOUT" "$SNAPSHOT" --json) || {
    echo "fm-queue: the fleet snapshot did not complete within ${FM_QUEUE_TIMEOUT}s" >&2
    exit 1
  }
fi

case "$SNAP" in
  "{"*) ;;
  *) echo "fm-queue: the fleet snapshot returned no JSON object" >&2; exit 1 ;;
esac

# A silently empty queue would read as "nothing to do", so refuse any input that
# is not the canonical snapshot contract rather than rendering nothing from it.
SNAP_SCHEMA=$(printf '%s' "$SNAP" | jq -r '.schema // ""')
case "$SNAP_SCHEMA" in
  fm-fleet-snapshot.*) ;;
  *) echo "fm-queue: expected a canonical fleet snapshot, got schema '${SNAP_SCHEMA:-none}'" >&2; exit 1 ;;
esac

# The whole model is built once, in jq, and the mode only chooses what is
# printed from it: the human view, the JSON form, or (for `answer`) the same JSON
# the model already carries. The answer path reuses this exact model, so it acts
# on the state the listing would print, never on a second classification.
# The captain-call text patterns come from their one owner, bin/fm-classify-lib.sh,
# so this model classifies a call exactly as that library's functions do.
call_pattern() {  # <name>
  captain_call_patterns | while IFS=$'\t' read -r name pattern; do
    [ "$name" = "$1" ] && printf '%s' "$pattern"
  done
}
RE_CHORE=$(call_pattern chore)
RE_DATA_GUARD=$(call_pattern data_guard)
RE_MERGE=$(call_pattern merge)
RE_MONEY=$(call_pattern money)
RE_TRIVIA=$(call_pattern trivia)

render_model() {  # <mode: human|json|answer>
  printf '%s' "$SNAP" | jq -r --arg mode "$1" --arg today "$FM_QUEUE_TODAY" \
    --arg re_chore "$RE_CHORE" --arg re_data_guard "$RE_DATA_GUARD" \
    --arg re_merge "$RE_MERGE" \
    --arg re_money "$RE_MONEY" --arg re_trivia "$RE_TRIVIA" '
# ---------------------------------------------------------------------------
# shape helpers
# ---------------------------------------------------------------------------
def dash: if . == null or . == "" then "-" else tostring end;
def state_rank: {"waiting on you":0,"answered, close pending":1,"unknown":2,"blocked":3,"in flight":4,"queued":5,"expired":6,"deferred":7,"aged":8,"agent chore":9,"tracking":10,"done":11}[.] // 12;
# A held call read the way bin/fm-classify-lib.sh captain_call_class reads it:
# title plus hold reason, lowercased, whitespace folded, first match wins. The
# discard class comes only from the explicit marker bin/fm-captain-hold.sh hold
# --discard records, never from the words.
def call_text($r): ((($r.title // $r.name // "") + " " + ($r.hold_reason // "")) | ascii_downcase | gsub("\\s+"; " "));
def call_class($r):
  call_text($r) as $x
  | if ($r.hold_discard // false) == true then "discard"
    elif ($r.hold_credential // false) == true then "captain"
    elif ($x | test($re_data_guard)) then "captain"
    elif ($x | test($re_chore)) then "chore"
    else "captain" end;
# A captain hold asks the captain now only when it is undated (or dated today)
# and carries a question; every other kind stays visible under its own label.
def captain_state($r):
  ($r.hold_reason // "") as $why
  | if ($r.hold_bucket // null) == "aged" and ($r.captain_actionable // false) == false then "aged"
    elif ($why | test("^\\s*$")) or ($why | test("tracking"; "i")) or ($why | test("^\\s*routed to"; "i")) then "tracking"
    elif (($r.hold_until // "") != "" and $r.hold_until > $today) then "deferred"
    elif call_class($r) == "chore" then "agent chore"
    elif (($r.hold_until // "") != "" and $r.hold_until < $today) then "expired"
    else "waiting on you" end;
def captain_why($r; $state):
  if $state == "deferred" then "deferred by you until \($r.hold_until)"
  elif $state == "expired" then "deferred by you until \($r.hold_until); that date passed with no answer"
  elif $state == "aged" then "held for you (aged hold\(if ($r.hold_age_days // null) != null then ", \($r.hold_age_days)d old" else "" end))"
  elif $state == "agent chore" then "routine fleet housekeeping, not a call for you"
  elif $state == "tracking" then "tracking row; no question for you"
  else "held for you (\($r.hold_bucket // "live") hold\(if ($r.hold_age_days // null) != null then ", \($r.hold_age_days)d old" else "" end))" end;
def captain_next($state):
  if $state == "deferred" then "none until the date; then answer the hold"
  elif $state == "expired" then "you: answer it, or firstmate re-holds it with a new date"
  elif $state == "aged" then "firstmate: reconcile or re-hold it before returning it to the captain"
  elif $state == "agent chore" then "firstmate: do the cleanup and close the hold"
  elif $state == "tracking" then "firstmate: keep or retire the tracking row"
  else "you: answer the hold" end;
def is_captain_state: . == "waiting on you" or . == "expired" or . == "deferred" or . == "aged" or . == "agent chore" or . == "tracking";
# A recorded answer is bin/fm-captain-hold.sh resolution block in the row body.
def answer_recorded($r):
  ((($r.body_lines // []) | join("\n")) + "\n" + ($r.raw // "")) as $b
  | ($b | test("Resolution recorded by fm-(captain|decision)-hold\\.")) and ($b | test("(Captain decision|Reconciliation evidence):"));
def newest_resolution_mode($r):
  ((($r.body_lines // []) | join("\n")) + "\n" + ($r.raw // ""))
  | split("Resolution mode: ")
  | if length > 1 then (.[1] | split("\n") | .[0]) else null end;
def close_pending($r):
  answer_recorded($r) and (newest_resolution_mode($r) != "released");
# The call a row names, qualified by the home that holds it, so two homes that
# reuse one row id never share a decision. A parent mirror (a main-home row
# `captain-hold-<id>-<n>`) names the call of a secondmate only when exactly one
# mate row published that parent key; otherwise the mirror keeps its own key.
def call_ident($r; $mate_index):
  if $r.home != null then "\($r.home):\($r.id)"
  elif ($r.id | startswith("captain-hold-")) then
    ([ $mate_index[] | select(.pk == $r.id) ]) as $by_key
    | if ($by_key | length) == 1 then "\($by_key[0].home):\($by_key[0].id)"
      else "main:\($r.id)" end
  else "main:\($r.id)" end;
def completed_on($r):
  ((($r.completion // null) | if type == "object" then .date else null end) // $r.merged // null);
# Consequence text tier, below the explicit credential marker.
def call_tier($x):
  if ($x | test($re_merge)) then "merge"
  elif ($x | test($re_money)) then "money"
  elif ($x | test($re_trivia)) then "trivia"
  else "product" end;
def tier_rank: {"secret":0,"merge":1,"money":2,"product":3,"trivia":4}[.] // 5;
# The parent-channel key a secondmate published for one of its held rows.
def parent_key($tasks; $home; $id):
  ([ $tasks[] | select(.id == $home) | (.hints.open_decisions // [])[]?.key // empty
     | select(startswith("captain-hold-" + $id + "-") and (ltrimstr("captain-hold-" + $id + "-") | test("^[0-9]+$"))) ]
   | last) // null;
# Shell words for a printed command: a plain word as is, anything else quoted.
def shword:
  if test("^[A-Za-z0-9_./:@%+=,-]+$") then . else "\u0027" + gsub("\u0027"; "\u0027\\\u0027\u0027") + "\u0027" end;
# The members of a decision as the captain saw them, home-qualified and sorted:
# a group answer carries this list and is refused when the decision has changed.
def member_list($d): [ $d.members[] | "\(.home // "main"):\(.id)" ] | sort | join(",");
# The exact command that answers a decision, runnable from the code root of the
# home that holds it: a group through this queue, bound to the members shown
# (it closes the rows this home holds and routes secondmate rows in its one
# hand-off), a single row this home holds through this queue, and a single
# secondmate call through bin/fm-send.sh, which refuses to guess the home. The
# text sent to a secondmate always names its row, because only that text crosses.
def answer_command($d; $fm_home):
  "FM_HOME=\($fm_home | shword) " as $env
  | "\u0027<answer>\u0027" as $placeholder
  | if $d.count > 1 then "\($env)bin/fm-queue.sh answer \($d.key | shword) --group --members \(member_list($d) | shword) --text \($placeholder)"
    elif $d.home == null then "\($env)bin/fm-queue.sh answer \($d.id | shword) --text \($placeholder)"
    elif $d.parent_key != null then "\($env)bin/fm-send.sh \($d.home | shword) --resolve-key \($d.parent_key | shword) \("\($d.id): <answer>" | shword)"
    else "\($env)bin/fm-send.sh \($d.home | shword) \("\($d.id): <answer>" | shword)" end;
def cleanup_command($r; $fm_home):
  "FM_HOME=\($fm_home | shword) bin/fm-captain-hold.sh finish \($r.id | shword)";
def is_cut: type == "string" and test("…$");

# The canonical snapshot does not truncate this home own backlog rows, so a cut
# field can only come from a secondmate home ledger, and that ledger bounds each
# field differently. Carry the real number so the disclosure names the bound that
# actually applied instead of one invented constant.
def ledger_bound($src; $field):
  if $src == "active_children" then
    (if $field == "name" then 70 else 120 end)
  elif $src == "queued" then
    (if $field == "hold_reason" or $field == "blocked_reason" then 160
     elif $field == "kind" or $field == "hold_kind" or $field == "hold_until" or $field == "since" then 40
     else 120 end)
  elif $src == "landed" then
    (if $field == "kind" or $field == "hold_kind" then 40
     elif $field == "pr_url" or $field == "report_path" then 500
     else 120 end)
  elif $src == "decisions_open" then
    (if $field == "summary" or $field == "reason" then 160 else 120 end)
  else 160 end;
def cut_mark($src; $field; $value):
  if ($value // null) | is_cut then {field:$field, bound:ledger_bound($src; $field)} else empty end;
def mate_cut_fields($src; $r):
  [ cut_mark($src; "title"; $r.title),
    cut_mark($src; "hold_reason"; $r.hold_reason),
    cut_mark($src; "name"; $r.name),
    cut_mark($src; "doing"; $r.doing) ];
def cut_names: map("\(.field)(\(.bound))") | join(", ");

# Project grouping is bin/fm-project-lib.sh work, published on every snapshot row
# as project_resolution. The registry NAME is the group; the colour token is
# per-row display metadata, never the grouping key (one project resolves many
# sub-project rows onto one token). Absent resolution means a build older than
# that owner, so the raw repo label is used and the renderer says so.
def row_project($r):
  if ($r.project_resolution // null) == null then ($r.repo // "(no project recorded)")
  elif ($r.project_resolution.status // "") == "resolved"
    then ($r.project_resolution.project // $r.repo // "(no project recorded)")
  else "unresolved: " + ($r.project_resolution.reason // "project could not be resolved") end;
def row_project_status($r):
  if ($r.project_resolution // null) == null then "raw"
  elif ($r.project_resolution.status // "") == "resolved" then "resolved"
  else "unresolved" end;
def row_project_token($r): ($r.project_resolution.token // null);

# One layer number per id, from the declared blocked_by edges that stay inside
# the project. A project with no declared edge puts every row in layer 1, which
# the renderer states as "no declared dependencies".
def project_layers($ids; $g):
  def L($id; $seen):
    if ($seen | index($id)) != null then 1
    else
      [ ($g[$id] // [])[] | . as $d | select(($ids | index($d)) != null) | $d ] as $deps
      | if ($deps | length) == 0 then 1
        else ([ $deps[] | L(.; $seen + [$id]) ] | max) + 1
        end
    end;
  reduce ($ids[]) as $id ({}; .[$id] = L($id; []));

# One entry per project: its declared in-project edges, each row layer number,
# and the project layer count. A wave is one layer of one project, so nothing
# here crosses a project boundary.
def project_graph($records; project_of):
  ($records | map(select(.id != null)) | group_by(project_of))
  | reduce .[] as $grp ({};
      ($grp | map(.id)) as $ids
      | ($grp | map({key:.id, value:(.blocked_by_ids // [])}) | from_entries) as $g
      | project_layers($ids; $g) as $layers
      | (($g | to_entries
              | map([ .value[] | . as $d | select(($ids | index($d)) != null) ] | length)
              | add) // 0) as $edges
      | .[($grp[0] | project_of)] =
          {layers:$layers, edges:$edges, max_layer:(([$layers[]] | max) // 1)});

def endpoint_word($t):
  if $t == null then "none"
  elif $t.endpoint.exists == true then "present"
  elif $t.endpoint.exists == false then "gone"
  else "unknown" end;

def worker_state($t):
  if $t == null then null
  else {state:($t.current_state.state // "unknown"),
        source:($t.current_state.source // "none"),
        detail:($t.current_state.detail // null),
        observed_at:($t.current_state.observed_at // null),
        freshness:($t.current_state.freshness // null),
        endpoint:endpoint_word($t),
        backend:($t.backend // null),
        target:($t.endpoint.target // null)} end;

# State precedence, in order: a recorded Done row or a worker reading done; a live
# captain hold; an unresolved declared blocker; any other recorded hold; then
# whether a worker record exists at all (an in-flight row with none is unknown, a
# queued row with none is queued); then the worker current state. The first three
# rungs match bin/fm-inbox.sh status (firstmate patch 0007); the later rungs add
# what a whole queue needs and that in-flight-only surface never reached. A
# declared blocker deliberately outranks a live worker: the record says the row
# waits on something that has not landed, which is worth the captain seeing even
# when a worker is also running.
def row_state($r; $t):
  ($t.current_state.state // null) as $cs
  | if $r.state == "done" or $cs == "done" then "done"
    elif ($r.hold_kind // null) == "captain" and close_pending($r) then "answered, close pending"
    elif ($r.hold_kind // null) == "captain" and ($r.hold_bucket // "live") != "blocked" then captain_state($r)
    elif (($r.unresolved_blocker_ids // []) | length) > 0 then "blocked"
    elif ($r.hold_kind // null) != null then "blocked"
    elif $t == null then (if $r.state == "in_flight" then "unknown" else "queued" end)
    elif ($cs == null or $cs == "unknown") then "unknown"
    elif $cs == "blocked" or $cs == "failed" then "blocked"
    elif $cs == "working" or $cs == "parked" or $cs == "paused" then "in flight"
    else "unknown" end;

def why_of($r; $t; $state):
  ($t.current_state.state // null) as $cs
  | if $state == "done" and $r.state == "done" then "the queue row is recorded Done"
    elif $state == "done" then "the worker reads done (\($t.current_state.source))"
    elif $state == "answered, close pending" then "the captain answer is durable, but its close did not finish"
    elif ($state | is_captain_state) then captain_why($r; $state)
    elif $state == "unknown" and $t == null
      then "the row is in flight with no worker record (unknown/no-worker-record)"
    elif $state == "unknown"
      then "no proof either way: \($t.current_state.detail // "the worker record carries no current state") (\($t.current_state.source))"
    elif $state == "blocked" and (($r.unresolved_blocker_ids // []) | length) > 0
      then "waiting on \((($r.unresolved_blocker_ids // []) | join(", ")))"
    elif $state == "blocked" and ($r.hold_kind // null) != null
      then "held by a hold of kind \($r.hold_kind)"
    elif $state == "blocked" and $cs == "failed"
      then "the worker failed: \($t.current_state.detail // "no detail")"
    elif $state == "blocked"
      then "the worker declared itself blocked: \($t.current_state.detail // "no detail")"
    elif $state == "in flight" then "the worker is \($cs) (\($t.current_state.source))"
    elif $state == "queued" then "not dispatched"
    else "-" end;

def next_of($r; $state):
  if $state == "answered, close pending" then "firstmate: finish the recorded close"
  elif ($state | is_captain_state) then captain_next($state)
  elif $state == "unknown" then "firstmate: reconcile the row against its own record before anything else"
  elif $state == "blocked" and (($r.unresolved_blocker_ids // []) | length) > 0
    then "firstmate: clear \((($r.unresolved_blocker_ids // []) | join(", ")))"
  elif $state == "blocked" and ($r.hold_kind // null) != null
    then "firstmate: wait on the \($r.hold_kind) hold; do not re-dispatch"
  elif $state == "blocked" then "firstmate: re-dispatch or retire the failed worker"
  elif $state == "in flight" then "none - the worker is working"
  elif $state == "queued" then "firstmate: dispatch"
  else "none" end;

def hold_of($r):
  if ($r.hold_kind // null) != null or ($r.hold_reason // null) != null
  then {kind:($r.hold_kind // null), bucket:($r.hold_bucket // null),
        until:($r.hold_until // null), age_days:($r.hold_age_days // null),
        reason:($r.hold_reason // null)}
  else null end;

def record_text($r):
  if (($r.body_lines // []) | length) > 0
    then ([($r.title // "")] + $r.body_lines | map(select(. != "")) | join("\n"))
  elif ($r.title // null) != null then $r.title
  else ($r.raw // "") end;

def ticket_detail($t):
  ([ ($t.kind // "?"),
     (if $t.mode == null then null else $t.mode end),
     (if $t.harness == null then null else $t.harness end) ]
   | map(select(. != null)) | join("/"))
  + " on " + ($t.backend // "?")
  + "; worker " + ($t.current_state.state // "unknown") + " (" + ($t.current_state.source // "none") + ")"
  + "; endpoint " + endpoint_word($t)
  + (if ($t.current_state.detail // null) == null then "" else "; " + $t.current_state.detail end);

def snapshot_owner($t):
  if $t == null then "(main)"
  elif $t.kind == "secondmate" or $t.mode == "secondmate"
    then $t.id + (if ($t.remote.host // null) == null then " (local)" else " @" + $t.remote.host end)
  else "(main)" end;

def fresh_or($t; $fallback):
  if ($t != null) and (($t.current_state.observed_at // null) != null)
    then "\($t.current_state.freshness // "unknown") \($t.current_state.observed_at)"
  else $fallback end;

# ---------------------------------------------------------------------------
# render helpers
# ---------------------------------------------------------------------------
def indent($n; $s): $s | split("\n") | map("                "[0:$n] + .) | join("\n");
def wave_line:
  if . == null then "-"
  elif .edges == 0 then "1 of 1 (no declared dependencies in \(.project))"
  else "\(.layer) of \(.layers) (\(.edges) declared dependencies in \(.project))" end;
def hold_line:
  "\(.kind // "captain") hold"
  + (if .bucket == null then "" else " [\(.bucket)]" end)
  + (if .until == null then "" else ", until \(.until)" end)
  + (if .age_days == null then "" else ", \(.age_days)d old" end);
def row_lines:
  . as $row
  | [ "[\($row.state)] \($row.id)\(if $row.kind == null then "" else " (" + $row.kind + ")" end)",
      (if $row.class == "request" then empty else "  class      \($row.class) - not your request" end),
      "  what       \($row.text | split("\n") | .[0] | dash)",
      "  why        \($row.why | dash)",
      "  wave       \($row.wave | wave_line)",
      "  tickets    \(if ($row.tickets | length) == 0 then "none dispatched" else ($row.tickets | map("\(.id): \(.detail)") | join(" | ")) end)",
      "  unblocks   \(if ($row.unblocks | length) == 0 then "none" else ($row.unblocks | join(", ")) end)",
      "  owner      \($row.owner | dash)",
      "  source     \($row.source | dash)",
      "  freshness  \($row.freshness | dash)",
      "  next       \($row.next_action | dash)",
      (if $row.hold == null then empty else "  hold       \($row.hold | hold_line)" end),
      (if $row.hold == null or ($row.hold.reason // null) == null then empty else "  ask        \($row.hold.reason)" end),
      (if $row.worker == null then empty
       else "  worker     \($row.worker.state) (\($row.worker.source)) endpoint \($row.worker.endpoint)\(if $row.worker.detail == null then "" else " - " + $row.worker.detail end)" end),
      (if ($row.cut_fields | length) == 0 then empty
       else "  CUT        a secondmate ledger cut \($row.cut_fields | cut_names); full text: \($row.source), row \($row.id)" end),
      "  text",
      ($row.text | indent(4; .)),
      "" ];
def maintenance_lines:
  . as $row
  | [ "[\($row.state)] \($row.id)\(if $row.kind == null then "" else " (" + $row.kind + ")" end) - \($row.class) (not your request)",
      "  why        \($row.why | dash)",
      "  owner      \($row.owner | dash)   freshness  \($row.freshness | dash)",
      "  source     \($row.source | dash)",
      "  next       \($row.next_action | dash)",
      "  text",
      ($row.text | indent(4; .)),
      "" ];

# ---------------------------------------------------------------------------
# the model
# ---------------------------------------------------------------------------
. as $snap
| ($snap.generated) as $generated
| ($snap.backlog.records // []) as $records
| ($snap.tasks // []) as $tasks
| ($snap.secondmate_current.records // []) as $mates
| ($tasks | map({key:.id, value:.}) | from_entries) as $task_by_id
| ($records | project_graph(.; row_project(.))) as $pg

# request rows from this home own backlog
| [ $records[] | . as $r
    | ($r.id) as $rid
    | (if $rid == null then null else ($task_by_id[$rid] // null) end) as $t
    | row_state($r; $t) as $state
    | {id:($rid // "(row #\($r.order))"),
       request:"request", class:"request",
       project:row_project($r),
       project_status:row_project_status($r),
       kind:($r.kind // null),
       state:$state,
       why:why_of($r; $t; $state),
       owner:snapshot_owner($t),
       source:(if $rid == null then "data/backlog.md #\($r.order) (free-form row)"
               else "data/backlog.md #\($r.order)"
                    + (if $t != null then " + state/\($rid).meta + bin/fm-crew-state.sh" else " (no worker record)" end)
               end),
       freshness:fresh_or($t; "snapshot \($generated); filed \($r.since // "-")"),
       next_action:next_of($r; $state),
       wave:(if $rid == null then null
             elif ((($pg[row_project($r)].layers[$rid]) // null) == null) then null
             else {layer:$pg[row_project($r)].layers[$rid],
                   layers:$pg[row_project($r)].max_layer,
                   edges:$pg[row_project($r)].edges,
                   project:row_project($r)} end),
       tickets:(if $t == null then [] else [{id:$t.id, detail:ticket_detail($t)}] end),
       unblocks:[ $records[] | select(.id != null) | select(((.blocked_by_ids // []) | index($rid)) != null) | .id ],
       hold:hold_of($r),
       worker:worker_state($t),
       links:($r.links // []),
       artifact:($r.pr_url // $r.report_path // null),
       report_path:($r.report_path // null),
       hold_credential:($r.hold_credential // false),
       project_token:row_project_token($r),
       text_complete:true,
       cut_fields:[],
       home:null,
       call_class:(if ($r.hold_kind // null) == "captain" then call_class($r) else null end),
       answer_recorded:answer_recorded($r),
       completed:completed_on($r),
       text:record_text($r)} ] as $main_rows

# request rows owned by a registered secondmate home. That home ledger bounds its
# own text per field, so each row keeps the array it came from and the bound that
# array applied.
| [ $mates[] | . as $m
    | ([ ($m.active_children // [])[] | . + {__state:"in flight", __src:"active_children"} ]
       + [ ($m.queued // [])[] | . + {__state:(if (.hold_kind // null) == "captain" and (.hold_bucket // "live") != "blocked" then captain_state(.)
                                           elif ((.unresolved_blocker_ids // []) | length) > 0 then "blocked"
                                           elif (.hold_kind // null) != null then "blocked"
                                           else "queued" end), __src:"queued"} ]
       + [ ($m.landed // [])[] | . + {__state:"done", __src:"landed"} ])
    | group_by(.id) | map(.[0]) | .[]
    | . as $r
    | ($r.__state) as $state
    | (mate_cut_fields($r.__src; $r)) as $cuts
    | {id:$r.id,
       request:"request", class:"request",
       project:row_project($r),
       project_status:row_project_status($r),
       project_token:row_project_token($r),
       kind:($r.kind // null),
       state:$state,
       why:(if ($state | is_captain_state) then captain_why($r; $state)
            elif $state == "blocked" and (($r.unresolved_blocker_ids // []) | length) > 0
              then "waiting on \((($r.unresolved_blocker_ids // []) | join(", ")))"
            elif $state == "blocked" then "held by a hold of kind \($r.hold_kind)"
            elif $state == "in flight" then "the worker is \($r.state // "working") (\($r.source // "pane"))"
            elif $state == "done" then "the home records it landed"
            else "not dispatched" end),
       owner:("\($m.id)" + (if ($m.host // null) == null then " (local)" else " @" + $m.host end)),
       source:"\($m.provenance.structured_home // ($m.id + " home"))/data/backlog.md (secondmate ledger on \($m.host // "this host"), \($m.provenance.summary_source // "unknown"))",
       freshness:(if ($m.freshness.observed_at // null) != null
                  then "\($m.freshness.status // "unknown") \($m.freshness.observed_at) (\($m.freshness.age_seconds // "?")s)"
                  else "unavailable" end),
       next_action:(if ($state | is_captain_state) then captain_next($state)
                    elif $state == "blocked" and (($r.unresolved_blocker_ids // []) | length) > 0
                      then "firstmate: clear \((($r.unresolved_blocker_ids // []) | join(", ")))"
                    elif $state == "blocked" and ($r.hold_kind // null) != null
                      then "firstmate: wait on the \($r.hold_kind) hold; do not re-dispatch"
                    elif $state == "blocked" then "firstmate: re-dispatch or retire the failed worker"
                    elif $state == "in flight" then "none - the worker is working"
                    elif $state == "done" then "none"
                    else "firstmate: dispatch" end),
       wave:null,
       tickets:(if $state == "in flight" then [{id:$r.id, detail:"\($r.name // $r.id) - \($r.doing // "working")"}] else [] end),
       unblocks:[],
       hold:(if ($r.hold_kind // null) != null or ($r.hold_reason // null) != null
             then {kind:($r.hold_kind // null), bucket:($r.hold_bucket // null),
                   until:($r.hold_until // null), age_days:($r.hold_age_days // null),
                   reason:($r.hold_reason // null)}
             else null end),
       worker:null,
       links:[],
       artifact:($r.pr_url // $r.report_path // null),
       report_path:($r.report_path // null),
       hold_credential:($r.hold_credential // false),
       text_complete:(($cuts | length) == 0),
       cut_fields:$cuts,
       home:$m.id,
       call_class:(if ($r.hold_kind // null) == "captain" then call_class($r) else null end),
       answer_recorded:false,
       completed:completed_on($r),
       text:(if ($r.title // null) != null then $r.title else ($r.name // $r.id) end)} ] as $mate_rows

# fleet maintenance: fleet-health facts, never the captain own request
| ([ $tasks[] | select(.endpoint.exists == false)
       | select((.current_state.state // "unknown") != "done")
       | select((.backlog // null) != null and (.backlog.id // null) != null)
       | {id:(.id), request:"maintenance", class:"dead worker",
          project:"(fleet)", project_status:"n/a", project_token:null, kind:(.kind // null),
          state:"unknown",
          why:"the worker endpoint at \(.endpoint.target // "?") (\(.backend // "?")) is gone",
          owner:snapshot_owner(.),
          source:"state/\(.id).meta + bin/fm-crew-state.sh",
          freshness:fresh_or(. ; "unavailable"),
          next_action:"firstmate: reconcile the row before relaunching or retiring it",
          wave:null, tickets:[], unblocks:[], hold:null,
          worker:worker_state(.),
          links:[], artifact:null, text_complete:true, cut_fields:[],
          text:"worker \(.id) has no endpoint at \(.endpoint.target // "?") (\(.backend // "?")); its queue row above reads unknown"} ]
   + [ $snap.main_inventory
       | select(.valid == false)
       | {id:"record drift", request:"maintenance", class:"record drift",
          project:"(fleet)", project_status:"n/a", project_token:null, kind:null, state:"unknown",
          why:(.reason // "the home current inventory does not reconcile"),
          owner:"(main)", source:"fm-fleet-snapshot.sh main_inventory",
          freshness:"snapshot \($generated)",
          next_action:"firstmate: reconcile the record",
          wave:null, tickets:[], unblocks:[], hold:null, worker:null, links:[],
          artifact:null, text_complete:true, cut_fields:[],
          text:"orphan in-flight ids without metadata: \((.orphan_in_flight // []) | join(", "))\nunstructured current rows: \(.unstructured_current_count // 0)"} ]
   + [ $tasks[] | select(.kind != "secondmate" and .mode != "secondmate")
       | select((.backlog // null) == null or (.backlog.id // null) == null)
       | {id:(.id), request:"maintenance", class:"unrecorded follow-up",
          project:"(fleet)", project_status:"n/a", project_token:null, kind:(.kind // null), state:"unknown",
          why:"a worker record with no queue row behind it (endpoint \(endpoint_word(.)) at \(.endpoint.target // "?"))",
          owner:snapshot_owner(.),
          source:"state/\(.id).meta (no matching queue row)",
          freshness:fresh_or(. ; "unavailable"),
          next_action:"firstmate: file a queue row or retire the worker record",
          wave:null, tickets:[], unblocks:[], hold:null,
          worker:worker_state(.), links:[], artifact:null,
          text_complete:true, cut_fields:[],
          text:"worker \(.id) is recorded with no queue row"} ]
   + [ $mates[] | select((.provenance.summary_valid // true) == false or (.contradiction // false))
       | {id:(.id + " home"), request:"maintenance", class:"home drift",
          project:"(fleet)", project_status:"n/a", project_token:null, kind:null, state:"unknown",
          why:(.invalidity // .reason // "the home structured state is not readable"),
          owner:(.id),
          source:"\(.id) home ledger (\(.provenance.summary_source // "unknown"))",
          freshness:(if (.freshness.observed_at // null) != null then "\(.freshness.status // "unknown") \(.freshness.observed_at)" else "unavailable" end),
          next_action:"firstmate: reconcile that home before reading its rows as truth",
          wave:null, tickets:[], unblocks:[], hold:null, worker:null, links:[],
          artifact:null, text_complete:true, cut_fields:[],
          text:"\(.id): \(.invalidity // .reason // "structured home state unavailable")"} ]) as $maintenance

| ($main_rows + $mate_rows) as $rows

# The open-decisions set: one entry per call among the rows waiting on you.
| ([ $mate_rows[] | {id, home, pk:parent_key($tasks; .home; .id)} ]) as $mate_index
| ([ $rows[] | select(.state == "done" and .answer_recorded) | call_ident(.; $mate_index) ] | unique) as $answered_keys
| ([ $rows[] | select(.state == "waiting on you")
     | . + {ck:(if .call_class == "discard" then "discard-approval" else call_ident(.; $mate_index) end)} ]) as $waiting
# An answered call leaves before grouping.
| ([ $waiting[] | select(.ck != "discard-approval" and (.ck as $k | any($answered_keys[]; . == $k))) ] | length) as $answered_rows
| ([ $waiting[] | select(.ck == "discard-approval" or (.ck as $k | any($answered_keys[]; . == $k) | not)) ]
  ) as $open
| ([ $rows[] | select(.state == "answered, close pending")
     | {id, home, owner, project, command:cleanup_command(.; $snap.fm_home)} ]) as $cleanup
| ([ $open | group_by(.ck)[]
     | . as $members
     | ($members | sort_by([(.home != null), .id]) | .[0]) as $rep
     | ([ $members[].hold.age_days | select(. != null) ]) as $ages
     | (if $rep.call_class == "discard" then "discard" else "captain" end) as $class
     | (if $class == "discard"
        then "Keep or discard the unlanded work in \($members | length) cop\(if ($members | length) == 1 then "y" else "ies" end) a cleanup refused (one answer covers every copy)"
        else ($rep.text | split("\n") | .[0]) end) as $text
     | (if any($members[]; .hold_credential == true) then "secret"
        elif $class == "discard" then "merge"
        else call_tier(([ $members[] | ((.text | split("\n") | .[0]) + " " + (.hold.reason // "")) ] | join(" ")) | ascii_downcase | gsub("\\s+"; " ")) end) as $tier
     | {key:$members[0].ck,
        id:$rep.id, home:$rep.home, owner:$rep.owner, project:$rep.project,
        class:$class, tier:$tier,
        count:($members | length),
        members:[ $members[] | {id, home, owner, project} ],
        age_days:($ages | max),
        newest_age_days:($ages | min),
        due_today:any($members[]; (.hold.until // "") == $today),
        aged:all($members[]; .hold.bucket == "aged"),
        text:$text,
        reason:($rep.hold.reason // null),
        parent_key:(if $rep.home == null then null else parent_key($tasks; $rep.home; $rep.id) end)}
     | . + {answer:answer_command(.; $snap.fm_home)} ]
   | sort_by([(.tier | tier_rank), (if .due_today then 0 else 1 end), (if .aged then 1 else 0 end),
              (.newest_age_days // 1e9), (- .count), .key])
   | to_entries | map(.value + {rank:(.key + 1)})) as $decisions
| (([ $decisions[].count ] | add) // 0) as $kept_rows
| ([ $rows[] | select((.cut_fields | length) > 0) ] | length) as $cut_rows
| ([ $rows[] | select(.state == "done") ] | length) as $done_rows
| ([ $rows[] | select(.project_status == "raw") ] | length) as $raw_project_rows_total
| ([ $rows[] | select(.project_status == "unresolved") ] | length) as $unresolved_project_rows
| ([ $rows[].project ] | unique) as $project_names
| ([ $rows[] | select(.project == "(no project recorded)") ] | length) as $noproject_rows
| ([ $mates[] as $m | ($m.omitted // [])[] as $o
     | {surface:"\($m.id) home \($o.surface)",
        detail:"\($o.count) record(s) that home withheld; full text: \($m.provenance.structured_home // ($m.id + " home"))/data/backlog.md on \($m.host // "this host")"} ]) as $mate_bounds
| ($project_names | sort_by([
      (if . == "(no project recorded)" then 2
       elif (startswith("unresolved:")) then 1
       else 0 end), .])) as $ordered_projects

| {schema:"fm-queue.v1",
   home:($snap.fm_home),
   generated:$generated,
   snapshot_schema:($snap.schema),
   counts:{requests:($rows | length),
           maintenance:($maintenance | length),
           by_state:([$rows[].state] | group_by(.) | map({key:.[0], value:length}) | from_entries),
           maintenance_by_class:([$maintenance[].class] | group_by(.) | map({key:.[0], value:length}) | from_entries),
           task_records:($tasks | length),
           endpoints_gone:([ $tasks[] | select(.endpoint.exists == false) ] | length),
           endpoints_present:([ $tasks[] | select(.endpoint.exists == true) ] | length),
           decisions:($decisions | length),
           hygiene:{waiting_rows:($waiting | length),
                    grouped_rows:($kept_rows - ($decisions | length)),
                    answered_rows:$answered_rows,
                    answered_close_pending:($cleanup | length),
                    expired_rows:([ $rows[] | select(.state == "expired") ] | length),
                    aged_rows:([ $rows[] | select(.state == "aged") ] | length),
                    chore_rows:([ $rows[] | select(.state == "agent chore") ] | length)}},
   decisions:$decisions,
   cleanup:$cleanup,
   projects:[ $ordered_projects[] as $p
              | {name:$p,
                 project_status:([ $rows[] | select(.project == $p) | .project_status ] | .[0]),
                 rows:([ $rows[] | select(.project == $p) ] | sort_by((.state | state_rank), .id))} ],
   maintenance:($maintenance | sort_by(.class, .id)),
   bounds:([ {surface:"row text",
             detail:(if $cut_rows > 0
                     then "\($cut_rows) row(s) carry text a secondmate ledger cut (\([$rows[].cut_fields[] | "\(.field)(\(.bound))"] | unique | join(", "))); each such row is marked CUT and names its full-text source"
                     else "none - every row prints its full text" end)},
            {surface:"project grouping",
             detail:(if $raw_project_rows_total > 0
                     then "registry resolution unavailable in this build (snapshot carries no project_resolution), so \($raw_project_rows_total) row(s) are grouped by their raw repo label"
                     elif $unresolved_project_rows > 0
                     then "\($unresolved_project_rows) row(s) name a project the registry cannot resolve"
                     else "every row resolves to a registered project" end)},
            {surface:"rows with no project",
             detail:(if $noproject_rows > 0
                     then "\($noproject_rows) row(s) record no project (a secondmate landed row carries no repo in its home summary), grouped under (no project recorded)"
                     else "none - every row names the project it belongs to" end)},
            {surface:"done rows",
             detail:"\($done_rows) Done row(s) shown; the durable queue keeps only its configured recent Done history, so older landed work is not in this queue"},
            {surface:"secondmate homes",
             detail:(if (($snap.secondmate_current.truncated // 0) > 0)
                     then "\($snap.secondmate_current.shown) of \($snap.secondmate_current.total) registered home(s) shown"
                     else "all \($snap.secondmate_current.total // 0) registered home(s) shown" end)},
            {surface:"buckets",
             detail:(if ($mate_bounds | length) > 0
                     then "no list built from this home own backlog is capped, and every record it carries is printed; the secondmate home bounds above name what those homes withheld"
                     else "none - no list below is capped and every row the snapshot carries is printed" end)}] + $mate_bounds)} as $m

| if $mode == "json" or $mode == "answer" then $m
  else ( $m
    | "fm-queue - what you asked for, and what the fleet is doing",
      "home       \(.home)",
      "observed   \(.generated) (\(.snapshot_schema))",
      "rows       \(.counts.requests) request(s), of which \(.counts.by_state.done // 0) done; \(.counts.maintenance) fleet-maintenance record(s)",
      "states     " + ([.counts.by_state | to_entries[] | "\(.key) \(.value)"] | join("  |  ")),
      "workers    \(.counts.endpoints_present) endpoint(s) present, \(.counts.endpoints_gone) gone, of \(.counts.task_records) task record(s); a dead worker with a queue row reads unknown on that row",
      ( .bounds[] | "bounds     \(.surface): \(.detail)" ),
      "",
      "== decisions - \(.counts.decisions) open from \(.counts.hygiene.waiting_rows) row(s) waiting on you (\(.counts.hygiene.grouped_rows) grouped under the call of another row, \(.counts.hygiene.answered_rows) already answered); \(.counts.hygiene.expired_rows) expired, \(.counts.hygiene.aged_rows) aged, and \(.counts.hygiene.chore_rows) agent chore(s) kept apart",
      ( .decisions[] | "  \(.rank). [\(.tier)] \(.id)\(if .count > 1 then " (x\(.count): \([.members[].id] | join(", ")))" else "" end) - \(.text)", "     answer: \(.answer)" ),
      "",
      (if (.cleanup | length) == 0 then empty
       else "== needs cleanup - \(.cleanup | length) answered close(s) pending ==",
            (.cleanup[] | "  \(.id) - \(.command)"), "" end),
      ( .projects[] as $p
        | ($p.rows | map(select(.state != "answered, close pending"))) as $shown
        | select(($shown | length) > 0)
        | "== \($p.name)\(if $p.project_status == "raw" then "  (raw repo label - registry resolution unavailable in this build)" else "" end) - \($shown | length) row(s), \(([$shown[].wave.layer] | map(select(. != null)) | unique | length)) wave(s)",
          "",
          ( $shown[] | row_lines[] ) ),
      "== fleet maintenance - not your request (\(.maintenance | length)) ==",
      "",
      ( .maintenance[] | maintenance_lines[] ) )
  end
'
}

die() { printf 'fm-queue: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- answer

# Validate one row this home holds and, when it is a captain hold, record and
# close the captain's answer through the captain-hold owner. Prints
# `<state>\t<project>\t<keyed>` for the hand-off.
close_row() {  # <model-json> <home> <row-id>
  local model=$1 home=$2 id=$3 row owner state project keyed=0 dec
  # This home's own row first: a secondmate may reuse the same id, and only a row
  # this home holds can be answered here.
  row=$(printf '%s' "$model" | jq -c --arg id "$id" '([.projects[].rows[] | select(.id == $id)] | (map(select(.home == null)) + .) | .[0]) // empty')
  if [ -z "$row" ]; then
    if printf '%s' "$model" | jq -e --arg id "$id" '[.maintenance[].id] | index($id) != null' >/dev/null 2>&1; then
      die "row $id is a fleet-maintenance record, not something the captain asked for; there is no answer to record"
    fi
    die "no queue row with id $id"
  fi
  owner=$(printf '%s' "$row" | jq -r '.owner')
  state=$(printf '%s' "$row" | jq -r '.state')
  project=$(printf '%s' "$row" | jq -r '.project')

  [ "$owner" = "(main)" ] \
    || die "row $id belongs to $owner; answer it in that home, not this one"
  [ "$state" != "done" ] \
    || die "row $id already reads done; there is nothing left to answer"
  case "$state" in
    "waiting on you"|expired|deferred|aged|"agent chore"|tracking) keyed=1 ;;
    *) [ "$CLOSE_MODE" != release ] \
         || die "row $id is not a captain hold; --close release applies only to a held decision" ;;
  esac

  if [ "$keyed" = 1 ]; then
    dec=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-queue-answer.XXXXXX") \
      || die "cannot stage the captain's answer for the captain-hold owner"
    if ! printf '%s\n' "$ANSWER_TEXT" > "$dec"; then
      rm -f -- "$dec"
      die "cannot stage the captain's answer for the captain-hold owner"
    fi
    if [ "$CLOSE_MODE" = release ]; then
      FM_HOME="$home" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$id" --release --decision-file "$dec" >&2 \
        || { rm -f -- "$dec"; die "the captain-hold owner refused the answer for $id; nothing was handed off"; }
    else
      FM_HOME="$home" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$id" --decision-file "$dec" >&2 \
        || { rm -f -- "$dec"; die "the captain-hold owner refused the answer for $id; nothing was handed off"; }
    fi
    rm -f -- "$dec"
  fi
  printf '%s\t%s\t%s\n' "$state" "$project" "$keyed"
}

# Hand the captain's answer off. Keyed decisions close through the captain-hold
# owner at answer time so the row leaves `waiting on you` immediately, and every
# accepted answer then rides the home's durable inbox so a session that is stopped
# still handles it when it starts. This function starts nothing: it names no
# backend, no spawner and no lock. With --group, every row of the decision this
# home holds closes the same way, and the one hand-off names the rest.
cmd_answer() {  # <model-json>
  local model=$1 home state project keyed note_out closed id mate closed_ids='' routed='' body tail failed=''
  home=$(printf '%s' "$model" | jq -r '.home // ""')
  [ -n "$home" ] || die "the snapshot names no home to hand the answer off in"

  if [ "${ANSWER_TEXT//[[:space:]]/}" = "" ]; then
    die "refusing to hand off an empty answer; pass the captain's words with --text or on stdin"
  fi
  # The reserved value is the intake's, not this command's: `reconcile` means
  # "go re-check reality", never "the captain answered". Refuse it here so it can
  # never be recorded as a decision.
  [ "$ANSWER_TEXT" != "reconcile" ] \
    || die "'reconcile' is not an answer; it asks firstmate to re-check the row's reality"

  if [ "$GROUP" = 0 ]; then
    closed=$(close_row "$model" "$home" "$ROW_ID") || exit 1
    IFS=$'\t' read -r state project keyed <<EOF
$closed
EOF
    if [ "$keyed" = 1 ]; then
      tail=$(printf 'the captain-hold decision for %s was recorded and closed through bin/fm-captain-hold.sh before this hand-off; act on what that decision unblocks.' "$ROW_ID")
    else
      tail=$(printf 'act on this answer for row %s: dispatch, approve, or retire it as the answer requires.' "$ROW_ID")
    fi
    body=$(printf 'queue-answer row=%s project=%s keyed=%s close=%s\nstate when answered: %s\nthe captain answered:\n%s\n\n%s\n' \
      "$ROW_ID" "$project" "$keyed" "$CLOSE_MODE" "$state" "$ANSWER_TEXT" "$tail")
  else
    local decision members closed_line routed_line
    # A decision key names the decision; a bare row id names the one decision
    # holding that row in this home, never a secondmate row that reuses the id.
    decision=$(printf '%s' "$model" | jq -c --arg id "$ROW_ID" '
      ([.decisions[] | select(.key == $id)] + [.decisions[] | select(any(.members[]; .id == $id and .home == null))]
       | .[0]) // empty')
    [ -n "$decision" ] || die "$ROW_ID is no open decision key and no row this home holds in one; answer it without --group"
    local shown now
    shown=$(printf '%s' "$MEMBERS" | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)
    now=$(printf '%s' "$decision" | jq -r '[.members[] | "\(.home // "main"):\(.id)"] | .[]' | LC_ALL=C sort | paste -sd, -)
    [ "$shown" = "$now" ] \
      || die "the decision now holds $now, not the $shown it showed; nothing was answered. Re-read the queue and answer the decision as it stands"
    members=$(printf '%s' "$decision" | jq -r '.members[] | "\(.id)\t\(.home // "")"')
    project=$(printf '%s' "$decision" | jq -r '.project')
    while IFS=$'\t' read -r id mate; do
      [ -n "$id" ] || continue
      if [ -n "$mate" ]; then
        routed="$routed$mate: $id"$'\n'
        continue
      fi
      if ! closed=$(close_row "$model" "$home" "$id"); then
        failed=$id
        break
      fi
      closed_ids="$closed_ids${closed_ids:+,}$id"
    done <<EOF
$members
EOF
    if [ -z "$closed_ids" ] && { [ -n "$failed" ] || [ -z "$routed" ]; }; then
      die "no row of that decision was answered${failed:+ ($failed was refused)}; nothing was handed off"
    fi
    state="waiting on you"
    keyed=0
    if [ -n "$closed_ids" ]; then
      keyed=1
      closed_line=$(printf 'the captain-hold decisions for %s were recorded and closed through bin/fm-captain-hold.sh before this hand-off; act on what that decision unblocks.' "$closed_ids")
    else
      closed_line='no row of this decision is held in this home; nothing was closed here.'
    fi
    routed_line=''
    [ -z "$routed" ] || routed_line=$(printf 'route the same answer to these secondmate rows of the decision, each in its own home:\n%s' "$routed")
    body=$(printf 'queue-answer row=%s project=%s keyed=%s close=%s rows=%s\nstate when answered: %s\nthe captain answered, once for every row of this decision:\n%s\n\n%s\n%s%s' \
      "$ROW_ID" "$project" "$keyed" "$CLOSE_MODE" "${closed_ids:--}" "$state" "$ANSWER_TEXT" "$closed_line" "$routed_line" \
      "$(if [ -n "$failed" ]; then printf '\nthe captain-hold owner refused %s, so it and the rows after it were NOT answered; reconcile them before acting.' "$failed"; fi)")
  fi

  note_out=$(printf '%s' "$body" | FM_HOME="$home" "$SCRIPT_DIR/fm-inbox.sh" note -) \
    || die "the hand-off for $ROW_ID failed: bin/fm-inbox.sh did not confirm the durable inbox record and its wake"

  printf 'answered row %s (%s)\n' "$ROW_ID" "$project"
  printf '  state     %s\n' "$state"
  if [ "$GROUP" = 1 ]; then
    printf '  decision  recorded and closed through the captain-hold owner for %s\n' "${closed_ids:-no row in this home}"
    [ -z "$routed" ] || printf '  routed    named in the hand-off for firstmate: %s\n' "$(printf '%s' "$routed" | tr '\n' ' ')"
  elif [ "$keyed" = 1 ]; then
    printf '  decision  recorded and closed through the captain-hold owner\n'
  fi
  printf '  handoff   durable inbox note queued in the home, one wake armed\n'
  printf '%s\n' "$note_out" | sed 's/^/            /'
  printf '  worker    none started by this command; whichever session holds the home drains the hand-off\n'
  [ -z "$failed" ] || die "the captain-hold owner refused $failed; it and the rows after it were not answered (the hand-off says so)"
}

if [ "$MODE" = answer ] && [ "$ANSWER_TEXT_SET" = 0 ]; then
  ANSWER_TEXT=$(cat)
fi

case "$MODE" in
  human|json) render_model "$MODE" ;;
  answer) cmd_answer "$(render_model answer)" ;;
esac
