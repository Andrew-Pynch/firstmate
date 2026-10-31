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
case "$(cat "$FM_HOME/sender-mode" 2>/dev/null)" in
  missing) echo 'missing Telegram credentials' >&2; exit 1 ;;
  hang) sleep 12 ;;
esac
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
    FM_FAKE_TMUX_WINDOW=fixture:fixture FM_POLL="${HEALTH_TEST_POLL:-3}" PATH="$dir/fakebin:$PATH" "$HEALTH" "$@"
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
  mv "$dir/state/live.meta" "$dir/state/z-worker.meta"
  printf 'owner=main-merge\n' > "$dir/state/a-merge.meta"
  health_run "$dir" check >/dev/null || fail 'stale check failed'
  health_run "$dir" check >/dev/null || fail 'repeat stale check failed'
  [ -s "$dir/telegram.log" ] || fail 'windowless metadata suppressed a later live endpoint'
  [ "$(wc -l < "$dir/telegram.log")" -eq 1 ] || fail 'one incident sent duplicate alerts'
  [ "$(grep -c primary-supervision-lost "$dir/state/.wake-queue")" -eq 1 ] || fail 'one incident queued duplicate wakes'
  touch "$dir/state/.last-successful-drain"
  health_run "$dir" check >/dev/null || fail 'recent drain did not restore health'
  [ ! -e "$dir/state/.primary-loss-alert" ] || fail 'recovery did not clear the incident'
  rm "$dir/state/.last-successful-drain"
  health_run "$dir" check >/dev/null || fail 'second outage failed'
  [ "$(wc -l < "$dir/telegram.log")" -eq 2 ] || fail 'second incident was suppressed'
  rm "$dir/state/z-worker.meta" "$dir/state/.primary-loss-alert"
  health_run "$dir" check >/dev/null || fail 'empty home check failed'
  [ "$(wc -l < "$dir/telegram.log")" -eq 2 ] || fail 'empty home sent an alert'
  pass 'supervision-health: watcher and drain freshness, incident dedupe, recovery, and empty-home suppression'
}

