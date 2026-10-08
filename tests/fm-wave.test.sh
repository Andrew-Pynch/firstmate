#!/usr/bin/env bash
# Behavior tests for the per-project wave computation: the next wave each
# project may dispatch, the layer a ticket sits in, and the gate that decides
# whether it may start now.
#
# The rule itself is owned by bin/fm-wave-lib.sh and stated for the agent in
# AGENTS.md section 7. These tests drive the command the way firstmate does -
# bin/fm-wave.sh over a real fixture home and its real fleet snapshot - and read
# back only what a consumer of the report sees: the lines it prints and the exit
# status that says whether anything is dispatchable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAVE="$ROOT/bin/fm-wave.sh"
TMP_ROOT=$(fm_test_tmproot fm-wave)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required to read the fleet snapshot)"; exit 0; }

# A home with an empty backlog and a registry naming the two projects these
# tests move between.
make_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$home/data/projects.md" <<'EOF'
# Projects

- firstmate [local-only +yolo] subprojects=fm - firstmate itself (added 2026-09-15)
- life [local-only] subprojects=life - private household repo (added 2026-09-12)
EOF
  printf '%s\n' "$home"
}

seed() { # <home> <id> <project>
  local home=$1 id=$2 project=$3
  (cd "$home" && tasks-axi add "$id" "ticket $id" --repo "$project" --queue >/dev/null) ||
    fail "could not seed $id"
}

start_task() { # <home> <id>
  (cd "$1" && tasks-axi start "$2" >/dev/null) || fail "could not start $2"
}

close_task() { # <home> <id>
  (cd "$1" && tasks-axi 'done' "$2" >/dev/null) || fail "could not close $2"
}

start_and_done() { # <home> <id>
  start_task "$1" "$2"
  close_task "$1" "$2"
}

hold_for_captain() { # <home> <id> <reason>
  (cd "$1" && tasks-axi hold "$2" --reason "$3" --kind captain >/dev/null) ||
    fail "could not hold $2"
}

block_on() { # <home> <id> <blocker>
  (cd "$1" && tasks-axi block "$2" --by "$3" >/dev/null) || fail "could not block $2 on $3"
}

# Hand-write one queued row, which is the only way to reach the shapes the
# backlog owner's own commands refuse: a dangling blocker edge whose blocker has
# been pruned, and a reply obligation.
append_queued_row() { # <home> <row>
  local home=$1 row=$2
  awk -v row="$row" '
    /^## Done/ && !placed { print row; print ""; placed = 1 }
    { print }
  ' "$home/data/backlog.md" > "$TMP_ROOT/backlog.tmp" || fail "could not rewrite the fixture backlog"
  mv "$TMP_ROOT/backlog.tmp" "$home/data/backlog.md"
}

WAVE_OUT=
WAVE_RC=0
wave() { # <home> <args...>
  local home=$1
  shift
  WAVE_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$WAVE" "$@" 2>"$TMP_ROOT/wave.stderr")
  WAVE_RC=$?
  return 0
}

# --- the two-project acceptance case ----------------------------------------

