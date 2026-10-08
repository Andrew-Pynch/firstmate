#!/usr/bin/env python3
"""fm_md.py - the one small Markdown renderer behind firstmate's captain pages.

bin/fm-md-page.sh owns command-line usage. This header owns the supported
Markdown subset and the shared page theme.

Blocks: ATX headings, paragraphs, fenced code (``` or ~~~), block quotes,
nested bullet and numbered lists (with [ ] and [x] task items), pipe tables
with alignment, and horizontal rules. Inline: code spans, **strong**, *em*,
~~strike~~, [label](url), ![alt](src), <url>, and bare http(s) URLs.
Bare URLs show a short label (link_label) with the full URL as the title.
All other text is HTML-escaped: raw HTML in the source renders as text, and
only http, https, mailto, anchor, and relative link targets become links.

THEME_CSS is the single owner of the shared look (andrewpynch.com's NERV
palette: near-black panes, 2px geometry, orange accent, teal data, red alert,
monospace labels). No overlay ever sits on top of content: report pages carry no
background grid at all, and the captain page's faint grid stays behind its panes.
bin/fm-current-page.py imports it.
"""
import html
import json
import os
import re
import sys

e = html.escape

THEME_CSS = """
:root{--bg:#0a0a0f;--surface:#0d1117;--raised:#161b22;--pane:rgba(13,17,23,.92);
--fg:#e6edf3;--fg2:#8b949e;--dim:#484f58;--acc:#ff8800;--acc-dim:rgba(255,136,0,.2);--acc-hi:rgba(255,136,0,.45);
--data:#00ddaa;--data-dim:rgba(0,221,170,.18);--alert:#ff3366;--alert-dim:rgba(255,51,102,.18);--link:#7cc4ff;
--mono:"Share Tech Mono","JetBrainsMono Nerd Font","JetBrains Mono","CaskaydiaMono Nerd Font",ui-monospace,SFMono-Regular,Menlo,monospace;
--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--r:2px;--glow:0 0 20px rgba(255,136,0,.3)}
*{box-sizing:border-box}[hidden]{display:none!important}
html,body{margin:0;background:var(--bg);color:var(--fg)}
body{font:14px/1.5 var(--sans)}
a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
code{font:12.5px var(--mono);background:var(--raised);border:1px solid var(--acc-dim);border-radius:var(--r);padding:0 .3em;color:#ffd7a8}
.grid-bg{position:fixed;inset:0;pointer-events:none;z-index:-1;opacity:.6;
background-image:linear-gradient(rgba(255,136,0,.05) 1px,transparent 1px),linear-gradient(90deg,rgba(255,136,0,.05) 1px,transparent 1px);background-size:28px 28px}
.hazard{height:3px;opacity:.5;background:repeating-linear-gradient(90deg,var(--acc) 0 8px,transparent 8px 16px)}
.lbl{font:11px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--fg2)}
.kbd,kbd{font:11px var(--mono);color:var(--acc);border:1px solid var(--acc-dim);border-radius:var(--r);padding:0 .35em;background:rgba(255,136,0,.06)}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--data);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{box-shadow:0 0 4px var(--data)}50%{box-shadow:0 0 12px var(--data),0 0 24px var(--data)}}
@keyframes boot{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
@keyframes flash{0%{background:rgba(0,221,170,.35)}100%{background:transparent}}
@keyframes blink{50%{opacity:0}}
.overlay{position:fixed;inset:0;z-index:9000;background:rgba(5,5,8,.78);display:flex;align-items:center;justify-content:center;animation:boot .15s ease-out}
.overlay .box{background:var(--surface);border:1px solid var(--acc-hi);border-radius:var(--r);box-shadow:var(--glow);padding:18px 22px;min-width:420px;max-width:760px;max-height:80vh;overflow:auto}
.overlay h2{font:600 13px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--acc);margin:0 0 10px}
.keys{display:grid;grid-template-columns:auto 1fr;gap:6px 14px;font-size:13px;align-items:center}.keys kbd{justify-self:start}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
"""

