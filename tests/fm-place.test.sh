#!/usr/bin/env bash
# tests/fm-place.test.sh - the farm placement decision in bin/fm-place.sh.
#
# What this suite pins: which home a queued row lands on, that an ineligible
# host refuses with the gate that refused it, that the primary at its ceiling
# does not strand work, that --handoff moves the row and instructs the mate,
# and the placement scorer: that without config/placement-scorer every line is
# the pre-scorer decision byte for byte, that a bad config refuses before any
# probe, that the opt-in T3 Code scorer ranks only gate-passing hosts, and that
# the shared vectors agree between the adapter and the pinned upstream selector.
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
  slow-host)
    # A mate that answers only after the T3 Code 15 s freshness window.
    sleep 16
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
#   <admission-detail> <nucleus-verdict> <nucleus-detail> <mem-gib> \
#   [<cpus> <cpu-util> <mem-total-gib>]
# The optional trailing facts are the T3 Code ones: the CPU count, the 200 ms
# CPU sample, and the installed memory, from which the byte facts follow. A
# report without them is a host whose probe read none of them.
write_mate_report() {
  local dir=$1 host=$2 platform=$3 admission=$4 admission_detail=$5
  local nucleus=$6 nucleus_detail=$7 mem=$8 admission_exit=1 nucleus_exit=1
  local cpus=${9:-} cpu_util=${10:-} total=${11:-}
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
    if [ -n "$cpus" ]; then
      printf 'cpus=%s\n' "$cpus"
      printf 'cpu_util=%s\n' "$cpu_util"
      printf 'mem_avail_bytes=%s\n' "$((mem * 1073741824))"
      printf 'mem_total_bytes=%s\n' "$((total * 1073741824))"
    fi
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

# The captain's 2026-09-28 rule: an eligible mate with more worker headroom
# takes the row even while this home is still under its cap.
test_the_host_with_the_most_headroom_wins() {
  local home reports ssh_fake proc out
  home=$(make_home most-headroom)
  reports="$TMP_ROOT/most-headroom-reports"
  proc="$TMP_ROOT/most-headroom-proc"
  fm_test_proc_fixture "$proc" 20 61
  write_cap "$home" 12
  write_worker "$home" alpha
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/most-headroom-ssh")
  seed_mate "$home" tight tight-host "$TMP_ROOT/most-headroom-tight" remote
  seed_mate "$home" roomy roomy-host "$TMP_ROOT/most-headroom-roomy" remote
  write_mate_report "$reports" tight-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 14
  write_mate_report "$reports" roomy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 50
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_PLACE_PROC_DIR=$proc FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "a fleet with eligible hosts should place the row"
  assert_contains "$out" 'PLACE home=roomy host=roomy-host' \
    "the host with the most worker headroom should win over an eligible primary"
  assert_contains "$out" 'headroom_workers=14 ranked=roomy:14,local:4,tight:2' \
    "the placement should rank every eligible host by headroom"
  pass "the eligible host with the most worker headroom takes the row"
}

test_a_headroom_tie_keeps_the_row_on_this_home() {
  local home reports ssh_fake proc out
  home=$(make_home headroom-tie)
  reports="$TMP_ROOT/headroom-tie-reports"
  proc="$TMP_ROOT/headroom-tie-proc"
  fm_test_proc_fixture "$proc" 20 61
  write_cap "$home" 12
  ssh_fake=$(make_fake_ssh "$TMP_ROOT/headroom-tie-ssh")
  seed_mate "$home" mate even-host "$TMP_ROOT/headroom-tie-mate" remote
  write_mate_report "$reports" even-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 21
  PATH_PREFIX="$ssh_fake:$TMUX_FAKE"
  FM_PLACE_PROC_DIR=$proc FM_FAKE_SSH_REPORTS=$reports run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 0 "$PLACE_STATUS" "a tie is still a placement"
  assert_contains "$out" 'PLACE home=local' "equal headroom should keep the row on this home"
  assert_contains "$out" 'ranked=local:4,mate:4' "both tied hosts should be ranked"
  pass "equal worker headroom prefers this home"
}

test_a_host_without_worker_headroom_is_refused() {
  local home proc out
  home=$(make_home no-headroom)
  proc="$TMP_ROOT/no-headroom-proc"
  fm_test_proc_fixture "$proc" 10 61
  write_cap "$home" 12
  : > "$home/data/secondmates.md"
  PATH_PREFIX=$TMUX_FAKE
  FM_PLACE_PROC_DIR=$proc run_place "$home"
  PATH_PREFIX=
  out=$PLACE_OUT
  expect_code 3 "$PLACE_STATUS" "a host with room for no worker must refuse the row"
  assert_contains "$out" 'local(memory: 10 GiB available leaves no room for a worker above the 8 GiB floor at 3 GiB per worker)' \
    "the refusal should name the headroom gate and its numbers"
  pass "a host above the floor but short of one worker's budget is refused"
}

# --- placement scorer (config/placement-scorer) -----------------------------

# The decision fleet the scorer cases share: this home at 20 of 61 GiB with 8
# CPUs half busy, and four remote mates. roomy has the most headroom but little
# idle CPU; tight has little headroom but 32 idle CPUs; busy runs a simulation;
# tina never answers. Every probed host carries the T3 Code facts, so the
# headroom cases prove those facts change nothing until the scorer is chosen.
# Sets SCORER_HOME, SCORER_REPORTS, SCORER_PROC, and SCORER_SSH; call it
# directly, never in a command substitution, so they survive.
SCORER_HOME=
SCORER_REPORTS=
SCORER_PROC=
SCORER_SSH=
build_scorer_fleet() {  # <name>
  local home
  home=$(make_home "$1")
  SCORER_HOME=$home
  SCORER_REPORTS="$TMP_ROOT/$1-reports"
  SCORER_PROC="$TMP_ROOT/$1-proc"
  fm_test_proc_fixture "$SCORER_PROC" 20 61
  fm_test_proc_cpu_fixture "$SCORER_PROC" 8 50
  write_cap "$home" 12
  write_worker "$home" alpha
  SCORER_SSH=$(make_fake_ssh "$TMP_ROOT/$1-ssh")
  seed_mate "$home" tight tight-host "$TMP_ROOT/$1-tight" remote
  seed_mate "$home" roomy roomy-host "$TMP_ROOT/$1-roomy" remote
  seed_mate "$home" busy busy-host "$TMP_ROOT/$1-busy" remote
  seed_mate "$home" tina unreachable-laptop "$TMP_ROOT/$1-tina" remote
  write_mate_report "$SCORER_REPORTS" tight-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 14 32 0.10 64
  write_mate_report "$SCORER_REPORTS" roomy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 50 4 0.90 64
  write_mate_report "$SCORER_REPORTS" busy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    BUSY 'BUSY: an unpaired job start is live' 60 64 0.01 64
  return 0
}

run_scorer_fleet() {  # <home>
  PATH_PREFIX="$SCORER_SSH:$TMUX_FAKE"
  FM_PLACE_PROC_DIR=$SCORER_PROC FM_FAKE_SSH_REPORTS=$SCORER_REPORTS run_place "$1"
  PATH_PREFIX=
}

# The expected lines below are what bin/fm-place.sh printed for these fleets
# before the scorer existed, so a missing config/placement-scorer (and an
# explicit headroom one) must reproduce them byte for byte.
test_without_a_scorer_config_placement_is_unchanged() {
  local home tie this config expect_a expect_b expect_c
  this=$(hostname -s 2>/dev/null || hostname)
  expect_a='PLACE home=roomy host=roomy-host platform=Linux laptop=not-applicable nucleus=idle free_gib=50 headroom_workers=14 ranked=roomy:14,local:4,tight:2 reason=the eligible host with the most worker headroom (14)'
  expect_b='REFUSE local(cap: 1 live workers recorded against the 1-worker ceiling (alive=1 unknown=0)); tight(memory: 9 GiB available leaves no room for a worker above the 8 GiB floor at 3 GiB per worker); roomy(laptop gate: OCCUPIED: cassidy is signed in); busy(nucleus: BUSY: an unpaired job start is live); tina(reach: ssh: connect to host unreachable-laptop port 22: Connection timed out)'
  expect_c="PLACE home=local host=$this platform=Linux laptop=not-applicable free_gib=20 headroom_workers=4 live=0/12 (alive=0 unknown=0) ranked=local:4,mate:4 reason=the eligible host with the most worker headroom (4), tied with mate and kept by tie order (this home first, then registry order)"
  build_scorer_fleet scorer-default
  home=$SCORER_HOME
  tie=$(make_home scorer-default-tie)
  write_cap "$tie" 12
  seed_mate "$tie" mate even-host "$TMP_ROOT/scorer-default-even" remote
  write_mate_report "$SCORER_REPORTS" even-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 21 64 0.01 64
  for config in missing headroom commented; do
    case "$config" in
      missing) rm -f "$home/config/placement-scorer" "$tie/config/placement-scorer" ;;
      headroom) printf 'headroom\n' | tee "$home/config/placement-scorer" > "$tie/config/placement-scorer" ;;
      commented) printf '# rank by memory headroom\n  # an indented note\n\n  headroom  \n' | tee "$home/config/placement-scorer" > "$tie/config/placement-scorer" ;;
    esac
    write_cap "$home" 12
    write_mate_report "$SCORER_REPORTS" tight-host Linux not-applicable 'platform Linux is not a macOS laptop' \
      IDLE 'IDLE: no live job' 14 32 0.10 64
    write_mate_report "$SCORER_REPORTS" roomy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
      IDLE 'IDLE: no live job' 50 4 0.90 64
    run_scorer_fleet "$home"
    expect_code 0 "$PLACE_STATUS" "the headroom decision should place ($config config)"
    assert_equals "$expect_a" "$PLACE_OUT" "the headroom placement line should be unchanged ($config config)"

    write_cap "$home" 1
    write_mate_report "$SCORER_REPORTS" tight-host Linux not-applicable 'platform Linux is not a macOS laptop' \
      IDLE 'IDLE: no live job' 9 32 0.10 64
    write_mate_report "$SCORER_REPORTS" roomy-host Darwin OCCUPIED 'OCCUPIED: cassidy is signed in' \
      IDLE 'IDLE: no live job' 50 4 0.90 64
    run_scorer_fleet "$home"
    expect_code 3 "$PLACE_STATUS" "the headroom refusal should refuse ($config config)"
    assert_equals "$expect_b" "$PLACE_OUT" "the headroom refusal line should be unchanged ($config config)"

    run_scorer_fleet "$tie"
    expect_code 0 "$PLACE_STATUS" "the headroom tie should place ($config config)"
    assert_equals "$expect_c" "$PLACE_OUT" "the headroom tie line should be unchanged ($config config)"
  done
  pass "without a scorer config, and with headroom, every placement line is byte-for-byte the pre-scorer decision"
}

