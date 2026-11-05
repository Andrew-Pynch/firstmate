import json, os, pathlib, re, shutil, subprocess, tempfile, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/andrew/.no-mistakes/evidence/01M6N2WQD0E0NGTQ4MS4JEJW13')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.live-placement-', dir=root))
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_PLACE_') or key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS'):
        del env[key]
env['FM_HOME'] = str(lab)
records = []
def run(label, argv, expected=0, extra=None):
    start = time.monotonic()
    p = subprocess.run(argv, cwd=root, env={**env, **(extra or {})}, text=True, capture_output=True, timeout=60)
    row = dict(scenario=label, command=argv, extra_env=extra or {}, elapsed_s=round(time.monotonic()-start,3), exit=p.returncode, stdout=p.stdout, stderr=p.stderr)
    records.append(row)
    print(f'[{label}] exit={p.returncode} elapsed={row["elapsed_s"]}s\n{p.stdout}{p.stderr}', flush=True)
    assert p.returncode == expected, row
    return p.stdout
try:
    run('Create disposable lab inside the gate worktree', ['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'data/captain.md').write_text('Allow a maximum 2 live workers.\n')
    (lab/'data/secondmates.md').write_text('')
    plain = run('Real Linux resource sample', ['bin/fm-fleet-resources.sh','--local'])
    assert re.search(r'cpu_util=(?:0\.[0-9]+|1\.0+) avail_bytes=[0-9]+ total_bytes=[0-9]+', plain)
    raw = run('Real Linux resource JSON', ['bin/fm-fleet-resources.sh','--local','--json'])
    resources = json.loads(raw)
    host = resources['hosts'][0]
    assert 0 <= host['cpu_util'] <= 1
    assert 0 < host['avail_bytes'] <= host['total_bytes']
    assert host['avail_bytes'] % 1024 == 0
    total = int(re.search(r'^MemTotal:\s+(\d+)', pathlib.Path('/proc/meminfo').read_text(), re.M)[1]) * 1024
    assert host['total_bytes'] == total
    run('Real Linux resource summary', ['bin/fm-fleet-resources.sh','--local','--summary'])
    missing = run('Missing config uses headroom', ['bin/fm-place.sh'])
    assert missing.startswith('PLACE home=local ') and 'scorer=' not in missing
    config = lab/'config/placement-scorer'
    config.write_text('headroom\n')
    explicit = run('Explicit headroom uses the same output contract', ['bin/fm-place.sh'])
    assert explicit.startswith('PLACE home=local ') and 'scorer=' not in explicit
    records.append(dict(scenario='Headroom byte comparison on successive real samples', identical=missing==explicit, note='Deterministic unchanged-decision comparisons are also covered by tests/fm-place.test.sh.'))
    config.write_text('t3\n')
    t3 = run('Opt in to T3 using real CPU and memory', ['bin/fm-place.sh'])
    assert 'scorer=t3code-v0.1.7 weights=local:50 score=' in t3
    assert float(re.search(r' score=([0-9.]+)', t3)[1]) > 0
    config.write_text('t3 local=73\n')
    weighted = run('Set a custom local weight', ['bin/fm-place.sh'])
    assert 'weights=local:73 score=' in weighted
    config.write_text('t3 local=0\n')
    zero = run('Weight zero excludes the only candidate', ['bin/fm-place.sh'],3)
    assert 'weight 0 keeps this host out of t3 ranking' in zero
    config.write_text('t3 local=100\n')
    (lab/'data/captain.md').write_text('Allow a maximum 0 live workers.\n')
    cap = run('Maximum weight cannot override the local cap', ['bin/fm-place.sh'],3)
    assert 'cap: 0 live workers recorded against the 0-worker ceiling' in cap
    (lab/'data/captain.md').write_text('Allow a maximum 2 live workers.\n')
    memory = run('Maximum weight cannot override the memory floor', ['bin/fm-place.sh'],3, {'FM_PLACE_MIN_FREE_GIB':str(total//1073741824)})
    assert 'memory:' in memory and 'leaves no room for a worker' in memory
    for invalid in ('bogus\n','t3 local=101\n','t3 nobody=50\n','t3 local=1 local=2\n','headroom local=1\n','t3\nheadroom\n',''):
        config.write_text(invalid)
        bad = run('Reject invalid configuration '+repr(invalid), ['bin/fm-place.sh'],2)
        assert not bad
        assert 'placement scorer:' in records[-1]['stderr']
    mate = lab/'mate'
    run('Create disposable same-machine mate', ['bin/fm-lab-home.sh','create',str(mate)])
    (lab/'data/secondmates.md').write_text(f'- probe-mate - resource validation (home: {mate}; scope: resource validation; projects: alpha; added 2026-11-04)\n')
    run('Read two real same-machine resource reports', ['bin/fm-fleet-resources.sh'])
    config.write_text('t3 local=0 probe-mate=100\n')
    unknown = run('Maximum weight cannot admit a mate with unknown Nucleus state', ['bin/fm-place.sh'],3)
    assert 'probe-mate(nucleus: missing:' in unknown
    assert 'local(t3: weight 0' in unknown
    records.append(dict(scenario='All live assertions',result='pass'))
finally:
    shutil.rmtree(lab)
    records.append(dict(scenario='Cleanup', lab_removed=not lab.exists()))
    (evidence/'live-placement.json').write_text(json.dumps(records, indent=2)+'\n')
