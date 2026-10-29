import os, pathlib, subprocess, json, time, shlex, signal

ROOT = pathlib.Path.cwd()
BASE = ROOT / '.test-current/process'
BASE.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_', 'CLAUDE_')) or k in ('TMUX','TMUX_PANE','TRACEPARENT'):
        env.pop(k, None)
env.update(HOME=str(BASE/'user'), TMPDIR=str(ROOT/'.test-current/tmp'), FM_GATE_REFUSE_BYPASS='1', FM_TEST_SEAM='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
for p in ['user', 'bin', 'home/config', 'home/data', 'home/state', 'home/projects']:
    (BASE/p).mkdir(parents=True, exist_ok=True)
def run(args, **kw):
    r=subprocess.run([str(x) for x in args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)
    if r.returncode: raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}')
    return r.stdout
def write(p,s):
    p.write_text(s)
    return p
socket=str(BASE/'tmux.sock')
tmux=write(BASE/'bin/tmux', '#!/bin/sh\nexec /usr/bin/tmux -S '+shlex.quote(socket)+' "$@"\n')
tmux.chmod(0o755)
worker=write(BASE/'bin/claude', '''#!/usr/bin/env python3
import os,json,pathlib,ctypes,sys
ctypes.CDLL(None).prctl(15,b'claude',0,0,0)
p=pathlib.Path('''+repr(str(BASE/'workers.jsonl'))+''')
with p.open('a') as f: f.write(json.dumps({'pid':os.getpid(),'cwd':os.getcwd(),'traceparent':os.environ.get('TRACEPARENT'),'task':os.environ.get('FM_TASK_ID')})+'\\n')
print('Local fixture worker ready',flush=True)
for line in sys.stdin:
    if line.strip()=='/exit': break
''')
worker.chmod(0o755)
env['PATH']=str(BASE/'bin')+':'+env['PATH']
env['FM_HOME']=str(BASE/'home')
env['FM_SPAWN_NO_GUARD']='1'
env['FM_ROOT_OVERRIDE']=str(ROOT)
env['FM_TRACE_CONTEXT']='on'
(BASE/'home/config/crew-harness').write_text('claude\n')
(BASE/'home/config/backend').write_text('tmux\n')
(BASE/'home/state/.lock').write_text(str(os.getpid())+'\n')
(BASE/'home/state/.trace-context-effective').write_text(str(os.getpid())+' on\n')
proj=BASE/'project'; wt=BASE/'worktree'
run(['git','init','-q','-b','main',proj])
run(['git','-C',proj,'config','user.name','Fixture'])
run(['git','-C',proj,'config','user.email','fixture@example.invalid'])
write(proj/'file','fixture\n')
run(['git','-C',proj,'add','file']); run(['git','-C',proj,'commit','-qm','fixture'])
run(['git','-C',proj,'worktree','add','-qb','fixture',wt])
task=BASE/'home/data/traceproof'; task.mkdir()
write(task/'brief.md', '''# Task
## Captain's intent
Prove local trace delivery.
## Firstmate spec
Record the received process environment.
## Acceptance record
Accept when: the process records the carrier
Proof: isolated process environment
Evidence gate: NONE
''')
def wait_for(fn, seconds=20):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        v=fn()
        if v: return v
        time.sleep(.1)
    raise RuntimeError('timed out')
def rows():
    p=BASE/'workers.jsonl'
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
def meta():
    return dict(x.split('=',1) for x in (BASE/'home/state/traceproof.meta').read_text().splitlines() if '=' in x)
watch=None
try:
    run(['tmux','-f','/dev/null','new-session','-d','-s','firstmate','-c',BASE,'/bin/bash --noprofile --norc'])
    run(['tmux','set-option','-g','default-shell','/bin/bash'])
    for k in ('PATH','HOME','TMPDIR'): run(['tmux','set-environment','-g',k,env[k]])
    args=[ROOT/'bin/fm-spawn.sh','traceproof',proj,'--worktree',wt,'--harness','claude','--mode','no-mistakes','--yolo','off','--backend','tmux']
    print(run(args),flush=True)
    first=wait_for(lambda: rows())[-1]
    recorded=meta()['traceparent']
    assert first['traceparent']==recorded and first['task']=='traceproof', (first,meta())
    print('PASS trace: actual worker process received persisted carrier', recorded,flush=True)
    run(['tmux','kill-window','-t',meta()['window']])
    print(run(args),flush=True)
    second=wait_for(lambda: rows() if len(rows())==2 else None)[-1]
    assert second['pid']!=first['pid'] and second['traceparent']==recorded==meta()['traceparent']
    print('PASS recovery: replacement worker PID received identical persisted carrier',flush=True)
    before=(BASE/'home/state/traceproof.meta').read_bytes()
    bad=subprocess.run([str(ROOT/'bin/fm-spawn.sh'),'badtrace',str(BASE/'home'),'--secondmate','--traceparent','00-not-a-carrier'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    assert bad.returncode and 'not a valid W3C traceparent' in bad.stdout,bad.stdout
    assert before==(BASE/'home/state/traceproof.meta').read_bytes() and len(rows())==2
    print('PASS malformed carrier: CLI refused before creating another process',bad.stdout.strip(),flush=True)
    state=BASE/'home/state'
    status=state/'traceproof.status'
    status.write_text('paused: awaiting external input\n')
    # A separate watcher uses actual tmux inventory/capture and production crew state.
    env.update(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_STALE_ESCALATE_SECS='1',FM_PAUSE_RESURFACE_SECS='12',FM_WATCH_HANDLING_SUCCESSOR='1')
    # Prime only the observed-status cursor through the public drain; no timer is aged.
    run([ROOT/'bin/fm-wake-drain.sh'])
    print(run([ROOT/'bin/fm-crew-state.sh','traceproof']),flush=True)
    # Watcher treats existing status as baseline using its owned signature contract.
    sig=run(['/bin/bash','-c','. "$1/bin/fm-classify-lib.sh"; printf "v2\\t%s\\t%s@%s" "$(status_observed_signature "$2")" "$(wc -c < "$2" | tr -d "[:space:]")" "$(_fm_open_decisions_file_ident "$2")"','_',ROOT,status])
    (state/'.seen-traceproof_status').write_text(sig)
    log=open(BASE/'pause.log','w')
    started=time.monotonic()
    watch=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    time.sleep(5)
    assert watch.poll() is None,(BASE/'pause.log').read_text()
    queue=state/'.wake-queue'
    assert not queue.exists() or 'stale:' not in queue.read_text(),queue.read_text()
    print('PASS pause: real pane remained quiet beyond 1-second wedge threshold',flush=True)
    watch.wait(timeout=25); log.close()
    elapsed=time.monotonic()-started
    out=(BASE/'pause.log').read_text()
    assert 'awaiting external' in out and 'possible wedge' not in out,out
    assert elapsed>=7,elapsed
    print('PASS pause: real elapsed long-cadence recheck after',round(elapsed,2),'seconds:',out.strip(),flush=True)
finally:
    if watch and watch.poll() is None:
        os.killpg(watch.pid,signal.SIGTERM); watch.wait(timeout=10)
    subprocess.run([str(tmux),'kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
