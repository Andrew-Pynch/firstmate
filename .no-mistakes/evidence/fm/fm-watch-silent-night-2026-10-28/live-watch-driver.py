import json, os, pathlib, subprocess, tempfile, time, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/andrew/.no-mistakes/evidence/01M692QWG08DYNN8KR5QX8FBBQ')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
env=os.environ.copy()
for key in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE','FM_TASK_ID','CLAUDECODE','PI_CODING_AGENT','FM_PI_HARNESS','CURSOR_AGENT','CURSOR_INVOKED_AS','GROK_AGENT'):
 env.pop(key,None)
env.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),FM_OMP_HARNESS='omp',OMP_SKIP_SETUP='1',FM_POLL='3',FM_SIGNAL_GRACE='999999',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
log=[]
def record(msg):
 log.append(msg); (E/'live-watch-transcript.log').write_text('\n'.join(log)+'\n'); print(msg,flush=True)
def tm(*a):
 return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True).stdout
def shot(name):
 s=tm('capture-pane','-p','-S','-100','-t','primary'); (E/(name+'.txt')).write_text(s); return s
def waitfor(fn,sec=60):
 end=time.monotonic()+sec
 while time.monotonic()<end:
  if fn(): return
  time.sleep(.25)
 raise TimeoutError('condition not observed')
def health():
 r=subprocess.run(['bash','bin/fm-supervision-health.sh','check'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 record(f'health check rc={r.returncode}: {r.stdout.strip()}'); return r
try:
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(LAB)],check=True,capture_output=True,text=True)
 (LAB/'tmux').mkdir(); (LAB/'config/supervision-host-off').touch()
 (LAB/'config/watch.env').write_text('export FM_POLL=3\nexport FM_SIGNAL_GRACE=999999\nexport FM_CHECK_INTERVAL=999999\nexport FM_HEARTBEAT=999999\n')
 record('Started disposable marked home and private tmux socket. omp version: '+subprocess.check_output(['omp','--version'],text=True).strip())
 tm('new-session','-d','-s','primary','-x','150','-y','45','-c',str(ROOT),'-e','FM_HOME='+str(LAB),'omp --no-session --no-lsp --no-title --config .omp/fm-worker-overlay.yml --auto-approve')
 time.sleep(8)
 record('Initial pane:\n'+shot('omp-initial'))
 tm('send-keys','-t','primary','For this isolated validation, call fm_watch_arm_omp exactly once and report its result. Do not run any other tools or modify any files.','Enter')
 waitfor(lambda:(LAB/'state/.last-watcher-beat').exists(),100)
 record('Real omp armed watcher. Session lock: '+(LAB/'state/.lock').read_text().strip())
 record('Watcher lock pid: '+(LAB/'state/.watch.lock/pid').read_text().strip())
 tm('new-window','-d','-t','primary','-n','worker','-c',str(ROOT),'sleep 180')
 # A real local endpoint, without simulating a vendor harness.
 (LAB/'state/live.meta').write_text('backend=tmux\nwindow=primary:worker\n')
 health()
 record('Armed pane:\n'+shot('omp-armed'))
 # SIGKILL the exact owning primary via its private tmux pane only.
 t0=time.monotonic()
 tm('respawn-pane','-k','-t','primary:0','sleep 180')
 record('Owning omp pane replaced; surviving local worker remains on private socket.')
 r=health()
 waitfor(lambda:(LAB/'state/.wake-queue').exists(),15)
 record('Elapsed to observed durable alert: %.3fs'%(time.monotonic()-t0))
 record('Durable queue:\n'+(LAB/'state/.wake-queue').read_text())
 for name in ('.primary-loss-alert','.primary-loss-queued','.watch-cycle-exits.log'):
  p=LAB/'state'/name
  if p.exists(): record(name+':\n'+p.read_text())
 r=health()
 record('Repeated check queue:\n'+(LAB/'state/.wake-queue').read_text())
 (E/'live-watch-result.json').write_text(json.dumps({'completed':True,'first_loss_rc':r.returncode},indent=2))
finally:
 try: tm('kill-server')
 except Exception: pass
 shutil.rmtree(LAB)
 record('Private tmux server stopped and disposable home removed.')
