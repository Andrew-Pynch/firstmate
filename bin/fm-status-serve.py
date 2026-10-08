#!/usr/bin/env python3
"""Loopback-only status page and captain-note capture; publish via tailnet serve."""
import fcntl
import importlib.util
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import subprocess
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME', ROOT))
PRIVATE = HOME / 'state/.status-page'
PUBLIC = HOME / 'state/status-page-public'
spec = importlib.util.spec_from_file_location('status_page', ROOT / 'bin/fm-status-page.py')
page = importlib.util.module_from_spec(spec)
spec.loader.exec_module(page)


class Handler(BaseHTTPRequestHandler):
    def send(self, code, data, kind='text/plain; charset=utf-8'):
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, notice=None):
        self.send_response(303)
        self.send_header('Location', './' + (f'?notice={notice}' if notice else ''))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()

    def do_GET(self):
        request = urlsplit(self.path)
        if request.path not in ('/', '/index.html'):
            return self.send(404, b'Not found')
        try:
            content = (PUBLIC / 'index.html').read_bytes()
            notice = parse_qs(request.query).get('notice', [None])[0]
            messages = {'stale': 'Page changed; reload before answering.',
                        'unavailable': 'Decision unavailable or already recorded.',
                        'invalid': 'Invalid decision. Check the form and try again.',
                        'forbidden': 'Decision requests require the owner on this tailnet site.'}
            if notice in messages:
                banner = f'<p role="alert" class="notice">{messages[notice]}</p>'.encode()
                content = content.replace(b'<body>', b'<body>' + banner, 1)
            self.send(200, content, 'text/html; charset=utf-8')
        except OSError:
            self.send(503, b'Page not published')

    def do_POST(self):
        if urlsplit(self.path).path != '/decision':
            return self.redirect('invalid')
        owner_file = HOME / 'config/status-page-owner'
        owner = owner_file.read_text().strip() if owner_file.is_file() else ''
        identity = self.headers.get_all('Tailscale-User-Login') or []
        hosts = self.headers.get_all('Host') or []
        origins = self.headers.get_all('Origin') or []
        host = hosts[0] if len(hosts) == 1 else ''
        if (not owner or len(identity) != 1 or identity[0] != owner or
                not host.endswith('.ts.net') or '/' in host or ':' in host or
                len(origins) != 1 or origins[0] != 'https://' + host or
                self.headers.get('Sec-Fetch-Site') != 'same-origin'):
            return self.redirect('forbidden')
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if length < 1 or length > 4096 or self.headers.get('Content-Type', '').split(';')[0] != 'application/x-www-form-urlencoded':
                return self.redirect('invalid')
            values = parse_qs(self.rfile.read(length).decode('utf-8'), strict_parsing=True, keep_blank_values=True)
            card, choice, detail, token = (values[name][0] for name in ('card', 'option', 'detail', 'token'))
            if len(detail) > 1500 or '\n' in detail or '\r' in detail:
                return self.redirect('invalid')
            with (PRIVATE / 'render.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                if not token or token not in page.valid_tokens():
                    return self.redirect('stale')
                # Refresh before validating the form. A closed call cannot receive an answer.
                page.render(lock_held=True)
                cards = json.loads((PRIVATE / 'cards.json').read_text())
                receipt_file = PRIVATE / 'recorded.json'
                receipts = json.loads(receipt_file.read_text()) if receipt_file.exists() else {}
                if card not in cards or card in receipts:
                    return self.redirect('unavailable')
                entry = cards[card]
                index = int(choice)
                if index < 0 or index >= len(entry['options']):
                    return self.redirect('invalid')
                body = f"decision {entry['task']}" + (f" [key={entry['key']}]" if entry['key'] else '')
                body += f" {entry['options'][index]}: {detail}".rstrip()
                result = subprocess.run([str(ROOT / 'bin/fm-inbox.sh'), 'note', '--request-id', entry['request_id'], '--json', '--', body],
                                        env={**os.environ, 'FM_HOME': str(HOME)}, capture_output=True, timeout=15)
                if result.returncode not in (0, 3):
                    return self.send(503, b'Could not save answer')
                receipt = json.loads(result.stdout)
                if not receipt['saved'] or not receipt['announced']:
                    # An idempotent retry repairs a saved note whose wake failed.
                    subprocess.run([str(ROOT / 'bin/fm-inbox.sh'), 'announce', receipt['id']],
                                   env={**os.environ, 'FM_HOME': str(HOME)}, capture_output=True, timeout=15, check=True)
                receipts[card] = {'id': receipt['id'], 'option': entry['options'][index],
                                  'at': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}
                page.atomic(receipt_file, json.dumps(receipts))
                page.atomic(PRIVATE / 'tokens.json', json.dumps([value for value in page.valid_tokens() if value != token]))
                page.render(lock_held=True)
            self.redirect()
        except (ValueError, KeyError, IndexError, UnicodeError):
            self.redirect('invalid')
        except (OSError, subprocess.SubprocessError):
            self.send(503, b'Decision service unavailable')


if __name__ == '__main__':
    config = HOME / 'config/status-page-port'
    port = int(config.read_text().strip()) if config.exists() else 8795
    if port < 1024 or port > 65535:
        raise SystemExit('status-page-port must be 1024..65535')
    HTTPServer(('127.0.0.1', port), Handler).serve_forever()
