#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh's guarded local-only landing.
# Uses real disk-backed git repositories and linked worktrees to prove explicit
# nondefault targets, the legacy default path, and mutation-free refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

make_case() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  fm_git_init_commit "$dir/project"
  git -C "$dir/project" worktree add -q -b gsg-sim "$dir/target" main
  git -C "$dir/project" worktree add -q -b fm/task-x1 "$dir/task" main
  printf '%s\n' "$name" > "$dir/task/change.txt"
  git -C "$dir/task" add change.txt
  git -C "$dir/task" commit -qm "task change for $name"
  fm_write_meta "$dir/home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$dir/task" "project=$dir/project" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=fixture-task-x1"
  chmod 0600 "$dir/home/state/task-x1.meta"
  touch "$dir/home/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

run_merge() {  # <case-dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$MERGE_LOCAL" task-x1 "$@"
}

assert_branch_unchanged() {  # <repo> <branch> <before> <message>
  local after
  after=$(git -C "$1" rev-parse "$2") || fail "$4: branch disappeared"
  [ "$after" = "$3" ] || fail "$4: $2 moved from $3 to $after"
}

assert_no_target_provenance() {  # <meta> <message>
  assert_no_grep 'local_target_branch=' "$1" "$2: branch provenance was recorded"
  assert_no_grep 'local_target_worktree=' "$1" "$2: worktree provenance was recorded"
}

