#!/usr/bin/env bash
# Behavior tests for per-project grill placement (bin/fm-grill-place.sh,
# bin/fm-grill-lib.sh).
#
# These are command-construction tests: a fake `herdr` records every call the
# helper makes, so the placement rule, the refuse-on-unresolved boundary, and
# the exact labels and colour tokens are verified without creating a workspace,
# tab, pane, or agent. The pure decision functions are exercised directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-grill-lib.sh
. "$ROOT/bin/fm-grill-lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found"
  exit 0
}

PLACE="$ROOT/bin/fm-grill-place.sh"
TMP_ROOT=$(fm_test_tmproot fm-grill-place)
DATA_DIR=$TMP_ROOT/data
mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/projects.md" <<'EOF'
# Projects

- mono [direct-PR +yolo] subprojects=alpha,beta - Org/mono
- solo [local-only] subprojects=solo - Org/solo
EOF

FAKEBIN=$(fm_fakebin "$TMP_ROOT/tools")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
case "${1:-}/${2:-}" in
  workspace/list) cat "$FM_TEST_HERDR_WORKSPACES" ;;
  workspace/create) printf '%s' "$FM_TEST_HERDR_WORKSPACE_CREATE" ;;
  workspace/report-metadata) : ;;
  tab/list) cat "$FM_TEST_HERDR_TABS" ;;
  tab/create) printf '%s' "$FM_TEST_HERDR_TAB_CREATE" ;;
  pane/list) cat "$FM_TEST_HERDR_PANES" ;;
  pane/split) printf '%s' "$FM_TEST_HERDR_SPLIT" ;;
  pane/report-metadata | pane/run) : ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr"

# Fresh per-case fake state; every field the fake reads is rewritten per case so
# one case's world can never leak into the next.
herdr_world() { # <workspaces-json> <tabs-json> <panes-json>
  export FM_TEST_HERDR_WORKSPACES=$TMP_ROOT/workspaces.json
  export FM_TEST_HERDR_TABS=$TMP_ROOT/tabs.json
  export FM_TEST_HERDR_PANES=$TMP_ROOT/panes.json
  # herdr seeds a new workspace with one default tab holding one idle pane, and
  # reports both in the create response; the fake models that exactly, because a
  # placement that ignores it consumes a grill slot with the seeded shell and
  # offsets every later pairing.
  export FM_TEST_HERDR_WORKSPACE_CREATE='{"result":{"workspace":{"workspace_id":"wG"},"tab":{"tab_id":"wG:t1","number":1,"pane_count":1},"root_pane":{"pane_id":"wG:p1"}}}'
  export FM_TEST_HERDR_TAB_CREATE='{"result":{"tab":{"tab_id":"wG:t2"},"root_pane":{"pane_id":"wG:p2"}}}'
  export FM_TEST_HERDR_SPLIT='{"result":{"pane":{"pane_id":"wG:p9"}}}'
  export FM_TEST_HERDR_LOG=$TMP_ROOT/herdr.log
  printf '%s' "$1" > "$FM_TEST_HERDR_WORKSPACES"
  printf '%s' "$2" > "$FM_TEST_HERDR_TABS"
  printf '%s' "$3" > "$FM_TEST_HERDR_PANES"
  : > "$FM_TEST_HERDR_LOG"
}

place() { # <extra-args...>
  PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_TEST_HERDR_LOG=$FM_TEST_HERDR_LOG "$PLACE" mono --session test --cwd "$TMP_ROOT" "$@"
}

