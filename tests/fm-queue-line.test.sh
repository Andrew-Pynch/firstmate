#!/usr/bin/env bash
# Behavior tests for visibility slice 7: the always-visible line.
#
# Two subjects, both driven through a public interface and nothing else:
#   bin/fm-queue-line.sh              its stdout and exit status over a fixture fleet
#   .omp/extensions/fm-primary-queue-line.ts
#                                     its handler contract over a fake omp API, loaded
#                                     for real by node's TypeScript stripping (the same
#                                     loader tests/fm-omp-harness.test.sh already uses)
#
# What the acceptance line requires, and where each requirement is proved:
#   nothing waiting  -> no line at all                       test_line_absent_when_nothing_waits
#   something waits  -> names the top item and the rest      test_names_top_and_remaining_count
#   changed answer   -> the line changes without a restart   test_extension_repins_on_a_turn_boundary
#   counts agree     -> with the queue program               test_count_agrees_with_the_queue_program
# shellcheck disable=SC2016 # The node programs below are single-quoted so the shell leaves ${...} to node.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINE="$ROOT/bin/fm-queue-line.sh"
QUEUE="$ROOT/bin/fm-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-line)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$LINE" ] || fail "bin/fm-queue-line.sh is missing or not executable"

# row <id> <title> <hold_kind|-> <hold_bucket|-> <until|-> <age|-> <state>:
# one canonical-snapshot backlog record.
row() {  # <id> <title> <kind> <bucket> <until> <age> <state>
  jq -cn --arg id "$1" --arg title "$2" --arg kind "$3" --arg bucket "$4" \
    --arg until "$5" --arg age "$6" --arg state "$7" '
    {order: 1, state: $state, structured: true, id: $id, title: $title, repo: "alpha", kind: "ship",
     captain_actionable: ($kind == "captain"),
     hold_kind: (if $kind == "-" then null else $kind end),
     hold_bucket: (if $bucket == "-" then null else $bucket end),
     hold_until: (if $until == "-" then null else $until end),
     hold_age_days: (if $age == "-" then null else ($age | tonumber) end),
     hold_reason: (if $kind == "captain" then "Answer this one." else null end),
     blocked_by_ids: [], unresolved_blocker_ids: [], links: [], body_lines: [],
     since: "2026-01-01",
     project_resolution: {status: "resolved", project: "alpha", token: "alpha"}}'
}

# dead_task <id>: a worker record whose endpoint is gone and whose queue row is
# in flight, which the snapshot reports as a missing endpoint rather than a state.
dead_task() {  # <id>
  jq -cn --arg id "$1" '
    {id: $id, kind: "ship", mode: "local-only", yolo: "off", project: "/tmp/alpha",
     harness: "claude", backend: "tmux", remote: null, spawn_gen: null, secondmate_projects: [],
     endpoint: {target: "sess:1", exists: false, agent_alive: "not_checked"},
     paths: {meta: {path: null, present: false}, status_log: {path: null, present: false, kind: "event_history", last_event: null},
             worktree: {path: null, present: false}, home: {path: null, present: false}, report: {path: null, present: false}},
     current_state: {state: "unknown", source: "none", detail: "backend target gone: sess:1",
                     observed_at: "2026-01-02T03:04:05Z", freshness: "fresh"},
     backlog: {id: $id, repo: "alpha", state: "in_flight"},
     pr: {url: null, source: "absent"}, hints: {}, actions: {}}'
}

# write_fixture <home> <path> <records-json> [tasks-json]
write_fixture() {  # <home> <path> <records> [tasks]
  local home=$1 path=$2 records=$3 tasks=${4:-[]}
  jq -n --arg home "$home" --argjson records "$records" --argjson tasks "$tasks" '
    {schema: "fm-fleet-snapshot.v1", generated: "2026-01-02T03:04:05Z", fm_home: $home,
     roots: {state: ($home + "/state"), data: ($home + "/data"), config: ($home + "/config"), projects: ($home + "/projects")},
     backlog: {path: ($home + "/data/backlog.md"), present: true, records: $records},
     tasks: $tasks, scout_reports: [],
     main_inventory: {valid: true, reason: null, orphan_in_flight: [], unstructured_current_count: 0},
     secondmate_current: {records: [], total: 0, shown: 0, truncated: []},
     secondmate_landed: {records: [], truncated: [], unreadable: [], partial: []},
     secondmate_guidance: {note: "none"}}' > "$path"
}

