#!/usr/bin/env bash
# Behavior tests for bin/fm-ask.sh: the ask record and its park path.
#
# The contract under test is the slice's acceptance line: an ask the captain
# does not answer within its wait leaves a VISIBLE queue row naming the question
# and the agent that is waiting, and the agent is RELEASED - while ask.timeout
# stays disabled, because a timeout-selected option is not the captain's answer
# and this command must never produce an answer at all.
#
# Every case drives the command through its public interface and reads the
# durable records it owns plus the owners it hands work to (the backlog row
# through bin/fm-captain-hold.sh, the release through the steering inbox).
# Nothing here asserts implementation source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$ROOT/bin/fm-ask.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ASKED='Ship the queue row that names my question and the agent waiting on it?'
OPENED_AT=1789527383
WAIT=600

make_home() {  # <name>; prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/alpha"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/worker-1.meta" \
    "window=firstmate:fm-worker-1" \
    "endpoint_task_id=worker-1" \
    "worktree=$home/projects/alpha" \
    "project=$home/projects/alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$home"
}

run_ask() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ASK" "$@"
}

# An ask opened at a known epoch, so a sweep can be judged against a deadline
# without sleeping.
open_ask() {  # <home> [<key>] [<agent>] [<wait>]
  local home=$1 key=${2:-deploy-window} agent=${3:-worker-1} wait=${4:-$WAIT}
  FM_ASK_NOW=$OPENED_AT run_ask "$home" open "$key" \
    --question "$ASKED" --agent "$agent" --wait "$wait"
}

park_at() {  # <home> <epoch> [--dry-run]
  local home=$1 at=$2
  shift 2
  FM_ASK_NOW=$at run_ask "$home" park "$@"
}

field_of() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

inbox_records() {  # <home> <agent>
  local dir="$1/state/$2.inbox"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.msg' 2>/dev/null | sort
}

# --- cases ------------------------------------------------------------------

test_open_records_the_question_the_agent_and_the_wait() {
  local home key
  home=$(make_home open-records)
  key=$(open_ask "$home") || fail "open failed"
  assert_equals "deploy-window" "$key" "open prints the key it recorded"
  local rec="$home/state/asks/deploy-window.ask"
  [ -f "$rec" ] || fail "the ask record must exist"
  assert_equals "fm-ask.v1" "$(field_of "$rec" schema)" "the record carries its schema"
  assert_equals "$ASKED" "$(field_of "$rec" question)" "the record names the question"
  assert_equals "worker-1" "$(field_of "$rec" agent)" "the record names the waiting agent"
  assert_equals "task" "$(field_of "$rec" agent_kind)" "a recorded task agent is a task waiter"
  assert_equals "$WAIT" "$(field_of "$rec" wait)" "the record carries the wait"
  assert_equals "$(( OPENED_AT + WAIT ))" "$(field_of "$rec" deadline)" "the deadline is the wait past the open"
  assert_equals "open" "$(field_of "$rec" state)" "a fresh ask is open"
  local listing
  listing=$(run_ask "$home" list) || fail "list failed"
  assert_contains "$listing" "1 open" "list counts the open ask"
  assert_contains "$listing" "deploy-window" "list names the ask"
  assert_contains "$listing" "$ASKED" "list prints the question in full"
  assert_contains "$listing" "agent worker-1" "list names the waiting agent"
  pass "open records the question, the waiting agent and the wait"
}

test_open_refuses_a_second_live_ask_on_the_same_key() {
  local home out status=0
  home=$(make_home open-refuses)
  open_ask "$home" >/dev/null || fail "first open failed"
  out=$(run_ask "$home" open deploy-window --question 'A different question' --agent worker-1 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a second live ask on the same key must be refused"
  assert_contains "$out" "already recorded" "the refusal says the ask is already recorded"
  assert_equals "$ASKED" "$(field_of "$home/state/asks/deploy-window.ask" question)" "the recorded question is untouched"
  pass "open refuses a second live ask on one key"
}

test_open_refuses_an_agent_this_home_does_not_record() {
  local home out status=0
  home=$(make_home open-unknown-agent)
  out=$(run_ask "$home" open ghost-ask --question "$ASKED" --agent ghost-worker 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an agent with no record in this home must be refused"
  assert_contains "$out" "not a task recorded in this home" "the refusal names the missing record"
  [ ! -e "$home/state/asks/ghost-ask.ask" ] || fail "a refused open must record nothing"
  assert_equals "$(printf '## In flight\n\n## Queued\n\n## Done\n')" "$(cat "$home/data/backlog.md")" "a refused open files no queue row"
  pass "open refuses an agent this home does not record"
}

test_an_ask_inside_its_wait_does_not_park() {
  local home out
  home=$(make_home inside-wait)
  open_ask "$home" >/dev/null || fail "open failed"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT - 1 ))") || fail "a sweep inside the wait must succeed"
  assert_equals "" "$out" "a sweep with nothing due prints nothing"
  assert_equals "open" "$(field_of "$home/state/asks/deploy-window.ask" state)" "the ask is still open"
  assert_not_contains "$(cat "$home/data/backlog.md")" "deploy-window" "no queue row is filed before the wait elapses"
  assert_equals "" "$(inbox_records "$home" worker-1)" "no release is delivered before the wait elapses"

  local dry
  dry=$(park_at "$home" "$(( OPENED_AT + WAIT ))" --dry-run) || fail "a dry run must succeed"
  assert_contains "$dry" "would park" "a dry run reports what it would do"
  assert_not_contains "$(cat "$home/data/backlog.md")" "deploy-window" "a dry run files no queue row"
  pass "an ask inside its wait does not park"
}

