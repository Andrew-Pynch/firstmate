#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-health)
HEALTH="$ROOT/bin/fm-supervision-health.sh"
ln -s /bin/sleep "$TMP_ROOT/omp"
"$TMP_ROOT/omp" 600 &
HEALTH_OWNER_PID=$!
health_cleanup() {
  t3_fake_stop
  kill "$HEALTH_OWNER_PID" 2>/dev/null || true
  wait "$HEALTH_OWNER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap health_cleanup EXIT

health_fixture() {
  local dir
  dir=$(make_supercase "$1")
  mkdir -p "$dir/config" "$dir/units"
  printf '%s\n' "$HEALTH_OWNER_PID" > "$dir/state/.lock"
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

health_pending_records() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-pending-reply-lib.sh"
    for task in first later; do
      case "$task" in first) corr=0000000000000001 ;; later) corr=0000000000000002 ;; esac
      made=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" "$task" "report $task")
      mv "$(fm_pending_reply_path "$FM_STATE_OVERRIDE" "$made")" "$(fm_pending_reply_path "$FM_STATE_OVERRIDE" "$corr")"
      rec=$(fm_pending_reply_path "$FM_STATE_OVERRIDE" "$corr")
      fm_pending_reply_set "$rec" corr_id "$corr"
      fm_pending_reply_set "$rec" grace_secs 0
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr"
      fm_pending_reply_set "$rec" request_turn_completed_epoch 1
    done
  ' _ "$ROOT"
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
  local mode=$1 dir watcher checker i code check_timeout=30 health_cycles=6 healthy_seconds=6 pending_hook=''
  dir=$(health_fixture "real-$mode")
  code=$ROOT
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
  if [ "$mode" = relaunch ]; then
    code="$dir/code"
    mkdir -p "$code/bin"
    for entry in "$ROOT/bin/"*; do
      [ "${entry##*/}" = fm-spawn.sh ] || ln -s "$entry" "$code/bin/${entry##*/}"
    done
    cat > "$code/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/relaunch-pid"
touch "$FM_HOME/relaunch-started"
sleep 20
touch "$FM_HOME/relaunch-finished"
SH
    chmod +x "$code/bin/fm-spawn.sh"
    printf 'kind=secondmate\nharness=codex\nbackend=tmux\nwindow=fixture:missing\n' > "$dir/state/mate.meta"
    check_timeout=2
  fi
  if [ "$mode" = capability ]; then
    printf 'backend=t3code\nwindow=capability-thread\n' > "$dir/state/a-t3.meta"
    cat > "$dir/fakebin/node" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  *fm-t3-mcp.mjs\ status) touch "$FM_HOME/capability-started"; sleep 20; exit 1 ;;
  *fm-t3-mcp.mjs\ state) printf '{"ok":true,"status":"running"}\n'; exit 0 ;;
  *fm-t3-mcp.mjs\ capture) printf 'working %s\n' "$(date +%s%N)"; exit 0 ;;
esac
exec "$FM_REAL_NODE" "$@"
SH
    chmod +x "$dir/fakebin/node"
    check_timeout=2
  fi
  if [ "$mode" = capture-rpc ]; then
    printf 'backend=t3code\nwindow=read-thread\n' > "$dir/state/a-t3.meta"
    t3_fake_start "$dir/server"
    t3_fake_case "$dir/server/world" '{"delayToolsMs":{"t3_thread_read":20000},"threads":{"read-thread":{"threadId":"read-thread","status":"running","activeRunId":"r1","items":[{"type":"assistant_message","status":"completed","text":"verified delayed capture"}]}}}'
    t3_fake_credential "$dir/config/t3code-token"
    cat > "$dir/fakebin/node" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  *fm-t3-mcp.mjs\ capture)
    touch "$FM_HOME/capture-started"
    "$FM_REAL_NODE" "$@" > "$FM_HOME/capture-inflight" || exit $?
    cp "$FM_HOME/capture-inflight" "$FM_HOME/capture-result"
    cat "$FM_HOME/capture-result"
    touch "$FM_HOME/capture-completed"
    exit 0 ;;
  *fm-t3-mcp.mjs\ status) exit 1 ;;
