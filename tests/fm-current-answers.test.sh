#!/usr/bin/env bash
# tests/fm-current-answers.test.sh - answer buttons on the current page and the endpoint behind them:
# options from the decision's words, same-origin + CSRF + JSON-only + revision checks that queue nothing
# when they refuse, and one round trip from a tap to Main's inbox note to the reply the page reads back.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-current-answers)
HOME_DIR="$TMP_ROOT/home"
PAGE="$HOME_DIR/data/page/current.html"
KEEP="$HOME_DIR/data/page/curated.json"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/page" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_CURRENT_PAGE_NO_FORGE=1 FM_CURRENT_PAGE_HOST=ron-test
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"

ORIGIN="https://ron.example.ts.net:8449"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$PORT"
printf 'data/page/current.html\ncurated=data/page/curated.json\nanswers_origin=%s\nanswers_listen=127.0.0.1:%s\n' \
  "$ORIGIN" "$PORT" > "$HOME_DIR/config/current-page"

"$ROOT/bin/fm-captain-hold.sh" hold pick-plan --title "Pick the scorecard plan" \
  --reason "Choose the scorecard plan from the retro." >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold ship-it --title "Ship the banner?" --reason "yes or no, it is ready" >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold open-ask --title "Which host runs it" --reason "Name the machine." >/dev/null
python3 - "$KEEP" <<'PY'
import json, sys, time
json.dump({"checked": int(time.time()),
           "needs": [{"t": "Merge the guide?", "why": "Bill reads it Oct 8.", "task": "ship-it", "options": ["Merge", "Hold"]},
                     {"t": "Scorecard plan", "task": "pick-plan",
                      "why": "A (recommended): Linear is the scorecard. B: a local file. C: leave it."}],
           "wins": [{"t": "Pilot opens the Diagram tab", "url": "https://github.com/example/alpha/pull/1", "why": "TJ lands on the drawing."},
                    {"t": "not a link", "url": "javascript:alert(1)"}]}, open(sys.argv[1], "w"))
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null

python3 - "$PAGE" "$HOME_DIR/state/.current-page/decisions.json" <<'PY' || fail "answer buttons, wins, PWA head, or decisions file differ"
import html.parser, json, sys
page, decisions = open(sys.argv[1]).read(), json.load(open(sys.argv[2]))["decisions"]
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.blocks, self.cur, self.wins, self.head, self.token = {}, None, [], [], None
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id") == "hud":
            self.token = a.get("data-token")
        if "answer" in (a.get("class") or "").split():
            self.cur = a["data-ans"]
            self.blocks.setdefault(self.cur, {"rev": a["data-rev"], "opts": [], "text": False})
        if self.cur and "ans-btn" in (a.get("class") or ""):
            self.blocks[self.cur]["opts"].append(a["data-opt"])
        if self.cur and tag == "input":
            self.blocks[self.cur]["text"] = True
        if tag == "a" and "win" in (a.get("class") or "").split():
            self.wins.append(a["href"])
        if tag in ("meta", "link"):
            self.head.append(a.get("name") or a.get("rel"))
p = P()
p.feed(page)
assert p.blocks["pick-plan"]["opts"] == ["A", "B", "C"], p.blocks
assert p.blocks["ship-it"]["opts"] == ["Merge", "Hold"], "curated options win over parsed ones"
assert p.blocks["open-ask"]["opts"] == [] and p.blocks["open-ask"]["text"], "no named options means a text box only"
assert all(b["text"] for b in p.blocks.values()), "every decision also takes a typed answer"
for key, block in p.blocks.items():
    assert decisions[key]["rev"] == block["rev"] and decisions[key]["options"] == block["opts"], (key, decisions)
assert decisions["pick-plan"]["row"] == "pick-plan"
assert p.wins == ["https://github.com/example/alpha/pull/1"], p.wins
assert p.token and "." in p.token
for want in ("apple-mobile-web-app-capable", "theme-color", "manifest", "apple-touch-icon"):
    assert want in p.head, (want, p.head)