test_a_bad_scorer_config_refuses_before_any_probe() {
  local home log bad expected
  build_scorer_fleet scorer-bad
  home=$SCORER_HOME
  log="$TMP_ROOT/scorer-bad-ssh.log"
  while IFS='|' read -r bad expected; do
    printf '%b' "$bad" > "$home/config/placement-scorer"
    : > "$log"
    PATH_PREFIX="$SCORER_SSH:$TMUX_FAKE"
    FM_FAKE_SSH_LOG=$log FM_PLACE_PROC_DIR=$SCORER_PROC FM_FAKE_SSH_REPORTS=$SCORER_REPORTS run_place "$home"
    PATH_PREFIX=
    expect_code 2 "$PLACE_STATUS" "config '$bad' must be a usage refusal"
    assert_contains "$PLACE_OUT" "fm-place: placement scorer: $home/config/placement-scorer" "the refusal should name the file ($bad)"
    assert_contains "$PLACE_OUT" "$expected" "the refusal should say what is wrong ($bad)"
    assert_not_contains "$PLACE_OUT" 'PLACE ' "a bad config must not place ($bad)"
    assert_not_contains "$PLACE_OUT" 'REFUSE ' "a bad config must not reach the decision ($bad)"
    [ ! -s "$log" ] || fail "config '$bad' must refuse before any host is probed (ssh ran: $(cat "$log"))"
  done <<'EOF'
t4|unknown scorer 't4'
headroom local=50|headroom takes no weights
t3 local=101|weight '101' for local is not an integer from 0 through 100
t3 local=-1|weight '-1' for local is not an integer from 0 through 100
t3 local=half|weight 'half' for local is not an integer from 0 through 100
t3 local|'local' is not <candidate-id>=<weight>
t3 nobody=50|'nobody' is neither local nor a secondmate
t3 tight=50 tight=20|tight is weighted more than once
t3\nheadroom\n|more than one setting line
# only a comment\n|names no scorer
EOF
  rm -f "$home/config/placement-scorer"
  mkdir "$home/config/placement-scorer"
  run_scorer_fleet "$home"
  expect_code 2 "$PLACE_STATUS" "a config path that is not a file must be a usage refusal"
  assert_contains "$PLACE_OUT" 'is not a readable file' "the refusal should say the file cannot be read"
  rmdir "$home/config/placement-scorer"
  pass "a malformed config/placement-scorer exits 2 before any host is probed"
}

