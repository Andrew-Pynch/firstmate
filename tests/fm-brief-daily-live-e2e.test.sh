#!/usr/bin/env bash
# Default-on live guard for the vendor seam omp's `/bearings` prints the daily
# brief through: an omp primary must route the bare `/bearings` slash command to
# .omp/extensions/fm-primary-bearings.ts and render the brief in the transcript
# without invoking the model.
#
# Why this needs a real omp: command routing and custom-message rendering are
# omp's own surfaces. A fake API can only confirm the shape this repository
# already believes in, which is exactly the assumption a release note could
# invalidate. The guard drives the installed omp through its rpc stdio mode and
# checks that the prompt settles with no agent turn, so it costs no tokens and
# runs wherever omp is installed.
#
# The brief's own text, ranking and counting are not this guard's subject:
# tests/fm-brief-daily.test.sh proves those against fixtures. Here the brief is a
# constant, so a failure names the vendor seam rather than a ranking rule.
#
# Run it after every omp upgrade: the extension loader, the command router and
# the rpc frame shape are all vendor surfaces, not Firstmate contracts.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_BRIEF_DAILY_LIVE_E2E omp jq

OMP_VERSION=$(omp --version 2>/dev/null || true)

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-brief-daily-live.XXXXXX")
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# A firstmate-shaped home with the brief command stubbed at the path the
# extension resolves by default, and an isolated agent directory so no personal
# extension contributes a frame.
LAB="$TMP_ROOT/home"
AGENT_DIR="$TMP_ROOT/agent"
mkdir -p "$LAB/.omp/extensions" "$LAB/.pi/extensions/lib" "$LAB/bin" "$AGENT_DIR"
cp "$ROOT/.omp/extensions/fm-primary-bearings.ts" "$LAB/.omp/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$LAB/.pi/extensions/lib/"
cat > "$LAB/bin/fm-brief-daily.sh" <<'SH'
#!/usr/bin/env bash
printf 'Next: decide top-row - Top Row\n\nChecked 2026-06-01T00:00:00Z from lab\n'
SH
chmod +x "$LAB/bin/fm-brief-daily.sh"

# One rpc session: wait for the extension to load, send the bare command, hold
# the session open long enough for the brief to land, then close it. FM_TASK_ID
# is dropped because the guard may be running inside a worker pane, where the
# extension deliberately registers nothing.
frames=$( (sleep 3; printf '{"id":"brief","type":"prompt","message":"/bearings"}\n'; sleep 5) |
  timeout 60 env -u FM_TASK_ID OMP_SKIP_SETUP=1 PI_CODING_AGENT_DIR="$AGENT_DIR" \
    omp --mode rpc --no-session --cwd "$LAB" 2>"$TMP_ROOT/err")

brief=$(printf '%s\n' "$frames" |
  jq -c 'select(.type == "message_end" and .message.customType == "firstmate-daily-brief") | .message' | head -1)
[ -n "$brief" ] || fail "omp $OMP_VERSION rendered no daily brief for /bearings (stderr: $(tail -3 "$TMP_ROOT/err" 2>/dev/null | tr '\n' ' '))"
[ "$(printf '%s' "$brief" | jq -r '.content')" = "$(printf 'Next: decide top-row - Top Row\n\nChecked 2026-06-01T00:00:00Z from lab')" ] ||
  fail "omp $OMP_VERSION rendered the wrong brief: $brief"
[ "$(printf '%s' "$brief" | jq -r '.display')" = "true" ] ||
  fail "omp $OMP_VERSION kept the brief out of the transcript: $brief"
pass "omp $OMP_VERSION: /bearings renders the daily brief in the transcript"

result=$(printf '%s\n' "$frames" | jq -c 'select(.type == "prompt_result" and .id == "brief")' | head -1)
[ -n "$result" ] || fail "omp $OMP_VERSION never settled the /bearings prompt"
[ "$(printf '%s' "$result" | jq -r '.agentInvoked')" = "false" ] ||
  fail "omp $OMP_VERSION invoked the model for /bearings: $result"
pass "omp $OMP_VERSION: /bearings settles without a model turn"