MD_CSS = """
.md{font-size:15px;line-height:1.6}
.md h1,.md h2,.md h3,.md h4{font-family:var(--mono);letter-spacing:.04em;line-height:1.25;scroll-margin-top:56px}
.md h1{font-size:26px;color:var(--fg);margin:.2em 0 .6em}
.md h2{font-size:19px;color:var(--acc);border-bottom:1px solid var(--acc-dim);padding-bottom:.25em;margin:1.6em 0 .6em}
.md h3{font-size:16px;color:var(--data);margin:1.3em 0 .4em}.md h4{font-size:14px;color:var(--fg2);margin:1em 0 .3em}
.md p{margin:.55em 0}.md ul,.md ol{margin:.4em 0;padding-left:1.4em}.md li{margin:.2em 0}.md li::marker{color:var(--acc)}
.md li.task{list-style:none;margin-left:-1.2em}.md li.task input{margin-right:.5em;accent-color:var(--data)}
.md strong{color:#fff}.md em{color:#ffd7a8}.md del{color:var(--dim)}
.md blockquote{margin:.8em 0;padding:.4em 1em;border-left:3px solid var(--data);background:rgba(0,221,170,.05)}
.md pre{background:var(--surface);border:1px solid var(--acc-dim);border-radius:var(--r);padding:.8em 1em;overflow:auto}
.md pre code{border:0;background:none;padding:0;color:var(--fg);font-size:13px}
.md hr{border:0;margin:1.6em 0}.md hr::after{content:"";display:block;height:3px;opacity:.4;background:repeating-linear-gradient(90deg,var(--acc) 0 8px,transparent 8px 16px)}
.md .tbl{overflow:auto;margin:.8em 0;border:1px solid var(--acc-dim)}
.md table{border-collapse:collapse;font-size:13px;width:100%}
.md th{font:600 11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--acc);background:var(--raised);text-align:left;position:sticky;top:0}
.md th,.md td{padding:.4em .6em;border-bottom:1px solid rgba(255,255,255,.06);vertical-align:top}
.md tr:hover td{background:rgba(255,136,0,.05)}
.md img{max-width:100%;border:1px solid var(--acc-dim)}
"""


def link_label(url):
    """A short label for a full URL: PR #n, a Linear key, Slack, a design slug, or host plus last path part."""
    pr = re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/pull/(\d+)/?", url)
    if pr:
        return f"PR #{pr.group(1)}"
    linear = re.match(r"https://linear\.app/[^/]+/issue/([A-Za-z]+-\d+)", url)
    if linear:
        return linear.group(1).upper()
    if re.match(r"https://[\w.-]*slack\.com/", url):
        return "Slack"
    path = url.split("?", 1)[0].split("#", 1)[0].rstrip("/")
    host = path.split("/")[2] if path.count("/") >= 2 else path
    tail = path.rsplit("/", 1)[-1] if path.count("/") >= 3 else ""
    if re.search(r"/designs?/", path) and tail:
        return tail.removesuffix(".html")
    short = host.split(".")[0]
    return f"{short}/{tail.removesuffix('.html')}" if tail else short


def safe_href(url):
    url = url.strip()
    return url if re.match(r"(https?:|mailto:|#|\.{0,2}/|[\w.-]+(?:/|\.\w+|#|$))", url) and not re.match(r"\s*(javascript|data|vbscript):", url, re.I) else ""


URL_RE = re.compile(r"https?://[^\s<>\"'`]+")
INLINE_RE = re.compile(
    r"(?P<code>(`+)(?P<ctext>.+?)(?<!`)\2(?!`))"
    r"|(?P<img>!\[(?P<alt>[^\]]*)\]\((?P<src>[^)\s]+)\))"
    r"|(?P<link>\[(?P<label>[^\]]+)\]\((?P<href>[^)\s]+)(?:\s+\"[^\"]*\")?\))"
    r"|(?P<angle><(?P<aurl>https?://[^>\s]+)>)"
    r"|(?P<url>https?://[^\s<>\"'`]+)")


