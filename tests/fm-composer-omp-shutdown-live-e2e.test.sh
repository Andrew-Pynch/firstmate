#!/usr/bin/env bash
# tests/fm-composer-omp-shutdown-live-e2e.test.sh - the live omp
# session-shutdown guard (live-harness-optin family; task
# fm-omp-shutdown-banner-composer).
#
# When an omp agent session ends, omp writes its own resume hint to stderr
# (`Resume this session with omp --resume <session-id>`, omp 18.1.14), and the
# user-level resume-command.js extension writes a second one on
# session_shutdown (`Resume this session: omp --resume <session-file>`).
# Measured 2026-09-15 on two wedged workers, the extension's write lands where
# the still-rendering TUI parked its cursor - the bare `❯` composer row - and
# the shared classifier read that sentence as the composer's unsubmitted text,
# so bin/fm-control.sh refused both exit and relaunch forever and the operator
# had to kill the pid by hand. The hint is vendor-rendered, so per
# .agents/skills/firstmate-coding-guidelines the byte fixtures in
# tests/fm-composer-lib.test.sh are not enough on their own: this guard takes
# the INSTALLED omp through a real shutdown and requires the shared classifier
# to reach `agent-gone` through both capability profiles that read it in
# production - the cursor-anchored tmux read (fm_tmux_composer_state) and the
# cursorless styled read Herdr and Zellij use. It fails naming omp and
# `omp --version`.
#
# The token-free half (the live idle composer still reads empty, exactly as
# before this rule) would pass on its own, but the hint itself only exists
# after omp has materialized a session, so the guard submits one minimal prompt
# to reach it. That spends model tokens, which is why the gate is opt-in:
# FM_COMPOSER_OMP_SHUTDOWN_LIVE=1 runs it (an absent omp then fails instead of
# skipping) and =0 disables it. A run that verified nothing fails rather than
# passing vacuously. Refresh docs/verification/runtime-backends.md
# ("Composer classification matrix") from this guard's output after any omp
# upgrade.
#
# The pane is a shell, exactly as fm-spawn leaves it behind every worker, so
# the shutdown frame survives the agent's exit - the same shape the operator
# reads on a real wedged pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_COMPOSER_OMP_SHUTDOWN_LIVE omp tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOCKET="fm-omp-shutdown-$$"
SESSION="ompshutdown"
WIN="omp"
SCRATCH="${TMPDIR:-/tmp}/fm-omp-shutdown-live.$$"
CHECKED=0
PROMPT='Reply with the single word: ready'

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-shutdown-live-bin.XXXXXX")
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
. "$ROOT/bin/fm-composer-lib.sh"

