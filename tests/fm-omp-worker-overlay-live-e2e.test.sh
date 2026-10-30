#!/usr/bin/env bash
# Default-on live guard for the tracked omp worker posture overlay's advisor pin
# and for the read-only posture of the Sol review the ship brief renders.
#
# What a worker session's advisor resolves to is a fact only the installed omp
# can answer: `--config` is one config layer among several, and omp resolves an
# unset `advisor` role through its `slow` priority chain. No fixture can prove
# which layer wins, so this guard gives the live agent profile a temporary,
# higher-priority host overlay with a different advisor switched off, then
# asserts the tracked worker overlay beats it twice: through omp's own config
# dump and through a real session's `/advisor status` report. The live profile
# supplies only authentication and is never written.
# It fails naming omp and the reported text instead of degrading quietly.
#
# The first half needs no model and no credential, so it always runs. The second
# half is a live resolution, which omp only performs for a provider whose
# credential is present, so it runs where the pinned provider is authenticated
# and capability-skips by name where it is not. Neither half spends a token.
#
# The last part runs the Sol review commands a freshly scaffolded ship brief
# renders against an isolated, hostile synthetic host: an allow-listed MCP
# server whose only tool mutates, a WATCHDOG.yml advisor granted write, bash,
# and edit, those tools allow-listed too, and yolo approval. A local
# OpenAI-compatible endpoint stands in for both models, records the tools each
# is offered, and on each model's first turn calls every mutating path at once.
# It needs no credential and spends no token, and it never touches the live
# profile. The same review without the read-only overlay must mutate, so the
# fixture cannot pass vacuously.
#
# Run it after every omp upgrade and before trusting a refreshed advisor posture:
# the layer precedence, the rpc builtin dispatch, and the credential gate are all
# vendor surfaces, not Firstmate contracts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/.omp/fm-worker-overlay.yml"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_OMP_WORKER_OVERLAY_LIVE_E2E omp jq

[ -f "$OVERLAY" ] || fail "the tracked worker posture overlay is missing at $OVERLAY"