# The four waiting rows every case that needs "something is waiting" reuses:
# one deferred to a date that has long passed, one waiting the longest, one
# fresh, one with no recorded age at all.
WAITING_RECORDS=$(
  printf '%s\n' "$(row due-row "Due Row" captain live 2020-01-01 1 in_flight)" \
    "$(row old-row "Old Row" captain live - 9 in_flight)" \
    "$(row fresh-row "Fresh Row" captain live - 0 in_flight)" \
    "$(row noage-row "No Age Row" captain live - - queued)" \
    "$(row working-row "Working Row" - - - - in_flight)" \
    "$(row blocked-hold-row "Blocked Hold Row" captain blocked - 30 in_flight)" \
    "$(row landed-row "Landed Row" - - - - "done")" | jq -s -c '.')

run_line() {  # <snapshot> [env assignments...]
  local snap=$1
  shift
  env FM_QUEUE_SNAPSHOT="$snap" FM_QUEUE_LINE_TODAY=2026-06-01 "$@" "$LINE"
}

test_line_absent_when_nothing_waits() {
  local home snap out status
  home=$TMP_ROOT/none
  mkdir -p "$home"
  snap=$home/snapshot.json
  write_fixture "$home" "$snap" "$(
    printf '%s\n' "$(row working-row "Working Row" - - - - in_flight)" \
      "$(row queued-row "Queued Row" - - - - queued)" \
      "$(row blocked-hold-row "Blocked Hold Row" captain blocked - 30 in_flight)" \
      "$(row landed-row "Landed Row" - - - - "done")" | jq -s -c '.')"
  out=$(run_line "$snap" 2>&1)
  status=$?
  expect_code 0 "$status" "an empty queue must not fail: $out"
  [ -z "$out" ] || fail "nothing waiting must print no line at all, got: $out"
  pass "nothing waiting on the captain prints no line"
}

test_names_top_and_remaining_count() {
  local home snap out lines
  home=$TMP_ROOT/waits
  mkdir -p "$home"
  snap=$home/snapshot.json
  write_fixture "$home" "$snap" "$WAITING_RECORDS"
  out=$(run_line "$snap")
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  assert_equals "1" "$lines" "the line is one line"
  assert_contains "$out" "waiting on you (4)" "the count is the number of rows waiting on the captain"
  assert_contains "$out" "due-row - Due Row" \
    "a hold deferred to a date that has passed outranks every newer hold"
  assert_contains "$out" "(+3 more)" "the rest of the queue is named as a count"
  assert_not_contains "$out" "old-row" "only the top item is named, not the runners-up"
  assert_not_contains "$out" "blocked-hold-row" \
    "a captain hold the model buckets blocked is not waiting on him"
  assert_not_contains "$out" "landed-row" "a done row is not counted"
  pass "the line names the most urgent waiting item and the count of the rest"
}

test_longest_wait_outranks_when_nothing_is_due() {
  local home snap out
  home=$TMP_ROOT/age
  mkdir -p "$home"
  snap=$home/snapshot.json
  write_fixture "$home" "$snap" "$(
    printf '%s\n' "$(row fresh-row "Fresh Row" captain live - 0 in_flight)" \
      "$(row old-row "Old Row" captain live - 9 in_flight)" \
      "$(row noage-row "No Age Row" captain live - - queued)" | jq -s -c '.')"
  out=$(run_line "$snap")
  assert_contains "$out" "old-row - Old Row" "with no due hold, the longest wait leads"
  assert_contains "$out" "waiting on you (3)" "every waiting row is counted"
  assert_contains "$out" "(+2 more)" "the remaining count follows the named item"
  pass "with nothing due, the longest-waiting hold leads the line"
}

test_count_agrees_with_the_queue_program() {
  local home snap line printed model_count
  home=$TMP_ROOT/agree
  mkdir -p "$home"
  snap=$home/snapshot.json
  write_fixture "$home" "$snap" "$WAITING_RECORDS" "[$(dead_task dead-row)]"
  line=$(run_line "$snap")
  printed=$(printf '%s' "$line" | sed -n 's/.*waiting on you (\([0-9]*\)).*/\1/p')
  model_count=$(FM_QUEUE_SNAPSHOT="$snap" "$QUEUE" --json | jq -r '.counts.by_state["waiting on you"]')
  [ -n "$printed" ] || fail "the line did not carry a waiting count: $line"
  assert_equals "$model_count" "$printed" \
    "the line count must be the queue program's own waiting count"
  assert_not_contains "$line" "dead-row" "a dead worker is maintenance, never the captain's request"
  pass "the pinned count and the queue program cannot disagree"
}

