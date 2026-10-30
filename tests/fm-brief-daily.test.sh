#!/usr/bin/env bash
# Behavior tests for bin/fm-brief-daily.sh, the captain's one-screen daily brief.
# Every case drives the script over a fixture snapshot through the queue
# program's own fixture seam and reads only its stdout and exit status.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief-daily.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-daily)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# rec <id> <title> <state> [reason] [age] [until] [completed] [pr] [report] [credential]: one main-home
# backlog record; a reason makes it a captain hold.
rec() {  # <id> <title> <state> [reason] [age] [until] [completed] [pr] [report] [marker: credential|discard]
  jq -cn --arg id "$1" --arg title "$2" --arg state "$3" --arg reason "${4:-}" --arg age "${5:-1}" \
    --arg until "${6:-}" --arg completed "${7:-}" --arg pr "${8:-}" --arg report "${9:-}" \
    --arg credential "${10:-}" '
    {order: 1, state: $state, structured: true, id: $id, title: $title, repo: "alpha", kind: "ship",
     hold_kind: (if $reason == "" then null else "captain" end),
     hold_credential: ($credential == "credential"),
     hold_discard: ($credential == "discard"),
     hold_bucket: (if $reason == "" then null else "live" end),
     hold_until: (if $until == "" then null else $until end),
     hold_age_days: ($age | tonumber), hold_reason: (if $reason == "" then null else $reason end),
     completion: (if $completed == "" then null else {verb: "merged", date: $completed} end),
     pr_url: (if $pr == "" then null else $pr end),
     report_path: (if $report == "" then null else $report end),
     blocked_by_ids: [], unresolved_blocker_ids: [], links: [], body_lines: [], since: "2026-01-01",
     project_resolution: {status: "resolved", project: "alpha", token: "alpha"}}'
}

write_fixture() {  # <path> <records-json>
  jq -n --arg home "$TMP_ROOT/home" --argjson records "$2" '
    {schema: "fm-fleet-snapshot.v1", generated: "2026-06-01T12:00:00Z", fm_home: $home,
     backlog: {records: $records}, tasks: [], scout_reports: [],
     main_inventory: {valid: true, reason: null, orphan_in_flight: [], unstructured_current_count: 0},
     secondmate_current: {records: [], total: 0, shown: 0, truncated: []}}' > "$1"
}

run_brief() {  # <snapshot>
  FM_QUEUE_SNAPSHOT="$1" FM_BRIEF_DAILY_TODAY=2026-06-01 "$BRIEF"
}

FULL=$TMP_ROOT/full.json
write_fixture "$FULL" "$(printf '%s\n' \
  "$(rec trivia-a "Rename the tab" queued "Optional: rename the dashboard tab." 0)" \
  "$(rec product-a "Onboarding flow" queued "Choose the onboarding flow for new members." 2)" \
  "$(rec product-b "Meetings bot owner" queued "Name the owner of the meetings bot." 6)" \
  "$(rec money-a "Build host RAM" queued "Which RAM to buy for the build host, 2,311 USD?" 3)" \
  "$(rec merge-a "Merge the bridge PR" queued "PR 1951 is green; merge it?" 4)" \
  "$(rec cred-a "Rotate the deploy credential" queued "Rotate the deploy credential after the exposure." 8 "" "" "" "" credential)" \
  "$(rec copy-a "Copy A" queued "Cleanup refused: copy-a holds 3 uncommitted files. Keep or discard?" 2 "" "" "" "" discard)" \
  "$(rec copy-b "Copy B" queued "Teardown refused for copy-b: 45 files unlanded." 1 "" "" "" "" discard)" \
  "$(rec doc-copy "Document copy" queued "Keep or discard the document copy?" 5)" \
  "$(rec chore-a "Merged cleanup" queued "Clean up the copy after the merged PR." 1)" \
  "$(rec late-a "Pick the vendor" queued "Pick the vendor for the cooling loop." 9 2026-05-20)" \
  "$(rec late-b "Pick the window" queued "Pick the release window." 9 2026-05-25)" \
  "$(rec win-old "Old win" "done" "" 1 "" 2026-05-01 https://example.test/pull/1)" \
  "$(rec win-mid "Mid win" "done" "" 1 "" 2026-05-20 https://example.test/pull/2)" \
  "$(rec win-new "New win" "done" "" 1 "" 2026-05-31 "" data/win-new/report.md)" \
  "$(rec win-newest "Newest win" "done" "" 1 "" 2026-06-01 https://example.test/pull/4)" \
  "$(rec done-nolink "Done without a link" "done" "" 1 "" 2026-06-01)" | jq -s -c '.')"

