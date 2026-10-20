#!/usr/bin/env bash
# tests/fm-status-page.test.sh - isolated page and inbox decision behavior.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-page)
FM_STATUS_TEST_ROOT="$ROOT" FM_STATUS_TEST_HOME="$TMP_ROOT/home" python3 - <<'PY'
import json, os, pathlib, socket, subprocess, time, urllib.error, urllib.parse, urllib.request
root = pathlib.Path(os.environ['FM_STATUS_TEST_ROOT'])
home = pathlib.Path(os.environ['FM_STATUS_TEST_HOME'])
for name in ('state', 'data', 'config'):
    (home / name).mkdir(parents=True)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
(home / 'config/status-page-port').write_text(str(port))
(home / 'config/status-page-owner').write_text('captain@example.com\n')
fixture = home / 'snapshot.json'
record = {'id':'fm-status-page-decisions-demo', 'state':'queued', 'title':'Synthetic choice',
          'hold_kind':'captain', 'hold_bucket':'live', 'hold_reason':'Options: A: fake red; B: fake blue',
          'body_lines':[], 'hold_set':'2026-09-30T04:00:00Z'}
snap = {'schema':'fm-bearings.v1', 'generated':'2026-09-30T04:00:00Z',
        'page_rows':[record, {'id':'outside', 'state':'queued', 'title':'Wait for TJ',
                               'hold_kind':'external', 'hold_reason':'TJ checks the model'},
                     {'id':'merged-demo', 'state':'in_flight', 'title':'Merged synthetic branch',
                      'completion':{'verb':None, 'date':None}}],
        'page_tasks':[], 'in_flight':[], 'decisions_open':[], 'gates':[], 'recorded_prs':[]}
def save(): fixture.write_text(json.dumps(snap))
save()
(home / 'state/fleet-ledger.jsonl').write_text('')
env = dict(os.environ, FM_HOME=str(home), FM_STATUS_SNAPSHOT=str(fixture))
def render():
    result = subprocess.run([root / 'bin/fm-status-page.sh'], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
render()
merge_event = {'v':1, 'ts':1790742000, 'event':'task.merged', 'task':'merged-demo',
               'via':'pr', 'pr':'https://github.com/example/repo/pull/1'}
with (home / 'state/fleet-ledger.jsonl').open('a') as ledger:
    ledger.write(json.dumps(merge_event) + '\n')
render()
merged_page = (home / 'state/status-page-public/index.html').read_text()
assert 'landed since last render <small>1</small>' in merged_page
assert 'https://github.com/example/repo/pull/1' in merged_page
render()
assert 'landed since last render <small>0</small>' in (home / 'state/status-page-public/index.html').read_text()
url = f'http://127.0.0.1:{port}/'
server = subprocess.Popen([root / 'bin/fm-status-serve.sh'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(60):
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                page = response.read().decode()
            break
        except (OSError, urllib.error.URLError):
            time.sleep(.1)
    else: raise AssertionError('server not listening')
    assert 'needs you <small>1</small>' in page and 'waiting on others <small>1</small>' in page
    assert 'fake red' in page and 'TJ checks the model' in page
    cards = json.loads((home / 'state/.status-page/cards.json').read_text())
    card, entry = next(iter(cards.items()))
    assert entry['options'] == ['A: fake red', 'B: fake blue']
    token = (home / 'state/.status-page/token').read_text()
    data = urllib.parse.urlencode({'card':card, 'option':'0', 'detail':'', 'token':token}).encode()
    headers = {'Host':'demo.tail.ts.net', 'Origin':'https://demo.tail.ts.net',
               'Sec-Fetch-Site':'same-origin', 'Tailscale-User-Login':'captain@example.com'}
    def submit(body=data, overrides=None):
        request_headers = {key:value for key,value in {**headers, **(overrides or {})}.items() if value is not None}
        return urllib.request.urlopen(urllib.request.Request(url + 'decision', data=body,
                                      headers=request_headers), timeout=10)
    for overrides in ({'Tailscale-User-Login':None}, {'Tailscale-User-Login':'someone@example.com'},
                      {'Origin':'https://attacker.example'}, {'Sec-Fetch-Site':'cross-site'}):
        try:
            submit(overrides=overrides)
            raise AssertionError('unauthorized decision accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 403
    stale = urllib.parse.urlencode({'card':card, 'option':'0', 'detail':'', 'token':'old-token'}).encode()
    try:
        submit(body=stale)
        raise AssertionError('stale token accepted')
    except urllib.error.HTTPError as error:
        assert error.code == 409
    assert not (home / 'state/inbox').exists()
    with submit() as response:
        assert 'recorded, waiting for Main' in response.read().decode()
    notes = list((home / 'state/inbox').glob('*.note'))
    assert len(notes) == 1 and 'decision fm-status-page-decisions-demo A: fake red:' in notes[0].read_text()
    assert (home / 'state/.wake-queue').read_text().count('\tcheck\tinbox:') == 1
    try:
        submit()
        raise AssertionError('duplicate accepted')
    except urllib.error.HTTPError as error:
        assert error.code == 409
    assert len(list((home / 'state/inbox').glob('*.note'))) == 1
    assert (home / 'state/.wake-queue').read_text().count('\tcheck\tinbox:') == 1
    snap['page_rows'] = [snap['page_rows'][1]]
    save()
    render()
    assert not json.loads((home / 'state/.status-page/cards.json').read_text())
    record['hold_set'] = '2026-09-30T04:01:00Z'
    snap['page_rows'] = [record, snap['page_rows'][0]]
    save()
    render()
    reopened = json.loads((home / 'state/.status-page/cards.json').read_text())
    second_card = next(iter(reopened))
    assert second_card != card
    second_data = urllib.parse.urlencode({'card':second_card, 'option':'1', 'detail':'',
                                          'token':(home / 'state/.status-page/token').read_text()}).encode()
    with submit(body=second_data) as response:
        assert 'recorded, waiting for Main' in response.read().decode()
    assert len(list((home / 'state/inbox').glob('*.note'))) == 2
    assert (home / 'state/.wake-queue').read_text().count('\tcheck\tinbox:') == 2
finally:
    server.terminate()
    server.wait(timeout=5)
print('PASS: owner, origin, token rejection; replay refusal and reopened-call capture')
PY