test_the_t3_scorer_ranks_eligible_hosts_by_cpu_and_memory() {
  local home
  build_scorer_fleet scorer-t3
  home=$SCORER_HOME
  seed_mate "$home" hot hot-host "$TMP_ROOT/scorer-t3-hot" remote
  seed_mate "$home" blind blind-host "$TMP_ROOT/scorer-t3-blind" remote
  write_mate_report "$SCORER_REPORTS" hot-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 60 64 0.97 64
  write_mate_report "$SCORER_REPORTS" blind-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 60 64 unobserved 64

  run_scorer_fleet "$home"
  assert_contains "$PLACE_OUT" 'PLACE home=hot host=hot-host' "headroom alone should pick the roomiest eligible host"

  printf 't3 tight=100 busy=100\n' > "$home/config/placement-scorer"
  run_scorer_fleet "$home"
  expect_code 0 "$PLACE_STATUS" "the t3 scorer should place the row"
  assert_equals 'PLACE home=tight host=tight-host platform=Linux laptop=not-applicable nucleus=idle free_gib=14 headroom_workers=2 scorer=t3code-v0.1.7 weights=local:50,tight:100,roomy:50,busy:100,tina:50,hot:50,blind:50 score=630.00 ranked=tight:630.00,local:65.57,roomy:15.62 reason=the eligible host with the highest T3 Code v0.1.7 score (630.00); not ranked: hot(t3: CPU utilization 0.97 is at or above 0.95); blind(t3: CPU utilization was not observed)' \
    "$PLACE_OUT" "the T3 score should rank idle cores over headroom, name the scorer and weights, and keep busy refused by its gate"

  printf 't3 tight=0 roomy=007\n' > "$home/config/placement-scorer"
  run_scorer_fleet "$home"
  expect_code 0 "$PLACE_STATUS" "a weight of 0 should not stop placement"
  assert_contains "$PLACE_OUT" 'PLACE home=local ' "with tight weighted out, this home has the best score"
  assert_contains "$PLACE_OUT" 'headroom_workers=4 live=1/12 (alive=1 unknown=0) scorer=t3code-v0.1.7 weights=local:50,tight:0,roomy:7,' \
    "a local placement should keep its cap facts, and a zero-padded weight reads as its number"
  assert_contains "$PLACE_OUT" 'tight(t3: weight 0 keeps this host out of t3 ranking)' "weight 0 should be named as the reason"

  write_cap "$home" 1
  write_mate_report "$SCORER_REPORTS" tight-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 14 32 0.99 64
  write_mate_report "$SCORER_REPORTS" roomy-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 50
  printf 't3\n' > "$home/config/placement-scorer"
  run_scorer_fleet "$home"
  expect_code 3 "$PLACE_STATUS" "no host the T3 score accepts means a refusal"
  assert_equals 'REFUSE local(cap: 1 live workers recorded against the 1-worker ceiling (alive=1 unknown=0)); busy(nucleus: BUSY: an unpaired job start is live); tina(reach: ssh: connect to host unreachable-laptop port 22: Connection timed out); tight(t3: CPU utilization 0.99 is at or above 0.95); roomy(t3: the host reported no complete resource sample); hot(t3: CPU utilization 0.97 is at or above 0.95); blind(t3: CPU utilization was not observed)' \
    "$PLACE_OUT" "the refusal should keep every gate reason and add every T3 rejection"
  rm -f "$home/config/placement-scorer"
  pass "the opt-in T3 Code scorer ranks only gate-passing hosts, by weight, idle cores, and free memory"
}

