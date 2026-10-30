#!/usr/bin/env python3
"""fm_share.py - explicit share links: publish a snapshot of one artifact under an unguessable token, list the
live shares, revoke one, and serve only the shared files; and share one running local Pilot slot with one
tailnet account (share-slot).

bin/fm-share.sh's header owns usage, configuration, layout, and the serving contract. The Deck renderer
(bin/fm-current-page.py) and its endpoint (bin/fm_current_answers.py) import this module, so the page, its
share buttons, and the command line read and change one set of shares.
"""
import datetime as dt
import http.server
import json
import mimetypes
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(SCRIPT_DIR)
HOME = os.environ.get("FM_HOME") or CODE_ROOT

TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{22,64}")
TOKEN_BYTES = 18                      # 24 URL-safe characters, 144 random bits
EMPTY_PAGE = b"<!doctype html><title>nothing here</title>\n"
LISTEN_DEFAULT = "127.0.0.1:8450"


# ---------- configuration ----------

def share_root():
    return os.path.abspath(os.path.expanduser(os.environ.get("FM_SHARE_ROOT") or "~/.local/share/fm-share"))


def records_dir():
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.abspath(os.path.expanduser(os.environ.get("FM_SHARE_RECORDS") or os.path.join(state, "fm-share")))


def _config_line(key):
    try:
        with open(os.path.join(HOME, "config", "current-page"), encoding="utf-8") as fh:
            for line in fh:
                match = re.match(r"^\s*" + key + r"=(\S+)\s*$", line)
                if match:
                    return match.group(1)
    except OSError:
        pass
    return None


def origin():
    """The https origin share links are minted under, or None when sharing is not configured."""
    value = (os.environ.get("FM_SHARE_ORIGIN") or _config_line("share_origin") or "").rstrip("/")
    return value if re.fullmatch(r"https://[A-Za-z0-9.-]+(:\d+)?", value) else None


def listen():
    return os.environ.get("FM_SHARE_LISTEN") or _config_line("share_listen") or LISTEN_DEFAULT


# ---------- shares ----------

class ShareError(Exception):
    pass


def safe_name(name):
    """A published file or folder name: URL-safe characters only, never hidden, never empty."""
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).lstrip(".-") or "file"
    return name[:120]


def _record_path(token):
    return os.path.join(records_dir(), token + ".json")


def _read_record(token):
    try:
        with open(_record_path(token), encoding="utf-8") as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else None
    except (OSError, ValueError):
        return None


def _write_record(rec):
    os.makedirs(records_dir(), mode=0o700, exist_ok=True)
    path = _record_path(rec["token"])
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def url_for(token, rel):
    base = origin()
    path = "/" + token + "/" + urllib.parse.quote(rel)
    return (base + path) if base else path


def _public_files(folder):
    """Every regular, non-hidden file under a share folder, as paths relative to it, sorted."""
    out = []
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not os.path.islink(os.path.join(dirpath, d)))
        for f in sorted(filenames):
            full = os.path.join(dirpath, f)
            if not f.startswith(".") and os.path.isfile(full) and not os.path.islink(full):
                out.append(os.path.relpath(full, folder))
    return out


def _snapshot(src, dest):
    """Copy src (a file, or a folder without its symlinks and hidden entries) to dest, world-readable."""
    if os.path.isfile(src):
        shutil.copyfile(src, dest)
        os.chmod(dest, 0o644)
        return
    shutil.copytree(src, dest, ignore=lambda d, names: [n for n in names
                                                        if n.startswith(".") or os.path.islink(os.path.join(d, n))])
    for dirpath, dirnames, filenames in os.walk(dest):
        os.chmod(dirpath, 0o755)
        for f in filenames:
            os.chmod(os.path.join(dirpath, f), 0o644)


