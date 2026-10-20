#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement), plus the presentation record that lets a reader see
# each unchanged row in full once instead of on every drain; these tests
# exercise the real drain script over crafted status logs and assert on its
# printed output, not on the fold's own source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# --- bounded re-presentation of decisions the reader already read -------------
#
# The section re-printed its unchanged rows on every one of 386 drains across
# one night. It now presents each row in full once per reader, counts the rest,
# and prints the command that re-presents them; these cases pin that a row can
# only ever be counted by a reader this home can name, and that anything the
# reader has not seen - a new decision, a decision whose note changed, a new
# session, an unnamed caller - still arrives in full.

# Give <state> a named reader: a session lock whose pid is the token the
# presentation record is keyed to (bin/fm-lock.sh publishes the same file).
name_session() {  # <state> <pid>
  printf '%s\n' "$2" > "$1/.lock"
}

# The rows the section printed in full, without its header, count, or hints.
open_rows() {  # <drain-out>
  awk '/^OPEN DECISIONS \(still open/{f=1; next} /^OPEN DECISIONS:/{f=0} f' "$1"
}

# The one-line count of rows this reader was already shown in full.
count_line() {  # <drain-out>
  grep -F 'unchanged since this reader was shown them in full' "$1" || true
}

test_unchanged_decisions_are_presented_once_per_reader() {
  local dir state out rows
  dir=$(make_case presented-once)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  printf 'blocked [key=b]: second\n' >> "$state/t1.status"
  printf 'needs-decision [key=c]: third\n' >> "$state/t1.status"
  name_session "$state" 424242

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  rows=$(open_rows "$out")
  [ "$(printf '%s\n' "$rows" | grep -c 'needs-decision\|blocked')" = 3 ] \
    || fail "the first drain did not present every open decision in full: $(cat "$out")"
  [ -z "$(count_line "$out")" ] || fail "the first drain counted rows it had not yet presented: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  [ -z "$(open_rows "$out")" ] || fail "the second drain re-printed rows this reader already read: $(cat "$out")"
  count_line "$out" | grep -F '3 unchanged' >/dev/null \
    || fail "the second drain did not count the three unchanged decisions: $(cat "$out")"
  count_line "$out" | grep -F 'FM_OPEN_DECISIONS_REVEAL=1 bin/fm-wake-drain.sh' >/dev/null \
    || fail "the count line does not name how to re-present the full list: $(cat "$out")"
  count_line "$out" | grep -F 't1[a]' >/dev/null \
    || fail "the count line does not name the decisions it collapsed: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "third drain failed"
  [ -z "$(open_rows "$out")" ] || fail "a repeat drain re-printed already-presented rows: $(cat "$out")"
  count_line "$out" | grep -F '3 unchanged' >/dev/null || fail "the count is not stable across drains"
  pass "a reader sees each unchanged decision in full once and then only its count"
}

test_a_new_decision_prints_in_full_among_counted_rows() {
  local dir state out
  dir=$(make_case presented-new)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  printf 'needs-decision [key=b]: second\n' >> "$state/t1.status"
  name_session "$state" 777001

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "setup drain failed"
  printf 'blocked [key=c]: third, newly raised\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after a new decision"

  open_rows "$out" | grep -F 't1 [key=c] blocked: third, newly raised' >/dev/null \
    || fail "a decision raised after the first drain was not presented in full: $(cat "$out")"
  if open_rows "$out" | grep -F '[key=a]' >/dev/null; then
    fail "the new decision dragged an already-presented row back in: $(cat "$out")"
  fi
  count_line "$out" | grep -F '2 unchanged' >/dev/null \
    || fail "the unchanged rows were not counted alongside the new one: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "repeat drain failed"
  [ -z "$(open_rows "$out")" ] || fail "the newly presented row was re-printed on the next drain: $(cat "$out")"
  count_line "$out" | grep -F '3 unchanged' >/dev/null \
    || fail "the newly presented row did not join the counted set: $(cat "$out")"
  pass "a newly open decision arrives in full while unchanged rows stay counted"
}

test_a_changed_decision_note_is_presented_again() {
  local dir state out
  dir=$(make_case presented-changed)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: pick REST or RPC\n' > "$state/t1.status"
  name_session "$state" 777002

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "setup drain failed"
  printf 'needs-decision [key=a]: narrowed to REST or GraphQL\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the note changed"

  open_rows "$out" | grep -F 'narrowed to REST or GraphQL' >/dev/null \
    || fail "a decision whose note changed was counted instead of re-presented: $(cat "$out")"
  pass "a decision whose text changed is not the row that was presented and prints again"
}

