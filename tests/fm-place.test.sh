#!/usr/bin/env bash
# tests/fm-place.test.sh - the farm placement decision in bin/fm-place.sh.
#
# What this suite pins: which home a queued row lands on, that an ineligible
# host refuses with the gate that refused it, that the primary at its ceiling
# does not strand work, and that --handoff moves the row and instructs the mate.
#
# The refusal fixtures are the captain's own ineligible cases: a host running a
# Nucleus simulation, a laptop that does not answer, and a laptop occupied by
# the other person who uses it. The remote probe is driven by a fake ssh and the
# local endpoint read by a fake tmux, so the decision table is exercised without
# a fleet.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

PLACE="$ROOT/bin/fm-place.sh"
TMP_ROOT=$(fm_test_tmproot fm-place)

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

PLACE_OUT=
PLACE_STATUS=0
PATH_PREFIX=

run_place() {  # <home> [args...]
  local home=$1
  shift
  PLACE_OUT=$(PATH="${PATH_PREFIX}${PATH_PREFIX:+:}$PATH" FM_HOME="$home" "$PLACE" "$@" 2>&1)
  PLACE_STATUS=$?
  return 0
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

write_cap() {  # <home> <cap>
  printf 'Ron: 61 GiB RAM, maximum %s live workers/scouts (raised from 10 by the captain with 20 GiB available). Fresh memory check before launch.\n' \
    "$2" > "$1/data/captain.md"
}

# The fixture endpoint read: one fake tmux answers the reads the shared endpoint
# classifier makes, for whichever fixture home FM_HOME names, so a recorded
# worker reads as a live endpoint exactly as the fleet snapshot suite drives it.
make_live_tmux() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for arg in "$@"; do
  [ "$prev" = -t ] && target=$arg
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'quiet\n> \n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

TMUX_FAKE=$(make_live_tmux "$TMP_ROOT/fakes")

# A fake ssh answering from per-host report files, so every gate case is driven
# by the report a host would produce rather than by a live machine.
make_fake_ssh() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:-/dev/null}"
host=
last=
for arg in "$@"; do
  host=$last
  last=$arg
done
case "$host" in
  unreachable-laptop)
    printf 'ssh: connect to host %s port 22: Connection timed out\n' "$host" >&2
    exit 255
    ;;
esac
report=${FM_FAKE_SSH_REPORTS:-}/$host.report
[ -f "$report" ] || {
  printf 'ssh: Could not resolve hostname %s\n' "$host" >&2
  exit 255
}
cat "$report"
SH
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

# write_worker <home> <id>: a recorded worker whose recorded endpoint reads live
# through the fixture tmux above.
write_worker() {  # <home> <id>
  mkdir -p "$1/projects/$2"
  fm_write_meta "$1/state/$2.meta" \
    "window=firstmate:fm-$2" \
    "worktree=$1/projects/$2" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
}

# seed_mate <home> <id> <host> <mate-home> <local|remote> [IDLE|BUSY|UNKNOWN]
# Registers a mate in the fixture registry. A local route additionally makes
# that home a genuine seeded home carrying its own Nucleus admission check.
seed_mate() {
  local home=$1 id=$2 host=$3 mate_home=$4 kind=${5:-remote} check=${6:-IDLE}
  local registry="$home/data/secondmates.md"
  if [ "$kind" = local ]; then
    printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-09-15)\n' \
      "$id" "$mate_home" >> "$registry"
    seed_secondmate_home_marker "$mate_home" "$id"
    mkdir -p "$mate_home/state" "$mate_home/projects"
    write_nucleus_check "$mate_home" "$check"
  else
    printf -- '- %s - feature work (host: %s; root: /srv/fm; home: %s; scope: feature work; projects: alpha; added 2026-09-15)\n' \
      "$id" "$host" "$mate_home" >> "$registry"
  fi
}

# write_nucleus_check <mate-home> <IDLE|BUSY|UNKNOWN>: the mate's own Nucleus
# admission check, standing in for the one the mates run.
write_nucleus_check() {
  local mate_home=$1 verdict=$2 detail rc=1
  case "$verdict" in
    IDLE)
      detail='no live job, no unaccounted attempt directory, and no solver'
      rc=0
      ;;
    BUSY) detail='an unpaired job start is live in /app/swarm-work/runs' ;;
    *) detail='docker is not on PATH, so the node could not be observed' ;;
  esac
  mkdir -p "$mate_home/data"
  printf '#!/usr/bin/env bash\necho "%s: %s"\nexit %s\n' "$verdict" "$detail" "$rc" \
    > "$mate_home/data/nucleus-live-job-check.sh"
}

