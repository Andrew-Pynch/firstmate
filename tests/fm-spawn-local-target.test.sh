#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's local-only landing target selection.
#
# A local-only ship that must land somewhere other than the project's default
# branch has that target chosen at intake. The spawn validates the branch and
# the linked copy holding it, records both on the task before the worker exists,
# and names the concrete branch in the rendered launch brief. That one record is
# what bin/fm-merge-local.sh and bin/fm-teardown.sh later read, so the worker's
# instructions and the landing cannot disagree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-spawn-local-target)

# Echoes "<case-dir>|<home>|<project>|<task-worktree>|<target-worktree>|<fakebin>".
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt target fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  target="$case_dir/target"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" gh gh-axi no-mistakes)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" worktree add --quiet -b gsg-sim "$target" main
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task
## Captain's intent
Land $id on the chosen local branch.

## Firstmate spec
Exercise the local landing target selection.

# Definition of done
Delivery contract: mode=local-only
BRIEF
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$target" "$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR TARGET_DIR FAKEBIN_DIR <<CASE
$1
CASE
}

run_local_spawn() {  # <home> <pane> <fakebin> [spawn args...]
  local home=$1 pane=$2 fakebin=$3
  shift 3
  CLAUDE_CONFIG_DIR='' fm_test_run_spawn "$home" "$pane" "$fakebin" "$@" --mode local-only --yolo off
}

test_selected_target_is_recorded_and_named_in_the_launch_brief() {
  local rec id out rc=0
  id=spawn-local-target-t1
  rec=$(make_case selected-target "$id")
  read_case_record "$rec"

  out=$(run_local_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --local-target-branch gsg-sim --local-target-worktree "$TARGET_DIR") || rc=$?
  expect_code 0 "$rc" "local-only spawn with an approved target should succeed: $out"

  assert_grep 'local_target_branch=gsg-sim' "$HOME_DIR/state/$id.meta" \
    "spawn did not record the selected landing branch before the worker started"
  assert_grep "local_target_worktree=$TARGET_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the selected landing copy before the worker started"
  assert_grep 'Current local landing target' "$HOME_DIR/data/$id/launch-brief.md" \
    "the launch brief did not carry the local landing target section"
  assert_grep "This task lands on local branch \`gsg-sim\`, checked out in \`$TARGET_DIR\`." \
    "$HOME_DIR/data/$id/launch-brief.md" \
    "the launch brief did not name the concrete selected branch and copy"
  pass "an approved local landing target is recorded before work starts and named in the launch brief"
}

