#!/usr/bin/env bash
# tests/fm-classify-captain-call.test.sh - the captain-call text classes in
# bin/fm-classify-lib.sh: which held calls are routine agent chores that never
# reach the captain, and the consequence tier that ranks the rest. The discard
# approval is never read from words; only the explicit hold marker puts a row in
# it. Drives the REAL captain_call_class / captain_call_tier /
# captain_call_patterns functions and checks that the queue model
# (bin/fm-queue.sh), which receives the same patterns, classifies a call the same
# way and takes the discard class from the marker alone.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

test_discard_is_never_read_from_words_and_chores_stay_narrow() {
  assert_equals "captain" "$(captain_call_class "Cleanup refused: copy59 holds 45 files not on main. Keep or discard?")" \
    "even a refused cleanup is not a discard approval by its wording; only the hold marker makes it one"
  assert_equals "captain" "$(captain_call_class "Keep or discard the document copy?")" \
    "a question that reads like a discard question stays an ordinary captain call"
  assert_equals "chore" "$(captain_call_class "Clean up the copy after the merged PR")" \
    "cleanup after a merged PR is a chore"
  assert_equals "chore" "$(captain_call_class "Retire the stale data/old-task/status record left by the sweep")" \
    "a stale data fleet record is a chore"
  assert_equals "chore" "$(captain_call_class "The fleet copy is empty; remove it")" \
    "an empty fleet copy is a chore"
  assert_equals "captain" "$(captain_call_class "The document copy is empty; remove it")" \
    "a generic empty copy stays a captain call"
  assert_equals "captain" "$(captain_call_class "Approve the Sprint 3 scope for the parts team")" \
    "an ordinary question stays a captain call"
  assert_equals "captain" "$(captain_call_class "Approve deleting stale records from the production database")" \
    "deleting production data is never housekeeping, whatever words it shares with a chore"
  assert_equals "captain" "$(captain_call_class "Retire the stale rows in the customer database")" \
    "customer data stays a captain call even when the verb is a chore verb"
  assert_equals "captain" "$(captain_call_class "Should the release notes mention the uncommitted roadmap items?")" \
    "the word uncommitted alone, with no copy in the sentence, is not a discard approval"
  assert_equals "captain" "$(captain_call_class "Keep or discard the production database snapshot?")" \
    "a discard question about real data is never folded into the copy approval"
  assert_equals "captain" "$(captain_call_class "Keep or discard the old logo variants?")" \
    "keep or discard with no fleet copy named is an ordinary call"
  assert_equals "captain" "$(captain_call_class "Remove stale record: should we delete the old DNS record?")" \
    "a generic stale DNS record stays a captain call"
  pass "the discard approval is never read from words, and routine cleanup stays narrow"
}

test_tiers_follow_their_documented_order() {
  assert_equals "merge" "$(captain_call_tier "Rotate the deploy credential, then merge PR 12")" \
    "credential prose adds no tier above the merge named in the call"
  assert_equals "product" "$(captain_call_tier "Revoke the leaked SSH key")" \
    "credential prose alone stays product-tier"
  assert_equals "product" "$(captain_call_tier "Grant key customers access to beta")" \
    "key used as an adjective never implies credential risk"
  assert_equals "product" "$(captain_call_tier "Grant access to hosted password manager settings")" \
    "password product prose never implies credential risk"
  assert_equals "product" "$(captain_call_tier "Secure hosted password sign-in")" \
    "ordinary password feature work stays product-tier"
  assert_equals "product" "$(captain_call_tier "Display SSH key fingerprints")" \
    "ordinary SSH-key feature work stays product-tier"
  assert_equals "merge" "$(captain_call_tier "PR1951 is green; merge it?")" "a merge call"
  assert_equals "merge" "$(captain_call_tier "Delete the Vigil v1 image")" "an irreversible delete ranks with merges"
  assert_equals "product" "$(captain_call_tier "Approve the sprint plan")" \
    "a word that merely contains pr is not a PR"
  assert_equals "money" "$(captain_call_tier "Which RAM to buy, 2,311 USD")" "a purchase"
  assert_equals "trivia" "$(captain_call_tier "Optional: rename the tab")" "an optional cosmetic call"
  assert_equals "product" "$(captain_call_tier "Choose the onboarding flow")" "everything else is product"
  pass "text consequence tiers apply in their documented order"
}

test_an_override_reaches_every_consumer() {
  local out
  out=$(FM_CLASSIFY_CHORE_RE='tidy the shelf' bash -c '. "$1"; captain_call_class "please tidy the shelf"; captain_call_patterns' _ "$ROOT/bin/fm-classify-lib.sh")
  assert_contains "$out" "chore" "an overridden chore pattern classifies with the override"
  assert_contains "$out" "$(printf 'chore\ttidy the shelf')" \
    "the pattern list hands the override to consumers outside bash"
  pass "an overridden pattern reaches both the functions and the published pattern list"
}

test_the_queue_model_classifies_like_the_library() {
  local tmp snap reason state
  tmp=$(fm_test_tmproot fm-classify-captain-call)
  snap=$tmp/snapshot.json
  jq -n --arg home "$tmp" '
    def held($id; $reason; $discard): {order: 1, state: "queued", structured: true, id: $id, title: $id, repo: "alpha",
      kind: "ship", hold_kind: "captain", hold_bucket: "live", captain_actionable: true, hold_until: null,
      hold_discard: $discard,
      hold_age_days: 1, hold_reason: $reason, blocked_by_ids: [], unresolved_blocker_ids: [], links: [],
      body_lines: [], since: "2026-01-01", project_resolution: {status: "resolved", project: "alpha", token: "alpha"}};
    {schema: "fm-fleet-snapshot.v1", generated: "2026-06-01T12:00:00Z", fm_home: $home,
     backlog: {records: [held("chore-row"; "Clean up the copy after the merged PR"; false),
                         held("marked-row"; "Teardown refused: 3 files unlanded."; true),
                         held("worded-row"; "Keep or discard the document copy?"; false)]},
     tasks: [], scout_reports: [], main_inventory: {valid: true},
     secondmate_current: {records: [], total: 0, shown: 0, truncated: []}}' > "$snap"
  state=$(FM_QUEUE_SNAPSHOT="$snap" FM_QUEUE_TODAY=2026-06-01 "$ROOT/bin/fm-queue.sh" --json \
    | jq -r '[.projects[].rows[] | "\(.id)=\(.state)/\(.call_class)"] | sort | join(",")')
  reason="chore-row=agent chore/$(captain_call_class "chore-row Clean up the copy after the merged PR"),marked-row=waiting on you/discard,worded-row=waiting on you/$(captain_call_class "worded-row Keep or discard the document copy?")"
  assert_equals "$reason" "$state" "the queue model agrees with the library on text and takes discard from the marker alone"
  pass "the queue model classifies a held call as the library does, with discard from the marker only"
}

test_discard_is_never_read_from_words_and_chores_stay_narrow
test_tiers_follow_their_documented_order
test_an_override_reaches_every_consumer
test_the_queue_model_classifies_like_the_library
