#!/usr/bin/env bash
# tests/fm-fleet-resources.test.sh - the worker-headroom rule and the fleet
# resource read in bin/fm-fleet-resources.sh (rule owner:
# bin/fm-host-probe-lib.sh).
#
# What this suite pins: headroom_workers at and around the memory floor, that
# both policy knobs move it, that every registered host gets a row and an
# unreachable one says why instead of disappearing, the one-line summary and
# JSON forms, and the T3 Code facts (200 ms CPU utilization and byte-precise
# memory) on Linux and macOS, unobserved rather than invented when missing.
# Local memory is driven through FM_PLACE_PROC_DIR and remote hosts through a
# fake ssh, so no real machine's load decides a verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-fleet-resources.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-resources)

OUT=
STATUS=0
run_fleet() {  # <home> <proc-dir> [args...]
  local home=$1 proc=$2
  shift 2
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_PLACE_PROC_DIR="$proc" \
    FM_FAKE_SSH_REPORTS="$TMP_ROOT/reports" "$FLEET" "$@" 2>&1)
  STATUS=$?
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state"
  : > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

# A fake ssh answering from per-host report files; an absent report is an
# unresolvable host. A host with a directory under FM_FAKE_DARWIN_ROOT instead
# runs the real probe snippet against that directory's stand-in macOS tools
# (uname, vm_stat, sysctl, and optionally a JavaScript runtime), the few POSIX
# tools the snippet needs, and its own home, with nothing else of this
# machine's PATH or environment, the way a near-bare macOS ssh session runs it.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakes")
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
set -u
host=
last=
for arg in "$@"; do
  host=$last
  last=$arg
done
darwin=${FM_FAKE_DARWIN_ROOT:-}/$host
if [ -n "${FM_FAKE_DARWIN_ROOT:-}" ] && [ -d "$darwin" ]; then
  exec env -i HOME="$darwin/home" PATH="$darwin/bin:/opt/homebrew/bin" sh -c "$last"
fi
report=${FM_FAKE_SSH_REPORTS:-}/$host.report
[ -f "$report" ] || {
  printf 'ssh: Could not resolve hostname %s\n' "$host" >&2
  exit 255
}
cat "$report"
SH
chmod +x "$FAKEBIN/ssh"

DARWIN_ROOT="$TMP_ROOT/darwin"

# write_darwin_host <host> <runtime: real|none|hang> <vm_stat: full|no-speculative|stuck>:
# stand-in macOS tools for one host. lil-timmy's own vm_stat output is the
# fixture: 16 KiB pages, 48 GiB installed, 16 CPUs.
write_darwin_host() {
  local dir="$DARWIN_ROOT/$1" runtime=$2 vm=$3 real tool
  mkdir -p "$dir/bin" "$dir/home"
  for tool in sh awk sed head grep ps cat sleep; do
    ln -sf "$(command -v "$tool")" "$dir/bin/$tool"
  done
  printf '#!/bin/sh\necho Darwin\n' > "$dir/bin/uname"
  {
    printf '#!/bin/sh\ncat <<EOF\n'
    printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
    printf 'Pages free:                                    32263.\n'
    printf 'Pages active:                                 790438.\n'
    printf 'Pages inactive:                               792906.\n'
    [ "$vm" = no-speculative ] || printf 'Pages speculative:                              1959.\n'
    printf 'Pages throttled:                                   0.\n'
    printf 'Pages wired down:                             582927.\n'
    printf 'Pages purgeable:                                3748.\n'
    printf 'EOF\n'
  } > "$dir/bin/vm_stat"
  [ "$vm" != stuck ] || printf '#!/bin/sh\nexec sleep 30\n' > "$dir/bin/vm_stat"
  cat > "$dir/bin/sysctl" <<'SH'
#!/bin/sh
case "$*" in
  *hw.memsize*) echo 51539607552 ;;
  *vm.loadavg*) echo '{ 1.60 1.40 1.20 }' ;;
  *hw.ncpu*) echo 16 ;;