def _emphasis(escaped):
    out = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__", lambda m: f"<strong>{m.group(1) or m.group(2)}</strong>", escaped)
    out = re.sub(r"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])|(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])",
                 lambda m: f"<em>{m.group(1) or m.group(2)}</em>", out)
    return re.sub(r"~~(?=\S)(.+?)(?<=\S)~~", r"<del>\1</del>", out)


def _url_token(url):
    """Split trailing sentence punctuation (and an unbalanced close paren) off a bare URL."""
    trail = ""
    while url and (url[-1] in ".,;:!?*" or (url[-1] == ")" and url.count("(") < url.count(")"))):
        trail, url = url[-1] + trail, url[:-1]
    return url, trail


def first_url(text):
    """The first bare http(s) URL in text, without trailing punctuation; empty when there is none."""
    m = URL_RE.search(text)
    return _url_token(m.group())[0] if m else ""


def inline(text):
    """One line of inline Markdown to escaped HTML."""
    out, end = [], 0
    for m in INLINE_RE.finditer(text):
        out.append(_emphasis(e(text[end:m.start()], quote=False)))
        end = m.end()
        if m.group("code"):
            out.append(f"<code>{e(m.group('ctext').strip(), quote=False)}</code>")
        elif m.group("img"):
            src = safe_href(m.group("src"))
            out.append(f'<img src="{e(src)}" alt="{e(m.group("alt"))}" loading="lazy">' if src else e(m.group()))
        elif m.group("link"):
            href = safe_href(m.group("href"))
            label = _emphasis(e(m.group("label"), quote=False))
            label = re.sub(r"`([^`]+)`", r"<code>\1</code>", label)
            out.append(f'<a href="{e(href)}" title="{e(href)}">{label}</a>' if href else e(m.group()))
        else:
            url, trail = _url_token(m.group("aurl") or m.group("url"))
            out.append(f'<a href="{e(url)}" title="{e(url)}">{e(link_label(url))}</a>{e(trail)}')
    out.append(_emphasis(e(text[end:], quote=False)))
    return "".join(out)


LIST_RE = re.compile(r"^( *)([-*+]|\d{1,9}[.)])(?: +|$)(.*)$")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})\s*([\w+-]*)")
HR_RE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
HEAD_RE = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
TSEP_RE = re.compile(r"^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$")


def _cells(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line)]


class _Ids:
    def __init__(self):
        self.seen = {}

    def __call__(self, text):
        base = re.sub(r"[^\w]+", "-", re.sub(r"<[^>]+>", "", text).lower()).strip("-") or "section"
        n = self.seen.get(base, 0)
        self.seen[base] = n + 1
        return base if n == 0 else f"{base}-{n + 1}"


