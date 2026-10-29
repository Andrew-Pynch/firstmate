import os,pathlib,subprocess,json,shlex,time,re,threading
R=pathlib.Path.cwd(); B=R/'.test-current/remote'; B.mkdir(parents=True,exist_ok=True)
P=B/'parent'; H=B/'host'; F=B/'bin'; F.mkdir(exist_ok=True)
for h in (P,H):
    for d in ('data','state','config','bin'): (h/d).mkdir(parents=True,exist_ok=True)
def put(p,s): p.write_text(s); return p
put(H/'AGENTS.md','# Isolated route fixture\n')
put(H/'.fm-secondmate-home','mate\n')
put(H/'.fm-secondmate-parent',f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={P}\n')
put(P/'config/secondmate-harness','claude\n')
put(P/'data/secondmates.md',f'- mate - isolated transport fixture (host: local-fixture; root: {R}; home: {H}; scope: fixture; projects: none; added 2026-10-29)\n')
old=B/'old-root'; new=B/'confirmed-root'; requested=B/'unconfirmed-request'
for d in (old,new,requested): d.mkdir(exist_ok=True)
hostmeta=H/'state/parent-route/mate.meta'; hostmeta.parent.mkdir(exist_ok=True)
put(hostmeta,f'window=fm-remote:w1:p1\nbackend=herdr\nherdr_session=fm-remote\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nendpoint_task_id=mate\nworktree={H}\nproject={R}\nkind=secondmate\nharness=claude\nmodel=\neffort=\ncode_root={new}\n')
put(P/'state/mate.meta',f'window=remote:mate\nendpoint_task_id=mate\nworktree={H}\nproject={R}\nkind=secondmate\nharness=claude\nmode=secondmate\nyolo=off\nhome={H}\ncode_root={old}\nremote_host=local-fixture\nremote_backend=herdr\nremote_target=fm-remote:w1:p1\n')
e=os.environ.copy()
for k in list(e):
    if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k in ('TMUX','TMUX_PANE'): e.pop(k,None)
e.update(HOME=str(B),TMPDIR=str(R/'.test-current/tmp'),FM_HOME=str(P),FM_ROOT_OVERRIDE=str(R),FM_GATE_REFUSE_BYPASS='1',FM_TEST_SEAM='1',FM_SECONDMATE_PERSIST_WAIT='20',FM_SECONDMATE_PERSIST_POLL='1',PATH=str(F)+':'+e['PATH'])
# Deliberately disconnected terminal edge: the durable send still runs; no real
# Herdr server is contacted. No terminal lifecycle is required by this proof.
herdr=put(F/'herdr','#!/bin/sh\nexit 1\n'); herdr.chmod(0o755)
transport=put(F/'local-transport', '''#!/usr/bin/env python3
import sys,base64,os,subprocess,pathlib,json
a=sys.argv[1:]
while a[0]=='-o': a=a[2:]
assert a[0:3]==['--','local-fixture','fm-remote-entrypoint.sh'],a
assert a[3]=='1'
root=base64.b64decode(a[4]).decode(); home=base64.b64decode(a[5]).decode()
args=base64.b64decode(a[6]).decode().rstrip('\\0').split('\\0')
b=pathlib.Path(__file__).parents[1]
with (b/'requests.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
env=os.environ.copy()
for k in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE'): env.pop(k,None)
env['FM_HOME']=home
assert args[0]=='fm-remote-secondmate-control.sh'
if args[1]=='relaunch':
    n=sum(json.loads(x)[1]=='relaunch' for x in (b/'requests.jsonl').read_text().splitlines())
    if n>1:
        print('fixture boundary: next restart request captured; replacement deliberately not executed',file=sys.stderr)
        sys.exit(42)
    # The endpoint has already confirmed its new root. Execute the production
    # route serializer rather than constructing a reply from request arguments.
    args=[args[0],'route',args[2]]
os.execve(root+'/bin/'+args[0],[root+'/bin/'+args[0]]+args[1:],env)
'''); transport.chmod(0o755)
e['FM_SSH_BIN']=str(transport)
def run(a,env=e):
    p=subprocess.run([str(x) for x in a],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if p.returncode: raise RuntimeError(p.stdout)
    return p.stdout
out=run([R/'bin/fm-remote-secondmate-relaunch.sh','mate','claude','default','default','--code-root',requested])
print(out,flush=True)
meta=dict(x.split('=',1) for x in (P/'state/mate.meta').read_text().splitlines() if '=' in x)
assert meta['code_root']==str(new) and meta['code_root']!=str(requested),meta
print('PASS: parent recorded production host route confirmation, not requested or old root',flush=True)
stop=threading.Event(); errors=[]
def worker():
    try:
        inbox=H/'state/parent-route/mate.inbox'
        while not stop.wait(.05):
            for path in inbox.glob('*.msg'):
                body=path.read_text(); corr=re.search(r'corr=([0-9a-f]{16})',body)
                if not corr: continue
                put(H/'data/persisted-request.txt',body)
                he=e.copy();he['FM_HOME']=str(H)
                run([R/'bin/fm-secondmate-report.sh','done',corr[1],'isolated fixture request durably recorded'],he)
                done=inbox/'handled';done.mkdir(exist_ok=True);path.rename(done/path.name)
    except Exception as ex: errors.append(str(ex))
t=threading.Thread(target=worker);t.start()
try:
    p=subprocess.run([str(R/'bin/fm-secondmate-restart.sh'),'mate'],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    print(p.stdout,flush=True)
finally:
    stop.set();t.join()
assert not errors,errors
requests=[json.loads(x) for x in (B/'requests.jsonl').read_text().splitlines()]
relaunch=[x for x in requests if x[1]=='relaunch']
assert len(relaunch)==2,requests
assert relaunch[-1][-2:]==['--code-root',str(new)],relaunch
assert (H/'data/persisted-request.txt').exists()
assert p.returncode==3 and 'outcome is unknown' in p.stdout,p.stdout
assert 'fixture boundary: next restart request captured' in p.stdout,p.stdout
print('PASS: production restart selected host-confirmed root after durable correlated acknowledgement',flush=True)
print('BOUNDARY: local transport; host confirmation preseeded; no real remote, replacement, or Herdr lifecycle executed',flush=True)
