#!/usr/bin/env bash
# tests/fm-current-page.test.sh - the live current page: needs, running, done today, aging, isolation, trigger.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-current-page)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PAGE="$HOME_DIR/data/page/current.html"
KEEP="$HOME_DIR/data/keeper/curated.json"
mkdir -p "$STATE" "$HOME_DIR/data/page" "$HOME_DIR/data/keeper" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_CURRENT_PAGE_NO_FORGE=1 FM_CURRENT_PAGE_HOST=ron-test

# A tmux stand-in that answers only the endpoint-presence read: a target listed
# in $FAKE_TMUX_LIVE exists, every other target does not.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH" FAKE_TMUX_LIVE="$TMP_ROOT/live-targets"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = display-message ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -t ]; then grep -qxF -- "$2" "$FAKE_TMUX_LIVE"; exit; fi
  shift
done
exit 1
SH
chmod +x "$FAKEBIN/tmux"
printf 'fm-alpha:0\nfm-beta:0\n' > "$FAKE_TMUX_LIVE"

now=$(date +%s)
fm_write_meta "$STATE/alpha-fix.meta" "kind=ship" "backend=tmux" "window=fm-alpha:0" \
  "project=$HOME_DIR/projects/alpha" "project_token=alpha-web" "pr=https://github.com/example/alpha/pull/7"
printf 'needs-decision [key=pick-color] [at=%s]: choose red or blue for the alpha banner\n' $((now - 600)) > "$STATE/alpha-fix.status"
printf 'working [at=%s]: building the alpha fix\n' $((now - 300)) >> "$STATE/alpha-fix.status"
fm_write_meta "$STATE/beta-scan.meta" "kind=scout" "backend=tmux" "window=fm-beta:0" "project=$HOME_DIR/projects/beta"
printf 'paused [at=%s]: kept alive for review\n' $((now - 200)) > "$STATE/beta-scan.status"
fm_write_meta "$STATE/gamma-gone.meta" "kind=ship" "backend=tmux" "window=fm-gamma:0" "project=$HOME_DIR/projects/alpha"
printf 'working [at=%s]: a worker whose endpoint is gone\n' $((now - 100)) > "$STATE/gamma-gone.status"
fm_write_secondmate_meta "$STATE/farmate.meta" "$TMP_ROOT/remote-home" remote:farmate beta
printf 'remote_host=far-box\n' >> "$STATE/farmate.meta"
printf 'blocked [key=farmate-disk] [at=%s]: the far box needs a <b>disk</b> decision\n' $((now - 900)) > "$STATE/farmate.status"
printf -- '- farmate - Own beta work on the far box; stay idle otherwise. (host: far-box; root: /r; home: /h; scope: beta; projects: beta; added 2026-09-12)\n' \
  > "$HOME_DIR/data/secondmates.md"

# page_part <id>: the text inside the element with that id, with each data-task
# and link target inlined as " task=<id> " and " href=<url> ".
page_part() {
  python3 - "$PAGE" "$1" <<'PY'
import html.parser, sys
target = sys.argv[2]
class P(html.parser.HTMLParser):
    depth, out = 0, []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if not self.depth and a.get("id") == target:
            self.depth = 1
            return
        if self.depth:
            self.depth += tag not in ("br", "img", "input", "meta", "hr")
            for key in ("data-task", "href"):
                if a.get(key):
                    self.out.append(f" {key.removeprefix('data-')}={a[key]} ")
    def handle_endtag(self, tag):
        if self.depth:
            self.depth -= 1
    def handle_data(self, data):
        if self.depth:
            self.out.append(data)
p = P()
p.feed(open(sys.argv[1]).read())
print("".join(p.out))
PY
}

out=$("$ROOT/bin/fm-current-page.sh" 2>&1) && code=0 || code=$?
expect_code 2 "$code" "render with no configured output"
assert_contains "$out" "config/current-page" "unconfigured render names the config file"
[ ! -e "$PAGE" ] || fail "unconfigured render wrote a page"
pass "no configured output renders nothing"

printf '# page path\ndata/page/current.html\ncurated=data/keeper/curated.json\n' > "$HOME_DIR/config/current-page"
printf '# current-notes\n\nContext line for the captain.\n' > "$HOME_DIR/data/page/current-notes.md"
"$ROOT/bin/fm-captain-hold.sh" hold call-new --title "Pick the banner color" \
  --reason "Red or blue? https://linear.app/x/issue/STA-1 see data/x/report.md" >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold call-later --title "Later call" --reason "revisit after launch" --until 2099-01-01 >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" add call-old "Old call" --kind captain --body "Captain hold set: 2026-01-01T00:00:00Z" >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" hold call-old --reason "an old open question" --kind captain >/dev/null