def block(text, ids=None, toc=None):
    """Markdown to escaped HTML; headings get ids, and (level, id, text) go to toc when given."""
    ids = ids or _Ids()
    lines = text.replace("\r\n", "\n").replace("\t", "    ").split("\n")
    out, i, n = [], 0, len(lines)

    def starts_block(line):
        return bool(FENCE_RE.match(line) or HEAD_RE.match(line) or HR_RE.match(line) or LIST_RE.match(line)
                    or line.lstrip().startswith(">"))

    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        fence = FENCE_RE.match(line)
        if fence:
            mark, lang, body = fence.group(1), fence.group(2), []
            i += 1
            while i < n and not re.match(r"^ {0,3}" + re.escape(mark[0]) + "{" + str(len(mark)) + r",}\s*$", lines[i]):
                body.append(lines[i])
                i += 1
            i += 1
            cls = f' class="lang-{e(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>{e(chr(10).join(body), quote=False)}</code></pre>")
            continue
        head = HEAD_RE.match(line)
        if head:
            level, body = len(head.group(1)), inline(head.group(2))
            hid = ids(body)
            if toc is not None:
                toc.append((level, hid, re.sub(r"<[^>]+>", "", body)))
            out.append(f'<h{level} id="{hid}">{body}</h{level}>')
            i += 1
            continue
        if HR_RE.match(line):
            out.append("<hr>")
            i += 1
            continue
        if "|" in line and i + 1 < n and TSEP_RE.match(lines[i + 1]) and "-" in lines[i + 1]:
            head_cells = _cells(line)
            aligns = []
            for c in _cells(lines[i + 1]):
                aligns.append("center" if c.startswith(":") and c.endswith(":") else "right" if c.endswith(":") else "")
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(_cells(lines[i]))
                i += 1

            def cell(tag, k, v):
                a = aligns[k] if k < len(aligns) else ""
                return f'<{tag}{f" style=text-align:{a}" if a else ""}>{inline(v)}</{tag}>'
            out.append('<div class="tbl"><table><thead><tr>' + "".join(cell("th", k, v) for k, v in enumerate(head_cells))
                       + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(cell("td", k, v) for k, v in enumerate(r)) + "</tr>" for r in rows)
                       + "</tbody></table></div>")
            continue
        if line.lstrip().startswith(">"):
            body = []
            while i < n and lines[i].strip() and (lines[i].lstrip().startswith(">") or not starts_block(lines[i])):
                body.append(re.sub(r"^\s*> ?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{block(chr(10).join(body), ids, toc)}</blockquote>")
            continue
        item = LIST_RE.match(line)
        if item:
            html_list, i = _list(lines, i, ids, toc)
            out.append(html_list)
            continue
        para = []
        while i < n and lines[i].strip() and not (para and starts_block(lines[i])) \
                and not ("|" in lines[i] and i + 1 < n and TSEP_RE.match(lines[i + 1]) and "-" in lines[i + 1]):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>" + " ".join(inline(x) for x in para) + "</p>")
    return "".join(out)


def _list(lines, i, ids, toc):
    """Parse one list starting at lines[i]; nested content is indented past the marker."""
    first = LIST_RE.match(lines[i])
    base, ordered = len(first.group(1)), first.group(2)[0].isdigit()
    items, n = [], len(lines)
    start = int(first.group(2)[:-1]) if ordered else 1
    while i < n:
        m = LIST_RE.match(lines[i])
        if not m or len(m.group(1)) > base + 1 or m.group(2)[0].isdigit() != ordered:
            break
        content_indent = len(m.group(1)) + len(m.group(2)) + 1
        body, loose = [m.group(3)], False
        i += 1
        while i < n:
            line = lines[i]
            if not line.strip():
                nxt = next((k for k in range(i + 1, n) if lines[k].strip()), None)
                if nxt is None:
                    break
                indent = len(lines[nxt]) - len(lines[nxt].lstrip())
                if indent >= content_indent or (indent > base and LIST_RE.match(lines[nxt])):
                    body.append("")
                    loose = loose or not LIST_RE.match(lines[nxt])
                    i += 1
                    continue
                break
            indent = len(line) - len(line.lstrip())
            if LIST_RE.match(line) and indent <= base + 1:
                break
            if indent == 0 and (HEAD_RE.match(line) or FENCE_RE.match(line) or HR_RE.match(line)):
                break
            body.append(line[min(indent, content_indent):] if indent >= 1 else line)
            i += 1
        items.append((body, loose))
        if i < n and not lines[i].strip():
            nxt = next((k for k in range(i, n) if lines[k].strip()), None)
            if nxt is not None and LIST_RE.match(lines[nxt]) and len(LIST_RE.match(lines[nxt]).group(1)) <= base + 1:
                i = nxt
    html_items = []
    for body, loose in items:
        cls = ""
        task = re.match(r"^\[([ xX])\]\s+", body[0])
        if task:
            cls = ' class="task"'
            body[0] = body[0][task.end():]
        inner = block("\n".join(body), ids, toc)
        if not loose and inner.startswith("<p>"):
            end = inner.find("</p>")
            inner = inner[3:end] + inner[end + 4:]
        if task:
            inner = f'<input type="checkbox" disabled{" checked" if task.group(1) != " " else ""}>' + inner
        html_items.append(f"<li{cls}>{inner}</li>")
    tag = "ol" if ordered else "ul"
    start_attr = f' start="{start}"' if ordered and start != 1 else ""
    return f"<{tag}{start_attr}>{''.join(html_items)}</{tag}>", i


PAGE_CSS = """
body{overflow:hidden}
header{position:fixed;top:0;left:0;right:0;height:44px;z-index:50;display:flex;align-items:center;gap:14px;padding:0 16px;
background:rgba(13,17,23,.95);backdrop-filter:blur(12px);border-bottom:2px solid var(--acc)}
header .brand{font:700 13px var(--mono);letter-spacing:.14em;color:var(--acc)}
header .title{font:600 14px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
#xp{position:fixed;top:44px;left:0;height:2px;background:var(--data);box-shadow:0 0 8px var(--data);width:0;z-index:51;transition:width .12s linear}
nav{position:fixed;top:46px;bottom:0;left:0;width:300px;overflow:auto;padding:14px 10px 40px;border-right:1px solid var(--acc-dim);background:rgba(13,17,23,.7)}
nav a{display:block;color:var(--fg2);padding:3px 8px;border-left:2px solid transparent;font-size:13px;line-height:1.35;border-radius:var(--r)}
nav a.l3{padding-left:22px;font-size:12px}nav a.l1{color:var(--fg);font-weight:600}
nav a.on{color:var(--acc);border-left-color:var(--acc);background:rgba(255,136,0,.07)}nav a.read:not(.on){color:var(--dim)}
nav a:hover{text-decoration:none;color:var(--fg)}
main{position:fixed;top:46px;bottom:0;left:300px;right:0;overflow:auto;padding:24px 48px 60vh}
main .md{max-width:920px;animation:boot .25s ease-out}
body.notoc nav{display:none}body.notoc main{left:0}body.notoc main .md{margin:auto}
.md section.fold>*:not(h2){display:none}.md section.fold>h2::after{content:" +";color:var(--dim)}
.md h2{cursor:pointer}
header a.back{font:600 12px var(--mono);letter-spacing:.06em;color:var(--acc);border:1px solid var(--acc-dim);border-radius:var(--r);padding:3px 10px;white-space:nowrap}
a.back.bottom{position:fixed;right:18px;bottom:14px;z-index:50;background:rgba(13,17,23,.95);font:600 12px var(--mono);color:var(--acc);
border:1px solid var(--acc);border-radius:var(--r);padding:6px 12px;box-shadow:var(--glow)}
header a.back:hover,a.back.bottom:hover{text-decoration:none;background:rgba(255,136,0,.12)}
"""

PAGE_JS = r"""
const M=document.querySelector("main"),heads=[...document.querySelectorAll(".md h1[id],.md h2[id],.md h3[id]")],
links=new Map([...document.querySelectorAll("nav a")].map(a=>[a.hash.slice(1),a])),xp=document.getElementById("xp"),
cnt=document.getElementById("cnt");let pend="",cur=0;
function sync(){const top=M.scrollTop+80;let k=0;heads.forEach((h,j)=>{if(h.offsetTop<=top)k=j;});cur=k;
 const max=M.scrollHeight-M.clientHeight;xp.style.width=(max>0?100*M.scrollTop/max:100)+"%";
 heads.forEach((h,j)=>{const a=links.get(h.id);if(a){a.classList.toggle("on",j===k);a.classList.toggle("read",j<k);}});
 const a=links.get(heads[k]&&heads[k].id);if(a)a.scrollIntoView({block:"nearest"});
 if(cnt)cnt.textContent=(k+1)+"/"+heads.length;}
M.addEventListener("scroll",()=>requestAnimationFrame(sync),{passive:true});
function go(j){j=Math.max(0,Math.min(heads.length-1,j));const h=heads[j];if(!h)return;
 const s=h.closest("section.fold");if(s)s.classList.remove("fold");M.scrollTo({top:h.offsetTop-12});cur=j;}
function sec(){const h=heads[cur];return h&&h.closest("section");}
document.querySelectorAll(".md h2").forEach(h=>h.addEventListener("click",()=>h.parentElement.classList.toggle("fold")));
const help=document.getElementById("help");
addEventListener("keydown",ev=>{if(ev.metaKey||ev.ctrlKey&&!"du".includes(ev.key)||ev.altKey)return;
 const k=(ev.ctrlKey?"^":"")+ev.key,two=pend+k;pend="";
 const act={j:()=>M.scrollBy({top:90}),k:()=>M.scrollBy({top:-90}),"^d":()=>M.scrollBy({top:M.clientHeight/2}),
  "^u":()=>M.scrollBy({top:-M.clientHeight/2}),d:()=>M.scrollBy({top:M.clientHeight/2}),u:()=>M.scrollBy({top:-M.clientHeight/2}),
  " ":()=>M.scrollBy({top:M.clientHeight*.85}),G:()=>M.scrollTo({top:M.scrollHeight}),gg:()=>M.scrollTo({top:0}),
  n:()=>go(cur+1),"]":()=>go(cur+1),J:()=>go(cur+1),p:()=>go(cur-1),"[":()=>go(cur-1),K:()=>go(cur-1),
  t:()=>document.body.classList.toggle("notoc"),za:()=>{const s=sec();if(s)s.classList.toggle("fold");},
  zM:()=>{document.querySelectorAll(".md section").forEach(s=>s.classList.add("fold"));M.scrollTo({top:0});},
  zR:()=>document.querySelectorAll(".md section").forEach(s=>s.classList.remove("fold")),
  gb:()=>{location.href=BACK;},"?":()=>help.hidden=!help.hidden,Escape:()=>help.hidden=true};
 const f=act[two]||act[k];if(f){ev.preventDefault();f();requestAnimationFrame(sync);}
 else if(k==="g"||k==="z")pend=k;});
help.addEventListener("click",()=>help.hidden=true);sync();
"""


def sectioned(body_html):
    """Wrap each h2 and what follows it in a <section> so a section can fold."""
    parts = re.split(r"(?=<h2 id=)", body_html)
    return parts[0] + "".join(f"<section>{p}</section>" for p in parts[1:])


BACK = "/current.html"  # the captain page every report links back to; same server root


def page(md_text, title=None):
    """A standalone, keyboard-driven HTML page for one Markdown report; the source rides along verbatim."""
    toc = []
    body = sectioned(block(md_text, toc=toc))
    if not title:
        title = next((t for level, _, t in toc if level == 1), "") or "Report"
    words = len(re.findall(r"\w+", md_text))
    nav = "".join(f'<a class="l{level}" href="#{hid}">{e(t)}</a>' for level, hid, t in toc if level <= 3)
    source = md_text.replace("</", "<\\/")
    help_rows = [("j / k", "scroll"), ("d / u, ^d / ^u, space", "half page / page"), ("n / p, J / K, ] / [", "next / previous heading"),
                 ("gg / G", "top / bottom"), ("t", "toggle the outline"), ("za / zM / zR", "fold this section / fold all / open all"),
                 ("gb", "back to current"), ("?", "this help"), ("Esc", "close")]
    keys = "".join(f"<kbd>{e(k)}</kbd><span>{e(v)}</span>" for k, v in help_rows)
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>{e(title)}</title><style>{THEME_CSS}{MD_CSS}{PAGE_CSS}</style></head><body>"
            f'<header><span class="brand">FM//REPORT</span><a class="back" href="{BACK}">&#8592; back to current</a>'
            f'<span class="title">{e(title)}</span>'
            f'<span class="lbl">{max(1, round(words / 230))} min · <span id="cnt"></span></span>'
            '<span class="lbl"><kbd>?</kbd> keys</span></header><div id="xp"></div>'
            f'<nav aria-label="Outline">{nav}</nav><main><article class="md">{body}</article></main>'
            f'<div class="overlay" id="help" hidden><div class="box"><h2>Keys</h2><div class="keys">{keys}</div></div></div>'
            f'<script type="text/markdown" id="md-src">{source}</script>'
            f'<a class="back bottom" href="{BACK}">&#8592; back to current</a>'
            f'<script>const BACK={json.dumps(BACK)};{PAGE_JS}</script></body></html>')


