#!/usr/bin/env bash
# tests/fm-authority-amend.test.sh - one-step authority propagation.
#
# bin/fm-authority-amend.sh exists so a mid-task authority change cannot sit
# half-applied while an owner keeps obeying superseded words (the 86-minute
# stale credential restriction of 2026-09-13). These tests drive the real
# executable over a stubbed tmux and pin:
#   1. The named task's brief `## Captain's intent` gains the captain's words,
#      the same words land as one durable record in its steering inbox, and the
#      report names the task as steered with an acknowledgement still pending.
#   2. A task the caller did not name is byte-for-byte untouched: no brief edit
#      and no inbox record.
#   3. The words stay inside the intent subsection, never in `## Firstmate
#      spec`, and repeated amendments leave one block per correction with no
#      growing run of blank lines.
#   4. A secret-shaped body is refused whole (shape named, value never printed),
#      with no brief edit and no record anywhere.
#   5. An owner's acknowledgement move into handled/ is reported as
#      `ack=acknowledged` once --wait observes it.
#   6. A wildcard or unresolved id, an operator-address opening, and a body
#      carrying a markdown heading are each refused with nothing changed.
#   7. A recorded brief with no live owner, and a charter brief with no task
#      intent, are still handled with their real outcome reported.
#   8. Naming one task twice appends and steers once.
# Nothing here asserts script source; every verdict comes from the brief files,
# the inbox records, and the script's own report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dod-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

AMEND="$ROOT/bin/fm-authority-amend.sh"
TMP_ROOT=$(fm_test_tmproot fm-authority-amend)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

CAPTAIN_WORDS='Copy the staging credential across hosts; this supersedes the earlier cross-host exclusion.'
SEED_INTENT='Keep the cross-host credential transfer out of scope.'

