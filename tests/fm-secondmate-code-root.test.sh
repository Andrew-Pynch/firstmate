#!/usr/bin/env bash
# tests/fm-secondmate-code-root.test.sh - the secondmate code-root seam.
#
# A persistent mate's home holds its state, data, projects, and charter, and is
# what FM_HOME points at. bin/fm-spawn.sh --code-root moves only the CHECKOUT
# its own code runs from - the directory the pane and the agent start in, which
# is also the directory a working-directory-scoped extension discovery (omp)
# reads. That is what lets a patched checkout run a persistent mate without
# writing into the home (bin/fm-farm-patch.sh owns the fleet's patched content).
#
# The contract under test:
#   - the launch root and the pane's own starting directory both become the code
#     root, while home= and worktree= keep pointing at the mate home
#   - a mate with no code root launches from its home exactly as before, and
#     records that home as its code root
#   - the override is refused for a non-secondmate, for a path that is not a
#     git worktree root, and for a checkout without the mate's own entry point
#   - a claude mate is refused a code root rather than launched into a directory
#     its workspace-trust pre-registration does not cover
#   - a relaunch keeps the recorded code root without being told again
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-code-root)
export FM_BACKEND=tmux

MAIN="$TMP_ROOT/main home"
MATE="$TMP_ROOT/mate-home"
CODE="$TMP_ROOT/code-root"
FAKEBIN=
LOG="$TMP_ROOT/tmux.log"
PANE="$TMP_ROOT/pane.txt"
MATE_ABS=
CODE_ABS=

setup() {
  mkdir -p "$MAIN/state" "$MAIN/data" "$MATE/state" "$MATE/data" "$MATE/config" \
    "$MATE/projects" "$MATE/bin"
  printf 'customer onboarding charter\n' > "$MATE/data/charter.md"
  # The shape a seeded secondmate home has: the identity marker, an instruction
  # file, and the operational directories a spawn validates.
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  printf 'mate home\n' > "$MATE/AGENTS.md"
  # A checkout that carries the mate's own entry point, which is the minimum a
  # code root must provide.
  fm_git_init_commit "$CODE"
  mkdir -p "$CODE/bin"
  printf '#!/usr/bin/env bash\nprintf "session start\\n"\n' > "$CODE/bin/fm-session-start.sh"
  chmod +x "$CODE/bin/fm-session-start.sh"
  git -C "$CODE" add bin/fm-session-start.sh
  git -C "$CODE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add entry point'
  MATE_ABS=$(cd "$MATE" && pwd -P)
  CODE_ABS=$(cd "$CODE" && pwd -P)
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  printf '❯\n' > "$PANE"
}

spawn_mate() {  # <extra arguments...>
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$MAIN" FM_FAKE_TMUX_LOG="$LOG" \
    FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" mate "$MATE" codex --secondmate "$@" 2>&1
}

test_code_root_moves_the_launch_and_the_pane() {
  local out meta
  out=$(spawn_mate --code-root "$CODE") || fail "a code-root secondmate spawn failed: $out"
  meta="$MAIN/state/mate.meta"
  assert_grep "home=$MATE_ABS" "$meta" "the mate home must stay home= with a code root in play"
  assert_grep "worktree=$MATE_ABS" "$meta" "the code root must not be recorded as the worktree"
  assert_grep "code_root=$CODE_ABS" "$meta" "the code root must be recorded for later relaunches"
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-mate -c $CODE_ABS" "$LOG" \
    "the pane must start in the code root"
  assert_grep "FM_HOME='$MATE_ABS'" "$LOG" "the launch must still point FM_HOME at the home"
  assert_grep "$MATE_ABS/data/charter.md" "$LOG" "the launch must still use the mate home's charter"
  assert_contains "$out" "runs its code from $CODE_ABS" "the spawn must say which checkout the mate runs from"
  pass "a code root moves the launch root and the pane while the home stays the home"
}

test_without_a_code_root_the_home_is_the_launch_root() {
  local meta
  spawn_mate >/dev/null || fail "a plain secondmate spawn failed"
  meta="$MAIN/state/mate.meta"
  assert_grep "home=$MATE_ABS" "$meta" "the home must stay home="
  assert_grep "code_root=$MATE_ABS" "$meta" "a mate with no code root records its home as the launch root"
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-mate -c $MATE_ABS" "$LOG" \
    "the pane must start in the home, exactly as before this seam"
  pass "without a code root the mate launches from its home and records that"
}

test_code_root_refusals() {
  local out rc plain insecure
  out=$(spawn_mate --code-root "$CODE"); : "$out"

  # Not a secondmate: a code root is meaningless for a task worktree.
  : > "$LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$MAIN" FM_FAKE_TMUX_LOG="$LOG" \
    FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" mate "$TMP_ROOT/whatever" --scout --code-root "$CODE" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a scout spawn must refuse --code-root"
  assert_contains "$out" 'applies only to --secondmate' "the refusal must name the kind it refuses"

  # A plain directory is not a checkout.
  plain="$TMP_ROOT/not-a-checkout"
  mkdir -p "$plain"
  out=$(spawn_mate --code-root "$plain") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a code root outside a git worktree must be refused: $out"
  assert_contains "$out" 'git worktree root' "the refusal must name the git requirement"

  # A checkout that cannot start a mate.
  insecure="$TMP_ROOT/incomplete-checkout"
  fm_git_init_commit "$insecure"
  out=$(spawn_mate --code-root "$insecure") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a code root without bin/fm-session-start.sh must be refused: $out"
  assert_contains "$out" 'bin/fm-session-start.sh' "the refusal must name the missing entry point"

  # A claude mate's trust pre-registration is scoped to its home, so a code root
  # would wedge it on the trust dialog rather than launch it.
  : > "$LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$MAIN" FM_FAKE_TMUX_LOG="$LOG" \
    FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" mate "$MATE" claude --secondmate --code-root "$CODE" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a claude secondmate must refuse a code root: $out"
  assert_contains "$out" 'workspace-trust pre-registration' "the refusal must name why claude cannot use one"
  pass "the code root is refused where it cannot be honoured"
}

test_relaunch_keeps_the_recorded_code_root() {
  local meta out
  spawn_mate --code-root "$CODE" >/dev/null || fail "the setup spawn failed"
  meta="$MAIN/state/mate.meta"
  : > "$LOG"
  # A relaunch with no flag must keep the mate where it was moved, rather than
  # silently returning it to its home. The fake backend reports this pane's
  # agent gone, which is the state a relaunch requires.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$MAIN" FM_FAKE_TMUX_LOG="$LOG" \
    FM_FAKE_TMUX_CAPTURE="$PANE" FM_FAKE_TMUX_WINDOW="firstmate:fm-mate" \
    FM_FAKE_TMUX_PANE_COMMAND=bash FM_FAKE_TMUX_PANE_PATH="$CODE_ABS" \
    "$ROOT/bin/fm-spawn.sh" mate --relaunch --harness codex 2>&1) || fail "the relaunch failed: $out"
  assert_grep "code_root=$CODE_ABS" "$meta" "the relaunch must keep the recorded code root"
  assert_grep "home=$MATE_ABS" "$meta" "the relaunch must keep the home"
  pass "a relaunch keeps the recorded code root without being told again"
}

setup
test_code_root_moves_the_launch_and_the_pane
test_without_a_code_root_the_home_is_the_launch_root
test_code_root_refusals
test_relaunch_keeps_the_recorded_code_root

echo "# fm-secondmate-code-root.test.sh: all assertions passed"
