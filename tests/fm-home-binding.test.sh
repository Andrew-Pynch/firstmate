#!/usr/bin/env bash
# tests/fm-home-binding.test.sh - behavior tests for bin/fm-home-binding-lib.sh
# (which Firstmate home a launched process serves), the session-start refusal
# and comparison lines built on it, and bin/fm-watcher-down.sh.
#
# The load-bearing contracts:
#   1. Resolution order: FM_HOME, then FM_ROOT_OVERRIDE, then the harness
#      session's recorded home, then the code root.
#   2. Several homes can share one code root: once a code root has served an
#      explicitly named home, a launch naming no home and carrying no recorded
#      home is refused, and a recorded home still binds its own home.
#   3. A linked task worktree is never noted as serving a home and stands the
#      extensions down instead of binding.
#   4. Session start refuses an ambiguous launch before it locks or digests,
#      and names both state directories when the harness serves another home.
#   5. The watcher-down banner fires only for a held lock, supervision need,
#      and a beat older than its threshold.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-binding) || fail "could not create a temp root"
LIB="$ROOT/bin/fm-home-binding-lib.sh"
export FM_HOME_BINDING_RUNTIME_DIR="$TMP_ROOT/runtime"

make_primary_root() {  # <dir>
  fm_git_init_commit "$1"
  : > "$1/AGENTS.md"
  mkdir -p "$1/bin"
}

resolve() {  # <code-root> [resolve args...]: prints status/home/source, then rc=
  local root=$1 rc
  shift
  bash "$LIB" resolve --code-root "$root" "$@" 2>&1
  rc=$?
  printf 'rc=%s\n' "$rc"
}

test_resolution_order() {
  local root="$TMP_ROOT/order/root" h1="$TMP_ROOT/order/h1" h2="$TMP_ROOT/order/h2" out
  make_primary_root "$root"
  mkdir -p "$h1" "$h2"
  out=$(FM_HOME="$h1" resolve "$root" --recorded "$h2")
  assert_contains "$out" "home=$h1"$'\n'"source=env" "an explicit FM_HOME must win over the session's recorded home"
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$h1" bash "$LIB" resolve --code-root "$root" --recorded "$h2")
  assert_contains "$out" "home=$h1"$'\n'"source=override" "FM_ROOT_OVERRIDE must win over the recorded home"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root" --recorded "$h2")
  assert_contains "$out" "home=$h2"$'\n'"source=session" "with no environment the session's recorded home must bind"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root")
  assert_contains "$out" "home=$root"$'\n'"source=code-root" "a code root that serves no other home is its own home"
  out=$(FM_HOME=relative/home resolve "$root")
  assert_contains "$out" "status=refused" "a relative FM_HOME must be refused, never replaced by a fallback"
  assert_contains "$out" "rc=4" "a refusal must exit 4"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root" --recorded "$TMP_ROOT/order/gone"; printf 'rc=%s\n' "$?")
  assert_contains "$out" "status=refused" "a recorded home that no longer exists must be refused"
  assert_contains "$out" "$TMP_ROOT/order/gone" "the refusal must name the vanished recorded home"
  pass "fm-home-binding: FM_HOME, then FM_ROOT_OVERRIDE, then the recorded home, then the code root"
}

test_two_homes_one_code_root() {
  local root="$TMP_ROOT/shared/root" h1="$TMP_ROOT/shared/h1" h2="$TMP_ROOT/shared/h2" out served
  make_primary_root "$root"
  mkdir -p "$h1" "$h2"
  # A launch that names h1 explicitly records that this code root serves it.
  out=$(FM_HOME="$h1" resolve "$root" --primary-only --record-pid "$$")
  assert_contains "$out" "source=env" "the explicit launch must bind its own home"
  served=$(bash "$LIB" served --code-root "$root")
  assert_equals "$h1" "$served" "an explicit launch on a primary code root must be noted as served"
  # A second explicit home on the same root is noted too, once.
  FM_HOME="$h2" bash "$LIB" resolve --code-root "$root" --record-pid "$$" >/dev/null
  FM_HOME="$h2" bash "$LIB" resolve --code-root "$root" --record-pid "$$" >/dev/null
  assert_equals 2 "$(grep -c . "$root/state/.code-root-served-homes")" "each served home must be recorded exactly once"
  # The resumed process with no environment and no record: refused, never the code root.
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root" --primary-only; printf 'rc=%s\n' "$?")
  assert_contains "$out" "status=refused" "a launch naming no home on a shared code root must be refused"
  assert_contains "$out" "rc=4" "the ambiguous launch must exit 4"
  assert_contains "$out" "$root/state" "the refusal must name the code root state it would have used"
  assert_contains "$out" "$h1" "the refusal must name the other homes the root serves"
  assert_not_contains "$out" "home=$root" "an ambiguous launch must never bind the code root"
  # The same resume with its session's recorded home binds exactly that home.
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root" --primary-only --recorded "$h2")
  assert_contains "$out" "home=$h2"$'\n'"source=session" "a resumed session must bind the home it recorded, not a shared default"
  # A home that no longer exists stops making the root ambiguous.
  bash "$LIB" forget --code-root "$root" "$h2" || fail "forget must succeed for a recorded home"
  rm -rf "$h1"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$root")
  assert_contains "$out" "source=code-root" "forgotten and vanished homes must no longer make the code root ambiguous"
  pass "fm-home-binding: two homes on one code root bind by recorded home or refuse, never by a shared default"
}

