#!/usr/bin/env python3
"""fm_share.py - explicit share links: publish a snapshot of one artifact under an unguessable token, list the
live shares, revoke one, and serve only the shared files.

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
import sys
import time
import urllib.parse

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
    except ShareError as exc:
        print(f"fm-share: {exc}", file=sys.stderr)
        return 2
    print("fm-share: usage: fm-share.sh add <path> [--label <text>] | list | revoke <token> | serve (see --help)",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