test_an_unanswered_ask_parks_and_releases_its_agent() {
  local home out rec release_text
  home=$(make_home parks)
  open_ask "$home" >/dev/null || fail "open failed"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT ))") || fail "park failed"
  assert_contains "$out" "parked: deploy-window" "the sweep reports the park"
  assert_contains "$out" "row deploy-window" "the park names the queue row it filed"
  assert_contains "$out" "released worker-1" "the park reports the released agent"

  # The queue row: it names the question, and it names the agent that waits.
  local show
  show=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" show deploy-window --full) \
    || fail "the queue row must exist"
  assert_contains "$show" "$ASKED" "the queue row names the question"
  assert_contains "$show" "worker-1 waits for this answer" "the queue row names the waiting agent"
  assert_contains "$show" "captain" "the queue row is held for the captain"

  # The question stays UNANSWERED: the row is open and the ask records no answer.
  assert_contains "$show" "state: " "the row reports its state"
  assert_not_contains "$show" "state: done" "the parked question is not answered by the park"
  rec="$home/state/asks/deploy-window.ask"
  assert_equals "parked" "$(field_of "$rec" state)" "the ask records that it parked"
  assert_equals "deploy-window" "$(field_of "$rec" row)" "the ask records the row it became"
  assert_equals "" "$(field_of "$rec" answer)" "no answer is ever recorded by a park"

  # The release: the waiting agent holds one durable record saying what happened.
  local records
  records=$(inbox_records "$home" worker-1)
  assert_equals "1" "$(printf '%s' "$records" | grep -c . )" "the waiting agent holds one release record"
  release_text=$(cat "$records")
  assert_contains "$release_text" "ask deploy-window is parked" "the release names the ask and its fate"
  assert_contains "$release_text" "This is not the answer" "the release is not passed off as the answer"
  assert_contains "$release_text" "stop holding" "the release tells the agent it is no longer held"
  pass "an unanswered ask parks and releases its agent"
}

test_parking_twice_files_nothing_new() {
  local home out show
  home=$(make_home parks-once)
  open_ask "$home" >/dev/null || fail "open failed"
  park_at "$home" "$(( OPENED_AT + WAIT ))" >/dev/null || fail "the first park failed"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT + 5000 ))") || fail "the second sweep must succeed"
  assert_equals "" "$out" "a second sweep with nothing due prints nothing"
  assert_equals "1" "$(inbox_records "$home" worker-1 | grep -c .)" "the release is written once"
  assert_equals "deploy-window" "$(field_of "$home/state/asks/deploy-window.ask" row)" "the ask still names one row"
  show=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" show deploy-window) \
    || fail "the queue row must still exist"
  assert_contains "$show" "id: deploy-window" "the row was not duplicated"
  pass "parking twice files nothing new"
}

test_a_parked_ask_retires_when_its_row_closes() {
  local home out
  home=$(make_home retires)
  open_ask "$home" >/dev/null || fail "open failed"
  park_at "$home" "$(( OPENED_AT + WAIT ))" >/dev/null || fail "park failed"
  # shellcheck disable=SC1010 # tasks-axi's verb really is `done`.
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" done deploy-window >/dev/null \
    || fail "could not close the row"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT + 60 ))") || fail "the sweep must succeed"
  assert_contains "$out" "resolved: deploy-window" "the sweep retires the ask whose row closed"
  local rec="$home/state/asks/deploy-window.ask"
  assert_equals "resolved" "$(field_of "$rec" state)" "the ask records its resolution"
  assert_contains "$(field_of "$rec" resolved_by)" "row" "the resolution names the row that closed it"
  assert_equals "deploy-window" "$(field_of "$rec" row)" "the resolution keeps the row it became"
  pass "a parked ask retires when its row closes"
}

test_a_resolved_ask_never_parks() {
  local home out
  home=$(make_home resolved)
  open_ask "$home" >/dev/null || fail "open failed"
  run_ask "$home" resolve deploy-window --reason "answered in chat" >/dev/null \
    || fail "resolve failed"
  assert_equals "resolved" "$(field_of "$home/state/asks/deploy-window.ask" state)" "resolve closes the ask"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT + 60 ))") || fail "the sweep must succeed"
  assert_equals "" "$out" "a resolved ask is never parked"
  assert_not_contains "$(cat "$home/data/backlog.md")" "deploy-window" "a resolved ask files no queue row"
  assert_equals "" "$(inbox_records "$home" worker-1)" "a resolved ask releases nothing"
  pass "a resolved ask never parks"
}