test_health_real_watcher() {
  local mode=$1 dir watcher checker i
  dir=$(health_fixture "real-$mode")
  touch "$dir/state/.last-heartbeat"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-base"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  printf 'working tick %s\n' "$(date +%s%N)"
else
  exec "$FM_HOME/fakebin/tmux-base" "$@"
fi
SH
  chmod +x "$dir/fakebin/tmux"
  if [ "$mode" = slow ]; then
    cat > "$dir/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/slow-started"
sleep 5
touch "$FM_HOME/slow-finished"
SH
    chmod 0700 "$dir/state/slow.check.sh"
    FM_HOME="$dir" bash "$ROOT/bin/fm-check-register.sh" slow >/dev/null || fail 'could not register slow check'
  else
    touch "$dir/state/.last-check"
  fi
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=2 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    FM_STALE_SECS=999999 FM_FAKE_TMUX_WINDOW=fixture:fixture PATH="$dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/watcher.log" 2>&1 &
  watcher=$!
  for i in $(seq 1 100); do
    [ -e "$dir/state/.last-watcher-beat" ] && break
    sleep 0.05
  done
  [ -e "$dir/state/.last-watcher-beat" ] || fail 'real watcher never checked in'
  if [ "$mode" = slow ]; then
    for i in $(seq 1 100); do [ -e "$dir/slow-started" ] && break; sleep 0.05; done
    [ -e "$dir/slow-started" ] || fail "slow check never started: $(cat "$dir/watcher.log")"
  fi
  (
    for i in $(seq 1 6); do
      HEALTH_TEST_POLL=2 health_run "$dir" run || exit 1
    done
  ) > "$dir/health.log" 2>&1 &
  checker=$!
  sleep 6
  [ ! -e "$dir/telegram.log" ] || fail "healthy real $mode watcher triggered an alert"
  kill -0 "$watcher" || fail "real healthy watcher exited: $(cat "$dir/watcher.log")"
  if [ "$mode" = slow ]; then
    [ -e "$dir/slow-finished" ] || fail 'supported slow check did not finish'
  fi
  python3 - "$watcher" "$dir" <<'PYTEST' || fail "real $mode watcher death missed its poll deadline"
from pathlib import Path
import os, signal, sys, time
pid=int(sys.argv[1]); home=Path(sys.argv[2]); beat=home/'state/.last-watcher-beat'
previous=beat.stat().st_mtime_ns
limit=time.monotonic()+3
while beat.stat().st_mtime_ns == previous:
    if time.monotonic()>limit: raise SystemExit('real watcher stopped publishing heartbeats')
    time.sleep(0.01)
time.sleep(0.2)
started=time.monotonic(); os.kill(pid,signal.SIGKILL)
while time.monotonic()-started < 2:
    paths=(home/'telegram.log',home/'state/.wake-queue')
    if all(p.exists() and 'primary-supervision-lost' in p.read_text() for p in paths): break
    time.sleep(0.01)
else: raise SystemExit('no durable and external alert within FM_POLL=2')
PYTEST
  wait "$watcher" 2>/dev/null || true
  wait "$checker" || fail "real watcher health monitor failed: $(cat "$dir/health.log")"
  [ "$(wc -l < "$dir/telegram.log")" -eq 1 ] || fail 'real watcher death alerted more than once'
  pass "supervision-health: real $mode watcher stays healthy and its death alerts within one poll"
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

test_health_failed_delivery() {
  local mode=$1 dir
  dir=$(health_fixture "delivery-$mode")
  printf '%s\n' "$mode" > "$dir/sender-mode"
  HEALTH_TEST_POLL=1 health_run "$dir" install >/dev/null || fail 'could not install failure fixture units'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_SUPERVISION_UNIT_DIR="$dir/units" \
    FM_FAKE_TMUX_WINDOW=fixture:fixture FM_POLL=1 PATH="$dir/fakebin:$PATH" \
    python3 - "$HEALTH" "$mode" <<'PYTEST' || fail "delivery-$mode lost its failure state or cadence"
from pathlib import Path
import configparser, os, shlex, subprocess, sys, time
health,mode=sys.argv[1:]; home=Path(os.environ['FM_HOME'])
unit=next((home/'units').glob('*.service'))
config=configparser.ConfigParser(interpolation=None,strict=False); config.read(unit)
env=os.environ.copy()
for line in unit.read_text().splitlines():
    if line.startswith('Environment='):
        key,value=shlex.split(line.partition('=')[2])[0].replace('%%','%').split('=',1)
        env[key]=value
args=shlex.split(config['Service']['ExecStart'])
for iteration in range(2):
    started=time.monotonic()
    result=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=10)
    elapsed=time.monotonic()-started
    assert result.returncode != 0, result.stdout
    assert elapsed >= 1, f'failure retried without its poll interval: {elapsed}'
    if mode=='hang' and iteration==0:
        assert elapsed < 9, f'sender was not bounded: {elapsed}'
    diagnosed=subprocess.run([health,'doctor'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert diagnosed.returncode != 0, diagnosed.stdout
    assert 'uncertain' in diagnosed.stderr, diagnosed.stderr
    marker=(home/'state/.primary-loss-alert').read_text()
    assert ('delivery-uncertain' if mode=='hang' else 'delivery-failed') in marker, marker
assert config['Service']['Restart']=='on-failure'
assert config['Service']['RestartSec']=='1s'
assert config['Service']['RestartPreventExitStatus']=='75'
assert len((home/'telegram.log').read_text().splitlines())==1, 'uncertain or failed send was retried'
assert len((home/'state/.wake-queue').read_text().splitlines())==1
(home/'state/.last-watcher-beat').touch()
assert subprocess.run([health,'check'],env=env,capture_output=True).returncode==0
assert not (home/'state/.primary-loss-alert').exists()
PYTEST
  pass "supervision-health: $mode sender remains diagnosed, respects cadence, and is not resent"
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
test_health_real_watcher ordinary
test_health_real_watcher slow
test_health_failed_delivery missing
test_health_failed_delivery hang
test_health_install_doctor