test_line_is_bounded_and_keeps_its_counts() {
  local home snap out width length
  home=$TMP_ROOT/bound
  mkdir -p "$home"
  snap=$home/snapshot.json
  long_title="Reconcile every accepted request against the artifact that proves it, then print the surviving rows in full, because the queue exists to be read all the way through"
  write_fixture "$home" "$snap" "$(
    printf '%s\n' "$(row long-row "$long_title" captain live - 5 in_flight)" \
      "$(row other-row "Other Row" captain live - 1 in_flight)" | jq -s -c '.')"
  width=60
  out=$(run_line "$snap" FM_QUEUE_LINE_WIDTH=$width)
  length=$(printf '%s' "$out" | jq -R 'length')
  [ "$length" -le "$width" ] || fail "the line is $length characters, over the $width bound: $out"
  assert_contains "$out" "(+1 more)" "cutting the item text must never cut the count"
  assert_contains "$out" "long-row" "the item is named even when its text must be cut"
  assert_contains "$out" "…" "a cut item text is marked as cut"
  assert_not_contains "$out" "Other Row" "only the top item is named"
  pass "the line stays inside its width and keeps both counts intact"
}

test_unreadable_model_is_not_an_empty_queue() {
  local home snap out status
  home=$TMP_ROOT/broken
  mkdir -p "$home"
  snap=$home/snapshot.json
  out=$(run_line "$home/missing.json" 2>&1)
  status=$?
  expect_code 1 "$status" "a queue read that cannot happen must fail loudly: $out"
  [ -z "$(run_line "$home/missing.json" 2>/dev/null)" ] || fail "a failed read must print no line"

  printf '{"schema":"something-else.v1","backlog":{"records":[]}}' > "$snap"
  out=$(run_line "$snap" 2>&1)
  status=$?
  expect_code 1 "$status" "a snapshot the queue program refuses must fail here too: $out"
  [ -z "$(run_line "$snap" 2>/dev/null)" ] || fail "a refused snapshot must print no line"
  pass "an unreadable or refused model exits non-zero instead of reading as an empty queue"
}

# --- the omp extension: the pin, over the real loader -------------------------

install_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.omp/extensions/fm-primary-queue-line.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/"
  cat > "$repo/bin/fm-queue-line.sh" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >> "${FM_LINE_LOG:?}"
case "${FM_LINE_MODE:?}" in
  waiting) printf '⧗ waiting on you (3): top-row - Top Row (+2 more)\n' ;;
  empty) exit 0 ;;
  fail) exit 1 ;;
  slow) sleep 0.4; printf '⧗ waiting on you (1): slow-row - Slow Row\n' ;;
esac
SH
  chmod +x "$repo/bin/fm-queue-line.sh"
  printf '%s\n' "$repo"
}

# run_extension <repo> <node program>: drives the real extension file through
# node's TypeScript loader with a fake omp API. Prints any thrown error. The
# worker marker is cleared here because the suite itself may be running inside a
# worker pane, and each case that wants it sets it in its own program.
run_extension() {  # <repo> <program>
  local repo=$1 program=$2
  env -u FM_TASK_ID EXT="$repo/.omp/extensions/fm-primary-queue-line.ts" \
    FM_LINE_LOG="${FM_LINE_LOG:-}" node --input-type=module -e "$program" 2>&1
}

