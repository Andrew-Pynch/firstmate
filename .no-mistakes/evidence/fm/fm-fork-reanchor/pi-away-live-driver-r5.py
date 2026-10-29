from pathlib import Path
import os,subprocess,json,time,select,signal,shlex
root=Path.cwd(); base=root/'.test-r5/pi-final'; base.mkdir(parents=True,exist_ok=True); home=base/'home'; home.mkdir()
evidence=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7/pi-away-live-r5.txt')
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,stdout=subprocess.DEVNULL)
(home/'bin').symlink_to(root/'bin',target_is_directory=True)
(home/'AGENTS.md').write_text('# Disposable validation home\n')
(home/'.fm-secondmate-home').write_text('validation\n')
probe=base/'owner.ts';probe.write_text('import {writeFileSync} from "node:fs"; export default function(pi) { writeFileSync(process.env.FM_HOME+"/state/.lock",process.pid+"\\n"); pi.registerCommand("validation-snapshot", {description:"Snapshot live session entries",handler:async(_,ctx)=>writeFileSync(process.env.FM_HOME+"/entries.json",JSON.stringify(ctx.sessionManager.getEntries()))}); }')
env=os.environ.copy()
for key in list(env):
 if key.startswith(('FM_','HERDR_','OPENAI_','ANTHROPIC_','PI_')) or key=='NO_MISTAKES_GATE':env.pop(key)
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-r5/tmp'),PI_CODING_AGENT_DIR=str(base/'agent'),PI_OFFLINE='1',PI_TELEMETRY='0')
with evidence.open('w',buffering=1) as log:
 def run(args):
  log.write('$ '+shlex.join(args)+'\n');r=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);log.write(r.stdout+'exit='+str(r.returncode)+'\n');assert r.returncode==0;return r.stdout
 run(['bash','bin/fm-afk-contract.sh','enter','--objective','Verify pending outcomes remain durable while away','--words','Preserve pending decisions for my return'])
 run(['bash','bin/fm-branch-outcome.sh','append','--task','release','--verdict','captain','--summary','Choose the release target after returning'])
 cmd=['node','/home/andrew/.npm/_npx/99fca8174466655b/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js','--mode','rpc','--session-dir',str(base/'sessions'),'--no-tools','--no-extensions','--no-skills','--no-context-files','--no-mcp','-e',str(probe),'-e',str(root/'.pi/extensions/fm-branch-supervision.ts')]
 log.write('$ '+shlex.join(cmd)+'\n');p=subprocess.Popen(cmd,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,start_new_session=True)
 def rpc(kind,**kw):
  data={'id':str(time.monotonic()),'type':kind,**kw};log.write('stdin '+json.dumps(data)+'\n');p.stdin.write(json.dumps(data)+'\n');p.stdin.flush();until=time.monotonic()+30
  while time.monotonic()<until:
   ready,_,_=select.select([p.stdout],[],[],.2)
   if ready:
    line=p.stdout.readline();log.write(line)
    try:r=json.loads(line)
    except ValueError:continue
    if r.get('id')==data['id']:
     assert r.get('success'),r;return r.get('data',{})
  raise RuntimeError('No response to '+kind)
 try:
  rpc('get_state');time.sleep(3)
  rpc('prompt',message='/validation-snapshot');away=json.loads((home/'entries.json').read_text());assert any(m.get('customType')=='fm-branch-visible-outcome' for m in away),away
  assert not any(m.get('customType')=='fm-branch-process' for m in away),away
  state=rpc('get_state');assert not state.get('isStreaming') and not state.get('pendingMessageCount'),state
  assert 'Choose the release target' in run(['bash','bin/fm-branch-outcome.sh','unprocessed'])
  log.write('PASS: actual Pi persists visible outcome, leaves it unprocessed, and opens no main processing turn while away.\n')
  run(['bash','bin/fm-afk-contract.sh','archive'])
  rpc('new_session');time.sleep(3)
  returned=rpc('get_messages')['messages'];assert any(m.get('customType')=='fm-branch-process' and 'Choose the release target' in str(m.get('content')) for m in returned),returned
  assert 'Choose the release target' in run(['bash','bin/fm-branch-outcome.sh','unprocessed'])
  log.write('PASS: archive followed by real Pi session-start presents the pending outcome in fm-branch-process; it remains unprocessed until acknowledged. No model completion claimed.\n')
 finally:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=8)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
print(evidence)
