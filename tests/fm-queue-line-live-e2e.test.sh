#!/usr/bin/env bash
# Default-on live guard for the vendor seam the always-visible line is pinned
# through: an omp primary must accept one line pinned above the editor and must
# accept clearing it.
#
# Why this needs a real omp: the surface is omp's own. ctx.ui.setWidget is a
# vendor API with a vendor placement vocabulary, and only the installed harness
# can say whether the extension is discovered, whether the widget reaches the
# surface, and whether clearing it removes the pin. A fake context can only
# confirm the shape this repository already believes in, which is exactly the
# assumption a release note could invalidate. The guard drives the installed omp
# through its rpc stdio mode with no prompt and no model call, so it costs no
# tokens and runs wherever omp is installed.
#
# The line's own text, ordering and counting are not this guard's subject:
# tests/fm-queue-line.test.sh proves those against fixtures. Here the pinned text
# is a constant, so a failure names the vendor seam rather than a counting rule.
#
# Run it after every omp upgrade: the extension loader, the widget placement and
# the rpc frame shape are all vendor surfaces, not Firstmate contracts.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_QUEUE_LINE_LIVE_E2E omp jq

OMP_VERSION=$(omp --version 2>/dev/null || true)

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-queue-line-live.XXXXXX")
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# A firstmate-shaped home: the extension and its helper at their tracked paths,
# and the line command at the path the extension resolves by default. The command
# is a stub because the real one is proved elsewhere and would make this guard
# depend on the whole fleet. The agent directory is isolated so the guard reads
# nothing of the captain's own omp home and its frames do not depend on whatever
# personal extensions are installed there.
LAB="$TMP_ROOT/home"
AGENT_DIR="$TMP_ROOT/agent"
mkdir -p "$LAB/.omp/extensions" "$LAB/.pi/extensions/lib" "$LAB/bin" "$AGENT_DIR"
cp "$ROOT/.omp/extensions/fm-primary-queue-line.ts" "$LAB/.omp/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$LAB/.pi/extensions/lib/"
cat > "$LAB/bin/fm-queue-line.sh" <<'SH'
#!/usr/bin/env bash
case "${FM_LINE_MODE:?}" in
  waiting) printf '⧗ waiting on you (3): top-row - Top Row (+2 more)\n' ;;
  empty) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$LAB/bin/fm-queue-line.sh"

# One rpc session per mode, held open long enough for the session-start read to
# land, then closed so omp disposes the session itself. FM_TASK_ID is dropped
# because the guard may be running inside a worker pane, where the extension
# deliberately renders nothing.
session_frames() {  # <mode>
  local mode=$1
  (cd "$LAB" && sleep 8) | timeout 60 env -u FM_TASK_ID OMP_SKIP_SETUP=1 PI_CODING_AGENT_DIR="$AGENT_DIR" \
    FM_LINE_MODE="$mode" omp --mode rpc --no-session --cwd "$LAB" 2>"$TMP_ROOT/err.$mode"
}

widget_frame() {  # <mode>
  session_frames "$1" |
    jq -c 'select(.type == "extension_ui_request" and .method == "setWidget" and .widgetKey == "firstmate-queue-line")' |
    head -1
}

expected='⧗ waiting on you (3): top-row - Top Row (+2 more)'
pinned=$(widget_frame waiting)
[ -n "$pinned" ] || fail "omp $OMP_VERSION emitted no setWidget frame for firstmate-queue-line; the pinned line would never appear (stderr: $(tail -3 "$TMP_ROOT/err.waiting" 2>/dev/null | tr '\n' ' '))"
[ "$(printf '%s' "$pinned" | jq -r '.widgetLines[0]')" = "$expected" ] ||
  fail "omp $OMP_VERSION pinned the wrong line: $pinned"
[ "$(printf '%s' "$pinned" | jq -r '.widgetPlacement')" = "aboveEditor" ] ||
  fail "omp $OMP_VERSION pinned the line somewhere other than above the editor: $pinned"
pass "omp $OMP_VERSION: a waiting queue pins one line above the editor"

cleared=$(widget_frame empty)
[ -n "$cleared" ] || fail "omp $OMP_VERSION emitted no setWidget frame when nothing waited, so the pin could never be removed"
[ "$(printf '%s' "$cleared" | jq -r 'has("widgetLines")')" = "false" ] ||
  fail "omp $OMP_VERSION kept a pinned line when nothing was waiting: $cleared"
pass "omp $OMP_VERSION: nothing waiting clears the pin instead of leaving a stale line"
