from pathlib import Path
import os,subprocess,json,time,select
r=Path.cwd(); b=r/'.test-r3/pi';b.mkdir(parents=True,exist_ok=True);home=b/'home';home.mkdir();e=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7/pi-live-r3.txt')
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,stdout=subprocess.DEVNULL)
(home/'bin').symlink_to(r/'bin',target_is_directory=True)
(home/'AGENTS.md').symlink_to(r/'AGENTS.md')
(home/'.fm-secondmate-home').write_text('validation\n')
subprocess.run(['git','init','--quiet',str(home)],check=True)
probe=b/'probe.ts';probe.write_text('''import {writeFileSync,readFileSync,existsSync,appendFileSync} from "node:fs";
import {spawnSync} from "node:child_process";
export default function(pi) {
 const home=process.env.FM_HOME; writeFileSync(home+"/state/.lock",process.pid+"\\n");
 pi.registerCommand("validation-hook",{description:"Run native session-open hook",handler:async(args)=>{
 const result=spawnSync(home+"/bin/fm-sessionstart-run.sh",["--source",args],{env:{...process.env,FM_ROOT_OVERRIDE:home},encoding:"utf8"});
 appendFileSync(home+"/probe.log","hook source="+args+" exit="+result.status+" main-record="+existsSync(home+"/state/.open-decisions-presented.main")+"\\n");
 }});
 pi.registerCommand("validation-probe",{description:"Exercise isolated branch lifecycle",handler:async()=>{
  const offer={message:"heartbeat: isolated validation",projects:[],heartbeat:true,eligible:true,awayOnly:false,accepted:false,settlement:Promise.resolve(),accept(p){this.accepted=true;this.settlement=p??Promise.resolve();}};
  pi.events.emit("fm-branch-supervision:dispatch",offer);
  appendFileSync(home+"/probe.log","accepted="+offer.accepted+"\\n");
  if(offer.accepted) offer.settlement.then(()=>appendFileSync(home+"/probe.log","settled\\n"),e=>appendFileSync(home+"/probe.log","settlement="+e.message+"\\n"));
 }});
}''')
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_')):env.pop(k)
env.pop('NO_MISTAKES_GATE',None)
env.update(FM_HOME=str(home),PI_CODING_AGENT_DIR=str(b/'agent'),PI_OFFLINE='1',PI_TELEMETRY='0')
cmd=['node','/home/andrew/.npm/_npx/99fca8174466655b/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js','--mode','rpc','--session-dir',str(b/'sessions'),'--no-tools','--no-extensions','--no-skills','--no-context-files','--no-mcp','-e',str(probe),'-e',str(r/'.pi/extensions/fm-branch-supervision.ts')]
with e.open('w',buffering=1) as out:
 out.write('$ '+ ' '.join(cmd)+'\n')
 p=subprocess.Popen(cmd,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=out,text=True,start_new_session=True)
 def command(data):
  out.write('stdin: '+json.dumps(data)+'\n');p.stdin.write(json.dumps(data)+'\n');p.stdin.flush()
  end=time.monotonic()+20
  while time.monotonic()<end:
   ready,_,_=select.select([p.stdout],[],[],.3)
   if not ready:continue
   line=p.stdout.readline()
   if not line:break
   out.write(line)
   try:obj=json.loads(line)
   except ValueError:continue
   if obj.get('type')=='response' and obj.get('id')==data['id']:return obj
  raise RuntimeError('No RPC response to '+data['type'])
 try:
  assert command({'id':'state','type':'get_state'})['success']
  main_record=home/'state/.open-decisions-presented.main';main_record.write_text(str(p.pid)+'\nmain fixture\n')
  command({'id':'hook-reload','type':'prompt','message':'/validation-hook reload'})
  assert main_record.exists(), 'reopening the same main context discarded its record'
  command({'id':'hook-resume','type':'prompt','message':'/validation-hook resume'})
  assert not main_record.exists(), 'resume context retained its prior presentation record'
  out.write('PASS: native session-open hook preserves reload and invalidates resume for the real Pi owner.\n')
  assert command({'id':'probe1','type':'prompt','message':'/validation-probe'})['success']
  time.sleep(4)
  out.write('probe log:\n'+(home/'probe.log').read_text())
  pointer=home/'state/.branch-session'
  out.write('branch pointer exists='+str(pointer.exists())+'\n')
  if pointer.exists():out.write(pointer.read_text())
  before=pointer.read_text(); record=home/'state/.open-decisions-presented.branch';record.write_text(str(p.pid)+'\nreview\tdeploy\tneeds-decision\tchoose deployment target\n')
  assert command({'id':'effort','type':'set_thinking_level','level':'high'})['success']
  command({'id':'probe-reopen','type':'prompt','message':'/validation-probe'})
  time.sleep(3)
  assert pointer.read_text()==before and record.exists(), 'same conversation did not retain its record'
  out.write('PASS: same-conversation reopen retained branch pointer and presentation record.\n')
  assert command({'id':'new','type':'new_session'})['success']
  assert command({'id':'probe2','type':'prompt','message':'/validation-probe'})['success']
  time.sleep(3)
  out.write('probe log after new_session:\n'+(home/'probe.log').read_text())
  out.write('branch pointer exists='+str(pointer.exists())+'\n')
  if pointer.exists():out.write(pointer.read_text())
  assert pointer.read_text()!=before and not record.exists(), 'replacement did not clear the presentation record'
  out.write('PASS: new_session replaced branch conversation and cleared the predecessor presentation record.\n')
 finally:
  os.killpg(p.pid,15)
  try:p.wait(timeout=8)
  except subprocess.TimeoutExpired:os.killpg(p.pid,9);p.wait()
print(e)
