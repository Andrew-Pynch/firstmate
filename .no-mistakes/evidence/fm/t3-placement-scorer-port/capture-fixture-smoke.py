import os, pathlib, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/andrew/.no-mistakes/evidence/01M6N2WQD0E0NGTQ4MS4JEJW13')
source=(root/'tests/fm-place.test.sh').read_text().split('\ntest_places_locally_when_under_the_cap\n',1)[0]
source+='''
# Retain the suite's real CLI driver and add transcript capture only.
eval "$(declare -f run_place | sed '1s/run_place/run_place_original/')"
run_place() {
  run_place_original "$@"
  printf '\\nCLI exit=%s\\n%s\\n' "$PLACE_STATUS" "$PLACE_OUT"
}
test_the_t3_scorer_ranks_eligible_hosts_by_cpu_and_memory
test_a_slow_mate_ages_earlier_t3_samples
'''
fd,name=tempfile.mkstemp(prefix='.capture-placement-',suffix='.sh',dir=root/'tests')
try:
    with os.fdopen(fd,'w') as f: f.write(source)
    p=subprocess.run(['bash',name],cwd=root,text=True,capture_output=True,timeout=90)
    log=p.stdout+p.stderr
    (evidence/'fixture-placement.log').write_text(log)
    print(log)
    raise SystemExit(p.returncode)
finally:
    pathlib.Path(name).unlink(missing_ok=True)