def add(source, label="", rid=""):
    """Publish a copy of one file, or of one folder that has an index.html, under a fresh token; return its record."""
    src = os.path.realpath(source)
    root = share_root()
    if not os.path.exists(src):
        raise ShareError(f"no such file: {source}")
    if os.path.isdir(src) and not os.path.isfile(os.path.join(src, "index.html")):
        raise ShareError(f"a shared folder needs an index.html: {source}")
    if not (os.path.isfile(src) or os.path.isdir(src)):
        raise ShareError(f"not a regular file or folder: {source}")
    if src == root or src.startswith(root + os.sep):
        raise ShareError("that is already inside the share folder")
    if rid:
        for rec in shares():
            if rec.get("rid") == rid:
                return rec
    os.makedirs(root, mode=0o755, exist_ok=True)
    token = secrets.token_urlsafe(TOKEN_BYTES)
    while os.path.lexists(os.path.join(root, token)):
        token = secrets.token_urlsafe(TOKEN_BYTES)
    name = safe_name(os.path.basename(src))
    staging = os.path.join(root, f".staging-{token}")
    os.mkdir(staging, 0o755)
    try:
        os.chmod(staging, 0o755)
        _snapshot(src, os.path.join(staging, name))
        kind = "folder" if os.path.isdir(src) else "file"
        rec = {"token": token, "name": name, "entry": f"{name}/index.html" if kind == "folder" else name, "kind": kind,
               "source": src, "label": str(label or "").strip()[:200], "created": int(time.time()), "rid": rid or ""}
        _write_record(rec)
        os.rename(staging, os.path.join(root, token))
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        try:
            os.remove(_record_path(token))
        except OSError:
            pass
        raise
    return _view(rec)


def _view(rec):
    rec = dict(rec)
    rec["url"] = url_for(rec["token"], rec["entry"])
    rec.setdefault("files", [rec["entry"]])
    return rec


def shares():
    """Every live share, newest first. A token folder with no record (made by hand) lists each of its files."""
    root = share_root()
    try:
        names = os.listdir(root)
    except OSError:
        return []
    out = []
    for token in names:
        folder = os.path.join(root, token)
        if not TOKEN_RE.fullmatch(token) or os.path.islink(folder) or not os.path.isdir(folder):
            continue
        rec = _read_record(token)
        if rec and rec.get("token") == token and rec.get("entry"):
            out.append(_view(rec))
            continue
        files = [f for f in _public_files(folder) if f != "index.html"]
        out.append({"token": token, "name": "", "entry": "", "kind": "by hand", "source": "", "label": "",
                    "created": int(os.stat(folder).st_mtime), "rid": "", "url": url_for(token, files[0]) if files else "",
                    "files": files, "urls": [url_for(token, f) for f in files]})
    for rec in out:
        rec.setdefault("urls", [url_for(rec["token"], f) for f in rec["files"]])
    out.sort(key=lambda r: r["created"], reverse=True)
    return out


def revoke(token):
    """Remove one share's folder and record at once; False when no such share exists."""
    if not TOKEN_RE.fullmatch(token or ""):
        raise ShareError(f"not a share token: {token!r}")
    root = share_root()
    folder = os.path.join(root, token)
    found = False
    if os.path.lexists(folder):
        gone = os.path.join(root, f".revoked-{token}-{os.getpid()}")
        os.rename(folder, gone)    # one atomic step takes the link down; deleting the copy follows
        shutil.rmtree(gone, ignore_errors=True)
        found = True
    try:
        os.remove(_record_path(token))
        found = True
    except FileNotFoundError:
        pass
    return found


