from pathlib import Path
import os,subprocess,json,time,shlex,signal
root=Path.cwd(); base=root/'.test-r5/live'; base.mkdir(parents=True,exist_ok=True)
evidence=Path('/home/andrew/.no-mistakes/evidence/01M62VWHSRWT01MB25T4A9K8M7')
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_','HERDR_')): env.pop(key)
env['FM_HERDR_LAB_STATE_DIR']=str(base/'herdr-state'); env['TMPDIR']=str(root/'.test-r5/tmp')
log=(evidence/'live-guards-r5.txt').open('w',buffering=1)
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
log.close();print("Decision and conflicting-pin CLI checks passed.")
