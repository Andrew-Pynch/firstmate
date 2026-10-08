#!/usr/bin/env bash
# Propagate one captain authority change to every affected owner, in one step.
#
# Usage:
#   fm-authority-amend.sh [--wait <secs>] (--authority <text> | --authority -) <task-id>...
#
# What this exists for: on 2026-09-13 the captain lifted a cross-host
# credential-transfer exclusion at 05:43:46Z, Main recorded the supersession in
# data/captain.md at 05:44:36Z, a running worker was still refusing the work
# under its older brief at 07:09:49Z, and the correction only reached that
# worker at 07:10:02Z - 86 minutes of stale authority and one wasted worker run
# (data/overnight-acceptance-retro/report.md section 2.5). The amend mechanism
# was never missing: bin/fm-send.sh already amends a running worker through its
# durable steering inbox. What was missing was one operation that does the
# whole propagation together, so an authority change cannot sit half-applied
# while a worker keeps obeying text the captain has already superseded.
#
# One step means, for each named task, in this order:
#   1. deliver the words through the existing durable steering inbox
#      (bin/fm-send.sh; no second messaging plane is introduced here), and
#   2. append the same words to that task's brief `## Captain's intent`
#      subsection through bin/fm-dod-lib.sh's one writer, so the record the
#      task is judged against carries the new authority too, and
#   3. report which owners acknowledged the steer (the worker's own move of the
#      record into its inbox handled/ directory is the only acknowledgement).
# Use bin/fm-send.sh directly for any ordinary mid-task steer; this script is
# only for an authority or scope change that has to reach several owners at once.
#
# The words are the captain's own. Never add a speaker label or direct address:
# the `## Captain's intent` heading supplies provenance (bin/fm-dod-lib.sh owns
# that contract), and a body line opening with a Captain label or address is
# refused here before anything is written, as is text carrying a markdown
# heading or code fence line that would end or swallow the subsection.
#
# Scope and refusal boundaries:
#   - Only the named task ids are ever touched. Ids are matched literally as
#     `[A-Za-z0-9._-]+`; a wildcard, glob, path, or any other id shape is
#     refused, so one invocation cannot reach a task the caller did not name.
#   - Every named task is validated before anything is written or sent, so a
#     bad id, a missing brief, or a secret body refuses the whole run with
#     nothing half-applied.
#   - The message is refused when it carries a secret-shaped value, by shape
#     only - private key headers, AWS/GitHub/Slack tokens, JWTs, `sk-` keys,
#     `Bearer` tokens, and `password`/`token`/`secret`/`credential` assignments
#     to a 12+ character dotless value. The refusal names the shape, never the
#     matched value, because a secret leaked into a log by its own guard is
#     still leaked. Shape matching is deliberately fail-closed: rewrite the
#     words rather than weaken this list, and copy a credential through its own
#     channel instead of through a steer.
#   - A named task id whose brief has no `## Captain's intent` subsection is
#     still steered and reports `intent=skipped(not-a-task-brief)` (a
#     secondmate charter brief is such a brief); a brief that has a `# Task`
#     section but lost the subsection is refused, matching how bin/fm-spawn.sh
#     refuses a legacy mixed Task brief with no provenance-marked captain words.
#   - A named task with no `state/<id>.meta` has no live owner to steer: the
#     brief is still amended and the task reports `steer=no-owner`, because the
#     durable brief is what a later dispatch is judged against.
#   - A remote secondmate keeps its brief and inbox in its own home. The steer
#     reaches it over the existing remote transport and the mate owns further
#     propagation inside its home; this script reports `steer=remote` and never
#     writes into another home.
#
# --wait <secs> polls for acknowledgements after every steer is enqueued
# (default 0: report the state observed right away). An unacknowledged record
# is not a failed propagation: the watcher's re-ring ladder owns it from there,
# and `bin/fm-task-inbox-lib.sh` owns that schedule.
#
# Exit status: 0 when every named task was amended or steered as above; 1 when
# any named task could not be (the refusal names the task and the reason).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# amend a brief or steer a worker (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-authority-amend refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-authority-amend cannot resolve this home's data" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-authority-amend cannot resolve this home's tasks" >&2
  exit 1
fi
if [ ! -d "$DATA" ]; then
  echo "error: data dir '$DATA' is missing; fm-authority-amend cannot find this home's briefs" >&2
  exit 1
