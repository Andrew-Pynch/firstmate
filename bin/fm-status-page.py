#!/usr/bin/env python3
"""Render one public HTML page from the canonical bearings projection and fleet ledger.

Private cursor/answer receipts stay outside the served directory. Publication uses a
home-local flock, then atomic replacements; a failed collection leaves the last page.
"""
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import secrets
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME', ROOT))
STATE = HOME / 'state'
PRIVATE = STATE / '.status-page'
PUBLIC = STATE / 'status-page-public'
H = lambda value: html.escape(str(value or ''), quote=True)


def atomic(path, text):
    fd, name = tempfile.mkstemp(prefix='.page-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def age(value, now):
    if isinstance(value, str):
        if len(value) == 10:
            return 'since ' + value
        try:
            value = int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
        except ValueError:
            return 'time not recorded'
    if not isinstance(value, int) or value > now or value < 0:
        return 'time not recorded'
    seconds = now - value
    if seconds < 3600:
        return f'{seconds // 60}m ago'
    if seconds < 86400:
        return f'{seconds // 3600}h ago'
    return f'{seconds // 86400}d ago'


def options(text):
    # Only explicit enumerations qualify; never guess an action from free prose.
    tail = re.search(r'\bOptions\s*:\s*(.*)', text, re.I | re.S)
    source = tail.group(1) if tail else text
    found = re.findall(r'(?:^|[;\n]\s*|\s{2,})\s*(?:\(([a-z])\)|([A-Z]):?)\s+(.+?)(?=\s*;\s*(?:\([a-z]\)|[A-Z]:?\s)|\n\s*(?:\([a-z]\)|[A-Z]:?\s)|$)', source, re.S)
    labels = []
    for a, b, body in found:
        label = re.split(r'\.\s+(?=[A-Z][a-z]+ )', body.strip(), maxsplit=1)[0]
        if label:
            labels.append(f'{a or b}: {label}')
    return labels[:8] if len(labels) >= 2 else ['yes', 'no', 'later']


def link(url):
    return f' <a href="{H(url)}" rel="noreferrer">{H(url)}</a>' if isinstance(url, str) and url.startswith('https://') else ''


def article(title, meta, body, extra='', kind=''):
    return f'<article class="{kind}"><h3>{H(title)}</h3><p class="meta">{H(meta)}</p><div class="text">{H(body)}</div>{extra}</article>'


def snapshot():
    fixture = os.environ.get('FM_STATUS_SNAPSHOT')
    if fixture:
        return json.loads(Path(fixture).read_text())
    result = subprocess.run([str(ROOT / 'bin/fm-bearings-snapshot.sh'), '--json', '--fields', 'page',
                             '--all-in-flight', '--all-decisions', '--all-queued', '--all-landed',
                             '--all-recorded-prs'], env={**os.environ, 'FM_HOME': str(HOME), 'FM_BEARINGS_AWAY_OK': '1'},
                            capture_output=True, check=True, timeout=90)
    return json.loads(result.stdout)


def ledger_delta(previous):
    path = STATE / 'fleet-ledger.jsonl'
    if not path.is_file():
        return [], {'inode': None, 'offset': 0}
    with path.open('rb') as stream:
        stat = os.fstat(stream.fileno())
        same = previous.get('inode') == stat.st_ino and previous.get('offset', 0) <= stat.st_size
        offset = previous.get('offset', 0) if same else stat.st_size
        stream.seek(offset)
        data = stream.read()
        complete = data.rfind(b'\n') + 1
        events = []
        for raw in data[:complete].splitlines():
            try:
                event = json.loads(raw)
                if event.get('v') == 1 and event.get('event') in ('task.status', 'task.merged', 'task.dispatched'):
                    events.append(event)
            except (ValueError, UnicodeError):
                continue
        return events, {'inode': stat.st_ino, 'offset': offset + complete}


def render():
    PRIVATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    PUBLIC.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (PRIVATE / 'render.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if os.environ.get('FM_STATUS_BEST_EFFORT') else 0))
        old_path = PRIVATE / 'cursor.json'
        old = json.loads(old_path.read_text()) if old_path.exists() else {}
        snap = snapshot()
        if snap.get('schema') != 'fm-bearings.v1' or not isinstance(snap.get('page_rows'), list):
            raise ValueError('bearings page projection missing')
        now = int(time.time())
        receipt_path = PRIVATE / 'recorded.json'
        recorded = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
        rows = {row['id']: row for row in snap['page_rows'] if row.get('id')}
        tasks = {row['id']: row for row in snap.get('page_tasks', []) if row.get('id')}
        events, cursor = ledger_delta(old)
        previous_ids = set(old.get('ids', []))
        previous_calls = set(old.get('calls', []))
        cards, extra, calls = [], [], set()
        manifest = {}
        token = secrets.token_urlsafe(32)
        def add_card(task, key, title, text, stamp, deferred=False, preview=None, source=''):
            identity = task + '\0' + key
            calls.add(identity)
            ask = text or title
            digest = hashlib.sha256(identity.encode() + b'\0' + ask.encode() + b'\0' + str(stamp).encode()).hexdigest()
            card_id = digest[:32]
            labels = options(ask)
            manifest[card_id] = {'task': task, 'key': key, 'ask': ask, 'options': labels,
                                 'request_id': 'status-page-' + digest}
            if recorded.get(card_id):
                action = '<p class="saved">recorded, waiting for Main</p>'
            else:
                buttons = ''.join(f'<button name="option" value="{i}">{H(label)}</button>' for i, label in enumerate(labels))
                action = f'<form method="post" action="decision"><input type="hidden" name="card" value="{card_id}">' \
                         f'<input type="hidden" name="token" value="{token}">{buttons}<label>More detail <input name="detail" maxlength="1500"></label></form>'
            disclosure = f'<details><summary>Full source row</summary><div class=\"text\">{H(source)}</div></details>' if source else ''
            content = article(title, f'{task} · {key} · {age(stamp, now)}', preview if preview is not None else ask, action + disclosure, 'ask')
            if deferred:
                extra.append(content)
            else:
                priority = int(datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp()) if isinstance(stamp, str) and 'T' in stamp else (stamp if isinstance(stamp, int) else 0)
                cards.append((priority, content))
        for row in rows.values():
            if row.get('hold_kind') != 'captain' or row.get('state') == 'done':
                continue
            text = row.get('hold_reason') or ''
            body = '\n'.join(row.get('body_lines') or [])
            ask = text + ('\n\n' + body if body else '')
            add_card(row['id'], '', row.get('title') or row['id'], ask,
                     row.get('hold_set') or row.get('since'), row.get('hold_bucket') != 'live',
                     preview=text, source=body)
        for task in tasks.values():
            for decision in task.get('open_decisions') or []:
                if decision.get('verb') != 'needs-decision':
                    continue
                key = decision.get('key') or ''
                stamp = None
                path = STATE / (task['id'] + '.status')
                if path.is_file() and not path.is_symlink():
                    for line in path.read_text(errors='replace').splitlines():
                        if line.startswith('needs-decision ') and f'[key={key}]' in line and line.split(':', 1)[-1].strip() == decision.get('summary', '').strip():
                            matches = re.findall(r'\[at=(\d{1,12})\]', line.split(':', 1)[0])
                            stamp = int(matches[0]) if len(matches) == 1 else None
                add_card(task['id'], key, task['id'], decision.get('summary') or '', stamp)
        local_ids = set(tasks) | set(rows)
        for decision in snap.get('page_remote_calls', []):
            task, key = decision.get('id', ''), decision.get('key') or ''
            if not task or task + '\0' + key in calls:
                continue
            if decision.get('verb') == 'captain-hold' and decision.get('hold_bucket') != 'live':
                deferred = True
            else:
                deferred = False
            text = decision.get('summary') or ''
            if text.endswith('…'):
                text += '\nSource summary is clipped; confirm the full ask with Main before answering.'
            add_card(task, key, task, text, None, deferred)
        for decision in snap.get('decisions_open', []):
            task, key = decision.get('id', ''), decision.get('key') or ''
            if not task or task in local_ids or task + '\0' + key in calls:
                continue
            if decision.get('verb') in ('needs-decision', 'captain-hold'):
                add_card(task, key, task, decision.get('summary') or '', None,
                         decision.get('verb') == 'captain-hold')
        flight = []
        prs = {row['id']: row['url'] for row in snap.get('recorded_prs', [])}
        for row in snap.get('in_flight', []):
            task = tasks.get(row['id'], {})
            event = task.get('last_event') or {}
            seconds = event.get('age_seconds')
            stamp = now - seconds if isinstance(seconds, int) and seconds >= 0 else None
            flight.append(article(row.get('name') or row['id'], f"{row['id']} · {row.get('state', 'unknown')} · last report {age(stamp, now)}",
                                  event.get('raw') or row.get('doing') or 'No status report', link(task.get('pr') or prs.get(row['id']))))
        landed = []
        fresh_done = {rid for rid, row in rows.items() if row.get('state') == 'done'} - set(old.get('done', [])) if old else set()
        merged = {event['task']: event for event in events if event['event'] == 'task.merged'}
        for rid in sorted(fresh_done | set(merged)):
            row, event = rows.get(rid, {}), merged.get(rid, {})
            url = event.get('pr') or row.get('pr_url')
            landed.append(article(row.get('title') or rid, rid + ' · ' + ((row.get('completion') or {}).get('date') or 'newly recorded'),
                                  (row.get('completion') or {}).get('verb') or event.get('via') or 'Done', link(url)))
        waiting = []
        for row in rows.values():
            if row.get('hold_kind') == 'external' and row.get('state') != 'done':
                waiting.append(article(row.get('title') or row['id'], row['id'], row.get('hold_reason') or 'External wait'))
        for gate in snap.get('gates', []):
            if gate.get('owner') != '(main)' and gate.get('reason') not in ('main inventory', 'away-return catch-up'):
                waiting.append(article(gate.get('title') or gate['id'], gate.get('owner') or 'external', gate.get('reason') or 'Waiting'))
        dropped = []
        if old:
            for rid in sorted(set(rows) - previous_ids):
                dropped.append(article(rows[rid].get('title') or rid, rid, 'New queue row'))
            for identity in sorted(calls - previous_calls):
                dropped.append(article(identity.split('\0')[0], 'new open decision', 'Decision recorded since last render'))
            for event in events[-20:]:
                if event['event'] == 'task.status':
                    dropped.append(article(event['task'], 'status · ' + age(event.get('ts'), now), event.get('text') or ''))
        recent = (old.get('recent', []) + [e for e in events if e['event'] == 'task.status'])[-12:]
        history = ''.join(article(e.get('task', 'unknown'), 'recent · ' + age(e.get('ts'), now), e.get('text') or '') for e in reversed(recent))
        def section(name, items, empty='Nothing recorded', count=None):
            return f'<section><h2>{name} <small>{len(items) if count is None else count}</small></h2>' + (''.join(items) or f'<p class="meta">{empty}</p>') + '</section>'
        cards.sort(key=lambda item: item[0], reverse=True)
        visible = [item[1] for item in cards[:8]]
        if len(cards) > 8:
            visible.append(f'<details><summary>All {len(cards) - 8} other open asks</summary>' + ''.join(item[1] for item in cards[8:]) + '</details>')
        page = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="90"><title>Firstmate status</title><style>
body{font:15px/1.5 system-ui,sans-serif;background:#10141a;color:#eee;max-width:1050px;margin:24px auto;padding:0 16px}h1{font-size:26px}h2{border-bottom:1px solid #404a54;padding-bottom:6px;margin-top:26px}h3{font-size:16px;margin:0}small,.meta{color:#abb8c8;font-size:13px}article{background:#1c2630;border:1px solid #394757;border-radius:8px;padding:12px;margin:10px 0}article.ask{border-left:4px solid #e7bb64}.text{white-space:pre-wrap;overflow-wrap:anywhere;margin:8px 0}a{color:#a9caff;overflow-wrap:anywhere}form{display:flex;flex-wrap:wrap;gap:9px;margin-top:12px}button,input{font:inherit;border-radius:6px;padding:8px;background:#293647;color:#fff;border:1px solid #718198}button{cursor:pointer}button:hover{background:#435872}label{display:flex;gap:6px;align-items:center;flex-wrap:wrap}.saved{color:#9ee0a4}details{margin:12px 0}summary{cursor:pointer;color:#a9caff}@media(max-width:600px){body{margin:10px auto}button{width:100%;text-align:left}form,label,input{width:100%;box-sizing:border-box}}
</style></head><body>'''
        page += f'<h1>Where things are</h1><p class="meta">Updated {H(datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds"))} · source {H(snap.get("generated"))}</p>'
        page += section('needs you', visible, count=len(cards)) + section('in flight', flight) + section('landed since last render', landed)
        page += section('waiting on others', waiting) + section('dropped in', dropped, 'Baseline established' if not old else 'No new rows or reports')
        page += '<details><summary>everything else (' + str(len(extra)) + ' parked or deferred)</summary>' + ''.join(extra) + '</details>'
        page += '<details><summary>recent status history</summary>' + history + '</details></body></html>'
        # Publish the private form authority before HTML. A concurrent refresh
        # may invalidate an old form; it must never accept a newer unbound one.
        atomic(PRIVATE / 'cards.json', json.dumps(manifest))
        atomic(PRIVATE / 'token', token)
        atomic(PUBLIC / 'index.html', page)
        atomic(PRIVATE / 'cursor.json', json.dumps({'ids': sorted(rows), 'done': sorted(rid for rid, row in rows.items() if row.get('state') == 'done'),
                                                     'calls': sorted(calls), 'recent': recent, **cursor}))
        atomic(PRIVATE / 'recorded.json', json.dumps({key: value for key, value in recorded.items() if key in manifest}))
        return len(cards)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--detach']:
            PRIVATE.mkdir(mode=0o700, parents=True, exist_ok=True)
            error = PRIVATE / 'refresh-error.log'
            with error.open('w') as log:
                error.chmod(0o600)
                subprocess.Popen([sys.executable, __file__], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
                                 env={**os.environ, 'FM_STATUS_BEST_EFFORT': '1'})
        else:
            print(f'rendered {render()} active decisions')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'fm-status-page: {error}', file=sys.stderr)
        sys.exit(1)
