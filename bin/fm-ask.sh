#!/usr/bin/env bash
# fm-ask.sh - the ask record and its park path.
#
# An ask is a question firstmate puts to the captain while he is PRESENT: a
# decision the turn it is asked in depends on. Anything that can wait is a
# queue row instead, and an ask the captain does not answer within its wait
# parks itself into that queue and releases the agent that was waiting on it,
# because an ask must never hold an agent indefinitely. `ask.timeout` stays
# disabled and is deliberately NOT the mechanism: a timeout-selected option is
# not the captain's answer.
#
# READ FIRST, THEN ASK. `open` records the question, the waiting agent and the
# wait BEFORE any dialog is presented, and the record is the ask. A question
# that was never recorded cannot be parked, so an ask that is presented without
# a record is a lost question; an ask that is recorded and never answered is a
# queue row the moment its wait elapses.
#
# PARK. `park` sweeps the open asks and, for every ask past its deadline:
#   1. files the queue row the question becomes, through the SAME owner every
#      captain question uses (bin/fm-captain-hold.sh hold, which creates the
#      row when the work item does not exist yet), so the row carries
#      hold_kind=captain and renders as `waiting on you` in bin/fm-queue.sh,
#      and so the captain's answer closes it through the ONE keyed-answer
#      intake. The row id IS the ask key: the key is the identity, as it is
#      for a captain call, and a key that already names a different row is
#      refused by that owner rather than silently reused.
#   2. releases the waiting agent, so the ask stops holding it. A task agent
#      gets one durable release record in its steering inbox (the transport
#      bin/fm-task-inbox-lib.sh owns; the watcher's ordinary ladder delivers
#      it and escalates if it cannot, exactly as for any other steer), stating
#      that the question is parked, that the release is NOT the answer, and
#      where the answer will arrive. The release is never sent through
#      bin/fm-send.sh's answerer-closes flag: that would record a parked
#      question as an ANSWERED decision, which is the false record this whole
#      path exists to prevent.
#   3. records both facts on the ask itself, so the ask, the row and the
#      release are one reconcilable story.
# A session agent (this home's own firstmate turn, named `main`) has no inbox:
# its release is the park line plus the record, because the question has left
# the turn for the queue.
# `park` is idempotent: a second sweep files no second row and writes no
# second release. A parked ask whose row is closed is retired as resolved, so
# the ask ledger matches the row it became instead of leaking forever.
#
# Contract:
#   - `open` and `park` mutate this home only, are serialized, and refuse while
#     a DIFFERENT live session holds this home's session lock (bin/fm-lock.sh),
#     because only the owning session may change the home's records.
#   - `open` never presents anything: presenting the question is the calling
#     agent's job, and this command has no dialog of its own.
#   - `park` never answers a question, never invents one, never enables
#     ask.timeout or any other harness setting, and never closes the row it
#     files. It holds records true; the captain's words close the row.
#   - `list` is read-only: it takes no lock and creates nothing.
#
# Usage:
#   fm-ask.sh open <key> --question <text> --agent <task-id|main> [--repo <repo>] [--wait <seconds>]
#   fm-ask.sh park [--now <epoch>] [--dry-run]
#   fm-ask.sh list
#   fm-ask.sh resolve <key> --reason <text>
#   fm-ask.sh -h | --help
#
# `open` prints the key; `resolve` and `park` print one line per action and are
# silent when nothing is due. `--now`/FM_ASK_NOW name the epoch the sweep
# judges deadlines against, so a wait can be exercised without sleeping.
#
# Environment:
#   FM_HOME         operational home whose state/ and data/ are used.
#   FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE  redirected roots.
#   FM_ASK_WAIT     default wait in seconds (over the config file below).
#   FM_ASK_NOW      epoch the sweep treats as now.
#
# Configuration:
#   config/ask-wait   default wait in whole seconds for a home that wants one
#                     other than the built-in 900. A value that is not a
#                     positive whole number is refused, never guessed around.
#
# Records live in state/asks/<key>.ask, one `schema=fm-ask.v1` key=value block.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ASKS="$STATE/asks"
PARK_LOCK="$STATE/.ask-park.lock"
DEFAULT_WAIT=900
FM_ASK_SCHEMA=fm-ask.v1

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  printf '%s\n' \
    'usage: fm-ask.sh open <key> --question <text> --agent <task-id|main> [--repo <repo>] [--wait <seconds>]' \
    '       fm-ask.sh park [--now <epoch>] [--dry-run]' \
    '       fm-ask.sh list' \
    '       fm-ask.sh resolve <key> --reason <text>' \
    '  open     record an ask before it is presented' \
    '  park     file every ask past its wait as a queue row and release its agent' \
    '  list     read-only view of the ask ledger' \
    '  resolve  close an ask the captain answered in-line, or withdrew' \
    '  --now    epoch the sweep judges deadlines against (default: now)' >&2
}