test_extension_pins_and_clears_the_line() {
  local repo out status
  repo=$(install_extension_fixture "$TMP_ROOT/ext-pin")
  out=$(FM_LINE_LOG="$TMP_ROOT/ext-pin/run.log" run_extension "$repo" '
import { pathToFileURL } from "node:url";
const load = (tag) => import(`${pathToFileURL(process.env.EXT).href}?pin=${tag}`);
const fail = (message) => { throw new Error(message); };
// The handlers return immediately by design, so a case waits for the read.
const settled = async (done, ms = 5000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (done()) return true;
    await new Promise((r) => setTimeout(r, 10));
  }
  return false;
};

// Something waits: exactly one line, pinned above the editor.
{
  const calls = [];
  const handlers = new Map();
  const pi = { on(e, h) { handlers.set(e, h); } };
  const ctx = { hasUI: true, ui: { setWidget: (...args) => calls.push(args) } };
  process.env.FM_LINE_MODE = "waiting";
  (await load("a")).default(pi);
  for (const event of ["session_start", "turn_end", "session_shutdown"]) {
    if (!handlers.has(event)) fail(`no ${event} handler was registered`);
  }
  handlers.get("session_start")({ type: "session_start" }, ctx);
  if (!(await settled(() => calls.length === 1))) {
    fail(`expected one pin, got ${JSON.stringify(calls)}`);
  }
  const [key, content, options] = calls[0];
  if (key !== "firstmate-queue-line") fail(`unexpected widget key ${key}`);
  if (content.length !== 1 || content[0] !== "⧗ waiting on you (3): top-row - Top Row (+2 more)") {
    fail(`unexpected widget content ${JSON.stringify(content)}`);
  }
  if (options?.placement !== "aboveEditor") fail(`unexpected placement ${JSON.stringify(options)}`);
}

// Nothing waits: the pin is cleared, not left showing a stale count.
{
  const calls = [];
  const handlers = new Map();
  const pi = { on(e, h) { handlers.set(e, h); } };
  const ctx = { hasUI: true, ui: { setWidget: (...args) => calls.push(args) } };
  process.env.FM_LINE_MODE = "empty";
  (await load("b")).default(pi);
  handlers.get("session_start")({ type: "session_start" }, ctx);
  if (!(await settled(() => calls.length === 1))) {
    fail(`an empty queue must clear the pin, got ${JSON.stringify(calls)}`);
  }
  if (calls[0][1] !== undefined) fail(`clearing must pass undefined, got ${JSON.stringify(calls[0])}`);
}
')
  status=$?
  expect_code 0 "$status" "the extension pins and clears the line: $out"
  [ -z "$out" ] || fail "the extension pin test printed output: $out"
  pass "the extension pins one line above the editor and clears it when nothing waits"
}

test_extension_repins_on_a_turn_boundary() {
  local repo out status
  repo=$(install_extension_fixture "$TMP_ROOT/ext-turn")
  out=$(FM_LINE_LOG="$TMP_ROOT/ext-turn/run.log" run_extension "$repo" '
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const calls = [];
const pi = { on(e, h) { handlers.set(e, h); } };
const ctx = { hasUI: true, ui: { setWidget: (...args) => calls.push(args) } };
const settled = async (done, ms = 5000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (done()) return true;
    await new Promise((r) => setTimeout(r, 10));
  }
  return false;
};
process.env.FM_LINE_MODE = "waiting";
process.env.FM_QUEUE_LINE_MIN_INTERVAL_MS = "1";
const mod = (await import(pathToFileURL(process.env.EXT).href + "?turn=1")).default;
mod(pi);
handlers.get("session_start")({ type: "session_start" }, ctx);
if (!(await settled(() => calls.length === 1))) throw new Error("the first read never pinned a line");
process.env.FM_LINE_MODE = "empty";
// One more turn boundary, with no restart: the pin must change to the new answer.
handlers.get("turn_end")({ type: "turn_end" }, ctx);
if (!(await settled(() => calls.length > 1))) throw new Error("a later turn boundary did not repaint the pin");
if (calls[calls.length - 1][1] !== undefined) {
  throw new Error(`the repaint did not clear the answered line: ${JSON.stringify(calls)}`);
}
const runs = readFileSync(process.env.FM_LINE_LOG, "utf8").trim().split("\n").length;
if (runs < 2) throw new Error(`expected a fresh read per repaint, saw ${runs}`);
')
  status=$?
  expect_code 0 "$status" "the extension repaints from a fresh read at a turn boundary: $out"
  [ -z "$out" ] || fail "the extension turn test printed output: $out"
  pass "answering the item changes the line without a restart"
}