esac
exec "$FM_REAL_NODE" "$@"
SH
    chmod +x "$dir/fakebin/node"
    health_cycles=26
    healthy_seconds=46
  fi
  if [ "$mode" = pending-rpc ]; then
    health_pending_records "$dir"
    printf 'kind=secondmate\nbackend=t3code\nwindow=read-thread\n' > "$dir/state/first.meta"
    printf 'kind=secondmate\nbackend=tmux\nwindow=fixture:0\nharness=codex\n' > "$dir/state/later.meta"
    t3_fake_start "$dir/server"
    t3_fake_case "$dir/server/world" '{"delayToolsMs":{"t3_environment_read":20000,"t3_thread_read":20000},"threads":{"read-thread":{"threadId":"read-thread","status":"completed"}}}'
    t3_fake_credential "$dir/config/t3code-token"
    cat > "$dir/recover" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/recovery.log"
SH
    cat > "$dir/fakebin/node" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in *fm-t3-mcp.mjs\ state) touch "$FM_HOME/observation-started" ;; esac
exec "$FM_REAL_NODE" "$@"
SH
    chmod +x "$dir/recover" "$dir/fakebin/node"
    pending_hook="$dir/recover"
    health_cycles=26
    healthy_seconds=46
  fi
  if [ "$mode" = procevent ]; then
    fm_test_track_procevent_home "$dir"
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
      bash "$ROOT/bin/fm-procevent.sh" register lavish pending -- /bin/true >/dev/null || fail 'could not register process-event fixture'
    python3 - "$dir/state/procevent/pending.source" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); content=path.read_text()
path.write_text(content.split('argv:\n')[0]+'argv:\n')
PY
    rm -f "$dir/state/procevent/.owner-lease"
    check_timeout=2
  fi
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
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$code" FM_STATE_OVERRIDE="$dir/state" FM_POLL=2 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT="$check_timeout" FM_HEARTBEAT=999999 \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=20 \
    FM_PENDING_REPLY_SEND_HOOK="$pending_hook" \
    FM_REAL_NODE="$(command -v node)" FM_STALE_SECS=999999 FM_FAKE_TMUX_WINDOW=fixture:fixture PATH="$dir/fakebin:$PATH" \
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
  if [ "$mode" = relaunch ]; then
    for i in $(seq 1 100); do [ -e "$dir/relaunch-started" ] && break; sleep 0.05; done
    [ -e "$dir/relaunch-started" ] || fail "secondmate relaunch never started: $(cat "$dir/watcher.log")"
  fi
  if [ "$mode" = procevent ]; then
    for i in $(seq 1 100); do [ -e "$dir/state/procevent/.owner-lease" ] && break; sleep 0.05; done
    [ -e "$dir/state/procevent/.owner-lease" ] || fail 'process-event reconciliation did not start'
  fi
  if [ "$mode" = capability ]; then
    for i in $(seq 1 160); do [ -e "$dir/capability-started" ] && break; sleep 0.05; done
    [ -e "$dir/capability-started" ] || fail "capability probe never started: $(cat "$dir/watcher.log")"
  fi
  if [ "$mode" = capture-rpc ]; then
    for i in $(seq 1 160); do [ -e "$dir/capture-started" ] && break; sleep 0.05; done
    [ -e "$dir/capture-started" ] || fail "capture never started: $(cat "$dir/watcher.log")"
  fi
  if [ "$mode" = pending-rpc ]; then
    for i in $(seq 1 160); do [ -e "$dir/observation-started" ] && break; sleep 0.05; done
    [ -e "$dir/observation-started" ] || fail 'pending-reply observation never started'
  fi
  (
    for i in $(seq 1 "$health_cycles"); do
      HEALTH_TEST_POLL=2 health_run "$dir" run || exit 1
    done
  ) > "$dir/health.log" 2>&1 &
  checker=$!
  sleep "$healthy_seconds"
  [ ! -e "$dir/telegram.log" ] || fail "healthy real $mode watcher triggered an alert"
  kill -0 "$watcher" || fail "real healthy watcher exited: $(cat "$dir/watcher.log")"
  if [ "$mode" = slow ]; then
    [ -e "$dir/slow-finished" ] || fail 'supported slow check did not finish'
  fi
  if [ "$mode" = capture-rpc ]; then
    [ -e "$dir/capture-completed" ] || fail 'multi-RPC capture did not complete'
    grep -q 'verified delayed capture' "$dir/capture-result" || fail 'capture lost the delayed server result'
    python3 - "$T3_FAKE_LOG" <<'PY' || fail 'capture did not finish both delayed RPCs'