# ---------- server ----------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fm-share"
    sys_version = ""

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')} {fmt % args}", flush=True)

    def do_GET(self):
        self.serve(body=True)

    def do_HEAD(self):
        self.serve(body=False)

    def headers_common(self, ctype, length):
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        self.end_headers()

    def empty(self, code, body):
        self.send_response(code)
        self.headers_common("text/html; charset=utf-8", len(EMPTY_PAGE))
        if body:
            self.wfile.write(EMPTY_PAGE)

    def resolve(self):
        """The shared file a request names, or None. Only /<token>/<file> with every part plain and visible."""
        path = urllib.parse.urlsplit(self.path).path
        parts = [urllib.parse.unquote(p) for p in path.split("/")[1:]]
        if len(parts) < 2 or not TOKEN_RE.fullmatch(parts[0]):
            return None
        if any(not p or p.startswith(".") or "\\" in p or "\0" in p or "/" in p for p in parts):
            return None
        root = self.server.root
        tokdir = os.path.join(root, parts[0])
        if os.path.islink(tokdir) or not os.path.isdir(tokdir):
            return None
        full = os.path.join(tokdir, *parts[1:])
        real = os.path.realpath(full)
        if not real.startswith(os.path.realpath(tokdir) + os.sep) or os.path.islink(full) or not os.path.isfile(real):
            return None
        return real

    def serve(self, body):
        if urllib.parse.urlsplit(self.path).path == "/":
            return self.empty(200, body)
        path = self.resolve()
        if path is None:
            return self.empty(404, body)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            return self.empty(404, body)
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json", "image/svg+xml"):
            ctype += "; charset=utf-8"
        self.send_response(200)
        self.headers_common(ctype, len(data))
        if body:
            self.wfile.write(data)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def serve():
    sys.path.insert(0, SCRIPT_DIR)
    from fm_current_answers import listen_address   # one owner for the loopback-or-tailnet listen rule
    value = listen()
    try:
        host, port = listen_address(value)
    except ValueError as exc:
        print(f"fm-share: refusing share_listen={value}: {exc}", file=sys.stderr)
        return 2
    root = share_root()
    os.makedirs(root, mode=0o755, exist_ok=True)
    srv = Server((host, port), Handler)
    srv.root = root
    print(f"fm-share: serving {root} on {host}:{port}", flush=True)
    srv.serve_forever()
    return 0


# ---------- Pilot slots ----------
# The local Pilot stack (pilot/scripts/up.sh in the monorepo) runs slot N, N in 0..4, on fixed ports: web
# 5173 + 100 * N and Convex 3210 + 100 * N. Its web app gives the browser a Convex URL; a loopback one is
# rewritten to the page's own host name with the same scheme and port (pilot/apps/web/src/convexUrl.ts), so a
# viewer on the tailnet reaches both only when both ports answer on this machine's tailnet name over plain http.

PILOT_SLOTS = range(5)
ACCOUNT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}@[A-Za-z0-9][A-Za-z0-9.-]{0,63}")
LOOPBACK = ("127.0.0.1", "localhost", "::1")
DENY_PORTS = (22, 443, 8449)   # the policy tests: SSH, the tailnet https front, and the Deck stay closed to the account


class SlotError(ShareError):
    """The slot cannot be shared: it is not up, a port is served another way, or the tailnet path does not answer."""


def slot_ports(slot):
    """(web, Convex) ports of one Pilot slot. FM_SHARE_PILOT_PORT_OFFSET moves both, for tests only."""
    offset = int(os.environ.get("FM_SHARE_PILOT_PORT_OFFSET") or 0)
    return offset + 5173 + 100 * slot, offset + 3210 + 100 * slot


def pilot_link(url, host, served=None):
    """(slot, path) when url opens a Pilot slot's web on this machine, else None.

    A slot's web port on loopback or this host's name counts, and so does another port on this host's name that a
    tailscale serve entry proxies to a slot's web port; served() returns that {port: slot} map and is only called
    for such a link.
    """
    try:
        parts = urllib.parse.urlsplit(str(url).strip())
        port = parts.port
    except ValueError:
        return None
    name, host = (parts.hostname or "").lower(), str(host or "").lower()
    if parts.scheme not in ("http", "https") or port is None:
        return None
    named = bool(host) and (name == host or name.startswith(host + "."))
    if name not in LOOPBACK and not named:
        return None
    path = (parts.path or "/") + ("?" + parts.query if parts.query else "") + ("#" + parts.fragment if parts.fragment else "")
    for slot in PILOT_SLOTS:
        if slot_ports(slot)[0] == port:
            return slot, path
    slot = (served() or {}).get(port) if named and served else None
    return (slot, path) if slot is not None else None