assert 'class="ans-btn rec" data-opt="A"' in page, "the recommended letter is marked"
PY
for f in manifest.json apple-touch-icon.png current-icon-192.png current-icon-512.png; do
  [ -s "$HOME_DIR/data/page/$f" ] || fail "missing app asset $f"
done
[ "$(stat -c %a "$HOME_DIR/state/.current-page/answer-secret")" = 600 ] || fail "the token key is not private"
pass "the page offers each decision's own options as buttons, wins, and an installable app"

python3 - "$ROOT/bin/fm-current-page.py" <<'PY' || fail "option parsing differs"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("page", sys.argv[1])
page = importlib.util.module_from_spec(spec)
spec.loader.exec_module(page)
cases = {
    "Pick A/B/C for the lane plan": (["A", "B", "C"], None),
    "Tell Main a, b, or c.": (["A", "B", "C"], None),
    "A: keep it. B (recommended): drop it.": (["A", "B"], "B"),
    "Yes/no: may agents move idle tickets?": (["Yes", "No"], None),
    "Merge or close the stale draft": (["Merge", "Close"], None),
    "Ron/Bertha both fine; see GDC 5 notes (A)": ([], None),
    "Name the machine.": ([], None),
}
for text, want in cases.items():
    got = page.decision_options(text)
    assert got == want, (text, got, want)
PY
pass "options come from lettered choices, yes/no, and merge/close; anything else gets a text box"

python3 - "$ROOT/bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_current_answers as a
st = lambda name, kind: {"name": name, "type": kind}
issue = {"identifier": "STA-1", "title": "Notes", "url": "https://linear.app/x/issue/STA-1",
         "description": "\n".join(f"line {i}" for i in range(20)), "state": st("References", "completed"),
         "projectMilestone": {"name": "Sprint 2", "issues": {"nodes": [{"state": s} for s in [
             st("Done", "completed"), st("Done", "completed"), st("References", "completed"), st("References", "completed"),
             st("In Progress", "started"), st("Todo", "unstarted"), st("Canceled", "canceled"), st("Duplicate", "duplicate")]]}}}
c = a.card(issue)
assert c["counted"] is False, c
assert c["milestone"] == {"name": "Sprint 2", "done": 2, "total": 4, "pct": 50}, c["milestone"]
assert len(c["body"]) == a.CARD_LINES and c["more"], c["body"]
assert a.card({**issue, "state": st("Done", "completed")})["counted"] is True
assert a.completion([st("References", "completed")])["pct"] is None
PY
pass "References tickets count neither done nor outstanding in a card's milestone completion"

: > "$TMP_ROOT/server.log"
unset FM_LINEAR_API_KEY
"$ROOT/bin/fm-current-answers.sh" >"$TMP_ROOT/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 1 50); do curl -fsS "$BASE/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "$BASE/api/health" >/dev/null || fail "endpoint did not start: $(cat "$TMP_ROOT/server.log")"
expect_code 503 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/linear/STA-1")" "a Linear card with no key configured"
expect_code 404 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/linear/not-an-id")" "a malformed issue id"

TOKEN=$(python3 -c 'import re,sys; print(re.search(r"data-token=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PAGE")
REV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["decisions"]["pick-plan"]["rev"])' "$HOME_DIR/state/.current-page/decisions.json")
notes() { find "$HOME_DIR/state/inbox" -maxdepth 1 -type f -name '*-*' 2>/dev/null | wc -l | tr -d ' '; }
# post <origin|-> <content-type> <token|-> <json>: prints the HTTP status, body in $TMP_ROOT/body
post() {
  local args=(-s -o "$TMP_ROOT/body" -w '%{http_code}' -X POST "$BASE/api/answer" -H "Content-Type: $2" --data "$4")
  [ "$1" = - ] || args+=(-H "Origin: $1")
  [ "$3" = - ] || args+=(-H "X-FM-Answer-Token: $3")
  curl "${args[@]}"
}
good() { printf '{"key":"pick-plan","rev":"%s","rid":"%s","option":"%s"}' "$REV" "$1" "${2:-A}"; }

