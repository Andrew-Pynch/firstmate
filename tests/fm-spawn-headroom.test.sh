#!/usr/bin/env bash
# tests/fm-spawn-headroom.test.sh - bin/fm-spawn.sh's local worker-headroom
# check.
#
# What this suite pins: a fresh ship spawn on a host with no worker headroom is
# refused before any task record exists and names the mate bin/fm-place.sh would
# hand the row to; --force-local launches anyway with a warning; and
# --force-local is refused where the check never runs. Local memory comes from
# FM_PLACE_PROC_DIR and the mate's host from a fake ssh, and the launch runs
# against the shared fake tmux spawn world, so no real harness starts.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-headroom)

LOW_PROC="$TMP_ROOT/proc-low"
fm_test_proc_fixture "$LOW_PROC" 9 61

make_case() {  # <name> <id>: prints "<home>|<proj>|<wt>|<fakebin>|<reports>"
  local dir=$TMP_ROOT/$1 id=$2 home proj wt fakebin reports
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  reports="$dir/reports"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$1"
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -u
host=
last=
for arg in "$@"; do
  host=$last
  last=$arg
done
report=${FM_FAKE_SSH_REPORTS:-}/$host.report
[ -f "$report" ] || { printf 'ssh: Could not resolve hostname %s\n' "$host" >&2; exit 255; }
cat "$report"
SH
  chmod +x "$fakebin/ssh"
  mkdir -p "$reports"
  printf 'platform=Linux\nadmission_verdict=not-applicable\nadmission_exit=0\nnucleus_verdict=IDLE\nnucleus_exit=0\nnucleus_detail=IDLE: no live job\nmem_gib=30\nmem_total_gib=31\nload_1m=1.00\ncpus=16\nworkers=2\nworker_rss_gib=3.0\n' \
    > "$reports/roomy-host.report"
  printf -- '- bertha - feature work (host: roomy-host; root: /srv/fm; home: /srv/fm-homes/bertha; scope: feature work; projects: alpha; added 2026-09-28)\n' \
    > "$home/data/secondmates.md"
  printf 'Ron: maximum 12 live workers/scouts.\n' > "$home/data/captain.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$reports"
}

test_a_spawn_without_headroom_is_refused_and_names_the_mate() {
  local home proj wt fakebin reports out rc
  IFS='|' read -r home proj wt fakebin reports <<EOF
$(make_case refused tight-task)
EOF
  out=$(FM_PLACE_PROC_DIR=$LOW_PROC FM_FAKE_SSH_REPORTS=$reports \
    fm_test_run_spawn "$home" "$wt" "$fakebin" tight-task "$proj" --mode local-only --yolo off)
  rc=$?
  expect_code 1 "$rc" "a spawn on a host with no worker headroom must be refused"
  assert_contains "$out" 'spawn refused - this host has no worker headroom for tight-task: home=local' \
    "the refusal should say why and carry this host's resource line"
  assert_contains "$out" 'avail_gib=9 total_gib=61' "the refusal should show the memory it read"
  assert_contains "$out" 'headroom_workers=0' "the refusal should show the headroom it derived"
  assert_contains "$out" 'placement: PLACE home=bertha host=roomy-host' \
    "the refusal should name the mate the placement decision chose"
  assert_contains "$out" 'bin/fm-place.sh --item tight-task --handoff' \
    "the refusal should name the command that hands the row over"
  [ ! -e "$home/state/tight-task.meta" ] || fail "a refused spawn must not publish a task record"
  pass "a local spawn without worker headroom is refused and names the mate to use"
}

test_force_local_launches_anyway_with_a_warning() {
  local home proj wt fakebin reports out rc
  IFS='|' read -r home proj wt fakebin reports <<EOF
$(make_case forced forced-task)
EOF
  out=$(FM_PLACE_PROC_DIR=$LOW_PROC FM_FAKE_SSH_REPORTS=$reports \
    fm_test_run_spawn "$home" "$wt" "$fakebin" forced-task "$proj" --mode local-only --yolo off --force-local)
  rc=$?
  expect_code 0 "$rc" "--force-local should launch past the headroom check"
  assert_contains "$out" 'warning: --force-local: launching forced-task on this host although it has no worker headroom' \
    "the override should be announced with the host's line"
  assert_not_contains "$out" 'spawn refused' "the override must not also refuse"
  assert_grep 'kind=ship' "$home/state/forced-task.meta" "the forced spawn should publish its task record"
  pass "--force-local launches on a host without headroom and says so"
}

test_an_unreadable_host_is_refused_by_name() {
  local home proj wt fakebin reports out rc
  IFS='|' read -r home proj wt fakebin reports <<EOF
$(make_case unreadable blind-task)
EOF
  mkdir -p "$TMP_ROOT/proc-empty"
  out=$(FM_PLACE_PROC_DIR="$TMP_ROOT/proc-empty" FM_FAKE_SSH_REPORTS=$reports \
    fm_test_run_spawn "$home" "$wt" "$fakebin" blind-task "$proj" --mode local-only --yolo off)
  rc=$?
  expect_code 1 "$rc" "a host whose memory cannot be read must refuse the spawn, not abort silently"
  assert_contains "$out" 'spawn refused - this host has no worker headroom for blind-task' \
    "the refusal should be reported even when the host could not be read"
  assert_contains "$out" 'headroom_workers=?' "the refusal should show that headroom was not derived"
  [ ! -e "$home/state/blind-task.meta" ] || fail "a refused spawn must not publish a task record"
  pass "a host whose memory cannot be read refuses the spawn by name"
}

test_force_local_is_refused_where_no_check_runs() {
  local home proj wt fakebin reports out rc
  IFS='|' read -r home proj wt fakebin reports <<EOF
$(make_case secondmate mate-task)
EOF
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" mate-task --secondmate --force-local)
  rc=$?
  expect_code 1 "$rc" "--force-local on a secondmate spawn should be refused"
  assert_contains "$out" '--force-local applies only to a fresh ship or scout spawn' \
    "the refusal should say where the override applies"
  pass "--force-local is refused on a spawn the headroom check exempts"
}

test_a_spawn_without_headroom_is_refused_and_names_the_mate
test_an_unreadable_host_is_refused_by_name
test_force_local_launches_anyway_with_a_warning
test_force_local_is_refused_where_no_check_runs

echo "ALL TESTS PASSED"
