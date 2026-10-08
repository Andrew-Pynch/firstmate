#!/usr/bin/env bash
# tests/fm-md-page.test.sh - Markdown reports become readable pages; real HTML pages are never rewritten.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-md-page)
trap fm_test_cleanup EXIT
cd "$TMP_ROOT"

cat > report.md <<'MD'
# Council report

Intro with `code <b>` and https://github.com/example/repo/pull/12. Then <script>alert(1)</script> as text.

## Ranked wave

| # | Task | Ticket |
|---|------|-------:|
| 1 | Fix the **import** | STA-1 |

- top item
  - nested item
- [x] done item

```sh
echo "<kept>"
```

[bad link](javascript:alert(1))
MD
"$ROOT/bin/fm-md-page.sh" report.md >/dev/null
page=$(cat report.html)
assert_contains "$page" '<h2 id="ranked-wave">Ranked wave</h2>' "headings render with anchors"
assert_contains "$page" '<td>Fix the <strong>import</strong></td>' "tables render with inline Markdown"
assert_contains "$page" '<th style=text-align:right>Ticket</th>' "table alignment is kept"
assert_contains "$page" '<li>top item<ul><li>nested item</li></ul></li>' "nested lists nest"
assert_contains "$page" 'title="https://github.com/example/repo/pull/12">PR #12</a>.' "bare URLs get a short label and keep sentence punctuation outside"
assert_contains "$page" '&lt;script&gt;alert(1)&lt;/script&gt;' "raw HTML in the source renders as text"
assert_not_contains "$page" 'href="javascript:' "unsafe link targets never become links"
assert_contains "$page" '<pre><code class="lang-sh">echo "&lt;kept&gt;"</code></pre>' "code fences keep their text"
pass "a Markdown report renders as one page"

cp report.html first.html
"$ROOT/bin/fm-md-page.sh" report.html >/dev/null
cmp -s first.html report.html || fail "re-rendering a rendered page changed it"
pass "re-rendering a rendered page is lossless and idempotent"

printf '<!doctype html><title>Old wrapper</title><h1>Old wrapper</h1><p><a href="sibling.html">Ranked findings</a></p><pre># Heading\n\n- [ ] open <a href="https://x.example/a">https://x.example/a</a> item\n</pre>' > wrapper.html
"$ROOT/bin/fm-md-page.sh" wrapper.html >/dev/null
page=$(cat wrapper.html)
assert_contains "$page" '<a href="sibling.html" title="sibling.html">Ranked findings</a>' "the wrapper's link line survives"
assert_contains "$page" '<li class="task"><input type="checkbox" disabled>open <a href="https://x.example/a"' "Markdown inside the old <pre> renders, links intact"
assert_contains "$page" '<title>Old wrapper</title>' "the old page title is kept"
pass "an older <pre> wrapper page upgrades in place"

printf '<!doctype html><title>Real page</title><h1>Real</h1><p>%s</p><pre># not the whole page</pre>' "$(printf 'x%.0s' $(seq 1 400))" > real.html
cp real.html real.orig
out=$("$ROOT/bin/fm-md-page.sh" real.html 2>&1) && code=0 || code=$?
expect_code 1 "$code" "a real HTML page is refused"
assert_contains "$out" 'not a Markdown page' "the refusal names the reason"
cmp -s real.html real.orig || fail "a refused page was modified"
pass "a real HTML page is never rewritten"