esac
SH
  case "$runtime" in
    real)
      real=$(command -v node || command -v bun || true)
      [ -n "$real" ] || [ ! -x "$HOME/.bun/bin/bun" ] || real=$HOME/.bun/bin/bun
      [ -n "$real" ] || return 1
      mkdir -p "$dir/home/.bun/bin"
      printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$dir/home/.bun/bin/bun"
      chmod +x "$dir/home/.bun/bin/bun"
      ;;
    hang) printf '#!/bin/sh\nexec sleep 30\n' > "$dir/bin/node" ;;
  esac
  chmod +x "$dir/bin/uname" "$dir/bin/vm_stat" "$dir/bin/sysctl"
  [ "$runtime" != hang ] || chmod +x "$dir/bin/node"
}

write_report() {  # <host> <avail-gib> <total-gib>
  mkdir -p "$TMP_ROOT/reports"
  printf 'platform=Linux\nadmission_verdict=not-applicable\nadmission_exit=0\nmem_gib=%s\nmem_total_gib=%s\nload_1m=2.00\ncpus=4\nworkers=3\nworker_rss_gib=6.2\n' \
    "$2" "$3" > "$TMP_ROOT/reports/$1.report"
}

register_remote_mate() {  # <home> <id> <host>
  printf -- '- %s - feature work (host: %s; root: /srv/fm; home: /srv/fm-homes/%s; scope: feature work; projects: alpha; added 2026-09-28)\n' \
    "$2" "$3" "$2" >> "$1/data/secondmates.md"
}

headroom_of() {  # <plain output> <home id>
  printf '%s\n' "$1" | sed -n "s/^RESOURCES home=$2 .* headroom_workers=\([^ ]*\).*/\1/p"
}