setup_case() { # <name> -> echoes the case dir
  local name=$1 dir fb
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data"
  fb=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fb"
  fm_test_spawn_brief "$dir/home" t_aff "$SEED_INTENT"
  fm_test_spawn_brief "$dir/home" t_other 'Land the widget fix.'
  fm_write_meta "$dir/home/state/t_aff.meta" "window=sess:fm-t_aff" "kind=ship" "harness=claude"
  fm_write_meta "$dir/home/state/t_other.meta" "window=sess:fm-t_other" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

run_amend() { # <dir> <out-file> [args...] -> amend exit status
  local dir=$1 out=$2
  shift 2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    "$AMEND" "$@" >"$out" 2>&1
}

brief_path() { printf '%s' "$1/home/data/$2/brief.md"; }

intent_body() { # <brief>
  fm_brief_task_heading_body "$1" "## Captain's intent"
}

spec_body() { # <brief>
  fm_brief_task_heading_body "$1" "## Firstmate spec"
}

inbox_records() { # <dir> <id> -> one record path per line
  local dir=$1 id=$2 f
  for f in "$dir/home/state/$id.inbox"/*.msg; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
  done
  return 0
}

record_count() { # <dir> <id>
  inbox_records "$1" "$2" | wc -l | tr -d ' '
}

msg_count() { # <dir>
  local dir=$1 n=0 f
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

handled_count() { # <dir> <id>
  msg_count "$1/home/state/$2.inbox/handled"
}

max_blank_run() { # <file>
  awk 'BEGIN { m = 0 }
    /^[[:space:]]*$/ { c++; if (c > m) m = c; next }
    { c = 0 }
    END { print m + 0 }' "$1"
}

file_mode() { stat -c %a "$1" 2>/dev/null || /usr/bin/stat -f %Lp "$1" 2>/dev/null; }

test_amends_named_task_only() {
  local dir out rc record other_before before_aff
  dir=$(setup_case amends-named)
  other_before="$dir/t_other.brief.before"
  before_aff="$dir/t_aff.brief.before"
  cp "$(brief_path "$dir" t_other)" "$other_before"
  cp "$(brief_path "$dir" t_aff)" "$before_aff"

  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" t_aff
  rc=$?
  out=$(cat "$dir/out")
  expect_code 0 "$rc" 'a named, resolvable task propagates'
  assert_contains "$out" "t_aff: intent=amended steer=enqueued" 'the affected task is reported amended and steered'
  assert_contains "$out" 'ack=pending' 'the steer is reported as not yet acknowledged'
  assert_not_contains "$out" 't_other' 'an unnamed task never appears in the report'

  assert_contains "$(intent_body "$(brief_path "$dir" t_aff)")" "$SEED_INTENT" \
    'the original ask survives the amendment'
  assert_contains "$(intent_body "$(brief_path "$dir" t_aff)")" "$CAPTAIN_WORDS" \
    'the corrected authority lands in the intent subsection'
  assert_not_contains "$(spec_body "$(brief_path "$dir" t_aff)")" "$CAPTAIN_WORDS" \
    'the build spec is not where captain words go'
  assert_equals "$(spec_body "$before_aff")" "$(spec_body "$(brief_path "$dir" t_aff)")" \
    'the build spec is byte-identical after the amendment'
  assert_equals 0 "$(diff "$before_aff" "$(brief_path "$dir" t_aff)" | grep -c '^<')" \
    'the amendment only adds lines; no existing brief line changes or disappears'

  cmp -s "$other_before" "$(brief_path "$dir" t_other)" ||
    fail 'a task outside the named set had its brief rewritten'
  assert_equals 0 "$(record_count "$dir" t_other)" 'a task outside the named set received a steer'
  assert_equals 1 "$(record_count "$dir" t_aff)" 'the affected task receives exactly one record'

  record=$(inbox_records "$dir" t_aff)
  assert_equals "$CAPTAIN_WORDS" "$(fm_task_inbox_body "$record")" \
    'the durable record carries exactly the captain words'
  assert_equals 0 "$(handled_count "$dir" t_aff)" \
    'an unacknowledged record is still pending in the inbox'
  pass 'named task amended and steered, unnamed task untouched'
}

test_repeated_amendment_one_block_each() {
  local dir rc
  dir=$(setup_case blank-run)
  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" t_aff ||
    fail 'the first amendment should succeed'
  run_amend "$dir" "$dir/out2" --authority 'A second correction for the same task.' t_aff ||
    fail 'a second amendment should succeed'
  rc=$(intent_body "$(brief_path "$dir" t_aff)" | grep -c -F -- "$CAPTAIN_WORDS")
  assert_equals 1 "$rc" 'the first amendment is present exactly once'
  rc=$(intent_body "$(brief_path "$dir" t_aff)" | grep -c -F -- 'A second correction for the same task.')
  assert_equals 1 "$rc" 'the second amendment is present exactly once'
  assert_equals 1 "$(max_blank_run "$(brief_path "$dir" t_aff)")" \
    'the blank line before the next heading does not accumulate'
  case "$(spec_body "$(brief_path "$dir" t_aff)")" in
    *'A second correction'*) fail 'a later amendment leaked into the build spec' ;;
  esac
  pass 'repeated amendments stack one block each'
}

test_secret_body_refused() {
  local dir out rc before_aff before_other
  dir=$(setup_case secret)
  before_aff="$dir/t_aff.brief.before"
  before_other="$dir/t_other.brief.before"
  cp "$(brief_path "$dir" t_aff)" "$before_aff"
  cp "$(brief_path "$dir" t_other)" "$before_other"

  run_amend "$dir" "$dir/out" --authority \
    'Use the token ghp_A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8 for the copy.' t_aff
  rc=$?
  out=$(cat "$dir/out")
  expect_code 1 "$rc" 'a secret-shaped body is refused'
  assert_contains "$out" 'github-token' 'the refusal names the shape it matched'
  assert_not_contains "$out" 'A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8' \
    'the refusal never prints the value it matched'
  cmp -s "$before_aff" "$(brief_path "$dir" t_aff)" || fail 'a refused body still rewrote the brief'
  cmp -s "$before_other" "$(brief_path "$dir" t_other)" || fail 'a refused body touched another task'
  assert_equals 0 "$(record_count "$dir" t_aff)" 'a refused body still enqueued a steer'
  pass 'a secret-shaped body is refused whole'
}

test_acknowledgement_reported() {
  local dir out rc mover
  dir=$(setup_case ack)
  (
    # The owner reads its inbox a beat after the steer lands, so the first
    # acknowledgement poll observes a still-pending record and the wait has to
    # actually wait for it.
    sleep 0.5
    while :; do
      for f in "$dir/home/state/t_aff.inbox"/*.msg; do
        [ -e "$f" ] || continue
        mv "$f" "$dir/home/state/t_aff.inbox/handled/" 2>/dev/null || true
      done
      sleep 0.05
    done
  ) &
  mover=$!
  run_amend "$dir" "$dir/out" --wait 8 --authority "$CAPTAIN_WORDS" t_aff
  rc=$?
  kill "$mover" 2>/dev/null || true
  wait "$mover" 2>/dev/null || true
  out=$(cat "$dir/out")
  expect_code 0 "$rc" 'waiting for an acknowledgement does not change the outcome'
  assert_contains "$out" 'ack=acknowledged' 'the owner acknowledgement move is reported'
  assert_equals 0 "$(record_count "$dir" t_aff)" 'an acknowledged record leaves the inbox root'
  assert_equals 1 "$(handled_count "$dir" t_aff)" 'the acknowledged record sits in handled/'
  pass 'an owner acknowledgement is reported'
}

test_refusal_boundaries() {
  local dir rc before
  dir=$(setup_case refusals)
  before="$dir/t_aff.brief.before"
  cp "$(brief_path "$dir" t_aff)" "$before"

  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" '*'
  rc=$?
  expect_code 1 "$rc" 'a wildcard id is refused'
  assert_contains "$(cat "$dir/out")" 'not a literal task id' 'the wildcard refusal explains the id rule'

  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" never-dispatched
  rc=$?
  expect_code 1 "$rc" 'an unresolvable id is refused'
  assert_contains "$(cat "$dir/out")" 'no readable brief' 'the refusal names the missing brief'

  run_amend "$dir" "$dir/out" --authority 'Captain, copy the credential across hosts.' t_aff
  rc=$?
  expect_code 1 "$rc" 'an operator-address opening is refused'
  assert_contains "$(cat "$dir/out")" 'operator label or address' 'the refusal explains the provenance rule'

  run_amend "$dir" "$dir/out" \
    --authority "$(printf 'Copy the credential.\n## Notes\nMore detail.')" t_aff
  rc=$?
  expect_code 1 "$rc" 'a heading inside the words is refused'
  assert_contains "$(cat "$dir/out")" 'markdown heading line' 'the refusal names the hazard'

  cmp -s "$before" "$(brief_path "$dir" t_aff)" || fail 'a refused run still rewrote the brief'
  assert_equals 0 "$(record_count "$dir" t_aff)" 'a refused run still enqueued a steer'
  pass 'bad ids and hazardous bodies are refused with nothing changed'
}

test_without_live_owner_and_charter_brief() {
  local dir rc
  dir=$(setup_case no-owner)
  rm -f "$dir/home/state/t_aff.meta"

  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" t_aff
  rc=$?
  expect_code 0 "$rc" 'a recorded brief with no live owner is still amended'
  assert_contains "$(cat "$dir/out")" 'steer=no-owner' 'the missing owner is reported'
  assert_contains "$(intent_body "$(brief_path "$dir" t_aff)")" "$CAPTAIN_WORDS" \
    'the durable brief still carries the new authority'
  assert_equals 0 "$(record_count "$dir" t_aff)" 'a task with no owner cannot have received a steer'

  mkdir -p "$dir/home/data/mate1"
  printf '# Charter\nDo the mate work.\n' >"$dir/home/data/mate1/brief.md"
  fm_write_meta "$dir/home/state/mate1.meta" "window=sess:fm-mate1" "kind=secondmate" "harness=claude"
  run_amend "$dir" "$dir/out2" --authority "$CAPTAIN_WORDS" mate1
  rc=$?
  expect_code 0 "$rc" 'a charter brief is steered without a task intent to amend'
  assert_contains "$(cat "$dir/out2")" 'intent=skipped-not-a-task-brief' \
    'the charter brief is reported as having no task intent to amend'
  assert_contains "$(cat "$dir/out2")" 'steer=enqueued' 'the charter owner still receives the steer'
  assert_equals 'Do the mate work.' "$(cat "$dir/home/data/mate1/brief.md" | sed -n '2p')" \
    'a charter brief is left exactly as it was'
  pass 'no-owner and non-task-brief outcomes are reported, not invented'
}

test_repeated_id_applies_once() {
  local dir rc
  dir=$(setup_case repeated-id)
  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" t_aff t_aff
  rc=$?
  expect_code 0 "$rc" 'naming one task twice is accepted'
  assert_equals 1 "$(record_count "$dir" t_aff)" 'naming one task twice steered it twice'
  rc=$(intent_body "$(brief_path "$dir" t_aff)" | grep -c -F -- "$CAPTAIN_WORDS")
  assert_equals 1 "$rc" 'naming one task twice appended the words once'
  pass 'a repeated id is amended and steered once'
}

test_brief_mode_preserved() {
  local dir before_mode after_mode
  dir=$(setup_case mode)
  before_mode=$(file_mode "$(brief_path "$dir" t_aff)")
  run_amend "$dir" "$dir/out" --authority "$CAPTAIN_WORDS" t_aff ||
    fail 'the amendment should succeed'
  after_mode=$(file_mode "$(brief_path "$dir" t_aff)")
  assert_equals "$before_mode" "$after_mode" 'the amended brief keeps its original mode'
  pass 'amending a brief preserves its mode'
}

test_amends_named_task_only
test_repeated_amendment_one_block_each
test_secret_body_refused
test_acknowledgement_reported
test_refusal_boundaries
test_without_live_owner_and_charter_brief
test_repeated_id_applies_once
test_brief_mode_preserved