test_resolve_keeps_what_a_parked_ask_became() {
  local home out rec
  home=$(make_home resolve-parked)
  open_ask "$home" >/dev/null || fail "open failed"
  park_at "$home" "$(( OPENED_AT + WAIT ))" >/dev/null || fail "park failed"
  run_ask "$home" resolve deploy-window --reason "answered in chat" >/dev/null \
    || fail "resolve of a parked ask failed"
  rec="$home/state/asks/deploy-window.ask"
  assert_equals "resolved" "$(field_of "$rec" state)" "resolve closes a parked ask"
  assert_equals "deploy-window" "$(field_of "$rec" row)" "the resolution keeps the row it became"
  assert_equals "inbox 001.msg" "$(field_of "$rec" release)" "the resolution keeps the release it delivered"
  assert_equals "answered in chat" "$(field_of "$rec" resolved_by)" "the resolution records the reason"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT + 60 ))") || fail "the sweep must succeed"
  assert_equals "" "$out" "a resolved parked ask is swept no further"
  pass "resolve keeps what a parked ask became"
}

test_a_key_can_be_asked_again_once_it_resolves() {
  local home out
  home=$(make_home re-asked)
  open_ask "$home" >/dev/null || fail "open failed"
  run_ask "$home" resolve deploy-window --reason "answered in chat" >/dev/null || fail "resolve failed"
  out=$(open_ask "$home") || fail "the key must be askable again once resolved"
  assert_equals "deploy-window" "$out" "the re-ask records the same key"
  assert_equals "open" "$(field_of "$home/state/asks/deploy-window.ask" state)" "the re-ask is open again"
  assert_equals "" "$(field_of "$home/state/asks/deploy-window.ask" resolved_at)" \
    "the re-ask carries no earlier resolution"
  pass "a key can be asked again once it resolves"
}

test_park_refuses_while_another_live_session_owns_the_home() {
  local home copy pid status=0 out
  home=$(make_home foreign-lock)
  open_ask "$home" >/dev/null || fail "open failed"
  copy="$TMP_ROOT/fake-harness/claude"
  mkdir -p "$(dirname "$copy")"
  if ! cp /bin/sleep "$copy" 2>/dev/null; then
    echo "skip: no /bin/sleep to build a fake harness process"
    return 0
  fi
  "$copy" 300 &
  pid=$!
  echo "$pid" > "$home/state/.lock"
  out=$(park_at "$home" "$(( OPENED_AT + WAIT ))" 2>&1) || status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "park must refuse while another live session owns the home"
  assert_contains "$out" "another live session holds this home's lock" "the refusal names the owner"
  assert_equals "open" "$(field_of "$home/state/asks/deploy-window.ask" state)" "the refused sweep parked nothing"
  assert_not_contains "$(cat "$home/data/backlog.md")" "deploy-window" "the refused sweep filed no queue row"
  assert_equals "" "$(inbox_records "$home" worker-1)" "the refused sweep released nothing"
  pass "park refuses while another live session owns the home"
}

test_a_parked_ask_is_a_visible_queue_row() {
  local home snapshot rendered
  home=$(make_home visible)
  open_ask "$home" >/dev/null || fail "open failed"
  park_at "$home" "$(( OPENED_AT + WAIT ))" >/dev/null || fail "park failed"
  snapshot="$TMP_ROOT/visible-snap.json"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$snapshot" || fail "the canonical snapshot must build"
  rendered=$(FM_HOME="$home" FM_QUEUE_SNAPSHOT="$snapshot" "$ROOT/bin/fm-queue.sh") \
    || fail "the queue program must render the fixture home"
  assert_contains "$rendered" "[waiting on you] deploy-window" "the parked ask is a waiting-on-you queue row"
  assert_contains "$rendered" "$ASKED" "the row carries the question in full"
  assert_contains "$rendered" "worker-1 waits for this answer" "the row names the agent that is waiting"
  pass "a parked ask is a visible queue row"
}

test_open_records_the_question_the_agent_and_the_wait
test_open_refuses_a_second_live_ask_on_the_same_key
test_open_refuses_an_agent_this_home_does_not_record
test_an_ask_inside_its_wait_does_not_park
test_an_unanswered_ask_parks_and_releases_its_agent
test_parking_twice_files_nothing_new
test_a_parked_ask_retires_when_its_row_closes
test_a_resolved_ask_never_parks
test_resolve_keeps_what_a_parked_ask_became
test_a_key_can_be_asked_again_once_it_resolves
test_park_refuses_while_another_live_session_owns_the_home
test_a_parked_ask_is_a_visible_queue_row