test_headroom_counts_whole_workers_above_the_floor() {
  local home proc avail expected
  home=$(make_home headroom-math)
  # Default policy: 8 GiB floor, 3 GiB per worker.
  for pair in 4:0 8:0 10:0 11:1 13:1 14:2 20:4 60:17; do
    avail=${pair%%:*}
    expected=${pair#*:}
    proc="$TMP_ROOT/proc-$avail"
    fm_test_proc_fixture "$proc" "$avail" 61 4.00 8
    run_fleet "$home" "$proc" --local
    expect_code 0 "$STATUS" "a readable host should exit 0 (avail $avail GiB)"
    assert_equals "$expected" "$(headroom_of "$OUT" local)" \
      "$avail GiB available should leave room for $expected workers"
  done
  assert_contains "$OUT" 'avail_gib=60 total_gib=61 load_1m=4.00 cpus=8 load_per_core=0.50' \
    "the row should carry the memory and load facts it was derived from"
  assert_contains "$OUT" 'POLICY floor_gib=8 per_worker_gib=3' "the row should name the policy it applied"
  pass "headroom is floor((available - 8 GiB) / 3 GiB), never negative"
}

test_both_policy_knobs_move_the_headroom() {
  local home proc
  home=$(make_home headroom-knobs)
  proc="$TMP_ROOT/proc-knobs"
  fm_test_proc_fixture "$proc" 9 16
  OUT=$(FM_HOME="$home" FM_PLACE_PROC_DIR="$proc" FM_PLACE_MIN_FREE_GIB=4 FM_PLACE_PER_WORKER_GIB=2 \
    "$FLEET" --local 2>&1)
  assert_equals 2 "$(headroom_of "$OUT" local)" "9 GiB over a 4 GiB floor at 2 GiB each is 2 workers"
  OUT=$(FM_HOME="$home" FM_PLACE_PROC_DIR="$proc" FM_PLACE_PER_WORKER_GIB=0 "$FLEET" --local 2>&1)
  STATUS=$?
  expect_code 2 "$STATUS" "a zero per-worker budget cannot size anything and must be refused"
  assert_contains "$OUT" 'FM_PLACE_PER_WORKER_GIB must be a positive integer' "the refusal should name the knob"
  pass "FM_PLACE_MIN_FREE_GIB and FM_PLACE_PER_WORKER_GIB set the rule"
}

test_every_registered_host_gets_a_row() {
  local home proc summary
  home=$(make_home all-hosts)
  proc="$TMP_ROOT/proc-all"
  fm_test_proc_fixture "$proc" 12 61
  register_remote_mate "$home" bertha roomy-host
  register_remote_mate "$home" timmy gone-host
  write_report roomy-host 21 31
  run_fleet "$home" "$proc"
  expect_code 3 "$STATUS" "an unreadable host should make the read exit 3"
  assert_equals 1 "$(headroom_of "$OUT" local)" "this host's row should be present"
  assert_equals 4 "$(headroom_of "$OUT" bertha)" "the reachable mate's row should carry its own headroom"
  assert_contains "$OUT" 'workers=3 worker_rss_gib=6.2' "the mate row should carry its live worker facts"
  assert_contains "$OUT" 'RESOURCES home=timmy host=gone-host headroom_workers=unknown error=reach: ssh: Could not resolve hostname gone-host' \
    "an unreachable mate should keep its row and say why it was not read"

  run_fleet "$home" "$proc" --summary
  summary=$OUT
  assert_equals 1 "$(printf '%s\n' "$summary" | wc -l | tr -d ' ')" "the summary should be exactly one line"
  assert_contains "$summary" 'roomy-host (bertha) 21/31 GiB free, load 0.50/core, 3 workers using 6.2 GiB, headroom 4' \
    "the summary should carry each host's facts"
  assert_contains "$summary" 'gone-host (timmy) unreadable: reach:' "the summary should name the unreadable host"

  run_fleet "$home" "$proc" --mate bertha
  expect_code 0 "$STATUS" "one reachable mate should read cleanly"
  assert_not_contains "$OUT" 'home=local' "--mate should read only that mate"
  run_fleet "$home" "$proc" --mate nobody
  expect_code 2 "$STATUS" "an unregistered mate is a usage error"

  if command -v jq >/dev/null 2>&1; then
    run_fleet "$home" "$proc" --json
    assert_equals '1 4 null' "$(printf '%s' "$OUT" | jq -r '[.hosts[].headroom_workers] | map(tostring) | join(" ")')" \
      "the JSON form should carry the same headroom per host, null when unread"
    assert_equals 'reach: ssh: Could not resolve hostname gone-host' \
      "$(printf '%s' "$OUT" | jq -r '.hosts[2].error')" "the JSON form should carry the unread host's reason"
  fi
  pass "every registered host is read; an unreadable one reports why"
}

# The probe's T3 Code facts on Linux: a 200 ms CPU sample read the pinned
# sampler's way and byte-precise memory, alongside unchanged headroom facts.
test_linux_probe_samples_cpu_and_bytes() {
  local home proc
  home=$(make_home linux-cpu)
  proc="$TMP_ROOT/proc-linux-cpu"
  fm_test_proc_fixture "$proc" 20 61 2.00 4
  fm_test_proc_cpu_fixture "$proc" 4 25
  run_fleet "$home" "$proc" --local
  expect_code 0 "$STATUS" "a readable host should exit 0"
  assert_contains "$OUT" 'avail_gib=20 total_gib=61 load_1m=2.00 cpus=4 load_per_core=0.50 workers=' \
    "the existing facts should be unchanged"
  assert_contains "$OUT" 'headroom_workers=4 cpu_util=0.250000 avail_bytes=21474836480 total_bytes=65498251264' \
    "a 25% busy sample and MemAvailable/MemTotal in bytes should be reported, ignoring iowait and the aggregate line"
  if command -v jq >/dev/null 2>&1; then
    run_fleet "$home" "$proc" --local --json
    assert_equals 'true' \
      "$(printf '%s' "$OUT" | jq -r '.hosts[0] | .cpu_util == 0.25 and .avail_bytes == 21474836480 and .total_bytes == 65498251264')" \
      "the JSON form should carry the same facts as numbers"
  fi

  fm_test_proc_cpu_fixture "$proc" 4 25 3
  run_fleet "$home" "$proc" --local
  assert_contains "$OUT" 'headroom_workers=4 cpu_util=? ' "a CPU count that changed between reads is no sample"

  proc="$TMP_ROOT/proc-linux-nocpu"
  fm_test_proc_fixture "$proc" 20 61 2.00 4
  run_fleet "$home" "$proc" --local
  expect_code 0 "$STATUS" "a host with no CPU counters is still read"
  assert_contains "$OUT" 'headroom_workers=4 cpu_util=? avail_bytes=21474836480' \
    "missing CPU counters are unobserved, never invented, and leave headroom unchanged"
  pass "the Linux probe reports a 200 ms CPU sample and byte-precise memory"
}

# The probe's T3 Code facts on macOS, run through the real snippet against
# stand-in macOS tools: valid, missing, and a host that never answers.
test_macos_probe_reads_cpu_and_bytes() {
  local home proc row
  home=$(make_home darwin-cpu)
  proc="$TMP_ROOT/proc-darwin"
  fm_test_proc_fixture "$proc" 20 61
  register_remote_mate "$home" timmy mac-valid
  register_remote_mate "$home" tina mac-missing
  register_remote_mate "$home" hung mac-hung
  register_remote_mate "$home" stuck mac-stuck
  write_darwin_host mac-missing none no-speculative
  write_darwin_host mac-hung hang full
  write_darwin_host mac-stuck none stuck
  if write_darwin_host mac-valid real full; then
    FM_FAKE_DARWIN_ROOT=$DARWIN_ROOT FM_PLACE_HOST_TIMEOUT=5 run_fleet "$home" "$proc"
    row=$(printf '%s\n' "$OUT" | grep '^RESOURCES home=timmy ')
    assert_contains "$row" 'avail_gib=12 total_gib=48 load_1m=1.60 cpus=16 ' "the macOS memory and load facts should be unchanged"
    assert_contains "$row" ' avail_bytes=13551665152 total_bytes=51539607552' \
      "available bytes should be free + inactive + speculative pages, without purgeable"
    printf '%s\n' "$row" | grep -Eq ' cpu_util=(0\.[0-9]{6}|1\.000000) ' || \
      fail "a JavaScript runtime in ~/.bun/bin should give a 0-1 CPU sample (row: $row)"
  else
    printf '# no node or bun on this host: the valid macOS CPU sample is not exercised\n'
    rm -rf "${DARWIN_ROOT:?}/mac-valid"
    FM_FAKE_DARWIN_ROOT=$DARWIN_ROOT FM_PLACE_HOST_TIMEOUT=5 run_fleet "$home" "$proc"
  fi
  expect_code 3 "$STATUS" "a host that never answers makes the read exit 3"
  row=$(printf '%s\n' "$OUT" | grep '^RESOURCES home=tina ')
  assert_contains "$row" 'avail_gib=12 total_gib=48 ' "missing T3 facts must not change the memory reading"
  assert_contains "$row" ' headroom_workers=1 ' "missing T3 facts must not change headroom"
  assert_contains "$row" ' avail_bytes=? total_bytes=51539607552' "a vm_stat without speculative pages leaves available bytes unobserved"
  # The snippet always searches /opt/homebrew/bin, so a Mac running this suite
  # with Homebrew's node or bun has a runtime even in this fixture.
  if [ -x /opt/homebrew/bin/node ] || [ -x /opt/homebrew/bin/bun ]; then
    printf '# /opt/homebrew/bin has a JavaScript runtime: the missing-runtime CPU case is not exercised\n'
  else
    assert_contains "$row" ' cpu_util=? ' "a macOS host with no JavaScript runtime has no CPU sample"
  fi
  row=$(printf '%s\n' "$OUT" | grep '^RESOURCES home=hung ')
  assert_contains "$row" 'avail_gib=12 total_gib=48 ' "a hung JavaScript runtime must not cost the host's memory facts"
  assert_contains "$row" ' headroom_workers=1 cpu_util=? avail_bytes=13551665152 ' \
    "a runtime that does not answer within its own 2 s bound leaves only the CPU sample unobserved"
  assert_contains "$OUT" 'RESOURCES home=stuck host=mac-stuck headroom_workers=unknown error=reach: the host did not answer within 5s, so its state is unknown' \
    "a probe that hangs is bounded by the whole-probe timeout and reported unknown"
  pass "the macOS probe reports the pinned sampler's facts, unobserved when missing, and is bounded"
}

test_headroom_counts_whole_workers_above_the_floor
test_both_policy_knobs_move_the_headroom
test_every_registered_host_gets_a_row
test_linux_probe_samples_cpu_and_bytes
test_macos_probe_reads_cpu_and_bytes

echo "ALL TESTS PASSED"
