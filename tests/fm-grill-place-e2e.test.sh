#!/usr/bin/env bash
# tests/fm-grill-place-e2e.test.sh - real-herdr acceptance test for per-project
# grill packing (bin/fm-grill-place.sh, bin/fm-grill-lib.sh).
#
# The captain's rule is two grills per tab, packed in pairs, a new tab per new
# pair (data/captain.md "Grill lane"). This suite drives the real helper against
# the real herdr binary in a private lab session (never the captain's `default`)
# and asserts the shape a captain sees after four placements:
#
#   grill 1 -> the tab and pane herdr seeds the new workspace with
#   grill 2 -> a split in that same tab
#   grill 3 -> a new tab, in the same workspace
#   grill 4 -> a split in that new tab, beside the third grill
#
# It also plants a foreign, untagged workspace first, because that is the shape
# of a real session and the lookup must neither adopt it nor trip over it.
#
# Safety (tests/herdr-test-safety.sh): the isolated lab session is created and
# torn down only through bin/fm-herdr-lab.sh's guarded paths, which refuse the
# default session and verify the fleet-state tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup_all
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || {
  echo "skip: herdr not found"
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found (required by the herdr adapter)"
  exit 0
}

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
SESSION="fm-lab-grill-place-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-grill-place-e2e.XXXXXX")

cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

# provision, not prepare: the lab session's own server must be running
# before the helper, which never starts one, is asked to place anything.
fm_herdr_lab_provision "$SESSION" || fail "could not provision the isolated herdr lab session"

mkdir -p "$SCRATCH/data"
cat > "$SCRATCH/data/projects.md" <<'EOF'
# Projects

- mono [local-only] subprojects=alpha,beta - Org/mono
EOF

place() {
  FM_HOME="$SCRATCH" "$ROOT/bin/fm-grill-place.sh" mono --token alpha \
    --cwd "$SCRATCH" --session "$SESSION"
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
tabs_in() { herdr tab list --workspace "$1" --session "$SESSION"; }
panes_in() { herdr pane list --workspace "$1" --session "$SESSION"; }
tab_count() { tabs_in "$1" | jq -r '.result.tabs? // [] | length'; }
panes_of_tab() { panes_in "$1" | jq -r --arg t "$2" '[.result.panes[]? | select(.tab_id == $t)] | length'; }
grills_of_tab() {
  panes_in "$1" | jq -r --arg t "$2" \
    '[.result.panes[]? | select(.tab_id == $t and ((.tokens // {}).kind // "") == "grill")] | length'
}

# A foreign workspace with no tokens at all, exactly like the firstmate
# workspace in a real session.
herdr workspace create --cwd "$SCRATCH" --label firstmate --no-focus --session "$SESSION" >/dev/null \
  || fail "could not create the foreign workspace"

# --- grill 1: the seeded tab and pane take it -------------------------------

out=$(place) || fail "the first grill must be placed: $out"
WS=$(field "$out" workspace)
T1=$(field "$out" tab)
P1=$(field "$out" pane)
case "$(field "$out" placement)" in
fill\ *) ;;
*) fail "the first grill must fill the seeded pane, not open a tab: $out" ;;
esac
[ -n "$WS" ] && [ -n "$T1" ] && [ -n "$P1" ] || fail "the first placement reported no endpoint: $out"
[ "$(tab_count "$WS")" = 1 ] || fail "the first grill must leave the workspace with one tab"
[ "$(panes_of_tab "$WS" "$T1")" = 1 ] || fail "the first grill must hold its tab alone"
[ "$(grills_of_tab "$WS" "$T1")" = 1 ] || fail "the first grill's pane must be tagged as a grill"
[ "$(tabs_in "$WS" | jq -r --arg t "$T1" '.result.tabs[]? | select(.tab_id == $t) | .label')" = "grill-alpha" ] \
  || fail "the adopted tab must carry the grill label"
pass "the first grill takes the workspace herdr seeded and is tagged there"

# --- grill 2: split into that same tab --------------------------------------

out=$(place) || fail "the second grill must be placed: $out"
case "$(field "$out" placement)" in
split\ *) ;;
*) fail "the second grill must split the first grill's tab: $out" ;;
esac
[ "$(field "$out" workspace)" = "$WS" ] || fail "the second grill must stay in the project's grill workspace: $out"
[ "$(field "$out" tab)" = "$T1" ] || fail "the second grill must join the first grill's tab: $out"
[ "$(tab_count "$WS")" = 1 ] || fail "the second grill must not add a tab"
[ "$(panes_of_tab "$WS" "$T1")" = 2 ] || fail "the first tab must hold two grills"
[ "$(grills_of_tab "$WS" "$T1")" = 2 ] || fail "both panes of the first tab must be tagged as grills"
pass "a second grill is split into the same tab as the first"

# --- grill 3: a new tab in the same workspace -------------------------------

out=$(place) || fail "the third grill must be placed: $out"
T2=$(field "$out" tab)
[ "$(field "$out" placement)" = "new-tab" ] || fail "the third grill must open a new tab: $out"
[ "$(field "$out" workspace)" = "$WS" ] || fail "the third grill must stay in the project's grill workspace: $out"
[ "$(tab_count "$WS")" = 2 ] || fail "the third grill must leave the workspace with two tabs"
[ "$(panes_of_tab "$WS" "$T2")" = 1 ] || fail "the third grill must hold the new tab alone"
pass "a third grill opens a new tab once the first tab holds two"

# --- grill 4: beside the third ----------------------------------------------

out=$(place) || fail "the fourth grill must be placed: $out"
case "$(field "$out" placement)" in
split\ *) ;;
*) fail "the fourth grill must pack beside the third: $out" ;;
esac
[ "$(field "$out" tab)" = "$T2" ] || fail "the fourth grill must join the third grill's tab: $out"
[ "$(tab_count "$WS")" = 2 ] || fail "the fourth grill must not add a third tab"
[ "$(panes_of_tab "$WS" "$T2")" = 2 ] || fail "the second tab must hold two grills"
[ "$(grills_of_tab "$WS" "$T2")" = 2 ] || fail "both panes of the second tab must be tagged as grills"
pass "a fourth grill packs beside the third, two grills to a tab"

# --- the foreign workspace is untouched -------------------------------------

WORKSPACES=$(herdr workspace list --session "$SESSION")
[ "$(printf '%s' "$WORKSPACES" | jq -r '[.result.workspaces[]? | select(.label == "Mono · Grill")] | length')" = 1 ] \
  || fail "the grills must live in exactly one workspace: $WORKSPACES"
FOREIGN=$(printf '%s' "$WORKSPACES" | jq -r '.result.workspaces[]? | select(.label == "firstmate") | .workspace_id')
[ -n "$FOREIGN" ] || fail "the foreign workspace disappeared: $WORKSPACES"
[ "$FOREIGN" != "$WS" ] || fail "the grills must not be placed in the foreign workspace"
[ "$(tab_count "$FOREIGN")" = 1 ] || fail "the foreign workspace must keep its own single tab"
[ "$(grills_of_tab "$FOREIGN" "$(tabs_in "$FOREIGN" | jq -r '.result.tabs[0].tab_id')")" = 0 ] \
  || fail "the foreign workspace must hold no grill"
pass "the grills stay in one project workspace and never touch a foreign one"

trap - EXIT
cleanup_all
echo "ALL TESTS PASSED"