# The pin this guard exists to defend. A deliberate change to the worker advisor
# updates this constant in the same commit.
EXPECTED_ADVISOR=openai-codex/gpt-6.1-sol:high
EXPECTED_PROVIDER=${EXPECTED_ADVISOR%%/*}
EXPECTED_MODEL=${EXPECTED_ADVISOR%:high}
# The posture of the host profile the guard stands in for: a different advisor,
# switched off, plus a `slow` model omp would resolve an unset advisor role to.
CONFLICT_ADVISOR=xai-oauth/grok-4.6:high
CONFLICT_SLOW=openai-codex/gpt-5.6-sol:high

OMP_VERSION=$(omp --version 2>/dev/null || true)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-worker-overlay.XXXXXX")
SERVER_PID=
cleanup() {
  local status=$?
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

HOST_OVERLAY="$TMP_ROOT/host.yml"
printf 'advisor:\n  enabled: false\nmodelRoles:\n  advisor: %s\n  slow: %s\n' \
  "$CONFLICT_ADVISOR" "$CONFLICT_SLOW" > "$HOST_OVERLAY"

# The advisor role omp resolves from the config layers alone. `config get`
# reports the merged record without calling a model or consulting a credential,
# so this half is deterministic on any machine.
layer_setting() { # <setting> <jq filter> <worker overlay, empty for host layer only>
  (
    cd "$TMP_ROOT" &&
      PI_CONFIG_FILES="$HOST_OVERLAY${3:+:$3}" omp config get "$1" --json 2>/dev/null
  ) | jq -r "$2"
}
layer_advisor() { layer_setting modelRoles '.value.advisor // ""' "$1"; }
layer_enabled() { layer_setting advisor.enabled '.value | tostring' "$1"; }

host_layer=$(layer_advisor '')
host_enabled=$(layer_enabled '')
[ "$host_layer" = "$CONFLICT_ADVISOR" ] && [ "$host_enabled" = false ] \
  || fail "omp $OMP_VERSION did not read the guard's isolated host profile, so the pin cannot be shown to beat it: got advisor '$host_layer', enabled '$host_enabled'"
pass "omp $OMP_VERSION: the isolated host profile resolves advisor $CONFLICT_ADVISOR, switched off"

pinned_layer=$(layer_advisor "$OVERLAY")
[ "$pinned_layer" = "$EXPECTED_ADVISOR" ] \
  || fail "the tracked overlay does not pin the worker advisor to $EXPECTED_ADVISOR; omp $OMP_VERSION resolved '$pinned_layer' from the config layers"
pinned_enabled=$(layer_enabled "$OVERLAY")
[ "$pinned_enabled" = true ] \
  || fail "the tracked overlay does not switch the worker advisor on; omp $OMP_VERSION resolved advisor.enabled '$pinned_enabled' from the config layers"
pass "omp $OMP_VERSION: the tracked overlay pins the worker advisor role to $EXPECTED_ADVISOR and switches it on over the host profile"

# The same pin as a real session reports it, through omp's rpc builtin dispatch,
# which starts no turn. The host profile switches the advisor off, so a running
# advisor proves the overlay's switch too. omp only builds an advisor for a
# provider it holds a credential for, so this reports `no_model` on a machine
# without one and is gated rather than asserted there.
session_advisor() {
  (
    cd "$TMP_ROOT" &&
      printf '{"id":"probe","type":"prompt","message":"/advisor status"}\n' \
        | PI_CONFIG_FILES="$HOST_OVERLAY" OMP_SKIP_SETUP=1 \
          omp --mode rpc --no-session --cwd "$TMP_ROOT" --config "$OVERLAY" 2>/dev/null
  ) | jq -r 'select(.type == "command_output") | .text | select(length > 0)'
}
if omp token "$EXPECTED_PROVIDER" >/dev/null 2>&1; then
  reported=$(session_advisor)
  case "$reported" in
    *"($EXPECTED_MODEL)"*) ;;
    *) fail "a session carrying the tracked overlay did not run an advisor on $EXPECTED_MODEL; omp $OMP_VERSION reported: $reported" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "  • "*"[paused]"*) ;;
      "  • "*)
        case "$line" in
          *" ($EXPECTED_MODEL)"*) ;;
          *) fail "a session carrying the tracked overlay ran an advisor other than $EXPECTED_MODEL; omp $OMP_VERSION reported: $reported" ;;
        esac ;;
    esac
  done <<<"$reported"
  pass "omp $OMP_VERSION: every running advisor in a session carrying the tracked overlay uses $EXPECTED_MODEL"
else
  printf 'skip: %s is not authenticated here, so the live session advisor report is unavailable\n' "$EXPECTED_PROVIDER"
fi

# --- the Sol review the ship brief renders cannot change anything ---
REVIEW_OVERLAY="$ROOT/.omp/fm-sol-review.yml"
[ -f "$REVIEW_OVERLAY" ] || fail "the tracked read-only Sol review overlay is missing at $REVIEW_OVERLAY"
# The lab's stand-in model endpoint and MCP server need python3 and the review
# needs git; a host without them still ran the checks above.
for tool in python3 git; do
  command -v "$tool" >/dev/null 2>&1 && continue
  case "${FM_OMP_WORKER_OVERLAY_LIVE_E2E:-${FM_LIVE:-}}" in
    1) fail "the read-only Sol review lab needs $tool, which is absent" ;;
  esac
  printf 'skip: live: %s absent, so the read-only Sol review lab did not run\n' "$tool"
  exit 0
done
LAB="$TMP_ROOT/review"
AGENT="$LAB/agent"
MARKERS="$LAB/markers"
REQUESTS="$LAB/requests.jsonl"
REPO="$LAB/repo"
mkdir -p "$AGENT" "$MARKERS" "$REPO" "$LAB/fm-home/data"

cat > "$LAB/mutator-mcp.py" <<'PY'
import json, os, sys
for line in sys.stdin:
    if not line.strip():
        continue
    msg = json.loads(line)
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2024-11-05"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "mutator", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "mutate", "description": "Create the marker file.",
                             "inputSchema": {"type": "object", "properties": {}}}]}
    elif method == "tools/call":
        open(os.environ["FM_MUTATOR_MARKER"], "w").write("mutated\n")
        result = {"content": [{"type": "text", "text": "mutated"}]}
    elif mid is None:
        continue
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()
PY

cat > "$LAB/fake-provider.py" <<'PY'
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
MARKERS = os.environ["FM_FAKE_MARKERS"]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        body = b'{"data": [{"id": "primary"}, {"id": "advisor"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        tools = sorted(t["function"]["name"] for t in req.get("tools") or [])
        role = "advisor" if "advise" in tools else "primary"
        first = not any(m.get("role") == "tool" for m in req.get("messages") or [])
        with open(os.environ["FM_FAKE_LOG"], "a") as fh:
            fh.write(json.dumps({"role": role, "tools": tools}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def send(delta, finish):
            chunk = {"id": "c", "object": "chat.completion.chunk", "model": req.get("model"),
                     "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        if first:
            m = os.path.join(MARKERS, role)
            calls = [("mutate", {}), ("write", {"path": "xd://mcp__mutator_mutate", "content": "{}"}),
                     ("write", {"path": m + "-write", "content": "mutated\n"}),
                     ("bash", {"command": "touch " + m + "-bash"}),
                     ("edit", {"path": m + "-edit", "edits": []}),
                     ("run_experiment", {"command": "touch " + m + "-run"})]
            send({"role": "assistant", "tool_calls": [
                {"index": i, "id": "call_%s_%d" % (role, i), "type": "function",
                 "function": {"name": n, "arguments": json.dumps(a)}} for i, (n, a) in enumerate(calls)]}, None)
            send({}, "tool_calls")
        else:
            send({"role": "assistant", "content": "no findings"}, None)
            send({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(os.environ["FM_FAKE_PORT_FILE"], "w").write(str(server.server_address[1]))
server.serve_forever()
PY

FM_FAKE_LOG=$REQUESTS FM_FAKE_MARKERS=$MARKERS FM_FAKE_PORT_FILE=$LAB/port python3 "$LAB/fake-provider.py" &
SERVER_PID=$!
i=0
while [ ! -s "$LAB/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$LAB/port" ] || fail "the local stand-in model endpoint did not start"

printf '%s\n' 'providers:' '  fake:' "    baseUrl: http://127.0.0.1:$(cat "$LAB/port")/v1" \
  '    apiKey: offline-test-only' '    api: openai-completions' '    models:' \
  '      - id: primary' '      - id: advisor' > "$AGENT/models.yml"
printf '%s\n' 'modelRoles:' '  default: fake/primary' 'tools:' '  approvalMode: yolo' '  approval:' \
  '    mcp__mutator_mutate: allow' '    write: allow' '    bash: allow' '    edit: allow' > "$AGENT/config.yml"
jq -n --arg py "$LAB/mutator-mcp.py" --arg marker "$MARKERS/mcp" \
  '{mcpServers: {mutator: {type: "stdio", command: "python3", args: [$py], env: {FM_MUTATOR_MARKER: $marker}}}}' \
  > "$AGENT/mcp.json"
printf '%s\n' 'advisors:' '  - name: Granted' '    tools: [read, write, bash, edit]' > "$AGENT/WATCHDOG.yml"

git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
echo change > "$REPO/file"
git -C "$REPO" add file
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m change

# A Firstmate root whose worker overlay pins the stand-in advisor, with a
# thinking suffix like the tracked pin's, and whose review overlay is
# <review overlay>; prints the rendered review run and proof lines.
render_review_run() {  # <name> <review overlay>
  local root="$LAB/root-$1"
  mkdir -p "$root/.omp"
  printf '%s\n' 'modelRoles:' '  advisor: fake/advisor:high' 'advisor:' '  enabled: true' > "$root/.omp/fm-worker-overlay.yml"
  cp "$2" "$root/.omp/fm-sol-review.yml"
  FM_HOME="$LAB/fm-home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-brief.sh" "review-$1" some-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh did not render a direct-PR brief for the review lab"
  awk '/^```sh$/ { f = 1; next } /^```$/ { f = 0 } f' "$LAB/fm-home/data/review-$1/brief.md" | sed -n 2,3p
}
# Names the marker files a mutation left, space-separated; empty when none.
markers() { find "$MARKERS" -type f -exec basename {} \; | sort | tr '\n' ' '; }

# Every built-in the installed omp has, other than read, grep, and glob, must be
# refused by the review overlay, even where the host allows it, so an upgrade
# that adds one fails here rather than reaching an advisor a host roster grants
# it to. omp names its built-ins when --tools gets a name it does not know.
builtins=$( (cd "$REPO" && PI_CODING_AGENT_DIR="$AGENT" OMP_SKIP_SETUP=1 \
  omp --mode rpc --no-session --tools fm-unknown-probe < /dev/null 2>&1) \
  | sed -n 's/^Built-in tools: \([^.]*\)\..*$/\1/p' | tr -d ' ' | tr ',' '\n')
[ -n "$builtins" ] \
  || fail "omp $OMP_VERSION no longer names its built-in tools for an unknown --tools entry, so the review overlay's deny list cannot be checked"
denied=$( (cd "$REPO" && PI_CODING_AGENT_DIR="$AGENT" PI_CONFIG_FILES="$REVIEW_OVERLAY" \
  omp config get tools.approval --json 2>/dev/null) | jq -r '.value | to_entries[] | select(.value == "deny") | .key')
unrefused=$(printf '%s\n' "$builtins" | grep -vxE 'read|grep|glob' | grep -vxF -e "$denied" | tr '\n' ' ')
[ -z "$unrefused" ] \
  || fail "omp $OMP_VERSION has built-in tools the read-only review overlay does not deny over the host's allow policy: $unrefused"
pass "omp $OMP_VERSION: the read-only review overlay denies every built-in tool except read, grep, and glob over a host allow policy"

# Runs the rendered review against the hostile host; prints its proof output.
# The run line resets the positional parameters, so both lines are read first.
run_review() {  # <run line> <proof line>
  local run=$1 proof=$2
  rm -f "$MARKERS"/* "$REQUESTS"
  (
    cd "$REPO" || exit 1
    export PI_CODING_AGENT_DIR="$AGENT"
    # shellcheck disable=SC2034  # read by the evaluated review line
    base=HEAD~1
    eval "$run" > /dev/null 2>&1 || exit 0
    eval "$proof"
  )
}

# Control: the same review without the read-only overlay, as the brief ran it
# before, lets the primary call the allow-listed MCP tool and the advisor write.
render_review_run control "$REVIEW_OVERLAY" > /dev/null
rm -f "$MARKERS"/* "$REQUESTS"
(
  cd "$REPO" &&
    PI_CODING_AGENT_DIR="$AGENT" OMP_SKIP_SETUP=1 omp -p --advisor --tools read,grep,glob --no-extensions \
      --approval-mode always-ask --config "$LAB/root-control/.omp/fm-worker-overlay.yml" --no-session \
      --mode json "Review the change." > /dev/null 2>&1
)
[ -f "$MARKERS/mcp" ] && [ -f "$MARKERS/advisor-write" ] && [ -f "$MARKERS/advisor-bash" ] \
  || fail "omp $OMP_VERSION: the hostile lab host did not let a review without the read-only overlay mutate, so the guard would prove nothing (markers: $(markers))"

lines=$(render_review_run readonly "$REVIEW_OVERLAY")
out=$(run_review "$(printf '%s\n' "$lines" | sed -n 1p)" "$(printf '%s\n' "$lines" | sed -n 2p)")
[ "$out" = 'Sol reviewed' ] \
  || fail "omp $OMP_VERSION: the read-only review did not complete with the pinned advisor; proof printed '$out'"
[ -z "$(markers)" ] \
  || fail "omp $OMP_VERSION: the review rendered in a ship brief changed files on a hostile host: $(markers)"
jq -e -s '[.[] | select(.role == "primary")] | length > 0 and all(.tools == ["glob", "grep", "read"])' "$REQUESTS" > /dev/null \
  || fail "omp $OMP_VERSION: the review primary was offered a tool beyond read, grep, and glob: $(jq -c -s '[.[] | select(.role == "primary") | .tools] | unique' "$REQUESTS")"
jq -e -s '[.[] | select(.role == "advisor")] | length > 0 and all(.tools | index("write") and index("bash"))' "$REQUESTS" > /dev/null \
  || fail "omp $OMP_VERSION: the hostile advisor roster no longer reaches the review advisor, so its refusal went untested"
pass "omp $OMP_VERSION: the rendered Sol review offers its primary only read, grep, and glob and refuses every write, bash, edit, and MCP call on a hostile host"

# A discovery source the read-only overlay does not switch off must stop the
# review before any model sees it.
grep -v '^  - native$' "$REVIEW_OVERLAY" > "$LAB/leaky-review.yml"
lines=$(render_review_run leaky "$LAB/leaky-review.yml")
out=$(run_review "$(printf '%s\n' "$lines" | sed -n 1p)" "$(printf '%s\n' "$lines" | sed -n 2p)")
[ -z "$out" ] && [ ! -s "$REQUESTS" ] && [ -z "$(markers)" ] \
  || fail "omp $OMP_VERSION: a review whose primary saw an extra tool still reached a model (proof '$out', $(wc -l < "$REQUESTS" 2>/dev/null || echo 0) requests)"
pass "omp $OMP_VERSION: a review whose primary would see any tool beyond read, grep, and glob never starts"