VERSION=$(omp --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'
OMP_BIN=$(command -v omp)

# The cursorless styled read exactly as bin/backends/herdr.sh describes its
# ANSI capture: a bounded styled tail plus the shared capability facts, with
# the lazy identity pass answered `probe-absent` because no identity probe is
# needed for a bare composer.
CAPS_CURSORLESS=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
classify_cursorless() {  # <styled-screen>
  local verdict
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1")
  if [ "$verdict" = need-identity ]; then
    verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1" '' probe-absent)
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

mkdir -p "$SCRATCH"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$SCRATCH" \
  || fail "omp ($VERSION): could not create the isolated tmux session"
# Pin the window name the same way bin/backends/tmux.sh does, so the target
# stays addressable whatever the operator's tmux config names windows.
tmux -L "$SOCKET" rename-window -t "$SESSION:" "$WIN" 2>/dev/null || true
tmux -L "$SOCKET" set-window-option -t "$SESSION:$WIN" automatic-rename off 2>/dev/null || true
tmux -L "$SOCKET" set-window-option -t "$SESSION:$WIN" allow-rename off 2>/dev/null || true
tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null \
  || fail "omp ($VERSION): the isolated tmux session did not survive creation"
# The launch mirrors bin/fm-spawn.sh's omp adapter, including the tracked
# worker overlay that pins the borderless `❯` composer shape every omp worker
# runs with; the tile is typed into a shell so the pane outlives the agent.
OMP_LAUNCH="env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 $OMP_BIN --config $ROOT/.omp/fm-worker-overlay.yml --auto-approve --cwd $SCRATCH"
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l "$OMP_LAUNCH" 2>/dev/null \
  || fail "omp ($VERSION): could not type the launch command"
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter 2>/dev/null || true

# --- Phase 1: the live idle composer is unchanged ---------------------------
# One minimal prompt is spent later, so the idle read is asserted first: the
# new rule must not disturb the verdict every ready idle omp pane already has.
budget=${FM_COMPOSER_OMP_SHUTDOWN_POLLS:-60}
i=0
tmux_verdict=''
cursorless_verdict=''
styled=''
while [ "$i" -lt "$budget" ]; do
  tmux_verdict=$(fm_tmux_composer_state "$SESSION:$WIN" 2>/dev/null || true)
  styled=$(tmux capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  cursorless_verdict=$(classify_cursorless "$styled")
  if [ "$tmux_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$tmux_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
  CHECKED=$((CHECKED + 1))
  pass "omp ($VERSION): the live idle composer classifies empty on the tmux and cursorless reads"
else
  printf '# omp pane tail at failure:\n' >&2
  printf '%s\n' "$styled" | fm_composer_strip_ansi | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "omp ($VERSION): the live idle composer never classified empty (tmux read: ${tmux_verdict:-unreadable}, cursorless styled read: ${cursorless_verdict:-unreadable})"
fi

# --- Phase 2: a real shutdown leaves the resume hint ------------------------
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l "$PROMPT" 2>/dev/null || true
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter 2>/dev/null || true
# Wait for the turn to finish: an observed busy first, then the return to an
# empty, non-busy composer. Requiring the busy observation is what makes the
# wait real - accepting idle straight after Enter would race omp's own busy
# footer and could quit a session that never materialized. Bounded, and a turn
# that never settles is a real failure rather than a silent skip.
turn_budget=${FM_COMPOSER_OMP_SHUTDOWN_TURN_POLLS:-180}
i=0
seen_busy=0
idle=no
while [ "$i" -lt "$turn_budget" ]; do
  if fm_pane_is_busy "$SESSION:$WIN" omp; then
    seen_busy=1
  elif [ "$seen_busy" = 1 ] \
       && [ "$(fm_tmux_composer_state "$SESSION:$WIN" 2>/dev/null || true)" = empty ]; then
    idle=yes
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$idle" = yes ] \
  || fail "omp ($VERSION): the one-prompt turn never settled (busy observed: $seen_busy), so the session could not be materialized"

tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l '/quit' 2>/dev/null || true
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter 2>/dev/null || true
# The pane's FOREGROUND PROCESS is the kernel fact that the agent is gone; the
# hint row is the vendor fact this rule reads. Wait for the process first, then
# for the hint, so the frame is read once omp has stopped writing to it.
exit_budget=${FM_COMPOSER_OMP_SHUTDOWN_EXIT_POLLS:-60}
i=0
while [ "$i" -lt "$exit_budget" ]; do
  case "$(tmux -L "$SOCKET" display-message -p -t "$SESSION:$WIN" '#{pane_current_command}' 2>/dev/null)" in
    bun|omp|'') i=$((i + 1)); sleep 1; continue ;;
  esac
  break
done

hint_row=''
styled=''
i=0
while [ "$i" -lt "$exit_budget" ]; do
  styled=$(tmux capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  hint_row=$(printf '%s\n' "$styled" | fm_composer_strip_ansi | grep -m1 -i -E 'resume this session' || true)
  [ -n "$hint_row" ] && break
  i=$((i + 1))
  sleep 1
done
if [ -z "$hint_row" ]; then
  printf '# omp pane tail at failure:\n' >&2
  printf '%s\n' "$styled" | fm_composer_strip_ansi | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "omp ($VERSION): the session shut down without leaving a resume hint, so this guard did not exercise the rule it exists for"
fi

tmux_verdict=$(fm_tmux_composer_state "$SESSION:$WIN" 2>/dev/null || true)
cursorless_verdict=$(classify_cursorless "$styled")
note "omp ($VERSION): shutdown hint row: $hint_row"
if [ "$cursorless_verdict" = agent-gone ] && [ "$tmux_verdict" = agent-gone ]; then
  CHECKED=$((CHECKED + 1))
  pass "omp ($VERSION): the real shutdown frame classifies agent-gone on the cursorless and tmux reads"
else
  printf '# omp pane tail at failure:\n' >&2
  printf '%s\n' "$styled" | fm_composer_strip_ansi | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "omp ($VERSION): the shutdown frame did not classify agent-gone (cursorless read: ${cursorless_verdict:-unreadable}, tmux read: ${tmux_verdict:-unreadable})"
fi

[ "$CHECKED" -gt 0 ] || fail "live omp shutdown guard verified nothing; refusing a vacuous pass"
pass "live omp shutdown guard verified $CHECKED live surface(s)"