expect_code 403 "$(post https://evil.example application/json "$TOKEN" "$(good rid-foreign-1)")" "foreign-origin fetch"
expect_code 403 "$(post - application/json "$TOKEN" "$(good rid-no-origin-1)")" "a post with neither Origin nor Referer"
expect_code 415 "$(post "$ORIGIN" application/x-www-form-urlencoded - "key=pick-plan&option=A")" "plain HTML form post"
expect_code 415 "$(post "$ORIGIN" text/plain "$TOKEN" "$(good rid-text-plain-1)")" "a text/plain simple request"
expect_code 403 "$(post "$ORIGIN" application/json - "$(good rid-no-token-1)")" "same-origin JSON without the page token"
expect_code 403 "$(post "$ORIGIN" application/json "1700000000.0123456789abcdef0123456789abcdef" "$(good rid-forged-1)")" "a forged token"
stale=$(printf '{"key":"pick-plan","rev":"000000000000","rid":"rid-stale-1","option":"A"}')
expect_code 409 "$(post "$ORIGIN" application/json "$TOKEN" "$stale")" "an answer bound to a replaced revision"
assert_contains "$(cat "$TMP_ROOT/body")" '"stale"' "a stale tab is told to refresh"
expect_code 409 "$(post "$ORIGIN" application/json "$TOKEN" '{"key":"no-such-row","rev":"x","rid":"rid-gone-1","option":"A"}')" "an answer to a decision that is gone"
expect_code 400 "$(post "$ORIGIN" application/json "$TOKEN" "$(good rid-bad-opt-1 Z)")" "an option the decision does not offer"
assert_equals 0 "$(notes)" "no refused answer reached Main's inbox"
code=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/answer" -H "Origin: https://evil.example" \
  -H "Access-Control-Request-Method: POST" -D "$TMP_ROOT/preflight")
expect_code 405 "$code" "CORS preflight"
assert_not_contains "$(tr '[:upper:]' '[:lower:]' < "$TMP_ROOT/preflight")" 'access-control-allow' "a preflight is never approved"
pass "foreign origins, form posts, missing or forged tokens, and stale revisions are refused and queue nothing"

expect_code 200 "$(post "$ORIGIN" application/json "$TOKEN" "$(good rid-round-trip-1)")" "a tap from the page"
receipt=$(cat "$TMP_ROOT/body")
assert_contains "$receipt" '"state": "received"' "the tap gets an immediate receipt"
note_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' "$TMP_ROOT/body")
expect_code 200 "$(post "$ORIGIN" application/json "$TOKEN" "$(good rid-round-trip-1)")" "a retried tap"
assert_contains "$(cat "$TMP_ROOT/body")" "\"note\": \"$note_id\"" "a retried tap returns the same note"
assert_equals 1 "$(notes)" "one tap, retried, is one note"
body=$("$ROOT/bin/fm-inbox.sh" receipts --all-pending | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending"][0]["body"])')
assert_contains "$body" "current-page-answer row=pick-plan key=pick-plan rev=$REV" "the note names the row and revision"
assert_contains "$body" "answered from the current page: A" "the note carries the answer"
feed=$(curl -fsS "$BASE/api/answers")
assert_contains "$feed" '"state": "received"' "the feed shows the answer waiting in Main's inbox"

"$ROOT/bin/fm-inbox.sh" drain --ack "$note_id" >/dev/null
sleep 3.2
assert_contains "$(curl -fsS "$BASE/api/answers")" '"state": "seen"' "the feed shows Main acknowledged it"
"$ROOT/bin/fm-inbox.sh" reply "$note_id" "Going with A; Linear is the scorecard." >/dev/null
sleep 3.2
feed=$(curl -fsS "$BASE/api/answers")
assert_contains "$feed" '"state": "answered"' "the feed shows Main replied"
assert_contains "$feed" 'Going with A; Linear is the scorecard.' "the reply text reaches the page"
pass "a tap reaches Main as one note, and the page reads back read and replied"
