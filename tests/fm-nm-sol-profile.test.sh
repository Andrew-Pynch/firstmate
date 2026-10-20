#!/usr/bin/env bash
# An opt-in pin cannot replace the operator's existing gate or add another reviewer.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(fm_test_tmproot fm-nm-sol-profile)
mkdir -p "$root/operator"
printf 'agent: claude\n' > "$root/operator/config.yaml"
cp "$root/operator/config.yaml" "$root/before.yaml"
rc=0
"$ROOT/bin/fm-nm-sol-profile.sh" --home "$root/operator" --omp /bin/true > "$root/out" 2> "$root/err" || rc=$?
[ "$rc" -ne 0 ] || fail 'existing gate home was replaced'
cmp "$root/before.yaml" "$root/operator/config.yaml" || fail 'existing gate configuration changed'
"$ROOT/bin/fm-nm-sol-profile.sh" --home "$root/opt-in" --omp /bin/true --effort high > "$root/out"
# JSON is YAML-compatible; inspect the actual public profile, not launcher source.
python3 - "$root/opt-in" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
c = json.loads((home / 'config.yaml').read_text())
assert c['agent'] == 'pi'
assert c['agent_config']['pi'] == {'model':'openai-codex/gpt-6.1-sol','effort':'high'}
assert set(c['review_agents']) == {'reviewer','fixer'}
assert c['review_agents']['reviewer'] == c['review_agents']['fixer'] == {'agent':'pi','model':'openai-codex/gpt-6.1-sol','effort':'high'}
assert 'agent_args_override' not in c
assert pathlib.Path(c['agent_path_override']['pi']).is_relative_to(home)
assert home.stat().st_mode & 0o777 == 0o700
PY
rc=0
"$ROOT/bin/fm-nm-sol-profile.sh" --home "$root/opt-in" --omp /bin/true > "$root/out" 2> "$root/err" || rc=$?
[ "$rc" -ne 0 ] || fail 'profile retry replaced an initialized gate home'
cmp "$root/before.yaml" "$root/operator/config.yaml" || fail 'creating an opt-in changed the operator default'
rc=0
"$ROOT/bin/fm-nm-sol-profile.sh" --home "$root/invalid" --omp /bin/true --effort bogus > "$root/out" 2> "$root/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$root/invalid" ] || fail 'invalid model effort left a half-created profile'
pass 'opt-in has one reviewer model, same fixer and gate steps, no native model override, and isolated state'