import json, sys
rows=[json.loads(row) for row in open(sys.argv[1])]
assert sum(row.get('tool') == 't3_thread_read' and not row.get('delayStarted') for row in rows) >= 2
PY
  fi
  if [ "$mode" = pending-rpc ]; then
    python3 - "$dir" <<'PY' || fail 'multi-RPC observation prevented pending-reply progress'
from pathlib import Path
import json, sys
home=Path(sys.argv[1])
assert home.joinpath('recovery.log').read_text().splitlines() == ['first','later']
for corr in ('0000000000000001','0000000000000002'):
    record=dict(line.split('=',1) for line in (home/'state/pending-replies'/corr).read_text().splitlines() if '=' in line)
    assert record['phase'] == 'recovery_sent'
rows=[json.loads(row) for row in (home/'server/world/requests.jsonl').read_text().splitlines()]
assert any(row.get('tool') == 't3_environment_read' and not row.get('delayStarted') for row in rows)
assert any(row.get('tool') == 't3_thread_read' and not row.get('delayStarted') for row in rows)
PY
  fi
  python3 - "$watcher" "$dir" <<'PYTEST' || fail "real $mode watcher death missed its poll deadline"
from pathlib import Path
import os, signal, subprocess, sys, time
pid=int(sys.argv[1]); home=Path(sys.argv[2]); beat=home/'state/.last-watcher-beat'
previous=beat.stat().st_mtime_ns
limit=time.monotonic()+3
while beat.stat().st_mtime_ns == previous:
    if time.monotonic()>limit: raise SystemExit('real watcher stopped publishing heartbeats')
    time.sleep(0.01)
time.sleep(0.2)
groups=[]
for row in subprocess.check_output(['ps','-eo','pid=,ppid=,pgid='],text=True).splitlines():
    child,parent,group=map(int,row.split())
    if parent==pid and child==group: groups.append(group)
started=time.monotonic(); os.kill(pid,signal.SIGKILL)
try:
    while time.monotonic()-started < 2:
        paths=(home/'telegram.log',home/'state/.wake-queue')
        if all(p.exists() and 'primary-supervision-lost' in p.read_text() for p in paths): break
        time.sleep(0.01)
    else: raise SystemExit('no durable and external alert within FM_POLL=2')
finally:
    for group in groups:
        try: os.killpg(group,signal.SIGTERM)
        except ProcessLookupError: pass

PYTEST
  wait "$watcher" 2>/dev/null || true
  if [ "$mode" = relaunch ]; then
    [ ! -e "$dir/relaunch-finished" ] || fail 'delayed relaunch finished before watcher death'
    python3 - "$dir/relaunch-pid" <<'PYTEST'
import os, signal, sys
pid=int(open(sys.argv[1]).read())
try: os.killpg(os.getpgid(pid), signal.SIGTERM)
except ProcessLookupError: pass
PYTEST
  fi
  wait "$checker" || fail "real watcher health monitor failed: $(cat "$dir/health.log")"
  [ "$(wc -l < "$dir/telegram.log")" -eq 1 ] || fail 'real watcher death alerted more than once'
  if [ "$mode" = capture-rpc ] || [ "$mode" = pending-rpc ]; then t3_fake_stop; fi
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

