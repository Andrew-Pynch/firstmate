#!/usr/bin/env bash
# tests/fm-share.test.sh - explicit share links: add publishes a snapshot under an unguessable token, the share
# server answers only /<token>/<file> (never a listing, a folder, a hidden entry, or a path out of the token), revoke
# takes the link down at once, and the Deck offers share and revoke on its own artifacts behind the answer token.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-share)
HOME_DIR="$TMP_ROOT/home"
PAGE_DIR="$HOME_DIR/data/page"
mkdir -p "$HOME_DIR/state" "$PAGE_DIR" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_CURRENT_PAGE_NO_FORGE=1 FM_CURRENT_PAGE_HOST=ron-test
export FM_SHARE_ROOT="$TMP_ROOT/share" FM_SHARE_RECORDS="$TMP_ROOT/records"
unset FM_SHARE_ORIGIN FM_SHARE_LISTEN FM_LINEAR_API_KEY
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
DECK="https://ron.example.ts.net:8449"
SHARE="https://ron.example.ts.net:8450"
SHARE_PORT=$(free_port)
ANS_PORT=$(free_port)
printf 'data/page/current.html\ncurated=data/page/curated.json\nanswers_origin=%s\nanswers_listen=127.0.0.1:%s\nshare_origin=%s\nshare_listen=127.0.0.1:%s\n' \
  "$DECK" "$ANS_PORT" "$SHARE" "$SHARE_PORT" > "$HOME_DIR/config/current-page"
SB="http://127.0.0.1:$SHARE_PORT"
code() { curl -s --path-as-is -o "$TMP_ROOT/got" -w '%{http_code}' "$@"; }

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; fm_test_cleanup' EXIT
wait_up() {
  for _ in $(seq 1 50); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done
  fail "server did not start: $(cat "$2")"
}

# A token folder made by hand before this tool existed keeps working and stays revocable.
LEGACY=frGEL5QvgwBXi4J9nsb0aP
mkdir -p "$FM_SHARE_ROOT/$LEGACY"
printf '<p>deslop</p>\n' > "$FM_SHARE_ROOT/$LEGACY/deslop.html"
printf '<!doctype html><title>nothing here</title>\n' > "$FM_SHARE_ROOT/$LEGACY/index.html"

