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
PARKED_VERBS = {"paused", "done", "failed"}
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
    """Merged PRs in the last 7 d, cached under state/.current-page for FM_CURRENT_PAGE_FORGE_TTL."""
    ttl = env_int("FM_CURRENT_PAGE_FORGE_TTL", 300)
    cache = {}
    try:
        with open(FORGE_CACHE, encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        cache = {}
    if os.environ.get("FM_CURRENT_PAGE_NO_FORGE") or not repos or not shutil.which("gh"):
        return cache.get("items", []), cache.get("fetched"), cache.get("viewer", ""), "skipped"
    if (cache.get("fetched") and time.time() - cache["fetched"] < ttl
            and cache.get("repos") == sorted(repos) and cache.get("window_days") == 7):
        return cache["items"], cache["fetched"], cache.get("viewer", ""), "cached"
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7 * 86400))
    query = "is:pr is:merged merged:>=" + since + "".join(" repo:" + r for r in sorted(repos))
    items, err = [], None
    try:
        viewer = cache.get("viewer") or subprocess.run(
            ["gh", "api", "user", "--jq", ".login"], capture_output=True, text=True, timeout=20).stdout.strip()
        for page in range(1, 11):
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
    cache = {"fetched": int(time.time()), "repos": sorted(repos), "viewer": viewer, "items": items, "window_days": 7}
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
    empty = {"checked": None, "needs": [], "why": {}, "mates": {}, "plain": {}, "hide": set(),
             "initiatives": [], "completed": [], "error": ""}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {**empty, "error": f"{os.path.basename(path)} not found"}
    except (OSError, ValueError) as exc:
        return {**empty, "error": f"{os.path.basename(path)} unreadable ({str(exc)[:120]})"}
    if not isinstance(data, dict):
        return {**empty, "error": f"{os.path.basename(path)} is not a JSON object"}
    why = data.get("why")
    plain = data.get("plain")
    hide = data.get("hide")
    return {"checked": ts_of(data.get("checked")),
            "needs": [n for n in data.get("needs") or [] if isinstance(n, dict) and str(n.get("t", "")).strip()],
            "why": {str(k): str(v) for k, v in why.items()} if isinstance(why, dict) else {},
            "plain": {str(k): {"text": str(v.get("text", "")), "at": ts_of(v.get("at"))}
                      for k, v in plain.items() if isinstance(v, dict) and str(v.get("text", "")).strip()}
            if isinstance(plain, dict) else {},
            "hide": {str(h) for h in hide} if isinstance(hide, list) else set(),
            "mates": data.get("mates") if isinstance(data.get("mates"), dict) else {},
            "initiatives": [n for n in data.get("initiatives") or [] if isinstance(n, dict) and n.get("id")],
            "completed": [n for n in data.get("completed") or [] if isinstance(n, dict)],
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


def link_label(url):
    """A short label for a full URL: PR #n, a Linear key, Slack, a design slug, or host plus last path part."""
    if PR_RE.fullmatch(url):
        return f'PR #{url.rsplit("/", 1)[1]}'
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


def note_links(text):
    """Keep inline Markdown while giving every full URL a short label."""
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
            label = link_label(url)
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
    """Optional recipient-ready message: a Copy button holding the exact raw text, and the text folded below."""
    message = need.get("message")
    if not isinstance(message, str) or not message.strip():
        return "", ""
    to = need.get("to")
    if isinstance(to, list):
        to = ", ".join(str(x) for x in to if str(x).strip())
    head = f'Message{" to " + e(to) if isinstance(to, str) and to.strip() else ""}'
    parts, end = [], 0
    for match in re.finditer(r"`([^`\n]+)`", message):
        parts.append(e(message[end:match.start()]))
        parts.append(f"<code>{e(match.group(1))}</code>")
        end = match.end()
    parts.append(e(message[end:]))
    # The parser folds a raw CR into LF, so a character reference keeps the copied text byte-exact.
    raw = e(message).replace("\r", "&#13;")
    button = f'<button type="button" class="copy-message" data-copy="{raw}">Copy message</button>'
    return button, f'<details class="need-message"><summary>{head}</summary><blockquote>{"".join(parts)}</blockquote></details>'


def need_actions(need):
    """The direct link, exact commands with Copy, message, and option chips of one curated need."""
    acts = []
    link = str(need.get("link") or "").strip()
    if re.match(r"https?://", link):
        acts.append(f'<a class="go" href="{e(link)}">Open {e(str(need.get("link_label") or link_label(link)))}</a>')
    action = str(need.get("do") or "").strip()
    if action:
        parts, end = [], 0
        for match in re.finditer(r"`([^`]+)`", action):
            parts.append(note_links(action[end:match.start()]))
            parts.append(f'<span class="cmd"><code>{e(match.group(1))}</code>'
                         '<button type="button" class="copy-command">Copy</button></span>')
            end = match.end()
        parts.append(note_links(action[end:]))
        acts.append(f'<span class="do">{"".join(parts)}</span>')
    button, folded = need_message(need)
    if button:
        acts.append(button)
    options = need.get("options")
    if isinstance(options, list):
        for option in options:
            if isinstance(option, str) and option.strip():
                rec = option == need.get("rec")
                acts.append(f'<span class="opt{" rec" if rec else ""}">{e(option)}{" (recommended)" if rec else ""}</span>')
    return (f'<div class="acts">{"".join(acts)}</div>' if acts else "") + folded


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
        verb, note, at = parse_line(last_line(status))
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
            info = mates.get(task, {})
            host = meta.get("remote_host") or info.get("host") or here
            projects = list(dict.fromkeys(info.get("projects") or meta.get("projects", "").split(",")))
            title = why.get(task) or info.get("scope") or task
        else:
            host = meta.get("remote_host") or here
            title = why.get(task) or plain_words(titles.get(task, ""), 120) or task
        pr = meta.get("pr", "")
        found = PR_RE.findall(note)
        if found:
            pr = found[-1]
        rows.append({"task": task, "kind": kind, "host": host, "projects": [p for p in dict.fromkeys(projects) if p],
                     "verb": verb, "note": note, "updated": updated, "pr": pr, "title": title,
                     "backend": meta.get("backend", ""), "target": meta.get("window", ""),
                     "remote": bool(meta.get("remote_host")),
                     "linear_project": meta.get("linear_project_id") or meta.get("linear_project", "")})
    return rows


def live_tasks(rows):
    """Ids whose recorded local endpoint is present, by the backend's cheap presence read; None when unreadable."""
    args = []
    for r in rows:
        if r["backend"] and r["target"] and not r["remote"]:
            args += [r["task"], r["backend"], r["target"]]
    if not args:
        return set()
    script = ('source "$1/fm-backend.sh" || exit 3; shift; while [ "$#" -ge 3 ]; do '
              'fm_backend_target_exists "$2" "$3" "fm-$1" >/dev/null 2>&1 && printf "%s\\n" "$1"; shift 3; done; exit 0')
    try:
        res = subprocess.run(["bash", "-c", script, "fm-current-page", SCRIPT_DIR, *args], capture_output=True,
                             text=True, timeout=120, env={**os.environ, "FM_HOME": HOME})
    except (OSError, subprocess.TimeoutExpired):
        return None
    return set(res.stdout.split()) if res.returncode == 0 else None


def ts_of(value):
    """Epoch seconds from an epoch number or an ISO date or timestamp (naive means local); None otherwise."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value or "").strip()
    if re.fullmatch(r"\d{9,11}", text):
        return float(text)
    try:
        stamp = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (ValueError, TypeError, OverflowError):
        return None
    return stamp.timestamp()


def ago(ts, now):
    if ts is None:
        return "at an unknown time"
    s = max(0, int(now - ts))
    if s < 60:
        return "just now"
    if s < 3600:
        return f"{s // 60}m ago"
    if s < 172800:
        return f"{s // 3600}h ago"
    return f"{s // 86400}d ago"


def age(ts, now, prefix=""):
    """An age the page script keeps current between renders."""
    if ts is None:
        return f'<span class="age">{e(prefix)}at an unknown time</span>'
    stamp = dt.datetime.fromtimestamp(ts)
    return (f'<time class="age" data-ts="{int(ts)}" data-prefix="{e(prefix)}" datetime="{stamp.isoformat(timespec="seconds")}"'
            f' title="{stamp.strftime("%a %d %b %H:%M")}">{e(prefix)}{ago(ts, now)}</time>')


def clip(text, n):
    return text if len(text) <= n else text[:n].rstrip() + "…"


def plain_words(text, n=200):
    """Raw status text made captain-readable: no home paths, links, or [name=value] tags."""
    text = re.sub(r"\S*data/\S+", "", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\[[a-z_]+=[^\]]*\]\s*", "", text)
    return clip(re.sub(r"\s+", " ", text).strip(), n)


def linked_words(text, n=220):
    """Plain words that keep full URLs as short links; a URL cut by the clip is dropped."""
    text = re.sub(r"\S*data/\S+", "", text)
    text = re.sub(r"\[[a-z_]+=[^\]]*\]\s*", "", text)
    text = clip(re.sub(r"\s+", " ", text).strip(), n)
    return note_links(re.sub(r"https?://\S*…$", "…", text))


def archived_done():
    """Read summary rows only; tasks-axi's markdown archive is outside its list API."""
    import tomllib
    archive = os.path.join(DATA, "done-archive.md")
    try:
        with open(os.path.join(HOME, ".tasks.toml"), "rb") as fh:
            config = tomllib.load(fh)
        if config.get("backend", "markdown") != "markdown":
            return []
        archive = os.path.join(HOME, config.get("markdown", {}).get("archive", "data/done-archive.md"))
    except FileNotFoundError:
        pass
    except (OSError, ValueError):
        return []
    rows = []
    try:
        with open(archive, encoding="utf-8") as fh:
            for line in fh:
                match = re.match(r"^- \[x\] (\S+) - (.*)", line)
                if not match:
                    continue
                task, summary = match.groups()
                closed = re.search(r"\((?:done|merged|reported) (\d{4}-\d{2}-\d{2})\)", summary)
                repo = re.search(r"\(repo: ([^)]+)\)", summary)
                if closed:
                    rows.append({"id": task, "title": summary.split(" (repo:")[0],
                                 "repo": repo.group(1) if repo else "", "closed": closed.group(1)})
    except OSError:
        pass
    return rows


def initiative_for(item, initiatives):
    """Prefer title evidence, then Linear project, then project token; ties use curated order."""
    title = str(item.get("match_title") or item.get("title") or "").casefold()
    projects = item.get("projects") or []
    linear = str(item.get("linear_project") or "").casefold()
    winner, best = "other", (0, 0)
    for initiative in initiatives:
        rule = initiative.get("match") or {}
        words = rule.get("title_keywords") or []
        size = max((len(word) for word in words if isinstance(word, str) and word.casefold() in title), default=0)
        score = ((3, size) if size else
                 (2, 0) if linear and linear in [str(p).casefold() for p in rule.get("linear_projects") or []] else
                 (1, 0) if set(projects) & set(rule.get("project_tokens") or []) else (0, 0))
        if score > best:
            winner, best = str(initiative["id"]), score
    return winner


def completions(cur, merged, done, rows, repos, viewer, now):
    """One item per finished piece of work in the last 7 d, each tagged with its initiative.

    A Done record that links a merged PR absorbs that PR, so one task never shows twice. Merged PRs
    by another author than the fleet's forge identity are returned separately.
    """
    initiatives = cur["initiatives"]
    by_task = {r["task"]: r for r in rows}
    pr_rows = {r["pr"]: r for r in rows if r["pr"]}
    today = dt.date.fromtimestamp(now).isoformat()
    week_start = dt.date.fromtimestamp(now - 7 * 86400).isoformat()
    prs = {}
    for pr in merged:
        url, ts = pr.get("url", ""), ts_of(pr.get("merged"))
        if PR_RE.fullmatch(url) and ts is not None and now - 7 * 86400 <= ts <= now:
            prs[url] = {**pr, "ts": ts}
    items, used, seen = [], set(), set()
    for ticket in [*(done or []), *cur["completed"], *archived_done()]:
        task = str(ticket.get("id", ""))
        closed = str(ticket.get("completed") or ticket.get("closed") or "")
        title = str(ticket.get("title") or task)
        links = PR_RE.findall(" ".join(str(ticket.get(k, "")) for k in ("links", "title", "url")))
        linked = next((u for u in links if u in prs and u not in used), "")
        date_only = bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", closed)) and not linked
        ts = prs[linked]["ts"] if linked else ts_of(closed)
        in_week = week_start <= closed <= today if date_only else ts is not None and now - 7 * 86400 <= ts <= now
        if not task or task in seen or not in_week:
            continue
        seen.add(task)
        if linked:
            used.add(linked)
        row = by_task.get(task, {})
        url = linked or str(ticket.get("url") or "") or (links[0] if links else "")
        item = {"title": cur["why"].get(task) or plain_words(re.sub(r"^Done:\s*", "", title), 120) or task,
                "match_title": title + " " + task, "url": url if url.startswith("https://") else "",
                "projects": row.get("projects") or [ticket.get("project_token") or ticket.get("repo") or ""],
                "linear_project": ticket.get("linear_project") or row.get("linear_project", ""),
                "ts": ts, "date_only": date_only, "closed": closed[:10],
                "today": closed == today if date_only else ts >= now - 86400}
        item["initiative"] = initiative_for(item, initiatives)
        items.append(item)
    others = []
    for url, pr in prs.items():
        if url in used:
            continue
        parts = url.split("/")
        row = pr_rows.get(url, {})
        item = {"title": re.sub(r"^(?:fix|feat|chore|docs|perf|test|refactor|ci)(?:\([^)]*\))?!?:\s*", "",
                                str(pr.get("title", ""))) or url,
                "match_title": str(pr.get("title", "")) + " " + str(row.get("title", "")), "url": url,
                "projects": row.get("projects") or [repos.get("/".join(parts[3:5]), parts[4])],
                "linear_project": row.get("linear_project", ""), "ts": pr["ts"], "date_only": False,
                "today": pr["ts"] >= now - 86400, "author": pr.get("author", "")}
        item["initiative"] = initiative_for(item, initiatives)
        (items if not viewer or item["author"] == viewer else others).append(item)
    return items, others


def done_li(item, now, by=False):
    link = f' <a href="{e(item["url"])}">{e(link_label(item["url"]))}</a>' if item["url"] else ""
    who = f' <span class="meta">by {e(item.get("author", ""))}</span>' if by else ""
    when = (f'<span class="age">{"today" if item["today"] else e(item["closed"])}</span>' if item["date_only"]
            else age(item["ts"], now))
    return f'<li>{e(clip(item["title"], 140))}{link}{who} <span class="meta">{when}</span></li>'


def grouped(items, initiatives, now, cap, key):
    """Items under their initiative's title, curated order then Other; each group shows `cap` items and folds the rest."""
    names = {str(i["id"]): str(i.get("title") or i["id"]) for i in initiatives}
    order = [*names, "other"]
    names["other"] = "Other"
    groups = {}
    for item in sorted(items, key=lambda x: x["ts"] or 0, reverse=True):
        groups.setdefault(item["initiative"], []).append(item)
    out = []
    for gid in order:
        rows = groups.get(gid)
        if not rows:
            continue
        lis = [done_li(x, now) for x in rows]
        body = "<ul>" + "".join(lis[:cap]) + "</ul>"
        if len(lis) > cap:
            body += (f'<details id="{e(key)}-{e(gid)}"><summary>{len(lis) - cap} more</summary>'
                     "<ul>" + "".join(lis[cap:]) + "</ul></details>")
        out.append(f'<div class="group" data-initiative="{e(gid)}"><h3>{e(names[gid])} <span class="n">{len(rows)}</span></h3>{body}</div>')
    return "".join(out)


def captain_calls(held, today):
    """Captain-held backlog rows keyed by id, with the hold-set time as the ask time and future-dated holds marked deferred."""
    calls = {}
    for h in held or []:
        if h.get("hold_kind") != "captain" or not h.get("id"):
            continue
        until = "" if h.get("hold_until") in (None, "", "-") else h["hold_until"]
        stamp = re.search(r"Captain hold set:\s*(\S+)", h.get("body", ""))
        asked = (ts_of(stamp.group(1)) if stamp else None) or ts_of(h.get("created"))
        calls[h["id"]] = {**h, "until": until, "asked": asked, "deferred": bool(until and until > today)}
    return calls


PAGE_CSS = """
body{font:16px/1.45 system-ui;background:#0d1117;color:#e6edf3;max-width:980px;margin:1.2em auto;padding:0 1em}
a{color:#58a6ff}h1{margin:.1em 0;font-size:26px}h2{margin:1.4em 0 .4em;font-size:21px;border-bottom:1px solid #30363d;padding-bottom:.2em}
h2 .n,h3 .n,summary .n{color:#8b949e;font-weight:400}h3{margin:.8em 0 .2em;font-size:16px;color:#79c0ff}
.k,.meta{color:#8b949e;font-size:13px}.age{white-space:nowrap}code{font-size:13px;color:#c9d1d9}
.warn{background:#2d1517;border:1px solid #da3633;color:#ffa198;border-radius:8px;padding:.4em .8em;margin:.4em 0}
ol.needs,ul.runs{list-style:none;padding:0;margin:0}
.need{background:#161b22;border:1px solid #30363d;border-left:5px solid #d29922;border-radius:10px;padding:.6em .9em;margin:.5em 0}
.need.new{border-left-color:#388bfd}.need.stale{border-left-color:#57606a;opacity:.75}
.head{display:flex;justify-content:space-between;gap:1em;align-items:baseline}.head b{font-size:17px}.head .meta{text-align:right}
.why{color:#c9d1d9;font-size:14px;margin:.15em 0;overflow-wrap:anywhere}
.acts{display:flex;flex-wrap:wrap;gap:.5em;align-items:center;margin:.4em 0 .1em}
a.go{background:#1f6feb;color:#fff;text-decoration:none;font-weight:600;border-radius:6px;padding:.25em .8em}
.do{font-size:14px;overflow-wrap:anywhere}.cmd code{font-family:ui-monospace,monospace;background:#0d1117;border:1px solid #30363d;border-radius:5px;padding:.1em .4em;color:#f0f6fc}
button{font:12px system-ui;color:#c9d1d9;background:#21262d;border:1px solid #57606a;border-radius:5px;padding:.25em .7em;margin-left:.3em;cursor:pointer}
.opt{background:#21262d;border:1px solid #30363d;border-radius:20px;padding:.1em .7em;font-size:13px}.opt.rec{border-color:#2ea043;color:#7ee787}
.need-message summary{font-size:13px;color:#8b949e}.need-message blockquote{margin:.4em 0;padding:.5em .8em;border-left:3px solid #388bfd;background:#0d1117;white-space:pre-wrap;overflow-wrap:anywhere}
.run{border-top:1px solid #21262d;padding:.45em 0}.run .st{color:#adbac7;font-size:14px;overflow-wrap:anywhere}
.tag{font-size:12px;border:1px solid #9e6a03;color:#e3b341;border-radius:5px;padding:0 .4em;margin-left:.3em}
.group ul{margin:.1em 0;padding-left:1.2em}.group li{margin:.15em 0;font-size:15px}
details.more{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:.4em .9em;margin:.5em 0}details.more>summary{font-weight:600}
summary{cursor:pointer}li{margin:.25em 0}.timeline{list-style:none;padding:0}.timeline li{display:flex;gap:.6em}
.note-kind{font-size:12px;color:#8b949e;min-width:5em}
"""

PAGE_JS = """
function ago(s){s=Math.max(0,Math.floor(s));if(s<60)return"just now";if(s<3600)return Math.floor(s/60)+"m ago";
  if(s<172800)return Math.floor(s/3600)+"h ago";return Math.floor(s/86400)+"d ago";}
function tick(){const now=Date.now()/1000;
  document.querySelectorAll("time.age[data-ts]").forEach(t=>{t.textContent=(t.dataset.prefix||"")+ago(now-Number(t.dataset.ts));});
  const stale=document.getElementById("render-stale");if(stale)stale.hidden=now-RENDERED<600;}
async function copyText(text){
  try{await navigator.clipboard.writeText(text);return;}catch{}
  const area=document.createElement("textarea");area.value=text;area.setAttribute("readonly","");area.style.cssText="position:fixed;opacity:0";
  document.body.appendChild(area);area.select();const ok=document.execCommand("copy");area.remove();if(!ok)throw new Error("copy refused");}
function copier(button,text){button.onclick=async()=>{try{await copyText(text());button.textContent="Copied";}catch{button.textContent="Copy failed, select it by hand";}};}
document.querySelectorAll(".copy-command").forEach(b=>copier(b,()=>b.previousElementSibling.textContent));
document.querySelectorAll(".copy-message").forEach(b=>copier(b,()=>b.dataset.copy));
const OPEN="current-page-open";const opened=new Set(JSON.parse(sessionStorage.getItem(OPEN)||"[]"));
document.querySelectorAll("details[id]").forEach(d=>{if(opened.has(d.id))d.open=true;
  d.addEventListener("toggle",()=>{d.open?opened.add(d.id):opened.delete(d.id);sessionStorage.setItem(OPEN,JSON.stringify([...opened]));});});
tick();setInterval(tick,30000);setTimeout(()=>location.reload(),60000);
"""


def render(paths, reason):
    now = time.time()
    today = dt.date.fromtimestamp(now).isoformat()
    confirm = env_int("FM_CURRENT_PAGE_CONFIRM_HOURS", 2) * 3600
    notes = parse_notes(paths["notes"])
    cur = parse_curated(paths["curated"])
    mates = parse_secondmates()
    for mid, info in cur["mates"].items():
        if mid in mates and isinstance(info, dict):
            mates[mid]["host"] = info.get("machine") or mates[mid]["host"]
            mates[mid]["scope"] = info.get("scope") or mates[mid]["scope"]
    backlog = tasks_axi("list", "--limit", "2000")
    titles = {r["id"]: r.get("title", "") for r in (backlog or []) if r.get("id")}
    held = tasks_axi("list", "--state", "held", "--limit", "2000", "--fields", "hold_kind,hold_until,hold_reason,created,body")
    done = tasks_axi("list", "--state", "done", "--limit", "2000", "--fields", "closed,links")
    rows = build_rows(mates, titles, cur["why"])
    by_task = {r["task"]: r for r in rows}
    open_by_task = {}
    for d in open_decisions():
        open_by_task.setdefault(d["task"], []).append(d)
    live = live_tasks(rows)
    repos = registry_repos()
    merged, fetched, viewer, forge_state = merged_prs(repos)
    here = local_host()
    calls = captain_calls(held, today)

    # Needs you now: curated needs the keeper re-checked inside the confirm window, minus any whose
    # backlog row is no longer an open captain call, plus captain calls Main opened inside that window.
    def need_li(n, cls, asked, checked):
        who = str(n.get("who") or "")
        host = n.get("machine") or (by_task[who]["host"] if who in by_task else mates.get(who, {}).get("host") or here)
        rechecked = f' · {age(checked, now, "checked ")}' if cls == "stale" else ""
        return (f'<li class="need {cls}" data-task="{e(str(n.get("task") or ""))}"><div class="head"><b>{e(str(n["t"]))}</b>'
                f'<span class="meta">{age(asked, now, "asked ")} · {e(host)}{rechecked}</span></div>'
                f'<div class="why">{note_links(str(n.get("why", "")))}</div>{need_actions(n)}</li>')
    needs_now, needs_stale, curated_tasks = [], [], set()
    for n in cur["needs"]:
        task = str(n.get("task") or "")
        if task:
            curated_tasks.add(task)
            if held is not None and (task not in calls or calls[task]["deferred"]):
                continue
        asked = ts_of(n.get("asked")) or calls.get(task, {}).get("asked")
        checked = ts_of(n.get("checked")) or cur["checked"]
        if checked is not None and now - checked < confirm:
            needs_now.append(need_li(n, "", asked, checked))
        else:
            needs_stale.append(need_li(n, "stale", asked, checked))
    fresh_calls, older_calls, deferred_calls = [], [], []
    for c in sorted(calls.values(), key=lambda c: c["asked"] or 0, reverse=True):
        if c["id"] in curated_tasks and not c["deferred"]:
            continue
        if c["deferred"]:
            deferred_calls.append(c)
        elif c["asked"] is not None and now - c["asked"] < confirm:
            fresh_calls.append(c)
        else:
            older_calls.append(c)
    for c in fresh_calls:
        needs_now.append(
            f'<li class="need new" data-task="{e(c["id"])}"><div class="head"><b>{e(plain_words(c.get("title", ""), 120) or c["id"])}</b>'
            f'<span class="meta">{age(c["asked"], now, "asked ")} · new, not summarized yet</span></div>'
            f'<div class="why">{linked_words(c.get("hold_reason", ""), 260)}</div></li>')

    def call_li(c):
        until = f' · until {e(c["until"])}' if c["until"] else ""
        return (f'<li data-task="{e(c["id"])}"><b>{e(plain_words(c.get("title", ""), 120) or c["id"])}</b> <span class="meta">'
                f'{age(c["asked"], now, "asked ")}{until} · <code>{e(c["id"])}</code></span>'
                f'<div class="why">{linked_words(c.get("hold_reason", ""))}</div></li>')

    # Running: workers whose endpoint is present right now; second mates always, by their routed status.
    def run_li(r):
        plain = cur["plain"].get(r["task"])
        if plain and plain["at"] is not None and now - plain["at"] < confirm and plain["at"] >= (r["updated"] or 0) - 60:
            text, as_of = plain["text"], plain["at"]
        else:
            text, as_of = plain_words(r["note"], 180) or "No report yet.", r["updated"]
        pr = f' <a href="{e(r["pr"])}">{e(link_label(r["pr"]))}</a>' if r["pr"] else ""
        tags = ""
        if r["task"] in open_by_task:
            tags += '<span class="tag">waiting on a decision from Main</span>'
        if r["verb"] == "paused":
            tags += '<span class="tag">paused</span>'
        return (f'<li class="run" data-task="{e(r["task"])}"><div class="head"><b>{e(r["title"])}{pr}</b>'
                f'<span class="meta">{e(r["host"])}</span></div>'
                f'<div class="st">{e(text)} <span class="meta">{age(as_of, now)}</span>{tags}</div></li>')
    shown = [r for r in rows if r["task"] not in cur["hide"]]
    shown.sort(key=lambda r: -(r["updated"] or 0))
    second = [r for r in shown if r["kind"] == "secondmate"]
    alive = [r for r in shown if r["kind"] != "secondmate" and live is not None and r["task"] in live]
    running = [r for r in alive if r["verb"] not in PARKED_VERBS]
    parked = [r for r in alive if r["verb"] in PARKED_VERBS]

    # Done today and earlier this week, by initiative.
    items, others = completions(cur, merged, done, rows, repos, viewer, now)
    done_today = [x for x in items if x["today"]]
    week = [x for x in items if not x["today"]]
    others_today = sorted((x for x in others if x["today"]), key=lambda x: -x["ts"])

    banners = []
    if cur["error"]:
        banners.append(f"The keeper's file has a problem ({e(cur['error'])}); Needs you shows only new backlog calls.")
    if cur["checked"] is None or now - cur["checked"] >= confirm:
        banners.append(f"The page keeper last checked {age(cur['checked'], now)}; anything not re-checked is folded.")
    if held is None:
        banners.append("The backlog could not be read, so answered calls may still show.")
    if live is None:
        banners.append("Could not check which workers are running.")
    if forge_state.startswith("stale"):
        banners.append(f"GitHub read failed; merged work is as of {age(fetched, now)}.")
    warn = "".join(f'<p class="warn">{b}</p>' for b in banners)

    def more(key, title, count, body):
        return (f'<details class="more" id="{key}"><summary>{e(title)} <span class="n">{count}</span></summary>{body}</details>'
                if count else "")
    notes_html = notes_timeline(notes, dt.date.fromtimestamp(now)) if not notes["missing"] else ""
    rest = "".join([
        more("more-older-calls", "Older open calls in the backlog", len(older_calls),
             '<p class="k">Captain-held backlog rows the keeper has not re-checked. Answer one by telling Main.</p>'
             "<ul>" + "".join(call_li(c) for c in older_calls) + "</ul>"),
        more("more-deferred-calls", "Calls deferred to a later date", len(deferred_calls),
             "<ul>" + "".join(call_li(c) for c in deferred_calls) + "</ul>"),
        more("more-parked", "Workers alive but parked", len(parked),
             '<ul class="runs">' + "".join(run_li(r) for r in parked) + "</ul>"),
        more("more-week", "Earlier this week, by initiative", len(week), grouped(week, cur["initiatives"], now, 3, "week")),
        more("more-others", "Merged by others today", len(others_today),
             "<ul>" + "".join(done_li(x, now, by=True) for x in others_today) + "</ul>"),
        more("more-notes", "Keeper notes", len(notes["events"]) + (1 if notes["free"] else 0), notes_html),
    ])
    stale_html = (f'<details class="more" id="needs-stale"><summary>Not re-checked in {confirm // 3600} h, may be answered '
                  f'<span class="n">{len(needs_stale)}</span></summary><ol class="needs">{"".join(needs_stale)}</ol></details>'
                  if needs_stale else "")
    second_html = f'<h3>Second mates</h3><ul class="runs" id="second-mates">{"".join(run_li(r) for r in second)}</ul>' if second else ""
    page = (
        '<!doctype html><meta charset="utf-8"><title>Current</title>'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<style>{PAGE_CSS}</style>"
        f'<h1>Current</h1><p class="k" title="{e(reason)}">Updated {age(now, now)} · {len(needs_now)} need you · '
        f'{len(running)} running · {len(done_today)} done today. Reloads every minute.</p>'
        '<p class="warn" id="render-stale" hidden>This page stopped updating; everything below may be old.</p>'
        f"{warn}"
        f'<section id="needs"><h2>Needs you now <span class="n">{len(needs_now)}</span></h2>'
        f'<ol class="needs" id="needs-now">{"".join(needs_now) or "<li class=k>Nothing waiting on you.</li>"}</ol>{stale_html}</section>'
        f'<section id="running"><h2>Running <span class="n">{len(running)}</span></h2>'
        f'<ul class="runs" id="running-now">{"".join(run_li(r) for r in running) or "<li class=k>No workers running.</li>"}</ul>'
        f'{second_html}</section>'
        f'<section id="done"><h2>Done today <span class="n">{len(done_today)}</span></h2>'
        '<p class="k">Merged fleet PRs and finished tasks from the last 24 h.</p>'
        f'{grouped(done_today, cur["initiatives"], now, 5, "today") or "<p class=k>Nothing finished yet today.</p>"}</section>'
        f'<section id="more"><h2>Everything else</h2>{rest or "<p class=k>Nothing else.</p>"}</section>'
        f"<script>const RENDERED={int(now)};{PAGE_JS}</script>")
    write_atomic(paths["out"], page)
    return {"needs": len(needs_now), "stale_needs": len(needs_stale), "running": len(running),
            "done_today": len(done_today), "older_calls": len(older_calls), "forge": forge_state}


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
    for d, suffixes in ((STATE, (".status", ".meta")), (DATA, ("backlog.md", "done-archive.md"))):
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
