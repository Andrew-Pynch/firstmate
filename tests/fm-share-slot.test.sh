#!/usr/bin/env bash
# tests/fm-share-slot.test.sh - bin/fm-share.sh share-slot: a running Pilot slot is served on the tailnet over plain
# http at its own web and Convex ports, a port served another way is never replaced, a slot that is not up or whose
# backend does not answer is refused, the printout is a one-account grant and policy test (never autogroup:shared),
# and the Deck offers "share slot" on cards naming a Pilot link, behind the page token, for the slots it offered.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-share-slot)
HOME_DIR="$TMP_ROOT/home"
PAGE_DIR="$HOME_DIR/data/page"
mkdir -p "$HOME_DIR/state" "$PAGE_DIR" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_CURRENT_PAGE_NO_FORGE=1 FM_CURRENT_PAGE_HOST=ron-test
export FM_SHARE_ROOT="$TMP_ROOT/share" FM_SHARE_RECORDS="$TMP_ROOT/records"
unset FM_SHARE_ORIGIN FM_SHARE_LISTEN FM_LINEAR_API_KEY
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
SERVE_JSON="$TMP_ROOT/serve.json" SERVE_LOG="$TMP_ROOT/serve.log"
printf '{}\n' > "$SERVE_JSON"
: > "$SERVE_LOG"
# A tailscale that answers status for this machine (MagicDNS name localhost, so the tailnet checks reach the fakes)
# and keeps its serve config in a file.
cat > "$FAKEBIN/tailscale" <<SH
#!/usr/bin/env bash
case "\$*" in
  "status --self --json") echo '{"Self":{"DNSName":"localhost.","UserID":1}}' ;;
  "status --json") echo '{"Self":{"DNSName":"localhost.","UserID":1},"User":{"1":{"LoginName":"me@github"},"2":{"LoginName":"T-Ev@github"}}}' ;;
  "serve status --json") cat "$SERVE_JSON" ;;
  "serve --bg --http="*)
    echo "\$*" >> "$SERVE_LOG"
    python3 - "$SERVE_JSON" "\$3" "\$4" <<'PY'
import json, sys
path, flag, target = sys.argv[1:]
port = flag.split("=", 1)[1]
d = json.load(open(path))
d.setdefault("TCP", {})[port] = {"HTTP": True}
d.setdefault("Web", {})["localhost:" + port] = {"Handlers": {"/": {"Proxy": target}}}
json.dump(d, open(path, "w"))
PY
    ;;
  *) echo "fake tailscale: unexpected \$*" >&2; exit 9 ;;
esac
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/tailscale"
export PATH="$FAKEBIN:$PATH"

# Move every slot port to a free block so slot 2 is ours and slot 4 is down.
OFFSET=$(python3 - <<'PY'
import random, socket
def free(p):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); return True
    except OSError:
        return False
    finally:
        s.close()
for _ in range(200):
    off = random.randrange(20000, 50000, 1000)
    if all(free(off + b + 100 * n) for b in (5173, 3210) for n in range(5)):
        print(off); break
PY
)
[ -n "$OFFSET" ] || fail "no free port block"
export FM_SHARE_PILOT_PORT_OFFSET=$OFFSET
WEB=$((OFFSET + 5373)) CONVEX=$((OFFSET + 3410))

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; fm_test_cleanup' EXIT
wait_up() {
  for _ in $(seq 1 50); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done
  fail "server did not start: $(cat "$2")"
}
# The slot: a web dev server whose bundle gives the browser a loopback Convex URL (pilot/scripts/up.sh's default),
# and a Convex that answers /version.
mkdir -p "$TMP_ROOT/web/src" "$TMP_ROOT/convex"
printf 'import.meta.env = {"VITE_CONVEX_DEFAULT_URL": "http://127.0.0.1:3210", "VITE_CONVEX_SAME_ORIGIN": "", "VITE_CONVEX_URL": "http://127.0.0.1:%s"};\n' \
  "$CONVEX" > "$TMP_ROOT/web/src/main.tsx"
printf '<div id="root"></div>\n' > "$TMP_ROOT/web/index.html"
printf 'unknown' > "$TMP_ROOT/convex/version"
python3 -m http.server "$WEB" --bind 127.0.0.1 --directory "$TMP_ROOT/web" >"$TMP_ROOT/web.log" 2>&1 &
pids+=($!)
python3 -m http.server "$CONVEX" --bind 127.0.0.1 --directory "$TMP_ROOT/convex" >"$TMP_ROOT/convex.log" 2>&1 &
CONVEX_PID=$!
pids+=("$CONVEX_PID")
wait_up "http://127.0.0.1:$WEB/" "$TMP_ROOT/web.log"
wait_up "http://127.0.0.1:$CONVEX/version" "$TMP_ROOT/convex.log"

