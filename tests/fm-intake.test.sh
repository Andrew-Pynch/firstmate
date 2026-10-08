#!/usr/bin/env bash
# Behavior tests for intake routing by what is still undecided: the record
# bin/fm-intake.sh leaves on the item, the captain grill it puts behind an open
# choice, the research it refuses to guess past, and the one started line a
# request is allowed to announce.
#
# The rule itself is owned by bin/fm-intake-lib.sh and stated for the agent in
# AGENTS.md section 7. These tests drive the command the way firstmate does and
# read back only what a consumer of the record sees: the command's own stdout,
# the note the backlog reports for the item, and the captain hold it reports.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() { # <name> <request-id>...
  local name=$1 home id
  shift
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  for id in "$@"; do
    (cd "$home" && tasks-axi add "$id" "request $id" --repo firstmate --queue >/dev/null) \
      || fail "could not seed request $id"
  done
  printf '%s\n' "$home"
}

# Run the command the way firstmate does. INTAKE_OUT is stdout alone, which is
# the captain's started line and nothing else; INTAKE_ERR is what went wrong.
INTAKE_OUT=
INTAKE_ERR=
INTAKE_RC=0
intake() { # <home> <args...>
  local home=$1
  shift
  INTAKE_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INTAKE" "$@" 2>"$TMP_ROOT/intake.stderr")
  INTAKE_RC=$?
  INTAKE_ERR=$(cat "$TMP_ROOT/intake.stderr")
  return 0
}

row_field() { # <home> <id> <field>
  (cd "$1" && tasks-axi show "$2" 2>/dev/null | sed -n "s/^  $3: //p" | head -1)
}

# The item's note as the backlog reports it. A one-line note arrives bare and a
# several-line note arrives JSON-escaped on one line, so containment is the
# useful assertion here and the route's own `show` output is what gets counted.
row_body() { # <home> <id>
  (cd "$1" && tasks-axi show "$2" --full 2>/dev/null | sed -n 's/^  body: //p' | head -1)
}

# --- the two routes ---------------------------------------------------------

# A request whose outcome, acceptance, and authority are already explicit starts
# work: no captain round, no hold, and no announcement beyond the one started
# line it is due.
test_a_scoped_request_is_delegated_without_a_captain_round() {
  local home
  home=$(make_home delegate scoped-1)
  intake "$home" route scoped-1 --reason "the README fix is scoped already"
  expect_code 0 "$INTAKE_RC" "a scoped request is routed"
  assert_equals "" "$INTAKE_OUT" "a route with no started line still announced something"
  assert_equals "no" "$(row_field "$home" scoped-1 held)" \
    "a delegate route held the request for the captain"
  assert_equals "no" "$(row_field "$home" scoped-1 blocked)" \
    "a delegate route blocked the request"
  intake "$home" show scoped-1
  expect_code 0 "$INTAKE_RC" "the recorded route is readable"
  assert_equals "Intake route: delegate - the README fix is scoped already" "$INTAKE_OUT" \
    "the recorded item does not name the route and its reason"
  pass "a scoped request is delegated without a captain round"
}

# The open product choice IS the route: it is what makes the item a grill, and a
# grill is a task held for the captain rather than a note nobody is waiting on.
test_an_open_product_choice_is_held_as_a_captain_grill() {
  local home
  home=$(make_home grill layout-1)
  intake "$home" route layout-1 --reason "the captain must pick the layout" \
    --open product-judgment
  expect_code 0 "$INTAKE_RC" "an open product choice routes the request"
  assert_equals "yes" "$(row_field "$home" layout-1 held)" \
    "an open product choice did not hold the request"
  assert_equals "captain" "$(row_field "$home" layout-1 hold_kind)" \
    "the hold is not the captain hold"
  assert_equals "the captain must pick the layout" "$(row_field "$home" layout-1 hold_reason)" \
    "the hold does not carry the route's reason"
  intake "$home" show layout-1
  assert_contains "$INTAKE_OUT" \
    "Intake route: grill [product-judgment] - the captain must pick the layout" \
    "the grill route is not recorded on the item"
  pass "an open product choice is held as a captain grill"
}

# The recorded item is the durable half of the decision: it names the route and
# the one-line reason, and a re-route replaces that line rather than stacking a
# second one beside it.
test_the_recorded_item_names_the_route_and_its_reason() {
  local home
  home=$(make_home record record-1)
  intake "$home" route record-1 --reason "first reading" --open protected-state
  expect_code 0 "$INTAKE_RC" "an open choice is routed"
  intake "$home" route record-1 --reason "the captain has to release the token" \
    --open authorization --open product-judgment
  expect_code 0 "$INTAKE_RC" "a re-routed request is recorded"
  intake "$home" show record-1
  assert_equals "1" "$(printf '%s\n' "$INTAKE_OUT" | grep -c '^Intake route:')" \
    "re-routing stacked a second route line"
  assert_contains "$INTAKE_OUT" \
    "Intake route: grill [product-judgment, authorization] - the captain has to release the token" \
    "the item does not name the standing route, its classes, and its reason"
  assert_not_contains "$INTAKE_OUT" "first reading" "the superseded reason is still recorded"
  pass "the recorded item names the route and its reason"
}

# --- the one started line ---------------------------------------------------

