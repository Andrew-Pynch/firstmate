from pathlib import Path
import os,subprocess,time,shlex
r=Path.cwd();b=r/'.test-r5/preflight-proof';b.mkdir();p=b/'parent';h=b/'mate'
for d in (p,h):subprocess.run(['bin/fm-lab-home.sh','create',str(d)],check=True,stdout=subprocess.DEVNULL)
(h/'.fm-secondmate-home').write_text('mate\n');(h/'AGENTS.md').write_text('# Disposable validation\n');(h/'data/charter.md').write_text('# Validation\n')
subprocess.run(['git','init','--quiet',str(h)],check=True)
socket=b/'tmux';socket.mkdir(mode=0o700)
env=os.environ.copy()
for key in list(env):
 if key.startswith(('FM_','HERDR_')) or key in ('TMUX','NO_MISTAKES_GATE'):env.pop(key)
env.update(TMUX_TMPDIR=str(socket),TMPDIR=str(r/'.test-r5/tmp'),FM_HOME=str(p))
log=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7/relaunch-preflight-r5.txt').open('w',buffering=1)
def run(argv,check=True):
 log.write('$ '+shlex.join(map(str,argv))+'\n');x=subprocess.run(list(map(str,argv)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);log.write(x.stdout+'exit='+str(x.returncode)+'\n');
 if check:assert x.returncode==0,x.stdout
 return x
launcher=b/'start.sh';launcher.write_text('#!/bin/sh\nexport PI_CODING_AGENT_DIR='+shlex.quote(str(b/'agent'))+'\nexec /home/andrew/.bun/bin/omp --cwd '+shlex.quote(str(r))+' --session-dir '+shlex.quote(str(b/'sessions'))+' --no-extensions --no-tools --no-skills --no-rules --no-title --no-lsp --no-session\n');launcher.chmod(0o700)
tmux=['tmux','-S','.test-r5/p.sock']
try:
 run(tmux+['new-session','-d','-s','primary','-n','fm-mate','-c',str(r),str(launcher)])
 time.sleep(2)
 pane_pid=int(run(tmux+['display-message','-p','-t','primary:fm-mate','#{pane_pid}']).stdout)
 run(['ps','-p',str(pane_pid),'-o','pid=,comm=,args='])
 env['TMUX']=run(tmux+['display-message','-p','-t','primary:fm-mate','#{socket_path},0,0']).stdout.strip()
 fields={'window':'primary:fm-mate','endpoint_task_id':'mate','backend':'tmux','harness':'omp','kind':'secondmate','mode':'secondmate','home':str(h),'project':str(h),'worktree':str(h),'code_root':str(r),'yolo':'off'}
 meta=p/'state/mate.meta';meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()));before=meta.read_bytes()
 for args,reason in [(['--harness','omp','--code-root',str(b/'missing')],'not a readable directory'),(['--harness','claude'],'cannot launch from a code root')]:
  out=run(['bash','bin/fm-control.sh','mate','relaunch',*args],False);assert out.returncode!=0 and reason in out.stdout,out.stdout
  assert meta.read_bytes()==before;os.kill(pane_pid,0)
  log.write('PASS: refused before stopping live OMP; PID survives and endpoint metadata is byte-identical.\n')
finally:
 run(tmux+['kill-server'],False);log.close()