"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE")
needs=$(page_part needs-now)
assert_contains "$page" 'curated.json not found' "a missing curated file is named"
assert_contains "$needs" 'task=call-new' "a call Main held inside the window shows without a curated need"
assert_contains "$needs" 'new, not summarized yet' "an uncurated call says it is not summarized"
assert_contains "$needs" 'href=https://linear.app/x/issue/STA-1 STA-1' "a full URL in the hold reason becomes a short link"
assert_not_contains "$page" 'data/x' "home data paths stay off the page"
assert_not_contains "$needs" 'choose red or blue' "raw status lines never fill Needs you"
assert_not_contains "$needs" 'call-old' "a call older than the window stays out of Needs you"
assert_contains "$(page_part more-older-calls)" 'task=call-old' "an older call is folded under Everything else"
assert_contains "$(page_part more-deferred-calls)" 'task=call-later' "a deferred call is folded separately"
pass "without a curated file, Needs you holds only calls Main just opened"

python3 - "$KEEP" "$now" <<'PY'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
json.dump({"checked": now,
           "needs": [{"t": "Pick the banner color", "why": "The alpha fix waits on it.", "task": "call-new",
                      "link": "https://linear.app/x/issue/STA-1", "who": "alpha-fix"},
                     {"t": "Ask TJ to upgrade", "why": "His updater is old.", "checked": now - 3 * 3600},
                     {"t": "Answered already", "why": "Its row is gone.", "task": "call-gone"},
                     {"t": "Deferred one", "why": "Its row waits for a date.", "task": "call-later"}],
           "why": {"alpha-fix": "Alpha banner gets a color"},
           "plain": {"alpha-fix": {"text": "Painting the banner.", "at": now - 120},
                     "beta-scan": {"text": "an old keeper line", "at": now - 5 * 3600}},
           "mates": {"farmate": {"machine": "far-box", "scope": "Beta work on the far box"}}}, open(path, "w"))
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
page=$(cat "$PAGE")
needs=$(page_part needs-now)
assert_contains "$needs" 'task=call-new' "a curated need tied to an open call shows"
assert_contains "$needs" 'Open STA-1' "a curated need carries its direct link"
printf '%s\n' "$needs" | grep -Eq 'asked (just now|[0-9]+m ago)' || fail "a curated need carries the age of its ask from the hold stamp: $needs"
assert_not_contains "$needs" 'new, not summarized yet' "a curated need replaces the raw call"
assert_not_contains "$page" 'Answered already' "a need whose backlog row is no longer held leaves the page"
assert_not_contains "$needs" 'Deferred one' "a need whose call is deferred leaves Needs you now"
assert_not_contains "$needs" 'Ask TJ to upgrade' "a need not re-checked in 2 h leaves Needs you now"
assert_contains "$(page_part needs-stale)" 'Ask TJ to upgrade' "a need not re-checked in 2 h folds as stale"
assert_contains "$(page_part needs-stale)" 'checked 3h ago' "a stale need says when it was last checked"
assert_not_contains "$page" 'page keeper last checked' "a fresh keeper check raises no banner"
pass "Needs you now holds only current, linked, aged needs"

running=$(page_part running-now)
assert_contains "$running" 'task=alpha-fix' "a live worker shows as running"
assert_contains "$running" 'Alpha banner gets a color' "curated why titles the worker"
assert_contains "$running" 'Painting the banner.' "a fresh curated line newer than the status describes the worker"
assert_contains "$running" 'href=https://github.com/example/alpha/pull/7 PR #7' "the worker's PR is linked"
assert_contains "$running" 'waiting on a decision from Main' "an open decision is named"
assert_not_contains "$running" 'beta-scan' "a paused worker is not running"
assert_not_contains "$page" 'gamma-gone' "a worker whose endpoint is gone is off the page"
assert_contains "$(page_part more-parked)" 'kept alive for review' "a live paused worker folds with its status, not a stale keeper line"
assert_contains "$(page_part second-mates)" 'the far box needs a <b>disk</b> decision' "second mates show their routed status"
assert_not_contains "$page" '<b>disk</b>' "status text is escaped"
pass "Running shows live workers in plain words with their PR"

"$ROOT/bin/fm-tasks-axi.sh" unhold call-new >/dev/null
"$ROOT/bin/fm-current-page.sh" >/dev/null
assert_not_contains "$(cat "$PAGE")" 'Pick the banner color' "an answered call leaves the page on the next render"
pass "releasing the backlog row removes its need"

python3 - "$KEEP" <<'PY'
import json, sys
msg = 'Hi TJ and Jeremy,\n"Quoted" & <b>not bold</b>, run `fm-x --y \'z\'` today.\r\nUnclosed ` tick stays.\n\n  - indented line'
cur = json.load(open(sys.argv[1]))
cur["needs"] = [{"t": "Message TJ and Jeremy", "why": "They need the reason.", "to": ["TJ", "Jeremy"], "message": msg},
                {"t": "Plain need", "why": "No message."}]