def served_slot_ports():
    """{tailnet port: slot} for each tailscale serve entry whose / proxies a Pilot slot's web port; {} on any failure."""
    try:
        status = _serve_status()
    except ShareError:
        return {}
    webs = {slot_ports(s)[0]: s for s in PILOT_SLOTS}
    out = {}
    for hostport, cfg in (status.get("Web") or {}).items() if isinstance(status, dict) else ():
        target = str((((cfg or {}).get("Handlers") or {}).get("/") or {}).get("Proxy") or "")
        m = re.fullmatch(r"http://(?:127\.0\.0\.1|localhost):(\d+)/?", target)
        port = str(hostport).rsplit(":", 1)[-1]
        if m and int(m.group(1)) in webs and port.isdigit():
            out[int(port)] = webs[int(m.group(1))]
    return out


def _tailscale(*args):
    exe = shutil.which("tailscale")
    if not exe:
        raise SlotError("tailscale is not installed on this machine")
    try:
        res = subprocess.run([exe, *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SlotError(f"tailscale {' '.join(args)}: {exc}")
    if res.returncode != 0:
        raise SlotError(f"tailscale {' '.join(args)} failed: {(res.stderr or res.stdout).strip()[:300]}")
    return res.stdout


def tailnet_self():
    """This machine on the tailnet: its MagicDNS name and its machine name (the policy's host name for it)."""
    try:
        dns = str(json.loads(_tailscale("status", "--self", "--json"))["Self"]["DNSName"]).rstrip(".").lower()
    except (ValueError, KeyError, TypeError):
        raise SlotError("tailscale status gave no MagicDNS name for this machine")
    if not dns:
        raise SlotError("this machine has no MagicDNS name; turn MagicDNS on for the tailnet")
    return {"dns": dns, "name": dns.split(".")[0]}


def tailnet_accounts():
    """The login names tailscale knows besides this machine's own user, sorted; [] when tailscale cannot say."""
    try:
        d = json.loads(_tailscale("status", "--json"))
        me = str(d["Self"]["UserID"])
        return sorted({str(u.get("LoginName")) for k, u in (d.get("User") or {}).items()
                       if str(k) != me and ACCOUNT_RE.fullmatch(str(u.get("LoginName") or ""))})
    except (ShareError, ValueError, KeyError, TypeError, AttributeError):
        return []


def _listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            return True
    except OSError:
        return False


def _status_code(url):
    try:
        with urllib.request.urlopen(url, timeout=15) as res:
            return res.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (OSError, ValueError):
        return None


def pilot_backend(web):
    """The Convex URL the slot's web app gives the browser, read from its dev bundle; '' when it uses the page origin."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{web}/src/main.tsx", timeout=15) as res:
            text = res.read(4_000_000).decode("utf-8", "replace")
    except (OSError, ValueError) as exc:
        raise SlotError(f"the web app on 127.0.0.1:{web} did not serve its Pilot bundle (/src/main.tsx): {exc}")
    env = {k: v for k, v in re.findall(r'"(VITE_CONVEX_(?:URL|DEFAULT_URL|SAME_ORIGIN))":\s*"([^"]*)"', text)}
    if not env:
        raise SlotError(f"the web app on 127.0.0.1:{web} is not a Pilot dev server (no Convex URL in /src/main.tsx)")
    if env.get("VITE_CONVEX_SAME_ORIGIN") == "1":
        return ""
    raw = env.get("VITE_CONVEX_URL") or env.get("VITE_CONVEX_DEFAULT_URL") or ""
    if not raw:
        raise SlotError(f"the web app on 127.0.0.1:{web} names no Convex URL")
    return raw


def browser_backend(raw, me):
    """Where a tailnet viewer's browser sends Convex traffic: {url, port, serve}; port None for another machine."""
    try:
        p = urllib.parse.urlsplit(raw)
        port = p.port or (443 if p.scheme == "https" else 80)
    except ValueError:
        raise SlotError(f"the web app's Convex URL {raw} does not parse")
    host = (p.hostname or "").lower()
    if host in LOOPBACK:
        if p.scheme != "http":
            raise SlotError(f"the web app's Convex URL {raw} is loopback https, which no tailnet serve can stand in for")
        return {"url": f"http://{me['dns']}:{port}", "port": port, "serve": True}
    if host in (me["dns"], me["name"]):
        return {"url": f"{p.scheme}://{p.netloc}", "port": port, "serve": False}
    return {"url": f"{p.scheme}://{p.netloc}", "port": None, "serve": False}


def _serve_entry(status, dns, port):
    """'present' when port is served over http to the same loopback port, None when unserved, else what is there."""
    tcp = (status.get("TCP") or {}).get(str(port))
    if not tcp:
        return None
    handlers = ((status.get("Web") or {}).get(f"{dns}:{port}") or {}).get("Handlers") or {}
    target = (handlers.get("/") or {}).get("Proxy")
    if tcp.get("HTTP") and target == f"http://127.0.0.1:{port}" and len(handlers) == 1:
        return "present"
    scheme = "https" if tcp.get("HTTPS") else "http" if tcp.get("HTTP") else "tcp"
    return f"{scheme} to {target or tcp.get('TCPForward') or 'something else'}"


def _serve_status():
    out = _tailscale("serve", "status", "--json").strip()
    try:
        return json.loads(out) if out else {}
    except ValueError:
        raise SlotError("tailscale serve status --json did not print JSON")


def ensure_serve(port, dns):
    """Serve 127.0.0.1:port on the tailnet name at the same port over http; 'present' or 'added'."""
    found = _serve_entry(_serve_status(), dns, port)
    if found == "present":
        return "present"
    if found:
        raise SlotError(f"tailnet port {port} is already served ({found}); a Pilot slot needs plain http to "
                        f"127.0.0.1:{port}. Free it with `tailscale serve --{found.split()[0]}={port} off` if it is stale")
    _tailscale("serve", "--bg", f"--http={port}", f"http://127.0.0.1:{port}")
    if _serve_entry(_serve_status(), dns, port) != "present":
        raise SlotError(f"tailscale serve did not take port {port}")
    return "added"


def share_slot(slot, to, path="/"):
    """Serve one running Pilot slot's web and Convex ports on the tailnet and return the grant, tests, and link."""
    if not isinstance(slot, int) or isinstance(slot, bool) or slot not in PILOT_SLOTS:
        raise ShareError(f"a Pilot slot is 0 to {PILOT_SLOTS[-1]}")
    to = str(to or "").strip()
    if not ACCOUNT_RE.fullmatch(to):
        raise ShareError("--to takes one tailnet account such as name@github (never autogroup:shared)")
    path = str(path or "/")
    if not re.fullmatch(r"/[^\s\"'<>\\`]{0,1000}", path):
        raise ShareError("a path starts with / and has no spaces or quotes")
    web, convex = slot_ports(slot)
    if not _listening(web):
        raise SlotError(f"Pilot slot {slot} is not up: nothing listens on 127.0.0.1:{web}")
    raw = pilot_backend(web)
    me = tailnet_self()
    backend = browser_backend(raw, me) if raw else {"url": f"http://{me['dns']}:{web}", "port": None, "serve": False}
    if backend["serve"] and not _listening(backend["port"]):
        raise SlotError(f"the slot's web app sends Convex traffic to {raw}, and nothing listens on 127.0.0.1:{backend['port']}")
    serves = [{"port": web, "state": ensure_serve(web, me["dns"])}]
    if backend["serve"] and backend["port"] != web:
        serves.append({"port": backend["port"], "state": ensure_serve(backend["port"], me["dns"])})
    ports = [web] + ([backend["port"]] if backend["port"] not in (None, web) else [])
    url = f"http://{me['dns']}:{web}{path}"
    checks = {"web": _status_code(f"http://{me['dns']}:{web}/")}
    if raw:
        checks["convex"] = _status_code(backend["url"] + "/version")
    bad = {k: v for k, v in checks.items() if v != 200}
    if bad:
        raise SlotError("served, but over the tailnet name from this machine "
                        + ", ".join(f"{k} answered {v or 'nothing'}" for k, v in bad.items()))
    host = me["name"]
    return {
        "slot": slot, "to": to, "web_port": web, "convex_port": convex, "backend": backend["url"],
        "serve": serves, "url": url, "checks": checks,
        "grant": {"src": [to], "dst": [host], "ip": [f"tcp:{p}" for p in ports]},
        "test": {"src": to, "accept": [f"{host}:{p}" for p in ports], "deny": [f"{host}:{p}" for p in DENY_PORTS]},
    }


def slot_text(res):
    """share-slot's printout: what is served, the link to send, and the two policy blocks to paste by hand."""
    lines = [f"Pilot slot {res['slot']}: web 127.0.0.1:{res['web_port']}, its browser talks to Convex at {res['backend']}"]
    lines += [f"  tailscale serve http :{s['port']} -> 127.0.0.1:{s['port']} ({s['state']})" for s in res["serve"]]
    lines += ["  checked over the tailnet name from here: " + ", ".join(f"{k} {v}" for k, v in res["checks"].items()), "",
              "Paste by hand into the tailnet policy file (there is no policy API here), keeping every existing grant:",
              '  under "grants":', "    " + json.dumps(res["grant"]) + ",",
              '  under "tests":', "    " + json.dumps(res["test"]) + ",", "",
              f"Then send {res['to']} this link:", f"  {res['url']}"]
    return "\n".join(lines)


# ---------- command line ----------

def _when(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def main(argv):
    args = list(argv)
    verb = args.pop(0) if args else ""
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    try:
        if verb == "add":
            label = ""
            if "--label" in args:
                i = args.index("--label")
                if i + 1 >= len(args):
                    raise ShareError("--label needs a value")
                label = args[i + 1]
                del args[i:i + 2]
            if len(args) != 1:
                raise ShareError("usage: fm-share.sh add <path> [--label <text>] [--json]")
            rec = add(args[0], label)
            print(json.dumps(rec, ensure_ascii=False) if as_json else rec["url"])
            if not origin():
                print("fm-share: no share_origin configured, so the link above is only a path", file=sys.stderr)
            return 0
        if verb == "list" and not args:
            rows = shares()
            if as_json:
                print(json.dumps(rows, ensure_ascii=False))
                return 0
            for r in rows:
                print(f'{r["token"]}  {_when(r["created"])}  {r["label"] or r["name"] or "(made by hand)"}')
                for u in r["urls"]:
                    print(f"    {u}")
            return 0
        if verb == "revoke" and len(args) == 1:
            if not revoke(args[0]):
                print(f"fm-share: no share {args[0]}", file=sys.stderr)
                return 1
            print(f"revoked {args[0]}")
            return 0
        if verb == "serve" and not args:
            return serve()
        if verb == "share-slot":
            to, path = None, "/"
            for flag in ("--to", "--path"):
                if flag in args:
                    i = args.index(flag)
                    if i + 1 >= len(args):
                        raise ShareError(f"{flag} needs a value")
                    to, path = (args[i + 1], path) if flag == "--to" else (to, args[i + 1])
                    del args[i:i + 2]
            if len(args) != 1 or not args[0].isdigit() or to is None:
                raise ShareError("usage: fm-share.sh share-slot <pilot-slot> --to <account> [--path /p] [--json]")
            try:
                res = share_slot(int(args[0]), to, path)
            except SlotError as exc:
                print(f"fm-share: {exc}", file=sys.stderr)
                return 1
            print(json.dumps(res, ensure_ascii=False) if as_json else slot_text(res))
            return 0
    except ShareError as exc:
        print(f"fm-share: {exc}", file=sys.stderr)
        return 2
    print("fm-share: usage: fm-share.sh add <path> [--label <text>] | list | revoke <token> | serve"
          " | share-slot <pilot-slot> --to <account> (see --help)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