# write_mate_report <reports-dir> <host> <platform> <admission-verdict> \
#   <admission-detail> <nucleus-verdict> <nucleus-detail> <mem-gib>
write_mate_report() {
  local dir=$1 host=$2 platform=$3 admission=$4 admission_detail=$5
  local nucleus=$6 nucleus_detail=$7 mem=$8 admission_exit=1 nucleus_exit=1
  case "$admission" in
    AVAILABLE) admission_exit=0 ;;
    OCCUPIED) admission_exit=2 ;;
    UNAVAILABLE) admission_exit=3 ;;
  esac
  [ "$nucleus" = IDLE ] && nucleus_exit=0
  mkdir -p "$dir"
  {
    printf 'platform=%s\n' "$platform"
    printf 'admission_verdict=%s\n' "$admission"
    printf 'admission_exit=%s\n' "$admission_exit"
    printf 'admission_detail=%s\n' "$admission_detail"
    printf 'nucleus_verdict=%s\n' "$nucleus"
    printf 'nucleus_exit=%s\n' "$nucleus_exit"
    printf 'nucleus_detail=%s\n' "$nucleus_detail"
    printf 'mem_gib=%s\n' "$mem"
  } > "$dir/$host.report"
}

inbox_body_stream() {  # <state-dir> <task-id>
  local rec
  for rec in "$1/$2.inbox"/*.msg; do
    [ -f "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ \
      "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
  done
}

test_places_locally_when_under_the_cap() {
  local home out
  home=$(make_home local-ok)
  write_cap "$home" 12
  write_worker "$home" alpha
  : > "$home/data/secondmates.md"
  PATH_PREFIX=$TMUX_FAKE
  run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "placement under the cap should succeed"
  assert_contains "$out" 'PLACE home=local' "an idle primary home should take the row itself"
  assert_contains "$out" 'live=1/12' "the placement should report the cap it measured"
  pass "a row is placed on the primary while it is under its live-worker cap"
}

test_cap_overflow_places_the_row_on_an_eligible_mate() {
  local home mate out
  home=$(make_home cap-overflow)
  mate="$TMP_ROOT/cap-overflow-mate"
  write_cap "$home" 2
  write_worker "$home" alpha
  write_worker "$home" beta
  seed_mate "$home" mate host-a "$mate" local IDLE
  PATH_PREFIX=$TMUX_FAKE
  run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "a full primary home should still place the row"
  assert_contains "$out" 'PLACE home=mate' "a row overflowed from a full primary should land on the eligible mate"
  assert_contains "$out" 'nucleus=idle' "the placement should report the mate's admission evidence"
  case "$out" in
    *'PLACE home=local'*) fail "a primary home at its ceiling must not place the row itself" ;;
  esac
  pass "work overflows to an eligible mate when the primary is at its cap"
}

test_refuses_a_host_running_a_simulation() {
  local home reports ssh_fake out
  home=$(make_home nucleus-busy)
  reports="$TMP_ROOT/nucleus-busy-reports"
  write_cap "$home" 1
  write_worker "$home" alpha
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/nucleus-busy-ssh")
  seed_mate "$home" mate busy-host "$TMP_ROOT/nucleus-busy-mate" remote
  write_mate_report "$reports" busy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    BUSY 'BUSY: a solver is running for run 42' 24
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "a host running a simulation must refuse the row"
  assert_contains "$out" 'REFUSE' "the decision should refuse rather than place"
  assert_contains "$out" 'mate(nucleus: BUSY: a solver is running for run 42)' \
    "the refusal should name the simulation gate and carry its own evidence"
  pass "a host with a live Nucleus simulation refuses new work by name"
}

test_refuses_a_laptop_that_does_not_answer() {
  local home reports ssh_fake out
  home=$(make_home sleeping-laptop)
  reports="$TMP_ROOT/sleeping-laptop-reports"
  write_cap "$home" 1
  write_worker "$home" alpha
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/sleeping-laptop-ssh")
  seed_mate "$home" mate unreachable-laptop "$TMP_ROOT/sleeping-laptop-mate" remote
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "an unreachable host must refuse the row"
  assert_contains "$out" 'REFUSE' "the decision should refuse rather than place"
  assert_contains "$out" 'mate(reach: ssh: connect to host unreachable-laptop port 22: Connection timed out)' \
    "the refusal should report the transport failure that made the host unknown"
  pass "a host that does not answer is refused as unknown, never treated as idle"
}

test_refuses_a_laptop_occupied_by_its_other_user() {
  local home reports ssh_fake out
  home=$(make_home occupied-laptop)
  reports="$TMP_ROOT/occupied-laptop-reports"
  write_cap "$home" 1
  write_worker "$home" alpha
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/occupied-laptop-ssh")
  seed_mate "$home" mate occupied-host "$TMP_ROOT/occupied-laptop-mate" remote
  write_mate_report "$reports" occupied-host Darwin OCCUPIED \
    'OCCUPIED: node=occupied-host policy=household; another account holds a GUI login session' \
    IDLE 'IDLE: no live job' 16
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "an occupied laptop must refuse the row"
  assert_contains "$out" 'REFUSE' "the decision should refuse rather than place"
  assert_contains "$out" 'laptop gate: OCCUPIED' "the refusal should name the occupancy gate"
  assert_contains "$out" 'another account holds a GUI login session' \
    "the refusal should carry the occupancy evidence"
  pass "a laptop another person is signed in to refuses new work"
}

test_the_refusal_names_every_candidate_and_gate() {
  local home reports ssh_fake out
  home=$(make_home all-refused)
  reports="$TMP_ROOT/all-refused-reports"
  write_cap "$home" 1
  write_worker "$home" alpha
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/all-refused-ssh")
  seed_mate "$home" first unreachable-laptop "$TMP_ROOT/all-refused-mate-one" remote
  seed_mate "$home" second busy-host "$TMP_ROOT/all-refused-mate-two" remote
  write_mate_report "$reports" busy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    BUSY 'BUSY: a solver is running for run 42' 24
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "a refusal is the outcome when no candidate passes"
  assert_contains "$out" 'local(cap: 1 live workers recorded against the 1-worker ceiling' \
    "the refusal should name the primary home's own failing gate"
  assert_contains "$out" 'first(reach:' "the refusal should name the first mate's failing gate"
  assert_contains "$out" 'second(nucleus: BUSY' "the refusal should name the second mate's failing gate"
  pass "one refusal line names every candidate and every gate that failed"
}

test_refuses_a_row_that_is_not_queued() {
  local home out
  [ "$HAVE_TASKS_AXI" = 1 ] || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home in-flight-row)
  write_cap "$home" 12
  printf '## In flight\n- [ ] active-row - already running (repo: alpha) (kind: ship) (since 2026-09-15)\n\n## Queued\n\n## Done\n' \
    > "$home/data/backlog.md"
  run_place "$home" --item active-row
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "an in-flight row must not be placed"
  assert_contains "$out" 'REFUSE row active-row is in_flight' \
    "the refusal should name the row's own state"
  pass "an in-flight row is refused by name and never moved"
}

test_refuses_a_row_that_is_not_ship_or_scout() {
  local home out
  [ "$HAVE_TASKS_AXI" = 1 ] || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home ops-row)
  write_cap "$home" 12
  printf '## Queued\n- [ ] ops-row - operator chore (repo: alpha) (kind: ops) (since 2026-09-15)\n\n## Done\n' \
    > "$home/data/backlog.md"
  run_place "$home" --item ops-row
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "a row this policy does not place must be refused"
  assert_contains "$out" 'REFUSE row ops-row is kind ops' \
    "the refusal should name the kind it will not place"
  pass "a row that is neither a ship nor a scout is refused by name"
}

test_handoff_moves_the_row_and_instructs_the_mate() {
  local home mate out
  [ "$HAVE_TASKS_AXI" = 1 ] || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home handoff)
  mate="$TMP_ROOT/handoff-mate"
  write_cap "$home" 1
  write_worker "$home" alpha
  seed_mate "$home" mate host-a "$mate" local IDLE
  printf '## Queued\n- [ ] overflow-row - work for the farm (repo: alpha) (kind: ship) (since 2026-09-15)\n\n## Done\n' \
    > "$home/data/backlog.md"
  printf '## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  fm_write_secondmate_meta "$home/state/mate.meta" "$mate" "firstmate:fm-mate"
  PATH_PREFIX=$TMUX_FAKE
  run_place "$home" --item overflow-row --handoff
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "the handoff should move the row and report the placement"
  assert_contains "$out" 'PLACE home=mate' "the handoff should report where the row went"
  assert_contains "$out" 'handoff=moved row overflow-row' "the handoff should report the move"
  assert_grep 'overflow-row' "$mate/data/backlog.md" \
    "the queued row should be in the mate's own backlog after the handoff"
  assert_no_grep 'overflow-row' "$home/data/backlog.md" \
    "the queued row should no longer sit in the dispatchable backlog"
  assert_contains "$(inbox_body_stream "$home/state" mate)" 'Farm placement sent overflow-row' \
    "the mate should receive the placement reason as an instruction"
  pass "--handoff moves a queued row to the mate and instructs it"
}

test_handoff_leaves_a_local_decision_alone() {
  local home out
  home=$(make_home handoff-local)
  write_cap "$home" 12
  write_worker "$home" alpha
  : > "$home/data/secondmates.md"
  PATH_PREFIX=$TMUX_FAKE
  run_place "$home" --handoff
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "a local decision is still a decision"
  assert_contains "$out" 'PLACE home=local' "the primary home takes the row itself"
  assert_contains "$out" 'handoff=none' \
    "a local placement reports that dispatch is local rather than moving a row"
  pass "a local decision reports handoff=none and moves nothing"
}

test_places_locally_when_under_the_cap
test_cap_overflow_places_the_row_on_an_eligible_mate
test_refuses_a_host_running_a_simulation
test_refuses_a_laptop_that_does_not_answer
test_refuses_a_laptop_occupied_by_its_other_user
test_the_refusal_names_every_candidate_and_gate
test_refuses_a_row_that_is_not_queued
test_refuses_a_row_that_is_not_ship_or_scout
test_handoff_moves_the_row_and_instructs_the_mate
test_handoff_leaves_a_local_decision_alone

echo "ALL TESTS PASSED"