test_no_selection_records_nothing_and_keeps_the_default_contract() {
  local rec id out rc=0
  id=spawn-local-target-t2
  rec=$(make_case no-selection "$id")
  read_case_record "$rec"

  out=$(run_local_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR") || rc=$?
  expect_code 0 "$rc" "local-only spawn without a target should still succeed: $out"

  assert_no_grep 'local_target_branch=' "$HOME_DIR/state/$id.meta" \
    "an unselected task recorded a landing branch"
  assert_no_grep 'local_target_worktree=' "$HOME_DIR/state/$id.meta" \
    "an unselected task recorded a landing copy"
  assert_no_grep 'Current local landing target' "$HOME_DIR/data/$id/launch-brief.md" \
    "an unselected task was told a concrete landing target"
  pass "no selection leaves the historical default-branch contract untouched"
}

test_unrelated_repository_target_is_refused_without_a_record() {
  local rec id out rc=0
  id=spawn-local-target-t3
  rec=$(make_case unrelated-repo "$id")
  read_case_record "$rec"
  fm_git_init_commit "$CASE_DIR/other"

  out=$(run_local_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --local-target-branch main --local-target-worktree "$CASE_DIR/other") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a landing copy from an unrelated repository"
  assert_contains "$out" "is not a linked copy of" \
    "spawn did not explain the repository-linkage refusal"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused target selection still published a task record"
  pass "a landing copy outside the project's repository is refused before any record exists"
}

test_target_copy_not_on_the_named_branch_is_refused() {
  local rec id out rc=0
  id=spawn-local-target-t4
  rec=$(make_case wrong-branch "$id")
  read_case_record "$rec"
  git -C "$TARGET_DIR" checkout -q -b some-other-branch

  out=$(run_local_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --local-target-branch gsg-sim --local-target-worktree "$TARGET_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a landing copy checked out on another branch"
  assert_contains "$out" "is not checked out on 'gsg-sim'" \
    "spawn did not explain the branch-checkout refusal"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused target selection still published a task record"
  pass "a landing copy not checked out on the selected branch is refused"
}

test_partial_selection_and_wrong_mode_are_refused() {
  local rec id out rc=0
  id=spawn-local-target-t5
  rec=$(make_case partial-and-mode "$id")
  read_case_record "$rec"

  out=$(run_local_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --local-target-branch gsg-sim) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a landing branch with no landing copy"
  assert_contains "$out" "must be supplied together" \
    "spawn did not explain the incomplete selection"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "an incomplete target selection still published a task record"

  rc=0
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off \
    --local-target-branch gsg-sim --local-target-worktree "$TARGET_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a local landing target on a PR-delivered mode"
  assert_contains "$out" "apply only to --mode local-only ships" \
    "spawn did not explain why a PR mode cannot carry a landing target"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a wrong-mode target selection still published a task record"
  pass "incomplete selections and non-local-only modes are refused"
}

# Treehouse allocates task worktrees out of a project's pool, so a pool slot is
# never a stable landing target: the same spawn can be handed that very slot,
# which moves it off the landing branch. The refusal therefore has to land
# before the allocation request, while nothing has been written into the slot
# and no endpoint, launch contract, or task record exists to strand. The pane
# path here is the slot itself, standing in for the pool handing it over.
test_treehouse_pool_slot_target_is_refused_before_allocation() {
  local rec id pool slot out rc=0
  id=spawn-local-target-t6
  rec=$(make_case pool-slot-target "$id")
  read_case_record "$rec"
  pool="$CASE_DIR/pool"
  slot="$pool/slot-a/repo"
  mkdir -p "$pool"
  printf '{}\n' > "$pool/treehouse-state.json"
  git -C "$PROJ_DIR" worktree add --quiet -b pooled-gsg-sim "$slot" main

  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    run_local_spawn "$HOME_DIR" "$slot" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --local-target-branch pooled-gsg-sim --local-target-worktree "$slot") || rc=$?

  [ "$rc" -ne 0 ] || fail "spawn accepted a Treehouse pool slot as the landing target"
  assert_contains "$out" "is a Treehouse pool slot for" \
    "spawn did not explain why a pool slot cannot be a landing target"
  assert_contains "$out" "$slot" "the refusal did not name the offending copy"
  [ "$(git -C "$slot" symbolic-ref --quiet --short HEAD)" = pooled-gsg-sim ] \
    || fail "the refused spawn moved the pool slot off its landing branch"
  [ -z "$(git -C "$slot" status --porcelain)" ] \
    || fail "the refused spawn wrote into the pool slot"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record"
  assert_absent "$HOME_DIR/data/$id/launch-brief.md" \
    "the refused spawn published a launch contract"
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "the refused spawn stranded a temp root no teardown can find"; }
  [ ! -s "$CASE_DIR/launch.log" ] \
    || fail "the refused spawn launched a worker: $(cat "$CASE_DIR/launch.log")"
  pass "a Treehouse pool slot is refused as a landing target before any slot is allocated"
}

test_selected_target_is_recorded_and_named_in_the_launch_brief
test_treehouse_pool_slot_target_is_refused_before_allocation
test_no_selection_records_nothing_and_keeps_the_default_contract
test_unrelated_repository_target_is_refused_without_a_record
test_target_copy_not_on_the_named_branch_is_refused
test_partial_selection_and_wrong_mode_are_refused
