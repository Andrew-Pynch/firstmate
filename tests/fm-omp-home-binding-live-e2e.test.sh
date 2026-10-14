#!/usr/bin/env bash
# Opt-in credentialed omp (Oh My Pi) guard for home binding
# (docs/configuration.md "Home binding") in the shape Main runs on Ron: the
# home is a plain checkout of this repository, and the code root omp starts in
# is a separate LINKED worktree of that same repository. The home's session
# lock is left stale, as a reboot leaves it. It submits three short prompts
# through `omp -p` with the captain's existing login and proves, against the
# installed omp, what tests/fm-omp-harness.test.sh can only pin over a fake API:
#   1. a launch with an explicit FM_HOME records it in the session as a
#      firstmate-home custom entry, and its native session start runs for that
#      home from the linked code root (the primary scope admits it);
#   2. after the lock goes stale again, a resume of that session with FM_HOME
#      unset (the shape Herdr's resume_agents_on_restore produces) reclaims
#      the home's lock, exports the recorded home into the agent's own shell,
#      and arms fm_watch_arm_omp for that home, never the code root;
#   3. a fresh launch from the linked code root with no FM_HOME and no
#      recorded home arms nothing and touches no state.
# Run it after every omp upgrade: the custom-entry persistence, the
# session_start shell-environment refresh, and the tool surface are vendor
# behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_LIVE_E2E omp git jq

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
LAB=$(fm_test_tmproot fm-omp-home-binding-live) || fail "could not create the lab"
CODE="$LAB/code"
HOME_MAIN="$LAB/home-main"
SESSIONS="$LAB/sessions"

# Every process the lab starts names the lab path on its command line or runs
# from it, so cleanup reaps by that path rather than by a name pattern.
reap_lab() {
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do
    [ "$pid" = "$$" ] || kill -TERM "$pid" 2>/dev/null || true
  done
}
trap reap_lab EXIT

git clone -q "$ROOT" "$HOME_MAIN" || fail "could not clone the repository into the lab home"
git -C "$HOME_MAIN" worktree add -q --detach "$CODE" || fail "could not add the linked code root"
while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$ROOT/$path" ] || continue
  for dest in "$HOME_MAIN" "$CODE"; do
    mkdir -p "$dest/$(dirname "$path")"
    cp "$ROOT/$path" "$dest/$path"
  done
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$HOME_MAIN/state" "$HOME_MAIN/data" "$SESSIONS"
[ "$(git -C "$CODE" rev-parse --git-dir)" != "$(git -C "$CODE" rev-parse --git-common-dir)" ] \
  || fail "fixture: the code root is not a linked worktree"

stale_lock() {  # write a dead session pid into the home's lock, as a reboot leaves it
  local dead
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$HOME_MAIN/state/.lock"
  printf '%s\n' "$dead"
}

run_omp() {  # <output-file> <omp args...>: from the code root, with the lab's runtime record dir
  local out=$1
  shift
  (cd "$CODE" && timeout 600 env -u FM_HOME -u FM_TASK_ID -u FM_OMP_HARNESS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME_BINDING_RUNTIME_DIR="$LAB/runtime" \
    "$@" > "$out" 2> "$out.err")
}

# 1. Explicit launch from the linked code root records the home.
STALE=$(stale_lock)
run_omp "$LAB/run1.out" FM_HOME="$HOME_MAIN" omp -p --model "$MODEL" --session-dir "$SESSIONS" \
  "Reply with the single word ok." || fail "omp $OMP_VERSION: the explicit launch failed: $(tail -3 "$LAB/run1.out.err")"
SESSION=$(find "$SESSIONS" -maxdepth 1 -name '*.jsonl' | head -1)
[ -n "$SESSION" ] || fail "omp $OMP_VERSION: the explicit launch wrote no session file"
recorded=$(jq -r 'select(.type == "custom" and .customType == "firstmate-home") | .data.home' "$SESSION" | tail -1)
[ "$recorded" = "$HOME_MAIN" ] || fail "omp $OMP_VERSION: the session recorded home '$recorded', not $HOME_MAIN"
[ -f "$HOME_MAIN/state/.session-start-complete" ] && [ "$(sed -n 1p "$HOME_MAIN/state/.lock")" != "$STALE" ] \
  || fail "omp $OMP_VERSION: the native session start never took the home's stale lock from the linked code root"
pass "omp $OMP_VERSION: an explicit FM_HOME launch from a linked code root records its home and takes the home's stale lock"

# 2. Lock stale again (the reboot), then resume with FM_HOME unset.
STALE=$(stale_lock)
rm -f "$HOME_MAIN/state/.session-start-complete" "$HOME_MAIN/state/.omp-watch-extension-loaded"
run_omp "$LAB/run2.out" omp -p --model "$MODEL" --session-dir "$SESSIONS" --resume="$SESSION" \
  "Do exactly two things. First run this bash command: echo FM_HOME=\$FM_HOME. Second call the fm_watch_arm_omp tool once. Then reply with the bash output line and the tool's exact text, nothing else." \
  || fail "omp $OMP_VERSION: the resume failed: $(tail -3 "$LAB/run2.out.err")"
assert_contains "$(cat "$LAB/run2.out")" "FM_HOME=$HOME_MAIN" \
  "omp $OMP_VERSION: the resumed session's shell did not inherit the recorded home"
assert_contains "$(cat "$LAB/run2.out")" "watcher: started omp extension arm child" \
  "omp $OMP_VERSION: the resumed session did not arm the watcher"
lock_pid=$(sed -n 1p "$HOME_MAIN/state/.lock" 2>/dev/null)
[ -n "$lock_pid" ] && [ "$lock_pid" != "$STALE" ] || fail "omp $OMP_VERSION: the resume never reclaimed the home's stale lock"
[ "$(sed -n 2p "$HOME_MAIN/state/.omp-watch-extension-loaded" 2>/dev/null)" = "$lock_pid" ] \
  || fail "omp $OMP_VERSION: the watch extension's marker in the recorded home does not name the session holding its lock"
assert_absent "$CODE/state/.omp-watch-extension-loaded" "omp $OMP_VERSION: the resumed session loaded the watcher against the code root"
assert_absent "$CODE/state/.lock" "omp $OMP_VERSION: the resumed session locked the code root's state"
pass "omp $OMP_VERSION: a resume with FM_HOME unset reclaims the recorded home's stale lock, exports the home, and arms the watcher for it"
reap_lab

# 3. A fresh launch from the linked code root naming no home arms nothing.
run_omp "$LAB/run3.out" omp -p --model "$MODEL" --session-dir "$LAB/sessions-none" \
  "Call the fm_watch_arm_omp tool once, then reply with its exact text and nothing else." \
  || fail "omp $OMP_VERSION: the unbound launch failed: $(tail -3 "$LAB/run3.out.err")"
assert_contains "$(cat "$LAB/run3.out")" "watcher: not armed" "omp $OMP_VERSION: an unbound launch from the linked code root armed"
assert_absent "$CODE/state/.lock" "omp $OMP_VERSION: the unbound launch locked the code root's state"
pass "omp $OMP_VERSION: a launch with no FM_HOME and no recorded home from the linked code root arms nothing"
