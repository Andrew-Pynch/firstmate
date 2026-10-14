#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version.
# omp is the exception to the typed doorbell: it is launched with the per-task
# extension bin/fm-spawn.sh writes, a draft is typed into its composer first,
# and the native doorbell must be honored while that draft stays in place.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # The omp case's spawn installs read-only git hooks under its home's state.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# omp is steered through the native doorbell its per-task extension serves
# (bin/fm-task-inbox-lib.sh header, "Native doorbell"), so it is launched the
# way bin/fm-spawn.sh launches it: the extension that script writes, loaded
# with -e, under the tracked worker overlay. A person's draft sits in the
# composer while the steer arrives; the worker must act and acknowledge, and
# the draft must still be in the composer, untouched and unsent, afterwards.
check_omp_native_doorbell() {
  local name=omp version win=hx-omp world home task=live-omp acted rec handled i fakebin
  local draft='Is the design ready for review or still' screen
  version=$(harness_version omp)
  world="$LAB/omp-world"
  home="$world/home"
  acted="$LAB/acted-omp"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[]}'
exit 0
SH
  chmod +x "$fakebin/omp"
  fm_test_spawn_home "$home" omp
  fm_git_worktree "$world/project" "$world/wt" live-omp >/dev/null
  fm_test_spawn_brief "$home" "$task"
  if ! FM_FAKE_LAUNCH_LOG="$world/launch.log" fm_test_run_spawn "$home" "$world/wt" "$fakebin" \
    "$task" "$world/project" --harness omp --scout >/dev/null || [ ! -f "$home/state/$task.omp-ext.ts" ]; then
    FAILED=1
    printf 'not ok - %s (%s): fm-spawn did not write the per-task extension\n' "$name" "$version" >&2
    return 0
  fi
  printf 'window=%s:%s\nbackend=tmux\n' "$SESSION" "$win" >> "$home/state/$task.meta"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$world/wt" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config $(printf '%q' "$ROOT/.omp/fm-worker-overlay.yml") --auto-approve --no-session -e $(printf '%q' "$home/state/$task.omp-ext.ts")" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  i=0
  while [ "$i" -lt 60 ] && [ ! -s "$home/state/$task.inbox/.native-doorbell" ]; do
    sleep 1
    i=$((i + 1))
  done
  if [ ! -s "$home/state/$task.inbox/.native-doorbell" ]; then
    FAILED=1
    printf 'not ok - %s (%s): the extension never published its native doorbell endpoint\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  wait_ready "$win" || note "$name ($version): idle composer never classified empty before the draft"
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l "$draft"
  sleep 1
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    sleep 1
    i=$((i + 1))
  done
  screen=$(tmux -L "$SOCKET" capture-pane -p -J -t "$SESSION:$win" 2>/dev/null || true)
  if [ ! -f "$handled" ] || [ ! -e "$acted" ]; then
    FAILED=1
    printf 'not ok - %s (%s): native doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  elif ! printf '%s\n' "$screen" | grep -qF "❯ $draft"; then
    FAILED=1
    printf 'not ok - %s (%s): the draft did not survive the steer in the composer\n' "$name" "$version" >&2
    printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the native doorbell reached a real worker, which acted and acked, and the draft stayed in the composer"
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse omp'}
for h in $HARNESSES; do
  if ! command -v "$h" >/dev/null 2>&1; then
    note "harness absent, not verified here: $h"
  elif [ "$h" = omp ]; then
    check_omp_native_doorbell
  else
    check_harness_doorbell "$h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