fail() {
  printf 'fm-ask: %s\n' "$1" >&2
  exit 1
}

require_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

require_one_line() {  # <label> <value>
  [ -n "$2" ] || fail "$1 must not be empty"
  case "$2" in
    *$'\n'*|*$'\r'*) fail "$1 must be one line" ;;
  esac
}

require_digits() {  # <label> <value>
  case "$2" in
    ''|*[!0-9]*) fail "$1 must be a whole number of seconds: $2" ;;
  esac
  [ "$2" -gt 0 ] || fail "$1 must be greater than zero"
}

field_of() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

ask_path() {  # <key>
  printf '%s/%s.ask' "$ASKS" "$1"
}

require_tasks_axi() {
  command -v tasks-axi >/dev/null 2>&1 \
    || fail 'tasks-axi is not on PATH; the queue row cannot be filed'
}

# The epoch this run treats as now. FM_ASK_NOW exists so a wait is exercised
# without sleeping.
now_epoch() {
  local now=${FM_ASK_NOW:-}
  if [ -n "$now" ]; then
    case "$now" in
      ''|*[!0-9]*) fail "FM_ASK_NOW must be an epoch second: $now" ;;
    esac
    printf '%s' "$now"
    return 0
  fi
  date +%s
}

# The wait for a new ask: --wait, then FM_ASK_WAIT, then config/ask-wait, then
# the built-in default. A malformed configured value is refused rather than
# silently replaced, because a wait nobody set is how an ask ends up holding an
# agent for the wrong length of time.
resolve_wait() {  # <explicit-or-empty>
  local value=$1
  if [ -z "$value" ]; then
    value=${FM_ASK_WAIT:-}
  fi
  if [ -z "$value" ] && [ -f "$CONFIG/ask-wait" ]; then
    value=$(tr -d '[:space:]' < "$CONFIG/ask-wait")
  fi
  if [ -z "$value" ]; then
    printf '%s' "$DEFAULT_WAIT"
    return 0
  fi
  case "$value" in
    ''|*[!0-9]*) fail "the ask wait must be a whole number of seconds: $value" ;;
  esac
  [ "$value" -gt 0 ] || fail 'the ask wait must be greater than zero'
  printf '%s' "$value"
}

# Only the session that owns this home's lock may change its records. A home
# with no lock, a malformed lock, or a stale lock is free; a lock held by a
# DIFFERENT live session refuses.
require_home_owner() {
  local lock_pid
  [ -f "$STATE/.lock" ] || return 0
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 0 ;; esac
  fm_harness_pid_alive "$lock_pid" || return 0
  fm_session_lock_owned_by_self "$STATE" && return 0
  fail "another live session holds this home's lock; ask records are changed only by the owning session"
}

write_record() {  # <path> <key> <question> <agent> <agent_kind> <repo> <wait> <opened_at> <opened> <state> [<extra-line>...]
  local path=$1 key=$2 question=$3 agent=$4 agent_kind=$5 repo=$6 wait=$7 opened_at=$8 opened=$9 state=${10}
  shift 10
  local tmp
  [ -d "$ASKS" ] || mkdir -p "$ASKS"
  tmp=$(mktemp "$ASKS/.staging.XXXXXX") || fail "cannot stage the ask record for $key"
  {
    printf 'schema=%s\n' "$FM_ASK_SCHEMA"
    printf 'key=%s\n' "$key"
    printf 'question=%s\n' "$question"
    printf 'agent=%s\n' "$agent"
    printf 'agent_kind=%s\n' "$agent_kind"
    printf 'repo=%s\n' "$repo"
    printf 'opened_at=%s\n' "$opened_at"
    printf 'opened=%s\n' "$opened"
    printf 'wait=%s\n' "$wait"
    printf 'deadline=%s\n' "$(( opened_at + wait ))"
    printf 'state=%s\n' "$state"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$tmp" || { rm -f "$tmp"; fail "cannot write the ask record for $key"; }
  mv "$tmp" "$path" || { rm -f "$tmp"; fail "cannot publish the ask record for $key"; }
}

command_open() {
  local key=${1:-} question='' agent='' repo='' wait_arg=''
  [ -n "$key" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --question) shift; question=${1:-} ;;
      --agent) shift; agent=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --wait) shift; wait_arg=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  require_slug key "$key"
  require_one_line question "$question"
  require_one_line agent "$agent"
  if [ -n "$repo" ]; then
    require_one_line repo "$repo"
  fi
  require_home_owner
  require_slug agent "$agent"
  local agent_kind=task
  if [ "$agent" = main ]; then
    agent_kind=session
  else
    [ -f "$STATE/$agent.meta" ] \
      || fail "--agent $agent is not a task recorded in this home"
    if [ -z "$repo" ]; then
      repo=$(field_of "$STATE/$agent.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
  fi
  [ -n "$repo" ] || repo=firstmate
  local wait opened_at opened path
  wait=$(resolve_wait "$wait_arg")
  opened_at=$(now_epoch)
  opened=$(date -u -d "@$opened_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  path=$(ask_path "$key")
  if [ -e "$path" ]; then
    local state
    state=$(field_of "$path" state)
    case "$state" in
      resolved) : ;;
      *) fail "ask $key is already recorded and $state; resolve it before opening a new one" ;;
    esac
  fi
  write_record "$path" "$key" "$question" "$agent" "$agent_kind" "$repo" "$wait" "$opened_at" "$opened" open
  printf '%s\n' "$key"
}

