#!/usr/bin/env bash
# Behavior tests for the acceptance record: the `## Acceptance record` a ship or
# scout brief carries before dispatch (bin/fm-dod-lib.sh owns its grammar).
#
# The record exists because an overnight request was reported as "captured and
# assigned" while the only part that would have changed the captain's screen was
# gated on a screenshot that never arrived, and the part that did ship absorbed
# the label: the brief delivered a Chat/Design-Panel split while the captain had
# asked for a Component Box Detail layout. These tests drive the promises the
# record makes at dispatch - a brief without it is refused, a request whose
# evidence gate is unmet is refused as a captain question rather than queued
# work, and accepted work is approved for its recorded scope.
# The completion half of the same contract (cleanup never closes a row whose
# recorded gate is unmet) is covered beside its owner in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-acceptance-record)

# The captain's own words from the retro report's counterexample: he asked to
# accept the Component Box Detail layout, and the shipped Chat/Design-Panel 50/50
# split was a subset of that, not the thing he had asked to accept.
COMPONENT_ASK='I wanted the Component Box Detail View to match the layout I asked for'
COMPONENT_PROOF='the staging URL at 1440x1000 on the deployed revision'
COMPONENT_GATE='Pilot Component-detail screenshot'

record() {  # <accept-when> <proof> <gate>
  printf '## Acceptance record\nAccept when: %s\nProof: %s\nEvidence gate: %s\n' "$1" "$2" "$3"
}

