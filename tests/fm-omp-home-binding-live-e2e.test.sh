#!/usr/bin/env bash
# Opt-in credentialed omp (Oh My Pi) guard for home binding
# (docs/configuration.md "Home binding") in an isolated lab: a plain clone of
# this working tree is the shared code root, and two scratch homes sit beside
# it. It submits three short prompts through `omp -p` with the captain's
# existing login and proves, against the installed omp, what
# tests/fm-omp-harness.test.sh can only pin over a fake API:
#   1. a launch with an explicit FM_HOME records it in the session as a
#      firstmate-home custom entry and notes it served from the code root;
#   2. a resume of that session with FM_HOME unset (the shape Herdr's
#      resume_agents_on_restore produces) exports the recorded home into the
#      agent's own shell and arms fm_watch_arm_omp for that home, never the
#      code root;
#   3. a fresh launch from the same code root with no FM_HOME and no recorded
#      home is refused by fm_watch_arm_omp, naming the code root's state.
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

git clone -q "$ROOT" "$CODE" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$ROOT/$path" ] || continue
  mkdir -p "$CODE/$(dirname "$path")"
  cp "$ROOT/$path" "$CODE/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$HOME_MAIN/state" "$HOME_MAIN/data" "$SESSIONS"

run_omp() {  # <output-file> <omp args...>: from the code root, with the lab's runtime record dir
  local out=$1
  shift
  (cd "$CODE" && timeout 600 env -u FM_HOME -u FM_TASK_ID -u FM_OMP_HARNESS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME_BINDING_RUNTIME_DIR="$LAB/runtime" \
    "$@" > "$out" 2> "$out.err")
}

# 1. Explicit launch records the home.
run_omp "$LAB/run1.out" FM_HOME="$HOME_MAIN" omp -p --model "$MODEL" --session-dir "$SESSIONS" \
  "Reply with the single word ok." || fail "omp $OMP_VERSION: the explicit launch failed: $(tail -3 "$LAB/run1.out.err")"
SESSION=$(find "$SESSIONS" -maxdepth 1 -name '*.jsonl' | head -1)
[ -n "$SESSION" ] || fail "omp $OMP_VERSION: the explicit launch wrote no session file"
recorded=$(jq -r 'select(.type == "custom" and .customType == "firstmate-home") | .data.home' "$SESSION" | tail -1)
[ "$recorded" = "$HOME_MAIN" ] || fail "omp $OMP_VERSION: the session recorded home '$recorded', not $HOME_MAIN"
grep -qxF "$HOME_MAIN" "$CODE/state/.code-root-served-homes" 2>/dev/null \
  || fail "omp $OMP_VERSION: the explicit launch did not note its home as served from the code root"
pass "omp $OMP_VERSION: an explicit FM_HOME launch records its home in the session and the code root"

# 2. Resume with FM_HOME unset binds the recorded home.
run_omp "$LAB/run2.out" omp -p --model "$MODEL" --session-dir "$SESSIONS" --resume="$SESSION" \
  "Do exactly two things. First run this bash command: echo FM_HOME=\$FM_HOME. Second call the fm_watch_arm_omp tool once. Then reply with the bash output line and the tool's exact text, nothing else." \
  || fail "omp $OMP_VERSION: the resume failed: $(tail -3 "$LAB/run2.out.err")"
assert_contains "$(cat "$LAB/run2.out")" "FM_HOME=$HOME_MAIN" \
  "omp $OMP_VERSION: the resumed session's shell did not inherit the recorded home"
assert_contains "$(cat "$LAB/run2.out")" "watcher: started omp extension arm child" \
  "omp $OMP_VERSION: the resumed session did not arm the watcher"
[ "$(sed -n 2p "$HOME_MAIN/state/.omp-watch-extension-loaded" 2>/dev/null)" = "$(sed -n 1p "$HOME_MAIN/state/.lock" 2>/dev/null)" ] \
  || fail "omp $OMP_VERSION: the watch extension's marker in the recorded home does not name the session holding its lock"
assert_absent "$CODE/state/.omp-watch-extension-loaded" "omp $OMP_VERSION: the resumed session loaded the watcher against the code root"
assert_absent "$CODE/state/.lock" "omp $OMP_VERSION: the resumed session locked the code root's state"
pass "omp $OMP_VERSION: a resume with FM_HOME unset exports the recorded home and arms the watcher for it"
reap_lab

# 3. A fresh launch naming no home on the shared code root is refused.
run_omp "$LAB/run3.out" omp -p --model "$MODEL" --session-dir "$LAB/sessions-none" \
  "Call the fm_watch_arm_omp tool once, then reply with its exact text and nothing else." \
  || fail "omp $OMP_VERSION: the unbound launch failed: $(tail -3 "$LAB/run3.out.err")"
assert_contains "$(cat "$LAB/run3.out")" "watcher: not armed" "omp $OMP_VERSION: an unbound launch on a shared code root armed"
assert_contains "$(cat "$LAB/run3.out")" "$CODE/state" "omp $OMP_VERSION: the refusal did not name the code root's state"
assert_absent "$CODE/state/.lock" "omp $OMP_VERSION: the unbound launch locked the code root's state"
pass "omp $OMP_VERSION: a launch with no FM_HOME and no recorded home on a shared code root refuses to arm"
