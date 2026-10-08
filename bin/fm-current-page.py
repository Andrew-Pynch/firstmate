#!/usr/bin/env python3
"""fm-current-page.py - implementation behind bin/fm-current-page.sh.

The shell wrapper's header owns usage, configuration, and triggers.
This header owns the keeper's current-notes.md format:
  - HH:MM <kind> <text>
One event per line, using a local 24-hour time.
Kinds: merged, fixed, live (green), decided (blue), needs (amber), blocked
(red), info (gray); an unknown kind displays as info.
Optional ## YYYY-MM-DD headings date the following events; events before a
date heading use the notes file's local modification date.
Events sort newest first, grouped by date, with today's first 15 shown.
More events today and other days sit behind closed details toggles.
Full HTTP(S) URLs become links, GitHub pull URLs display as PR #<number>,
and /design/ or /designs/ URLs display their final slug without .html.
Other lines keep their existing Markdown rendering without timeline styling.
"""
import datetime as dt
import fcntl
import html
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(SCRIPT_DIR)
HOME = os.environ.get("FM_HOME") or CODE_ROOT
STATE = os.path.join(HOME, "state")
DATA = os.path.join(HOME, "data")
PRIVATE = os.path.join(STATE, ".current-page")
FOLD = os.path.join(PRIVATE, "fold")
FORGE_CACHE = os.path.join(PRIVATE, "merged.json")
LOCK = os.path.join(PRIVATE, "render.lock")

KNOWN_VERBS = {"working", "needs-decision", "blocked", "paused", "done", "failed", "resolved", "note"}
ACTIVE_VERBS = {"working", "needs-decision", "blocked", "none", "note", "resolved"}
BADGE = {"working": "#238636", "needs-decision": "#9e6a03", "blocked": "#da3633", "failed": "#da3633",
         "paused": "#57606a", "done": "#8957e5", "resolved": "#238636", "note": "#57606a", "none": "#57606a"}
LINE_RE = re.compile(r"^\s*([A-Za-z][\w-]*)((?:\s*\[[^\]]*\])*)\s*:?\s*(.*)$", re.S)
AT_RE = re.compile(r"\[at=(\d+)\]")
PR_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")
e = html.escape


def env_int(name, default):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    if not raw.isdigit() or int(raw) <= 0:
        sys.exit(f"fm-current-page: {name} must be a positive integer")
    return int(raw)


def local_host():
    return os.environ.get("FM_CURRENT_PAGE_HOST") or socket.gethostname().split(".")[0]


# ---------- durable sources ----------

def read_meta(path):
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    meta[k] = v
    except OSError:
        pass
    return meta


def last_line(path):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 65536))
            chunk = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    for line in reversed(chunk.splitlines()):
        if line.strip():
            return line
    return None


def parse_line(line):
    """Return (verb, note, at) for one status line; verb is a display word only."""
    if not line:
        return "none", "", None
    m = LINE_RE.match(line)
    verb, note = (m.group(1).lower(), m.group(3)) if m else ("note", line)
    if verb not in KNOWN_VERBS:
        verb, note = "note", line
    at = AT_RE.search(line)
    return verb, note.strip(), int(at.group(1)) if at else None


def mtime(path):
    try:
        return int(os.stat(path).st_mtime)
    except OSError:
        return None


