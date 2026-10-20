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
Events sort newest first, grouped by date: the inspector's foot shows the
newest six, and the L key opens the whole log with other days folded.
Inline Markdown renders through bin/fm_md.py, so full URLs show short labels
(PR #<number>, a Linear key, a design slug).
Other lines render as Markdown without timeline styling.
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
sys.path.insert(0, SCRIPT_DIR)
import fm_md  # noqa: E402  (the one Markdown renderer and page theme, beside this file)
import fm_current_answers as answers  # noqa: E402  (answer key, revision, token, decisions file)
import zlib  # noqa: E402
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
DOC_SKIP = {"brief.md", "launch-brief.md"}
DOC_LIMIT = 6
DOC_KEY_RE = re.compile(r"\b(?:report|plan|review)=(\S+?\.md)\b")
SECRET_RE = re.compile(r"gh[opsu]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|xox[abp]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9_-]{20,}")
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
             "initiatives": [], "completed": [], "links": [], "wins": [], "factory": [], "error": ""}
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
            "links": [(str(n.get("label") or fm_md.link_label(str(n["url"]))), str(n["url"]))
                      for n in data.get("links") or [] if isinstance(n, dict) and re.match(r"https://", str(n.get("url", "")))],
            "wins": [n for n in data.get("wins") or [] if isinstance(n, dict) and str(n.get("t", "")).strip()
                     and re.match(r"https?://", str(n.get("url", "")))][:10],
            "factory": [n for n in data.get("factory") or [] if isinstance(n, dict) and str(n.get("t", "")).strip()][:8],
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


def timeline_rows(rows):
    return '<ol class="timeline">' + "".join(
        f'<li class="note-event"><time datetime="{row["day"]}T{row["time"]}">{row["time"]}</time>'
        f'<span class="note-kind {row["kind"]}">{row["kind"]}</span>'
        f'<div class="note-text">{fm_md.inline(row["text"])}</div></li>' for row in rows) + "</ol>"


def notes_timeline(notes, today):
    """The keeper log overlay: today's events, then other days folded, then any free Markdown."""
    groups = {}
    for row in notes["events"]:
        groups.setdefault(row["day"], []).append(row)
    out = []
    if groups:
        day = today.isoformat()
        rows = groups.pop(day, [])
        out.append(f'<h3>Today · <time datetime="{day}">{today.strftime("%a, %d %b %Y")}</time></h3>')
        out.append(timeline_rows(rows) if rows else '<p class="k">No events today.</p>')
        if groups:
            count = sum(len(rows) for rows in groups.values())
            out.append(f'<details class="notes-history"><summary>Other days · {count} event{"s" if count != 1 else ""}</summary>')
            for day, rows in groups.items():
                label = dt.date.fromisoformat(day).strftime("%a, %d %b %Y")
                out.append(f'<h3><time datetime="{day}">{label}</time></h3>{timeline_rows(rows)}')
            out.append("</details>")
    if notes["free"]:
        out.append(fm_md.block(notes["free"]))
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


def need_actions(need, answerable=False):
    """The direct link, exact commands with Copy, message, and option chips of one curated need."""
    acts = []
    link = str(need.get("link") or "").strip()
    if re.match(r"https?://", link):
        acts.append(f'<a class="go" href="{e(link)}">Open {e(str(need.get("link_label") or fm_md.link_label(link)))}</a>')
    action = str(need.get("do") or "").strip()
    if action:
        parts, end = [], 0
        for match in re.finditer(r"`([^`]+)`", action):
            parts.append(fm_md.inline(action[end:match.start()]))
            parts.append(f'<span class="cmd"><code>{e(match.group(1))}</code>'
                         '<button type="button" class="copy-command">Copy</button></span>')
            end = match.end()
        parts.append(fm_md.inline(action[end:]))
        acts.append(f'<span class="do">{"".join(parts)}</span>')
    button, folded = need_message(need)
    if button:
        acts.append(button)
    options = need.get("options")
    if isinstance(options, list) and not answerable:
        for option in options:
            if isinstance(option, str) and option.strip():
                rec = option == need.get("rec")
                acts.append(f'<span class="opt{" rec" if rec else ""}">{e(option)}{" (recommended)" if rec else ""}</span>')
    return (f'<div class="acts">{"".join(acts)}</div>' if acts else "") + folded


LETTER_RE = re.compile(r"(?<![\w/])([A-F])(\s*\((?:recommended|rec)\))?\s*[:)]")
REC_RE = re.compile(r"(?<![\w/])([A-Fa-f])\b[^.;:]{0,4}\(?recommended\)?", re.I)


def decision_options(text):
    """Answer buttons from a decision's own words: lettered choices (A: ... B: ..., A/B/C, a, b, or c),
    yes/no, merge/close, or approve/reject; ([], None) when it names none, so the page offers a text box only."""
    letters = [m.group(1) for m in LETTER_RE.finditer(text)]
    slash = re.search(r"(?<![\w/])([A-Fa-f](?:\s*/\s*[A-Fa-f])+)(?![\w/])", text)
    listed = re.search(r"(?<!\w)([a-f]), ([a-f]),? or ([a-f])(?!\w)", text, re.I)
    run = []
    for letter in dict.fromkeys(letters):
        if ord(letter) - ord("A") == len(run):
            run.append(letter)
    if len(run) < 2 and slash:
        run = [x.strip().upper() for x in slash.group(1).split("/")]
    if len(run) < 2 and listed:
        run = [x.upper() for x in listed.groups()]
    if len(run) >= 2:
        rec = REC_RE.search(text)
        return run, rec.group(1).upper() if rec and rec.group(1).upper() in run else None
    for pair in (("yes", "no"), ("merge", "close"), ("approve", "reject")):
        if re.search(rf"\b{pair[0]}\s*(?:/|or)\s*{pair[1]}\b", text, re.I):
            return [p.capitalize() for p in pair], None
    return [], None


def answer_block(key, rev, options, rec, title="", compact=False):
    """Option buttons plus a one-line text box (buttons only when compact); the page script posts the tap and paints its receipt here."""
    buttons = "".join(
        f'<button type="button" class="ans-btn{" rec" if o == rec else ""}" data-opt="{e(o)}">{e(o)}'
        f'{"<small>recommended</small>" if o == rec and not compact else ""}</button>' for o in options)
    text = ("" if compact else
            f'<div class="ans-text"><input type="text" maxlength="{answers.MAX_TEXT}" enterkeyhint="send" autocomplete="off" '
            f'placeholder="{"Or type an answer" if options else "Type your answer"}" aria-label="Answer for Main">'
            '<button type="button" class="ans-send">Send</button></div>')
    return (f'<div class="answer{" compact" if compact else ""}" data-ans="{e(key)}" data-rev="{e(rev)}"'
            + (f' data-title="{e(title)}"' if title else "") + ">"
            + (f'<div class="ans-opts">{buttons}</div>' if buttons else "") + text
            + '<div class="receipt" aria-live="polite" hidden></div></div>')


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
    return fm_md.inline(re.sub(r"https?://\S*…$", "…", text))


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
                "match_title": title + " " + task, "url": url if url.startswith("https://") else "", "task": task,
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