test_reveal_re_presents_every_row_in_full() {
  local dir state out
  dir=$(make_case presented-reveal)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  printf 'needs-decision [key=b]: second\n' >> "$state/t1.status"
  name_session "$state" 777003

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "setup drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  [ -z "$(open_rows "$out")" ] || fail "setup error: rows were expected to be counted here"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_REVEAL=1 "$DRAIN" > "$out" \
    || fail "reveal drain failed"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "the reveal did not re-present an already-counted decision: $(cat "$out")"
  open_rows "$out" | grep -F 't1 [key=b] needs-decision: second' >/dev/null \
    || fail "the reveal presented only part of the open set: $(cat "$out")"
  [ -z "$(count_line "$out")" ] || fail "the reveal still counted rows it had just printed: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "post-reveal drain failed"
  [ -z "$(open_rows "$out")" ] || fail "the reveal left the reader's record stale: $(cat "$out")"
  pass "the reveal re-presents the full list and the reader stays recorded afterwards"
}

test_a_new_session_is_shown_every_decision_again() {
  local dir state out
  dir=$(make_case presented-new-session)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  name_session "$state" 777004

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first session drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  [ -z "$(open_rows "$out")" ] || fail "setup error: rows were expected to be counted here"

  # A restarted session owns the home now, so nothing in its context is known:
  # every row must arrive in full rather than inherit the previous session's read.
  name_session "$state" 777005
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "new session drain failed"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "a new session was shown only the previous session's count: $(cat "$out")"
  pass "a new session is shown every open decision in full"
}

test_a_reader_with_no_named_session_always_gets_the_full_list() {
  local dir state out
  dir=$(make_case presented-unnamed)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  printf 'needs-decision [key=b]: second\n' >> "$state/t1.status"
  # No state/.lock: this home cannot name the reader, so nothing may be counted.
  printf 'nonsense\n' > "$state/.lock.nope"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "an unnamed reader was counted instead of presented: $(cat "$out")"
  [ -z "$(count_line "$out")" ] || fail "an unnamed reader was counted against another reader's record"
  pass "an unnamed reader is always shown every open decision in full"
}

test_a_non_reader_caller_records_nothing_for_the_session() {
  local dir state out
  dir=$(make_case presented-non-reader)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  name_session "$state" 777008

  # The away-mode supervisor daemon drains this home, parses only the queue rows
  # out of a temp file, and deletes it, so no reader ever sees the section. It
  # must not spend this reader's credit: after it runs, the session's own drain
  # still presents the row in full.
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_NO_RECORD=1 "$DRAIN" > "$out" \
    || fail "the non-reader drain failed"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "the non-reader drain did not present the row in full: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "the session drain failed"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "a non-reader drain retired a decision the session reader never saw: $(cat "$out")"
  pass "a caller whose output no reader sees presents in full and records nothing"
}

test_a_record_path_that_is_not_a_readable_record_never_hides_a_decision() {
  local dir state out rc
  dir=$(make_case presented-unreadable-record)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=a]: first\n' > "$state/t1.status"
  name_session "$state" 777006
  # A directory sits where the record belongs, so the record can never be read
  # (and a plain mv would move the staged file inside it rather than record
  # anything). A record this home cannot read must never stand in for a
  # decision: the row prints in full on every drain.
  mkdir -p "$state/.open-decisions-presented.main"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with an unreadable record path"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out"; rc=$?
  [ "$rc" -eq 0 ] || fail "an advisory record failure changed the drain's exit status ($rc)"
  open_rows "$out" | grep -F 't1 [key=a] needs-decision: first' >/dev/null \
    || fail "an unreadable record hid a decision behind a count: $(cat "$out")"
  [ -z "$(ls -A "$state/.open-decisions-presented.main")" ] \
    || fail "the drain relocated its staged record into the unreadable path"
  pass "a record path that is not a readable record keeps presenting the full list"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_unchanged_decisions_are_presented_once_per_reader
test_a_new_decision_prints_in_full_among_counted_rows
test_a_changed_decision_note_is_presented_again
test_reveal_re_presents_every_row_in_full
test_a_new_session_is_shown_every_decision_again
test_a_reader_with_no_named_session_always_gets_the_full_list
test_a_record_path_that_is_not_a_readable_record_never_hides_a_decision
test_a_non_reader_caller_records_nothing_for_the_session