test_one_screen_in_order() {
  local out first
  out=$(run_brief "$FULL")
  expect_code 0 $? "the brief must render: $out"
  first=$(printf '%s\n' "$out" | sed -n 1p)
  assert_equals "Next: decide cred-a - Rotate the deploy credential" "$first" \
    "line 1 is the single next action: the top-ranked decision"
  assert_contains "$out" "Decisions: 8 open, top 5 by consequence" \
    "the open decisions are counted once per call"
  assert_equals "cred-a,copy-a,merge-a,doc-copy,money-a" \
    "$(printf '%s\n' "$out" | sed -n 's/^ [0-9]\. \[[a-z]*\] \([a-z-]*\).*/\1/p' | paste -sd, -)" \
    "credentials and merges are pinned first, then money, then product"
  assert_contains "$out" " 2. [merge] copy-a (x2), 2d:" "the marked refused copies are one decision with a count and an age"
  assert_contains "$out" " 4. [merge] doc-copy, 5d:" \
    "a keep-or-discard question without the discard marker stays its own decision"
  assert_contains "$out" "    2 rows, see bin/fm-queue.sh" \
    "a grouped decision stays bounded and points to the full queue"
  assert_not_contains "$out" "--members" "the brief never embeds an unbounded member list"
  assert_contains "$out" " +3 not shown: bin/fm-queue.sh lists every decision" \
    "the rest are counted, not dropped silently"
  assert_not_contains "$out" "chore-a" "an agent chore never reaches the brief"
  assert_not_contains "$out" "trivia-a," "the brief stops at five decisions"
  pass "the brief prints one screen: next action, five ranked decisions with bounded directions, and the rest counted"
}

test_wins_expired_and_footer() {
  local out
  out=$(run_brief "$FULL")
  assert_equals "win-newest,win-new,win-mid" \
    "$(printf '%s\n' "$out" | sed -n 's/^ - \([^ :]*\).*/\1/p' | paste -sd, -)" \
    "the three most recent wins that carry a link, newest first"
  assert_contains "$out" " - win-new: data/win-new/report.md" "a win prints its validated relative report path"
  assert_equals " - win-newest" "$(printf '%s\n' "$out" | grep '^ - win-newest$')" \
    "a PR-only win prints its task id alone"
  assert_not_contains "$out" "https://" "wins never print URLs"
  assert_not_contains "$out" "done-nolink" "a completion with no link is not a win to show"
  assert_contains "$out" "Expired, still open? 2: late-a (until 2026-05-20), late-b (until 2026-05-25) - answer each or re-hold it with a new date" \
    "the expired holds surface on one line, and only there"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c 'late-a')" "an expired hold surfaces exactly once"
  assert_equals "Checked 2026-06-01T12:00:00Z from $TMP_ROOT/home" "$(printf '%s\n' "$out" | tail -n 1)" \
    "the footer says when the fleet was checked"
  pass "wins, the expired line and the footer"
}

test_deterministic_and_secret_free() {
  local snap one two leaked opaque
  snap=$TMP_ROOT/secrets.json
  # Token-shaped values built from pieces so this file carries none.
  leaked="gh""p_""AbCdEfGh1234567890IjKl"
  opaque="abcdefghijklmnopqrstuvwxyz""234567"
  write_fixture "$snap" "$(printf '%s\n' \
    "$(rec leak-a "Rotate after DEPLOY_""TOKEN=$leaked was printed" queued "Rotate the exposed value." 1)" \
    "$(rec leak-b "Revoke session Zx9Qw8Er7Ty6Ui5Op4As3Df2" queued "Revoke the session." 2)" \
    "$(rec "leak-Mq3Rt7Yp2Kd9Lw4Hs8Vb" "A row whose id is token-shaped" queued "Revoke the session id." 3)" \
    "$(rec win-capability "Capability link" "done" "" 1 "" 2026-05-31 "https://example.test/share/$opaque/report")" \
    "$(rec win-token-path "Token-shaped report directory" "done" "" 1 "" 2026-05-30 "" "data/$leaked/report.md")" \
    | jq -s -c '.')"
  one=$(run_brief "$snap")
  two=$(run_brief "$snap")
  assert_equals "$one" "$two" "the same fleet always prints the same brief"
  assert_not_contains "$one" "$leaked" "a credential value never prints, in a title or a report path"
  assert_contains "$one" " - win-token-path: data/[redacted]/report.md" \
    "a token-shaped report path keeps its shape and loses the token"
  assert_not_contains "$one" "Zx9Qw8Er7Ty6Ui5Op4As3Df2" "a token-shaped word never prints"
  assert_not_contains "$one" "Mq3Rt7Yp2Kd9Lw4Hs8Vb" "a token-shaped id never prints, in its heading or its answer command"
  assert_contains "$one" "(answer command withheld: it carries a token-shaped value; bin/fm-queue.sh prints it)" \
    "a command redaction would break is withheld with a reason, never printed broken"
  assert_not_contains "$one" "answer leak-[redacted]" "a broken command never prints"
  assert_not_contains "$one" "$opaque" "an opaque capability URL never reaches the brief"
  assert_not_contains "$one" "https://" "the brief emits no win URL"
  assert_contains "$one" " - win-capability" "the completed linked row still qualifies as a win"
  assert_contains "$one" "DEPLOY_""TOKEN=[redacted]" "the variable name survives so the captain knows what leaked"
  pass "the brief is deterministic and prints no secret"
}

