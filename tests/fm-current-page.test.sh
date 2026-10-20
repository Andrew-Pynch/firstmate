#!/usr/bin/env bash
# tests/fm-current-page.test.sh - the live current page: sources, filters, notes, isolation, trigger.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-current-page)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PAGE="$HOME_DIR/data/page/current.html"
mkdir -p "$STATE" "$HOME_DIR/data/page" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_CURRENT_PAGE_NO_FORGE=1 FM_CURRENT_PAGE_HOST=ron-test

fm_write_meta "$STATE/alpha-fix.meta" "kind=ship" "project=$HOME_DIR/projects/alpha" "project_token=alpha-web" \
  "model=example/model-x" "worktree=$TMP_ROOT/wt/alpha" "pr=https://github.com/example/alpha/pull/7"
printf 'needs-decision [key=pick-color] [at=1790000000]: choose red or blue for the alpha banner\n' > "$STATE/alpha-fix.status"
printf 'working [at=1790000100]: building the <script>alert(1)</script> fix\n' >> "$STATE/alpha-fix.status"
fm_write_meta "$STATE/beta-scan.meta" "kind=scout" "project=$HOME_DIR/projects/beta"
printf 'needs-decision [key=old-call] [at=1790000000]: an answered question\n' > "$STATE/beta-scan.status"
printf 'resolved [key=old-call] [at=1790000050]: answered\n' >> "$STATE/beta-scan.status"
fm_write_meta "$STATE/gamma-docs.meta" "kind=ship" "project=$HOME_DIR/projects/alpha"
printf 'working [at=1790000000]: wrote data/gamma/report.md see https://example.com/x [key=g] for review\n' > "$STATE/gamma-docs.status"
fm_write_meta "$STATE/delta-old.meta" "kind=ship" "project=$HOME_DIR/projects/alpha"
printf 'working [at=1790000000]: an old row the keeper hides\n' > "$STATE/delta-old.status"
fm_write_secondmate_meta "$STATE/farmate.meta" "$TMP_ROOT/remote-home" remote:farmate beta
printf 'remote_host=far-box\n' >> "$STATE/farmate.meta"
printf 'blocked [key=farmate-disk] [at=1790000200]: the far box needs a disk decision\n' > "$STATE/farmate.status"
printf -- '- farmate - Own beta work on the far box; stay idle otherwise. (host: far-box; root: /r; home: /h; scope: beta; projects: beta; added 2026-09-12)\n' \
  > "$HOME_DIR/data/secondmates.md"

out=$("$ROOT/bin/fm-current-page.sh" 2>&1) && code=0 || code=$?
expect_code 2 "$code" "render with no configured output"
assert_contains "$out" "config/current-page" "unconfigured render names the config file"
[ ! -e "$PAGE" ] || fail "unconfigured render wrote a page"
pass "no configured output renders nothing"

printf '# page path\ndata/page/current.html\ncurated=data/keeper/curated.json\n' > "$HOME_DIR/config/current-page"
printf '# current-notes\n\nContext line for the captain.\n' > "$HOME_DIR/data/page/current-notes.md"