field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]); [v := v[k] if isinstance(v, dict) else v[int(k)] for k in sys.argv[2:]]; print(json.dumps(v) if isinstance(v, (dict, list)) else v)' "$@"; }

out=$("$ROOT/bin/fm-share.sh" share-slot 2 --to T-Ev@github --path /designs/x --json)
assert_equals "http://localhost:$WEB/designs/x" "$(field "$out" url)" "the link opens the slot's web port on the tailnet name"
assert_equals "{\"src\": [\"T-Ev@github\"], \"dst\": [\"localhost\"], \"ip\": [\"tcp:$WEB\", \"tcp:$CONVEX\"]}" "$(field "$out" grant)" \
  "the grant names the one account and both ports"
assert_equals "{\"src\": \"T-Ev@github\", \"accept\": [\"localhost:$WEB\", \"localhost:$CONVEX\"], \"deny\": [\"localhost:22\", \"localhost:443\", \"localhost:8449\"]}" \
  "$(field "$out" test)" "the policy test accepts both ports and denies SSH, https, and the Deck"
assert_equals "added added" "$(field "$out" serve 0 state) $(field "$out" serve 1 state)" "both ports newly served"
assert_equals "serve --bg --http=$WEB http://127.0.0.1:$WEB
serve --bg --http=$CONVEX http://127.0.0.1:$CONVEX" "$(cat "$SERVE_LOG")" "plain http on the same port numbers"
text=$("$ROOT/bin/fm-share.sh" share-slot 2 --to T-Ev@github)
assert_contains "$text" "(present)" "a second run finds both serves"
assert_contains "$text" "by hand" "the printout says the paste is a human step"
assert_contains "$text" "http://localhost:$WEB/" "the printout ends with the link to send"
assert_equals 2 "$(wc -l < "$SERVE_LOG" | tr -d ' ')" "a second run serves nothing new"
pass "share-slot serves web and Convex over http at their own ports and prints one account's grant, test, and link"

for bad in "share-slot 2 --to autogroup:shared" "share-slot 5 --to T-Ev@github" "share-slot 2" \
           "share-slot 2 --to T-Ev@github --path nope"; do
  # shellcheck disable=SC2086
  expect_code 2 "$("$ROOT/bin/fm-share.sh" $bad >/dev/null 2>&1; echo $?)" "$bad"
done
err=$("$ROOT/bin/fm-share.sh" share-slot 4 --to T-Ev@github 2>&1 >/dev/null; echo "rc=$?")
assert_contains "$err" "Pilot slot 4 is not up" "a slot that is not up"
assert_contains "$err" "rc=1" "a slot that is not up exits 1"
python3 - "$SERVE_JSON" "$WEB" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["TCP"][sys.argv[2]] = {"HTTPS": True}
json.dump(d, open(sys.argv[1], "w"))
PY
before=$(cat "$SERVE_JSON")
err=$("$ROOT/bin/fm-share.sh" share-slot 2 --to T-Ev@github 2>&1 >/dev/null; echo "rc=$?")
assert_contains "$err" "already served (https" "a port served another way is reported"
assert_contains "$err" "rc=1" "a port served another way exits 1"
assert_equals "$before" "$(cat "$SERVE_JSON")" "a port served another way is never replaced"
printf '{}\n' > "$SERVE_JSON"
kill "$CONVEX_PID"
wait "$CONVEX_PID" 2>/dev/null || true
err=$("$ROOT/bin/fm-share.sh" share-slot 2 --to T-Ev@github 2>&1 >/dev/null; echo "rc=$?")
assert_contains "$err" "nothing listens on 127.0.0.1:$CONVEX" "a backend that is down"
assert_contains "$err" "rc=1" "a backend that is down exits 1"
python3 -m http.server "$CONVEX" --bind 127.0.0.1 --directory "$TMP_ROOT/convex" >"$TMP_ROOT/convex.log" 2>&1 &
pids+=($!)
wait_up "http://127.0.0.1:$CONVEX/version" "$TMP_ROOT/convex.log"
pass "share-slot refuses bad arguments, a slot that is not up, a port served another way, and a backend that is down"

# The Deck: a card naming a Pilot link gets the control; other links do not.
DECK="https://ron.example.ts.net:8449"
ANS_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'data/page/current.html\ncurated=data/page/curated.json\nanswers_origin=%s\nanswers_listen=127.0.0.1:%s\n' \
  "$DECK" "$ANS_PORT" > "$HOME_DIR/config/current-page"