test_nothing_open() {
  local snap out
  snap=$TMP_ROOT/empty.json
  write_fixture "$snap" "$(rec working "Working" in_flight | jq -s -c '.')"
  out=$(run_brief "$snap")
  assert_equals "Next: nothing waits on you" "$(printf '%s\n' "$out" | sed -n 1p)" "an empty fleet says so on line 1"
  assert_contains "$out" "Decisions: none open" "no decision is invented"
  assert_contains "$out" "Expired, still open? none" "the expired line is always present"
  pass "nothing open prints a short, explicit brief"
}

test_unreadable_model_fails() {
  local out rc
  out=$(FM_QUEUE_SNAPSHOT="$TMP_ROOT/missing.json" "$BRIEF" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a model that cannot be read must fail, never print an empty brief: $out"
  pass "an unreadable model fails instead of reading as an empty brief"
}

# --- the omp /bearings command, over the real loader ---------------------------

# The real extension file, driven through node's TypeScript loader with a fake
# omp API and a stub brief program, the same harness tests/fm-queue-line.test.sh
# uses for the pinned line.
test_omp_bearings_command() {
  local repo out status
  repo=$TMP_ROOT/ext
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.omp/extensions/fm-primary-bearings.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/"
  cat > "$repo/bin/fm-brief-daily.sh" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >> "${FM_BRIEF_LOG:?}"
case "${FM_BRIEF_MODE:?}" in
  ok) printf 'Next: decide top-row - Top Row\n\nDecisions: 1 open, top 1 by consequence\n' ;;
  fail) echo "fm-brief-daily: the queue model could not be read" >&2; exit 1 ;;
esac
SH
  chmod +x "$repo/bin/fm-brief-daily.sh"
  # shellcheck disable=SC2016 # the node program is literal JavaScript, expanded by node
  out=$(env -u FM_TASK_ID EXT="$repo/.omp/extensions/fm-primary-bearings.ts" FM_BRIEF_LOG="$repo/run.log" \
    node --input-type=module -e '
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const fail = (message) => { throw new Error(message); };
const load = async (tag) => (await import(`${pathToFileURL(process.env.EXT).href}?b=${tag}`)).default;
const fake = () => {
  const api = { commands: new Map(), messages: [], prompts: [], notes: [] };
  api.registerCommand = (name, options) => api.commands.set(name, options);
  api.sendMessage = (message, options) => api.messages.push({ message, options });
  api.sendUserMessage = (text) => api.prompts.push(text);
  api.ctx = { ui: { notify: (text, level) => api.notes.push({ text, level }) } };
  return api;
};
const runs = () => readFileSync(process.env.FM_BRIEF_LOG, "utf8").split("\n").filter(Boolean).length;

// Plain /bearings: the brief, verbatim, in the transcript, with no model turn.
{
  const api = fake();
  process.env.FM_BRIEF_MODE = "ok";
  (await load("a"))(api);
  const command = api.commands.get("bearings") ?? fail("no bearings command was registered");
  await command.handler("", api.ctx);
  if (api.messages.length !== 1) fail(`expected one transcript message, got ${JSON.stringify(api.messages)}`);
  const { message, options } = api.messages[0];
  if (message.content !== "Next: decide top-row - Top Row\n\nDecisions: 1 open, top 1 by consequence") {
    fail(`the brief was not printed verbatim: ${JSON.stringify(message.content)}`);
  }
  if (message.display !== true) fail("the brief must render in the transcript");
  if (options?.triggerTurn !== false) fail("printing the brief must not start a model turn");
  if (api.prompts.length !== 0) fail("plain /bearings must not prompt the agent");
}

// /bearings with options is the skill`s: the agent is asked, the brief is not read.
{
  const api = fake();
  const before = runs();
  (await load("b"))(api);
  await api.commands.get("bearings").handler("file include PRs", api.ctx);
  if (runs() !== before) fail("options must not read the brief");
  if (api.prompts.length !== 1 || !api.prompts[0].includes("/bearings file include PRs")) {
    fail(`options must reach the bearings skill, got ${JSON.stringify(api.prompts)}`);
  }
}

// A failed read says why and prints no brief.
{
  const api = fake();
  process.env.FM_BRIEF_MODE = "fail";
  (await load("c"))(api);
  await api.commands.get("bearings").handler("", api.ctx);
  if (api.messages.length !== 0) fail("a failed read must print no brief");
  const error = api.notes.find((n) => n.level === "error") ?? fail("a failed read must be reported");
  if (!error.text.includes("the queue model could not be read")) fail(`unexpected error ${error.text}`);
}

// A worker pane registers nothing.
{
  const api = fake();
  process.env.FM_TASK_ID = "some-task";
  (await load("d"))(api);
  delete process.env.FM_TASK_ID;
  if (api.commands.size !== 0) fail("a worker pane must not register /bearings");
}
' 2>&1)
  status=$?
  expect_code 0 "$status" "the omp /bearings command: $out"
  [ -z "$out" ] || fail "the omp /bearings test printed output: $out"
  pass "omp /bearings prints the brief with no model turn and leaves options to the skill"
}

test_one_screen_in_order
test_wins_expired_and_footer
test_deterministic_and_secret_free
test_nothing_open
test_unreadable_model_fails
test_omp_bearings_command