def parse_secondmates():
    """data/secondmates.md: '- <id> - <charter> (host: h; root: r; ...; projects: a, b; added d)'."""
    mates = {}
    try:
        with open(os.path.join(DATA, "secondmates.md"), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return mates
    for line in lines:
        m = re.match(r"^- (\S+) - (.*)$", line)
        if not m:
            continue
        mid, rest = m.group(1), m.group(2)
        fields, desc = {}, rest
        cut = rest.rfind("(host:")
        if cut >= 0:
            desc = rest[:cut].strip()
            for part in rest[cut + 1:].rstrip(")").split(";"):
                if ":" in part:
                    k, v = part.split(":", 1)
                    fields[k.strip()] = v.strip()
        first = re.split(r"(?<=[.;])\s", desc, maxsplit=1)[0].rstrip(".;")
        mates[mid] = {"host": fields.get("host", ""), "scope": first[:200],
                      "projects": [p.strip() for p in fields.get("projects", "").split(",") if p.strip()]}
    return mates


TRUNC_RE = re.compile(r"\s*\.\.\. \(truncated, \d+ chars total[^)]*\)\s*$")


def toon_cells(row):
    """Split one TOON table row: comma-separated, double-quoted cells carry backslash escapes."""
    cells, cur, quoted, i = [], [], False, 0
    while i < len(row):
        ch = row[i]
        if quoted and ch == "\\" and i + 1 < len(row):
            nxt = row[i + 1]
            cur.append({"n": "\n", "t": "\t", "r": ""}.get(nxt, nxt))
            i += 2
            continue
        if ch == '"':
            quoted = not quoted
        elif ch == "," and not quoted:
            cells.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    cells.append("".join(cur))
    return [" ".join(TRUNC_RE.sub("…", c).split()) for c in cells]


def toon_rows(text):
    """Parse the tabular TOON block tasks-axi prints: 'name[N]{a,b}:' then one row per indented line."""
    rows, fields = [], None
    for line in text.splitlines():
        head = re.match(r"^\w+\[\d+\]\{([^}]*)\}:\s*$", line)
        if head:
            fields = head.group(1).split(",")
            continue
        if fields is None:
            continue
        if not line.startswith("  ") or line.startswith("  - "):
            fields = None
            continue
        cells = toon_cells(line.strip())
        if len(cells) == len(fields):
            rows.append(dict(zip(fields, cells)))
    return rows


def tasks_axi(*args):
    try:
        res = subprocess.run([os.path.join(SCRIPT_DIR, "fm-tasks-axi.sh"), *args], capture_output=True,
                             text=True, timeout=60, env={**os.environ, "FM_HOME": HOME})
    except (OSError, subprocess.TimeoutExpired):
        return None
    return toon_rows(res.stdout) if res.returncode == 0 else None


def registry_repos():
    """GitHub repos named in data/projects.md: '- <name> [...] ... - Owner/Repo: ...'."""
    repos = {}
    try:
        with open(os.path.join(DATA, "projects.md"), encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^- (\S+) .*? - ([\w.-]+/[\w.-]+):", line)
                if m:
                    repos[m.group(2)] = m.group(1)
    except OSError:
        pass
    return repos


def merged_prs(repos):
    """Merged PRs in the last 24 h, cached under state/.current-page for FM_CURRENT_PAGE_FORGE_TTL."""
    ttl = env_int("FM_CURRENT_PAGE_FORGE_TTL", 300)
    cache = {}
    try:
        with open(FORGE_CACHE, encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        cache = {}
    if os.environ.get("FM_CURRENT_PAGE_NO_FORGE") or not repos or not shutil.which("gh"):
        return cache.get("items", []), cache.get("fetched"), cache.get("viewer", ""), "skipped"
    if cache.get("fetched") and time.time() - cache["fetched"] < ttl and cache.get("repos") == sorted(repos):
        return cache["items"], cache["fetched"], cache.get("viewer", ""), "cached"
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400))
    query = "is:pr is:merged merged:>=" + since + "".join(" repo:" + r for r in sorted(repos))
    items, err = [], None
    try:
        viewer = cache.get("viewer") or subprocess.run(
            ["gh", "api", "user", "--jq", ".login"], capture_output=True, text=True, timeout=20).stdout.strip()
        for page in (1, 2, 3):
            res = subprocess.run(["gh", "api", "-X", "GET", "search/issues", "-f", "q=" + query, "-f", "per_page=100",
                                  "-f", f"page={page}", "--jq",
                                  '.items[] | {url: .html_url, merged: .pull_request.merged_at, author: .user.login, title: .title}'],
                                 capture_output=True, text=True, timeout=30)
            if res.returncode != 0:
                err = (res.stderr.strip().splitlines() or ["gh failed"])[-1]
                break
            batch = [json.loads(x) for x in res.stdout.splitlines() if x.strip()]
            items += batch
            if len(batch) < 100:
                break
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        err = str(exc)
    if err:
        return cache.get("items", []), cache.get("fetched"), cache.get("viewer", ""), "stale: " + err[:120]
    cache = {"fetched": int(time.time()), "repos": sorted(repos), "viewer": viewer, "items": items}
    write_atomic(FORGE_CACHE, json.dumps(cache))
    return items, cache["fetched"], viewer, "fresh"


def sync_fold_shadow():
    """Mirror state/*.status as hard links (plus each task's kind) into a private fold directory.

    The open-decision fold that the wake drain uses is incremental: it keeps a byte cursor beside
    every status file. Folding the shadow keeps those cursors private to this page, so the drain's
    own cursors and presentation records are never touched, while a hard link still reads every
    append the instant it lands.
    """
    os.makedirs(FOLD, exist_ok=True)
    live = set()
    for name in os.listdir(STATE):
        if not name.endswith(".status"):
            continue
        src = os.path.join(STATE, name)
        if os.path.islink(src) or not os.path.isfile(src):
            continue
        task = name[:-len(".status")]
        live.add(task)
        dst = os.path.join(FOLD, name)
        try:
            if not os.path.exists(dst) or os.stat(dst).st_ino != os.stat(src).st_ino:
                if os.path.lexists(dst):
                    os.unlink(dst)
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copyfile(src, dst)
        except OSError:
            continue
        kind = read_meta(os.path.join(STATE, task + ".meta")).get("kind")
        kind_path = os.path.join(FOLD, task + ".meta")
        want = f"kind={kind}\n" if kind else None
        have = None
        if os.path.exists(kind_path):
            with open(kind_path, encoding="utf-8") as fh:
                have = fh.read()
        if want != have:
            if want is None:
                os.unlink(kind_path)
            else:
                write_atomic(kind_path, want)
    for name in os.listdir(FOLD):
        task = re.sub(r"^\.|\.open-decisions-cursor$|\.status$|\.meta$", "", name)
        if task not in live:
            os.unlink(os.path.join(FOLD, name))


def open_decisions():
    sync_fold_shadow()
    script = 'source "$1/fm-classify-lib.sh" && scan_open_decisions_incremental "$2"'
    res = subprocess.run(["bash", "-c", script, "fm-current-page", SCRIPT_DIR, FOLD],
                         capture_output=True, text=True, timeout=300)
    out = []
    for line in res.stdout.splitlines():
        parts = line.split("\t", 3)
        if len(parts) == 4:
            out.append({"task": parts[0], "key": parts[1], "verb": parts[2], "note": parts[3]})
    return out


# ---------- curated file and notes ----------

def parse_curated(path):
    """The keeper's curated JSON; bin/fm-current-page.sh's header owns the field list."""
    empty = {"next": None, "needs": [], "why": {}, "mates": {}, "plain": {}, "hide": set(), "error": ""}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {**empty, "error": f"{os.path.basename(path)} not found"}
    except (OSError, ValueError) as exc:
        return {**empty, "error": f"{os.path.basename(path)} unreadable ({str(exc)[:120]})"}
    if not isinstance(data, dict):
        return {**empty, "error": f"{os.path.basename(path)} is not a JSON object"}

    def strmap(key):
        val = data.get(key)
        return {str(k): str(v) for k, v in val.items()} if isinstance(val, dict) else {}
    nx = data.get("next")
    hide = data.get("hide")
    return {"next": nx if isinstance(nx, dict) else None,
            "needs": [n for n in data.get("needs") or [] if isinstance(n, dict)],
            "why": strmap("why"), "plain": strmap("plain"),
            "hide": {str(h) for h in hide} if isinstance(hide, list) else set(),
            "mates": data.get("mates") if isinstance(data.get("mates"), dict) else {},
            "error": ""}


def parse_notes(path):
    """Read dated timeline events and preserve legacy Markdown."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
            day = dt.datetime.fromtimestamp(os.fstat(fh.fileno()).st_mtime).date()
    except OSError:
        return {"free": "", "events": [], "missing": True}
    free, events = [], []
    for line in text.splitlines():
        if re.match(r"^#\s+current-notes\s*$", line, re.I):
            continue
        heading = re.fullmatch(r"##\s+(\d{4}-\d{2}-\d{2})\s*", line)
        if heading:
            try:
                day = dt.date.fromisoformat(heading.group(1))
                continue
            except ValueError:
                pass
        event = re.fullmatch(r"- ([01]\d|2[0-3]):([0-5]\d) ([\w-]+) (.+)", line)
        if not event:
            free.append(line)
            continue
        hour, minute, kind, note = event.groups()
        kind = kind if kind in {"merged", "fixed", "live", "decided", "needs", "blocked", "info"} else "info"
        events.append({"day": day.isoformat(), "time": f"{hour}:{minute}", "kind": kind, "text": note})
    events.sort(key=lambda row: (row["day"], row["time"]), reverse=True)
    return {"free": "\n".join(free).strip(), "events": events, "missing": False}


def inline_md(text):
    out = e(text)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+|[\w./#-]+)\)", r'<a href="\2">\1</a>', out)
    out = re.sub(r'(?<![">])(https?://[^\s<]+)', r'<a href="\1">\1</a>', out)
    return out


def block_md(text):
    html_out, para, items = [], [], []

    def flush():
        if para:
            html_out.append("<p>" + inline_md(" ".join(para)) + "</p>")
            para.clear()
        if items:
            html_out.append("<ul>" + "".join("<li>" + inline_md(i) + "</li>" for i in items) + "</ul>")
            items.clear()
    for line in text.splitlines():
        if not line.strip():
            flush()
            continue
        h = re.match(r"^(#{1,4})\s+(.*)$", line)
        li = re.match(r"^\s*(?:[-*]|\d+\.)\s+(.*)$", line)
        if h:
            flush()
            html_out.append(f"<h3>{inline_md(h.group(2))}</h3>")
        elif li:
            if para:
                flush()
            items.append(li.group(1))
        elif items and line.startswith("  "):
            items[-1] += " " + line.strip()
        else:
            if items:
                flush()
            para.append(line.strip())
    flush()
    return "".join(html_out)


def note_links(text):
    """Keep inline Markdown while shortening full PR and design URLs."""
    out, end = [], 0
    for match in re.finditer(r"\[[^\]]+\]\(https?://[^)\s]+\)|https?://[^\s<>]+", text):
        out.append(inline_md(text[end:match.start()]))
        token = match.group()
        if token.startswith("["):
            label, url = token[1:].split("](", 1)
            url, trailing = url[:-1], ""
        else:
            url = token.rstrip(".,;:!?)")
            trailing = token[len(url):]
            label = url
            if PR_RE.fullmatch(url):
                label = f'PR #{url.rsplit("/", 1)[1]}'
            elif re.search(r"/designs?/", url):
                label = url.split("?", 1)[0].split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]
                label = label.removesuffix(".html")
        out.append(f'<a href="{e(url)}">{e(label)}</a>{e(trailing)}')
        end = match.end()
    out.append(inline_md(text[end:]))
    return "".join(out)


def notes_timeline(notes, today):
    """Render at most 15 events initially, with overflow and history folded."""
    groups = {}
    for row in notes["events"]:
        groups.setdefault(row["day"], []).append(row)

    def rows_html(rows):
        return '<ol class="timeline">' + "".join(
            f'<li class="note-event"><time datetime="{row["day"]}T{row["time"]}">{row["time"]}</time>'
            f'<span class="note-kind {row["kind"]}">{row["kind"]}</span>'
            f'<div class="note-text">{note_links(row["text"])}</div></li>' for row in rows) + "</ol>"

    out = []
    if groups:
        day = today.isoformat()
        rows = groups.pop(day, [])
        out.append(f'<h3>Today · <time datetime="{day}">{today.strftime("%a, %d %b %Y")}</time></h3>')
        out.append(rows_html(rows[:15]) if rows else '<p class="k">No events today.</p>')
        if len(rows) > 15:
            out.append(f'<details><summary>{len(rows) - 15} more today</summary>{rows_html(rows[15:])}</details>')
        if groups:
            count = sum(len(rows) for rows in groups.values())
            out.append(f'<details class="notes-history"><summary>Other days · {count} event{"s" if count != 1 else ""}</summary>')
            for day, rows in groups.items():
                label = dt.date.fromisoformat(day).strftime("%a, %d %b %Y")
                out.append(f'<h3><time datetime="{day}">{label}</time></h3>{rows_html(rows)}')
            out.append("</details>")
    if notes["free"]:
        out.append(block_md(notes["free"]))
    return "".join(out)


def need_message(need):
    """Optional recipient-ready message: verbatim text, inline code shown as code, one Copy for the raw text."""
    message = need.get("message")
    if not isinstance(message, str) or not message.strip():
        return ""
    to = need.get("to")
    if isinstance(to, list):
        to = ", ".join(str(x) for x in to if str(x).strip())
    head = f'<b>Message{" to " + e(to) if isinstance(to, str) and to.strip() else ""}</b>'
    parts, end = [], 0
    for match in re.finditer(r"`([^`\n]+)`", message):
        parts.append(e(message[end:match.start()]))
        parts.append(f"<code>{e(match.group(1))}</code>")
        end = match.end()
    parts.append(e(message[end:]))
    # The parser folds a raw CR into LF, so a character reference keeps the copied text byte-exact.
    raw = e(message).replace("\r", "&#13;")
    return (f'<div class="need-message"><div class="need-message-head">{head}'
            f'<button type="button" class="copy-message" data-copy="{raw}" aria-label="Copy message">Copy message</button></div>'
            f'<blockquote>{"".join(parts)}</blockquote></div>')


def need_details(need):
    """Optional action, message, and recommendation, leaving legacy needs unchanged."""
    out = []
    action = need.get("do")
    if isinstance(action, str) and action.strip():
        parts, end = [], 0
        for match in re.finditer(r"`([^`]+)`", action):
            parts.append(inline_md(action[end:match.start()]))
            parts.append(f'<span class="need-command"><code>{e(match.group(1))}</code>'
                         '<button type="button" class="copy-command" aria-label="Copy command">Copy</button></span>')
            end = match.end()
        parts.append(inline_md(action[end:]))
        out.append(f'<div class="need-action"><b>Do</b><div>{"".join(parts)}</div></div>')
    out.append(need_message(need))
    options = need.get("options")
    if isinstance(options, list):
        chips = []
        for option in options:
            if not isinstance(option, str) or not option.strip():
                continue
            recommended = option == need.get("rec")
            chips.append(f'<span class="need-option{" recommended" if recommended else ""}">{e(option)}'
                         f'{" <b>Recommended</b>" if recommended else ""}</span>')
        if chips:
            out.append(f'<div class="need-options" aria-label="Options">{"".join(chips)}</div>')
    return "".join(out)


# ---------- model ----------

def build_rows(mates, titles, why):
    here = local_host()
    rows = []
    for name in sorted(os.listdir(STATE)):
        if not name.endswith(".meta"):
            continue
        task = name[:-5]
        meta = read_meta(os.path.join(STATE, name))
        status = os.path.join(STATE, task + ".status")
        line = last_line(status)
        verb, note, at = parse_line(line)
        updated = at or mtime(status) or mtime(os.path.join(STATE, name))
        kind = meta.get("kind", "ship")
        project_path = meta.get("project", "")
        projects = []
        if meta.get("project_token"):
            projects.append(meta["project_token"])
        if project_path:
            base = os.path.basename(project_path.rstrip("/"))
            projects.append("firstmate" if os.path.realpath(project_path) == os.path.realpath(HOME) else base)
        if kind == "secondmate":
            mate = task
            info = mates.get(task, {})
            host = meta.get("remote_host") or info.get("host") or here
            projects = list(dict.fromkeys(info.get("projects") or meta.get("projects", "").split(",")))
            title = why.get(task) or info.get("scope") or task
        else:
            mate = "Main"
            host = meta.get("remote_host") or here
            title = why.get(task) or titles.get(task) or task
        pr = meta.get("pr", "")
        found = PR_RE.findall(note)
        if found:
            pr = found[-1]
        rows.append({"task": task, "kind": kind, "mate": mate, "host": host, "projects": [p for p in dict.fromkeys(projects) if p],
                     "model": meta.get("model", ""), "worktree": meta.get("worktree", ""), "verb": verb, "note": note,
                     "updated": updated, "pr": pr, "title": title,
                     "subtitle": titles.get(task, "") if titles.get(task, "") != title else ""})
    return rows


def ago(ts, now):
    if not ts:
        return "never"
    s = max(0, int(now - ts))
    if s < 90:
        return f"{s}s ago"
    if s < 3600:
        return f"{s // 60}m ago"
    if s < 86400:
        return f"{s // 3600}h{(s % 3600) // 60:02d}m ago"
    return f"{s // 86400}d ago"


def clock(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%a %H:%M") if ts else "-"


def attrs(host, mate, projects):
    out = []
    if host:
        out.append(f'data-m="{e(host)}"')
    if mate:
        out.append(f'data-g="{e(mate)}"')
    if projects:
        out.append(f'data-p="{e(" ".join(projects))}"')
    return " ".join(out)


def badge(verb):
    return f'<span class="b" style="background:{BADGE.get(verb, "#57606a")}">{e(verb)}</span>'


def clip(text, n):
    return text if len(text) <= n else text[:n].rstrip() + "…"


def plain_words(text, n=200):
    """Raw status text made captain-readable: no home paths, links, or [name=value] tags."""
    text = re.sub(r"\S*data/\S+", "", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\[[a-z_]+=[^\]]*\]\s*", "", text)
    return clip(re.sub(r"\s+", " ", text).strip(), n)


def render(paths, reason):
    now = time.time()
    notes = parse_notes(paths["notes"])
    cur = parse_curated(paths["curated"])
    mates = parse_secondmates()
    for mid, info in cur["mates"].items():
        if mid in mates and isinstance(info, dict):
            mates[mid]["host"] = info.get("machine") or mates[mid]["host"]
            mates[mid]["scope"] = info.get("scope") or mates[mid]["scope"]
    backlog = tasks_axi("list", "--limit", "2000")
    titles = {r["id"]: r.get("title", "") for r in (backlog or []) if r.get("id")}
    held = tasks_axi("list", "--state", "held", "--limit", "2000", "--fields", "hold_kind,hold_until,hold_reason")
    rows = build_rows(mates, titles, cur["why"])
    by_task = {r["task"]: r for r in rows}
    decisions = open_decisions()
    repos = registry_repos()
    landed, fetched, viewer, forge_state = merged_prs(repos)
    here = local_host()

    machines = list(dict.fromkeys([here] + [m["host"] for m in mates.values() if m["host"]] + [r["host"] for r in rows]))
    mate_names = list(dict.fromkeys(["Main"] + list(mates) + [r["mate"] for r in rows]))
    project_names = sorted({p for r in rows for p in r["projects"]} | set(repos.values()))

    def chips(dim, label, values):
        btn = [f'<button class="chip on" data-dim="{dim}" data-v="all">All</button>']
        btn += [f'<button class="chip" data-dim="{dim}" data-v="{e(v)}">{e(v)}</button>' for v in values]
        return f'<div class="chips"><span class="lbl">{label}</span>{"".join(btn)}</div>'

    # Needs you and NEXT come only from the curated file; raw status lines never reach them.
    need_cards = []
    for n in cur["needs"]:
        who = str(n.get("who", ""))
        row = by_task.get(who)
        mate = row["mate"] if row else (who if who in mates else "Main")
        host = n.get("machine") or (row["host"] if row else mates.get(who, {}).get("host") or here)
        projects = row["projects"] if row else mates.get(who, {}).get("projects", [])
        need_cards.append(
            f'<div class="card need f" {attrs(host, mate, projects)}><b>{e(str(n.get("t", "")))}</b>'
            f'{need_details(n)}'
            f'<div class="why">{inline_md(str(n.get("why", "")))}</div>'
            f'<div class="k">{e(host)} / {e(mate)}{" / <code>" + e(who) + "</code>" if who else ""}</div></div>')
    nx = cur["next"]
    if nx and nx.get("do"):
        unblocks = f' Unblocks: {inline_md(str(nx["unblocks"]))}.' if nx.get("unblocks") else ""
        next_html = (f'<p><b>{inline_md(str(nx["do"]))}</b></p>'
                     f'<p class="k">{inline_md(str(nx.get("why", "")))}{unblocks}</p>')
    else:
        next_html = "<p><b>Nothing curated as next.</b></p>"
    if cur["error"]:
        next_html += f'<p class="k">Curated file problem: {e(cur["error"])}</p>'

    # Still-open decision records (resolved keys already folded away) show as a count on each live card.
    grouped = {}
    for d in decisions:
        grouped.setdefault(d["task"], []).append(d)

    # Live workstreams: active first, then parked/finished in a fold. Card text is the curated
    # plain line when one exists, else the last status line reduced to plain words.
    def card(r):
        pr = (f'<a href="{e(r["pr"])}">PR #{e(r["pr"].rsplit("/", 1)[1])}</a>' if r["pr"] else "")
        bits = [e(r["host"]), e(r["mate"]), f'<code>{e(r["task"])}</code>', e(r["kind"])]
        if r["projects"]:
            bits.append(e(" · ".join(r["projects"])))
        if r["model"]:
            bits.append(e(r["model"].split("/")[-1]))
        sub = f'<div class="why">{e(r["subtitle"])}</div>' if r["subtitle"] else ""
        text = cur["plain"].get(r["task"]) or plain_words(r["note"])
        n_open = len(grouped.get(r["task"], []))
        opened = f' · {n_open} open decision{"s" if n_open > 1 else ""}' if n_open else ""
        wt = f' · <span title="{e(r["worktree"])}">{e(clip(r["worktree"], 60))}</span>' if r["worktree"] else ""
        foot = " · ".join(x for x in (pr, f'updated {clock(r["updated"])} ({ago(r["updated"], now)})') if x)
        return (f'<div class="card f" {attrs(r["host"], r["mate"], r["projects"])}><div class="top"><b>{e(r["title"])}</b>{badge(r["verb"])}</div>'
                f'<div class="k">{" / ".join(bits)}</div>{sub}{f"<div class=st>{e(text)}</div>" if text else ""}'
                f'<div class="k">{foot}{opened}{wt}</div></div>')
    rows = [r for r in rows if r["task"] not in cur["hide"]]
    mate_rank = {m: i for i, m in enumerate(mate_names)}
    rows.sort(key=lambda r: (mate_rank.get(r["mate"], 99), -(r["updated"] or 0)))
    quiet_after = env_int("FM_CURRENT_PAGE_QUIET_HOURS", 48) * 3600
    active = [r for r in rows if r["kind"] == "secondmate" or r["task"] in grouped
              or (r["verb"] in ACTIVE_VERBS and now - (r["updated"] or 0) < quiet_after)]
    parked = [r for r in rows if r not in active]

    # Landed: fleet PRs (authored by the forge identity the workers use), then everyone else folded.
    pr_task = {r["pr"]: r for r in rows if r["pr"]}
    landed.sort(key=lambda x: x.get("merged") or "", reverse=True)

    def landed_li(x):
        url = x.get("url", "")
        if not url.startswith("https://"):
            return ""
        parts = url.split("/")
        repo = "/".join(parts[3:5])
        project = repos.get(repo, parts[4])
        r = pr_task.get(url)
        try:
            ts = dt.datetime.fromisoformat(x["merged"].replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError, AttributeError):
            ts = None
        who = "" if x.get("author") == viewer else f' <span class="k">by {e(x.get("author", ""))}</span>'
        return (f'<li class="f" {attrs(r["host"] if r else "", r["mate"] if r else "", [project])}>'
                f'<a href="{e(url)}">{e(project)} #{e(parts[-1])}</a> {e(x.get("title", ""))}{who}'
                f' <span class="k">{clock(ts)}</span></li>')
    fleet = [landed_li(x) for x in landed if x.get("author") == viewer]
    others = [landed_li(x) for x in landed if x.get("author") != viewer]
    forge_note = {"fresh": "", "cached": "", "skipped": " (GitHub read skipped)"}.get(
        forge_state, f" (GitHub read failed, showing {clock(fetched)}: {forge_state[7:]})")
    landed_html = (f'<p class="k">Last 24 h across {len(repos)} registered repos, as of {clock(fetched)}{e(forge_note)}.</p>'
                   f'<ul>{"".join(fleet) or "<li class=k>none from the fleet</li>"}</ul>'
                   + (f'<details><summary>{len(others)} by others</summary><ul>{"".join(others)}</ul></details>' if others else ""))

    # Held: backlog rows held for a reason, captain calls first, deferred ones folded.
    held_html = ""
    if held is None:
        held_html = '<p class="k">Backlog unreadable this render.</p>'
    else:
        today = dt.date.today().isoformat()
        now_rows, later_rows = [], []
        for h in held:
            until = h.get("hold_until", "")
            until = "" if until == "-" else until
            r = by_task.get(h.get("id", ""))
            projects = [h.get("repo")] if h.get("repo") not in ("", "-", None) else []
            li = (f'<li class="f" {attrs(r["host"] if r else here, "Main", projects)}>'
                  f'<code>{e(h.get("id", ""))}</code> {e(h.get("title", ""))} <span class="k">{e(h.get("hold_kind", ""))}'
                  f'{" until " + e(until) if until else ""}</span>'
                  f'<div class="k">{e(plain_words(h.get("hold_reason", ""), 220))}</div></li>')
            (later_rows if until and until > today else now_rows).append((h.get("hold_kind") != "captain", li))
        now_rows.sort(key=lambda x: x[0])
        held_html = (f'<ul>{"".join(li for _, li in now_rows) or "<li class=k>none</li>"}</ul>'
                     + (f'<details><summary>{len(later_rows)} deferred to a later date</summary>'
                        f'<ul>{"".join(li for _, li in later_rows)}</ul></details>' if later_rows else ""))

    notes_html = ""
    if notes["missing"]:
        notes_html = f'<p class="k">No notes yet ({e(os.path.basename(paths["notes"]))}).</p>'
    elif notes["free"] or notes["events"]:
        notes_html = f'<section class="notes" aria-label="Context from Main">{notes_timeline(notes, dt.date.today())}</section>'

    stamp = dt.datetime.fromtimestamp(now).strftime("%a %H:%M:%S %Z").strip()
    page = f'''<!doctype html><meta charset="utf-8"><title>Current</title><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{{font:16px/1.45 system-ui;background:#0d1117;color:#e6edf3;max-width:1100px;margin:1.5em auto;padding:0 1em}}a{{color:#58a6ff}}h1{{margin:.2em 0}}h2{{margin-top:1.6em;border-bottom:1px solid #30363d;padding-bottom:.2em}}h3{{margin:.6em 0 .2em}}.k{{color:#8b949e;font-size:13px}}code{{font-size:13px;color:#c9d1d9}}
.next{{border:3px solid #f85149;border-radius:12px;padding:1em 1.3em;background:#2d1517;font-size:18px}}.next h2{{margin:.1em 0;border:0;color:#ff7b72}}.next p{{margin:.3em 0}}.notes{{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:.4em 1.1em;margin:.8em 0}}
.timeline{{list-style:none;margin:.5em 0;padding:0}}.timeline .note-event{{display:grid;grid-template-columns:5ch 5.5em minmax(0,1fr);align-items:baseline;gap:.8em;border-top:1px solid #30363d;padding:.65em 0;margin:0}}.note-event time{{font-weight:700;font-variant-numeric:tabular-nums;white-space:nowrap}}.note-kind{{font-size:12px;font-weight:700;text-align:center;border:1px solid;border-radius:5px;padding:2px 6px}}.note-kind.merged,.note-kind.fixed,.note-kind.live{{color:#7ee787;background:#12261e;border-color:#238636}}.note-kind.decided{{color:#79c0ff;background:#10233f;border-color:#1f6feb}}.note-kind.needs{{color:#e3b341;background:#2b2110;border-color:#9e6a03}}.note-kind.blocked{{color:#ff7b72;background:#2d1517;border-color:#da3633}}.note-kind.info{{color:#c9d1d9;background:#21262d;border-color:#57606a}}.note-text{{overflow-wrap:anywhere}}.notes details{{margin:.7em 0;color:#c9d1d9}}@media(max-width:480px){{.timeline .note-event{{gap:.5em;grid-template-columns:5ch 5em minmax(0,1fr);font-size:14px}}.notes{{padding:.4em .7em}}}}
.card{{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:.9em 1.1em;margin:.7em 0}}.need{{border-left:6px solid #d29922}}.top{{display:flex;justify-content:space-between;gap:1em;font-size:17px}}
.need-action{{display:flex;align-items:baseline;gap:.8em;background:#2b2110;border:1px solid #9e6a03;border-radius:8px;padding:.7em .9em;margin:.7em 0;color:#e6edf3}}.need-action>div{{min-width:0;overflow-wrap:anywhere}}.need-action>b{{color:#e3b341}}.need-command code{{font-family:ui-monospace,monospace;white-space:pre-wrap;color:#f0f6fc}}.copy-command{{font:12px system-ui;color:#c9d1d9;background:#21262d;border:1px solid #57606a;border-radius:5px;padding:.2em .6em;margin-left:.5em;cursor:pointer}}.copy-command:focus-visible{{outline:2px solid #58a6ff;outline-offset:2px}}.need-options{{display:flex;flex-wrap:wrap;gap:.5em;margin:.6em 0}}.need-option{{background:#21262d;border:1px solid #57606a;border-radius:20px;padding:.3em .8em;font-size:14px;overflow-wrap:anywhere;min-width:0}}.need-option.recommended{{background:#12261e;border-color:#238636;color:#7ee787}}.need-option b{{font-size:11px;margin-left:.4em}}
.need-message{{background:#10233f;border:1px solid #1f6feb;border-radius:8px;padding:.7em .9em;margin:.7em 0}}.need-message-head{{display:flex;justify-content:space-between;align-items:center;gap:.8em}}.need-message-head>b{{color:#79c0ff}}.need-message blockquote{{margin:.6em 0 0;padding:.5em .9em;border-left:4px solid #388bfd;background:#0d1117;border-radius:4px;white-space:pre-wrap;overflow-wrap:anywhere;color:#f0f6fc}}.need-message blockquote code{{font-family:ui-monospace,monospace;background:#21262d;border-radius:4px;padding:0 .3em}}.copy-message{{font:600 15px system-ui;color:#fff;background:#1f6feb;border:1px solid #388bfd;border-radius:6px;padding:.45em 1.1em;cursor:pointer;white-space:nowrap}}.copy-message:hover{{background:#388bfd}}.copy-message:focus-visible{{outline:2px solid #f0f6fc;outline-offset:2px}}
.b{{color:#fff;padding:2px 8px;border-radius:5px;font-size:12px;height:fit-content;white-space:nowrap;margin-right:.4em}}.why{{color:#c9d1d9;margin:.3em 0}}.st{{color:#adbac7;font-size:14px;margin:.3em 0;word-break:break-word}}summary{{cursor:pointer}}
ul.dl{{list-style:none;padding-left:0}}ul.dl li{{margin:.5em 0}}ul.dl .st{{display:inline}}
#filters{{position:sticky;top:0;background:#0d1117;padding:.4em 0;border-bottom:1px solid #30363d;z-index:1}}.chips{{margin:.15em 0}}.lbl{{display:inline-block;width:5.5em;color:#8b949e;font-size:13px}}
.chip{{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:20px;padding:.25em .8em;margin:.15em .2em .15em 0;font-size:14px;cursor:pointer}}.chip.on{{background:#1f6feb;border-color:#1f6feb}}li{{margin:.3em 0}}</style>
<h1>Current</h1>
<p class="k">Live. Rendered {e(stamp)} after {e(reason)}. <span id="nlive">{len(active)}</span> live · <span id="nneed">{len(need_cards)}</span> need you · {len(fleet)} fleet PRs landed in 24 h. Reloads every minute.</p>
<div class="next"><h2>NEXT for Andrew</h2>{next_html}</div>
{notes_html}
<div id="filters">{chips("m", "Machine", machines)}{chips("g", "Mate", mate_names)}{chips("p", "Project", project_names)}</div>
<h2>Needs you (<span class="cnt">{len(need_cards)}</span>)</h2><div class="sec">{"".join(need_cards) or '<p class="k">Nothing open.</p>'}</div>
<h2>Live workstreams (<span class="cnt">{len(active)}</span>)</h2><div class="sec">{"".join(card(r) for r in active)}</div>
<details><summary class="k">{len(parked)} paused, finished, or quiet for {quiet_after // 3600} h, still recorded</summary><div class="sec">{"".join(card(r) for r in parked)}</div></details>
<h2>Landed today (<span class="cnt">{len(fleet)}</span>)</h2><div class="sec">{landed_html}</div>
<h2>Held (<span class="cnt">{len(held or [])}</span>)</h2><div class="sec">{held_html}</div>
<script>
const sel={{m:"all",g:"all",p:"all"}};
function apply(){{
  document.querySelectorAll(".chip").forEach(c=>c.classList.toggle("on",sel[c.dataset.dim]==c.dataset.v));
  document.querySelectorAll(".f").forEach(el=>{{
    let ok=true;
    for(const d of ["m","g","p"]){{if(sel[d]=="all")continue;const v=(el.dataset[d]||"").split(" ");if(!v.includes(sel[d]))ok=false;}}
    el.style.display=ok?"":"none";
  }});
  document.querySelectorAll(".sec").forEach(s=>{{const h=s.previousElementSibling;const c=h&&h.querySelector(".cnt");
    if(c)c.textContent=[...s.querySelectorAll(":scope > .f, :scope > ul > .f")].filter(x=>x.style.display!="none").length;}});
  history.replaceState(null,"","#"+new URLSearchParams(sel).toString());
}}
function fromHash(){{new URLSearchParams(location.hash.slice(1)).forEach((v,k)=>{{if(k in sel)sel[k]=v;}});}}
fromHash();
window.addEventListener("hashchange",()=>{{fromHash();apply();}});
document.querySelectorAll(".chip").forEach(c=>c.onclick=()=>{{sel[c.dataset.dim]=c.dataset.v;apply();}});
async function copyText(text){{
  try{{await navigator.clipboard.writeText(text);return;}}catch{{}}
  const area=document.createElement("textarea");
  area.value=text;area.setAttribute("readonly","");area.style.cssText="position:fixed;opacity:0";
  document.body.appendChild(area);area.select();
  const ok=document.execCommand("copy");area.remove();
  if(!ok)throw new Error("copy refused");
}}
document.querySelectorAll(".copy-command").forEach(button=>button.onclick=async()=>{{
  try{{
    await copyText(button.previousElementSibling.textContent);
    button.textContent="Copied";
    button.setAttribute("aria-label","Command copied");
  }}catch{{
    button.textContent="Copy failed";
    button.setAttribute("aria-label","Copy failed, select the command to copy it manually");
  }}
}});
document.querySelectorAll(".copy-message").forEach(button=>button.onclick=async()=>{{
  try{{
    await copyText(button.dataset.copy);
    button.textContent="Copied";
    button.setAttribute("aria-label","Message copied");
  }}catch{{
    button.textContent="Copy failed";
    button.setAttribute("aria-label","Copy failed, select the message to copy it manually");
  }}
}});
apply();
setTimeout(()=>location.reload(),60000);
</script>
'''
    write_atomic(paths["out"], page)
    return {"live": len(active), "needs": len(need_cards), "decisions": len(decisions), "landed": len(fleet),
            "held": len(held or []), "forge": forge_state}


# ---------- plumbing ----------

def write_atomic(path, content):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, f".{os.path.basename(path)}.tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def configured_paths():
    """config/current-page: first plain line is the page; optional notes=<path> and curated=<path> lines."""
    found = {}
    try:
        with open(os.path.join(HOME, "config", "current-page"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, val = line.split("=", 1) if re.match(r"^(notes|curated)=", line) else ("out", line)
                if key not in found:
                    found[key] = val if os.path.isabs(val) else os.path.join(HOME, val)
    except OSError:
        pass
    return found


def locked_render(paths, reason):
    os.makedirs(PRIVATE, exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return render(paths, reason)


def watched_signature(paths):
    sig = []
    for d, suffixes in ((STATE, (".status", ".meta")), (DATA, ("backlog.md",))):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.endswith(suffixes):
                try:
                    st = os.stat(os.path.join(d, n))
                except OSError:
                    continue
                sig.append((n, st.st_size, st.st_mtime_ns, st.st_ino))
    for key in ("notes", "curated"):
        try:
            st = os.stat(paths[key])
            sig.append((key, st.st_size, st.st_mtime_ns, st.st_ino))
        except OSError:
            pass
    return sig


def watch(paths):
    """Render on every status, meta, backlog, notes, or curated change; at most one render per debounce window."""
    debounce = env_int("FM_CURRENT_PAGE_DEBOUNCE_SECS", 10)
    idle = env_int("FM_CURRENT_PAGE_IDLE_SECS", 300)
    poll = env_int("FM_CURRENT_PAGE_POLL_SECS", 2)
    inputs = "|".join(re.escape(os.path.basename(paths[k])) for k in ("notes", "curated"))
    names = re.compile(r"(\.status|\.meta|^backlog\.md|^(?:" + inputs + r"))$")
    notify = None
    if shutil.which("inotifywait") and not os.environ.get("FM_CURRENT_PAGE_POLL"):
        dirs = list(dict.fromkeys([STATE, DATA] + [os.path.dirname(paths[k]) for k in ("notes", "curated")]))
        notify = subprocess.Popen(["inotifywait", "-m", "-q", "-e", "close_write,modify,moved_to,create,delete",
                                   "--format", "%f", *dirs], stdout=subprocess.PIPE, text=True, bufsize=1)
        os.set_blocking(notify.stdout.fileno(), False)
    last_render = 0.0
    pending = "watch start"
    sig = watched_signature(paths) if not notify else None
    print(f"fm-current-page: watching {'with inotify' if notify else f'by polling every {poll}s'}; output {paths['out']}", flush=True)
    while True:
        if notify:
            if notify.poll() is not None:
                sys.exit("fm-current-page: inotifywait exited")
            select.select([notify.stdout], [], [], poll)
            while True:
                line = notify.stdout.readline()
                if not line:
                    break
                name = line.strip()
                if names.search(name):
                    pending = pending or f"change to {name}"
        else:
            time.sleep(poll)
            cur = watched_signature(paths)
            if cur != sig:
                changed = sorted({x[0] for x in set(cur) ^ set(sig)})
                pending = pending or f"change to {changed[0] if changed else 'state'}"
                sig = cur
        now = time.time()
        if not pending and now - last_render >= idle:
            pending = "idle refresh"
        if pending and now - last_render >= debounce:
            reason, pending = pending, None
            last_render = now
            try:
                summary = locked_render(paths, reason)
                print(f"{time.strftime('%H:%M:%S')} rendered ({reason}): {json.dumps(summary)}", flush=True)
            except Exception as exc:  # keep watching; the next change retries
                print(f"{time.strftime('%H:%M:%S')} render failed ({reason}): {exc}", file=sys.stderr, flush=True)


def main(argv):
    args = list(argv)
    mode = "render"
    if args and args[0] in ("render", "watch"):
        mode = args.pop(0)
    flags = {}
    while args:
        a = args.pop(0)
        if a in ("--out", "--notes", "--curated") and args:
            flags[a[2:]] = os.path.abspath(args.pop(0))
        else:
            sys.exit(f"fm-current-page: unknown argument {a!r} (see --help)")
    paths = {**configured_paths(), **flags}
    if not paths.get("out"):
        print("fm-current-page: no output configured; write the page path to config/current-page or pass --out",
              file=sys.stderr)
        return 2
    page_dir = os.path.dirname(paths["out"])
    paths.setdefault("notes", os.path.join(page_dir, "current-notes.md"))
    paths.setdefault("curated", os.path.join(page_dir, "current-curated.json"))
    if not os.path.isdir(STATE):
        print(f"fm-current-page: no state directory under {HOME}", file=sys.stderr)
        return 2
    if mode == "watch":
        watch(paths)
        return 0
    summary = locked_render(paths, os.environ.get("FM_CURRENT_PAGE_REASON", "manual render"))
    print(f"wrote {paths['out']}: {json.dumps(summary)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