test_a_slow_mate_ages_earlier_t3_samples() {
  local home id pattern
  build_scorer_fleet scorer-slow
  home=$SCORER_HOME
  seed_mate "$home" slow slow-host "$TMP_ROOT/scorer-slow-slow" remote
  write_mate_report "$SCORER_REPORTS" slow-host Linux not-applicable 'platform Linux is not a macOS laptop' \
    IDLE 'IDLE: no live job' 14 4 0.90 64
  printf 't3\n' > "$home/config/placement-scorer"
  PATH_PREFIX="$SCORER_SSH:$TMUX_FAKE"
  FM_PLACE_HOST_TIMEOUT=30 FM_PLACE_PROC_DIR=$SCORER_PROC FM_FAKE_SSH_REPORTS=$SCORER_REPORTS run_place "$home"
  PATH_PREFIX=
  expect_code 0 "$PLACE_STATUS" "a slow but answering mate should not stop placement"
  assert_contains "$PLACE_OUT" 'PLACE home=slow host=slow-host' "the slow mate's fresh sample should win"
  assert_contains "$PLACE_OUT" 'ranked=slow:4.37 ' "only the fresh sample should be ranked"
  for id in local tight roomy; do
    pattern="$id\\(t3: the sample is [0-9]+ ms old, past the 15000 ms freshness window\\)"
    [[ "$PLACE_OUT" =~ $pattern ]] || fail "$id should be rejected as stale: $PLACE_OUT"
  done
  rm -f "$home/config/placement-scorer"
  pass "a slow mate ages earlier T3 Code samples past the freshness window and only its fresh sample ranks"
}