test_health_queue_retry() {
  local mode=$1 dir
  dir=$(health_fixture "queue-$mode")
  printf '%s\n' "$mode" > "$dir/sender-mode"
  HEALTH_TEST_POLL=1 health_run "$dir" install >/dev/null || fail 'could not install queue fixture units'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_SUPERVISION_UNIT_DIR="$dir/units" \
    FM_FAKE_TMUX_WINDOW=fixture:fixture FM_POLL=1 PATH="$dir/fakebin:$PATH" \
    python3 - "$HEALTH" "$ROOT" "$mode" <<'PYTEST' || fail "queue contention lost $mode incident"
from pathlib import Path
import os, subprocess, sys, time
health,root,mode=sys.argv[1:]; home=Path(os.environ['FM_HOME'])
locker=subprocess.Popen(['bash','-c', '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; echo ready; read -r release; fm_lock_release "$FM_WAKE_QUEUE_LOCK"', '_',root],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
try:
    assert locker.stdout.readline().strip()=='ready'
    first=subprocess.run([health,'run'],capture_output=True,text=True,timeout=10)
    assert first.returncode != 0
    queue=home/'state/.wake-queue'
    assert not queue.exists() or not queue.read_text(), 'lock did not prevent initial publication'
    assert len((home/'telegram.log').read_text().splitlines())==1
finally:
    locker.communicate('release\n',timeout=5)
for _ in range(2):
    result=subprocess.run([health,'run'],capture_output=True,text=True,timeout=10)
    assert result.returncode != 0, 'lost failed or uncertain delivery diagnosis'
    assert 'uncertain' in result.stderr, result.stderr
    assert 'publication remains pending' not in result.stderr, result.stderr
rows=(home/'state/.wake-queue').read_text().splitlines()
assert len(rows)==1 and rows[0].split('\t')[3]=='primary-supervision-lost', rows
assert len((home/'telegram.log').read_text().splitlines())==1, 'transport retried after contention'
receipt=(home/'state/.primary-loss-alert').read_text()
assert ('delivery-uncertain' if mode=='hang' else 'delivery-failed') in receipt, receipt
assert (home/'state/.primary-loss-queued').read_text().strip()==receipt.splitlines()[0]
doctor=subprocess.run([health,'doctor'],capture_output=True,text=True)
assert doctor.returncode != 0 and 'uncertain' in doctor.stderr, doctor
PYTEST
  pass "supervision-health: queue contention retries durable $mode outage without resending Telegram"
}

test_health_orphan_host() {
  local dir primary host watcher
  dir=$(health_fixture orphan-host)
  ln -s /bin/bash "$dir/omp"
  touch "$dir/state/.last-heartbeat" "$dir/state/.last-check" "$dir/config/supervision-host"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=3 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_SECS=999999 \
    FM_FAKE_TMUX_WINDOW=fixture:fixture FM_SUPERVISION_HOST_PRIMARY=omp \
    FM_SUPERVISION_ENGINE_COMMAND=/bin/false PATH="$dir/fakebin:$PATH" \
    "$dir/omp" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$1" park > "$FM_HOME/host.log" 2>&1 & echo "$!" > "$FM_HOME/host.pid"; wait "$!"' _ "$ROOT/bin/fm-supervision-host.sh" &
  primary=$!
  for _ in $(seq 1 200); do [ -s "$dir/state/.watch.lock/pid" ] && [ -e "$dir/state/.last-watcher-beat" ] && break; sleep 0.05; done
  [ -e "$dir/state/.last-watcher-beat" ] || fail "real host never armed: $(cat "$dir/host.log")"
  host=$(cat "$dir/host.pid")
  watcher=$(cat "$dir/state/.watch.lock/pid")
  health_run "$dir" check >/dev/null || fail 'healthy real host was rejected'
  [ ! -e "$dir/telegram.log" ] || fail 'healthy real host raised an alert'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=3 PATH="$dir/fakebin:$PATH" \
    python3 - "$primary" "$host" "$watcher" "$HEALTH" <<'PY' || fail 'orphan host hid the dead primary'
from pathlib import Path
import os, signal, subprocess, sys, time
primary,host,watcher=map(int,sys.argv[1:4]); health=sys.argv[4]
home=Path(os.environ['FM_HOME']); beat=home/'state/.last-watcher-beat'
before=beat.stat().st_mtime_ns; started=time.monotonic()
os.kill(primary,signal.SIGKILL)
try:
    while beat.stat().st_mtime_ns==before:
        assert time.monotonic()-started<1.5, 'orphan watcher did not keep beating'
        time.sleep(0.02)
    os.kill(host,0); os.kill(watcher,0)
    result=subprocess.run([health,'check'],capture_output=True,text=True,timeout=3)
    assert result.returncode==0, result.stderr
    assert time.monotonic()-started<3, 'outage exceeded one poll'
    assert (home/'telegram.log').exists(), 'fresh orphan was treated as healthy'
    assert 'primary-supervision-lost' in (home/'telegram.log').read_text()
    assert 'primary-supervision-lost' in (home/'state/.wake-queue').read_text()
finally:
    for pid in (host,watcher):
        try: os.kill(pid,signal.SIGTERM)
        except ProcessLookupError: pass
PY
  wait "$primary" 2>/dev/null || true
  pass 'supervision-health: dead primary alerts while its real orphan host watcher still beats'
}

test_health_remote_work() {
  local verdict dir
  for verdict in alive dead missing stopped; do
    dir=$(health_fixture "remote-$verdict")
    make_remote_liveness_fixture "$dir" "$verdict"
    health_run "$dir" check >/dev/null || fail "remote $verdict probe failed"
    [ -s "$dir/remote-probes.log" ] || fail 'recorded remote endpoint was probed locally'
    if [ "$verdict" = alive ]; then
      [ "$(grep -c primary-supervision-lost "$dir/state/.wake-queue")" -eq 1 ] || fail 'remote-only live work did not queue its outage'
      [ "$(wc -l < "$dir/telegram.log")" -eq 1 ] || fail 'remote-only live work did not alert'
    else
      [ ! -e "$dir/telegram.log" ] || fail "remote $verdict endpoint raised an outage"
    fi
  done
  pass 'supervision-health: remote-only live work alerts; dead, missing and stopped endpoints stay quiet'
}

test_health_slow_endpoint() {
  local dir checker
  dir=$(health_fixture slow-endpoint)
  mv "$dir/state/live.meta" "$dir/state/z-live.meta"
  printf 'backend=t3code\nwindow=unavailable-thread\n' > "$dir/state/a-slow.meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-base"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
sleep 0.2
exec "$FM_HOME/fakebin/tmux-base" "$@"
SH
  cat > "$dir/fakebin/node" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *fm-t3-mcp.mjs*) touch "$FM_HOME/slow-probe-started"; sleep 20; exit 1 ;;
esac
exec "$FM_REAL_NODE" "$@"
SH
  chmod +x "$dir/fakebin/node" "$dir/fakebin/tmux"
  FM_REAL_NODE=$(command -v node) HEALTH_TEST_POLL=3 health_run "$dir" run > "$dir/health.log" 2>&1 &
  checker=$!
  for _ in $(seq 1 100); do [ -e "$dir/telegram.log" ] && break; sleep 0.02; done
  [ -e "$dir/slow-probe-started" ] || fail 'slow backend fixture did not run'
  [ -e "$dir/telegram.log" ] || fail "slow first endpoint starved later live work: $(cat "$dir/health.log")"
  wait "$checker" || fail 'slow-endpoint check failed'
  [ "$(grep -c primary-supervision-lost "$dir/state/.wake-queue")" -eq 1 ] || fail 'slow-endpoint outage not queued once'
  pass 'supervision-health: slow first endpoint cannot starve a later live endpoint'
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

test_health_rejects_unused_live() {
  local dir rc
  dir=$(health_fixture unused-live)
  health_run "$dir" _live >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail 'removed shell live entry remained callable'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=3 \
    python3 "$ROOT/bin/fm-supervision-health.py" live >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail 'removed Python live entry remained callable'
  pass 'supervision-health: unused live entry points are rejected'
}

test_health_rejects_zero_poll() {
  local dir rc
  dir=$(health_fixture zero-poll)
  FM_HOME="$dir" FM_POLL=0000 "$HEALTH" check >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail 'zero cadence could create a rapid timer loop'
  pass 'supervision-health: zero cadence is rejected'
}

test_health_wedge_reads() {
  local dir watcher checker i
  dir=$(health_fixture wedge-reads)
  printf 'backend=t3code\nwindow=read-thread\n' > "$dir/state/t3.meta"
  t3_fake_start "$dir/server"
  t3_fake_case "$dir/server/world" '{"delayToolsMs":{"t3_thread_read":2000},"threads":{"read-thread":{"threadId":"read-thread","status":"running","activeRunId":"r1","runs":[{"runId":"r1","status":"running","startedAt":"2099-01-01T00:00:00Z"}]}}}'
  t3_fake_credential "$dir/config/t3code-token"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=2 FM_CHECK_TIMEOUT=1 FM_SIGNAL_GRACE=0 bash -c '
      . "$1/bin/fm-watch.sh"
      WATCHER_PID=$$
      mkdir "$WATCH_LOCK"
      printf "%s\n" "$$" > "$WATCH_LOCK/pid"
      wedge_defer_t3code_running read-thread "$STATE/since" fixture 10 || exit 1
      touch "$FM_HOME/wedge-completed"
      started=$SECONDS
      WATCHER_WAIT_BUDGET=1 watcher_waited sleep 30
      [ "$?" -eq 124 ] && [ "$((SECONDS-started))" -le 3 ] || exit 1
      touch "$FM_HOME/bounded-wait-completed"
      while :; do watcher_waited sleep 2; done
    ' _ "$ROOT" > "$dir/watcher.log" 2>&1 &
  watcher=$!
  for i in $(seq 1 100); do [ -e "$dir/state/.last-watcher-beat" ] && break; sleep 0.05; done
  (
    for i in $(seq 1 7); do HEALTH_TEST_POLL=2 health_run "$dir" run || exit 1; done
  ) > "$dir/health.log" 2>&1 &
  checker=$!
  for i in $(seq 1 180); do [ -e "$dir/bounded-wait-completed" ] && break; sleep 0.05; done
  [ -e "$dir/wedge-completed" ] || fail "wedge reads failed: $(cat "$dir/watcher.log")"
  [ -e "$dir/bounded-wait-completed" ] || fail 'owned wait exceeded its operation budget'
  [ ! -e "$dir/telegram.log" ] || fail 'healthy wedge reads triggered an outage'
  python3 - "$watcher" "$dir" <<'PY' || fail 'wedge reader death missed its poll deadline'
from pathlib import Path
import os, signal, sys, time
pid=int(sys.argv[1]); home=Path(sys.argv[2])
start=time.monotonic(); os.kill(pid,signal.SIGKILL)
while time.monotonic()-start < 2:
    if all(p.exists() and 'primary-supervision-lost' in p.read_text() for p in (home/'telegram.log',home/'state/.wake-queue')):
        break
    time.sleep(0.01)
else: raise SystemExit('no durable and external alert within FM_POLL=2')
PY
  wait "$watcher" 2>/dev/null || true
  wait "$checker" || fail "wedge reader health check failed: $(cat "$dir/health.log")"
  t3_fake_stop
  pass 'supervision-health: verified wedge reads refresh health, waits terminate, and reader death alerts'
}

test_health_pending_stuck() {
  local dir watcher checker i
  dir=$(health_fixture pending-stuck)
  health_pending_records "$dir"
  printf 'backend=tmux\nwindow=stuck:0\n' > "$dir/state/first.meta"
  printf 'backend=tmux\nwindow=fixture:0\n' > "$dir/state/later.meta"
  cat > "$dir/recover" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/recovery.log"
[ "$1" != first ] || sleep 30
SH
  chmod +x "$dir/recover"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    FM_PENDING_REPLY_SEND_HOOK="$dir/recover" FM_POLL=2 FM_CHECK_TIMEOUT=1 FM_SIGNAL_GRACE=0 \
    bash -c '
      . "$1/bin/fm-watch.sh"
      WATCHER_PID=$$
      mkdir "$WATCH_LOCK"
      printf "%s\n" "$$" > "$WATCH_LOCK/pid"
      fm_backend_busy_state() {
        [ "$2" != stuck:0 ] || sleep 30
        printf idle
      }
      started=$SECONDS
      fm_pending_reply_tick "$STATE" watcher_pending_reply_operation
      [ "$((SECONDS-started))" -lt 12 ] || exit 1
      fm_pending_reply_reconcile_recovery "$STATE" 0000000000000001 || exit 1
      touch "$FM_HOME/scan-completed"
      while :; do watcher_waited sleep 2; done
    ' _ "$ROOT" > "$dir/watcher.log" 2>&1 &
  watcher=$!
  for i in $(seq 1 100); do [ -e "$dir/state/.last-watcher-beat" ] && break; sleep 0.05; done
  (
    for i in $(seq 1 9); do HEALTH_TEST_POLL=2 health_run "$dir" run || exit 1; done
  ) > "$dir/health.log" 2>&1 &
  checker=$!
  for i in $(seq 1 220); do [ -e "$dir/scan-completed" ] && break; sleep 0.05; done
  [ -e "$dir/scan-completed" ] || fail "stuck operation starved the scan: $(cat "$dir/watcher.log")"
  [ ! -e "$dir/telegram.log" ] || fail 'bounded pending-reply operations caused a false outage'
  python3 - "$dir" <<'PY' || fail 'stuck operation lost recovery state or later work'
from pathlib import Path
import sys
home=Path(sys.argv[1])
assert home.joinpath('recovery.log').read_text().splitlines() == ['first','later']
def record(corr):
    return dict(line.split('=',1) for line in (home/'state/pending-replies'/corr).read_text().splitlines() if '=' in line)
first=record('0000000000000001')
assert first['phase'] == 'recovery_unknown' and first['recovery_attempted_epoch']
assert record('0000000000000002')['phase'] == 'recovery_sent'
PY
  python3 - "$watcher" "$dir" <<'PY' || fail 'pending-reply owner death missed its poll deadline'
from pathlib import Path
import os, signal, sys, time
pid=int(sys.argv[1]); home=Path(sys.argv[2])
start=time.monotonic(); os.kill(pid,signal.SIGKILL)
while time.monotonic()-start < 2:
    if all(p.exists() and 'primary-supervision-lost' in p.read_text() for p in (home/'telegram.log',home/'state/.wake-queue')):
        break
    time.sleep(0.01)
else: raise SystemExit('no durable and external alert within FM_POLL=2')
PY
  wait "$watcher" 2>/dev/null || true
  wait "$checker" || fail "pending-reply health check failed: $(cat "$dir/health.log")"
  pass 'supervision-health: stuck pending-reply operations are bounded without losing later records or uncertain recovery'
}

test_health_bootstrap_default_home
test_health_rejects_zero_poll
test_health_rejects_unused_live
test_health_incidents
test_health_real_watcher ordinary
test_health_real_watcher slow
test_health_real_watcher relaunch
test_health_real_watcher procevent
test_health_real_watcher capability
test_health_real_watcher capture-rpc
test_health_real_watcher pending-rpc
test_health_pending_stuck
test_health_wedge_reads
test_health_orphan_host
test_health_slow_endpoint
test_health_remote_work
test_health_queue_retry missing
test_health_queue_retry hang
test_health_failed_delivery missing
test_health_failed_delivery hang
test_health_install_doctor