write_brief() {  # <file> [<record-line>...]
  local file=$1
  shift
  mkdir -p "$(dirname "$file")"
  {
    printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nBuild it.\n\n' "$COMPONENT_ASK"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$file"
}

# A spawn world: an isolated project worktree, the shared spawn fakebin (fake
# tmux records the launch command), and a home pinned to the codex harness.
make_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# The launch log is the observable side of a dispatch: a refusal must leave it
# untouched, and a launch must carry the brief. A relaunch reuses the task's
# recorded delivery contract, so it passes no mode flags.
LAUNCH_LOG=
run_spawn() {  # <id> [extra args...]
  local id=$1
  shift
  local -a args=("$id")
  if [ "${1:-}" = --relaunch ]; then
    args+=("$@")
  else
    args+=("$PROJ_DIR" "$@" --mode local-only --yolo off)
  fi
  LAUNCH_LOG="$CASE_DIR/$id.launch.log"
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${args[@]}"
}

# The dispatch gate: a request scoped after this shipped carries the record, so a
# brief without one cannot start work at all. Refusal must say what to record and
# must happen before any endpoint or task record exists.
test_dispatch_without_a_record_is_refused() {
  local rec id out status
  rec=$(make_case no-record)
  read_case "$rec"
  id=no-record-task
  write_brief "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "a brief with no acceptance record must be refused"
  assert_contains "$out" "has no ## Acceptance record subsection" \
    "the refusal did not name the missing record"
  assert_contains "$out" "what the captain will accept" \
    "the refusal did not say what to record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused dispatch still launched a worker"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused dispatch published task metadata"
  pass "fm-spawn: a brief without an acceptance record is refused before dispatch"
}

# The same gate on a record that was scaffolded and left half-filled, so a
# placeholder can never be dispatched as if it recorded a decision.
test_half_filled_and_malformed_records_are_refused() {
  local rec id out status
  rec=$(make_case half-filled)
  read_case "$rec"

  id=half-filled-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    '## Acceptance record' "Accept when: $COMPONENT_ASK" 'Proof:' 'Evidence gate: NONE'
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "an empty Proof field must be refused"
  assert_contains "$out" "left Proof: unfilled" "the refusal did not name the unfilled field"

  id=unfilled-placeholder-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    '## Acceptance record' 'Accept when: {ACCEPT_WHEN}' 'Proof: {ACCEPT_PROOF}' 'Evidence gate: {ACCEPT_GATE}'
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "an unfilled scaffolded record must be refused"
  assert_contains "$out" "still contains" "the refusal did not report the leftover placeholders"

  id=malformed-gate-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    '## Acceptance record' "Accept when: $COMPONENT_ASK" "Proof: $COMPONENT_PROOF" 'Evidence gate: maybe later'
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "an unrecognized gate value must be refused rather than read as free text"
  assert_contains "$out" "none of NONE, MET <artifact>, or UNMET <artifact>" \
    "the refusal did not state the closed gate set"
  [ ! -e "$HOME_DIR/state/half-filled-task.meta" ] \
    || fail "a half-filled record was dispatched anyway"
  pass "fm-spawn: half-filled and malformed acceptance records are refused"
}

# A complete record permits dispatch: the gate must never block accepted work.
test_complete_record_dispatches() {
  local rec id out status
  rec=$(make_case complete)
  read_case "$rec"
  id=complete-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    "$(record "$COMPONENT_ASK" "$COMPONENT_PROOF" NONE)"
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 0 "$status" "a complete acceptance record must dispatch: $out"
  assert_contains "$out" "spawned $id" "the spawn did not report success"
  assert_present "$HOME_DIR/state/$id.meta" "a dispatched task published no metadata"
  pass "fm-spawn: a brief carrying a complete acceptance record launches"
}

# The counterexample itself: the gate is unmet, so the request is a captain
# question held for the captain, never queued work. The refusal must name the
# exact hold command, so the request cannot be filed and forgotten while the
# recorded outcome is unreachable.
test_unmet_gate_is_held_not_dispatched() {
  local rec id out status
  rec=$(make_case unmet-gate)
  read_case "$rec"
  id=component-detail-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    "$(record "$COMPONENT_ASK" "$COMPONENT_PROOF" "UNMET $COMPONENT_GATE")"
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "an unmet evidence gate must refuse dispatch"
  assert_contains "$out" "$COMPONENT_GATE" "the refusal did not name the artifact the request waits on"
  assert_contains "$out" "bin/fm-captain-hold.sh hold $id" \
    "the refusal did not name the hold command that parks it as a held decision"
  assert_contains "$out" "captain question, not queued work" \
    "the refusal did not distinguish a held decision from queued work"
  [ ! -s "$LAUNCH_LOG" ] || fail "a held request was dispatched anyway"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a held request was dispatched anyway"

  # MET names the artifact that did arrive, and dispatches.
  id=component-detail-ready-task
  write_brief "$HOME_DIR/data/$id/brief.md" \
    "$(record "$COMPONENT_ASK" "$COMPONENT_PROOF" "MET $COMPONENT_GATE")"
  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 0 "$status" "a met evidence gate must dispatch: $out"
  pass "fm-spawn: an unmet evidence gate is held for the captain instead of dispatched"
}

# A legacy brief predating the record must never strand a relaunch, which
# continues work the captain already accepted; a fresh dispatch of that same
# brief still refuses, so the tolerance cannot open new work.
test_legacy_brief_relaunches_but_never_dispatches_fresh() {
  local rec id out status
  rec=$(make_case legacy)
  read_case "$rec"
  id=legacy-task
  write_brief "$HOME_DIR/data/$id/brief.md"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" \
    "project=$PROJ_DIR" "kind=ship" "mode=local-only" "spawn_gen=legacy-record-test"

  out=$(run_spawn "$id" 2>&1); status=$?
  expect_code 1 "$status" "a fresh dispatch of a record-less brief must refuse"
  assert_contains "$out" "has no ## Acceptance record subsection" \
    "a fresh dispatch of a record-less brief was refused for the wrong reason"

  # A relaunch is the relief path for legacy work, and its own endpoint gate runs
  # before the brief contract, so the observable proof here is that the record is
  # NOT what refused it: the run reaches the endpoint check it would hit anyway.
  out=$(run_spawn "$id" --relaunch 2>&1); status=$?
  expect_code 1 "$status" "relaunching a task with no live endpoint must fail"
  case "$out" in
    *"has no ## Acceptance record subsection"*)
      fail "a relaunch of legacy work was refused on the record, stranding already-accepted work" ;;
  esac
  assert_contains "$out" "recorded endpoint" \
    "the relaunch did not proceed past the record gate to its own endpoint checks"
  pass "fm-spawn: a record-less brief still refuses a fresh dispatch and is never what strands a relaunch"
}

