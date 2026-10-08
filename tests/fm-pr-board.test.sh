#!/usr/bin/env bash
# tests/fm-pr-board.test.sh - bin/fm-pr-board.sh must re-read only open pull
# requests whose mergeability GitHub is still computing, stop at its bound and
# say so, report merged pull requests as merged without a mergeability verdict,
# and board exactly the records that carry a pr= URL.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-pr-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-board-tests)

# make_fake <dir>: a gh that answers `pr view <url> --json ...` from
# <dir>/answers/<number>.<n>.json, where <n> is that PR's read count (falling
# back to the highest answer present), and counts reads in <dir>/reads/<number>.
make_fake() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/answers" "$dir/reads" "$dir/state"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-} ${2:-}" = "pr view" ] || exit 1
num=${3##*/}
count=$(( $(cat "$FAKE_DIR/reads/$num" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$FAKE_DIR/reads/$num"
i=$count
while [ "$i" -gt 0 ] && [ ! -f "$FAKE_DIR/answers/$num.$i.json" ]; do i=$((i - 1)); done
[ "$i" -gt 0 ] || exit 1
cat "$FAKE_DIR/answers/$num.$i.json"
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

answer() {  # <dir> <number> <read-n> <state> <mergeable> [mergedAt]
  printf '{"state":"%s","isDraft":false,"mergeable":"%s","mergeStateStatus":"%s","headRefOid":"0123456789abcdef","mergedAt":%s,"statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]}\n' \
    "$4" "$5" "$([ "$5" = MERGEABLE ] && echo CLEAN || echo UNKNOWN)" "$([ -n "${6:-}" ] && printf '"%s"' "$6" || echo null)" \
    > "$1/answers/$2.$3.json"
}

run_board() {  # <dir> <fakebin> [args...]
  local dir=$1 fakebin=$2
  shift 2
  FAKE_DIR=$dir PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_PR_BOARD_POLL=1 "$BOARD" "$@" 2>&1
}

URL=https://github.com/acme/widget/pull

test_unknown_resolves_within_the_bound() {
  local dir fakebin out
  dir="$TMP_ROOT/resolves"
  fakebin=$(make_fake "$dir")
  answer "$dir" 11 1 OPEN UNKNOWN
  answer "$dir" 11 3 OPEN MERGEABLE
  out=$(run_board "$dir" "$fakebin" --wait 10 "$URL/11") || fail "board failed: $out"
  assert_contains "$out" "mergeable=MERGEABLE merge_state=CLEAN" "a mergeability that resolved within the bound was not reported"
  assert_contains "$out" "checks=3 failing=1 pending=1" "check buckets were miscounted"
  assert_equals 3 "$(cat "$dir/reads/11")" "UNKNOWN was not re-read until it resolved"
  pass "an open pull request reading UNKNOWN is re-read until GitHub answers"
}

test_unknown_stops_at_the_bound() {
  local dir fakebin out
  dir="$TMP_ROOT/bounded"
  fakebin=$(make_fake "$dir")
  answer "$dir" 12 1 OPEN UNKNOWN
  out=$(run_board "$dir" "$fakebin" --wait 2 "$URL/12") || fail "board failed: $out"
  assert_contains "$out" "mergeable=UNKNOWN(after 2s)" "a still-computing pull request did not name the bound it waited"
  assert_equals 3 "$(cat "$dir/reads/12")" "the re-read count did not match a 2s bound at 1s polling"
  pass "a pull request still UNKNOWN at the bound is reported as still computing"
}

test_merged_is_not_re_read() {
  local dir fakebin out
  dir="$TMP_ROOT/merged"
  fakebin=$(make_fake "$dir")
  answer "$dir" 13 1 MERGED UNKNOWN 2026-10-05T22:39:29Z
  out=$(run_board "$dir" "$fakebin" --wait 5 "$URL/13") || fail "board failed: $out"
  assert_contains "$out" "state=MERGED" "a merged pull request was not reported as merged"
  assert_contains "$out" "mergeable=n/a merge_state=n/a" "a merged pull request carried a mergeability verdict"
  assert_contains "$out" "merged_at=2026-10-05T22:39:29Z" "the merge time was not reported"
  assert_equals 1 "$(cat "$dir/reads/13")" "a merged pull request was re-read"
  pass "a merged pull request is reported once as merged, with no mergeability verdict"
}

test_recorded_tasks_are_boarded() {
  local dir fakebin out
  dir="$TMP_ROOT/recorded"
  fakebin=$(make_fake "$dir")
  answer "$dir" 14 1 OPEN MERGEABLE
  fm_write_meta "$dir/state/alpha.meta" "kind=ship" "pr=$URL/14"
  fm_write_meta "$dir/state/beta.meta" "kind=ship"
  out=$(run_board "$dir" "$fakebin") || fail "board failed: $out"
  assert_contains "$out" "alpha $URL/14 state=OPEN" "a recorded pr= was not boarded under its task"
  assert_not_contains "$out" "beta" "a record with no pr= was boarded"
  out=$(run_board "$dir" "$fakebin" alpha) || fail "task operand failed: $out"
  assert_contains "$out" "alpha $URL/14" "a task-id operand did not resolve its recorded pr="
  pass "only records carrying pr= are boarded, by default and by task id"
}

test_unsupported_and_unreadable_fail() {
  local dir fakebin out rc
  dir="$TMP_ROOT/unsupported"
  fakebin=$(make_fake "$dir")
  rc=0
  out=$(run_board "$dir" "$fakebin" https://gitlab.example.com/g/p/-/merge_requests/3 "$URL/99") || rc=$?
  expect_code 1 "$rc" "an unsupported and an unreadable pull request"
  assert_contains "$out" "merge_requests/3 unsupported" "a GitLab URL was not reported unsupported"
  assert_contains "$out" "$URL/99 unreadable" "an unreadable pull request was not reported"
  pass "unsupported and unreadable pull requests are named and fail the run"
}

test_unknown_resolves_within_the_bound
test_unknown_stops_at_the_bound
test_merged_is_not_re_read
test_recorded_tasks_are_boarded
test_unsupported_and_unreadable_fail
