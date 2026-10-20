#!/usr/bin/env bash
# Behavior tests for the --project-token flag contract on bin/fm-spawn.sh.
#
# The flag carries a task's Herdr colour token, so the spawn must refuse it
# where it cannot mean anything (a secondmate home, a relaunch that keeps its
# recorded label) and refuse a value that would split into two metadata tokens.
# These are parse-time refusals: they happen before any endpoint, worktree, or
# record exists, which is what makes them cheap to assert here without a live
# backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-label)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

spawn() { # <args...>
  # The advisory guard banner is not this test's subject; drop its report lines
  # from the captured output while preserving the spawn's own exit status.
  local status
  FM_HOME="$HOME_DIR" FM_GATE_REFUSE_BYPASS=1 "$SPAWN" "$@" >"$TMP_ROOT/spawn.out" 2>&1
  status=$?
  grep -v '^●' "$TMP_ROOT/spawn.out" || true
  return "$status"
}

expect_refusal() { # <expected-substring> <args...>
  local want=$1
  shift
  local out
  if out=$(spawn "$@"); then
    fail "spawn should have refused: $*"
  fi
  case "$out" in
  *"$want"*) ;;
  *) fail "refusal for '$*' should mention '$want', got: $out" ;;
  esac
}

expect_refusal "--project-token requires a value" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token
expect_refusal "--project-token requires a non-empty value" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token=
expect_refusal "must be one whitespace-free token" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token 'two tokens'
# A secondmate's display identity is its own home workspace, not one project.
expect_refusal "applies to a ship or scout spawn" secondmate-task --secondmate --project-token pilot
pass "the project-token flag refuses a missing, empty, split, or secondmate value"

# No spawn happened, so the home holds no task record at all.
[ -e "$HOME_DIR/state/some-task.meta" ] && fail "a refused spawn must not write a task record"
pass "a refused project-token spawn leaves no task record"

echo "ALL TESTS PASSED"
