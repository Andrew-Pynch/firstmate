from pathlib import Path
import os,subprocess,json,shlex
r=Path.cwd(); b=r/'.test-r5/remote-final';b.mkdir(); p=b/'parent';h=b/'host';p.mkdir();h.mkdir();e=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7/remote-route-r5.txt')
for home in (p,h):
 subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,stdout=subprocess.DEVNULL)
(h/'bin').symlink_to(r/'bin',target_is_directory=True);(h/'AGENTS.md').write_text('# Local transport test\n');(h/'.fm-secondmate-home').write_text('mate\n');(h/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(p)+'\n')
(h/'state/parent-route').mkdir();(p/'config/secondmate-harness').write_text('codex\n')
old=b/'old';requested=b/'requested';confirmed=b/'confirmed root'
for d in (old,requested,confirmed):d.mkdir()
fields={'window':'fm-remote:p1','endpoint_task_id':'mate','backend':'herdr','herdr_session':'fm-remote','herdr_workspace_id':'w1','herdr_tab_id':'t1','herdr_pane_id':'p1','harness':'codex','kind':'secondmate','mode':'secondmate','home':str(h),'worktree':str(h),'project':str(r),'code_root':str(old),'model':'','effort':''}
def write_meta(file,items):file.write_text(''.join(k+'='+v+'\n' for k,v in items.items()))
write_meta(h/'state/parent-route/mate.meta',fields)
write_meta(p/'state/mate.meta',{**fields,'remote_host':'local-fixture','remote_root':str(r),'remote_backend':'herdr','remote_target':'fm-remote:p1'})
(p/'data/secondmates.md').write_text(f'- mate - isolated transport (host: local-fixture; root: {r}; home: {h}; scope: validation; projects: demo; added 2026-10-29)\n')
shim=b/'shim';shim.mkdir();herdr=shim/'herdr';herdr.write_text('#!/bin/sh\n# Network/lifecycle is intentionally unavailable in this routing fixture.\nexit 1\n');herdr.chmod(0o700)
transport=b/'transport.py';transport.write_text('''#!/usr/bin/env python3
from pathlib import Path
import os,sys,base64,subprocess,json,re
args=sys.argv[1:]
while args and args[0]=='-o':args=args[2:]
assert args.pop(0)=='--';assert args.pop(0)=='local-fixture';assert args.pop(0)=='fm-remote-entrypoint.sh'
protocol,root,home,payload=args;assert protocol=='1'
r=Path(base64.b64decode(root).decode());h=Path(base64.b64decode(home).decode());cmd=[s.decode() for s in base64.b64decode(payload).split(b'\\0') if s]
assert cmd[0]=='fm-remote-secondmate-control.sh'
with open(os.environ['TRANSPORT_LOG'],'a') as f:f.write(json.dumps(cmd)+'\\n')
env=os.environ.copy();env['FM_HOME']=str(h)
for k in ('FM_STATE_OVERRIDE','FM_ROOT_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE'):env.pop(k,None)
if cmd[1]=='relaunch':
 # Only the forbidden lifecycle leaf is simulated. Route generation, encoding,
 # parent recording, persistence handshake, and restart selection are production.
 meta=h/'state/parent-route/mate.meta';items=dict(line.split('=',1) for line in meta.read_text().splitlines())
 requested=cmd[cmd.index('--code-root')+1] if '--code-root' in cmd else items['code_root']
 selected=os.environ['CONFIRMED_ROOT'] if requested==os.environ['REQUESTED_ROOT'] else requested
 items.update(code_root=selected,harness=cmd[3],model='' if cmd[4]=='default' else cmd[4],effort='' if cmd[5]=='default' else cmd[5])
 meta.write_text(''.join(k+'='+v+'\\n' for k,v in items.items()))
 subprocess.run(['bash',str(r/'bin'/cmd[0]),'route','mate'],env=env,check=True)
elif cmd[1]=='send':
 subprocess.run(['bash',str(r/'bin'/cmd[0]),*cmd[1:]],env=env,check=True)
 corr=re.search(r'corr=([a-f0-9]{16})',cmd[3]);assert corr,cmd
 subprocess.run(['bash',str(r/'bin/fm-secondmate-report.sh'),'done',corr[1],'Fixture agent persisted its empty open-work set'],env=env,check=True)
else:raise RuntimeError(cmd)
''');transport.chmod(0o700)
env=os.environ.copy()
for key in list(env):
 if key.startswith(('FM_','HERDR_')):env.pop(key)
env.update(FM_HOME=str(p),FM_SSH_BIN=str(transport),PATH=str(shim)+':'+env['PATH'],TMPDIR=str(r/'.test-r5/tmp'),FM_SECONDMATE_PERSIST_WAIT='10',FM_SECONDMATE_PERSIST_POLL='1',TRANSPORT_LOG=str(b/'wire.jsonl'),REQUESTED_ROOT=str(requested),CONFIRMED_ROOT=str(confirmed))
with e.open('w',buffering=1) as log:
 log.write('Isolated local transport. Real fm-on, host route/send, parent metadata update, correlated reply, and restart selection. Agent lifecycle leaf simulated; no Herdr or remote target touched.\n')
 def run(argv):
  log.write('$ '+shlex.join(argv)+'\n');res=subprocess.run(argv,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45);log.write(res.stdout+'exit='+str(res.returncode)+'\n');assert res.returncode==0,res.stdout
 run(['bash','bin/fm-remote-secondmate-relaunch.sh','mate','codex','default','default','--code-root',str(requested)])
 assert dict(x.split('=',1) for x in (p/'state/mate.meta').read_text().splitlines())['code_root']==str(confirmed)
 log.write('Parent after confirmed route:\n'+(p/'state/mate.meta').read_text())
 run(['bash','bin/fm-secondmate-restart.sh','mate'])
 wire=[json.loads(x) for x in (b/'wire.jsonl').read_text().splitlines()];log.write('Decoded wire commands:\n'+json.dumps(wire,indent=2)+'\n')
 last=[c for c in wire if c[1]=='relaunch'][-1];assert last[last.index('--code-root')+1]==str(confirmed),last
 assert dict(x.split('=',1) for x in (p/'state/mate.meta').read_text().splitlines())['code_root']==str(confirmed)
 assert dict(x.split('=',1) for x in (h/'state/parent-route/mate.meta').read_text().splitlines())['code_root']==str(confirmed)
 log.write('PASS: parent selected host-confirmed root (including spaces), restart transmitted that root, and both host and parent retained it.\n')
print(e)
