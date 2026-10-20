#!/usr/bin/env bash
# fm-project-inventory.sh - read one evidence mapping per registered project.
# Usage: fm-project-inventory.sh [--mappings <json>] [--check] [--help]
# Emits JSON; never creates tickets, retires entries or changes delivery policy.
# Optional evidence file defaults to <data>/project-mappings.json. Its keys are
# registered project names; values contain canonical_repository, canonical_host,
# linear {workspace,team,project,ticket_rule}, and coding_guidelines (a path).
# Explicit null Linear fields with linear.not_applicable=true record a deliberate
# no-Linear project. Missing evidence stays unresolved, never a guessed mapping.
# Canonical remote identity is checked against the observed clone origin. Local
# identities name an existing Git repository, not a fabricated remote. The
# registry/parser and delivery policy owners remain fm-project-lib.sh and
# fm-project-mode.sh. A missing clone alone never proves a stale registration;
# retirement requires separate evidence and the project-management removal path.
# --check prints the inventory and exits 3 while any identity remains unresolved
# or evidence names an unregistered project. Use it before a policy cutover,
# not as a new gate on live work that already has issued instructions.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-project-lib.sh
. "$SCRIPT_DIR/fm-project-lib.sh"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
MAPPINGS="${FM_DATA_OVERRIDE:-$FM_HOME/data}/project-mappings.json"
CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mappings) [ "$#" -ge 2 ] || exit 2; MAPPINGS=$2; shift ;;
    --check) CHECK=1 ;;
    --help|-h) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) printf 'fm-project-inventory: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
REGISTRY=$(fm_project_registry_map_json)
export FM_HOME
python3 - "$SCRIPT_DIR" "$MAPPINGS" "$REGISTRY" "$CHECK" <<'PY'
import json, os, pathlib, re, socket, subprocess, sys, urllib.parse
scripts, mapping_path, registry, check = sys.argv[1:]
registry = json.loads(registry)
path = pathlib.Path(mapping_path)
try:
    mappings = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(mappings, dict):
        raise ValueError('mapping evidence must be an object keyed by project')
except (ValueError, OSError) as error:
    sys.exit(f'fm-project-inventory: cannot read mapping evidence: {error}')
projects = pathlib.Path(os.environ.get('FM_PROJECTS_OVERRIDE', os.environ['FM_HOME'] + '/projects'))
def git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None
def remote_identity(value):
    if not value:
        return None
    # Credentials and query parameters never belong in inventory output.
    match = re.fullmatch(r'(?:[^/@]+@)?([^/:]+):(.+)', value)
    if match and '://' not in value:
        host, repo = match.groups()
    else:
        parsed = urllib.parse.urlsplit(value)
        host, repo = parsed.hostname, parsed.path.lstrip('/')
    if not host or not repo:
        return None
    return 'https://' + host.lower() + '/' + repo.removesuffix('.git').rstrip('/')
def is_repository_root(repo):
    top = git(repo, 'rev-parse', '--show-toplevel')
    return top is not None and pathlib.Path(top).resolve() == pathlib.Path(repo).resolve()
rows = []
for name, registration in registry.items():
    evidence = mappings.get(name, {})
    if not isinstance(evidence, dict):
        sys.exit(f'fm-project-inventory: invalid evidence for {name}')
    clone = projects / name
    gaps = []
    clone_is_repo = clone.is_dir() and is_repository_root(clone)
    observed = remote_identity(git(clone, 'remote', 'get-url', 'origin')) if clone_is_repo else None
    canonical = evidence.get('canonical_repository')
    if not canonical:
        gaps.append('canonical_repository')
    elif '://' in canonical or re.match(r'[^/]+@[^:]+:', canonical):
        if remote_identity(canonical) != observed:
            gaps.append('canonical_repository_mismatch')
        canonical = remote_identity(canonical)
    elif not pathlib.Path(canonical).is_absolute() or not is_repository_root(canonical):
        gaps.append('canonical_repository_unverified')
    host = evidence.get('canonical_host')
    if not host:
        gaps.append('canonical_host')
    linear = evidence.get('linear', {})
    if not isinstance(linear, dict):
        sys.exit(f'fm-project-inventory: invalid Linear evidence for {name}')
    if linear.get('not_applicable') is not True:
        for field in ('workspace', 'team', 'project', 'ticket_rule'):
            if not linear.get(field):
                gaps.append('linear.' + field)
    guide = evidence.get('coding_guidelines')
    if not guide:
        gaps.append('coding_guidelines')
    elif not (clone / guide).is_file():
        gaps.append('coding_guidelines_unverified')
    mode = subprocess.run([scripts + '/fm-project-mode.sh', '--raw', name], capture_output=True, text=True)
    if mode.returncode != 0:
        sys.exit(f'fm-project-inventory: cannot read delivery posture for {name}')
    delivery, yolo = mode.stdout.strip().split()
    if not clone.is_dir():
        gaps.append('local_clone')
    elif not clone_is_repo:
        gaps.append('local_clone_not_repository')
    if not registration['tokens']:
        gaps.append('subprojects')
    rows.append(dict(project=name, canonical_repository=canonical, canonical_host=host,
                     observed_repository=observed, observed_host=socket.gethostname(),
                     clone=str(clone), linear=linear, subprojects=registration['tokens'],
                     coding_guidelines=guide, delivery_mode=delivery, yolo=yolo,
                     unresolved=gaps, retirement_candidate=False))
print(json.dumps(dict(schema='fm-project-inventory.v1', projects=rows,
                      unregistered_evidence=sorted(set(mappings) - set(registry))), indent=2))
if check == '1' and (any(row['unresolved'] for row in rows) or set(mappings) - set(registry)):
    sys.exit(3)
PY