fi

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() { sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

FM_AUTHORITY_SECRET_KINDS=(
  private-key
  aws-access-key-id
  github-token
  slack-token
  jwt
  api-key
  bearer-token
  assigned-secret
)
FM_AUTHORITY_SECRET_PATTERNS=(
  '[-]{5}BEGIN [A-Z0-9 ]*PRIVATE KEY[-]{5}'
  '(AKIA|ASIA)[0-9A-Z]{16}'
  '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
  'sk-[A-Za-z0-9]{20,}'
  '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{20,}'
  '(password|passwd|secret|token|api[_-]?key|credential)s?[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_+/-]{12,}'
)

# Print the shape of the first secret-looking value in the text on stdin, and
# fail when the text carries none. Only the shape name is printed; the matched
# value never reaches stdout, stderr, or a log.
fm_authority_secret_kind() {
  local entry text
  text=$(cat)
  for entry in "${!FM_AUTHORITY_SECRET_PATTERNS[@]}"; do
    if printf '%s\n' "$text" | LC_ALL=C grep -Eq -- "${FM_AUTHORITY_SECRET_PATTERNS[$entry]}"; then
      printf '%s' "${FM_AUTHORITY_SECRET_KINDS[$entry]}"
      return 0
    fi
  done
  return 1
}

fm_authority_valid_id() {  # <task-id>
  case "$1" in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# Print the shape of the first line that would break the brief's intent
# subsection, and fail when the text has none. The appended words land inside
# that subsection, so a line the brief's own reader treats as its end (an
# unfenced ATX heading at level 1 or 2) or as an unterminated code fence would
# silently cut the words, or everything after them, out of the parsed body.
# Refusing here keeps that from surfacing later as a corrupted brief.
fm_authority_body_hazard() {  # <- text on stdin
  LC_ALL=C awk '
    hazard == "" && /^ {0,3}#{1,2}([[:space:]]|$)/ { hazard = "a markdown heading line" }
    hazard == "" && /^ {0,3}(```|~~~)/ { hazard = "a code fence line" }
    END {
      if (hazard == "") exit 1
      print hazard
    }
  '
}

# The record this steer produced: the newest record at or after the sequence
# slot observed before the send whose body is this steer's text. A marked
# secondmate request keeps the from-firstmate marker and correlation token as a
# prefix inside the same body (bin/fm-marker-lib.sh owns that prefix), so the
# match is on the body's tail. Comparing the body is what makes this a lookup
# rather than a guess: a concurrent enqueue by another actor on the same inbox
# cannot be mistaken for this one.
fm_authority_find_record() {  # <state-dir> <task-id> <min-seq> <text>
  local state=$1 task=$2 min=$3 text=$4 dir f n body
  dir=$(fm_task_inbox_dir "$state" "$task")
  for f in "$dir"/*.msg "$dir"/handled/*.msg; do
    [ -e "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -ge "$min" ] || continue
    body=$(fm_task_inbox_body "$f") || continue
    case "$body" in
      *"$text") ;;
      *) continue ;;
    esac
    printf '%s' "$f"
    return 0
  done
  return 1
}

fm_authority_record_acknowledged() {  # <record-path>
  local rec=$1
  case "$rec" in
    */handled/*) return 0 ;;
  esac
  [ -e "${rec%/*}/handled/${rec##*/}" ]
}

fm_authority_meta_get() {  # <meta-file> <key>
  awk -v want="$2" '
    index($0, want "=") == 1 { print substr($0, length(want) + 2); exit }
  ' "$1"
}

WAIT_SECS=0
AUTHORITY=
AUTHORITY_SET=0
TASK_IDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority)
      [ "$#" -ge 2 ] || usage
      AUTHORITY=$2
      AUTHORITY_SET=1
      shift 2
      ;;
    --wait)
      [ "$#" -ge 2 ] || usage
      WAIT_SECS=$2
      shift 2
      ;;
    --help | -h) usage ;;
    -*) echo "error: unknown option '$1'" >&2; exit 2 ;;
    *)
      TASK_IDS+=("$1")
      shift
      ;;
  esac
done

case "$WAIT_SECS" in '' | *[!0-9]*) echo "error: --wait takes whole seconds: $WAIT_SECS" >&2; exit 2 ;; esac
[ "$AUTHORITY_SET" -eq 1 ] || { echo "error: --authority <text> (or --authority -) is required" >&2; exit 2; }
[ "${#TASK_IDS[@]}" -gt 0 ] || { echo "error: name at least one affected task id" >&2; exit 2; }
if [ "$AUTHORITY" = - ]; then
  AUTHORITY=$(cat)
fi
if [ -z "$(printf '%s' "$AUTHORITY" | tr -d '[:space:]')" ]; then
  echo "error: the authority text is empty; nothing was amended or sent" >&2
  exit 2
fi
while [ "${AUTHORITY%$'\n'}" != "$AUTHORITY" ]; do AUTHORITY=${AUTHORITY%$'\n'}; done

if kind=$(printf '%s\n' "$AUTHORITY" | fm_authority_secret_kind); then
  echo "error: refusing to propagate an authority change whose body carries a secret-shaped value ($kind); copy the credential through its own channel and restate the authority without it" >&2
  exit 1
fi

# The appended words and the steered words are the same bytes on purpose: one
# body, one owner, no chance of the brief and the instruction disagreeing.
ADDRESS_PROBE=$(mktemp "${TMPDIR:-/tmp}/fm-authority-address.XXXXXX") || exit 1
trap 'rm -f "$ADDRESS_PROBE"' EXIT
printf '# Task\n## Captain'"'"'s intent\n%s\n' "$AUTHORITY" > "$ADDRESS_PROBE"
if address_line=$(fm_brief_intent_address_line "$ADDRESS_PROBE"); then
  echo "error: the authority text opens with an operator label or address ('$address_line'); pass the captain's actual words, which the '## Captain's intent' heading already credits" >&2
  exit 1
fi
rm -f "$ADDRESS_PROBE"
trap - EXIT

if hazard=$(printf '%s\n' "$AUTHORITY" | fm_authority_body_hazard); then
  echo "error: the authority text contains $hazard, which would end or swallow the brief's '## Captain's intent' subsection; restate it as prose (nothing was amended or sent)" >&2
  exit 1
fi

# --- preflight: validate every named task before any write ------------------
P_TASKS=()
P_BRIEFS=()
P_MODES=()   # amend | skip-not-a-task-brief
P_STEER=()   # local | remote | no-owner
seen_ids=''
for id in "${TASK_IDS[@]}"; do
  if ! fm_authority_valid_id "$id"; then
    echo "error: '$id' is not a literal task id; fm-authority-amend only touches the ids you name" >&2
    exit 1
  fi
  case "$seen_ids" in
    *" $id "*) continue ;;
  esac
  seen_ids="$seen_ids $id "
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] && [ -r "$brief" ] || {
    echo "error: no readable brief at $brief; name the task ids this change affects (nothing was amended or sent)" >&2
    exit 1
  }
  [ -w "$DATA/$id" ] || {
    echo "error: $DATA/$id is not writable; nothing was amended or sent" >&2
    exit 1
  }
  mode=skip-not-a-task-brief
  if fm_brief_task_heading_present "$brief" "## Captain's intent"; then
    mode=amend
  elif fm_brief_task_heading_present "$brief" "# Task"; then
    echo "error: $brief has a '## Task' section but no '## Captain's intent' subsection; its captain words cannot be told apart from Firstmate specification, so amend it by hand (nothing was amended or sent)" >&2
    exit 1
  fi
  steer=no-owner
  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    if [ -n "$(fm_authority_meta_get "$meta" remote_host)" ]; then
      steer=remote
    else
      steer=local
    fi
  fi
  P_TASKS+=("$id")
  P_BRIEFS+=("$brief")
  P_MODES+=("$mode")
  P_STEER+=("$steer")
done

# --- apply: steer, then amend the brief the task is judged against ----------
R_INTENT=()
R_STEER=()
R_RECORDS=()
FAILED=0
for i in "${!P_TASKS[@]}"; do
  id=${P_TASKS[$i]}
  brief=${P_BRIEFS[$i]}
  intent=${P_MODES[$i]}
  steer=${P_STEER[$i]}
  record=
  if [ "$steer" != no-owner ]; then
    min_seq=$(fm_task_inbox_next_seq "$(fm_task_inbox_dir "$STATE" "$id")")
    if ! err=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-send.sh" "$id" "$AUTHORITY" 2>&1 >/dev/null); then
      intent="failed(steer: ${err:-fm-send exited nonzero})"
      steer=failed
      R_INTENT+=("$intent")
      R_STEER+=("$steer")
      R_RECORDS+=("")
      continue
    fi
    if [ "$steer" = local ]; then
      if record=$(fm_authority_find_record "$STATE" "$id" "$min_seq" "$AUTHORITY"); then
        steer=enqueued
      else
        intent="failed(steer: no record found in $STATE/$id.inbox)"
        steer=failed
        R_INTENT+=("$intent")
        R_STEER+=("$steer")
        R_RECORDS+=("")
        continue
      fi
    fi
  fi
  if [ "$intent" = amend ]; then
    if fm_brief_intent_append "$brief" "$AUTHORITY"; then
      intent=amended
    else
      intent='failed(brief)'
    fi
  elif [ "$intent" = skip-not-a-task-brief ]; then
    intent=skipped-not-a-task-brief
  fi
  R_INTENT+=("$intent")
  R_STEER+=("$steer")
  R_RECORDS+=("$record")
done

# --- acknowledgement window -------------------------------------------------
if [ "$WAIT_SECS" -gt 0 ]; then
  deadline=$(( $(date +%s) + WAIT_SECS ))
  while :; do
    pending=0
    for record in "${R_RECORDS[@]}"; do
      [ -n "$record" ] || continue
      fm_authority_record_acknowledged "$record" || pending=1
    done
    [ "$pending" -eq 1 ] || break
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
fi

for i in "${!P_TASKS[@]}"; do
  id=${P_TASKS[$i]}
  ack=not-applicable
  case "${R_STEER[$i]}" in
    enqueued)
      if fm_authority_record_acknowledged "${R_RECORDS[$i]}"; then ack=acknowledged; else ack=pending; fi
      ;;
    remote) ack=owner-status-reply ;;
    failed) ack=not-applicable ;;
  esac
  case "${R_INTENT[$i]}" in
    failed\(*) FAILED=$((FAILED + 1)) ;;
  esac
  line="$id: intent=${R_INTENT[$i]} steer=${R_STEER[$i]}"
  [ -z "${R_RECORDS[$i]}" ] || line="$line record=${R_RECORDS[$i]}"
  printf '%s ack=%s\n' "$line" "$ack"
done
printf 'summary: tasks=%s failed=%s\n' "${#P_TASKS[@]}" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
