#!/usr/bin/env bash
# The watcher must alert when its own beacon is healthy but Main stops handling wakes.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-quiet)
export TMP_ROOT # make_case in wake-helpers.sh uses this root.
dir=$(make_case stalled)
state="$dir/state"
export FM_STATE_OVERRIDE="$state" FM_MAIN_QUIET_SECS=2
NOTIFY="$ROOT/bin/fm-wake-notify.sh"
append_wake "$state" check ready 'check: ready for landing'
[ "$("$NOTIFY" claim)" = deliver ] || fail 'first notification was not delivered'
[ "$("$NOTIFY" claim)" = skip ] || fail 'immediate duplicate was delivered'
sleep 3
# A beating watcher cannot substitute for a successful drain.
touch "$state/.last-watcher-beat"
[ "$("$NOTIFY" claim)" = deliver ] || fail 'aged actionable queue stayed suppressed behind a healthy watcher beacon'
[ "$("$NOTIFY" claim)" = skip ] || fail 'stall alert was not bounded'
"$NOTIFY" health > "$dir/health"
grep -F 'last_successful_drain=never' "$dir/health" >/dev/null || fail 'missing drain must remain visible'
grep -E 'oldest_queued_wake_age=[3-9][0-9]*s' "$dir/health" >/dev/null || fail 'oldest queue age was not exposed'
: > "$state/.afk"
sleep 3
[ "$("$NOTIFY" claim)" = skip ] || fail 'away supervision produced a Main stall alert'
rm "$state/.afk"
[ "$("$NOTIFY" claim)" = skip ] || fail 'away return did not allow time to resume'
sleep 3
PATH="$dir/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_WATCH_HANDLING_SUCCESSOR=1 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
pid=$!
wait_for_exit "$pid" 15 || { kill "$pid" 2>/dev/null || true; fail 'watcher never surfaced Main stall'; }
grep -F 'check: main wake-loop stalled:' "$dir/watch.out" >/dev/null || fail 'watcher did not alert on its own undrained queue'
"$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err"
ack_drain_err "$state" "$dir/drain.err" || fail 'successful handling acknowledgement failed'
"$NOTIFY" health > "$dir/health"
grep -E 'last_successful_drain=[0-9]+' "$dir/health" >/dev/null || fail 'successful acknowledgement was not recorded'
grep -F 'oldest_queued_wake_age=none' "$dir/health" >/dev/null || fail 'handled queue still reported old work'
# Heartbeats and declared external waits do not justify an actionable-stall alert.
append_wake "$state" heartbeat heartbeat heartbeat
append_wake "$state" stale waiting 'stale: waiting (paused 500s, awaiting external - declared pause, release)'
[ "$("$NOTIFY" claim)" = deliver ] || fail 'fresh notification missing'
sleep 3
[ "$("$NOTIFY" claim)" = skip ] || fail 'non-actionable queue caused a Main stall alert'
pass 'bounded Main-quiet alert survives a healthy watcher, resumes after away, and clears on handled wakes'
