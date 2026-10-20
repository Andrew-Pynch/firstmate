#!/usr/bin/env python3
"""fm_current_answers.py - the current page's answer endpoint, and the pieces the renderer shares with it.

bin/fm-current-answers.sh's header owns usage, configuration, and the security contract.
The renderer (bin/fm-current-page.py) imports this module for three things so the two
sides cannot drift: the answer key and revision of a decision, the per-render CSRF
token, and the decisions file it publishes for this server to check answers against.
"""
import datetime as dt
import fcntl
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(SCRIPT_DIR)
HOME = os.environ.get("FM_HOME") or CODE_ROOT
STATE = os.path.join(HOME, "state")
PRIVATE = os.path.join(STATE, ".current-page")
SECRET = PRIVATE + "/answer-secret"
DECISIONS = os.path.join(PRIVATE, "decisions.json")
LEDGER = os.path.join(PRIVATE, "answers.jsonl")
THREAD = os.path.join(PRIVATE, "thread.jsonl")   # the Deck inbox panel's own notes, for its thread view
INBOX = os.path.join(SCRIPT_DIR, "fm-inbox.sh")

TOKEN_MAX_AGE = 24 * 3600   # the page re-renders at least every idle period, so a live tab always holds a fresh one
MAX_BODY = 4096
MAX_TEXT = 500
FEED_HOURS = 48
MAX_NOTE = 1200       # one inbox note from the phone panel, in characters
THREAD_DAYS = 7
THREAD_MAX = 400
RID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")


# ---------- shared with the renderer ----------

def answer_key(task, title):
    """A decision's stable key: its backlog row id, or a digest of its title when it has no row."""
    task = str(task or "").strip()
    return task if task else "need-" + hashlib.sha256(str(title).encode()).hexdigest()[:10]