printf '<h1>retro v1</h1>\n' > "$TMP_ROOT/retro.html"
url=$("$ROOT/bin/fm-share.sh" add "$TMP_ROOT/retro.html" --label "Retro, Oct 9")
[[ $url =~ ^https://ron\.example\.ts\.net:8450/([A-Za-z0-9_-]{24})/retro\.html$ ]] || fail "add printed $url"
TOKEN=$(basename "$(dirname "$url")")
printf '<h1>retro v2, private draft</h1>\n' > "$TMP_ROOT/retro.html"

mkdir -p "$TMP_ROOT/tour/assets" "$TMP_ROOT/outside"
printf '<h1>tour</h1>\n' > "$TMP_ROOT/tour/index.html"
printf 'body{}\n' > "$TMP_ROOT/tour/assets/site.css"
printf 'secret\n' > "$TMP_ROOT/outside/key.txt" && printf 'hidden\n' > "$TMP_ROOT/tour/.env"
ln -s "$TMP_ROOT/outside/key.txt" "$TMP_ROOT/tour/key.txt"
tour=$("$ROOT/bin/fm-share.sh" add "$TMP_ROOT/tour" --json)
TOUR_URL=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$tour")
TOUR=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$tour")
assert_equals "$SHARE/$TOUR/tour/index.html" "$TOUR_URL" "a shared folder opens its index.html"
expect_code 2 "$("$ROOT/bin/fm-share.sh" add "$TMP_ROOT/outside" >/dev/null 2>&1; echo $?)" "a folder without index.html"
pass "add mints a 24-character token per share and prints its link"

"$ROOT/bin/fm-share.sh" serve >"$TMP_ROOT/share.log" 2>&1 &
pids+=($!)
wait_up "$SB/" "$TMP_ROOT/share.log"
expect_code 200 "$(code "$SB/")" "the root"
assert_not_contains "$(cat "$TMP_ROOT/got")" "$TOKEN" "the root lists nothing"
assert_not_contains "$(cat "$TMP_ROOT/got")" "$LEGACY" "the root lists nothing"
expect_code 200 "$(code "$SB/$TOKEN/retro.html")" "a shared file"
assert_contains "$(cat "$TMP_ROOT/got")" "retro v1" "the link serves the snapshot taken at add"
assert_not_contains "$(cat "$TMP_ROOT/got")" "private draft" "later edits to the source do not reach the link"
headers=$(curl -s -D - -o /dev/null "$SB/$TOKEN/retro.html" | tr -d '\r')
assert_contains "$headers" "Cache-Control: no-store" "shared files are not cached"
assert_contains "$headers" "Referrer-Policy: no-referrer" "a shared page leaks no referrer"
expect_code 200 "$(code "$SB/$LEGACY/deslop.html")" "a file in the folder made by hand"
expect_code 200 "$(code "$SB/$TOUR/tour/assets/site.css")" "an asset inside a shared folder"
for path in "/$TOKEN/" "/$TOKEN" "/$LEGACY/" "/$TOUR/tour/" "/$TOUR/tour" "/$TOUR/tour/assets/" \
            "/$TOUR/tour/key.txt" "/$TOUR/tour/.env" "/$TOKEN/../$LEGACY/deslop.html" "/$TOKEN/%2e%2e/$LEGACY/deslop.html" \
            "/$TOKEN/..%2f$LEGACY%2fdeslop.html" "/.staging-x/retro.html" "/short/retro.html" "/index.html" "/$TOKEN/nope.html"; do
  expect_code 404 "$(code "$SB$path")" "GET $path"
done
expect_code 501 "$(code -X POST "$SB/$TOKEN/retro.html")" "a POST"
pass "the server answers only /<token>/<file>: the root is empty, and folders, hidden, traversal, and symlinked paths 404"

listing=$("$ROOT/bin/fm-share.sh" list)
assert_contains "$listing" "Retro, Oct 9" "list names a share by its label"
assert_contains "$listing" "$SHARE/$LEGACY/deslop.html" "list shows each file of a folder made by hand"
assert_not_contains "$listing" "$LEGACY/index.html" "the placeholder index is not a shared file"
"$ROOT/bin/fm-share.sh" revoke "$TOKEN" >/dev/null
expect_code 404 "$(code "$SB/$TOKEN/retro.html")" "a revoked link"
[ ! -e "$FM_SHARE_RECORDS/$TOKEN.json" ] || fail "revoke left the record"
expect_code 1 "$("$ROOT/bin/fm-share.sh" revoke "$TOKEN" >/dev/null 2>&1; echo $?)" "revoking it again"
"$ROOT/bin/fm-share.sh" revoke "$TOUR" >/dev/null
expect_code 200 "$(code "$SB/$LEGACY/deslop.html")" "the folder made by hand after other revokes"
expect_code 2 "$(FM_SHARE_LISTEN=0.0.0.0:1 "$ROOT/bin/fm-share.sh" serve >/dev/null 2>&1; echo $?)" "listening on every interface"
pass "revoke takes a link down at once, and the server refuses a non-loopback, non-tailnet listen address"

# The Deck: its own artifacts get share controls; links elsewhere do not.
mkdir -p "$HOME_DIR/data/pick-plan"
printf '# Plan\n\nA or B.\n' > "$HOME_DIR/data/pick-plan/report.md"
printf '<h1>board</h1>\n' > "$PAGE_DIR/board.html"
"$ROOT/bin/fm-captain-hold.sh" hold pick-plan --title "Pick the plan" --reason "A or B" >/dev/null
python3 - "$PAGE_DIR/curated.json" "$DECK" <<'PY'
import json, sys, time
deck = sys.argv[2]
json.dump({"checked": int(time.time()),
           "wins": [{"t": "Board", "url": deck + "/board.html", "why": "ready"},
                    {"t": "PR", "url": "https://github.com/example/alpha/pull/1"},
                    {"t": "Gone", "url": deck + "/missing.html"},
                    {"t": "The Deck itself", "url": deck + "/current.html"}]}, open(sys.argv[1], "w"))
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
arts() { python3 -c 'import re,sys; print(" ".join(sorted(set(re.findall(r"class=\"share[^\"]*\" data-art=\"([^\"]+)\"", open(sys.argv[1]).read())))))' "$PAGE_DIR/current.html"; }
assert_equals "board.html pick-plan-report.html" "$(arts)" "share controls sit on the Deck's own artifacts only"
assert_contains "$(cat "$PAGE_DIR/current.html")" "$SHARE/$LEGACY/deslop.html" "the Shared section lists the folder made by hand"

"$ROOT/bin/fm-current-answers.sh" >"$TMP_ROOT/answers.log" 2>&1 &
pids+=($!)
wait_up "http://127.0.0.1:$ANS_PORT/api/health" "$TMP_ROOT/answers.log"
PAGE_TOKEN=$(python3 -c 'import re,sys; print(re.search(r"data-token=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PAGE_DIR/current.html")
post() {  # post <route> <token|-> <json>
  local args=(-s -o "$TMP_ROOT/body" -w '%{http_code}' -X POST "http://127.0.0.1:$ANS_PORT/api/$1"
              -H "Origin: $DECK" -H "Content-Type: application/json" --data "$3")
  [ "$2" = - ] || args+=(-H "X-FM-Answer-Token: $2")
  curl "${args[@]}"
}
shares() { find "$FM_SHARE_ROOT" -mindepth 1 -maxdepth 1 -not -name "$LEGACY" | wc -l | tr -d ' '; }
expect_code 403 "$(post share - '{"rid":"rid-share-0001","artifact":"board.html"}')" "a share without the page token"
expect_code 409 "$(post share "$PAGE_TOKEN" '{"rid":"rid-share-0002","artifact":"../config/current-page"}')" "a path the page never offered"
assert_equals 0 "$(shares)" "no refused share published anything"
expect_code 200 "$(post share "$PAGE_TOKEN" '{"rid":"rid-share-0003","artifact":"board.html"}')" "a share tap from the Deck"
DECK_URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$TMP_ROOT/body")
expect_code 200 "$(post share "$PAGE_TOKEN" '{"rid":"rid-share-0003","artifact":"board.html"}')" "a retried share tap"
assert_equals "$DECK_URL" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$TMP_ROOT/body")" "a retry returns the same link"
assert_equals 1 "$(shares)" "one tap, retried, is one share"
expect_code 200 "$(code "${DECK_URL/$SHARE/$SB}")" "the Deck's link on the share server"
"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE_DIR/current.html")
assert_contains "$page" "class=\"share on\" data-art=\"board.html\"><span class=\"sh-badge\">shared</span>" "the shared artifact wears the badge"
assert_contains "$page" "data-url=\"$DECK_URL\"" "the badge carries the link"
DECK_TOKEN=$(basename "$(dirname "$DECK_URL")")
expect_code 200 "$(post share/revoke "$PAGE_TOKEN" "{\"rid\":\"rid-revoke-0001\",\"token\":\"$DECK_TOKEN\"}")" "revoke from the Deck"
expect_code 404 "$(code "${DECK_URL/$SHARE/$SB}")" "the revoked Deck link"
"$ROOT/bin/fm-current-page.sh" >/dev/null
assert_not_contains "$(cat "$PAGE_DIR/current.html")" "$DECK_TOKEN" "the page drops a revoked share"
pass "the Deck shares its own artifacts behind the page token, shows the badge, and revokes"

sed -i '/^share_origin=/d' "$HOME_DIR/config/current-page"
"$ROOT/bin/fm-current-page.sh" >/dev/null
assert_equals "" "$(arts)" "no share origin, no share controls"
pass "without share_origin the Deck shows no share controls"