test_explicit_nondefault_linked_target_lands_without_moving_main() {
  local dir main_before task_head out
  dir=$(make_case explicit-success)
  main_before=$(git -C "$dir/project" rev-parse main)
  task_head=$(git -C "$dir/task" rev-parse HEAD)

  out=$(run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target") \
    || fail "explicit nondefault landing failed: $out"

  [ "$(git -C "$dir/target" rev-parse HEAD)" = "$task_head" ] \
    || fail "explicit landing did not fast-forward gsg-sim to the exact task commit"
  assert_branch_unchanged "$dir/project" main "$main_before" \
    "explicit nondefault landing"
  assert_grep 'local_target_branch=gsg-sim' "$dir/home/state/task-x1.meta" \
    "explicit landing did not record its target branch"
  assert_grep "local_target_worktree=$dir/target" "$dir/home/state/task-x1.meta" \
    "explicit landing did not record its target linked copy"
  assert_contains "$out" "merged fm/task-x1 into local gsg-sim" \
    "explicit landing output did not attribute the selected branch"
  pass "fm-merge-local: approved nondefault linked target lands while main stays unchanged"
}

test_default_path_still_lands_on_main() {
  local dir before task_head
  dir=$(make_case default-success)
  before=$(git -C "$dir/project" rev-parse main)
  task_head=$(git -C "$dir/task" rev-parse HEAD)

  run_merge "$dir" >/dev/null || fail "default local landing failed"

  [ "$(git -C "$dir/project" rev-parse main)" = "$task_head" ] \
    || fail "default landing did not fast-forward main to the task commit"
  [ "$before" != "$task_head" ] || fail "default fixture did not advance beyond main"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "default landing"
  pass "fm-merge-local: omitted target preserves the guarded default-branch path"
}

# An unselected default attempt must stay unselected: pinning it would refuse
# the operator's later explicit choice until the record was hand-edited.
test_unselected_default_attempt_does_not_pin_a_later_explicit_target() {
  local dir task_head out
  dir=$(make_case default-then-explicit)
  task_head=$(git -C "$dir/task" rev-parse HEAD)

  run_merge "$dir" >/dev/null || fail "default local landing failed"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "default attempt"

  out=$(run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target") \
    || fail "an explicit target after an unselected default attempt was refused: $out"

  [ "$(git -C "$dir/target" rev-parse HEAD)" = "$task_head" ] \
    || fail "the explicit retry did not land on the selected target"
  assert_grep 'local_target_branch=gsg-sim' "$dir/home/state/task-x1.meta" \
    "the explicit retry did not record its selection"
  pass "fm-merge-local: an unselected default attempt leaves a later explicit target selectable"
}

test_empty_target_options_refuse_instead_of_defaulting() {
  local dir main_before rc=0
  dir=$(make_case empty-target)
  main_before=$(git -C "$dir/project" rev-parse main)

  run_merge "$dir" --target-branch "" --target-worktree "" \
    > "$dir/out" 2> "$dir/err" || rc=$?

  [ "$rc" -eq 2 ] || fail "empty target options returned $rc instead of a usage refusal"
  assert_branch_unchanged "$dir/project" main "$main_before" "empty target refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "empty target refusal"
  assert_grep 'requires a single non-empty value' "$dir/err" \
    "empty target refusal was not explained"
  pass "fm-merge-local: empty target options refuse rather than silently landing on main"
}

# The landing target is chosen at intake and recorded on the task, so the
# ordinary merge call carries no options at all and must still land there.
test_recorded_target_is_honored_when_options_are_omitted() {
  local dir main_before task_head out
  dir=$(make_case recorded-target)
  printf 'local_target_branch=gsg-sim\nlocal_target_worktree=%s\n' "$dir/target" \
    >> "$dir/home/state/task-x1.meta"
  main_before=$(git -C "$dir/project" rev-parse main)
  task_head=$(git -C "$dir/task" rev-parse HEAD)

  out=$(run_merge "$dir") || fail "recorded-target landing without options failed: $out"

  [ "$(git -C "$dir/target" rev-parse HEAD)" = "$task_head" ] \
    || fail "an omitted-option merge did not land on the recorded target"
  assert_branch_unchanged "$dir/project" main "$main_before" \
    "recorded-target landing without options"
  assert_contains "$out" "merged fm/task-x1 into local gsg-sim" \
    "the landing did not attribute the recorded branch"
  pass "fm-merge-local: an omitted target honors the selection recorded at intake"
}

test_option_contradicting_the_recorded_target_refuses() {
  local dir main_before target_before rc=0
  dir=$(make_case contradicting-target)
  printf 'local_target_branch=gsg-sim\nlocal_target_worktree=%s\n' "$dir/target" \
    >> "$dir/home/state/task-x1.meta"
  main_before=$(git -C "$dir/project" rev-parse main)
  target_before=$(git -C "$dir/target" rev-parse gsg-sim)

  run_merge "$dir" --target-branch main --target-worktree "$dir/project" \
    > "$dir/out" 2> "$dir/err" || rc=$?

  [ "$rc" -ne 0 ] || fail "a target contradicting the recorded selection was accepted"
  assert_branch_unchanged "$dir/project" main "$main_before" "contradicting target refusal"
  assert_branch_unchanged "$dir/project" gsg-sim "$target_before" "contradicting target refusal"
  assert_grep 'refusing a different target' "$dir/err" \
    "the refusal did not name the recorded selection as authoritative"
  pass "fm-merge-local: an option contradicting the recorded target refuses"
}

test_dirty_target_refuses_without_mutation() {
  local dir before rc=0
  dir=$(make_case dirty-target)
  before=$(git -C "$dir/target" rev-parse gsg-sim)
  printf 'dirty\n' > "$dir/target/untracked.txt"

  run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target" \
    > "$dir/out" 2> "$dir/err" || rc=$?

  [ "$rc" -ne 0 ] || fail "dirty target was accepted"
  assert_branch_unchanged "$dir/project" gsg-sim "$before" "dirty target refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "dirty target refusal"
  assert_grep 'dirty working tree' "$dir/err" "dirty target refusal was not explained"
  pass "fm-merge-local: dirty target refuses with no branch or metadata mutation"
}

test_diverged_target_refuses_without_mutation() {
  local dir before rc=0
  dir=$(make_case diverged-target)
  printf 'target only\n' > "$dir/target/target.txt"
  git -C "$dir/target" add target.txt
  git -C "$dir/target" commit -qm 'diverge target'
  before=$(git -C "$dir/target" rev-parse gsg-sim)

  run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target" \
    > "$dir/out" 2> "$dir/err" || rc=$?

  [ "$rc" -ne 0 ] || fail "diverged target was accepted"
  assert_branch_unchanged "$dir/project" gsg-sim "$before" "diverged target refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "diverged target refusal"
  assert_grep 'not a fast-forward of gsg-sim' "$dir/err" \
    "diverged target refusal did not name the fast-forward requirement"
  pass "fm-merge-local: diverged target refuses with no mutation"
}

test_wrong_repository_and_wrong_branch_refuse_without_mutation() {
  local dir other wrong_before target_before rc=0
  dir=$(make_case wrong-identities)
  other="$dir/other"
  fm_git_init_commit "$other"
  wrong_before=$(git -C "$other" rev-parse main)

  run_merge "$dir" --target-branch main --target-worktree "$other" \
    > "$dir/wrong-repo.out" 2> "$dir/wrong-repo.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unrelated repository target was accepted"
  assert_branch_unchanged "$other" main "$wrong_before" "wrong repository refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "wrong repository refusal"
  assert_grep 'not a linked copy' "$dir/wrong-repo.err" \
    "wrong repository refusal did not identify repository linkage"

  git -C "$dir/target" checkout -q -b another-target
  target_before=$(git -C "$dir/target" rev-parse another-target)
  rc=0
  run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target" \
    > "$dir/wrong-branch.out" 2> "$dir/wrong-branch.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "target checked out on the wrong branch was accepted"
  assert_branch_unchanged "$dir/project" another-target "$target_before" \
    "wrong target branch refusal"
  assert_branch_unchanged "$dir/project" gsg-sim "$target_before" \
    "wrong target branch refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "wrong target branch refusal"
  assert_grep "expected local target branch 'gsg-sim'" "$dir/wrong-branch.err" \
    "wrong branch refusal did not identify the checkout mismatch"
  pass "fm-merge-local: unrelated repositories and mismatched target branches refuse"
}

test_ambiguous_target_and_task_branch_identity_refuse() {
  local dir target_before main_before rc=0
  dir=$(make_case ambiguous-target)
  target_before=$(git -C "$dir/target" rev-parse gsg-sim)

  run_merge "$dir" --target-branch gsg-sim > "$dir/partial.out" 2> "$dir/partial.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "partial target returned $rc instead of usage refusal"
  assert_branch_unchanged "$dir/project" gsg-sim "$target_before" "partial target refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "partial target refusal"

  git -C "$dir/task" checkout -q -b unrelated-task-branch
  main_before=$(git -C "$dir/project" rev-parse main)
  rc=0
  run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target" \
    > "$dir/task-identity.out" 2> "$dir/task-identity.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "task worktree on the wrong branch was accepted"
  assert_branch_unchanged "$dir/project" main "$main_before" "task identity refusal"
  assert_branch_unchanged "$dir/project" gsg-sim "$target_before" "task identity refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" "task identity refusal"
  assert_grep "expected 'fm/task-x1'" "$dir/task-identity.err" \
    "task identity refusal did not name the expected task branch"
  pass "fm-merge-local: partial targets and changed task branch identity refuse"
}

test_captain_held_explicit_target_refuses_without_mutation() {
  local dir target_before rc=0
  dir=$(make_case held-target)
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$dir/home/data/backlog.md"
  tasks-axi add task-x1 'held local target fixture' --kind ship \
    --repo sample --start --file "$dir/home/data/backlog.md" >/dev/null \
    || fail "could not create held local target fixture"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 \
    --reason 'captain local merge approval pending' >/dev/null \
    || fail "could not hold explicit local target fixture"
  target_before=$(git -C "$dir/target" rev-parse gsg-sim)

  run_merge "$dir" --target-branch gsg-sim --target-worktree "$dir/target" \
    > "$dir/out" 2> "$dir/err" || rc=$?

  [ "$rc" -ne 0 ] || fail "captain-held explicit target was accepted"
  assert_branch_unchanged "$dir/project" gsg-sim "$target_before" \
    "captain-held target refusal"
  assert_no_target_provenance "$dir/home/state/task-x1.meta" \
    "captain-held target refusal"
  assert_grep 'still held for the captain' "$dir/err" \
    "held target refusal did not name the authority boundary"
  pass "fm-merge-local: captain-held explicit target refuses before mutation"
}

test_explicit_nondefault_linked_target_lands_without_moving_main
test_default_path_still_lands_on_main
test_unselected_default_attempt_does_not_pin_a_later_explicit_target
test_empty_target_options_refuse_instead_of_defaulting
test_recorded_target_is_honored_when_options_are_omitted
test_option_contradicting_the_recorded_target_refuses
test_dirty_target_refuses_without_mutation
test_diverged_target_refuses_without_mutation
test_wrong_repository_and_wrong_branch_refuse_without_mutation
test_ambiguous_target_and_task_branch_identity_refuse
test_captain_held_explicit_target_refuses_without_mutation
