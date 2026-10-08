#!/usr/bin/env bash
# tests/fm-fleet-resources.test.sh - the worker-headroom rule and the fleet
# resource read in bin/fm-fleet-resources.sh (rule owner:
# bin/fm-host-probe-lib.sh).
#
# What this suite pins: headroom_workers at and around the memory floor, that
# both policy knobs move it, that every registered host gets a row and an
# unreachable one says why instead of disappearing, and the one-line summary and
# JSON forms. Local memory is driven through FM_PLACE_PROC_DIR and remote hosts
# through a fake ssh, so no real machine's load decides a verdict.
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
# unresolvable host.
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
report=${FM_FAKE_SSH_REPORTS:-}/$host.report
[ -f "$report" ] || {
  printf 'ssh: Could not resolve hostname %s\n' "$host" >&2
  exit 255
}
cat "$report"
SH
chmod +x "$FAKEBIN/ssh"

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

test_headroom_counts_whole_workers_above_the_floor
test_both_policy_knobs_move_the_headroom
test_every_registered_host_gets_a_row

echo "ALL TESTS PASSED"
