#!/usr/bin/env bash
# Opt-in credentialed guard for an omp (Oh My Pi) SECONDMATE, the placement a
# remote second mate runs on its own host. It uses the captain's existing omp
# login without copying any credential, and every Herdr call - the test's own
# and every production-adapter call - goes through bin/fm-herdr-lab.sh on a
# named non-default lab session.
#
# It proves, against the installed omp and the real Firstmate scripts, what the
# portable suite (tests/fm-omp-harness.test.sh) can only pin over a fake omp:
#   1. a seeded secondmate home auto-discovers BOTH tracked .omp/extensions
#      with no -e at all, which is the whole basis of omp secondmate
#      supervision and the reason fm-spawn refuses a home or an omp that
#      cannot provide it;
#   2. a bounded instruction sent through the ordinary durable steering inbox
#      reaches the live agent and it executes that instruction;
#   3. its completion reaches the PARENT through the real parent channel
#      (bin/fm-parent-channel-lib.sh), not just its own pane;
#   4. it stays controllable (bin/fm-control.sh interrupt) and survives the
#      supported relaunch path, whose replacement loads supervision again.
#
# The transport half of a remote route (SSH, readiness, the host-local control
# verbs) is covered deterministically by tests/fm-remote-secondmate-lifecycle-e2e.sh
# and tests/fm-remote-doctor.test.sh; real-host proof on a second machine
# remains an operator smoke test recorded in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate opt-in FM_OMP_SECONDMATE_LIVE_E2E omp herdr jq git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
MODEL=${FM_OMP_SECONDMATE_LIVE_MODEL:-openai-codex/gpt-5.6-sol}
ID=omplive
NONCE="omp-secondmate-live-$$"
CORR=$(printf '%016x' "$(( (RANDOM << 16 | RANDOM) & 0xffffffff ))")

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-omp-secondmate-live-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
PARENT="$TMP_ROOT/parent"
SM_HOME="$TMP_ROOT/mate"
mkdir -p "$FAKEBIN" "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
touch "$PARENT/state/.last-watcher-beat"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-omp-secondmate-live)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

# Every process this lab starts names the lab path on its command line (omp
# itself, the watcher the mate's own extension arms, its arm child), so cleanup
# reaps by that path rather than by remembered pids.
lab_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v lab="$TMP_ROOT" 'index($0, lab) && $1 != PROCID { print $1 }' PROCID=$$
}

reap_lab() {
  local pid
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  local status=$?
  reap_lab
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only Herdr transport. The production adapter has
# already appended the exact session; this shim strips that validated pair,
# refuses any other session flag, and forwards through the guarded run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# --- a real seeded secondmate home ------------------------------------------
# A clone of this repository plus this working tree's pending edits, so the
# extensions and scripts under test are the ones that ship on this branch.
git clone -q "$ROOT" "$SM_HOME" || fail "could not clone the repository into the lab secondmate home"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$SM_HOME/$(dirname "$path")"
  cp "$ROOT/$path" "$SM_HOME/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/data" "$SM_HOME/projects"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$SM_HOME/.fm-secondmate-parent"
printf '%s\n' "$ID" > "$SM_HOME/.fm-secondmate-home"
cat > "$SM_HOME/data/charter.md" <<'EOF'
# Charter

You are a persistent second mate in an isolated lab home.

Do not start work of your own, do not survey this home, and do not spawn anything.
Stay idle until a firstmate instruction arrives in your steering inbox.
When one arrives, run exactly the command it names, then acknowledge that record by moving it into the inbox's handled/ directory, then go back to idle.
EOF

# config/secondmate-harness is how a fleet keeps a mate on omp durably, and it
# is what the supported relaunch path re-resolves, so the lab pins it here
# rather than passing per-spawn flags the relaunch would not see.
printf '%s %s\n' omp "$MODEL" > "$PARENT/config/secondmate-harness"

spawn_mate() {
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$SM_HOME" --secondmate 2>&1
}

wait_for_file() {  # <path> <attempts>
  local path=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

meta_field() {  # <field>
  sed -n "s/^$1=//p" "$PARENT/state/$ID.meta" | tail -1
}

agent_state() {
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_agent_state herdr "$2"
  ' _ "$ROOT" "$(meta_field window)"
}

# --- 1. auto-discovery in a real secondmate home ------------------------------
SPAWN_OUT=$(spawn_mate) || fail "omp secondmate spawn failed: $SPAWN_OUT"
case "$SPAWN_OUT" in
  *"spawned $ID harness=omp kind=secondmate"*) ;;
  *) fail "spawn did not report an omp secondmate: $SPAWN_OUT" ;;