log_contains() { # <substring>
  grep -qF -- "$1" "$FM_TEST_HERDR_LOG" || fail "herdr was never called with: $1
$(cat "$FM_TEST_HERDR_LOG")"
}
log_lacks() { # <substring>
  ! grep -qF -- "$1" "$FM_TEST_HERDR_LOG" || fail "herdr must not be called with: $1
$(cat "$FM_TEST_HERDR_LOG")"
}
out_field() { # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# --- the packing rule -------------------------------------------------------

# The decision comes from the workspace's live pane list. A pane counts as a
# grill only when its own kind=grill token says so, so an idle pane - the shell
# herdr seeds a new workspace with, or one opened by hand - is filled instead of
# being counted against the tab.
G='{"tab_id":"w:t1","pane_id":"w:p1","tokens":{"kind":"grill"}}'
G2='{"tab_id":"w:t1","pane_id":"w:p2","tokens":{"kind":"grill"}}'
IDLE='{"tab_id":"w:t1","pane_id":"w:p1"}'
TAB1='{"result":{"tabs":[{"tab_id":"w:t1","number":1,"pane_count":1}]}}'
TAB12='{"result":{"tabs":[{"tab_id":"w:t2","number":2,"pane_count":1},{"tab_id":"w:t1","number":1,"pane_count":2}]}}'

[ "$(fm_grill_plan_tab "$TAB1" "{\"result\":{\"panes\":[$IDLE]}}")" = "fill w:t1 w:p1" ] \
  || fail "the first grill fills the idle pane rather than splitting it"
[ "$(fm_grill_plan_tab "$TAB1" "{\"result\":{\"panes\":[$G]}}")" = "split w:t1 w:p1" ] \
  || fail "a second grill splits the pane the first one holds"
[ "$(fm_grill_plan_tab "$TAB1" "{\"result\":{\"panes\":[$G,$G2]}}")" = "new-tab" ] \
  || fail "a workspace whose every tab holds two grills needs a new tab"
[ "$(fm_grill_plan_tab "$TAB12" "{\"result\":{\"panes\":[$G,$G2,{\"tab_id\":\"w:t2\",\"pane_id\":\"w:p3\",\"tokens\":{\"kind\":\"grill\"}}]}}")" = "split w:t2 w:p3" ] \
  || fail "a later tab with room is used before a new tab"
[ "$(fm_grill_plan_tab "$TAB12" "{\"result\":{\"panes\":[$G,$G2,{\"tab_id\":\"w:t2\",\"pane_id\":\"w:p3\"}]}}")" = "fill w:t2 w:p3" ] \
  || fail "an idle pane in a later tab is filled"
[ "$(fm_grill_plan_tab '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}')" = "new-tab" ] \
  || fail "a workspace with no tabs needs its first tab"
[ "$(fm_grill_plan_tab "$TAB1" '{"result":{"panes":[{"tab_id":"w:t1","pane_id":"w:p1","tokens":{"kind":"other"}}]}}')" = "fill w:t1 w:p1" ] \
  || fail "another kind's token must not count as a grill"
# A pane that reports a registered agent is never written into: the grill goes
# to a new tab instead, and the same tab still packs a second grill beside the
# agent-free one it already has.
[ "$(fm_grill_plan_tab "$TAB1" '{"result":{"panes":[{"tab_id":"w:t1","pane_id":"w:p1","agent_status":"idle"}]}}')" = "new-tab" ] \
  || fail "a pane holding an agent must not be filled"
[ "$(fm_grill_plan_tab "$TAB1" "{\"result\":{\"panes\":[$G,{\"tab_id\":\"w:t1\",\"pane_id\":\"w:p3\",\"agent_status\":\"working\"}]}}")" = "split w:t1 w:p1" ] \
  || fail "a tab with a grill and an agent-held pane still splits its grill"
# Two grills is the captain's bound: the third goes to a new tab, and the
# second still shares the first.
[ "$FM_GRILL_PER_TAB" = "2" ] || fail "the per-tab grill bound must stay 2"
pass "grills pack two per tab and only then take a new tab"

# The grill workspace label is display text built from the registered name; the
# colour token is the identity a lookup matches on.
[ "$(fm_grill_workspace_label mono)" = "Mono · Grill" ] || fail "grill label wrong"
[ "$(fm_grill_workspace_find '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' alpha 'Mono · Grill')" = "wG" ] \
  || fail "a matching grill workspace must be found"
[ -z "$(fm_grill_workspace_find '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"beta"},"workspace_id":"wG"}]}}' alpha 'Mono · Grill')" ] \
  || fail "a workspace with another project's token must not be adopted"
[ -z "$(fm_grill_workspace_find '{"result":{"workspaces":[{"label":"firstmate","tokens":{},"workspace_id":"wF"}]}}' alpha 'Mono · Grill')" ] \
  || fail "the firstmate workspace must never be adopted"
pass "a project's grill workspace is found by label and colour token"

# --- fresh placement --------------------------------------------------------

# A project with no grill workspace gets one, and the tab and pane herdr seeded
# it with become this first grill's own: no split, no extra tab, and the seeded
# pane is tagged so the next placement counts it as a grill.
herdr_world '{"result":{"workspaces":[]}}' '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
out=$(place --token alpha) || fail "a fresh grill placement must succeed: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "fresh placement workspace: $out"
[ "$(out_field "$out" label)" = "Mono · Grill" ] || fail "fresh placement label: $out"
[ "$(out_field "$out" tab)" = "wG:t1" ] || fail "fresh placement tab: $out"
[ "$(out_field "$out" pane)" = "wG:p1" ] || fail "fresh placement pane: $out"
[ "$(out_field "$out" token)" = alpha ] || fail "fresh placement token: $out"
[ "$(out_field "$out" token_source)" = explicit ] || fail "fresh placement token source: $out"
[ "$(out_field "$out" placement)" = "fill wG:t1 wG:p1" ] || fail "fresh placement plan: $out"
log_contains "workspace create --cwd $TMP_ROOT --label Mono · Grill --no-focus --session test"
log_contains "workspace report-metadata wG --source firstmate --token project=alpha --token kind=grill --session test"
log_contains "tab rename wG:t1 grill-alpha --session test"
log_contains "pane report-metadata wG:p1 --source firstmate --token project=alpha --token kind=grill --session test"
log_lacks "pane split"
log_lacks "tab create"
pass "a project with no grill workspace gets one, and its seeded pane takes the grill"

# --- a second grill shares that tab -----------------------------------------

herdr_world \
  '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":1}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1","tokens":{"kind":"grill"}}]}}'
out=$(place --token alpha) || fail "a second grill must join the first tab: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "second grill workspace: $out"
[ "$(out_field "$out" tab)" = "wG:t1" ] || fail "second grill tab: $out"
[ "$(out_field "$out" pane)" = "wG:p9" ] || fail "second grill pane: $out"
[ "$(out_field "$out" placement)" = "split wG:t1 wG:p1" ] || fail "second grill plan: $out"
log_lacks "workspace create"
log_lacks "tab create"
log_contains "pane split --pane wG:p1 --direction right --cwd $TMP_ROOT --session test"
log_contains "pane report-metadata wG:p9 --source firstmate --token project=alpha --token kind=grill --session test"
pass "a second grill is split into the first grill's tab and tagged"

# --- an idle pane is filled, never split ------------------------------------

# The pane a workspace was seeded with is idle until a grill takes it. Counting
# it as occupied was what pushed the second grill into a tab of its own.
herdr_world \
  '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":1}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1"}]}}'
out=$(place --token alpha) || fail "an idle pane must be fillable: $out"
[ "$(out_field "$out" tab)" = "wG:t1" ] || fail "idle-pane tab: $out"
[ "$(out_field "$out" pane)" = "wG:p1" ] || fail "idle-pane pane: $out"
[ "$(out_field "$out" placement)" = "fill wG:t1 wG:p1" ] || fail "idle-pane plan: $out"
log_lacks "workspace create"
log_lacks "tab create"
log_lacks "pane split"
log_contains "pane report-metadata wG:p1 --source firstmate --token project=alpha --token kind=grill --session test"
pass "an idle pane in the grill workspace takes the grill instead of being split"

# --- a full tab takes a new tab in the same workspace ------------------------

herdr_world \
  '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":2}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1","tokens":{"kind":"grill"}},{"tab_id":"wG:t1","pane_id":"wG:p2","tokens":{"kind":"grill"}}]}}'
out=$(place --token alpha) || fail "a third grill must take a new tab: $out"
[ "$(out_field "$out" placement)" = new-tab ] || fail "full-tab plan: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "a full tab must not move the grill to another workspace: $out"
[ "$(out_field "$out" tab)" = "wG:t2" ] || fail "new-tab placement tab: $out"
[ "$(out_field "$out" pane)" = "wG:p2" ] || fail "new-tab placement pane: $out"
log_lacks "workspace create"
log_lacks "pane split"
log_contains "tab create --workspace wG --cwd $TMP_ROOT --label grill-alpha --no-focus --session test"
log_contains "pane report-metadata wG:p2 --source firstmate --token project=alpha --token kind=grill --session test"
pass "a third grill opens a new tab in the same grill workspace"

# --- never the firstmate workspace ------------------------------------------

# The firstmate workspace carries no tokens at all, which must not stop the
# lookup: reading it as an error would hide this project's own grill workspace
# and plant a second one beside it on every placement.
herdr_world \
  '{"result":{"workspaces":[{"label":"firstmate","workspace_id":"wF"},{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":1}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1","tokens":{"kind":"grill"}}]}}'
out=$(place --token alpha) || fail "placement beside a firstmate workspace must succeed: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "the project's own grill workspace must be found: $out"
log_lacks "wF"
log_lacks "workspace create"
pass "a grill is never placed in the firstmate workspace"

# --- refusals ---------------------------------------------------------------

herdr_world '{"result":{"workspaces":[]}}' '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
if err=$(PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA_DIR" \
  "$PLACE" unregistered --session test 2>&1); then
  fail "an unregistered project must refuse placement"
fi
case "$err" in
*'not a registered project'*) ;;
*) fail "the refusal must name the reason, got: $err" ;;
esac
[ ! -s "$FM_TEST_HERDR_LOG" ] || fail "a refused placement must not touch herdr"

if err=$(PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA_DIR" \
  "$PLACE" mono --token gamma --session test 2>&1); then
  fail "an undeclared sub-project token must refuse placement"
fi
case "$err" in
*'not declared for project'*) ;;
*) fail "the token refusal must name the declared tokens, got: $err" ;;
esac
[ ! -s "$FM_TEST_HERDR_LOG" ] || fail "a refused token must not touch herdr"
pass "an unresolvable project is refused loudly and never placed"

# --- dry run ----------------------------------------------------------------

herdr_world '{"result":{"workspaces":[]}}' '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
out=$(place --token alpha --dry-run 2>"$TMP_ROOT/dry.err") || fail "a dry run must succeed: $out"
[ ! -s "$FM_TEST_HERDR_LOG" ] || fail "a dry run must not call herdr"
grep -qF "herdr workspace create --cwd $TMP_ROOT --label Mono · Grill --no-focus --session test" "$TMP_ROOT/dry.err" \
  || fail "a dry run must print the commands it would run: $(cat "$TMP_ROOT/dry.err")"
grep -qF "herdr pane report-metadata <seeded-pane> --source firstmate --token project=alpha --token kind=grill --session test" "$TMP_ROOT/dry.err" \
  || fail "a dry run must print the tagging it would do: $(cat "$TMP_ROOT/dry.err")"
grep -qF "herdr tab rename <seeded-tab> grill-alpha --session test" "$TMP_ROOT/dry.err" \
  || fail "a dry run must print the tab label it would set: $(cat "$TMP_ROOT/dry.err")"
[ "$(out_field "$out" placement)" = "fill <seeded-tab> <seeded-pane>" ] || fail "a dry run must still report its plan: $out"
pass "a dry run prints the placement commands and changes nothing"

echo "ALL TESTS PASSED"
