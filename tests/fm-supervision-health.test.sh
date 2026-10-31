#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-health)
HEALTH="$ROOT/bin/fm-supervision-health.sh"

health_fixture() {
  local dir
  dir=$(make_supercase "$1")
  mkdir -p "$dir/config" "$dir/units"
  printf 'backend=tmux\nwindow=fixture:0\n' > "$dir/state/live.meta"
  cat > "$dir/fakebin/bun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/telegram.log"
exit 0
SH
  cat > "$dir/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/systemctl.log"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*) echo "${FM_FAKE_TIMER_STATE:-active}" ;;
  *show*) echo success ;;
esac
SH
  chmod +x "$dir/fakebin/bun" "$dir/fakebin/systemctl"
  printf '%s\n' "$dir"
}

health_run() {
  local dir=$1
  shift
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_SUPERVISION_UNIT_DIR="$dir/units" \
    FM_FAKE_TMUX_WINDOW=fixture:fixture FM_POLL=3 PATH="$dir/fakebin:$PATH" "$HEALTH" "$@"
}

stale_health() {
  python3 - "$1/state/.last-watcher-beat" <<'PY'
import os
import sys
import time
os.utime(sys.argv[1], (time.time() - 10, time.time() - 10))
PY
}

test_health_incidents() {
  local dir
  dir=$(health_fixture incidents)
  touch "$dir/state/.last-watcher-beat"
  health_run "$dir" check >/dev/null || fail 'healthy check failed'
  [ ! -e "$dir/telegram.log" ] || fail 'healthy watcher raised an alert'
  stale_health "$dir"
  health_run "$dir" check >/dev/null || fail 'stale check failed'
  health_run "$dir" check >/dev/null || fail 'repeat stale check failed'
  [ "$(wc -l < "$dir/telegram.log")" -eq 1 ] || fail 'one incident sent duplicate alerts'
  [ "$(grep -c primary-supervision-lost "$dir/state/.wake-queue")" -eq 1 ] || fail 'one incident queued duplicate wakes'
  touch "$dir/state/.last-successful-drain"
  health_run "$dir" check >/dev/null || fail 'recent drain did not restore health'
  [ ! -e "$dir/state/.primary-loss-alert" ] || fail 'recovery did not clear the incident'
  rm "$dir/state/.last-successful-drain"
  health_run "$dir" check >/dev/null || fail 'second outage failed'
  [ "$(wc -l < "$dir/telegram.log")" -eq 2 ] || fail 'second incident was suppressed'
  rm "$dir/state/live.meta" "$dir/state/.primary-loss-alert"
  health_run "$dir" check >/dev/null || fail 'empty home check failed'
  [ "$(wc -l < "$dir/telegram.log")" -eq 2 ] || fail 'empty home sent an alert'
  pass 'supervision-health: watcher and drain freshness, incident dedupe, recovery, and empty-home suppression'
}

test_health_healthy_window() {
  local dir writer
  dir=$(health_fixture healthy-window)
  (for _ in $(seq 1 35); do touch "$dir/state/.last-watcher-beat"; sleep 0.1; done) &
  writer=$!
  touch "$dir/state/.last-watcher-beat"
  health_run "$dir" run >/dev/null || fail 'healthy oneshot failed'
  wait "$writer"
  [ ! -e "$dir/telegram.log" ] || fail 'healthy bounded run sent an alert'
  pass 'supervision-health: a whole healthy oneshot window stays quiet'
}

test_health_install_doctor() {
  local dir rc unit target
  dir=$(health_fixture install)
  health_run "$dir" doctor >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail 'doctor accepted absent units'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_SUPERVISION_UNIT_DIR="$dir/units" FM_POLL=3 PATH="$dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-bootstrap.sh" install supervision-health >/dev/null || fail 'bootstrap installation failed'
  health_run "$dir" doctor >/dev/null || fail 'doctor rejected installed active units'
  FM_FAKE_TIMER_STATE=inactive health_run "$dir" doctor >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail 'doctor accepted an inactive timer'
  mkdir -p "$dir/runtime"
  for target in basic shutdown sysinit sockets timers; do
    printf '[Unit]\nDescription=Private %s target\nDefaultDependencies=no\n' "$target" > "$dir/units/$target.target"
  done
  for unit in "$dir/units/"*.service "$dir/units/"*.timer; do
    SYSTEMD_UNIT_PATH="$dir/units" XDG_RUNTIME_DIR="$dir/runtime" systemd-analyze --user verify "$unit" || fail 'systemd rejected generated unit'
  done
  pass 'supervision-health: bootstrap installs private units and doctor verifies active state'
}

test_health_bootstrap_default_home() {
  local dir rc
  dir=$(health_fixture default-home)
  (
    unset FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
    export FM_ROOT_OVERRIDE="$dir" FM_SUPERVISION_UNIT_DIR="$dir/units" FM_POLL=3
    export PATH="$dir/fakebin:$PATH"
    bash "$ROOT/bin/fm-bootstrap.sh" install supervision-health >/dev/null || exit 1
    bash "$ROOT/bin/fm-bootstrap.sh" doctor supervision-health >/dev/null || exit 1
    FM_FAKE_TIMER_STATE=inactive bash "$ROOT/bin/fm-bootstrap.sh" install supervision-health >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || exit 1
  ) || fail 'bootstrap lost its default home or hid a failed timer installation'
  pass 'supervision-health: bootstrap forwards its default home and propagates installation failure'
}

test_health_rejects_zero_poll() {
  local dir rc
  dir=$(health_fixture zero-poll)
  FM_HOME="$dir" FM_POLL=0000 "$HEALTH" check >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail 'zero cadence could create a rapid timer loop'
  pass 'supervision-health: zero cadence is rejected'
}

test_health_bootstrap_default_home
test_health_rejects_zero_poll
test_health_incidents
test_health_healthy_window
test_health_install_doctor