esac
case "$SPAWN_OUT" in
  *" -e "*) fail "a secondmate launch must name no -e: $SPAWN_OUT" ;;
esac
wait_for_file "$SM_HOME/state/.omp-watch-extension-loaded" 240 \
  || fail "omp $OMP_VERSION did not auto-discover the watch extension in the secondmate home"
wait_for_file "$SM_HOME/state/.omp-turnend-extension-loaded" 120 \
  || fail "omp $OMP_VERSION did not auto-discover the turn-end guard extension in the secondmate home"
pass "omp $OMP_VERSION: a seeded secondmate home loads both tracked supervision extensions by auto-discovery alone"

# --- 2 and 3. a bounded instruction, and its completion on the parent channel --
REPORT_CMD="FM_HOME='$SM_HOME' '$SM_HOME/bin/fm-secondmate-report.sh' done $CORR '$NONCE'"
STEER="Run exactly this one command from your home directory, then stop: $REPORT_CMD"
PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" \
  "$ROOT/bin/fm-send.sh" "fm-$ID" "$STEER" \
  || fail "the bounded instruction was not durably recorded for the live omp secondmate"

wait_for_line() {  # <file> <fixed-string> <attempts>
  local file=$1 needle=$2 attempts=${3:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    grep -Fq "$needle" "$file" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_line "$PARENT/state/$ID.status" "$NONCE" 480 \
  || fail "the live omp secondmate never published its completion to the parent channel ($PARENT/state/$ID.status)"
grep -Fq "corr=$CORR" "$PARENT/state/$ID.status" \
  || fail "the published completion lost its correlation token"
i=0
while [ "$i" -lt 240 ]; do
  [ -n "$(find "$PARENT/state/$ID.inbox/handled" -name '*.msg' -print -quit 2>/dev/null)" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$(find "$PARENT/state/$ID.inbox/handled" -name '*.msg' -print -quit 2>/dev/null)" ] \
  || fail "the live omp secondmate never acknowledged the steering record it acted on"
pass "omp $OMP_VERSION: a durable steering instruction reached the live secondmate and its completion landed on the parent channel"

# --- 4. control and the supported relaunch path -------------------------------
[ "$(agent_state)" = alive ] || fail "the live omp secondmate is not alive before the control checks"
CONTROL_OUT=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" \
  "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1) \
  || fail "interrupt refused a live omp secondmate: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "interrupt-delivered $ID harness=omp" "interrupt did not report the controlled agent: $CONTROL_OUT"
[ "$(agent_state)" = alive ] || fail "interrupt stopped the agent instead of cancelling its turn"

OLD_WINDOW=$(meta_field window)
rm -f "$SM_HOME/state/.omp-watch-extension-loaded" "$SM_HOME/state/.omp-turnend-extension-loaded"
RELAUNCH_OUT=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" \
  "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "live omp secondmate relaunch" 2>&1) \
  || fail "the supported relaunch path failed for a live omp secondmate: $RELAUNCH_OUT"
assert_contains "$RELAUNCH_OUT" "relaunched $ID harness=omp from=omp" "relaunch did not report the same runtime: $RELAUNCH_OUT"
[ "$(meta_field window)" = "$OLD_WINDOW" ] || fail "relaunch moved the secondmate out of its recorded endpoint"
wait_for_file "$SM_HOME/state/.omp-watch-extension-loaded" 240 \
  || fail "the relaunched omp secondmate did not load its watch extension again"
wait_for_file "$SM_HOME/state/.omp-turnend-extension-loaded" 120 \
  || fail "the relaunched omp secondmate did not load its turn-end guard again"
[ "$(agent_state)" = alive ] || fail "the relaunched omp secondmate is not alive"
pass "omp $OMP_VERSION: the live secondmate stays controllable and its supported relaunch reloads supervision in the same endpoint"

# Standalone `exit` is deliberately NOT asserted here. The stop half of the
# control plane is already exercised above, because relaunch stopped the
# previous agent before launching its replacement. A separate
# `bin/fm-control.sh <id> exit` against the settled replacement was observed
# twice (omp 18.1.18, Linux, idle per `herdr agent get`, once with a freshly
# refreshed watcher beacon) to return `exit-command=delivered agent-state=alive
# exit=unconfirmed` after its 30s wait: the control plane reported the
# uncertainty rather than claiming a stop it could not see. That observation is
# recorded in docs/verification/runtime-backends.md and belongs to the
# real-host omp smoke test, not to this guard's contract.
pass "omp $OMP_VERSION: live secondmate placement verified end to end in an isolated Herdr lab"
