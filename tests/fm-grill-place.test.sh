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
  export FM_TEST_HERDR_WORKSPACE_CREATE='{"result":{"workspace":{"workspace_id":"wG"},"tab":{"tab_id":"wG:t1"}}}'
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

# Only the lowest-numbered tab with a free slot is reused; a workspace whose
# tabs are full takes a new tab; an empty workspace is a new tab.
[ "$(fm_grill_plan_tab '{"result":{"tabs":[{"tab_id":"w:t2","number":2,"pane_count":1},{"tab_id":"w:t1","number":1,"pane_count":0}]}}')" = "reuse w:t1" ] \
  || fail "the lowest-numbered tab with room must be reused"
[ "$(fm_grill_plan_tab '{"result":{"tabs":[{"tab_id":"w:t1","number":1,"pane_count":2},{"tab_id":"w:t2","number":2,"pane_count":2}]}}')" = "new-tab" ] \
  || fail "a workspace whose every tab holds two grills needs a new tab"
[ "$(fm_grill_plan_tab '{"result":{"tabs":[{"tab_id":"w:t1","number":1,"pane_count":2},{"tab_id":"w:t2","number":2,"pane_count":1}]}}')" = "reuse w:t2" ] \
  || fail "a later tab with room must still be reused"
[ "$(fm_grill_plan_tab '{"result":{"tabs":[]}}')" = "new-tab" ] \
  || fail "an empty workspace needs its first tab"
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

herdr_world '{"result":{"workspaces":[]}}' '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
out=$(place --token alpha) || fail "a fresh grill placement must succeed: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "fresh placement workspace: $out"
[ "$(out_field "$out" label)" = "Mono · Grill" ] || fail "fresh placement label: $out"
[ "$(out_field "$out" tab)" = "wG:t2" ] || fail "fresh placement tab: $out"
[ "$(out_field "$out" pane)" = "wG:p2" ] || fail "fresh placement pane: $out"
[ "$(out_field "$out" token)" = alpha ] || fail "fresh placement token: $out"
[ "$(out_field "$out" token_source)" = explicit ] || fail "fresh placement token source: $out"
[ "$(out_field "$out" placement)" = new-tab ] || fail "fresh placement plan: $out"
log_contains "workspace create --cwd $TMP_ROOT --label Mono · Grill --no-focus --session test"
log_contains "workspace report-metadata wG --source firstmate --token project=alpha --token kind=grill --session test"
log_contains "tab create --workspace wG --cwd $TMP_ROOT --label grill-alpha --no-focus --session test"
log_contains "pane report-metadata wG:p2 --source firstmate --token project=alpha --token kind=grill --session test"
log_lacks "pane split"
pass "a project with no grill workspace gets one labelled and tagged"

# --- reuse within the existing workspace ------------------------------------

herdr_world \
  '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":1}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1"}]}}'
out=$(place --token alpha) || fail "reusing an existing grill tab must succeed: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "reuse workspace: $out"
[ "$(out_field "$out" tab)" = "wG:t1" ] || fail "reuse tab: $out"
[ "$(out_field "$out" pane)" = "wG:p9" ] || fail "reuse pane: $out"
[ "$(out_field "$out" placement)" = "reuse wG:t1" ] || fail "reuse plan: $out"
log_lacks "workspace create"
log_lacks "tab create"
log_contains "pane split --pane wG:p1 --direction right --cwd $TMP_ROOT --session test"
log_contains "pane report-metadata wG:p9 --source firstmate --token project=alpha --token kind=grill --session test"
pass "a second grill joins the existing tab and is tagged"

# --- a full tab takes a new tab in the same workspace ------------------------

herdr_world \
  '{"result":{"workspaces":[{"label":"Mono · Grill","tokens":{"project":"alpha"},"workspace_id":"wG"}]}}' \
  '{"result":{"tabs":[{"tab_id":"wG:t1","number":1,"pane_count":2}]}}' \
  '{"result":{"panes":[{"tab_id":"wG:t1","pane_id":"wG:p1"},{"tab_id":"wG:t1","pane_id":"wG:p2"}]}}'
out=$(place --token alpha) || fail "a third grill must take a new tab: $out"
[ "$(out_field "$out" placement)" = new-tab ] || fail "full-tab plan: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "a full tab must not move the grill to another workspace: $out"
log_lacks "workspace create"
log_lacks "pane split"
log_contains "tab create --workspace wG --cwd $TMP_ROOT --label grill-alpha --no-focus --session test"
pass "a third grill opens a new tab in the same grill workspace"

# --- never the firstmate workspace ------------------------------------------

herdr_world \
  '{"result":{"workspaces":[{"label":"firstmate","tokens":{},"workspace_id":"wF"}]}}' \
  '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
out=$(place --token alpha) || fail "placement beside a firstmate workspace must succeed: $out"
[ "$(out_field "$out" workspace)" = wG ] || fail "placement must create its own workspace: $out"
log_lacks "wF"
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
[ "$(out_field "$out" placement)" = new-tab ] || fail "a dry run must still report its plan: $out"
pass "a dry run prints the placement commands and changes nothing"

echo "ALL TESTS PASSED"