# An existing https front on another tailnet port that proxies to the slot's web (the FOAK review's :8453 shape) is a
# Pilot link too; a front to something else is not.
FRONT=$((OFFSET + 8453)) OTHER_FRONT=$((OFFSET + 8454))
python3 - "$SERVE_JSON" "$FRONT" "$OTHER_FRONT" "$WEB" <<'PY'
import json, sys
path, front, other, web = sys.argv[1:]
json.dump({"TCP": {front: {"HTTPS": True}, other: {"HTTPS": True}},
           "Web": {f"localhost:{front}": {"Handlers": {"/": {"Proxy": f"http://127.0.0.1:{web}"}}},
                   f"localhost:{other}": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:1"}}}}}, open(path, "w"))
PY
python3 - "$PAGE_DIR/curated.json" "$WEB" "$FRONT" "$OTHER_FRONT" <<'PY'
import json, sys, time
web, front, other = sys.argv[2:]
json.dump({"checked": int(time.time()),
           "needs": [{"t": "Look at the new layout", "why": f"open http://ron-test.example.ts.net:{web}/designs/y and say if it reads",
                      "checked": int(time.time())}],
           "wins": [{"t": "Pilot board", "url": f"http://127.0.0.1:{web}/designs/x"},
                    {"t": "Pilot behind its https front", "url": f"https://ron-test.example.ts.net:{front}/designs/z"},
                    {"t": "Another front", "url": f"https://ron-test.example.ts.net:{other}/designs/w"},
                    {"t": "Not Pilot", "url": f"http://127.0.0.1:{int(web) + 1}/designs/x"},
                    {"t": "Elsewhere", "url": f"http://other-host:{web}/designs/x"}]}, open(sys.argv[1], "w"))
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE_DIR/current.html")
ctls() { python3 -c 'import re,sys; print(" ".join(sorted({a + b for a, b in re.findall(r"class=\"ss\" data-slot=\"(\d)\" data-path=\"([^\"]+)\"", open(sys.argv[1]).read())})))' "$PAGE_DIR/current.html"; }
assert_equals "2/designs/x 2/designs/y 2/designs/z" "$(ctls)" "share slot sits on the cards naming this machine's Pilot links only"
assert_contains "$page" "Tailscale has no policy API here" "the Deck says the paste is a human step"
assert_contains "$page" '<datalist id="ss-accounts" data-swap><option value="T-Ev@github"></datalist>' "the tailnet's other account is suggested"
assert_contains "$page" 'value="T-Ev@github"' "the only other account is filled in"

"$ROOT/bin/fm-current-answers.sh" >"$TMP_ROOT/answers.log" 2>&1 &
pids+=($!)
wait_up "http://127.0.0.1:$ANS_PORT/api/health" "$TMP_ROOT/answers.log"
PAGE_TOKEN=$(python3 -c 'import re,sys; print(re.search(r"data-token=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PAGE_DIR/current.html")
post() {  # post <token|-> <json>
  local args=(-s -o "$TMP_ROOT/body" -w '%{http_code}' -X POST "http://127.0.0.1:$ANS_PORT/api/share/slot"
              -H "Origin: $DECK" -H "Content-Type: application/json" --data "$2")
  [ "$1" = - ] || args+=(-H "X-FM-Answer-Token: $1")
  curl "${args[@]}"
}
: > "$SERVE_LOG"
expect_code 403 "$(post - '{"rid":"rid-slot-0001","slot":2,"path":"/designs/x","to":"T-Ev@github"}')" "a slot share without the page token"
expect_code 409 "$(post "$PAGE_TOKEN" '{"rid":"rid-slot-0002","slot":3,"path":"/designs/x","to":"T-Ev@github"}')" "a slot the page never offered"
expect_code 409 "$(post "$PAGE_TOKEN" '{"rid":"rid-slot-0003","slot":2,"path":"/elsewhere","to":"T-Ev@github"}')" "a path the page never offered"
expect_code 400 "$(post "$PAGE_TOKEN" '{"rid":"rid-slot-0004","slot":2,"path":"/designs/x","to":"autogroup:shared"}')" "autogroup:shared"
assert_equals 0 "$(wc -l < "$SERVE_LOG" | tr -d ' ')" "no refused tap served anything"
expect_code 200 "$(post "$PAGE_TOKEN" '{"rid":"rid-slot-0005","slot":2,"path":"/designs/y","to":"T-Ev@github"}')" "a share slot tap from the Deck"
body=$(cat "$TMP_ROOT/body")
assert_equals "http://localhost:$WEB/designs/y" "$(field "$body" url)" "the Deck gets the link for the card's path"
assert_equals "[\"tcp:$WEB\", \"tcp:$CONVEX\"]" "$(field "$body" grant ip)" "the Deck gets the grant to paste"
assert_equals 2 "$(wc -l < "$SERVE_LOG" | tr -d ' ')" "the tap served both ports"
pass "the Deck offers share slot on Pilot links and serves only an offered slot, for one account, behind the page token"
