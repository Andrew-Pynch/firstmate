#!/usr/bin/env bash
# tests/fm-dead-records.test.sh - bin/fm-dead-records.sh must hand the owner a
# guarded teardown only for a gone-endpoint record that is unheld, has no open
# decision, has a clean recorded copy, and carries merged-PR or done evidence;
# every other record is named with the reason it is not a candidate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-dead-records.sh"
TMP_ROOT=$(fm_test_tmproot fm-dead-records-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
URL=https://github.com/acme/widget/pull

# gh answers `pr view` with the state named by the PR number's last digit:
# 1 MERGED, 2 OPEN, anything else unreadable.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "${3##*/}" in
  *1) s=MERGED ;;
  *2) s=OPEN ;;
  *) exit 1 ;;
esac
printf '{"state":"%s","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"abc","mergedAt":null,"statusCheckRollup":[]}\n' "$s"
SH
chmod +x "$FAKEBIN/gh"

CLEAN_COPY="$TMP_ROOT/clean"
DIRTY_COPY="$TMP_ROOT/dirty"
fm_git_init_commit "$CLEAN_COPY" || fail "could not create the clean fixture copy"
fm_git_init_commit "$DIRTY_COPY" || fail "could not create the dirty fixture copy"
printf 'x\n' > "$DIRTY_COPY/uncommitted.txt"

# task <id> <endpoint-exists> <backlog-state> <hold|null> <decisions> <copy|null> <pr|null> <last-event>
task() {
  jq -n --arg id "$1" --argjson alive "$2" --arg b "$3" --argjson hold "$4" --argjson dec "$5" \
    --argjson wt "$6" --argjson pr "$7" --arg last "$8" '{
      id: $id, kind: "ship", remote: null,
      endpoint: {exists: $alive},
      backlog: {state: $b, hold_kind: $hold, pr_url: null},
      hints: {open_decisions: [range(0; $dec) | "k"]},
      paths: {worktree: (if $wt == null then null else {path: $wt, present: true} end),
              status_log: {last_event: {state: $last}}},
      pr: (if $pr == null then null else {url: $pr} end)
    }'
}

SNAP="$TMP_ROOT/snapshot.json"
{
  task live-one true in_flight null 0 "\"$CLEAN_COPY\"" "\"$URL/11\"" working
  task held-merged false in_flight '"external"' 0 "\"$CLEAN_COPY\"" "\"$URL/21\"" 'done'
  task decision-open false in_flight null 1 "\"$CLEAN_COPY\"" null 'done'
  task dirty-merged false in_flight null 0 "\"$DIRTY_COPY\"" "\"$URL/31\"" 'done'
  task pr-still-open false in_flight null 0 "\"$CLEAN_COPY\"" "\"$URL/42\"" 'done'
  task merged-clean false in_flight null 0 "\"$CLEAN_COPY\"" "\"$URL/51\"" 'done'
  task row-done false 'done' null 0 null null working
  task no-evidence false in_flight null 0 "\"$CLEAN_COPY\"" null working
  task done-only false in_flight null 0 "\"$CLEAN_COPY\"" null 'done'
} | jq -s '{schema: "fm-fleet-snapshot.v1", tasks: .}' > "$SNAP"

OUT=$(PATH="$FAKEBIN:$PATH" "$INVENTORY" --snapshot "$SNAP" 2>&1) || fail "inventory failed: $OUT"

test_only_proven_records_become_candidates() {
  assert_contains "$OUT" "candidate merged-clean kind=ship backlog=in_flight pr=$URL/51 pr merged" "a merged, clean, unheld record was not a candidate"
  assert_contains "$OUT" "candidate row-done kind=ship backlog=done" "a Done backlog row was not a candidate"
  assert_contains "$OUT" "teardown: bin/fm-teardown.sh merged-clean" "a candidate got no guarded teardown line"
  assert_not_contains "$OUT" "--force" "the inventory proposed a forced teardown"
  [ "$(printf '%s\n' "$OUT" | grep -c '^teardown:')" = 2 ] || fail "unexpected teardown lines: $OUT"
  pass "only unheld, clean records with a merged PR or a Done row become guarded teardown candidates"
}

test_refusals_name_their_reason() {
  assert_contains "$OUT" "held held-merged kind=ship backlog=in_flight pr=$URL/21 hold=external pr_state=MERGED" "a held record with a merged PR was not shown as held with its PR state"
  assert_contains "$OUT" "open-decision decision-open" "an open decision did not refuse"
  assert_contains "$OUT" "dirty dirty-merged kind=ship backlog=in_flight pr=$URL/31 uncommitted=1" "an uncommitted copy did not refuse"
  assert_contains "$OUT" "pr-open pr-still-open" "an open PR did not refuse"
  assert_contains "$OUT" "undetermined no-evidence" "a record with no done evidence was not left undetermined"
  assert_contains "$OUT" "done-unproven done-only" "a done event without a PR or Done row became a teardown candidate"
  assert_not_contains "$OUT" "live-one" "a live endpoint was listed without --all"
  assert_contains "$OUT" "summary: live=1 held=1 open-decision=1 dirty=1 pr-open=1 candidate=2 done-unproven=1 undetermined=1" "the summary miscounted the verdicts"
  pass "every non-candidate record names why it is not handed to teardown"
}

test_rejects_non_snapshot_input() {
  local rc=0 out
  printf '{"tasks":[]}\n' > "$TMP_ROOT/bad.json"
  out=$("$INVENTORY" --snapshot "$TMP_ROOT/bad.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "non-snapshot input"
  assert_contains "$out" "not an fm-fleet-snapshot.v1 document" "the refusal did not name the expected schema"
  pass "input that is not a fleet snapshot is refused"
}

test_only_proven_records_become_candidates
test_refusals_name_their_reason
test_rejects_non_snapshot_input