test_extension_keeps_the_line_when_a_read_fails() {
  local repo out status
  repo=$(install_extension_fixture "$TMP_ROOT/ext-fail")
  out=$(FM_LINE_LOG="$TMP_ROOT/ext-fail/run.log" run_extension "$repo" '
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const calls = [];
const pi = { on(e, h) { handlers.set(e, h); } };
const ctx = { hasUI: true, ui: { setWidget: (...args) => calls.push(args) } };
const settled = async (done, ms = 5000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (done()) return true;
    await new Promise((r) => setTimeout(r, 10));
  }
  return false;
};
process.env.FM_LINE_MODE = "fail";
const mod = (await import(pathToFileURL(process.env.EXT).href + "?fail=1")).default;
mod(pi);
handlers.get("session_start")({ type: "session_start" }, ctx);
// Wait for the read to have actually happened, so an untouched pin is an answer
// rather than a race the test won.
const ran = () => existsSync(process.env.FM_LINE_LOG) && readFileSync(process.env.FM_LINE_LOG, "utf8").trim() !== "";
if (!(await settled(ran))) throw new Error("the failing read never ran");
await new Promise((r) => setTimeout(r, 200));
if (calls.length !== 0) throw new Error(`a failed read must not touch the pin, got ${JSON.stringify(calls)}`);
')
  status=$?
  expect_code 0 "$status" "a failed read leaves the pin alone: $out"
  [ -z "$out" ] || fail "the extension failure test printed output: $out"
  pass "a read that fails leaves the pinned line as it was"
}

test_extension_reads_once_per_interval_and_coalesces() {
  local repo out status
  repo=$(install_extension_fixture "$TMP_ROOT/ext-rate")
  out=$(FM_LINE_LOG="$TMP_ROOT/ext-rate/run.log" run_extension "$repo" '
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); } };
const ctx = { hasUI: true, ui: { setWidget() {} } };
const settled = async (done, ms = 5000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (done()) return true;
    await new Promise((r) => setTimeout(r, 10));
  }
  return false;
};
process.env.FM_LINE_MODE = "slow";
process.env.FM_QUEUE_LINE_MIN_INTERVAL_MS = "1";
const mod = (await import(pathToFileURL(process.env.EXT).href + "?rate=1")).default;
mod(pi);
const runs = () => {
  const log = readFileSync(process.env.FM_LINE_LOG, "utf8").trim();
  return log === "" ? 0 : log.split("\n").length;
};
handlers.get("session_start")({ type: "session_start" }, ctx);
handlers.get("turn_end")({ type: "turn_end" }, ctx);
handlers.get("turn_end")({ type: "turn_end" }, ctx);
// One read is in flight and the two triggers behind it coalesce into one
// follow-up, so three triggers cost two fleet reads rather than three.
if (!(await settled(() => runs() === 2))) throw new Error(`expected two reads, saw ${runs()}`);
await new Promise((r) => setTimeout(r, 700));
if (runs() !== 2) throw new Error(`three triggers during one read must coalesce to one follow-up read, saw ${runs()}`);
')
  status=$?
  expect_code 0 "$status" "the extension coalesces refreshes: $out"
  [ -z "$out" ] || fail "the extension rate test printed output: $out"
  pass "one read at a time, one coalesced follow-up, never a read per trigger"
}

test_extension_stays_out_of_worker_panes() {
  local repo out status
  repo=$(install_extension_fixture "$TMP_ROOT/ext-worker")
  out=$(FM_LINE_LOG="$TMP_ROOT/ext-worker/run.log" run_extension "$repo" '
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const calls = [];
const pi = { on(e, h) { handlers.set(e, h); } };
const ctx = { hasUI: true, ui: { setWidget: (...args) => calls.push(args) } };
process.env.FM_LINE_MODE = "waiting";
process.env.FM_TASK_ID = "fm-some-worker";
const mod = (await import(pathToFileURL(process.env.EXT).href + "?worker=1")).default;
mod(pi);
if (handlers.size !== 0) throw new Error("a worker pane must register no handler at all");
')
  status=$?
  expect_code 0 "$status" "a worker pane renders nothing: $out"
  [ -z "$out" ] || fail "the extension worker test printed output: $out"
  pass "a worker pane never renders the captain's queue line"
}

test_line_absent_when_nothing_waits
test_names_top_and_remaining_count
test_longest_wait_outranks_when_nothing_is_due
test_count_agrees_with_the_queue_program
test_line_is_bounded_and_keeps_its_counts
test_unreadable_model_is_not_an_empty_queue
test_extension_pins_and_clears_the_line
test_extension_repins_on_a_turn_boundary
test_extension_keeps_the_line_when_a_read_fails
test_extension_reads_once_per_interval_and_coalesces
test_extension_stays_out_of_worker_panes