def revision(key, title, text, options):
    """Changes whenever the decision a reader sees changes, so a stale tab cannot answer a replaced one."""
    raw = json.dumps([key, str(title), str(text), list(options)], ensure_ascii=False)
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def secret():
    """The home-private HMAC key, created once (0600) by whichever side needs it first."""
    os.makedirs(PRIVATE, exist_ok=True)
    try:
        with open(SECRET, encoding="ascii") as fh:
            value = fh.read().strip()
        if len(value) >= 32:
            return value.encode()
    except FileNotFoundError:
        pass
    value = secrets.token_hex(32)
    try:
        fd = os.open(SECRET, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:   # the other side won the race; use its key
        with open(SECRET, encoding="ascii") as fh:
            return fh.read().strip().encode()
    with os.fdopen(fd, "w", encoding="ascii") as fh:
        fh.write(value + "\n")
    return value.encode()


def mint_token(now=None):
    stamp = str(int(now if now is not None else time.time()))
    mac = hmac.new(secret(), b"fm-answer:" + stamp.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{stamp}.{mac}"


def token_ok(token, now=None):
    now = now if now is not None else time.time()
    match = re.fullmatch(r"(\d{9,11})\.([0-9a-f]{32})", token or "")
    if not match:
        return False
    stamp = match.group(1)
    want = hmac.new(secret(), b"fm-answer:" + stamp.encode(), hashlib.sha256).hexdigest()[:32]
    return hmac.compare_digest(want, match.group(2)) and -60 <= now - int(stamp) <= TOKEN_MAX_AGE


def write_decisions(decisions, now):
    """Publish the answerable decisions of one render: {key: {row, title, rev, options, text}}."""
    os.makedirs(PRIVATE, exist_ok=True)
    tmp = DECISIONS + f".tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"rendered": int(now), "decisions": decisions}, fh, ensure_ascii=False)
    os.replace(tmp, DECISIONS)


# ---------- server ----------

def configured():
    """config/current-page lines `answers_origin=<https origin>`, `answers_listen=<host>:<port>`, `linear_key_file=<path>`."""
    found = {}
    try:
        with open(os.path.join(HOME, "config", "current-page"), encoding="utf-8") as fh:
            for line in fh:
                match = re.match(r"^\s*(answers_origin|answers_listen|linear_key_file)=(\S+)\s*$", line)
                if match and match.group(1) not in found:
                    found[match.group(1)] = match.group(2)
    except OSError:
        pass
    return found


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- Linear hover cards ----------

LINEAR_API = "https://api.linear.app/graphql"
LINEAR_ID_RE = re.compile(r"^[A-Z][A-Z0-9]{1,6}-\d{1,6}$")
LINEAR_TTL = 600            # a card is at most 10 min old
LINEAR_ERROR_TTL = 30       # an upstream failure is retried soon, not hammered
CARD_LINES = 12
NOT_COUNTED_STATES = {"references"}         # reference notes: no work, so never done and never outstanding
NOT_COUNTED_TYPES = {"canceled", "duplicate"}
LINEAR_QUERY = """query($id:String!){issue(id:$id){identifier title url description state{name type}
 assignee{name displayName} projectMilestone{name issues(first:250){nodes{state{name type}}}}}}"""


def counts_toward_completion(state):
    """False for the References state, canceled, and duplicates; they are neither done nor outstanding."""
    return (str(state.get("name") or "").casefold() not in NOT_COUNTED_STATES
            and str(state.get("type") or "") not in NOT_COUNTED_TYPES)


def completion(states):
    """{"done", "total", "pct"} over the issues that count; pct is None when none count."""
    counted = [s for s in states if counts_toward_completion(s)]
    done = sum(1 for s in counted if s.get("type") == "completed")
    return {"done": done, "total": len(counted), "pct": round(100 * done / len(counted)) if counted else None}


def card(issue):
    """The hover card for one Linear issue: title, state, assignee, the body's first lines, milestone completion."""
    state = issue.get("state") or {}
    who = issue.get("assignee") or {}
    lines = [line for line in (issue.get("description") or "").splitlines() if line.strip(" *#-")]
    milestone = issue.get("projectMilestone")
    return {"id": issue.get("identifier", ""), "title": issue.get("title", ""), "url": issue.get("url", ""),
            "state": state.get("name", ""), "state_type": state.get("type", ""),
            "counted": counts_toward_completion(state), "assignee": who.get("name") or who.get("displayName") or "",
            "body": [line[:240] for line in lines[:CARD_LINES]], "more": len(lines) > CARD_LINES,
            "milestone": {"name": milestone.get("name", ""),
                          **completion([(n or {}).get("state") or {} for n in (milestone.get("issues") or {}).get("nodes") or []])}
            if milestone else None}


def linear_key():
    """The Linear API key: FM_LINEAR_API_KEY, else the `*LINEAR_API_KEY=` line (or bare key) of linear_key_file."""
    if os.environ.get("FM_LINEAR_API_KEY"):
        return os.environ["FM_LINEAR_API_KEY"].strip()
    path = configured().get("linear_key_file")
    if not path:
        return ""
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return ""
    match = re.search(r"^\s*(?:export\s+)?[A-Z_]*LINEAR_API_KEY=['\"]?([^'\"\s]+)", text, re.M)
    bare = text.strip()
    return match.group(1) if match else bare if bare and not re.search(r"\s|=", bare) else ""


class LinearCards:
    """Cards fetched from Linear's GraphQL API, cached per issue for LINEAR_TTL (errors for LINEAR_ERROR_TTL)."""
    def __init__(self):
        self.cache, self.lock = {}, threading.Lock()

    def get(self, ident):
        """(http code, payload)."""
        now = time.time()
        with self.lock:
            hit = self.cache.get(ident)
            if hit and now < hit[0]:
                return hit[1], hit[2]
        code, payload = self.fetch(ident)
        ttl = LINEAR_TTL if code in (200, 404) else LINEAR_ERROR_TTL
        with self.lock:
            self.cache[ident] = (now + ttl, code, {**payload, "fetched": iso(now)})
        return code, self.cache[ident][2]

    def fetch(self, ident):
        import urllib.request
        key = linear_key()
        if not key:
            return 503, {"error": "linear", "detail": "no Linear key configured (linear_key_file in config/current-page)"}
        req = urllib.request.Request(LINEAR_API, json.dumps({"query": LINEAR_QUERY, "variables": {"id": ident}}).encode(),
                                     {"Content-Type": "application/json", "Authorization": key})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
        except (OSError, ValueError) as exc:
            return 502, {"error": "linear", "detail": type(exc).__name__}
        issue = (data.get("data") or {}).get("issue")
        if issue:
            return 200, card(issue)
        if any("not found" in str(err.get("message", "")).casefold() or
               (err.get("extensions") or {}).get("code") == "INPUT_ERROR" for err in data.get("errors") or []) or not data.get("errors"):
            return 404, {"error": "not found", "id": ident}
        return 502, {"error": "linear", "detail": "upstream error"}


def read_decisions():
    try:
        with open(DECISIONS, encoding="utf-8") as fh:
            data = json.load(fh)
        return data.get("decisions") or {}
    except (OSError, ValueError):
        return None


def ledger_append(entry):
    os.makedirs(PRIVATE, exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def ledger_recent(now):
    """Newest answer per key from the last FEED_HOURS, newest first."""
    latest = {}
    try:
        with open(LEDGER, encoding="utf-8") as fh:
            lines = fh.readlines()[-500:]
    except OSError:
        return []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and now - row.get("ts", 0) < FEED_HOURS * 3600:
            latest[row.get("key")] = row
    return sorted(latest.values(), key=lambda r: -r.get("ts", 0))


class Receipts:
    """fm-inbox.sh receipts, cached briefly so a page polling every 10 s costs one read per few seconds."""
    def __init__(self, ttl=3.0):
        self.ttl, self.at, self.data, self.lock = ttl, 0.0, None, threading.Lock()

    def get(self):
        with self.lock:
            if self.data is None or time.time() - self.at > self.ttl:
                res = subprocess.run([INBOX, "receipts", "--all-pending", "--all-handled", "--all-replies"],
                                     capture_output=True, text=True, timeout=30, env={**os.environ, "FM_HOME": HOME})
                data = json.loads(res.stdout) if res.returncode == 0 else {}
                self.data = {"pending": {n["id"] for n in data.get("pending") or []},
                             "handled": {n["id"] for n in data.get("handled") or []},
                             "replies": {r["id"]: r for r in data.get("replies") or []}}
                self.at = time.time()
            return self.data

    def invalidate(self):
        with self.lock:
            self.data = None


def thread_append(entry):
    os.makedirs(PRIVATE, exist_ok=True)
    with open(THREAD, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def thread_recent(now):
    """The panel's own notes from the last THREAD_DAYS, oldest first."""
    try:
        with open(THREAD, encoding="utf-8") as fh:
            lines = fh.readlines()[-THREAD_MAX:]
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and now - row.get("ts", 0) < THREAD_DAYS * 86400:
            out.append(row)
    return out


def thread_body(text):
    return ("deck-phone-note\n"
            "the captain wrote to Main from the Deck inbox panel:\n\n"
            f"{text}\n\n"
            "Answer with `bin/fm-inbox.sh reply <this note id> <text>`; the reply shows in his Deck inbox thread.\n")


def note_body(row, decision, answer, key, rev):
    return (f"current-page-answer row={row or '-'} key={key} rev={rev}\n"
            f"the captain answered from the current page: {answer}\n"
            f"decision: {decision.get('title', '')}\n\n"
            "Act on it as the captain's answer to that decision. Publish what you did with "
            "`bin/fm-inbox.sh reply <this note id> <text>`; the reply shows under the item on the page.\n")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fm-current-answers"
    sys_version = ""

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} {fmt % args}", flush=True)

    def route(self):
        path = urllib.parse.urlsplit(self.path).path
        return path[4:] if path.startswith("/api/") else path

    def send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):   # no CORS: a foreign origin's preflight gets no allow headers
        self.send(405, {"error": "method"})

    def do_GET(self):
        route = self.route()
        if route == "/health":
            self.send(200, {"ok": True})
        elif route == "/answers":
            self.send(200, self.feed())
        elif route == "/thread":
            self.send(200, self.thread())
        elif route.startswith("/linear/") and LINEAR_ID_RE.fullmatch(route[8:]):
            code, payload = self.server.linear.get(route[8:])
            self.send(code, payload)
        else:
            self.send(404, {"error": "not found"})

    def same_origin(self):
        origin = self.server.origin
        sent = self.headers.get("Origin")
        if sent is not None:
            ok = sent == origin
        else:
            referer = self.headers.get("Referer") or ""
            ok = referer == origin or referer.startswith(origin + "/")
        site = self.headers.get("Sec-Fetch-Site")
        return ok and site in (None, "same-origin")

    def read_post(self, what):
        """The shared refusals for every POST: same origin, JSON, the page token, a sane size, a request id."""
        if not self.same_origin():
            return None, self.send(403, {"error": "origin", "detail": f"{what} come only from the Deck page"})
        if (self.headers.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json":
            return None, self.send(415, {"error": "content-type", "detail": "JSON only"})
        if not token_ok(self.headers.get("X-FM-Answer-Token")):
            return None, self.send(403, {"error": "token", "detail": "reload the page"})
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if not 0 < length <= MAX_BODY:
            return None, self.send(413, {"error": "size"})
        try:
            req = json.loads(self.rfile.read(length))
        except ValueError:
            return None, self.send(400, {"error": "json"})
        if not isinstance(req, dict):
            return None, self.send(400, {"error": "json"})
        if not RID_RE.match(str(req.get("rid") or "")):
            return None, self.send(400, {"error": "rid"})
        return req, None

    def inbox_note(self, request_id, body):
        res = subprocess.run([INBOX, "note", "--request-id", request_id, "--json", "-"], input=body,
                             capture_output=True, text=True, timeout=30, env={**os.environ, "FM_HOME": HOME})
        try:
            note = json.loads(res.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            note = {}
        if res.returncode not in (0, 3) or not note.get("saved"):
            return None, (res.stderr or "note not saved").strip()[:200]
        return note, None

    def do_POST(self):
        route = self.route()
        if route == "/answer":
            return self.post_answer()
        if route == "/note":
            return self.post_note()
        return self.send(404, {"error": "not found"})

    def post_note(self):
        req, _ = self.read_post("notes")
        if req is None:
            return
        text = str(req.get("text") or "").replace("\r\n", "\n").strip()
        if not text:
            return self.send(400, {"error": "empty"})
        if len(text) > MAX_NOTE:
            return self.send(400, {"error": "text", "detail": f"at most {MAX_NOTE} characters"})
        rid = str(req["rid"])
        note, err = self.inbox_note("deck-note-" + rid, thread_body(text))
        if note is None:
            return self.send(502, {"error": "inbox", "detail": err})
        now = time.time()
        if note.get("outcome") != "replay":
            thread_append({"ts": int(now), "note": note["id"], "text": text, "rid": rid})
        self.server.receipts.invalidate()
        self.send(200, {"state": "received", "note": note["id"], "at": iso(now), "announced": note.get("announced"),
                        "outcome": note.get("outcome")})

    def post_answer(self):
        req, _ = self.read_post("answers")
        if req is None:
            return
        key, rev, rid = str(req.get("key") or ""), str(req.get("rev") or ""), str(req.get("rid") or "")
        option, text = req.get("option"), req.get("text")
        decisions = read_decisions()
        if decisions is None:
            return self.send(503, {"error": "decisions", "detail": "the page has not published its decisions"})
        decision = decisions.get(key)
        if decision is None:
            return self.send(409, {"error": "gone", "detail": "that decision is no longer open; refreshing"})
        if decision.get("rev") != rev:
            return self.send(409, {"error": "stale", "detail": "that decision changed; refreshing"})
        if isinstance(option, str) and option:
            if option not in (decision.get("options") or []):
                return self.send(400, {"error": "option"})
            answer = option
        elif isinstance(text, str) and text.strip():
            answer = " ".join(text.split())
            if len(answer) > MAX_TEXT:
                return self.send(400, {"error": "text", "detail": f"at most {MAX_TEXT} characters"})
        else:
            return self.send(400, {"error": "empty"})
        note, err = self.inbox_note("current-page-" + rid, note_body(decision.get("row"), decision, answer, key, rev))
        if note is None:
            return self.send(502, {"error": "inbox", "detail": err})
        now = time.time()
        if note.get("outcome") != "replay":
            ledger_append({"ts": int(now), "key": key, "rev": rev, "row": decision.get("row") or "",
                           "title": decision.get("title", ""), "answer": answer, "note": note["id"], "rid": rid})
        self.server.receipts.invalidate()
        self.send(200, {"state": "received", "key": key, "answer": answer, "note": note["id"], "at": iso(now),
                        "announced": note.get("announced"), "outcome": note.get("outcome")})

    def receipts_or_empty(self, needed):
        try:
            return (self.server.receipts.get() if needed else {"pending": set(), "handled": set(), "replies": {}}), False
        except (OSError, ValueError, subprocess.SubprocessError):
            return {"pending": set(), "handled": set(), "replies": {}}, True

    def thread(self):
        """The Deck inbox thread: the panel's notes and the page's decision answers, oldest first, each with Main's reply."""
        now = time.time()
        notes, answers_ = thread_recent(now), ledger_recent(now)
        rec, unread = self.receipts_or_empty(bool(notes or answers_))
        def state(note):
            return "answered" if note in rec["replies"] else "seen" if note in rec["handled"] else "received"
        def reply(note):
            r = rec["replies"].get(note)
            return (r.get("body", "").strip(), r.get("at")) if r else ("", None)
        msgs = [{"kind": "note", "note": n["note"], "text": n["text"], "ts": n["ts"], "at": iso(n["ts"]), "state": state(n["note"]),
                 "reply": reply(n["note"])[0], "reply_at": reply(n["note"])[1]} for n in notes]
        msgs += [{"kind": "answer", "note": a["note"], "text": a["answer"], "title": a["title"], "ts": a["ts"], "at": iso(a["ts"]),
                  "state": state(a["note"]), "reply": reply(a["note"])[0], "reply_at": reply(a["note"])[1]} for a in answers_]
        msgs.sort(key=lambda m: m["ts"])
        return {"now": iso(now), "messages": msgs, "receipts": "unreadable" if unread else "ok"}

    def feed(self):
        now = time.time()
        rows = ledger_recent(now)
        try:
            rec = self.server.receipts.get() if rows else {"pending": set(), "handled": set(), "replies": {}}
            unread = False
        except (OSError, ValueError, subprocess.SubprocessError):
            rec, unread = {"pending": set(), "handled": set(), "replies": {}}, True
        out = []
        for r in rows:
            reply = rec["replies"].get(r["note"])
            state = "answered" if reply else "seen" if r["note"] in rec["handled"] else "received"
            out.append({"key": r["key"], "rev": r["rev"], "row": r["row"], "title": r["title"], "answer": r["answer"],
                        "note": r["note"], "at": iso(r["ts"]), "state": state,
                        "reply": reply.get("body", "").strip() if reply else "", "reply_at": reply.get("at") if reply else None})
        return {"now": iso(now), "answers": out, "receipts": "unreadable" if unread else "ok"}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def listen_address(value):
    host, _, port = value.rpartition(":")
    host = host.strip("[]")
    addr = ipaddress.ip_address(host)
    if not (addr.is_loopback or addr in ipaddress.ip_network("100.64.0.0/10") or addr in ipaddress.ip_network("fd7a:115c:a1e0::/48")):
        raise ValueError(f"{host} is neither loopback nor a tailnet address")
    return host, int(port)


def main(argv):
    conf = configured()
    origin = os.environ.get("FM_CURRENT_ANSWERS_ORIGIN") or conf.get("answers_origin")
    listen = os.environ.get("FM_CURRENT_ANSWERS_LISTEN") or conf.get("answers_listen") or "127.0.0.1:8451"
    if argv and argv[0] in ("-h", "--help"):
        return 0
    if argv:
        print(f"fm-current-answers: unknown argument {argv[0]!r} (see --help)", file=sys.stderr)
        return 2
    if not origin or not re.fullmatch(r"https://[A-Za-z0-9.-]+(:\d+)?", origin):
        print("fm-current-answers: set answers_origin=https://<host>[:port] in config/current-page", file=sys.stderr)
        return 2
    try:
        host, port = listen_address(listen)
    except ValueError as exc:
        print(f"fm-current-answers: refusing answers_listen={listen}: {exc}", file=sys.stderr)
        return 2
    secret()
    srv = Server((host, port), Handler)
    srv.origin, srv.receipts, srv.linear = origin, Receipts(), LinearCards()
    print(f"fm-current-answers: listening on {host}:{port} for {origin}", flush=True)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
