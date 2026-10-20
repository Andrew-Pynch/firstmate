#!/usr/bin/env python3
"""Stateful protocol fixture for the project-label spawn regression, never a server."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if '--session' in args:
    i = args.index('--session')
    del args[i:i + 2]
path = Path(os.environ['FM_LABEL_STUB_STATE'])
state = json.loads(path.read_text())
state['calls'].append(args)

def value(flag):
    return args[args.index(flag) + 1]

def publish(result):
    path.write_text(json.dumps(state))
    print(json.dumps({'result': result}))
    sys.exit(0)

if args[0] == 'status':
    path.write_text(json.dumps(state))
    print(json.dumps({'client': {'protocol': 16, 'version': '0.8.0'},
                      'server': {'running': True, 'compatible': True, 'protocol': 16,
                                 'version': '0.8.0'}}))
    sys.exit(0)
if args[:2] == ['session', 'list']:
    path.write_text(json.dumps(state))
    print(json.dumps({'sessions': [{'name': 'label-fixture', 'running': True,
                                   'socket_path': str(path.parent / 'fixture.sock')}]}))
    sys.exit(0)
if args[:2] == ['workspace', 'list']:
    publish({'workspaces': state['workspaces']})
if args[:2] == ['workspace', 'create']:
    workspace = {'workspace_id': 'w2', 'label': value('--label'), 'focused': False,
                 'active_tab_id': 'w2:t0'}
    tab = {'workspace_id': 'w2', 'tab_id': 'w2:t0', 'label': '1', 'focused': False}
    pane = {'workspace_id': 'w2', 'tab_id': 'w2:t0', 'pane_id': 'w2:p0'}
    state['workspaces'].append(workspace)
    state['tabs'].append(tab)
    state['panes'].append(pane)
    publish({'workspace': workspace, 'tab': tab, 'root_pane': pane})
if args[:2] == ['tab', 'create']:
    workspace = value('--workspace')
    tab = {'workspace_id': workspace, 'tab_id': workspace + ':t1',
           'label': value('--label'), 'focused': False}
    pane = {'workspace_id': workspace, 'tab_id': tab['tab_id'],
            'pane_id': workspace + ':p1', 'foreground_cwd': os.environ['FM_LABEL_STUB_WT']}
    state['tabs'].append(tab)
    state['panes'].append(pane)
    publish({'tab': tab, 'root_pane': pane})
if args[:2] in (['tab', 'list'], ['pane', 'list']):
    kind = args[0] + 's'
    rows = state[kind]
    if '--workspace' in args:
        rows = [r for r in rows if r['workspace_id'] == value('--workspace')]
    publish({kind: rows})
if args[:2] in (['workspace', 'get'], ['tab', 'get'], ['pane', 'get']):
    kind = args[0]
    rows = [r for r in state[kind + 's'] if r[kind + '_id'] == args[2]]
    if rows:
        publish({kind: rows[0]})
    path.write_text(json.dumps(state))
    print(json.dumps({'error': {'code': kind + '_not_found'}}))
    sys.exit(1)
if args[:2] in (['workspace', 'report-metadata'], ['pane', 'report-metadata']):
    kind = args[0]
    row = next(r for r in state[kind + 's'] if r[kind + '_id'] == args[2])
    key, val = value('--token').split('=', 1)
    row.setdefault('tokens', {})[key] = val
    publish({kind: row})
if args[:2] == ['pane', 'close']:
    pane = next(r for r in state['panes'] if r['pane_id'] == args[2])
    state['panes'].remove(pane)
    state['tabs'] = [r for r in state['tabs'] if r['tab_id'] != pane['tab_id']]
    publish({})
if args[:2] == ['terminal', 'title']:
    publish({'reason': 'no_foreground_client'})
if args[:2] in (['pane', 'run'], ['pane', 'send-text'], ['pane', 'send-keys']):
    publish({})
path.write_text(json.dumps(state))
print(json.dumps({'error': {'code': 'agent_not_found' if args[0] == 'agent' else 'unsupported_fixture_command'}}))
sys.exit(1)
