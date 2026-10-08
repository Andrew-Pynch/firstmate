#!/usr/bin/env bash
# fm-nm-sol-profile.sh - create an explicit isolated no-mistakes Sol gate profile.
# Usage: fm-nm-sol-profile.sh --home <new-absolute-directory>
#        [--omp <absolute-executable>] [--effort low|medium|high|xhigh]
# This creates files only in a NEW directory. It never edits ~/.no-mistakes,
# connects to a daemon, starts a pipeline, changes dispatch or adds a reviewer.
# Installed no-mistakes v1.72.0 has no axi run --model/--effort: NM_HOME/config.yaml
# is the supported opt-in seam. Keep Opus implementation in its existing worker;
# select this NM_HOME before initializing/running that branch's gate after the
# first pass. Initialize this separate profile through no-mistakes' existing
# init command. Never switch NM_HOME mid-run or start a duplicate active run.
# One Sol reviewer, the same Sol fixer, and Sol on the gate's other agent steps.
# Native argument overrides are deliberately absent; no credential/config copy.
# OMP uses its existing account and the executable resolved from PATH (the local
# workstation fence stays in force). Fallback and advisor are off in this profile.
# Until fm-project-inventory.sh --check passes, project review remains advisory;
# this helper does not authorize custody, delivery-mode or merge-policy changes.
# Measure ready-to-merge time, meaningful fixes and provider credits by project
# before expanding defaults. There is no second reviewer row or manual signoff.
# The Pi adapter's --no-context-files is not an OMP 18.4.4 CLI flag. The
# launcher translates it through OMP's installed context capability, including
# custom instruction filenames, then disables the exact discovered IDs. A
# failed discovery stops the invocation rather than loading fleet instructions.
set -eu
PROFILE_HOME=
OMP=$(command -v omp || true)
EFFORT=high
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home|--omp|--effort)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
      case "$1" in --home) PROFILE_HOME=$2 ;; --omp) OMP=$2 ;; --effort) EFFORT=$2 ;; esac
      shift ;;
    --help|-h) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) printf 'fm-nm-sol-profile: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
python3 - "$PROFILE_HOME" "$OMP" "$EFFORT" <<'PY'
import json, os, pathlib, sys
raw, omp, effort = sys.argv[1:]
home = pathlib.Path(raw)
if not raw or not home.is_absolute() or home.exists() or home.is_symlink():
    sys.exit('fm-nm-sol-profile: --home must name a new absolute directory; existing state is never replaced')
if not pathlib.Path(omp).is_absolute() or not os.access(omp, os.X_OK):
    sys.exit('fm-nm-sol-profile: --omp must be an existing absolute executable')
if effort not in ('low', 'medium', 'high', 'xhigh'):
    sys.exit('fm-nm-sol-profile: unsupported effort')
model = 'openai-codex/gpt-6.1-sol'
profile = dict(model=model, effort=effort)
role = dict(agent='pi', **profile)
# Require an existing parent so the helper cannot populate unrelated home trees.
home.mkdir(mode=0o700)
(home / 'controls.yml').write_text('''advisor:
  enabled: false
codexResets:
  autoRedeem: "no"
claudeResets:
  autoRedeem: "no"
retry:
  modelFallback: false
  usageAwareFallback: false
''')
(home / 'contract.txt').write_text('''You are the single no-mistakes pipeline reviewer/fixer, not the implementation worker or fleet supervisor.
Do not spawn a second reviewer or seek independent manual signoff. The existing pipeline owns branch custody, findings, changed-head re-review and publication.
Preserve the supplied user intent, acceptance criteria, source boundaries and forbidden changes. A finding that challenges deliberate product intent is an ask-user decision, never authorization to remove required behavior. Do not answer your own ask-user finding.
Use the mapped project's authoritative coding guidelines. Missing project identity or guideline evidence is unresolved, not permission to invent standards or change delivery/merge policy. On incompletely mapped projects, this review is advisory, not a completed blocking gate.
''')
launcher = home / 'agent-omp'
launcher.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, subprocess, sys
home = pathlib.Path(__file__).resolve().parent
args = sys.argv[1:]
controls = home / 'controls.yml'
if any(arg in ('--no-context-files', '-nc') for arg in args):
    args = [arg for arg in args if arg not in ('--no-context-files', '-nc')]
    package = pathlib.Path(os.environ.get('PI_PACKAGE_DIR', str(pathlib.Path.home() / '.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent')))
    discovery = package / 'src/discovery/index.ts'
    probe = \"const { loadCapability } = await import(process.argv[1]); const r = await loadCapability('context-files', {cwd:process.cwd(), disabledExtensions:[], includeDisabled:true}); if (r.warnings.length) throw new Error('context discovery incomplete'); console.log(JSON.stringify([...new Set(r.all.map(f => 'context-file:' + f.level + ':' + f.path.split('/').pop()))]));\"
    result = subprocess.run(['bun', '--eval', probe, str(discovery)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit('Sol gate: OMP context suppression could not be verified')
    ids = json.loads(result.stdout)
    overlay = dict(advisor=dict(enabled=False), codexResets=dict(autoRedeem='no'),
                   claudeResets=dict(autoRedeem='no'),
                   retry=dict(modelFallback=False,usageAwareFallback=False),
                   disabledExtensions=ids)
    key = hashlib.sha256(os.getcwd().encode()).hexdigest()[:16]
    controls = home / ('.context-' + key + '.json')
    staged = home / ('.context-' + str(os.getpid()) + '.tmp')
    staged.write_text(json.dumps(overlay))
    os.replace(staged, controls)
    args = ['--no-rules', *args]
os.environ['NO_MISTAKES_GATE'] = '1'
'''+ 'omp = ' + repr(omp) + '''
os.execv(omp, [omp, '--config', str(controls), '--no-extensions', '--no-prewalk',
              '--append-system-prompt', str(home / 'contract.txt'), *args])
''')
launcher.chmod(0o700)
config = dict(agent='pi', agent_config=dict(pi=profile),
              agent_path_override=dict(pi=str(launcher)),
              review_agents=dict(reviewer=role, fixer=role))
# JSON is valid YAML; avoid a second YAML parser or a new runtime dependency.
(home / 'config.yaml').write_text(json.dumps(config, indent=2) + '\n')
print(str(home))
PY