test_linked_worktree_stands_down_and_is_never_noted() {
  local repo="$TMP_ROOT/linked/repo" wt="$TMP_ROOT/linked/wt" h1="$TMP_ROOT/linked/h1" out
  fm_git_worktree "$repo" "$wt" task
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$h1"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$LIB" resolve --code-root "$wt" --primary-only; printf 'rc=%s\n' "$?")
  assert_contains "$out" "status=ineligible" "a linked task worktree naming no home must stand the extensions down"
  assert_contains "$out" "rc=3" "a stand-down must exit 3"
  FM_HOME="$h1" bash "$LIB" resolve --code-root "$wt" --record-pid "$$" >/dev/null
  assert_absent "$wt/state/.code-root-served-homes" "a linked worktree must never be noted as serving a home"
  pass "fm-home-binding: a linked task worktree stands down and never records a served home"
}

test_report_names_both_state_directories() {
  local h1="$TMP_ROOT/report/h1" h2="$TMP_ROOT/report/h2" root="$TMP_ROOT/report/root" pid out
  make_primary_root "$root"
  mkdir -p "$h1/state" "$h2/state"
  env FM_HOME="$h1" sleep 60 >/dev/null 2>&1 &
  pid=$!
  FM_HOME="$h1" bash "$LIB" resolve --code-root "$root" --record-pid "$pid" >/dev/null
  out=$(FM_HOME="$h1" bash "$LIB" report --pid "$pid")
  assert_contains "$out" "BOOTSTRAP_INFO: home binding: session start FM_HOME=$h1" "the comparison line must name the session's home"
  assert_contains "$out" "extension resolved $h1/state (source=env)" "the comparison line must name what the extension resolved"
  assert_not_contains "$out" "HOME_MISMATCH" "a harness serving this session's home must not report a mismatch"
  out=$(FM_HOME="$h2" bash "$LIB" report --pid "$pid")
  assert_contains "$out" "HOME_MISMATCH: the harness extensions in pid $pid act on $h1/state but this session start acted on $h2/state" \
    "an extension bound to another home must report both state directories"
  if [ -r "/proc/$pid/environ" ]; then
    assert_contains "$out" "launched with FM_HOME=$h1, so its hooks act on $h1/state" \
      "a harness launched for another home must report its launch environment"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # A pid whose record belongs to an exited process never vouches for its successor.
  sleep 60 >/dev/null 2>&1 &
  pid=$!
  out=$(FM_HOME="$h2" bash "$LIB" report --pid "$pid")
  assert_contains "$out" "extension no record" "a pid with no record of its own must read as no record"
  cp "$FM_HOME_BINDING_RUNTIME_DIR/$$" "$FM_HOME_BINDING_RUNTIME_DIR/$pid"
  out=$(FM_HOME="$h2" bash "$LIB" report --pid "$pid")
  assert_contains "$out" "extension no record" "another process's record copied under this pid must not vouch for it"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-home-binding: the session-start comparison names both state directories on a mismatch"
}

test_session_start_refuses_an_ambiguous_launch() {
  local root="$TMP_ROOT/start/root" h1="$TMP_ROOT/start/h1" out status f
  make_primary_root "$root"
  mkdir -p "$h1"
  for f in fm-session-start.sh fm-home-binding-lib.sh fm-primary-scope-lib.sh; do
    cp "$ROOT/bin/$f" "$root/bin/$f"
  done
  FM_HOME="$h1" bash "$root/bin/fm-home-binding-lib.sh" note-served "$h1" || fail "fixture: could not note the served home"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE bash "$root/bin/fm-session-start.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a refused session start keeps the always-zero exit contract"
  assert_contains "$out" "HOME_MISMATCH: session start did not run:" "an ambiguous launch must refuse loudly at session start"
  assert_contains "$out" "$h1" "the refusal must name the home this code root serves"
  assert_absent "$root/state/.lock" "a refused session start must never lock the code root's state"
  pass "fm-session-start: a launch naming no home on a shared code root refuses before locking"
}

test_watcher_down_banner() {
  local home="$TMP_ROOT/down/home" bin out pid now
  bin="$TMP_ROOT/down/bin"
  mkdir -p "$home/state" "$bin"
  ln -sf /bin/bash "$bin/omp"
  "$bin/omp" -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.lock"
  : > "$home/state/demo.meta"
  now=$(date +%s)
  : > "$home/state/.last-watcher-beat"
  fm_touch_epoch "$((now - 7260))" "$home/state/.last-watcher-beat"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-watcher-down.sh")
  assert_contains "$out" "WATCHER DOWN - no watcher beat for 2h01m in $home/state while pid $pid holds" \
    "a two-hour-old beat under a held lock must surface the outage and its length"
  assert_contains "$out" "1 task(s) in flight" "the banner must name what needs supervision"
  out=$(FM_HOME="$home" FM_WATCHER_DOWN_BANNER_MINUTES=180 "$ROOT/bin/fm-watcher-down.sh")
  assert_equals "" "$out" "an outage shorter than the threshold must stay silent"
  fm_touch_epoch "$((now - 30))" "$home/state/.last-watcher-beat"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-watcher-down.sh")
  assert_equals "" "$out" "a fresh beat must stay silent"
  fm_touch_epoch "$((now - 7260))" "$home/state/.last-watcher-beat"
  rm -f "$home/state/demo.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-watcher-down.sh")
  assert_equals "" "$out" "a home with nothing to supervise must stay silent"
  : > "$home/state/demo.meta"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(FM_HOME="$home" "$ROOT/bin/fm-watcher-down.sh")
  assert_equals "" "$out" "with no live session holding the lock the banner must stay silent"
  pass "fm-watcher-down: the banner fires only for a held lock, supervision need, and a stale beat"
}

test_resolution_order
test_two_homes_one_code_root
test_linked_worktree_stands_down_and_is_never_noted
test_report_names_both_state_directories
test_session_start_refuses_an_ambiguous_launch
test_watcher_down_banner