# The release text a task agent receives. It states what happened, that it is
# not the answer, and where the answer will arrive, so a released worker never
# reads a park as a decision.
release_text() {  # <key> <row>
  printf '%s' "released: ask $1 is parked as queue row $2; stop holding the question. This is not the answer - the answer will reach you as a steer once row $2 is answered."
}

command_park() {
  local now_arg='' dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) shift; now_arg=${1:-} ;;
      --dry-run) dry_run=1 ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  if [ -n "$now_arg" ]; then
    case "$now_arg" in
      ''|*[!0-9]*) fail "--now must be an epoch second: $now_arg" ;;
    esac
    FM_ASK_NOW=$now_arg
  fi
  [ -d "$ASKS" ] || return 0
  local now
  now=$(now_epoch)
  if [ "$dry_run" -eq 0 ]; then
    require_home_owner
    require_tasks_axi
    fm_lock_acquire_wait_bounded "$PARK_LOCK" 5 \
      || fail 'another sweep holds the ask park lock; nothing was changed'
    trap 'fm_lock_release "$PARK_LOCK"' EXIT
  fi
  local rec key state question agent agent_kind repo wait opened_at opened deadline row release show row_state
  for rec in "$ASKS"/*.ask; do
    [ -e "$rec" ] || continue
    key=$(field_of "$rec" key)
    [ -n "$key" ] || continue
    state=$(field_of "$rec" state)
    question=$(field_of "$rec" question)
    agent=$(field_of "$rec" agent)
    agent_kind=$(field_of "$rec" agent_kind)
    repo=$(field_of "$rec" repo)
    wait=$(field_of "$rec" wait)
    opened_at=$(field_of "$rec" opened_at)
    opened=$(field_of "$rec" opened)
    case "$state" in
      open) ;;
      parked)
        # Retire an ask whose row has closed, so the ledger matches the row it
        # became. A row that no longer exists at all retires the same way: the
        # question is no longer owed a queue row.
        command -v tasks-axi >/dev/null 2>&1 || continue
        row=$(field_of "$rec" row)
        row_state=gone
        if show=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$row" --full 2>/dev/null); then
          row_state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
        fi
        case "$row_state" in
          done|gone)
            if [ "$dry_run" -eq 1 ]; then
              printf 'would resolve: %s row %s is %s\n' "$key" "$row" "$row_state"
              continue
            fi
            write_record "$rec" "$key" "$question" "$agent" "$agent_kind" "$repo" "$wait" "$opened_at" "$opened" resolved \
              "row=$row" \
              "parked_at=$(field_of "$rec" parked_at)" \
              "release=$(field_of "$rec" release)" \
              "resolved_at=$now" \
              "resolved_by=its queue row is $row_state"
            printf 'resolved: %s (row %s is %s)\n' "$key" "$row" "$row_state"
            ;;
        esac
        continue
        ;;
      *) continue ;;
    esac
    [ -n "$wait" ] || fail "ask $key records no wait; its record is corrupt"
    deadline=$(( opened_at + wait ))
    [ "$now" -ge "$deadline" ] || continue
    if [ "$dry_run" -eq 1 ]; then
      printf 'would park: %s -> row %s, releasing %s\n' "$key" "$key" "$agent"
      continue
    fi
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$key" --title "$question" \
      --reason "the ask $key is parked: $agent waits for this answer and is released from holding" \
      --repo "$repo" >/dev/null \
      || fail "could not file the queue row for ask $key; nothing was parked"
    release=none
    if [ "$agent_kind" = session ]; then
      release="session - the question left the turn for queue row $key"
    else
      local rec_path
      rec_path=$(fm_task_inbox_write_idempotent "$STATE" "$agent" "$(release_text "$key" "$key")") \
        || fail "the queue row $key was filed but the release for $agent could not be recorded"
      release="inbox ${rec_path#"$STATE/$agent.inbox/"}"
    fi
    write_record "$rec" "$key" "$question" "$agent" "$agent_kind" "$repo" "$wait" "$opened_at" "$opened" parked \
      "row=$key" \
      "parked_at=$now" \
      "release=$release"
    printf 'parked: %s -> row %s, released %s\n' "$key" "$key" "$agent"
  done
}

command_list() {
  local rec key state question agent agent_kind wait opened_at deadline release row now
  local open_count=0 parked_count=0 resolved_count=0
  now=$(now_epoch)
  printf 'fm-ask - questions waiting on the captain'\''s presence\n'
  printf 'home     %s\n' "$FM_HOME"
  if [ -d "$ASKS" ]; then
    for rec in "$ASKS"/*.ask; do
      [ -e "$rec" ] || continue
      case "$(field_of "$rec" state)" in
        open) open_count=$(( open_count + 1 )) ;;
        parked) parked_count=$(( parked_count + 1 )) ;;
        resolved) resolved_count=$(( resolved_count + 1 )) ;;
      esac
    done
  fi
  printf 'waiting  %s open, %s parked, %s resolved\n' "$open_count" "$parked_count" "$resolved_count"
  [ "$open_count" -gt 0 ] || [ "$parked_count" -gt 0 ] || return 0
  if [ "$open_count" -gt 0 ]; then
    printf -- '--- open ---\n'
    for rec in "$ASKS"/*.ask; do
      [ -e "$rec" ] || continue
      [ "$(field_of "$rec" state)" = open ] || continue
      key=$(field_of "$rec" key)
      question=$(field_of "$rec" question)
      agent=$(field_of "$rec" agent)
      wait=$(field_of "$rec" wait)
      opened_at=$(field_of "$rec" opened_at)
      deadline=$(( opened_at + wait ))
      printf '  %s  agent %s  %ss of %ss\n      %s\n' \
        "$key" "$agent" "$(( now - opened_at ))" "$wait" "$question"
      [ "$now" -lt "$deadline" ] || printf '      past its wait: park files it\n'
    done
  fi
  if [ "$parked_count" -gt 0 ]; then
    printf -- '--- parked ---\n'
    for rec in "$ASKS"/*.ask; do
      [ -e "$rec" ] || continue
      [ "$(field_of "$rec" state)" = parked ] || continue
      key=$(field_of "$rec" key)
      question=$(field_of "$rec" question)
      agent=$(field_of "$rec" agent)
      agent_kind=$(field_of "$rec" agent_kind)
      row=$(field_of "$rec" row)
      release=$(field_of "$rec" release)
      printf '  %s  row %s  agent %s (%s)  release %s\n      %s\n' \
        "$key" "$row" "$agent" "$agent_kind" "$release" "$question"
    done
  fi
}

command_resolve() {
  local key=${1:-} reason=''
  [ -n "$key" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  require_slug key "$key"
  require_one_line reason "$reason"
  local path state question agent agent_kind repo wait opened_at opened now extra=()
  path=$(ask_path "$key")
  [ -f "$path" ] || fail "no ask $key is recorded in $FM_HOME"
  state=$(field_of "$path" state)
  [ "$state" != resolved ] || fail "ask $key is already resolved"
  require_home_owner
  question=$(field_of "$path" question)
  agent=$(field_of "$path" agent)
  agent_kind=$(field_of "$path" agent_kind)
  repo=$(field_of "$path" repo)
  wait=$(field_of "$path" wait)
  opened_at=$(field_of "$path" opened_at)
  opened=$(field_of "$path" opened)
  now=$(now_epoch)
  if [ "$state" = parked ]; then
    extra+=("row=$(field_of "$path" row)" "parked_at=$(field_of "$path" parked_at)" "release=$(field_of "$path" release)")
  fi
  write_record "$path" "$key" "$question" "$agent" "$agent_kind" "$repo" "$wait" "$opened_at" "$opened" resolved \
    ${extra[@]+"${extra[@]}"} \
    "resolved_at=$now" \
    "resolved_by=$reason"
  printf 'resolved: %s\n' "$key"
}

VERB=${1:-}
[ -n "$VERB" ] || { usage; exit 2; }
shift || true
case "$VERB" in
  open) command_open "$@" ;;
  park) command_park "$@" ;;
  list) command_list "$@" ;;
  resolve) command_resolve "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