"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE")
needs=${page#*Needs you (}
needs=${needs%%Live workstreams (*}
assert_contains "$page" 'Curated file problem: curated.json not found' "a missing curated file is named"
assert_not_contains "$needs" 'choose red or blue' "raw status lines never fill Needs you"
assert_not_contains "$page" 'Answer' "raw status lines never fill NEXT"
pass "without a curated file, NEXT and Needs you stay empty"

mkdir -p "$HOME_DIR/data/keeper"
cat > "$HOME_DIR/data/keeper/curated.json" <<'EOF'
{"next": {"do": "Pick the banner color.", "why": "The alpha fix waits on it.", "unblocks": "alpha-fix"},
 "needs": [{"t": "Far box disk call", "why": "Bigger disk or prune.", "who": "farmate", "machine": "far-box"}],
 "why": {"alpha-fix": "Alpha banner gets a color"},
 "plain": {"beta-scan": "Scan finished, nothing left to do."},
 "hide": ["delta-old"],
 "mates": {"farmate": {"machine": "far-box", "scope": "Beta work on the far box"}}}
EOF
"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE")
needs=${page#*Needs you (}
needs=${needs%%Live workstreams (*}
for chip in 'data-dim="m" data-v="ron-test"' 'data-dim="m" data-v="far-box"' 'data-dim="g" data-v="Main"' \
  'data-dim="g" data-v="farmate"' 'data-dim="p" data-v="alpha-web"' 'data-dim="p" data-v="beta"'; do
  assert_contains "$page" "$chip" "filter chip"
done
pass "machine, mate, and project chips come from metas and the secondmate registry"

assert_contains "$page" '<b>Pick the banner color.</b>' "curated next fills the NEXT box"
assert_contains "$page" 'Unblocks: alpha-fix.' "curated next names what it unblocks"
assert_contains "$needs" 'data-m="far-box" data-g="farmate" data-p="beta"><b>Far box disk call</b>' "curated need carries its machine, mate, and project"
assert_not_contains "$needs" 'the far box needs a disk decision' "raw blocker stays out of Needs you"
assert_contains "$page" 'Alpha banner gets a color' "curated why sets the card title"
assert_contains "$page" 'Context line for the captain.' "free notes render"
assert_not_contains "$page" '<script>alert(1)' "status text is escaped"
assert_contains "$page" '&lt;script&gt;alert(1)' "status text survives escaped"
pass "NEXT and Needs you come from the curated file only"

live=${page#*Live workstreams (}
card_of() { local c=${live#*"<code>$1</code>"}; printf '%s' "${c%%</div></div>*}"; }
assert_contains "$(card_of alpha-fix)" '1 open decision' "open decision counts on its live card"
assert_contains "$(card_of farmate)" '1 open decision' "secondmate blocker counts on its card"
assert_not_contains "$(card_of beta-scan)" 'open decision' "a key closed by a resolved line is not counted"
assert_not_contains "$page" 'choose red or blue' "raw decision text is not on the page"
pass "live cards count only still-open decisions"

assert_contains "$(card_of beta-scan)" 'Scan finished, nothing left to do.' "curated plain line replaces the status line"
assert_contains "$(card_of gamma-docs)" 'wrote see for review' "raw status text is reduced to plain words"
assert_not_contains "$page" 'data/gamma' "home data paths stay off the page"
assert_not_contains "$page" '<code>delta-old</code>' "curated hide leaves a row off the page"
pass "card text uses curated plain lines, plain words, and hide"

python3 - "$HOME_DIR/data/keeper/curated.json" <<'PY'
import json, sys
msg = 'Hi TJ and Jeremy,\n"Quoted" & <b>not bold</b>, run `fm-x --y \'z\'` today.\r\nUnclosed ` tick stays.\n\n  - indented line'
json.dump({"needs": [{"t": "Message TJ and Jeremy", "why": "They need the reason.", "to": ["TJ", "Jeremy"], "message": msg},
                     {"t": "Legacy need", "why": "No message."}]}, open(sys.argv[1], "w"))
open(sys.argv[1] + ".expected", "w", newline="").write(msg)
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE")
python3 - "$PAGE" "$HOME_DIR/data/keeper/curated.json.expected" <<'PY' || fail "message copy text differs from the raw message"
import html.parser, sys
want = open(sys.argv[2], newline="").read()
class P(html.parser.HTMLParser):
    copies, in_quote, quote = [], False, ""
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "copy-message" in (a.get("class") or ""):
            self.copies.append(a.get("data-copy"))
        self.in_quote |= tag == "blockquote"
    def handle_endtag(self, tag):
        self.in_quote &= tag != "blockquote"
    def handle_data(self, data):
        if self.in_quote:
            self.quote += data
p = P(convert_charrefs=True)
p.feed(open(sys.argv[1], newline="").read())
assert p.copies == [want], p.copies
assert p.quote.replace("\r", "") == want.replace("`fm-x --y 'z'`", "fm-x --y 'z'").replace("\r", ""), repr(p.quote)
PY
needs=${page#*Needs you (}
needs=${needs%%Live workstreams (*}
assert_contains "$needs" '<b>Message to TJ, Jeremy</b>' "message recipients render"
assert_contains "$needs" "run <code>fm-x --y &#x27;z&#x27;</code> today." "inline code in a message renders as code"
assert_not_contains "$needs" '<b>not bold</b>' "message text is escaped"
legacy=${needs#*Legacy need}
assert_not_contains "${legacy%%</div></div>*}" 'copy-message' "a need without a message gets no message block"
pass "a need message renders verbatim with a Copy button holding the exact raw text"

for f in "$STATE"/.*open-decisions-cursor; do
  [ ! -e "$f" ] || fail "render wrote a drain cursor: $f"
done
pass "rendering leaves the wake drain's decision cursors untouched"

: > "$TMP_ROOT/watch.log"
FM_CURRENT_PAGE_POLL=1 FM_CURRENT_PAGE_POLL_SECS=1 FM_CURRENT_PAGE_DEBOUNCE_SECS=1 \
  "$ROOT/bin/fm-current-page.sh" watch >"$TMP_ROOT/watch.log" 2>&1 &
watch_pid=$!
trap 'kill "$watch_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 1 50); do grep -q 'rendered (watch start)' "$TMP_ROOT/watch.log" && break; sleep 0.2; done
printf 'working [at=1790000300]: fresh line the watcher must publish\n' >> "$STATE/gamma-docs.status"
seen=0
for _ in $(seq 1 50); do
  if grep -q 'fresh line the watcher must publish' "$PAGE"; then seen=1; break; fi
  sleep 0.2
done
[ "$seen" -eq 1 ] || fail "watch did not publish a status append within 10s: $(cat "$TMP_ROOT/watch.log")"
pass "watch republishes the page after a status append"