# One blocked ticket in one project leaves the other project's wave
# dispatchable: every project's graph is computed on its own, so no project ever
# waits on another project's unfinished ticket.
test_two_projects_dispatch_their_own_waves() {
  local home snap
  home=$(make_home two-projects)
  seed "$home" c-open firstmate
  seed "$home" c-blocked firstmate
  block_on "$home" c-blocked c-open
  seed "$home" d-ready life

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next over two projects"
  assert_contains "$WAVE_OUT" "project=life wave=1 start=d-ready" \
    "the second project's wave did not dispatch while the first project was blocked"
  assert_contains "$WAVE_OUT" "project=firstmate wave=1 start=c-open" \
    "the first project's own wave did not dispatch"
  assert_not_contains "$WAVE_OUT" "c-blocked" \
    "a ticket whose declared blocker has not landed was dispatchable"

  wave "$home" plan
  expect_code 0 "$WAVE_RC" "plan over two projects"
  assert_contains "$WAVE_OUT" "wave 2 c-blocked queued blocked-by:c-open" \
    "the blocked ticket is not reported as blocked in its own project"

  # A snapshot the caller already holds answers the same, so a heartbeat that
  # already ran the fleet view never pays for a second observation.
  snap="$TMP_ROOT/two-projects.json"
  (cd "$home" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$snap") ||
    fail "could not take the fixture snapshot"
  wave "$home" next --snapshot "$snap"
  expect_code 0 "$WAVE_RC" "next from a held snapshot"
  assert_contains "$WAVE_OUT" "project=life wave=1 start=d-ready" \
    "a held snapshot did not produce the same wave"

  pass "two projects dispatch their own waves"
}

# --- starting as soon as its own blockers land -------------------------------

# A ticket whose declared blockers have all landed starts with no manual step:
# the gate is read from the records, so the re-evaluation dispatches it.
test_a_ticket_starts_once_its_own_blockers_land() {
  local home
  home=$(make_home landed-blockers)
  seed "$home" a-done firstmate
  seed "$home" b-next firstmate
  block_on "$home" b-next a-done
  start_task "$home" a-done

  wave "$home" next
  expect_code 3 "$WAVE_RC" "next while the blocker has not landed"
  assert_contains "$WAVE_OUT" "none: no project has a dispatchable wave" \
    "an unlanded blocker was reported as a dispatchable wave"

  close_task "$home" a-done
  wave "$home" next
  expect_code 0 "$WAVE_RC" "next once the blocker landed"
  assert_contains "$WAVE_OUT" "project=firstmate wave=2 start=b-next" \
    "the ticket did not start once its declared blocker landed"

  wave "$home" plan
  assert_contains "$WAVE_OUT" "wave 2 b-next queued ready" \
    "the landed blocker's dependent is not the next layer of its project"

  pass "a ticket starts once its own blockers land"
}

# --- an unreviewed item holds only what declares it -------------------------

# An item waiting on the captain holds the tickets that declare it and nothing
# else: unrelated work in the same project, and every other project, still
# dispatches.
test_an_unreviewed_item_blocks_only_its_dependents() {
  local home
  home=$(make_home unreviewed)
  seed "$home" x-open firstmate
  hold_for_captain "$home" x-open "review the landed wave"
  seed "$home" y-dep firstmate
  block_on "$home" y-dep x-open
  seed "$home" z-other firstmate
  seed "$home" w-elsewhere life

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next beside an item waiting on the captain"
  assert_contains "$WAVE_OUT" "project=firstmate wave=1 start=z-other" \
    "unrelated work in the same project waited on the captain's review"
  assert_contains "$WAVE_OUT" "project=life wave=1 start=w-elsewhere" \
    "another project waited on the captain's review"
  assert_not_contains "$WAVE_OUT" "y-dep" \
    "a ticket whose declared blocker waits on the captain was dispatchable"

  wave "$home" plan
  assert_contains "$WAVE_OUT" "wave 1 x-open queued waiting-on-you" \
    "the item waiting on the captain is not reported as such"
  assert_contains "$WAVE_OUT" "wave 2 y-dep queued blocked-by:x-open" \
    "the dependent does not name the blocker it waits on"

  pass "an unreviewed item blocks only its dependents"
}

# --- a landed row never holds work again ------------------------------------

# An answered captain call records its resolution on a closed row, so a landed
# row clears its dependents whatever hold metadata it keeps: reading the hold
# alone would stall every dependent of an answered call forever.
test_a_landed_row_clears_its_dependents() {
  local home
  home=$(make_home answered-call)
  seed "$home" p-done firstmate
  start_and_done "$home" p-done
  hold_for_captain "$home" p-done "the answer is recorded on the closed row"
  seed "$home" q-dep firstmate
  block_on "$home" q-dep p-done

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next beside a landed row carrying a captain hold"
  assert_contains "$WAVE_OUT" "project=firstmate wave=2 start=q-dep" \
    "a landed row held its dependent back"

  wave "$home" plan
  assert_contains "$WAVE_OUT" "wave 1 p-done done landed" \
    "a landed row's gate is not read as landed"

  pass "a landed row clears its dependents"
}

# --- a blocker whose row is gone --------------------------------------------

# A declared blocker the backlog no longer carries counts as resolved, which is
# the shape of a blocker that landed and was pruned into the archive: the live
# backlog keeps only its recent Done rows, so reading the edge alone would stall
# the dependent forever.
test_a_pruned_blocker_no_longer_holds_its_dependent() {
  local home
  home=$(make_home pruned-blocker)
  seed "$home" r-next firstmate
  append_queued_row "$home" "- [ ] r-next - ticket r-next blocked-by: old-blocker (repo: firstmate) (kind: ship) (since 2026-09-15)"

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next beside a pruned blocker"
  assert_contains "$WAVE_OUT" "project=firstmate wave=1 start=r-next" \
    "a dependent of a pruned blocker did not start"

  pass "a pruned blocker no longer holds its dependent"
}

# --- a reply obligation is never worker work ---------------------------------

# A public-followup obligation is delivered by its own owner and never spawned,
# so it never appears in a start list however it is blocked.
test_a_reply_obligation_is_never_dispatched() {
  local home
  home=$(make_home obligation)
  seed "$home" ready-ship firstmate
  append_queued_row "$home" "- [ ] reply-1 - deliver the promised reply (repo: firstmate) (kind: public-followup) (since 2026-09-15)"

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next beside a reply obligation"
  assert_contains "$WAVE_OUT" "start=ready-ship" "the real work did not dispatch"
  assert_not_contains "$WAVE_OUT" "reply-1" \
    "a reply obligation was reported as dispatchable work"

  wave "$home" plan
  assert_contains "$WAVE_OUT" "reply-1 queued obligation" \
    "the obligation is not reported as an obligation"

  pass "a reply obligation is never dispatched"
}

# --- a cycle is a broken edge set, not a schedule ---------------------------

# A dependency cycle has no layer and no start: the computation reports it and
# keeps dispatching the projects that are not tangled in it.
test_a_cycle_is_reported_and_never_dispatched() {
  local home
  home=$(make_home cycle)
  seed "$home" cycle-a firstmate
  seed "$home" cycle-b firstmate
  block_on "$home" cycle-a cycle-b
  block_on "$home" cycle-b cycle-a
  seed "$home" elsewhere life

  wave "$home" next
  expect_code 0 "$WAVE_RC" "next beside a dependency cycle"
  assert_contains "$WAVE_OUT" "project=life wave=1 start=elsewhere" \
    "an unrelated project stopped dispatching because of a cycle"
  assert_not_contains "$WAVE_OUT" "cycle-a" "a cyclic ticket was dispatchable"
  assert_not_contains "$WAVE_OUT" "cycle-b" "a cyclic ticket was dispatchable"

  wave "$home" plan
  assert_contains "$WAVE_OUT" "wave 0 cycle-a queued cycle" \
    "the cyclic ticket is not reported as a cycle"

  pass "a cycle is reported and never dispatched"
}

test_two_projects_dispatch_their_own_waves
test_a_ticket_starts_once_its_own_blockers_land
test_an_unreviewed_item_blocks_only_its_dependents
test_a_landed_row_clears_its_dependents
test_a_pruned_blocker_no_longer_holds_its_dependent
test_a_reply_obligation_is_never_dispatched
test_a_cycle_is_reported_and_never_dispatched