class _Source:
    """Pull the Markdown back out of a page: our embedded source, else the <pre> blocks of an older wrapper page."""

    def __init__(self, text):
        import html.parser
        self.title, self.md, self.pres, self.outside, self.links = "", None, [], 0, []
        outer = self

        class P(html.parser.HTMLParser):
            where, skip = None, 0

            def handle_starttag(self, tag, attrs):
                a = dict(attrs)
                if tag == "title":
                    self.where = "title"
                elif tag == "script" and a.get("id") == "md-src":
                    self.where, outer.md = "md", ""
                elif tag == "pre":
                    self.where = "pre"
                    outer.pres.append("")
                elif tag in ("style", "script", "h1", "h2"):
                    self.skip += 1
                elif tag == "a" and a.get("href") and not a["href"].startswith("#") and self.where is None:
                    outer.links.append([a["href"], ""])
                    self.where = "a"

            def handle_endtag(self, tag):
                if tag in ("title", "pre") or (tag, self.where) in (("a", "a"), ("script", "md")):
                    self.where = None
                elif tag in ("style", "script", "h1", "h2"):
                    self.skip = max(0, self.skip - 1)

            def handle_data(self, data):
                if self.where == "title":
                    outer.title += data
                elif self.where == "md":
                    outer.md += data
                elif self.where == "pre":
                    outer.pres[-1] += data
                elif self.where == "a":
                    outer.links[-1][1] += data
                elif not self.skip:
                    outer.outside += len(data.strip())

        P(convert_charrefs=True).feed(text)
        if self.md is not None:
            self.md = self.md.replace("<\\/", "</")