def task_docs(task, page_dir, cache):
    """The task's worker documents rendered beside the page as <task>-<name>.html: (name, href) pairs.

    Sources: every data/<task>/*.md except the briefs, plus any .md under data/ that the task's status log
    names in a report=, plan= or review= key. Only the DOC_LIMIT most recently changed are rendered and
    linked. A page is re-rendered only when its source is newer, and a source that looks like it holds a
    secret is neither rendered nor linked.
    """
    if not task or not re.fullmatch(r"[\w.-]+", task):
        return []
    if task in cache:
        return cache[task]
    srcs = {}
    own = os.path.join(DATA, task)
    try:
        for name in sorted(os.listdir(own)):
            if name.endswith(".md") and name not in DOC_SKIP:
                srcs[os.path.join(own, name)] = name[:-3]
    except OSError:
        pass
    try:
        with open(os.path.join(STATE, task + ".status"), encoding="utf-8", errors="replace") as fh:
            named = DOC_KEY_RE.findall(fh.read())
    except OSError:
        named = []
    data_root = os.path.realpath(DATA) + os.sep
    for ref in named:
        path = os.path.realpath(ref if os.path.isabs(ref) else os.path.join(HOME, ref))
        if path.startswith(data_root) and os.path.basename(path) not in DOC_SKIP and path not in srcs:
            parent = os.path.basename(os.path.dirname(path))
            srcs[path] = os.path.basename(path)[:-3] if parent == task else f"{parent}-{os.path.basename(path)[:-3]}"
    out = []
    newest = sorted(srcs, key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)
    for src in newest[:DOC_LIMIT]:
        name = srcs[src]
        page = f"{task}-{name}.html"
        target = os.path.join(page_dir, page)
        try:
            stale = not os.path.exists(target) or os.path.getmtime(src) > os.path.getmtime(target)
            if stale:
                with open(src, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
                if SECRET_RE.search(text):
                    if os.path.exists(target):
                        os.remove(target)
                    continue
                fm_md.write_atomic(target, fm_md.page(text))
        except OSError:
            continue
        out.append((name, page))
    cache[task] = out
    return out


def docs_line(pairs):
    """The inspector line linking a task's rendered documents, or '' when it has none."""
    if not pairs:
        return ""
    return ('<p class="docs"><span class="lbl">Docs</span> '
            + " ".join(f'<a href="{e(href)}" target="_blank" rel="noopener">{e(name)} &#8599;</a>' for name, href in pairs) + "</p>")


def item_div(key, row, det, href="", task="", cls=""):
    """One selectable pane item: a one-line row, plus the inspector body the page script shows while it is selected."""
    attrs = f' data-key="{e(key)}"' + (f' data-task="{e(task)}"' if task else "") + (f' data-href="{e(href)}"' if href else "")
    return f'<div class="it{" " + cls if cls else ""}"{attrs}><div class="row">{row}</div><div class="det">{det}</div></div>'


def chips(*parts):
    return '<div class="chips">' + "".join(f'<span class="chip">{p}</span>' for p in parts if p) + "</div>"


def done_div(item, now, initiative):
    url = item["url"]
    when = (f'<span class="age">{"today" if item["today"] else e(item["closed"])}</span>' if item["date_only"]
            else age(item["ts"], now))
    label = fm_md.link_label(url) if url else ""
    row = f'<span class="mk"></span><span class="t">{e(clip(item["title"], 140))}</span><span class="m">{e(label)}</span>'
    det = (f'<h2>{e(item["title"])}</h2>{chips("done " + when, e(initiative))}'
           + (f'<div class="acts"><a class="go" href="{e(url)}">Open {e(label)}</a></div>' if url else
              "" if item.get("docs") else '<p class="k">No link recorded for this one.</p>')
           + item.get("docs", ""))
    return item_div("done:" + (url or item["title"]), row, det, href=url)


def grouped(items, initiatives, now):
    """Done items under their initiative's title, curated order then Other, newest first inside each."""
    names = {str(i["id"]): str(i.get("title") or i["id"]) for i in initiatives}
    order = [*names, "other"]
    names["other"] = "Other"
    groups = {}
    for item in sorted(items, key=lambda x: x["ts"] or 0, reverse=True):
        groups.setdefault(item["initiative"], []).append(item)
    return "".join(f'<div class="group" data-initiative="{e(gid)}"><h3>{e(names[gid])} <span class="n">{len(groups[gid])}</span></h3>'
                   + "".join(done_div(x, now, names[gid]) for x in groups[gid]) + "</div>"
                   for gid in order if groups.get(gid))


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
body{height:100vh;overflow:hidden;display:flex;flex-direction:column}
#hud{display:flex;align-items:center;gap:16px;padding:0 14px;height:42px;flex:none;background:rgba(13,17,23,.96);
border-bottom:2px solid var(--acc);font:12px var(--mono);letter-spacing:.08em;white-space:nowrap}
#hud .brand{font-weight:700;letter-spacing:.16em;color:var(--acc);text-shadow:0 0 12px rgba(255,136,0,.5)}
#hud .live{color:var(--fg2)}#hud .live.off .dot{background:var(--alert);animation:none}
#hud .stat{color:var(--fg2)}#hud .stat b{color:var(--fg);font-size:15px;margin-left:4px}
#hud .stat.hot b{color:var(--alert);text-shadow:0 0 10px rgba(255,51,102,.6)}#hud .stat.good b{color:var(--data)}
#hud .lv{display:flex;align-items:center;gap:6px;color:var(--fg2)}#hud .lv b{color:var(--acc)}
#hud .bar{display:inline-block;width:70px;height:6px;border:1px solid var(--acc-dim);position:relative}
#hud .bar i{position:absolute;inset:0 auto 0 0;background:var(--acc);box-shadow:0 0 8px var(--acc);transition:width .6s ease-out}
#hud .sp{flex:1}#hud a{color:var(--link)}#hud .out a+a{margin-left:12px}#clock{color:var(--data)}
#warn{flex:none}#warn p{margin:0;padding:4px 14px;background:var(--alert-dim);color:#ffb3c4;font-size:12.5px;border-bottom:1px solid var(--alert)}
#cols{flex:1;min-height:0;display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1.2fr);gap:10px;padding:10px}
.stack{display:flex;flex-direction:column;gap:10px;min-height:0}
.pane,#insp{display:flex;flex-direction:column;min-height:0;background:var(--pane);border:1px solid var(--acc-dim);border-radius:var(--r);
box-shadow:0 8px 32px rgba(0,0,0,.5),inset 0 1px 0 rgba(255,255,255,.03)}
.pane{flex:1 1 0;transition:flex-grow .22s ease-out,border-color .2s,box-shadow .2s;animation:boot .35s ease-out backwards}
.stack .pane.on{flex-grow:2.4}.pane.on{border-color:var(--acc);box-shadow:var(--glow),0 12px 48px rgba(0,0,0,.6)}
#p-running{animation-delay:.05s}#p-done{animation-delay:.1s}#p-held{animation-delay:.15s}#insp{animation:boot .35s .2s ease-out backwards}
.pane>header,#insp>header{display:flex;align-items:center;gap:8px;padding:6px 10px;flex:none;background:var(--raised);
border-bottom:1px solid rgba(255,255,255,.04);font:12px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--fg2)}
.pane.on>header b{color:var(--acc)}.pane>header .n{margin-left:auto;color:var(--data);font-size:13px}
.list{overflow:auto;flex:1;min-height:0;padding:2px 0 8px;scrollbar-width:thin;scrollbar-color:var(--acc-dim) transparent}
.it{cursor:pointer}.it .det{display:none}
.it .row{display:flex;gap:8px;align-items:center;padding:3px 10px;border-left:2px solid transparent;white-space:nowrap;font-size:13.5px;line-height:1.45}
.it .t{overflow:hidden;text-overflow:ellipsis;flex:1;min-width:0}.it .m{font:11px var(--mono);color:var(--fg2);flex:none}
.it .mk{width:6px;height:6px;flex:none;background:var(--data);opacity:.8}
.it.heat2 .mk{background:var(--acc)}.it.heat3 .mk{background:var(--alert);box-shadow:0 0 6px var(--alert)}
#needs-now .it.heat3 .mk{animation:blink 1.4s steps(2,start) infinite}.it.held .mk{background:var(--dim)}
.it.dim .t,.it.dim .mk{opacity:.55}.it.new .mk{background:var(--link)}
.it:hover .row{background:rgba(255,255,255,.03)}
.it.sel .row{background:rgba(255,255,255,.05);border-left-color:var(--dim)}
.pane.on .it.sel .row{background:linear-gradient(90deg,rgba(255,136,0,.2),rgba(255,136,0,.04));border-left-color:var(--acc)}
.pane.on .it.sel .t{color:#fff}.it.flash .row{animation:flash 1.6s ease-out}
.list h3{margin:0;padding:9px 10px 2px;font:600 10.5px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--data)}
.list h3 .n{color:var(--dim)}.list .k{padding:6px 12px}.k{color:var(--fg2);font-size:13px}
.zero{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:6px;font:700 22px var(--mono);
letter-spacing:.2em;color:var(--data);text-shadow:0 0 18px rgba(0,221,170,.6);animation:pulse-t 3s ease-in-out infinite}
.zero small{font:12px var(--mono);letter-spacing:.12em;color:var(--fg2);text-shadow:none}
@keyframes pulse-t{50%{opacity:.65}}
#insp{position:relative}#insp .body{overflow:auto;flex:1;padding:16px 20px;animation:boot .18s ease-out}
#insp h2{font:600 19px/1.3 var(--sans);margin:0 0 8px;color:#fff}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 12px}
.chip{font:11px var(--mono);letter-spacing:.06em;border:1px solid var(--acc-dim);padding:1px 7px;color:var(--fg2);border-radius:var(--r)}
.chip.alert{border-color:var(--alert);color:var(--alert)}.chip code{border:0;background:none;padding:0}
.why{font-size:14.5px;line-height:1.6;margin:0 0 12px;overflow-wrap:anywhere}
.acts{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:12px 0}
.docs{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:baseline;margin:12px 0 4px;font:13px var(--mono)}.docs .lbl{margin-right:2px}
a.go{background:var(--acc);color:#0a0a0f;font:700 12px var(--mono);letter-spacing:.1em;text-transform:uppercase;padding:6px 12px;border-radius:var(--r);box-shadow:var(--glow)}
a.go::before{content:"\\23CE  "}a.go:hover{text-decoration:none;filter:brightness(1.15)}
.do{font-size:14px;overflow-wrap:anywhere;flex-basis:100%}
.cmd{display:inline-flex;align-items:center;gap:4px;margin:2px 0}.cmd code{font-size:13px;padding:2px 6px;color:#fff}
button{font:11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--acc);background:transparent;border:1px solid var(--acc-dim);border-radius:var(--r);padding:2px 8px;cursor:pointer}
button:hover{border-color:var(--acc)}
.opt{font:12px var(--mono);border:1px solid var(--dim);padding:2px 8px;border-radius:var(--r);color:var(--fg2)}
.opt.rec{border-color:var(--data);color:var(--data);box-shadow:0 0 10px rgba(0,221,170,.25)}
.need-message summary{font:11px var(--mono);letter-spacing:.08em;color:var(--fg2);cursor:pointer;text-transform:uppercase}
.need-message blockquote{margin:.4em 0;padding:.6em .9em;border-left:3px solid var(--data);background:rgba(0,221,170,.05);white-space:pre-wrap;overflow-wrap:anywhere}
.tag{font:11px var(--mono);border:1px solid var(--acc);color:var(--acc);padding:0 6px;margin-right:6px;border-radius:var(--r)}
.st{font-size:14.5px;line-height:1.6;overflow-wrap:anywhere}
#logtail{flex:none;border-top:1px solid var(--acc-dim);padding:6px 12px 8px;font:12px/1.55 var(--mono);color:var(--fg2);max-height:30%;overflow:hidden}
#logtail .lbl{display:block;margin-bottom:2px}
.timeline{list-style:none;padding:0;margin:0}.timeline li{display:flex;gap:8px;white-space:nowrap;overflow:hidden}
.timeline .note-text{overflow:hidden;text-overflow:ellipsis}.overlay .timeline li{white-space:normal}
.note-kind{min-width:5.5em;text-transform:uppercase;font-size:10.5px;letter-spacing:.08em;padding-top:1px}
.note-kind.merged,.note-kind.fixed,.note-kind.live{color:var(--data)}.note-kind.needs{color:var(--acc)}
.note-kind.blocked{color:var(--alert)}.note-kind.decided{color:var(--link)}
#keys{flex:none;display:flex;gap:14px;align-items:center;padding:4px 14px;border-top:1px solid var(--acc-dim);background:rgba(13,17,23,.96);
font:11px var(--mono);color:var(--fg2);white-space:nowrap;overflow:hidden}
#keys input{font:12px var(--mono);background:transparent;border:0;border-bottom:1px solid var(--acc-dim);color:var(--fg);width:180px;outline:0;padding:1px 2px}
#keys input:focus{border-bottom-color:var(--acc)}#keys .sp{flex:1}
#toasts{position:fixed;right:18px;bottom:44px;display:flex;flex-direction:column;align-items:flex-end;gap:8px;z-index:9500;pointer-events:none}
.toast{background:var(--surface);border:1px solid var(--data);color:var(--data);box-shadow:0 0 22px rgba(0,221,170,.35);padding:8px 14px;
font:700 13px var(--mono);letter-spacing:.14em;animation:toast 3.2s ease-out forwards}
.toast.acc{border-color:var(--acc);color:var(--acc);box-shadow:var(--glow)}.toast.big{font-size:22px;padding:14px 24px}
@keyframes toast{0%{transform:translateX(130%)}8%{transform:none}85%{opacity:1}100%{opacity:0;transform:translateY(-12px)}}
@media (max-width:1100px){body{height:auto;overflow:auto}#cols{grid-template-columns:1fr}.pane,#insp{min-height:40vh}#hud{flex-wrap:wrap;height:auto}}
#wins,#mine{flex:none;display:flex;align-items:center;gap:10px;padding:8px 10px 0}#wins>.lbl{color:var(--data);flex:none}
#mine>.lbl{color:var(--link);flex:none}#mine>.lbl .n{color:var(--fg2);margin-left:6px}
.wins-row,.mine-list{display:flex;gap:8px;overflow-x:auto;flex:1;min-width:0;padding-bottom:3px;scrollbar-width:thin;scrollbar-color:var(--acc-dim) transparent}
.win,.mine{flex:0 0 250px;display:flex;flex-direction:column;gap:1px;min-width:0;padding:5px 10px;background:var(--pane);
border:1px solid var(--data-dim);border-left:3px solid var(--data);border-radius:var(--r);color:var(--fg)}
.win:hover{text-decoration:none;border-color:var(--data);box-shadow:0 0 14px rgba(0,221,170,.25)}
.win b,.mine>b{font:600 13px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.win .why{font-size:12px;color:var(--fg2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.win .m{font:10.5px var(--mono);color:var(--data);letter-spacing:.06em}
.mine{flex:0 0 300px;gap:0;padding:4px 10px;border-color:rgba(124,196,255,.25);border-left-color:var(--link)}
.mine .mh{display:flex;gap:6px;align-items:baseline;min-width:0}
.mine .mh b{flex:1;min-width:0;font:600 13px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mine .mh .m{flex:none;font:10.5px var(--mono);color:var(--fg2)}.mine .rc{margin:0}
.answer{margin:14px 0 6px;padding:10px 12px;border:1px solid var(--acc-dim);background:rgba(255,136,0,.04);border-radius:var(--r)}
.answer.busy{opacity:.6;pointer-events:none}
.ans-opts{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px}
.ans-btn{font:600 13px var(--mono);color:var(--fg);border-color:var(--acc-hi);padding:6px 12px;text-transform:none;letter-spacing:.02em;text-align:center}
.ans-btn small{display:block;font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;opacity:.8}
.ans-btn.rec{border-color:var(--data);color:var(--data)}
.ans-btn.chosen{background:var(--acc);border-color:var(--acc);color:#0a0a0f}
.ans-btn.armed{background:var(--data);border-color:var(--data);color:#0a0a0f;box-shadow:0 0 16px rgba(0,221,170,.5)}
.ans-btn.armed::after{content:"tap again to send";display:block;font-size:9.5px;letter-spacing:.1em;text-transform:uppercase}
.ans-text{display:flex;gap:8px}
.ans-text input{flex:1;min-width:0;font:14px var(--sans);background:var(--surface);color:var(--fg);border:1px solid var(--acc-dim);
border-radius:var(--r);padding:5px 8px;outline:0}.ans-text input:focus{border-color:var(--acc)}
.receipt{margin-top:10px}.receipt.err .rc{color:var(--alert)}
.rc{display:block;font:12px/1.5 var(--mono);color:var(--fg2);min-width:0}.rc b{color:var(--fg)}
.rc>summary,.rc.line{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;list-style:none;cursor:pointer}
.rc>summary::-webkit-details-marker{display:none}.rc.line{cursor:default}
.gl{font:700 11px var(--mono);color:var(--data);margin-right:4px}.gl.wait{color:var(--fg2)}.gl.err{color:var(--alert)}
.rc-reply{margin:4px 0 2px;padding:6px 8px;border-left:3px solid var(--link);background:rgba(124,196,255,.07);color:var(--fg);
font:13px/1.5 var(--sans);white-space:pre-wrap;overflow-wrap:anywhere}
#factory{flex:none;margin:8px 10px 0;padding:5px 10px;border:1px solid var(--alert);border-left:4px solid var(--alert);
background:linear-gradient(90deg,var(--alert-dim),rgba(255,51,102,.04));border-radius:var(--r)}
#factory>.lbl{display:block;color:var(--alert);margin-bottom:1px}#factory>.lbl b{color:var(--fg);margin-left:8px}
.fx{display:flex;align-items:center;gap:12px;min-height:30px;padding:1px 0;border-top:1px solid rgba(255,51,102,.16)}.fx:first-child{border-top:0}
.fx-q{flex:1;min-width:0;font:600 13.5px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fx-u{flex:none;font:11.5px var(--mono);color:var(--data);white-space:nowrap}
.fx-a{flex:none;display:flex;gap:10px;align-items:center}.fx-a>a{font:12px var(--mono)}
.answer.compact{margin:0;padding:0;border:0;background:none;display:flex;align-items:center;gap:8px}
.answer.compact .ans-opts{margin:0;gap:6px;flex-wrap:nowrap}.answer.compact .ans-btn{padding:2px 10px;font-size:12px}
.answer.compact .ans-btn.armed::after{display:inline;content:" · tap again"}.answer.compact .receipt{margin:0;max-width:300px}
.mob{display:none}
@media (max-width:760px){
html{-webkit-text-size-adjust:100%}
body{height:auto;overflow-x:hidden;overflow-y:auto;font-size:16px;
padding:0 env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
#insp,#keys,#hud .lv,#hud .hint,#hud .sp,#clock,.pane>header kbd{display:none}
#hud{flex-wrap:wrap;height:auto;gap:2px 12px;padding:calc(env(safe-area-inset-top) + 6px) 12px 4px;
white-space:normal;font-size:12px}
#hud .stat b{font-size:16px}
#hud .out{flex-basis:100%;display:flex;flex-wrap:wrap;gap:0 18px}
#hud .out a{display:inline-flex;align-items:center;min-height:44px;margin:0!important;font-size:14px}
.mob{display:inline-flex;align-items:center;justify-content:center}#logbtn{margin-left:auto}
#warn p{font-size:14px;padding:8px 12px}
#wins,#mine{display:block;padding:12px 10px 0}#wins>.lbl,#mine>.lbl{display:block;margin:0 2px 6px;font-size:12px}
.wins-row{overflow-x:auto;scroll-snap-type:x mandatory;gap:10px;padding-bottom:6px}
.win{flex:0 0 84%;scroll-snap-align:start;padding:10px 12px;min-height:56px}
.mine-list{overflow-x:auto;scroll-snap-type:x mandatory;gap:10px;padding-bottom:6px}.mine{flex:0 0 84%;scroll-snap-align:start;padding:8px 12px}
.win b{font-size:16px;white-space:normal}.win .why{font-size:14px;white-space:normal}.win .m{font-size:12px}
.mine .mh b{font-size:15px}.rc{font-size:13px}.rc>summary{min-height:32px;padding-top:4px}
#cols{display:block;padding:12px 10px}.stack{display:block}
.pane{margin:0 0 12px;animation:none}.pane>header{font-size:13px;padding:10px 12px;min-height:44px;cursor:pointer}.list{overflow:visible}
.pane>header::after{content:"\\25BE";color:var(--fg2);margin-left:8px}.pane.fold>header::after{content:"\\25B8"}.pane.fold .list{display:none}
.list h3{font-size:12px;padding:12px 12px 4px}
.it .row{min-height:48px;padding:10px 12px;font-size:16px;white-space:normal;align-items:flex-start}
.it .t{white-space:normal;overflow:visible}.it .m{font-size:12px;padding-top:3px}.it .mk{margin-top:8px}
#needs-now .it .row{white-space:nowrap;align-items:center}#needs-now .it .t{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#needs-now .it .m,#needs-now .it .mk{padding-top:0;margin-top:0}
.it.open .det{display:block;padding:0 14px 14px 26px;overflow-wrap:anywhere}
.it .det h2{display:none}
.why,.st,.do{font-size:16px}.chip{font-size:12px}code{font-size:13px;word-break:break-all}
button,a.go{min-height:44px;padding:8px 14px;font-size:14px}a.go{display:inline-flex;align-items:center}
.need-message summary{min-height:44px;display:flex;align-items:center}
.ans-btn{min-height:52px;flex:1 1 40%;font-size:16px}.ans-text input{min-height:44px;font-size:16px}.ans-send{min-width:84px}
.receipt{font-size:14px}
#factory{margin:10px 10px 0}.fx{flex-wrap:wrap;gap:6px 10px;padding:8px 0}.fx-q{flex-basis:100%;white-space:normal;font-size:15px}
.answer.compact .ans-btn{min-height:40px;flex:0 0 auto;font-size:14px;padding:6px 12px}
.zero{height:auto;padding:28px 0}
.overlay .box{min-width:0;width:calc(100vw - 24px);max-height:85vh}.timeline li{white-space:normal}
#toasts{left:12px;right:12px;bottom:calc(env(safe-area-inset-bottom) + 12px);align-items:stretch}.toast{text-align:center}
}
"""

# Keys, selection, filter, copy, and live refresh. The page re-fetches itself (a cheap 304 while unchanged), swaps
# every [data-swap] element in place, and keeps the reader's pane, selection, filter, open items, and half-typed
# answers; a need that vanished was answered, so it scores a cleared call. Answers: a tap arms an option, a second
# tap posts it to the answer endpoint, and every 10 s the page reads /api/answers to move each receipt from Main's
# inbox to read to replied. Narrow screens (phone) stack the panes and open items in place instead of the inspector.
PAGE_JS = r"""
const $=(s,r=document)=>r.querySelector(s),$$=(s,r=document)=>[...r.querySelectorAll(s)];
const S={pane:0,sel:{},q:"",cleared:+(sessionStorage.getItem("fm-cleared")||0),open:new Set(),ans:{},sending:{},fed:false,
 fold:new Set(["p-done","p-held"]),rcOpen:new Set(),read:JSON.parse(localStorage.getItem("fm-read")||"{}")};
let panes=[],pend="";const body=$("#insp .body"),q=$("#q"),MOB=matchMedia("(max-width:760px)");
function ago(s){s=Math.max(0,Math.floor(s));if(s<60)return"just now";if(s<3600)return Math.floor(s/60)+"m ago";
 if(s<172800)return Math.floor(s/3600)+"h ago";return Math.floor(s/86400)+"d ago";}
function tick(){const now=Date.now()/1000;
 $$("time.age[data-ts]").forEach(t=>{t.textContent=(t.dataset.prefix||"")+ago(now-Number(t.dataset.ts));});
 const off=now-Number(document.body.dataset.rendered)>600;$("#live").classList.toggle("off",off);
 $("#live-l").textContent=off?"STALE":"LIVE";}
function clock(){$("#clock").textContent=new Date().toLocaleTimeString([], {hour12:false});}
function vis(p){return $$(".it",p).filter(x=>!x.hidden);}
function cur(i=S.pane){const its=vis(panes[i]||document.createElement("p"));return its.find(x=>x.dataset.key===S.sel[i])||its[0]||null;}
function show(scroll=true){panes.forEach((p,i)=>{p.classList.toggle("on",i===S.pane);const c=cur(i);
  $$(".it.sel",p).forEach(x=>x!==c&&x.classList.remove("sel"));if(c){c.classList.add("sel");S.sel[i]=c.dataset.key;}});
 const it=cur();if(it&&scroll&&!MOB.matches)it.scrollIntoView({block:"nearest"});
 body.innerHTML=it?it.querySelector(".det").innerHTML:'<p class="k">Nothing here'+(S.q?" for this filter":"")+".</p>";
 body.style.animation="none";void body.offsetWidth;body.style.animation="";$("#insp-n").textContent=panes[S.pane].dataset.title;tick();paint();}
function move(d){const its=vis(panes[S.pane]);if(!its.length)return;let i=its.indexOf(cur());
 i=Math.max(0,Math.min(its.length-1,i+d));S.sel[S.pane]=its[i].dataset.key;show();}
function to(i){S.pane=(i+panes.length)%panes.length;show();}
function openSel(){const it=cur();const h=it&&it.dataset.href;if(h)window.open(h,"_blank","noopener");else toast("NO LINK ON THIS ONE","acc");}
async function copyText(t){try{await navigator.clipboard.writeText(t);return;}catch{}
 const a=document.createElement("textarea");a.value=t;a.setAttribute("readonly","");a.style.cssText="position:fixed;opacity:0";
 document.body.appendChild(a);a.select();const ok=document.execCommand("copy");a.remove();if(!ok)throw new Error("copy refused");}
async function yank(msg){const m=body.querySelector(".copy-message"),c=body.querySelector(".cmd code");
 const t=msg||!c?(m&&m.dataset.copy):c.textContent;if(!t){toast("NOTHING TO COPY","acc");return;}
 try{await copyText(t);toast(msg||!c?"MESSAGE COPIED":"COMMAND COPIED");}catch{toast("COPY FAILED","acc");}}
function filter(v){S.q=v.trim().toLowerCase();
 $$(".it").forEach(x=>{x.hidden=!!S.q&&!(x.firstChild.textContent+" "+(x.dataset.task||"")).toLowerCase().includes(S.q);});
 $$(".list .group,.list .sub").forEach(g=>{g.hidden=!!S.q&&!$$(".it",g).some(x=>!x.hidden);});
 panes.forEach(p=>{const n=$(".n",p);n.textContent=S.q?vis(p).length+" found":n.dataset.n;});show();}
function toast(t,cls=""){const d=document.createElement("div");d.className="toast "+cls;d.textContent=t;$("#toasts").appendChild(d);
 setTimeout(()=>d.remove(),3300);}
function score(){const c=$("#cleared");c.textContent=S.cleared;sessionStorage.setItem("fm-cleared",S.cleared);}
function folds(){panes.forEach(p=>p.classList.toggle("fold",MOB.matches&&S.fold.has(p.id)));}
function bind(){panes=$$(".pane[data-pane]").sort((a,b)=>a.dataset.pane-b.dataset.pane);folds();
 panes.forEach(p=>{const n=$(".n",p);n.dataset.n=n.textContent;});}
function inputs(){return $$(".answer input").map(i=>[i.closest(".answer").dataset.ans,i]);}
function apply(text){const doc=new DOMParser().parseFromString(text,"text/html");
 const typed={},focus=(inputs().find(([,i])=>i===document.activeElement)||[])[0];inputs().forEach(([k,i])=>{if(i.value)typed[k]=i.value;});
 const keys=()=>new Set($$("#needs-now .it").map(x=>x.dataset.key)),before=keys(),done=$$("#done .it").length;
 $$("[data-swap]").forEach(el=>{const n=doc.getElementById(el.id);if(n)el.replaceWith(document.importNode(n,true));});
 document.body.dataset.rendered=doc.body.dataset.rendered;document.title=doc.title;bind();const after=keys();
 const gone=[...before].filter(k=>!after.has(k)).length,fresh=[...after].filter(k=>!before.has(k));
 fresh.forEach(k=>{const x=$$("#needs-now .it").find(y=>y.dataset.key===k);if(x)x.classList.add("flash");});
 if(gone){S.cleared+=gone;score();toast(gone>1?gone+" CALLS CLEARED":"CALL CLEARED");}
 if(fresh.length)toast(fresh.length>1?fresh.length+" NEW CALLS":"NEW CALL","acc");
 const shipped=$$("#done .it").length-done;if(shipped>0)toast("+"+shipped+" SHIPPED");
 if(before.size&&!after.size)toast("INBOX ZERO","big");filter(q.value);
 $$(".it").forEach(x=>x.classList.toggle("open",S.open.has(x.dataset.key)));
 inputs().forEach(([k,i])=>{if(typed[k])i.value=typed[k];});
 const back=inputs().find(([k,i])=>k===focus&&i.offsetParent);if(back)back[1].focus({preventScroll:true});paint();}
function esc(s){const d=document.createElement("div");d.textContent=s==null?"":String(s);return d.innerHTML;}
function rid(){return crypto.randomUUID?crypto.randomUUID():[...crypto.getRandomValues(new Uint8Array(16))].map(b=>b.toString(16).padStart(2,"0")).join("");}
const GL={sending:["&#8230;","sending","wait"],received:["&#10003;","in Main's inbox","wait"],seen:["&#10003;&#10003;","Main read it","wait"],
 answered:["&#10003;&#10003;","Main replied",""]};
function glyph(a){if(a.state==="error")return'<i class="gl err" title="not sent">&#10007;</i>';
 const g=GL[a.state]||["?",a.state,"wait"];return'<i class="gl '+g[2]+'" title="'+g[1]+'">'+g[0]+"</i>";}
function receipt(a,bare){const g=bare?"":glyph(a);
 if(a.state==="error")return'<div class="rc line">'+g+"not sent: "+esc(a.detail)+"</div>";
 const you="You: <b>"+esc(a.answer)+"</b>";
 if(!a.reply)return'<div class="rc line">'+g+you+" &#183; "+(GL[a.state]||[0,esc(a.state)])[1]+"</div>";
 return'<details class="rc" data-rc="'+esc(a.note||a.key)+'"'+(S.rcOpen.has(a.note||a.key)?" open":"")+"><summary>"+g+you
  +" &#183; Main: "+esc(a.reply.split("\n")[0])+'</summary><div class="rc-reply">'+esc(a.reply)+"</div></details>";}
function tsOf(a){return(Date.parse(a.reply_at||a.at||"")||0)/1000;}
function paint(){const shown=new Set(),now=Date.now()/1000;
 // A receipt belongs to the question it answered: an earlier answer on the same backlog row with another title goes to Your answers.
 $$(".answer[data-ans]").forEach(b=>{const k=b.dataset.ans,t=b.dataset.title,a0=S.sending[k]||S.ans[k];
  const a=a0&&(S.sending[k]||!t||!a0.title||a0.title===t)?a0:null,r=$(".receipt",b);if(a&&b.closest(".pane,#factory"))shown.add(k);
  b.classList.toggle("busy",!!a&&a.state==="sending");$$(".ans-btn",b).forEach(x=>x.classList.toggle("chosen",!!a&&x.dataset.opt===a.answer));
  r.hidden=!a;if(a){r.classList.toggle("err",a.state==="error");r.innerHTML=receipt(a);}});
 const m=$("#mine");if(!m)return;
 // An answer whose call left the page stays here while Main has not replied; a reply stays 24 h, or until it was on screen a minute.
 const seen=document.visibilityState==="visible";
 const off=Object.values(S.ans).filter(a=>{if(shown.has(a.key))return false;if(a.state!=="answered")return true;
  const id=a.note||a.key;if(now-tsOf(a)>86400)return false;if(seen&&!S.read[id])S.read[id]=now;return!(S.read[id]&&now-S.read[id]>60);})
  .sort((x,y)=>tsOf(y)-tsOf(x));
 for(const id in S.read)if(now-S.read[id]>259200)delete S.read[id];localStorage.setItem("fm-read",JSON.stringify(S.read));
 m.hidden=!off.length;$(".lbl .n",m).textContent=off.length;
 $(".mine-list",m).innerHTML=off.map(a=>'<div class="mine"><div class="mh">'+glyph(a)+'<b title="'+esc(a.title)+'">'+esc(a.title)+"</b>"
  +'<span class="m">'+ago(now-tsOf(a))+"</span></div>"+receipt(a,true)+"</div>").join("");}
async function send(box,pick){const key=box.dataset.ans,said=pick.option||pick.text,id=rid();let r=null,j={};
 const h=box.closest(".det,.body"),title=box.dataset.title||(h&&h.querySelector("h2")||{}).textContent||key;
 S.sending[key]={state:"sending",answer:said};paint();
 for(let i=0;i<3&&!r;i++){try{r=await fetch("/api/answer",{method:"POST",credentials:"same-origin",
  headers:{"Content-Type":"application/json","X-FM-Answer-Token":($("#hud").dataset.token||"")},
  body:JSON.stringify({key,rev:box.dataset.rev,rid:id,...pick})});}catch{await new Promise(z=>setTimeout(z,800));}}
 try{j=r?await r.json():{};}catch{}delete S.sending[key];
 if(r&&r.ok){S.ans[key]={...j,title};toast("MAIN GOT IT");if(navigator.vibrate)navigator.vibrate(30);paint();setTimeout(poll,1500);return true;}
 S.sending[key]={state:"error",answer:said,detail:j.detail||j.error||(r?"HTTP "+r.status:"offline; try again")};paint();
 if(r&&r.status===409){toast("DECISION CHANGED, REFRESHING","acc");refresh();}
 else if(r&&r.status===403&&j.error==="token"){toast("RELOADING","acc");setTimeout(()=>location.reload(),900);}
 else toast("NOT SENT","acc");
 setTimeout(()=>{if(S.sending[key]&&S.sending[key].state==="error"){delete S.sending[key];paint();}},15000);return false;}
async function sendText(box){const i=$("input",box),t=i.value.trim();if(!t){toast("TYPE AN ANSWER FIRST","acc");i.focus();return;}
 if(await send(box,{text:t}))inputs().forEach(([k,x])=>{if(k===box.dataset.ans)x.value="";});}
async function poll(){if(!$("#hud").dataset.token)return;try{const r=await fetch("/api/answers",{cache:"no-store"});if(!r.ok)return;
 const j=await r.json(),prev=S.ans;S.ans={};(j.answers||[]).forEach(a=>{S.ans[a.key]=a;const p=prev[a.key];if(!S.fed||!p)return;
  if(a.state==="answered"&&p.state!=="answered")toast("MAIN REPLIED");else if(a.state==="seen"&&p.state==="received")toast("MAIN READ IT");});
 S.fed=true;paint();}catch{}}
async function refresh(){try{const r=await fetch(location.href,{cache:"no-cache"});if(!r.ok)throw 0;const t=await r.text();
 const m=t.match(/data-rendered="(\d+)"/);if(m&&m[1]!==document.body.dataset.rendered)apply(t);}catch{$("#live").classList.add("off");}}
document.addEventListener("keydown",ev=>{const i=ev.target.closest&&ev.target.closest(".answer input");
 if(i&&ev.key==="Enter"&&!ev.isComposing){ev.preventDefault();sendText(i.closest(".answer"));}});
addEventListener("keydown",ev=>{if(ev.target.closest&&ev.target.closest(".answer"))return;
 if(ev.target===q){if(ev.key==="Escape"){q.value="";filter("");q.blur();}
  else if(ev.key==="Enter"||ev.key==="ArrowDown"){q.blur();}return;}
 if(ev.metaKey||ev.altKey||(ev.ctrlKey&&!"du".includes(ev.key)))return;
 const ov=$(".overlay:not([hidden])");if(ov){if(["Escape","?","L","q"].includes(ev.key)){ov.hidden=true;ev.preventDefault();}return;}
 const k=(ev.ctrlKey?"^":"")+ev.key,two=pend+k;pend="";
 const A={j:()=>move(1),ArrowDown:()=>move(1),k:()=>move(-1),ArrowUp:()=>move(-1),l:()=>to(S.pane+1),ArrowRight:()=>to(S.pane+1),
  h:()=>to(S.pane-1),ArrowLeft:()=>to(S.pane-1),Tab:()=>to(S.pane+(ev.shiftKey?-1:1)),gg:()=>move(-1e9),G:()=>move(1e9),
  Enter:openSel,o:openSel,y:()=>yank(false),Y:()=>yank(true),"/":()=>{q.focus();q.select();},
  "?":()=>{$("#help").hidden=false;},L:()=>{$("#log").hidden=false;},r:refresh,
  O:()=>{const a=$("#hud .out a");if(a)window.open(a.href,"_blank","noopener");},
  "^d":()=>body.scrollBy(0,body.clientHeight/2),"^u":()=>body.scrollBy(0,-body.clientHeight/2),
  Escape:()=>{if(S.q){q.value="";filter("");}}};
 const f=A[two]||A[k];if(f){ev.preventDefault();f();}
 else if(/^[1-9]$/.test(k)&&+k<=panes.length){ev.preventDefault();to(+k-1);}else if(k==="g")pend="g";});
document.addEventListener("click",ev=>{const b=ev.target.closest("button.copy-command,button.copy-message");
 if(b){const t=b.classList.contains("copy-message")?b.dataset.copy:b.previousElementSibling.textContent;
  copyText(t).then(()=>{b.textContent="Copied";toast("COPIED");},()=>{b.textContent="Copy failed";});return;}
 const ov=ev.target.closest(".overlay");if(ov&&!ev.target.closest(".box")){ov.hidden=true;return;}
 if(ev.target.closest("#logbtn")){$("#log").hidden=false;return;}
 const hd=ev.target.closest(".pane>header");
 if(hd&&MOB.matches){const p=hd.parentElement;if(!S.fold.delete(p.id))S.fold.add(p.id);folds();return;}
 const ab=ev.target.closest(".ans-btn");
 if(ab){if(!ab.classList.contains("armed")){$$(".ans-btn.armed").forEach(x=>x.classList.remove("armed"));ab.classList.add("armed");
   setTimeout(()=>ab.classList.remove("armed"),4000);return;}
  ab.classList.remove("armed");send(ab.closest(".answer"),{option:ab.dataset.opt});return;}
 const sb=ev.target.closest(".ans-send");if(sb){sendText(sb.closest(".answer"));return;}
 const it=ev.target.closest(".pane .it");if(it&&!ev.target.closest("a,button,input,.det")){const i=panes.indexOf(it.closest(".pane"));
  if(MOB.matches){if(it.classList.toggle("open"))S.open.add(it.dataset.key);else S.open.delete(it.dataset.key);}
  S.pane=i;S.sel[i]=it.dataset.key;show(false);}});
document.addEventListener("visibilitychange",()=>{if(!document.hidden){refresh();poll();}});
document.addEventListener("dblclick",ev=>{if(ev.target.closest(".pane .it")&&!ev.target.closest(".det,button,input,a")&&!MOB.matches)openSel();});
document.addEventListener("toggle",ev=>{const d=ev.target;if(!d.matches||!d.matches("details.rc"))return;
 if(d.open)S.rcOpen.add(d.dataset.rc);else S.rcOpen.delete(d.dataset.rc);},true);
document.addEventListener("wheel",ev=>{const s=ev.target.closest&&ev.target.closest(".wins-row,.mine-list");
 if(!s||ev.ctrlKey||s.scrollWidth<=s.clientWidth||Math.abs(ev.deltaY)<=Math.abs(ev.deltaX))return;
 s.scrollLeft+=ev.deltaY*(ev.deltaMode===1?16:ev.deltaMode===2?s.clientWidth:1);ev.preventDefault();},{passive:false});
q.addEventListener("input",()=>filter(q.value));
MOB.addEventListener("change",folds);
bind();score();show();clock();setInterval(clock,1000);setInterval(tick,30000);setInterval(refresh,10000);poll();setInterval(poll,10000);
"""


def render(paths, reason):
    now = time.time()
    today = dt.date.fromtimestamp(now).isoformat()
    confirm = env_int("FM_CURRENT_PAGE_CONFIRM_HOURS", 2) * 3600
    answers_on = bool(paths.get("answers_origin"))
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
    def heat(asked):
        return "heat1" if asked is None or now - asked < 7200 else "heat2" if now - asked < 28800 else "heat3"

    decisions = {}
    page_dir = os.path.dirname(os.path.abspath(paths["out"]))
    doc_cache = {}

    def docs(*tasks):
        return docs_line([p for t in dict.fromkeys(t for t in tasks if t) for p in task_docs(t, page_dir, doc_cache)])

    def answer_for(task, title, text, options, rec, compact=False):
        """Register one answerable decision for the answer endpoint and return its buttons; '' when answers are off."""
        if not answers_on:
            return ""
        key = answers.answer_key(task, title)
        if key in decisions and decisions[key]["title"] != title:
            key += "~" + answers.answer_key("", title)[5:11]
        if not options:
            options, rec = decision_options(f"{title} {text}")
        rev = answers.revision(key, title, text, options)
        decisions[key] = {"row": task, "title": title, "rev": rev, "options": options}
        return answer_block(key, rev, options, rec, title, compact)

    def need_div(n, stale, asked, checked):
        who, task = str(n.get("who") or ""), str(n.get("task") or "")
        host = n.get("machine") or (by_task[who]["host"] if who in by_task else mates.get(who, {}).get("host") or here)
        link = str(n.get("link") or "").strip()
        opts = [o for o in n.get("options") or [] if isinstance(o, str) and o.strip()] if isinstance(n.get("options"), list) else []
        reason = calls.get(task, {}).get("hold_reason", "")
        ans = answer_for(task, str(n["t"]), f'{n.get("why", "")} {reason}'.strip(), opts, n.get("rec") if opts else None)
        row = f'<span class="mk"></span><span class="t">{e(str(n["t"]))}</span><span class="m">{age(asked, now)}</span>'
        det = (f'<h2>{e(str(n["t"]))}</h2>'
               + chips(age(asked, now, "asked "), e(str(host)), e(who) if who != task else "", f"<code>{e(task)}</code>" if task else "",
                       f'not re-checked · {age(checked, now, "checked ")}' if stale else "")
               + f'<div class="why">{fm_md.inline(str(n.get("why", "")))}</div>{need_actions(n, bool(ans))}{ans}'
               + docs(task, who))
        return item_div("need:" + (task or str(n["t"])), row, det, href=link if re.match(r"https?://", link) else "",
                        task=task, cls=heat(asked) + (" dim" if stale else ""))
    needs_now, needs_stale, curated_tasks, asks = [], [], set(), []
    for n in cur["needs"]:
        task = str(n.get("task") or "")
        if task:
            curated_tasks.add(task)
            if held is not None and (task not in calls or calls[task]["deferred"]):
                continue
        asked = ts_of(n.get("asked")) or calls.get(task, {}).get("asked")
        checked = ts_of(n.get("checked")) or cur["checked"]
        if checked is not None and now - checked < confirm:
            needs_now.append(need_div(n, False, asked, checked))
            asks.append(asked)
        else:
            needs_stale.append(need_div(n, True, asked, checked))
    curated_tasks |= {str(f["task"]) for f in cur["factory"] if f.get("task")}  # a call in the factory band is covered there
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

    def call_div(c, note, cls=""):
        title = plain_words(c.get("title", ""), 120) or c["id"]
        reason = c.get("hold_reason", "")
        until = f'until {e(c["until"])}' if c["until"] else ""
        ans = answer_for(c["id"], title, reason, [], None)
        row = f'<span class="mk"></span><span class="t">{e(title)}</span><span class="m">{until or age(c["asked"], now)}</span>'
        det = (f"<h2>{e(title)}</h2>" + chips(age(c["asked"], now, "asked "), note, until, f'<code>{e(c["id"])}</code>')
               + f'<div class="why">{linked_words(reason, 260)}</div>'
               + (ans or '<p class="k">Answer it by telling Main.</p>') + docs(c["id"]))
        return item_div("call:" + c["id"], row, det, href=fm_md.first_url(re.sub(r"\S*data/\S+", "", reason)), task=c["id"],
                        cls=cls or heat(c["asked"]))
    for c in fresh_calls:
        needs_now.append(call_div(c, "new, not summarized yet", "new " + heat(c["asked"])))
        asks.append(c["asked"])

    # Running: workers whose endpoint is present right now; second mates always, by their routed status.
    def run_div(r):
        plain = cur["plain"].get(r["task"])
        if plain and plain["at"] is not None and now - plain["at"] < confirm and plain["at"] >= (r["updated"] or 0) - 60:
            text, as_of = plain["text"], plain["at"]
        else:
            text, as_of = plain_words(r["note"], 180) or "No report yet.", r["updated"]
        pr = f'<a href="{e(r["pr"])}">{e(fm_md.link_label(r["pr"]))}</a>' if r["pr"] else ""
        tags = ('<span class="tag">waiting on a decision from Main</span>' if r["task"] in open_by_task else "") + \
            ('<span class="tag">paused</span>' if r["verb"] == "paused" else "")
        row = f'<span class="mk"></span><span class="t">{e(r["title"])}</span><span class="m">{age(as_of, now)}</span>'
        det = (f'<h2>{e(r["title"])}</h2>' + chips(pr, e(r["host"]), age(as_of, now, "said "), f'<code>{e(r["task"])}</code>')
               + f'<div class="st">{tags}{e(text)}</div>' + docs(r["task"]))
        cls = "dim" if r["verb"] in PARKED_VERBS else "heat2" if r["task"] in open_by_task else "heat1"
        return item_div("run:" + r["task"], row, det, href=r["pr"], task=r["task"], cls=cls)
    shown = [r for r in rows if r["task"] not in cur["hide"]]
    shown.sort(key=lambda r: -(r["updated"] or 0))
    second = [r for r in shown if r["kind"] == "secondmate"]
    alive = [r for r in shown if r["kind"] != "secondmate" and live is not None and r["task"] in live]
    running = [r for r in alive if r["verb"] not in PARKED_VERBS]
    parked = [r for r in alive if r["verb"] in PARKED_VERBS]

    # Done today, by initiative. Older work and other people's merges live in Linear and GitHub.
    items, _others = completions(cur, merged, done, rows, repos, viewer, now)
    done_today = [x for x in items if x["today"]]
    for x in done_today:
        x["docs"] = docs(x.get("task", ""))

    banners = []
    if cur["error"]:
        banners.append(f"The keeper's file has a problem ({e(cur['error'])}); Needs you shows only new backlog calls.")
    if cur["checked"] is None or now - cur["checked"] >= confirm:
        banners.append(f"The page keeper last checked {age(cur['checked'], now)}; anything not re-checked is held.")
    if held is None:
        banners.append("The backlog could not be read, so answered calls may still show.")
    if live is None:
        banners.append("Could not check which workers are running.")
    if forge_state.startswith("stale"):
        banners.append(f"GitHub read failed; merged work is as of {age(fetched, now)}.")

    def sub(sid, title, divs):
        return (f'<div class="sub" id="{sid}"><h3>{e(title)} <span class="n">{len(divs)}</span></h3>{"".join(divs)}</div>'
                if divs else "")

    def pane(pid, num, title, count, body):
        return (f'<section class="pane" id="p-{pid}" data-pane="{num}" data-title="{e(title)}" data-swap>'
                f'<header><kbd>{num}</kbd><b>{e(title)}</b><span class="n">{count}</span></header>'
                f'<div class="list">{body}</div></section>')
    held_count = len(needs_stale) + len(older_calls) + len(deferred_calls)
    needs_body = ("".join(needs_now) or '<div class="zero">INBOX ZERO<small>nothing is waiting on you</small></div>')
    running_body = (f'<div id="running-now">{"".join(run_div(r) for r in running) or "<p class=k>No workers running.</p>"}</div>'
                    + sub("second-mates", "Second mates", [run_div(r) for r in second])
                    + sub("parked", "Parked, still alive", [run_div(r) for r in parked]))
    held_body = (sub("held-stale", f"Not re-checked in {confirm // 3600} h, may be answered", needs_stale)
                 + sub("held-older", "Older open calls", [call_div(c, "", "held") for c in older_calls])
                 + sub("held-deferred", "Deferred to a later date", [call_div(c, "deferred", "dim") for c in deferred_calls])
                 or "<p class=k>No other open calls.</p>")
    oldest = min((a for a in asks if a is not None), default=None)
    level, xp = 1 + len(done_today) // 5, (len(done_today) % 5) * 20
    links = "".join(f'<a href="{e(url)}" target="_blank" rel="noopener">{e(label)} &#8599;</a>' for label, url in cur["links"])
    notes_html = notes_timeline(notes, dt.date.fromtimestamp(now)) if not notes["missing"] else "<p class=k>No keeper notes file.</p>"
    help_rows = [("j / k", "move down / up"), ("h / l, Tab", "previous / next pane"), ("1 - 4", "jump to a pane"),
                 ("gg / G", "first / last item"), ("Enter, o, double-click", "open the item's link in a new tab"),
                 ("y / Y", "copy the command / the message"), ("/", "filter every pane; Esc clears"),
                 ("^d / ^u", "scroll the inspector"), ("L", "keeper log"), ("O", "open the first link-out (Linear)"),
                 ("r", "refresh now (it also refreshes itself every 10 s)"), ("?", "this help")]
    keys_help = "".join(f"<kbd>{e(k)}</kbd><span>{e(v)}</span>" for k, v in help_rows)
    # Factory blocked on you: only the calls whose answer releases running work, each with its answer inline.
    def factory_div(f):
        task = str(f.get("task") or "")
        if task and held is not None and (task not in calls or calls[task]["deferred"]):
            return ""
        title = str(f["t"])
        opts = [o for o in f.get("options") or [] if isinstance(o, str) and o.strip()] if isinstance(f.get("options"), list) else []
        ans = answer_for(task, title, str(f.get("why", "")), opts, f.get("rec"), compact=True) if opts else ""
        links = "".join(f'<a href="{e(str(lk["url"]))}" target="_blank" rel="noopener">{e(str(lk.get("label") or fm_md.link_label(str(lk["url"]))))} &#8599;</a>'
                        for lk in f.get("links") or [] if isinstance(lk, dict) and re.match(r"https://", str(lk.get("url", ""))))
        return (f'<div class="fx" data-task="{e(task)}"><span class="fx-q" title="{e(title)}">{e(title)}</span>'
                f'<span class="fx-u">&#8594; {e(str(f.get("unblocks", "")))}</span><span class="fx-a">{ans}{links}</span></div>')
    factory = [d for d in (factory_div(f) for f in cur["factory"]) if d]
    wins = "".join(
        f'<a class="win" href="{e(str(w["url"]))}" target="_blank" rel="noopener"><b>{e(str(w["t"]))}</b>'
        f'<span class="why">{e(str(w.get("why", "")))}</span>'
        f'<span class="m">{e(str(w.get("kind") or fm_md.link_label(str(w["url"]))))} &#8599;</span></a>' for w in cur["wins"])
    write_pwa_assets(page_dir, os.path.basename(paths["out"]))
    page = (
        f'<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{f"({len(needs_now)}) " if needs_now else ""}Current</title>'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<meta name="theme-color" content="#0a0a0f"><meta name="apple-mobile-web-app-capable" content="yes">'
        '<meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Current">'
        '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
        f'<link rel="manifest" href="{PWA_MANIFEST}"><link rel="apple-touch-icon" href="{PWA_ICONS[180]}">'
        f'<link rel="icon" type="image/png" href="{PWA_ICONS[192]}">'
        f"<style>{fm_md.THEME_CSS}{PAGE_CSS}</style></head>"
        f'<body data-rendered="{int(now)}"><div class="grid-bg"></div>'
        f'<div id="hud" data-swap title="{e(reason)}"'
        + (f' data-token="{answers.mint_token(now)}"' if answers_on else "")
        + '><span class="brand">FM//CURRENT</span>'
        f'<span class="live" id="live"><span class="dot"></span> <span id="live-l">LIVE</span> · {age(now, now)}</span>'
        f'<span class="stat{" hot" if needs_now else " good"}">NEED<b>{len(needs_now)}</b></span>'
        f'<span class="stat">RUN<b>{len(running)}</b></span><span class="stat good">DONE<b>{len(done_today)}</b></span>'
        f'<span class="stat">HELD<b>{held_count}</b></span>'
        + (f'<span class="stat{" hot" if now - oldest > 28800 else ""}">OLDEST CALL<b>{age(oldest, now)}</b></span>'
           if oldest is not None else "")
        + f'<span class="lv" title="one level per 5 shipped today">LV<b>{level}</b><i class="bar"><i style="width:{xp}%"></i></i></span>'
        f'<span class="sp"></span><span class="stat">KEEPER {age(cur["checked"], now)}</span>'
        f'<span class="out">{links}</span><span id="clock"></span><span class="hint"><kbd>?</kbd></span>'
        '<button type="button" id="logbtn" class="mob">Log</button></div>'
        f'<div id="warn" data-swap>{"".join(f"<p>{b}</p>" for b in banners)}</div>'
        + (f'<section id="factory" data-swap aria-label="Factory blocked on you"{"" if factory else " hidden"}>'
           f'<span class="lbl">Factory blocked on you<b>{len(factory)}</b></span><div class="fx-list">{"".join(factory)}</div></section>')
        + f'<nav id="wins" data-swap aria-label="Wins"{"" if wins else " hidden"}><span class="lbl">Wins</span><div class="wins-row">{wins}</div></nav>'
        + ('<section id="mine" hidden><span class="lbl">Your answers<span class="n"></span></span><div class="mine-list"></div></section>' if answers_on else "")
        + '<div id="cols">'
        + pane("needs", 1, "Needs you", len(needs_now), f'<div id="needs-now">{needs_body}</div>')
        + '<div class="stack">'
        + pane("running", 2, "Running", len(running), running_body)
        + pane("done", 3, "Done today", len(done_today),
               f'<div id="done">{grouped(done_today, cur["initiatives"], now) or "<p class=k>Nothing finished yet today.</p>"}</div>')
        + pane("held", 4, "Held calls", held_count, held_body)
        + '</div><aside id="insp"><header><b>Inspect</b><span>&#183;</span><span id="insp-n"></span></header><div class="body"></div>'
        f'<div id="logtail" data-swap><span class="lbl">Keeper log &#183; L for all</span>{timeline_rows(notes["events"][:6])}</div>'
        '</aside></div>'
        '<div id="keys"><span>/ <input id="q" placeholder="filter" autocomplete="off" spellcheck="false"></span>'
        '<span><kbd>j</kbd><kbd>k</kbd> move</span><span><kbd>h</kbd><kbd>l</kbd> pane</span><span><kbd>1-4</kbd> jump</span>'
        '<span><kbd>&#9166;</kbd> open</span><span><kbd>y</kbd> copy</span><span><kbd>L</kbd> log</span><span><kbd>?</kbd> help</span>'
        '<span class="sp"></span><span class="lbl">cleared this session <b id="cleared">0</b></span></div>'
        f'<div class="overlay" id="help" hidden><div class="box"><h2>Keys</h2><div class="keys">{keys_help}</div></div></div>'
        f'<div class="overlay" id="log" hidden data-swap><div class="box"><h2>Keeper log</h2>{notes_html}</div></div>'
        '<div id="toasts"></div>'
        f"<script>{PAGE_JS}</script></body></html>")
    if answers_on:   # decisions first, so a tap on the new page never meets the previous render's revisions
        answers.write_decisions(decisions, now)
    write_atomic(paths["out"], page)
    return {"needs": len(needs_now), "stale_needs": len(needs_stale), "running": len(running),
            "done_today": len(done_today), "older_calls": len(older_calls), "forge": forge_state}

# ---------- installable app (Add to Home Screen) ----------

PWA_MANIFEST = "manifest.json"
PWA_ICONS = {180: "apple-touch-icon.png", 192: "current-icon-192.png", 512: "current-icon-512.png"}


def icon_png(size):
    """The app icon as PNG bytes, drawn here so the page needs no image library: an orange radar ring with a
    teal sweep on the page's near-black, 2x2 supersampled."""
    import math
    bg, acc, data = (10, 10, 15), (255, 136, 0), (0, 221, 170)

    def mix(c, over, a):
        return tuple(c[i] + (over[i] - c[i]) * a for i in range(3))

    def shade(u, v):
        c = bg
        if abs((u + 1) * 4 % 1) < 0.02 or abs((v + 1) * 4 % 1) < 0.02:
            c = mix(c, acc, 0.12)
        r, ang = math.hypot(u, v), math.degrees(math.atan2(v, u))
        if r < 0.72 and -90 <= ang <= -30:
            c = mix(c, data, 0.45 * (ang + 90) / 60)
        if abs(r - 0.45) < 0.025:
            c = mix(c, data, 0.8)
        if abs(r - 0.72) < 0.06 or r < 0.14 or (abs(u) < 0.03 and 0.8 < abs(v) < 0.95) or (abs(v) < 0.03 and 0.8 < abs(u) < 0.95):
            c = acc
        return c
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px = [shade((x + dx) / size * 2 - 1, (y + dy) / size * 2 - 1) for dx in (0.25, 0.75) for dy in (0.25, 0.75)]
            rows.extend(int(sum(p[i] for p in px) / 4) for i in range(3))

    def chunk(kind, payload):
        return (len(payload).to_bytes(4, "big") + kind + payload
                + zlib.crc32(kind + payload).to_bytes(4, "big"))
    head = size.to_bytes(4, "big") * 2 + bytes([8, 2, 0, 0, 0])
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


def write_pwa_assets(page_dir, page_name):
    """manifest.json and the icons beside the page, so iOS Add to Home Screen opens it as a standalone app.
    Icons are drawn once (absent files only); the manifest is rewritten only when its content changes."""
    manifest = json.dumps({"name": "FM Current", "short_name": "Current", "start_url": page_name, "scope": "./",
                           "display": "standalone", "background_color": "#0a0a0f", "theme_color": "#0a0a0f",
                           "icons": [{"src": name, "sizes": f"{size}x{size}", "type": "image/png", "purpose": "any"}
                                     for size, name in PWA_ICONS.items()]}, indent=1) + "\n"
    path = os.path.join(page_dir, PWA_MANIFEST)
    try:
        with open(path, encoding="utf-8") as fh:
            same = fh.read() == manifest
    except OSError:
        same = False
    if not same:
        write_atomic(path, manifest)
    for size, name in PWA_ICONS.items():
        target = os.path.join(page_dir, name)
        if not os.path.exists(target):
            tmp = os.path.join(page_dir, f".{name}.tmp.{os.getpid()}")
            with open(tmp, "wb") as fh:
                fh.write(icon_png(size))
            os.chmod(tmp, 0o644)
            os.replace(tmp, target)



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
    """config/current-page: first plain line is the page; optional notes=<path> and curated=<path> lines, and
    answers_origin=<origin> (bin/fm-current-answers.sh's header), which turns on the page's answer buttons."""
    found = {}
    try:
        with open(os.path.join(HOME, "config", "current-page"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, val = line.split("=", 1) if re.match(r"^(notes|curated|answers_origin|answers_listen)=", line) else ("out", line)
                if key in ("answers_origin", "answers_listen"):
                    found.setdefault(key, val)
                elif key not in found:
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
    if os.environ.get("FM_CURRENT_ANSWERS_ORIGIN"):
        paths["answers_origin"] = os.environ["FM_CURRENT_ANSWERS_ORIGIN"]
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
