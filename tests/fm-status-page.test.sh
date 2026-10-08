#!/usr/bin/env bash
# tests/fm-status-page.test.sh - isolated page and inbox decision behavior.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-page)
FM_STATUS_TEST_ROOT="$ROOT" FM_STATUS_TEST_HOME="$TMP_ROOT/home" python3 - <<'PY'
import json, os, pathlib, re, socket, subprocess, time, urllib.error, urllib.parse, urllib.request
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
    def form_token(markup):
        return re.search(r'name="token" value="([^"]+)"', markup).group(1)
    token = form_token(page)
    for _ in range(4):
        render()
    fresh_token = form_token((home / 'state/status-page-public/index.html').read_text())
    assert fresh_token != token
    data = urllib.parse.urlencode({'card':card, 'option':'0', 'detail':'', 'token':token}).encode()
    headers = {'Host':'demo.tail.ts.net', 'Origin':'https://demo.tail.ts.net',
               'Sec-Fetch-Site':'same-origin', 'Tailscale-User-Login':'captain@example.com'}
    def submit(body=data, overrides=None):
        request_headers = {key:value for key,value in {**headers, **(overrides or {})}.items() if value is not None}
        return urllib.request.urlopen(urllib.request.Request(url + 'decision', data=body,
                                      headers=request_headers), timeout=10)
    for overrides in ({'Tailscale-User-Login':None}, {'Tailscale-User-Login':'someone@example.com'},
                      {'Origin':'https://attacker.example'}, {'Sec-Fetch-Site':'cross-site'}):
        with submit(overrides=overrides) as response:
            assert response.url.endswith('/?notice=forbidden')
            assert 'Decision requests require the owner' in response.read().decode()
    stale = urllib.parse.urlencode({'card':card, 'option':'0', 'detail':'', 'token':'old-token'}).encode()
    with submit(body=stale) as response:
        assert response.url.endswith('/?notice=stale')
        assert 'Page changed; reload before answering' in response.read().decode()
    assert not (home / 'state/inbox').exists()
    with urllib.request.urlopen(url, timeout=10) as response:
        assert 'name="option" value="0"' in response.read().decode()
    with submit() as response:
        assert response.url.endswith('/')
        assert re.search(r'recorded: A: fake red at \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC', response.read().decode())
    notes = list((home / 'state/inbox').glob('*.note'))
    assert len(notes) == 1 and 'decision fm-status-page-decisions-demo A: fake red:' in notes[0].read_text()
    assert (home / 'state/.wake-queue').read_text().count('\tcheck\tinbox:') == 1
    with submit() as response:
        assert response.url.endswith('/?notice=stale')
        assert 'recorded: A: fake red at ' in response.read().decode()
    duplicate = urllib.parse.urlencode({'card':card, 'option':'0', 'detail':'', 'token':fresh_token}).encode()
    with submit(body=duplicate) as response:
        assert response.url.endswith('/?notice=unavailable')
        assert 'already recorded' in response.read().decode()
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
    second_page = (home / 'state/status-page-public/index.html').read_text()
    second_data = urllib.parse.urlencode({'card':second_card, 'option':'1', 'detail':'',
                                          'token':form_token(second_page)}).encode()
    for _ in range(20):
        render()
    with submit(body=second_data) as response:
        assert response.url.endswith('/?notice=stale')
        markup = response.read().decode()
        assert 'Page changed; reload before answering' in markup
        assert 'name="option" value="1"' in markup
    latest = (home / 'state/status-page-public/index.html').read_text()
    second_data = urllib.parse.urlencode({'card':second_card, 'option':'1', 'detail':'',
                                          'token':form_token(latest)}).encode()
    invalid = urllib.parse.urlencode({'card':second_card, 'option':'9', 'detail':'',
                                      'token':form_token(latest)}).encode()
    with submit(body=invalid) as response:
        assert response.url.endswith('/?notice=invalid')
        assert 'Invalid decision' in response.read().decode()
    with submit(body=second_data) as response:
        assert 'recorded: B: fake blue at ' in response.read().decode()
    assert len(list((home / 'state/inbox').glob('*.note'))) == 2
    assert (home / 'state/.wake-queue').read_text().count('\tcheck\tinbox:') == 2
finally:
    server.terminate()
    server.wait(timeout=5)
print('PASS: owner and origin checks; stale-tab window, redirect banner, recorded receipt, replay and reopened-call capture')
PY