json.dump(cur, open(sys.argv[1], "w"))
open(sys.argv[1] + ".expected", "w", newline="").write(msg)
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
python3 - "$PAGE" "$KEEP.expected" <<'PY' || fail "message copy text differs from the raw message"
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
needs=$(page_part needs-now)
assert_contains "$needs" 'Message to TJ, Jeremy' "message recipients render"
assert_not_contains "$(cat "$PAGE")" '<b>not bold</b>' "message text is escaped"
pass "a need message carries a Copy button holding the exact raw text"

python3 - "$HOME_DIR" "$KEEP" <<'PY'
import datetime as dt, json, os, sys, time
home, keep = sys.argv[1], sys.argv[2]
now = time.time()
stamp = lambda age: dt.datetime.fromtimestamp(now - age, dt.timezone.utc).isoformat()
today = dt.date.today().isoformat()
cur = json.load(open(keep))
cur["initiatives"] = [{"id": "pilot", "title": "Pilot review", "match": {"project_tokens": ["alpha"], "title_keywords": ["FOAK"]}},
                      {"id": "parts", "title": "Parts counts", "match": {"title_keywords": ["applicability"]}}]
cur["completed"] = [{"id": "receipt-task", "title": "Receipts show a diff", "completed": today,
                     "url": "https://github.com/example/alpha/pull/15"}]
json.dump(cur, open(keep, "w"))
os.makedirs(home + "/state/.current-page", exist_ok=True)
prs = [
    {"url": "https://github.com/example/alpha/pull/11", "title": "fix: FOAK applicability fix", "merged": stamp(3600), "author": "fleet-bot"},
    {"url": "https://github.com/example/alpha/pull/12", "title": "FOAK earlier fix", "merged": stamp(86400 * 2), "author": "fleet-bot"},
    {"url": "https://github.com/example/beta/pull/13", "title": "Someone else's change", "merged": stamp(3600), "author": "someone"},
    {"url": "https://github.com/example/alpha/pull/14", "title": "FOAK outside the week", "merged": stamp(86400 * 8), "author": "fleet-bot"},
    {"url": "https://github.com/example/alpha/pull/15", "title": "feat(chat): receipt diff", "merged": stamp(7200), "author": "fleet-bot"},
]
json.dump({"items": prs, "fetched": now, "viewer": "fleet-bot"}, open(home + "/state/.current-page/merged.json", "w"))
open(home + "/data/done-archive.md", "w").write(
    "- [x] archived-foak - FOAK review packet sent (repo: alpha) (kind: ship) (done " + today + ")\n")
PY
"$ROOT/bin/fm-current-page.sh" >/dev/null
python3 - "$PAGE" <<'PY' || fail "done grouping, deduplication, or time windows differ"
import html.parser, sys
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.section, self.group, self.groups = None, None, {}
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("section", "details") and a.get("id") in ("done", "more-week", "more-others"):
            self.section = a["id"]
        if tag == "div" and a.get("data-initiative"):
            self.group = (self.section, a["data-initiative"])
        key = self.group if self.section in ("done", "more-week") else (self.section, None)
        if tag == "a" and self.section and key[0] == self.section:
            self.groups.setdefault(key, []).append(a["href"])
    def handle_endtag(self, tag):
        if tag == "section" and self.section == "done":
            self.section, self.group = None, None
p = P()
p.feed(open(sys.argv[1]).read())
pull = lambda n: f"https://github.com/example/{'beta' if n == 13 else 'alpha'}/pull/{n}"
assert p.groups.get(("done", "parts")) == [pull(11)], p.groups
assert p.groups.get(("done", "other")) == [pull(15)], p.groups
assert p.groups.get(("more-week", "pilot")) == [pull(12)], p.groups
assert p.groups.get(("more-others", None)) == [pull(13)], p.groups
links = [h for hrefs in p.groups.values() for h in hrefs]
assert pull(14) not in links, links
assert links.count(pull(15)) == 1, links
PY
done_text=$(page_part done)
assert_contains "$done_text" 'Receipts show a diff' "a Done record that links a merged PR names the work once"
assert_not_contains "$done_text" 'receipt diff' "the absorbed PR's own title is not repeated"
assert_contains "$done_text" 'FOAK review packet sent' "a finished task archived today is done today"
assert_contains "$done_text" 'Pilot review' "done work sits under its initiative"
pass "Done today groups fleet work by initiative, once per piece of work, inside its time window"

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
printf 'working [at=%s]: fresh line the watcher must publish\n' "$(date +%s)" >> "$STATE/alpha-fix.status"
seen=0
for _ in $(seq 1 50); do
  if grep -q 'fresh line the watcher must publish' "$PAGE"; then seen=1; break; fi
  sleep 0.2
done
[ "$seen" -eq 1 ] || fail "watch did not publish a status append within 10s: $(cat "$TMP_ROOT/watch.log")"
assert_not_contains "$(page_part running-now)" 'Painting the banner.' "a keeper line older than the worker's newest status gives way to it"
pass "watch republishes the page after a status append"
