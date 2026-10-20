#!/usr/bin/env bash
# tests/fm-wake-digest.test.sh - bin/fm-wake-digest.sh must present every wake
# the real drain presented (collapsing only redundant signal rows), record the
# drain's exact acknowledgement cutoff, and consume it only through an explicit
# --ack, so a supervisor never retypes a generation and never acks unseen rows.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DIGEST="$ROOT/bin/fm-wake-digest.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-digest-tests)
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

digest() {  # <state> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$DIGEST" "$@" 2>&1
}

test_signal_rows_collapse_without_losing_names() {
  local dir state out
  dir=$(make_case collapse)
  state="$dir/state"
  append_wake "$state" signal alpha.status "signal: $state/alpha.status $state/beta.turn-ended"
  append_wake "$state" signal beta.turn-ended "signal: $state/alpha.status $state/beta.turn-ended"
  append_wake "$state" check merged-alpha "check: merge landed: alpha https://example.test/pull/7"

  out=$(digest "$state") || fail "digest failed: $out"
  assert_contains "$out" "wake signal x2 #" "signal rows did not collapse into one line"
  assert_contains "$out" "alpha.status beta.turn-ended" "a signal key or reason path was lost"
  assert_contains "$out" "check: merge landed: alpha https://example.test/pull/7" "a check row reason was not printed verbatim"
  assert_contains "$out" "ack: after handling run bin/fm-wake-digest.sh --ack" "no ack line replaced WAKE_ACK_REQUIRED"
  assert_not_contains "$out" "WAKE_ACK_REQUIRED" "the raw ack line leaked into the digest"
  assert_not_contains "$out" "drain them with bin/fm-wake-drain.sh before anything else" "the redundant queued-wake warning was kept"
  [ "$(printf '%s\n' "$out" | grep -c '^wake signal')" = 1 ] || fail "more than one signal line: $out"

  out=$(digest "$state" --full)
  assert_contains "$out" "WAKE_ACK_REQUIRED" "--full did not reprint the raw drain output"
  [ "$(printf '%s\n' "$out" | grep -c "$(printf '\tsignal\t')")" = 2 ] || fail "--full lost a raw signal row: $out"
  pass "signal rows collapse to one line while every name, check reason, and the raw output survive"
}

test_ack_consumes_exactly_once() {
  local dir state out rc
  dir=$(make_case ack-once)
  state="$dir/state"
  append_wake "$state" check one "check: first"
  digest "$state" >/dev/null || fail "digest failed"
  assert_present "$state/.wake-digest.main.ack" "the drain cutoff was not recorded"

  out=$(digest "$state" --ack) || fail "--ack failed: $out"
  assert_contains "$out" "acknowledged through" "--ack did not report the cutoff it consumed"
  assert_absent "$state/.wake-digest.main.ack" "--ack left the consumed record behind"

  out=$(digest "$state") || fail "post-ack digest failed: $out"
  assert_not_contains "$out" "check: first" "an acknowledged row was presented again"
  assert_not_contains "$out" "ack: after handling" "an empty drain still asked for an acknowledgement"

  rc=0
  out=$(digest "$state" --ack) || rc=$?
  expect_code 0 "$rc" "a second --ack with nothing recorded"
  assert_contains "$out" "nothing recorded to acknowledge" "a second --ack did not say it had nothing to do"
  pass "--ack consumes the recorded cutoff once and is a reported no-op afterwards"
}

test_unacked_rows_are_re_presented_with_a_fresh_cutoff() {
  local dir state out first second
  dir=$(make_case re-present)
  state="$dir/state"
  append_wake "$state" check one "check: first"
  digest "$state" >/dev/null || fail "first digest failed"
  first=$(head -n 1 "$state/.wake-digest.main.ack")
  append_wake "$state" check two "check: second"
  out=$(digest "$state") || fail "second digest failed: $out"
  assert_contains "$out" "check: first" "an unacknowledged row was not re-presented"
  assert_contains "$out" "check: second" "a new row was not presented"
  second=$(head -n 1 "$state/.wake-digest.main.ack")
  [ "$second" -gt "$first" ] || fail "the recorded cutoff did not advance ($first -> $second)"
  digest "$state" --ack >/dev/null || fail "--ack of the newer cutoff failed"
  out=$(digest "$state") || fail "final digest failed: $out"
  assert_not_contains "$out" "check: second" "the newer cutoff did not cover the newer row"
  pass "an unacknowledged row is re-presented and the newest cutoff covers every presented row"
}

test_malformed_record_is_refused() {
  local dir state out rc
  dir=$(make_case malformed)
  state="$dir/state"
  printf 'abc\ngen\n' > "$state/.wake-digest.main.ack"
  rc=0
  out=$(digest "$state" --ack) || rc=$?
  expect_code 1 "$rc" "a malformed recorded cutoff"
  assert_contains "$out" "malformed" "the refusal did not name the malformed record"
  pass "a malformed recorded cutoff is refused rather than replayed"
}

test_signal_rows_collapse_without_losing_names
test_ack_consumes_exactly_once
test_unacked_rows_are_re_presented_with_a_fresh_cutoff
test_malformed_record_is_refused