def load(path):
    """(markdown, title) from a .md file or an HTML page that carries Markdown; ValueError otherwise."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not re.search(r"\.html?$", path, re.I):
        return text, None
    src = _Source(text)
    if src.md is not None:
        return src.md, src.title.strip() or None
    # An older wrapper page: nothing but a title, file headings, a link line, and <pre> blocks that each open
    # with a Markdown heading. Anything richer is a real HTML page and stays as it is.
    if src.pres and src.outside <= 300 and all(re.match(r"#{1,3} ", p.lstrip()) for p in src.pres):
        links = " · ".join(f"[{t.strip() or h}]({h})" for h, t in src.links)
        return (links + "\n\n" if links else "") + "\n\n---\n\n".join(p.strip("\n") for p in src.pres), src.title.strip() or None
    raise ValueError(f"{path}: not a Markdown page (no embedded source, and not a wrapper of <pre> blocks that open with a heading)")


def write_atomic(path, content):
    d = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(d, f".{os.path.basename(path)}.tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, path)


def main(argv):
    args, out, title, srcs = list(argv), None, None, []
    while args:
        a = args.pop(0)
        if a in ("-o", "--out") and args:
            out = args.pop(0)
        elif a == "--title" and args:
            title = args.pop(0)
        elif a.startswith("-") and a != "-":
            print(f"fm-md-page: unknown option {a}", file=sys.stderr)
            return 2
        else:
            srcs.append(a)
    if not srcs or (out and len(srcs) > 1):
        print("usage: fm-md-page.sh <report.md|page.html>... | <src> -o <out.html> [--title <t>]", file=sys.stderr)
        return 2
    code = 0
    for src in srcs:
        try:
            md_text, found = load(src)
        except (OSError, ValueError) as exc:
            print(f"fm-md-page: {exc}", file=sys.stderr)
            code = 1
            continue
        dest = out or (src if re.search(r"\.html?$", src, re.I) else re.sub(r"\.(md|markdown)$", "", src) + ".html")
        write_atomic(dest, page(md_text, title or found))
        print(dest)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
