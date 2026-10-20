#!/usr/bin/env bash
# Inventory never guesses identity or changes delivery policy to fill a gap.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(fm_test_tmproot fm-project-inventory)
mkdir -p "$root/home/data" "$root/home/projects/alpha" "$root/home/config" "$root/home/state"
cat > "$root/home/data/projects.md" <<'EOF'
- alpha [no-mistakes-prod-only +yolo] subprojects=app,tools - remote project
- private [local-only] subprojects=private - local project
EOF
git -C "$root/home/projects/alpha" init -q
git -C "$root/home/projects/alpha" remote add origin git@github.com:Example/alpha.git
printf 'Follow this contribution guide.\n' > "$root/home/projects/alpha/CONTRIBUTING.md"
cat > "$root/mappings.json" <<'EOF'
{"alpha":{"canonical_repository":"https://github.com/Example/alpha","canonical_host":"fixture-host",
 "linear":{"workspace":"example","team":"APP","project":"project-uuid","ticket_rule":"https://linear.app/example/issue/APP-{number}"},
 "coding_guidelines":"CONTRIBUTING.md"}}
EOF
FM_HOME="$root/home" "$ROOT/bin/fm-project-inventory.sh" --mappings "$root/mappings.json" > "$root/out.json"
jq -e '.projects | length == 2 and any(.[]; .project == "alpha" and .unresolved == [] and .delivery_mode == "no-mistakes-prod-only" and .yolo == "on" and .subprojects == ["app","tools"]) and any(.[]; .project == "private" and (.unresolved | index("canonical_repository") != null) and .delivery_mode == "local-only" and .yolo == "off")' "$root/out.json" >/dev/null \
  || fail 'inventory guessed a missing mapping or flattened conditional delivery policy'
jq '.alpha.canonical_repository = "https://github.com/Example/wrong"' "$root/mappings.json" > "$root/wrong.json"
FM_HOME="$root/home" "$ROOT/bin/fm-project-inventory.sh" --mappings "$root/wrong.json" > "$root/out.json"
jq -e '.projects[] | select(.project == "alpha") | .unresolved | index("canonical_repository_mismatch") != null' "$root/out.json" >/dev/null \
  || fail 'inventory silently accepted a registry mapping for a different repository'
# A missing local clone is a gap, not authority to remove a registered project.
jq -e '.projects[] | select(.project == "private") | .retirement_candidate == false' "$root/out.json" >/dev/null \
  || fail 'missing clone was misclassified as a stale registration'
rc=0
FM_HOME="$root/home" "$ROOT/bin/fm-project-inventory.sh" --check --mappings "$root/wrong.json" > "$root/out.json" || rc=$?
[ "$rc" -eq 3 ] || fail 'unresolved identities were accepted by the policy-cutover check'
mkdir -p "$root/home/projects/alpha/not-a-repo"
jq --arg path "$root/home/projects/alpha/not-a-repo" '.alpha.canonical_repository = $path' "$root/mappings.json" > "$root/nested.json"
FM_HOME="$root/home" "$ROOT/bin/fm-project-inventory.sh" --mappings "$root/nested.json" > "$root/out.json"
jq -e '.projects[] | select(.project == "alpha") | .unresolved | index("canonical_repository_unverified") != null' "$root/out.json" >/dev/null \
  || fail 'a subdirectory inherited its parent Git identity as a canonical repository'
pass 'one mapping per registration, explicit identity gaps, origin mismatch and unchanged delivery posture'