# The scaffold is where the record is authored, so the placeholders it writes
# must be exactly the ones the validator reads: otherwise the documented fill
# would produce a brief that can never dispatch.
test_scaffold_placeholders_match_the_validator() {
  local home id brief content out kind
  home="$TMP_ROOT/scaffold-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="scaffold-$kind-task"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$BRIEF" "$id" some-proj --scout >/dev/null 2>&1 || fail "scout scaffold failed"
    else
      FM_HOME="$home" "$BRIEF" "$id" some-proj --mode local-only >/dev/null 2>&1 || fail "ship scaffold failed"
    fi
    brief="$home/data/$id/brief.md"
    assert_grep '## Acceptance record' "$brief" "the $kind scaffold wrote no acceptance record section"
    content=$(cat "$brief")
    content=${content//'{TASK}'/"$COMPONENT_ASK"}
    content=${content//'{FIRSTMATE_SPEC}'/Build it.}
    content=${content//'{ACCEPT_WHEN}'/"$COMPONENT_ASK"}
    content=${content//'{ACCEPT_PROOF}'/"$COMPONENT_PROOF"}
    content=${content//'{ACCEPT_GATE}'/NONE}
    printf '%s\n' "$content" > "$brief"
    out=$(
      # shellcheck source=bin/fm-dod-lib.sh
      . "$ROOT/bin/fm-dod-lib.sh"
      fm_acceptance_record_validate "$brief" && printf 'dispatchable\n'
    ) || true
    assert_contains "$out" "dispatchable" \
      "a $kind scaffold filled with its own documented placeholders was not dispatchable"
  done
  pass "fm-brief: the scaffolded record is exactly what the dispatch validator reads"
}

# Promotion authorizes a real build for the scope the scout was accepted for, so
# an unmet gate refuses it, and the recorded scope travels into the ship
# instructions unchanged - the same accepted scope needs no second approval.
test_promotion_gates_and_carries_the_record() {
  local rec id out status
  rec=$(make_case promotion)
  read_case "$rec"
  id=promoted-task
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" \
    "project=$PROJ_DIR" "kind=scout" "spawn_gen=promote-record-test"
  write_brief "$HOME_DIR/data/$id/brief.md" \
    "$(record "$COMPONENT_ASK" "$COMPONENT_PROOF" "UNMET $COMPONENT_GATE")"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$PROMOTE" "$id" --mode local-only --yolo off 2>&1); status=$?
  expect_code 1 "$status" "promotion on an unmet evidence gate must refuse"
  assert_contains "$out" "$COMPONENT_GATE" "the promotion refusal did not name the outstanding artifact"
  grep -qx 'kind=scout' "$HOME_DIR/state/$id.meta" \
    || fail "a refused promotion still flipped the task to a ship task"

  # With the gate met, the same recorded scope promotes without a new record.
  write_brief "$HOME_DIR/data/$id/brief.md" \
    "$(record "$COMPONENT_ASK" "$COMPONENT_PROOF" "MET $COMPONENT_GATE")"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$PROMOTE" "$id" --mode local-only --yolo off 2>&1); status=$?
  expect_code 0 "$status" "promotion with a dispatchable record must succeed: $out"
  assert_grep "$COMPONENT_ASK" "$HOME_DIR/data/$id/ship-instructions.md" \
    "the promoted ship instructions dropped the recorded scope"
  assert_grep "$COMPONENT_GATE" "$HOME_DIR/data/$id/ship-instructions.md" \
    "the promoted ship instructions dropped the recorded evidence gate"
  pass "fm-promote: an unmet gate refuses promotion and a met one carries the recorded scope"
}

test_dispatch_without_a_record_is_refused
test_half_filled_and_malformed_records_are_refused
test_complete_record_dispatches
test_unmet_gate_is_held_not_dispatched
test_legacy_brief_relaunches_but_never_dispatches_fresh
test_scaffold_placeholders_match_the_validator
test_promotion_gates_and_carries_the_record

echo "# all fm-acceptance-record tests passed"
