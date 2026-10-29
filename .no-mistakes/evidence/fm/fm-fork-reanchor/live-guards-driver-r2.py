from pathlib import Path
import os,subprocess,json,time,shlex,signal
root=Path.cwd(); base=root/'.test-r2/live'; base.mkdir(parents=True,exist_ok=True)
evidence=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7')
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_','HERDR_')): env.pop(key)
env['FM_HERDR_LAB_STATE_DIR']=str(base/'herdr-state'); env['TMPDIR']=str(root/'.test-r2/tmp')
log=(evidence/'live-guards-r2.txt').open('w',buffering=1)
def run(args,check=True,extra=None):
    ee=env.copy();ee.update(extra or {})
    log.write('$ '+shlex.join(map(str,args))+'\n')
    p=subprocess.run(list(map(str,args)),env=ee,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    log.write(p.stdout+'exit='+str(p.returncode)+'\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
helper=root/'bin/fm-herdr-lab.sh';parent=base/'parent';mate=base/'mate'
for home in (parent,mate): run(['bin/fm-lab-home.sh','create',home])
(mate/'.fm-secondmate-home').write_text('mate\n');(mate/'AGENTS.md').write_text('# Isolated live validation mate\n');(mate/'data/charter.md').write_text('# Isolated validation\n')
run(['git','init','--quiet',mate])
# This public CLI needs no model or terminal transport.
(parent/'state/.lock').write_text(str(os.getpid())+'\n')
status=parent/'state/reanchor.status'; status.write_text('needs-decision [key=release]: '+('long decision '*30)+'tail=alpha\n')
denv={'FM_HOME':str(parent),'FM_SUPERVISION_ACTOR':'main'}
a=run(['bin/fm-wake-drain.sh'],extra=denv).stdout
b=run(['bin/fm-wake-drain.sh'],extra=denv).stdout
assert 'OPEN DECISIONS (still open' in a and '1 unchanged' in b
status.write_text('needs-decision [key=release]: '+('long decision '*30)+'tail=beta\n')
c=run(['bin/fm-wake-drain.sh'],extra=denv).stdout
assert 'OPEN DECISIONS (still open' in c
record=(parent/'state/.open-decisions-presented.main').read_text();assert 'tail=beta' in record
log.write('Persisted complete decision identity:\n'+record)
d=run(['bin/fm-wake-drain.sh'],extra={**denv,'FM_OPEN_DECISIONS_REVEAL':'1'}).stdout
assert 'OPEN DECISIONS (still open' in d
with status.open('a') as f:f.write('resolved [key=release]: accepted\n')
assert 'OPEN DECISIONS' not in run(['bin/fm-wake-drain.sh'],extra=denv).stdout
log.write('PASS: first presentation, repeat suppression, long-tail change, reveal, and resolution.\n')
# Conflicting account/profile pins refuse before any launch/auth work.
pin=parent/'config/secondmate-accounts/mate';pin.mkdir(parents=True)
(pin/'omp-profile').write_text('test-profile\n');(parent/'config/omp-account').write_text(str(base/'nonexistent-account')+'\nopenai-codex\n')
p=run(['bin/fm-spawn.sh','mate',mate,'--secondmate','--harness','omp','--code-root',root],False,denv)
assert p.returncode and 'conflicts with' in p.stdout and not (parent/'state/mate.meta').exists()
(parent/'config/omp-account').unlink();(pin/'omp-profile').unlink()
name=run([helper,'name','guard-r2']).stdout.strip();provisioned=False
try:
    run([helper,'provision',name]);provisioned=True
    pane=json.loads(run([helper,'run',name,'workspace','create','--cwd',mate,'--label','validation-r2','--no-focus']).stdout)['result']['root_pane']['pane_id']
    launcher=base/'start-omp.sh'; agent=base/'omp-state';agent.mkdir();sessions=base/'sessions';sessions.mkdir()
    launcher.write_text('#!/bin/sh\n'+ 'export PI_CODING_AGENT_DIR='+shlex.quote(str(agent))+'\nexec '+shlex.join(['/home/andrew/.bun/bin/omp','--cwd',str(root),'--session-dir',str(sessions),'--no-extensions','--no-tools','--no-skills','--no-rules','--no-title','--no-lsp','--no-session'])+'\n');launcher.chmod(0o700)
    run([helper,'run',name,'pane','run',pane,launcher])
    found=[]
    for _ in range(40):
        ps=subprocess.run(['ps','-eo','pid=,args='],text=True,stdout=subprocess.PIPE).stdout
        found=[line.strip() for line in ps.splitlines() if str(sessions) in line and 'omp' in line]
        if found: break
        time.sleep(.25)
    assert found,'OMP process not started'
    time.sleep(3)
    pids=[int(line.split()[0]) for line in found]; log.write('Real OMP process:\n'+'\n'.join(found)+'\n')
    output=run([helper,'run',name,'pane','read',pane,'--source','recent','--lines','60']).stdout
    assert output.strip(), 'OMP returned no rendered terminal output'
    fields={'window':name+':'+pane,'endpoint_task_id':'mate','backend':'herdr','herdr_session':name,'herdr_pane_id':pane,'herdr_workspace_id':pane.split(':')[0],'herdr_tab_id':pane.split(':')[0]+':t1','harness':'omp','kind':'secondmate','mode':'secondmate','worktree':str(mate),'project':str(mate),'home':str(mate),'code_root':str(root),'yolo':'off'}
    meta=parent/'state/mate.meta';meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()));before=meta.read_bytes()
    shims=base/'bin';shims.mkdir();original=env['PATH']
    shim=shims/'herdr';shim.write_text('#!/usr/bin/env bash\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ]; then unset "args[n-1]" "args[n-2]"; fi\nexec env PATH='+shlex.quote(original)+' '+shlex.join([str(helper),'run',name])+' "${args[@]}"\n');shim.chmod(0o700)
    cenv={**denv,'PATH':str(shims)+':'+original,'HERDR_SESSION':name}
    for args,reason in [(['--harness','omp','--code-root',str(base/'missing')],'not a readable directory'),(['--harness','claude'],'cannot launch from a code root')]:
        res=run(['bin/fm-control.sh','mate','relaunch',*args],False,cenv)
        assert res.returncode and reason in res.stdout
        assert meta.read_bytes()==before
        for pid in pids:os.kill(pid,0)
    run([helper,'run',name,'pane','get',pane])
    log.write('PASS: missing code root and incompatible Claude switch preserve the running process and byte-identical metadata.\n')
finally:
    if provisioned:run([helper,'teardown',name])
log.close();print('Live CLI guards passed; lab torn down.')