# The shared vectors: the Firstmate adapter must give each case's expected
# winner and rejection set, and so must the pinned upstream selector under Bun
# wherever Bun is installed.
vector_results_adapter() {  # <scratch-dir>
  local dir=$1 f name now out winner rejected
  mkdir -p "$dir"
  awk -v dir="$dir" '
    /^#/ || !NF { next }
    $1 == "case" { n++; f = sprintf("%s/%03d", dir, n); print $2, $3 > (f ".case"); close(f ".case"); next }
    { print > (f ".in") }
  ' "$ROOT/tests/fixtures/t3-placement-vectors.tsv"
  for f in "$dir"/*.case; do
    read -r name now < "$f"
    out=$(bash -c '. "$1"; fm_placement_t3_score "$2"' _ "$ROOT/bin/fm-placement-scorer-lib.sh" "$now" < "${f%.case}.in")
    winner=$(printf '%s\n' "$out" | awk '$1 == "winner" { print $2 }')
    rejected=$(printf '%s\n' "$out" | awk '$1 == "candidate" && $3 == "reject" { r = r (r == "" ? "" : ",") $2 } END { print (r == "" ? "-" : r) }')
    printf '%s %s %s\n' "$name" "$winner" "$rejected"
  done
}

vector_results_upstream() {  # <bun> <scratch-dir>
  local bun=$1 dir=$2
  mkdir -p "$dir"
  cat > "$dir/upstream.mjs" <<'JS'
const [selector, vectors] = process.argv.slice(2);
const { chooseLoadBalancedEnvironment: choose } = await import(selector);
const cases = [];
for (const raw of (await Bun.file(vectors).text()).split("\n")) {
  const line = raw.trim();
  if (!line || line.startsWith("#")) continue;
  const f = line.split(/\s+/);
  if (f[0] === "case") { cases.push({ name: f[1], now: Number(f[2]), cands: [] }); continue; }
  const [id, weight, cpus, util, avail, total, at] = f;
  const missing = [cpus, avail, total].includes("unobserved");
  cases.at(-1).cands.push({
    environmentId: id,
    weight: Number(weight),
    receivedAt: Number(at),
    resources: missing ? null : {
      sampledAt: Number(at),
      cpuUtilization: util === "unobserved" ? null : Number(util),
      cpuCount: Number(cpus),
      availableMemoryBytes: Number(avail),
      totalMemoryBytes: Number(total),
    },
  });
}
for (const c of cases) {
  const winner = choose(c.cands, c.now) ?? "-";
  const rejected = c.cands.filter((x) => choose([x], c.now) === null).map((x) => x.environmentId);
  console.log(`${c.name} ${winner} ${rejected.length ? rejected.join(",") : "-"}`);
}
JS
  "$bun" "$dir/upstream.mjs" "$ROOT/bin/vendor/t3code/load-balancing.ts" "$ROOT/tests/fixtures/t3-placement-vectors.tsv"
}

test_shared_vectors_match_the_pinned_upstream_selector() {
  local expected adapter upstream bun
  expected=$(awk '$1 == "case" { print $2, $4, $5 }' "$ROOT/tests/fixtures/t3-placement-vectors.tsv")
  [ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" -ge 10 ] || fail "the shared vectors should hold every boundary case"
  adapter=$(vector_results_adapter "$TMP_ROOT/vectors-adapter")
  assert_equals "$expected" "$adapter" "the Firstmate adapter should give every case's expected winner and rejection set"
  bun=$(command -v bun 2>/dev/null || true)
  [ -n "$bun" ] || [ ! -x "$HOME/.bun/bin/bun" ] || bun=$HOME/.bun/bin/bun
  if [ -n "$bun" ]; then
    upstream=$(vector_results_upstream "$bun" "$TMP_ROOT/vectors-upstream") || fail "the pinned upstream selector did not run under Bun"
    assert_equals "$adapter" "$upstream" "the pinned upstream selector and the adapter should agree on every case"
    printf '%s\n' "$upstream" | sed 's/^/# upstream bun: /'
    pass "the shared vectors give the same winner and rejection set through upstream Bun and the Firstmate adapter"
  else
    printf '# bun is not installed: the upstream half of the shared vectors was not run\n'
    pass "the shared vectors give the expected winner and rejection set through the Firstmate adapter"
  fi
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
test_the_host_with_the_most_headroom_wins
test_a_headroom_tie_keeps_the_row_on_this_home
test_a_host_without_worker_headroom_is_refused
test_without_a_scorer_config_placement_is_unchanged
test_a_bad_scorer_config_refuses_before_any_probe
test_the_t3_scorer_ranks_eligible_hosts_by_cpu_and_memory
test_a_slow_mate_ages_earlier_t3_samples
test_shared_vectors_match_the_pinned_upstream_selector

echo "ALL TESTS PASSED"