# One request announces one start. The item records that the line was emitted,
# so neither researching more nor growing the request into tickets can produce a
# second one.
test_one_started_line_per_request() {
  local home
  home=$(make_home started started-1)
  intake "$home" route started-1 --reason "the fix is scoped" \
    --started "started: the README fix is under way"
  expect_code 0 "$INTAKE_RC" "a delegate route carrying a started line"
  assert_equals "started: the README fix is under way" "$INTAKE_OUT" \
    "the started line was not emitted verbatim"
  intake "$home" show started-1
  assert_equals "1" "$(printf '%s\n' "$INTAKE_OUT" | grep -c '^Intake started:')" \
    "the item did not record exactly one started line"

  intake "$home" route started-1 --reason "the fix is scoped and reviewed" \
    --started "started: the README fix is under way"
  expect_code 0 "$INTAKE_RC" "a re-route after more work"
  assert_equals "" "$INTAKE_OUT" "the request announced a second started line"
  intake "$home" show started-1
  assert_equals "1" "$(printf '%s\n' "$INTAKE_OUT" | grep -c '^Intake started:')" \
    "the item records more than one started line"
  assert_contains "$INTAKE_OUT" "Intake started: started: the README fix is under way" \
    "the started line was dropped by the re-route"
  pass "one started line per request"
}

# A request waiting on the captain has not started, so announcing one would be a
# claim about work that is not happening.
test_a_grill_route_never_announces_a_start() {
  local home
  home=$(make_home no-start pending-1)
  intake "$home" route pending-1 --reason "the captain must authorize the deploy" \
    --open authorization --started "started: the deploy is under way"
  expect_code 2 "$INTAKE_RC" "a grill route refuses a started line"
  assert_contains "$INTAKE_ERR" "has not started" "the refusal does not say why"
  assert_equals "" "$INTAKE_OUT" "a refused route announced a start"
  assert_equals "no" "$(row_field "$home" pending-1 held)" "the refused request was still routed"
  intake "$home" show pending-1
  expect_code 1 "$INTAKE_RC" "the refused request was still recorded"
  pass "a grill route never announces a start"
}

# --- facts are researched, never guessed ------------------------------------

# A classification resting on an unestablished fact is not a route, it is a
# question for the code or the docs: it is refused rather than guessed at.
test_an_unestablished_fact_is_researched_before_classifying() {
  local home
  home=$(make_home research unknown-1)
  intake "$home" route unknown-1 --reason "the API is already scoped" \
    --fact "which API version the deploy pins"
  expect_code 3 "$INTAKE_RC" "routing on an unestablished fact"
  assert_contains "$INTAKE_ERR" "which API version the deploy pins" \
    "the refusal does not name the fact to research"
  assert_equals "no" "$(row_field "$home" unknown-1 held)" "an unresearched request was held"
  intake "$home" show unknown-1
  expect_code 1 "$INTAKE_RC" "an unresearched request was still recorded"
  pass "an unestablished fact is researched before classifying"
}

# --- refusals leave the item alone ------------------------------------------

test_bad_input_is_refused_without_touching_the_item() {
  local home
  home=$(make_home refused bad-1)
  intake "$home" route bad-1 --reason "an open choice" --open product-feel
  expect_code 2 "$INTAKE_RC" "an unspellable open-decision class"
  intake "$home" route bad-1 --reason "   "
  expect_code 2 "$INTAKE_RC" "a blank reason"
  intake "$home" route bad-1 --reason "the captain picks a layout (A or B)"
  expect_code 2 "$INTAKE_RC" "a reason carrying the hold tags' parentheses"
  intake "$home" route missing-1 --reason "a scoped fix"
  expect_code 1 "$INTAKE_RC" "an item this home has no row for"
  (cd "$home" && tasks-axi add closed-1 "request closed-1" --repo firstmate --queue >/dev/null) \
    || fail "could not seed the closed request"
  (cd "$home" && tasks-axi "done" closed-1 >/dev/null) || fail "could not close the seeded request"
  intake "$home" route closed-1 --reason "a scoped fix"
  expect_code 1 "$INTAKE_RC" "a request that has already landed"
  assert_equals "no" "$(row_field "$home" bad-1 held)" "a refused route held the request anyway"
  intake "$home" show bad-1
  expect_code 1 "$INTAKE_RC" "a refused route was recorded anyway"
  assert_contains "$INTAKE_ERR" "no intake route is recorded" \
    "the empty read does not say what is missing"
  pass "bad input is refused without touching the item"
}

# --- routing beside another owner's record ----------------------------------

# The route is written onto an item other owners also write to, so it must not
# disturb a note an earlier pass left, nor the hold stamp the captain-hold owner
# writes when a re-route turns the request into a grill.
test_an_existing_note_and_hold_stamp_survive_routing() {
  local home body
  home=$(make_home coexist note-1)
  (cd "$home" && tasks-axi update note-1 --body "Existing note from an earlier pass." >/dev/null)
  intake "$home" route note-1 --reason "the fix is scoped" --started "started: the fix is under way"
  expect_code 0 "$INTAKE_RC" "routing beside an existing note"
  intake "$home" route note-1 --reason "the captain must release protected state" \
    --open protected-state
  expect_code 0 "$INTAKE_RC" "re-routing to a grill"
  body=$(row_body "$home" note-1)
  assert_contains "$body" "Existing note from an earlier pass." \
    "routing destroyed a note another pass had written"
  assert_contains "$body" "Captain hold set: " "the captain hold stamp is missing"
  assert_contains "$body" "Intake route: grill [protected-state] - the captain must release protected state" \
    "the standing route is not recorded"
  assert_contains "$body" "Intake started: started: the fix is under way" \
    "the started line that a re-route did not emit was dropped"
  pass "an existing note and hold stamp survive routing"
}

test_a_scoped_request_is_delegated_without_a_captain_round
test_an_open_product_choice_is_held_as_a_captain_grill
test_the_recorded_item_names_the_route_and_its_reason
test_one_started_line_per_request
test_a_grill_route_never_announces_a_start
test_an_unestablished_fact_is_researched_before_classifying
test_bad_input_is_refused_without_touching_the_item
test_an_existing_note_and_hold_stamp_survive_routing
