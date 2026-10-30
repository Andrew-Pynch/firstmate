#!/usr/bin/env bash
# Behavior tests for bin/fm-queue.sh, the read-only queue program.
#
# Every case drives the program through its public interface: the human view,
# the --json model, or a run against a fixture home. Nothing here asserts
# implementation source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUEUE="$ROOT/bin/fm-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A body long enough that a clipping renderer would cut it mid-sentence.
LONG_BODY="Reconcile every accepted request against the artifact that proves it, then print the surviving rows in full, because the queue exists to be read all the way through and a sentence cut in the middle teaches the reader something false about what is still owed."

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# write_snapshot <home> <path> [mate]: a canonical-snapshot fixture for the
# renderer. The secondmate ledger row is opt-in, so a fixture without it proves
# the "nothing was cut" case and one with it proves the disclosure case.
write_snapshot() {  # <home> <path> [mate]
  local home=$1 path=$2 with_mate=${3:-}
  local mate_records='{"records": [], "total": 0, "shown": 0, "truncated": []}'
  if [ "$with_mate" = mate ]; then
    mate_records='{"records": [
      {"id": "mate", "host": "other-host", "registered": true, "state": "captain_decision",
       "provenance": {"selected": "structured-home", "structured_home": "/home/andrew/work/fm-homes/mate-home", "summary_source": "remote-ledger", "summary_valid": true},
       "freshness": {"status": "fresh", "observed_at": "2026-01-02T03:04:05Z", "age_seconds": 10},
       "contradiction": false,
       "active_children": [], "decisions_open": [], "holds": [], "landed": [],
       "queued": [
         {"id": "mate-held-row", "title": "Mate Held Row", "repo": "alpha", "kind": "ship",
          "hold_kind": "captain", "hold_bucket": "live", "captain_actionable": true,
          "hold_reason": "Finish the wizard and report back …",
          "blocked_by_ids": [], "unresolved_blocker_ids": [], "since": "2026-01-01",
          "project_resolution": {"status": "resolved", "project": "alpha", "token": "alpha"}}
       ],
       "counts": {"active_children": 0, "decisions_open": 0, "holds": 0, "queued": 1, "landed": 0, "endpoints": 0},
       "omitted": [{"surface": "queued", "count": 4}]}
    ], "total": 1, "shown": 1, "truncated": []}'
  fi
  cat > "$path" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-01-02T03:04:05Z",
  "fm_home": "$home",
  "roots": {"state": "$home/state", "data": "$home/data", "config": "$home/config", "projects": "$home/projects"},
  "backlog": {"path": "$home/data/backlog.md", "present": true, "records": [
    {"order": 1, "state": "in_flight", "structured": true, "id": "dead-row",
     "title": "Dead Row", "repo": "alpha", "kind": "ship",
     "captain_actionable": false, "hold_kind": null, "hold_bucket": null,
     "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": ["Dead Row body line that must survive intact."],
     "since": "2026-01-01", "project_resolution": {"status": "resolved", "token": "alpha"}},
    {"order": 2, "state": "in_flight", "structured": true, "id": "held-row",
     "title": "Held Row", "repo": "alpha", "kind": "ship",
     "captain_actionable": true, "hold_kind": "captain", "hold_bucket": "live",
     "hold_reason": "Pick the API shape before the worker continues.",
     "hold_age_days": 2, "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": [], "since": "2026-01-01",
     "project_resolution": {"status": "resolved", "token": "alpha"}},
    {"order": 3, "state": "queued", "structured": true, "id": "wave-root",
     "title": "Wave Root", "repo": "alpha", "kind": "ship",
     "captain_actionable": false, "hold_kind": null, "hold_bucket": null,
     "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": [], "since": "2026-01-01",
     "project_resolution": {"status": "resolved", "token": "alpha"}},
    {"order": 4, "state": "queued", "structured": true, "id": "dep-row",
     "title": "Dep Row", "repo": "alpha", "kind": "ship",
     "captain_actionable": false, "hold_kind": null, "hold_bucket": null,
     "blocked_by": "wave-root", "blocked_by_ids": ["wave-root"],
     "unresolved_blocker_ids": ["wave-root"], "links": [],
     "body_lines": [], "since": "2026-01-01",
     "project_resolution": {"status": "resolved", "token": "alpha"}},
    {"order": 5, "state": "queued", "structured": true, "id": "long-row",
     "title": "Long Row", "repo": "beta", "kind": "ship",
     "captain_actionable": false, "hold_kind": null, "hold_bucket": null,
     "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": ["$LONG_BODY"], "since": "2026-01-01",
     "project_resolution": {"status": "pending", "reason": "no registry entry for beta"}},
    {"order": 6, "state": "done", "structured": true, "id": "landed-row",
     "title": "Landed Row", "repo": "gamma", "kind": "ship",
     "captain_actionable": false, "hold_kind": null, "hold_bucket": null,
     "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": [], "since": "2026-01-01"},
    {"order": 7, "state": "in_flight", "structured": true, "id": "external-row",
     "title": "External Row", "repo": "alpha", "kind": "ship",
     "captain_actionable": false, "hold_kind": "external", "hold_bucket": null,
     "hold_reason": "Wait on the upstream release; do not re-run it locally.",
     "blocked_by_ids": [], "unresolved_blocker_ids": [], "links": [],
     "body_lines": [], "since": "2026-01-01",
     "project_resolution": {"status": "resolved", "project": "alpha", "token": "alpha"}}
  ]},
  "tasks": [
    {"id": "dead-row", "kind": "ship", "mode": "local-only", "yolo": "off",
     "project": "$home/projects/alpha", "harness": "claude", "backend": "tmux", "remote": null,
     "spawn_gen": null, "secondmate_projects": [],
     "endpoint": {"target": "sess:1", "exists": false, "agent_alive": "not_checked"},
     "paths": {"meta": {"path": "$home/state/dead-row.meta", "present": true},
               "status_log": {"path": "$home/state/dead-row.status", "present": true, "kind": "event_history",
                              "last_event": {"state": "done", "note": "worker said done", "raw": "done: worker said done"}},
               "worktree": {"path": "$home/projects/alpha", "present": true},
               "home": {"path": null, "present": false},
               "report": {"path": "$home/data/dead-row/report.md", "present": false}},
     "current_state": {"state": "unknown", "source": "none", "detail": "backend target gone: sess:1",
                       "observed_at": "2026-01-02T03:04:05Z", "freshness": "fresh"},
     "backlog": {"id": "dead-row", "repo": "alpha", "state": "in_flight"},
     "pr": {"url": null, "source": "absent"}, "hints": {}, "actions": {}},
    {"id": "held-row", "kind": "ship", "mode": "local-only", "yolo": "off",
     "project": "$home/projects/alpha", "harness": "claude", "backend": "tmux", "remote": null,
     "spawn_gen": null, "secondmate_projects": [],
     "endpoint": {"target": "sess:2", "exists": true, "agent_alive": "not_checked"},
     "paths": {"meta": {"path": "$home/state/held-row.meta", "present": true},
               "status_log": {"path": "$home/state/held-row.status", "present": true, "kind": "event_history",
                              "last_event": {"state": "needs-decision", "note": "pick a shape", "raw": "needs-decision: pick a shape"}},
               "worktree": {"path": "$home/projects/alpha", "present": true},
               "home": {"path": null, "present": false},
               "report": {"path": "$home/data/held-row/report.md", "present": false}},
     "current_state": {"state": "working", "source": "pane", "detail": "harness busy",
                       "observed_at": "2026-01-02T03:04:05Z", "freshness": "fresh"},
     "backlog": {"id": "held-row", "repo": "alpha", "state": "in_flight"},
     "pr": {"url": null, "source": "absent"}, "hints": {}, "actions": {}},
    {"id": "orphan-task", "kind": "scout", "mode": "scout", "yolo": "off",
     "project": "$home/projects/alpha", "harness": "claude", "backend": "tmux", "remote": null,
     "spawn_gen": null, "secondmate_projects": [],
     "endpoint": {"target": "sess:3", "exists": false, "agent_alive": "not_checked"},
     "paths": {"meta": {"path": "$home/state/orphan-task.meta", "present": true},
               "status_log": {"path": "$home/state/orphan-task.status", "present": true, "kind": "event_history",
                              "last_event": {"state": "working", "note": "scouting", "raw": "working: scouting"}},
               "worktree": {"path": "$home/projects/alpha", "present": true},
               "home": {"path": null, "present": false},
               "report": {"path": "$home/data/orphan-task/report.md", "present": false}},
     "current_state": {"state": "unknown", "source": "none", "detail": "backend target gone: sess:3",
                       "observed_at": "2026-01-02T03:04:05Z", "freshness": "fresh"},
     "backlog": null,
     "pr": {"url": null, "source": "absent"}, "hints": {}, "actions": {}}
  ],
  "scout_reports": [],
  "main_inventory": {"valid": true, "reason": null, "orphan_in_flight": [], "unstructured_current_count": 0},
  "secondmate_current": $mate_records,
  "secondmate_landed": {"records": [], "truncated": [], "unreadable": [], "partial": []},
  "secondmate_guidance": {"note": "none"}
}
EOF
}

# home_digest <home>: content digest of every file under a fixture home, using
# whichever SHA-256 tool this host has, so a missing hasher fails loudly instead
# of comparing two empty strings.
home_digest() {  # <home>
  local h=$1 f sum
  ( cd "$h" || exit 1
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum < "$f"); else sum=$(shasum -a 256 < "$f"); fi
      printf '%s  %s\n' "${sum%% *}" "$f"
    done )
}

run_queue() {  # <snapshot> [args...]
  local snap=$1
  shift
  FM_QUEUE_SNAPSHOT="$snap" "$QUEUE" "$@"
}

test_dead_worker_reads_unknown_never_done() {
  local home snap out
  home=$(make_home dead)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "[unknown] dead-row (ship)" \
    "a row whose worker is gone must read unknown"
  assert_not_contains "$out" "[done] dead-row" \
    "a stale done status event must never make a dead worker read done"
  assert_contains "$out" "no proof either way: backend target gone: sess:1 (none)" \
    "the unknown reading must name the evidence it rests on"
  assert_contains "$out" "data/backlog.md #1 + state/dead-row.meta + bin/fm-crew-state.sh" \
    "the row must name its authoritative source"
  pass "a task whose worker died reads unknown with its source, never done"
}

test_captain_hold_reads_waiting_on_you() {
  local home snap out json
  home=$(make_home held)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "[waiting on you] held-row (ship)" \
    "a live captain hold must read waiting on you"
  assert_contains "$out" "Pick the API shape before the worker continues." \
    "the hold reason must be printed in full, as the ask"
  json=$(run_queue "$snap" --json)
  assert_equals "waiting on you" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="held-row") | .state')" \
    "the json model must agree that a captain hold waits on the captain"
  pass "a live captain hold is a waiting-on-you row whose ask prints whole"
}

test_text_is_never_clipped() {
  local home snap out json
  home=$(make_home text)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "$LONG_BODY" \
    "the whole body must print, not a clipped prefix"
  assert_not_contains "$out" "${LONG_BODY%%.*}.…" \
    "no truncated copy of the body may be printed alongside it"
  assert_contains "$out" "bounds     row text: none - every row prints its full text" \
    "a view with no cut text must state that nothing was cut"
  pass "row text is printed in full and the view says so"
}

test_a_non_captain_hold_is_not_reported_as_a_failed_worker() {
  local home snap out json
  home=$(make_home hold)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "[blocked] external-row (ship)" \
    "a row held by a non-captain hold does not proceed"
  assert_contains "$out" "held by a hold of kind external" \
    "the wait must be named as the hold, not as a failure"
  assert_contains "$out" "next       firstmate: wait on the external hold; do not re-dispatch" \
    "the next action must be to wait, never to re-dispatch"
  assert_not_contains "$out" "re-dispatch or retire" \
    "no held row may be told to re-dispatch while its own hold says otherwise"
  json=$(run_queue "$snap" --json)
  assert_equals "blocked" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="external-row") | .state')" \
    "the json model must agree the held row is blocked"
  pass "a non-captain hold reads as a wait, never as a failed worker to re-dispatch"
}

test_cut_text_is_disclosed_not_passed_off_as_whole() {
  local home snap out json
  home=$(make_home cut)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap" mate
  out=$(run_queue "$snap")
  assert_contains "$out" "CUT        a secondmate ledger cut hold_reason(160)" \
    "a cut field must name the field and the bound that applied"
  assert_contains "$out" "bounds     row text: 1 row(s) carry text a secondmate ledger cut (hold_reason(160))" \
    "the view must state the real bound it saw"
  json=$(run_queue "$snap" --json)
  assert_equals "hold_reason" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="mate-held-row") | .cut_fields[0].field')" \
    "the json model must name the cut field"
  assert_equals "160" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="mate-held-row") | .cut_fields[0].bound')" \
    "the json model must carry the bound that applied, not a constant"
  assert_equals "false" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="mate-held-row") | .text_complete')" \
    "a cut row must be marked incomplete"
  assert_equals "true" \
    "$(printf '%s' "$json" | jq -r '.projects[].rows[] | select(.id=="dead-row") | .text_complete')" \
    "this home own backlog text is never producer-cut"
  pass "cut text is disclosed with its real bound instead of passed off as whole"
}

test_every_row_prints_and_no_bucket_is_capped() {
  local home snap out ids listed
  home=$(make_home whole)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  for ids in dead-row held-row wave-root dep-row long-row landed-row external-row; do
    assert_contains "$out" "] $ids " "row $ids must appear in the view"
  done
  listed=$(printf '%s\n' "$out" | grep -c '^\[')
  assert_equals "9" "$listed" \
    "7 request rows plus 2 maintenance records is every row the snapshot carries"
  assert_contains "$out" "bounds     buckets: none - no list below is capped" \
    "the view must state that no bucket was capped"
  pass "every row prints and the view states that no bucket is capped"
}

test_maintenance_is_grouped_apart() {
  local home snap out json part
  home=$(make_home maint)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "== fleet maintenance - not your request (2) ==" \
    "maintenance must be its own labelled group"
  part=$(printf '%s' "$out" | sed -n '/fleet maintenance/,$p')
  assert_contains "$part" "orphan-task" \
    "a worker record with no queue row belongs to the maintenance group"
  assert_contains "$part" "orphan-task (scout) - unrecorded follow-up (not your request)" \
    "a maintenance row must say it is not the captain request"
  assert_not_contains "$(printf '%s' "$out" | sed -n '1,/fleet maintenance/p')" "orphan-task" \
    "maintenance must not also be listed among the requests"
  json=$(run_queue "$snap" --json)
  assert_equals "unrecorded follow-up" \
    "$(printf '%s' "$json" | jq -r '.maintenance[] | select(.id=="orphan-task") | .class')" \
    "the json model must classify the same maintenance record"
  assert_equals "0" \
    "$(printf '%s' "$json" | jq -r '[.maintenance[].id] | length - (unique | length)')" \
    "a maintenance record must not be listed twice under two classes"
  pass "fleet maintenance is grouped apart and labelled as not the captain request"
}

test_unresolved_project_is_reported_not_hidden() {
  local home snap out
  home=$(make_home project)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "== unresolved: no registry entry for beta - 1 row(s)" \
    "an unresolvable project must be reported where it would otherwise render"
  assert_contains "$out" "long-row" "the row must still print under its reported project"
  pass "a project the registry cannot resolve is reported, not silently rendered"
}

test_wave_layers_stay_inside_their_project() {
  local home snap out json
  home=$(make_home wave)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  assert_contains "$out" "2 of 2 (1 declared dependencies in alpha)" \
    "a declared blocker inside the project must put its dependent on the next layer"
  json=$(run_queue "$snap" --json)
  assert_equals "2" \
    "$(printf '%s' "$json" | jq -r '.projects[] | select(.name=="alpha") | .rows[] | select(.id=="dep-row") | .wave.layer')" \
    "the dependent row sits on the project second layer"
  assert_equals "2" \
    "$(printf '%s' "$json" | jq -r '.projects[] | select(.name=="alpha") | .rows[] | select(.id=="dep-row") | .wave.layers')" \
    "the project has two layers"
  assert_equals "1" \
    "$(printf '%s' "$json" | jq -r '.projects[] | select(.name | startswith("unresolved:")) | .rows[] | select(.id=="long-row") | .wave.layers')" \
    "a project with no declared edge must not borrow another project layer count"
  assert_equals "0" \
    "$(printf '%s' "$json" | jq -r '.projects[] | select(.name | startswith("unresolved:")) | .rows[] | select(.id=="long-row") | .wave.edges')" \
    "a project with no declared edge reports no edge"
  assert_equals "dep-row" \
    "$(printf '%s' "$json" | jq -r '.projects[] | select(.name=="alpha") | .rows[] | select(.id=="wave-root") | .unblocks[0]')" \
    "the json model must name what the row unblocks"
  pass "wave layers come from each project own declared dependencies"
}

test_json_model_parity() {
  local home snap out json human_rows
  home=$(make_home parity)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(run_queue "$snap")
  json=$(run_queue "$snap" --json)
  assert_equals "fm-queue.v1" "$(printf '%s' "$json" | jq -r '.schema')" "json schema id"
  assert_equals "9" "$(printf '%s' "$json" | jq -r '.counts.requests + .counts.maintenance')" \
    "the json model must carry every row the human view prints"
  assert_equals "7" "$(printf '%s' "$json" | jq -r '.counts.requests')" "request row count"
  human_rows=$(printf '%s\n' "$out" | grep -c '^\[')
  assert_equals "9" "$human_rows" "the human view and the json model must agree on the row count"
  assert_equals "0" "$(printf '%s' "$json" | jq -r '[.projects[].rows[] | select(.text_complete == false)] | length')" \
    "every row of this home own backlog is complete text"
  pass "the json model is a parity form of the human view"
}

test_withheld_records_are_disclosed_with_a_reveal_path() {
  local home snap out
  home=$(make_home withheld)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap" mate
  out=$(run_queue "$snap")
  assert_contains "$out" "bounds     mate home queued: 4 record(s) that home withheld" \
    "a home that bounded its own ledger must say so and how many it withheld"
  assert_contains "$out" "full text: /home/andrew/work/fm-homes/mate-home/data/backlog.md on other-host" \
    "the withheld bound must carry a path a reader can actually open"
  assert_contains "$out" "secondmate home bounds above name what those homes withheld" \
    "the no-cap claim must say what it actually verified"
  pass "a bounded secondmate ledger is disclosed with an openable reveal path"
}

test_refuses_a_non_snapshot_input() {
  local home snap rc out
  home=$(make_home refuse)
  snap=$home/snapshot.json
  printf '%s\n' '{"schema": "fm-queue.v1", "projects": []}' > "$snap"
  out=$(run_queue "$snap" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a non-snapshot input must be refused, not rendered as an empty queue"
  assert_contains "$out" "expected a canonical fleet snapshot" \
    "the refusal must say what it wanted"
  pass "a non-snapshot input is refused rather than shown as an empty queue"
}

test_reads_the_real_snapshot_and_stays_read_only() {
  local home fakebin before after out rc
  home=$(make_home live)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - Live Task (repo: alpha) (kind: ship) (since 2026-01-01)
  Preserve this detail for the queue.

## Done
EOF
  mkdir -p "$home/projects/alpha-worktree"
  fm_write_meta "$home/state/live-task.meta" \
    "window=firstmate:fm-live-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=$home/projects/alpha-worktree" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf 'done: worker said it finished\n' > "$home/state/live-task.status"
  fakebin=$TMP_ROOT/livebin
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/no-mistakes"

  before=$(home_digest "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$QUEUE")
  rc=$?
  after=$(home_digest "$home")
  expect_code 0 "$rc" "the queue must run against the canonical snapshot"
  assert_contains "$out" "[unknown] live-task (ship)" \
    "a worker with no live endpoint must read unknown even after a done status event"
  assert_contains "$out" "Preserve this detail for the queue." \
    "the real snapshot full body text must reach the view"
  assert_contains "$before" "live-task.meta" "the digest must cover the fixture, not compare two empty strings"
  assert_equals "$before" "$after" "the queue must leave the home byte-identical"
  assert_absent "$home/state/.lock" "the queue must not take the session lock"
  pass "the queue reads the real canonical snapshot, starts nothing and writes nothing"
}

# --- answering a row --------------------------------------------------------
#
# Slice 8's acceptance line: an answer given while firstmate is stopped is
# handled when a session starts and is never lost; a decision answered from the
# queue is recorded through the captain-hold owner and leaves the queue; and the
# queue starts no worker itself. Each case drives the public `answer` verb and
# reads its effect from durable records, never from source text.

# A hand-off that outlives a stopped session is two durable artifacts: the record
# in the home's inbox, and the one wake that presents it. Both come from the real
# bin/fm-inbox.sh, so this proves the transport and not a stub of it.
test_answer_is_handed_off_through_the_home_inbox() {
  local home snap out rc notes wakes listed
  home=$(make_home handoff)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" \
    answer wave-root --text "Dispatch this wave now." 2>&1)
  rc=$?
  expect_code 0 "$rc" "answering a queued row must succeed"
  assert_contains "$out" "answered row wave-root (alpha)" \
    "the answer must name the row it answered"
  assert_contains "$out" "none started by this command" \
    "the answer path must say it started no worker"

  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals "1" "$notes" "the answer must leave exactly one durable inbox record"
  assert_contains "$(cat "$home/state/inbox"/*.note)" "Dispatch this wave now." \
    "the durable record must carry the captain's own words"
  assert_contains "$(cat "$home/state/inbox"/*.note)" "queue-answer row=wave-root" \
    "the durable record must name the row it answers"

  wakes=$(grep -c "inbox:" "$home/state/.wake-queue")
  assert_equals "1" "$wakes" "the hand-off must arm exactly one wake"
  assert_contains "$(cat "$home/state/.wake-queue")" "	check	inbox:" \
    "the armed wake must be the check wake a session start presents"
  assert_absent "$home/state/.lock" "the answer path must not take the session lock"

  listed=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" drain)
  assert_contains "$listed" "Dispatch this wave now." \
    "a session that starts later must still find the answer waiting in the inbox"
  pass "an answer while stopped waits durably in the home's inbox behind one wake"
}

# The keyed half: a row that reads waiting on you is a captain hold, so its answer
# is recorded through the captain-hold owner, and the row then leaves that bucket.
test_a_keyed_answer_closes_through_the_captain_hold_owner() {
  local home out rc body
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home keyed)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ( cd "$home" && tasks-axi add held-row "Held Row" --repo alpha ) >/dev/null 2>&1 \
    || fail "could not create the held fixture row"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold held-row \
    --reason "Pick the API shape before the worker continues." >/dev/null 2>&1 \
    || fail "could not hold the fixture row for the captain"

  out=$(FM_HOME="$home" FM_QUEUE_TIMEOUT=60 "$QUEUE" 2>&1)
  assert_contains "$out" "[waiting on you] held-row" \
    "the held row must read waiting on you before it is answered"

  out=$(FM_HOME="$home" "$QUEUE" answer held-row --text "Use POST, not PUT." 2>&1)
  rc=$?
  expect_code 0 "$rc" "answering a held decision must succeed"
  assert_contains "$out" "recorded and closed through the captain-hold owner" \
    "a keyed answer must be recorded through the captain-hold owner"

  body=$( cd "$home" && tasks-axi show held-row | sed -n '/body:/,$p' )
  assert_contains "$body" "Use POST, not PUT." \
    "the captain's exact words must reach the decision record"
  assert_contains "$body" "Resolution mode: answered" \
    "the decision must be closed by the captain-hold owner, not by this command"

  out=$(FM_HOME="$home" FM_QUEUE_TIMEOUT=60 "$QUEUE" 2>&1)
  assert_contains "$out" "[done] held-row" \
    "an answered decision must read done on the next queue read"
  assert_not_contains "$out" "[waiting on you] held-row" \
    "an answered decision must leave the waiting-on-you bucket"
  assert_contains "$(cat "$home/state/inbox"/*.note)" "Use POST, not PUT." \
    "the keyed answer must also be handed off through the inbox"
  assert_absent "$home/state/.lock" "the answer path must not take the session lock"
  pass "a decision answered from the queue closes through the captain-hold owner and leaves it"
}

test_an_aged_answer_closes_through_the_captain_hold_owner() {
  local home out rc body
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home aged-answer)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ( cd "$home" && tasks-axi add aged-row "Aged Row" --repo alpha ) >/dev/null 2>&1 \
    || fail "could not create the aged fixture row"
  FM_CAPTAIN_HOLD_NOW=2026-05-01T12:00:00Z FM_HOME="$home" \
    "$ROOT/bin/fm-captain-hold.sh" hold aged-row \
      --reason "Pick the owner of the old deployment." >/dev/null 2>&1 \
    || fail "could not hold the aged fixture row for the captain"

  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-06-01T12:00:00Z FM_QUEUE_TODAY=2026-06-01 \
    "$QUEUE" 2>&1)
  assert_contains "$out" "[aged] aged-row" \
    "the old hold must read aged before it is answered"

  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-06-01T12:00:00Z FM_QUEUE_TODAY=2026-06-01 \
    "$QUEUE" answer aged-row --text "Assign it to operations." 2>&1)
  rc=$?
  expect_code 0 "$rc" "answering an aged hold must succeed"
  assert_contains "$out" "recorded and closed through the captain-hold owner" \
    "an aged answer must be recorded through the captain-hold owner"

  body=$( cd "$home" && tasks-axi show aged-row | sed -n '/body:/,$p' )
  assert_contains "$body" "Assign it to operations." \
    "the captain's exact words must reach the aged hold record"
  assert_contains "$body" "Resolution mode: answered" \
    "the aged hold must be closed by the captain-hold owner"
  pass "an aged hold answer closes through the captain-hold owner"
}

# The queue is a hand-off, never a dispatcher, and it refuses the rows it cannot
# answer rather than guessing. The backend tools are recording shims, so "started
# no worker" is checked against what would actually have been invoked.
test_answer_starts_no_worker_and_refuses_what_it_cannot_answer() {
  local home snap out rc fakebin log
  home=$(make_home guard)
  snap=$home/snapshot.json
  write_snapshot "$home" "$snap"
  fakebin=$(fm_fakebin "$home")
  log="$home/backend.log"
  : > "$log"
  local tool
  for tool in tmux treehouse no-mistakes; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\\n' "$tool \$*" >> "$log"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" PATH="$fakebin:$PATH" "$QUEUE" \
    answer wave-root --text "go" 2>&1)
  rc=$?
  expect_code 0 "$rc" "answering a queued row must succeed"
  assert_equals "" "$(cat "$log")" \
    "the answer path must start no worker through the backend tooling"

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer orphan-task --text x 2>&1)
  rc=$?
  expect_code 1 "$rc" "a fleet-maintenance record must be refused"
  assert_contains "$out" "fleet-maintenance record" \
    "the refusal must say the row is not the captain's request"

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer no-such-row --text x 2>&1)
  rc=$?
  expect_code 1 "$rc" "an unknown row must be refused"
  assert_contains "$out" "no queue row with id no-such-row" "the refusal must name the row"

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer landed-row --text x 2>&1)
  rc=$?
  expect_code 1 "$rc" "a row that already reads done must be refused"
  assert_contains "$out" "already reads done" "the refusal must say the row is finished"

  out=$(printf '' | FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer wave-root 2>&1)
  rc=$?
  expect_code 1 "$rc" "an empty answer must be refused"
  assert_contains "$out" "empty answer" "the refusal must say why"

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer wave-root --text reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "the intake's reserved reconcile value must be refused"
  assert_contains "$out" "reconcile" "the refusal must name the reserved value"

  out=$(FM_QUEUE_SNAPSHOT="$snap" FM_HOME="$home" "$QUEUE" answer wave-root --close release --text x 2>&1)
  rc=$?
  expect_code 1 "$rc" "releasing a row that is not a hold must be refused"
  assert_contains "$out" "not a captain hold" "the refusal must say why release does not apply"

  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "1" "$notes" "only the one accepted answer may leave a hand-off record"
  pass "the answer path starts no worker and refuses every row it cannot answer"
}

# --- the open-decisions set ---------------------------------------------------

# held <id> <reason> [until] [age] [state] [credential]: one main-home captain-held record.
held() {  # <id> <reason> [until] [age] [state] [marker: credential|discard]
  jq -cn --arg id "$1" --arg reason "$2" --arg until "${3:--}" --arg age "${4:-1}" --arg state "${5:-queued}" \
    --arg credential "${6:-}" '
    {order: 1, state: $state, structured: true, id: $id, title: ("Title of " + $id), repo: "alpha", kind: "ship",
     hold_kind: "captain", hold_bucket: "live", captain_actionable: true,
     hold_credential: ($credential == "credential"),
     hold_discard: ($credential == "discard"),
     hold_until: (if $until == "-" then null else $until end),
     hold_age_days: ($age | tonumber), hold_reason: $reason,
     blocked_by_ids: [], unresolved_blocker_ids: [], links: [], body_lines: [], since: "2026-01-01",
     project_resolution: {status: "resolved", project: "alpha", token: "alpha"}}'
}

# in_project <name>: move one held record (stdin) into another project.
in_project() {  # <name>
  jq -c --arg p "$1" '.repo = $p | .project_resolution = {status: "resolved", project: $p, token: $p}'
}

# write_records <home> <path> <records-json> [mate-queued-json] [mate-task-hints-json]
write_records() {  # <home> <path> <records> [mate-queued] [mate-hints]
  local home=$1 path=$2 records=$3 queued=${4:-[]} hints=${5:-null}
  jq -n --arg home "$home" --argjson records "$records" --argjson queued "$queued" --argjson hints "$hints" '
    {schema: "fm-fleet-snapshot.v1", generated: "2026-06-01T12:00:00Z", fm_home: $home,
     roots: {state: ($home + "/state"), data: ($home + "/data"), config: ($home + "/config"), projects: ($home + "/projects")},
     backlog: {path: ($home + "/data/backlog.md"), present: true, records: $records},
     tasks: (if $hints == null then [] else
       [{id: "mate", kind: "secondmate", mode: "secondmate", backend: "tmux", remote: null,
         endpoint: {target: "sess:9", exists: true}, current_state: {state: "working", source: "pane"},
         backlog: null, pr: {url: null}, hints: {open_decisions: $hints}}] end),
     scout_reports: [],
     main_inventory: {valid: true, reason: null, orphan_in_flight: [], unstructured_current_count: 0},
     secondmate_current: {records: (if ($queued | length) == 0 then [] else
       [{id: "mate", host: null, registered: true,
         provenance: {selected: "structured-home", structured_home: "/homes/mate", summary_source: "local", summary_valid: true},
         freshness: {status: "fresh", observed_at: "2026-06-01T12:00:00Z", age_seconds: 1},
         contradiction: false, active_children: [], decisions_open: [], holds: [], landed: [],
         queued: $queued, omitted: []}] end), total: 1, shown: 1, truncated: []},
     secondmate_landed: {records: [], truncated: [], unreadable: [], partial: []},
     secondmate_guidance: {note: "none"}}' > "$path"
}

decisions_model() {  # <snapshot>
  FM_QUEUE_SNAPSHOT="$1" FM_QUEUE_TODAY=2026-06-01 "$QUEUE" --json
}

test_expired_and_deferred_holds_stay_out_of_the_decisions() {
  local home snap model
  home=$(make_home expiry)
  snap=$home/snapshot.json
  write_records "$home" "$snap" "$(printf '%s\n' \
    "$(held passed-row "Pick the vendor for the cooling loop." 2026-05-31)" \
    "$(held due-row "Pick the colour of the dashboard header." 2026-06-01)" \
    "$(held later-row "Pick the release window for the agent." 2026-06-02)" \
    "$(held aged-row "Pick the owner of the old deployment." - 30 | jq -c '.hold_bucket = "aged" | .captain_actionable = false')" \
    "$(held open-row "Pick the API shape before the worker continues.")" | jq -s -c '.')"
  model=$(decisions_model "$snap")
  assert_equals "expired" "$(printf '%s' "$model" | jq -r '.projects[].rows[] | select(.id == "passed-row") | .state')" \
    "a hold whose date has passed with no answer reads expired"
  assert_equals "deferred" "$(printf '%s' "$model" | jq -r '.projects[].rows[] | select(.id == "later-row") | .state')" \
    "a hold dated after today stays deferred"
  assert_equals "aged" "$(printf '%s' "$model" | jq -r '.projects[].rows[] | select(.id == "aged-row") | .state')" \
    "an aged non-actionable hold stays visible under its structured bucket"
  assert_equals "due-row,open-row" "$(printf '%s' "$model" | jq -r '[.decisions[].id] | sort | join(",")')" \
    "only the undated call and the one dated today are open decisions"
  assert_equals "1" "$(printf '%s' "$model" | jq -r '.counts.hygiene.expired_rows')" \
    "the expired row is counted apart, once"
  assert_equals "1" "$(printf '%s' "$model" | jq -r '.counts.hygiene.aged_rows')" \
    "the aged row is counted apart, once"
  pass "an expired, deferred, or aged hold stays out of the open decisions"
}

test_routine_cleanup_is_an_agent_chore_and_discards_rule_once() {
  local home snap model discard
  home=$(make_home chores)
  snap=$home/snapshot.json
  write_records "$home" "$snap" "$(printf '%s\n' \
    "$(held merged-cleanup "Clean up the copy after the merged PR.")" \
    "$(held stale-meta "Retire the stale task record left by the last fleet sweep.")" \
    "$(held copy-a "Cleanup refused: copy-a holds 3 uncommitted files. Keep or discard?" - 1 queued discard)" \
    "$(held copy-b "Teardown refused for copy-b: 45 files unlanded." - 1 queued discard)" \
    "$(held copy-c "Bertha copy-c: keep or discard the working diff?" - 1 queued discard)" \
    "$(held credential-cleanup "Clean up the leaked credential after the merged PR." - 1 queued credential)" \
    "$(held doc-copy "Keep or discard the document copy?")" \
    "$(held real-call "Approve the Sprint 3 scope for the parts team.")" | jq -s -c '.')"
  model=$(decisions_model "$snap")
  assert_equals "agent chore,agent chore" "$(printf '%s' "$model" | jq -r '[.projects[].rows[] | select(.id == "merged-cleanup" or .id == "stale-meta") | .state] | join(",")')" \
    "routine cleanup is an agent chore"
  assert_equals "4" "$(printf '%s' "$model" | jq -r '.counts.decisions')" \
    "marked refused cleanups group while the credential, look-alike, and real call stay their own"
  discard=$(printf '%s' "$model" | jq -c '.decisions[] | select(.class == "discard")')
  assert_equals "3" "$(printf '%s' "$discard" | jq -r '.count')" "the discard decision counts every marked copy"
  assert_equals "copy-a,copy-b,copy-c" "$(printf '%s' "$discard" | jq -r '[.members[].id] | join(",")')" \
    "the discard decision names every marked copy and nothing else"
  assert_equals "captain" "$(printf '%s' "$model" | jq -r '.decisions[] | select(.id == "doc-copy") | .class')" \
    "a question worded like a discard question, without the marker, is never folded into the approval"
  assert_equals "secret" "$(printf '%s' "$model" | jq -r '.decisions[] | select(.id == "credential-cleanup") | .tier')" \
    "an explicit credential remains a captain call even when its wording resembles a chore"
  assert_contains "$(printf '%s' "$discard" | jq -r '.answer')" "--group" \
    "one answer covers every refused copy"
  assert_not_contains "$(printf '%s' "$model" | jq -r '[.decisions[].members[].id] | join(",")')" "merged-cleanup" \
    "a chore is never a captain decision"
  pass "routine cleanup is an agent chore and every refused discard is one decision"
}

test_explicit_identity_groups_and_same_reason_stays_distinct() {
  local home snap model
  home=$(make_home grouping)
  snap=$home/snapshot.json
  write_records "$home" "$snap" "$(printf '%s\n' \
    "$(held captain-hold-pick-api-1 "Bertha pick-api: choose the API shape for the agent bridge.")" \
    "$(held captain-hold-omitted-call-1 "Mate omitted-call: pick the rollout window.")" \
    "$(held twin-one "Choose the retention period for the nightly database snapshots.")" \
    "$(held twin-two "choose the retention period, for the nightly database snapshots")" \
    "$(held lone-call "Name the owner of the meetings bot.")" | jq -s -c '.')" \
    "$(printf '%s\n' "$(held pick-api "Choose the API shape for the agent bridge before the worker resumes.")" \
      "$(held omitted-call "Pick the rollout window before the worker resumes.")" \
      "$(held mate-only "Approve the Bertha disk cleanup window for Saturday.")" | jq -s -c '.')" \
    '[{"key":"captain-hold-pick-api-1","verb":"needs-decision","summary":"x"},{"key":"captain-hold-mate-only-2","verb":"needs-decision","summary":"x"}]'
  model=$(decisions_model "$snap")
  assert_equals "7" "$(printf '%s' "$model" | jq -r '.counts.decisions')" \
    "only a mirror backed by its exact published parent key shares one call identity"
  assert_equals "captain-hold-pick-api-1,pick-api" "$(printf '%s' "$model" | jq -r '.decisions[] | select(.key == "mate:pick-api") | [.members[].id] | join(",")')" \
    "a parent mirror and its secondmate row are one call"
  assert_equals "main:captain-hold-omitted-call-1,mate:omitted-call" \
    "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id == "captain-hold-omitted-call-1" or .id == "omitted-call") | .key] | sort | join(",")')" \
    "an unmatched mirror stays distinct even when one mate row shares its task id"
  assert_equals "main:twin-one,main:twin-two" \
    "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id == "twin-one" or .id == "twin-two") | .key] | sort | join(",")')" \
    "two distinct rows stay separate even when their reasons differ only in spelling"
  assert_equals "1,1" \
    "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id == "twin-one" or .id == "twin-two") | .count] | join(",")')" \
    "neither same-reason decision gains another member"
  assert_equals "FM_HOME=$home bin/fm-send.sh mate --resolve-key captain-hold-mate-only-2 'mate-only: <answer>'" \
    "$(printf '%s' "$model" | jq -r '.decisions[] | select(.id == "mate-only") | .answer')" \
    "a secondmate call is answered with its published parent key, in its home, and the text names the row"
  assert_equals "FM_HOME=$home bin/fm-queue.sh answer lone-call --text '<answer>'" \
    "$(printf '%s' "$model" | jq -r '.decisions[] | select(.id == "lone-call") | .answer')" \
    "a single call this home holds is answered through the queue"
  assert_equals "FM_HOME=$home bin/fm-queue.sh answer mate:pick-api --group --members main:captain-hold-pick-api-1,mate:pick-api --text '<answer>'" \
    "$(printf '%s' "$model" | jq -r '.decisions[] | select(.key == "mate:pick-api") | .answer')" \
    "a call of several rows is answered once, by its decision key, bound to its members"
  pass "only explicit call identity groups rows into one decision"
}

# Two homes reusing one row id, or one generic question asked in two projects,
# are separate calls; an answer recorded in one home never closes another.
test_identity_is_scoped_to_its_home_and_project() {
  local home snap model answered
  home=$(make_home identity)
  snap=$home/snapshot.json
  answered=$(held pick-api "Choose the API shape for the main bridge." - 3 "done" | jq -c '.body_lines = [
    "Resolution recorded by fm-captain-hold.", "Decision digest: abc", "Resolution mode: answered", "",
    "Captain decision:", "Use POST."]')
  write_records "$home" "$snap" "$(printf '%s\n' "$answered" \
    "$(held same-id "Approve the retention period for the main home snapshots.")" \
    "$(held generic-alpha "Approve the plan in the report before the worker continues.")" \
    "$(held generic-beta "Approve the plan in the report before the worker continues." | in_project beta)" \
    | jq -s -c '.')" \
    "$(printf '%s\n' "$(held pick-api "Choose the API shape for the Bertha agent bridge.")" \
      "$(held same-id "Approve the Bertha disk cleanup window for Saturday.")" | jq -s -c '.')" \
    '[]'
  model=$(decisions_model "$snap")
  assert_equals "mate:pick-api" "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id == "pick-api") | .key] | join(",")')" \
    "an answered main-home call does not close a secondmate call that reuses its id"
  assert_equals "main:same-id,mate:same-id" "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id == "same-id") | .key] | sort | join(",")')" \
    "one id in two homes is two decisions"
  assert_equals "1,1" "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id | startswith("generic-")) | .count] | join(",")')" \
    "the same generic question in two projects is two decisions"
  pass "a call is identified within its home and project"
}

# A reason a secondmate ledger cut short never proves two rows are one call, and
# an answered call never hides a distinct call that shares its words.
test_cut_reasons_and_answered_calls_never_merge_distinct_calls() {
  local home snap model answered shared
  home=$(make_home no-false-merge)
  snap=$home/snapshot.json
  shared="Approve the rollout plan described in the report for the agent bridge."
  answered=$(held pick-api "$shared" - 3 "done" | jq -c '.body_lines = [
    "Resolution recorded by fm-captain-hold.", "Decision digest: abc", "Resolution mode: answered", "",
    "Captain decision:", "Use POST."]')
  write_records "$home" "$snap" "$(printf '%s\n' "$answered" \
    "$(held captain-hold-pick-api-1 "$shared")" \
    "$(held other-call "$shared")" | jq -s -c '.')" \
    "$(printf '%s\n' \
      "$(held cut-one "Approve the migration window for the Pilot staging store before the worker cont…")" \
      "$(held cut-two "Approve the migration window for the Pilot staging store before the worker cont…")" \
      | jq -s -c '.')" '[]'
  model=$(decisions_model "$snap")
  assert_equals "captain-hold-pick-api-1,other-call" "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.members[].id == "other-call" or .members[].id == "captain-hold-pick-api-1") | .id] | sort | unique | join(",")')" \
    "an answered main row does not hide an unmatched mirror that shares its words"
  assert_equals "1,1" "$(printf '%s' "$model" | jq -r '[.decisions[] | select(.id | startswith("cut-")) | .count] | join(",")')" \
    "two questions cut to the same prefix stay two decisions"
  pass "cut reasons and answered calls never merge distinct calls"
}

test_an_answered_main_call_does_not_close_an_unmatched_mirror() {
  local home snap model answered
  home=$(make_home answered)
  snap=$home/snapshot.json
  answered=$(held pick-api "Choose the API shape." - 3 "done" | jq -c '.body_lines = [
    "Resolution recorded by fm-captain-hold.", "Decision digest: abc", "Resolution mode: answered", "",
    "Captain decision:", "Use POST."]')
  write_records "$home" "$snap" "$(printf '%s\n' "$answered" \
    "$(held captain-hold-pick-api-1 "Bertha pick-api: choose the API shape for the agent bridge.")" \
    "$(held other-call "Name the owner of the meetings bot.")" | jq -s -c '.')"
  model=$(decisions_model "$snap")
  assert_equals "captain-hold-pick-api-1,other-call" "$(printf '%s' "$model" | jq -r '[.decisions[].id] | sort | join(",")')" \
    "an answered main row cannot suppress an unmatched parent mirror"
  assert_equals "0" "$(printf '%s' "$model" | jq -r '.counts.hygiene.answered_rows')" \
    "the distinct unmatched mirror is not counted as an answered row"
  pass "an answered main call does not close an unmatched mirror"
}

test_answered_open_hold_hygiene_respects_hold_lifecycles() {
  local home snap model rendered answered reheld
  home=$(make_home answered-close-pending)
  snap=$home/snapshot.json
  answered=$(held interrupted-call "Choose the API shape." | jq -c '.body_lines = [
    "Captain hold set: 2026-06-01T12:00:00Z", "",
    "Resolution recorded by fm-captain-hold.", "Decision digest: abc", "Resolution mode: answered", "",
    "Captain decision:", "Use POST."]')
  reheld=$(held reheld-call "Choose the new rollout window." | jq -c '.body_lines = [
    "Captain hold set: 2026-06-01T12:00:00Z", "",
    "Resolution recorded by fm-captain-hold.", "Decision digest: old", "Resolution mode: released", "",
    "Captain decision:", "Proceed with the previous rollout."]')
  write_records "$home" "$snap" "$(printf '%s\n' "$answered" \
    "$reheld" \
    "$(held open-call "Name the owner of the meetings bot.")" | jq -s -c '.')"
  model=$(decisions_model "$snap")
  assert_equals "open-call,reheld-call" "$(printf '%s' "$model" | jq -r '[.decisions[].id] | sort | join(",")')" \
    "only the current interrupted answer is excluded from decisions"
  assert_equals "waiting on you" \
    "$(printf '%s' "$model" | jq -r '.projects[].rows[] | select(.id == "reheld-call") | .state')" \
    "a release from an earlier lifecycle does not answer the re-held call"
  assert_equals "1" "$(printf '%s' "$model" | jq -r '.counts.hygiene.answered_close_pending')" \
    "the interrupted close is counted as hygiene"
  assert_equals "FM_HOME=$home bin/fm-captain-hold.sh finish interrupted-call" \
    "$(printf '%s' "$model" | jq -r '.cleanup[0].command')" \
    "the cleanup entry carries the exact close command"
  rendered=$(FM_QUEUE_SNAPSHOT="$snap" FM_QUEUE_TODAY=2026-06-01 "$QUEUE")
  assert_contains "$rendered" "== needs cleanup - 1 answered close(s) pending ==" \
    "the full queue separates interrupted closes under one cleanup heading"
  assert_equals "1" "$(printf '%s\n' "$rendered" | grep -c 'interrupted-call')" \
    "the answered row appears once in the human queue"
  pass "answered open hold hygiene respects hold lifecycles"
}

test_decisions_rank_by_consequence() {
  local home snap model
  home=$(make_home ranking)
  snap=$home/snapshot.json
  write_records "$home" "$snap" "$(printf '%s\n' \
    "$(held trivia-call "Optional: rename the dashboard tab." - 0)" \
    "$(held product-call "Choose the onboarding flow for new members." - 0)" \
    "$(held money-call "Which RAM to buy for the build host, 2,311 USD?" - 0)" \
    "$(held merge-call "PR 1951 is green; merge it?" - 0)" \
    "$(held old-cred-call "Rotate the leaked deploy credential." - 9 queued credential)" \
    "$(held new-cred-call "Grant the production password reset token." - 1 queued credential)" \
    "$(held product-credential-prose "Grant key customers access to beta." - 0)" | jq -s -c '.')"
  model=$(decisions_model "$snap")
  assert_equals "new-cred-call,old-cred-call,merge-call,money-call,product-call,product-credential-prose,trivia-call" \
    "$(printf '%s' "$model" | jq -r '[.decisions[].id] | join(",")')" \
    "credentials, then merges, then money, then product, then trivia; newer first within a tier"
  assert_equals "product" "$(printf '%s' "$model" | jq -r '.decisions[] | select(.id == "product-credential-prose") | .tier')" \
    "credential-like prose without the marker stays product-tier"
  assert_equals "1,2,3,4,5,6,7" "$(printf '%s' "$model" | jq -r '[.decisions[].rank] | join(",")')" \
    "every decision carries its rank"
  pass "decisions rank by consequence"
}

# Grouped answers through the real owners: the printed command, run as printed,
# closes every row this home holds for the call, and the one hand-off names them
# all. A row that joined the decision after it was shown refuses that answer.
test_a_group_answer_closes_every_row_of_the_call() {
  local home out rc note shown_cmd id
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home group-answer)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  hold_copy() {  # <id>
    ( cd "$home" && tasks-axi add "$1" "Copy $1" --repo alpha ) >/dev/null 2>&1 \
      || fail "could not create the fixture row $1"
    FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold "$1" \
      --reason "Cleanup refused: $1 holds uncommitted files. Keep or discard?" --discard >/dev/null 2>&1 \
      || fail "could not hold $1 for the captain"
  }
  hold_copy copy-a
  hold_copy copy-b
  out=$(FM_HOME="$home" FM_QUEUE_TIMEOUT=60 "$QUEUE" --json 2>&1)
  assert_equals "2" "$(printf '%s' "$out" | jq -r '.decisions[0].count')" \
    "both refused copies are one decision before the answer"
  shown_cmd=$(printf '%s' "$out" | jq -r '.decisions[0].answer | sub("<answer>"; "Discard both.")')
  assert_contains "$shown_cmd" "--members main:copy-a,main:copy-b" "the command names the members it covers"

  # A third copy is refused after the captain saw two: his answer covers two.
  hold_copy copy-c
  out=$(cd "$ROOT" && bash -c "$shown_cmd" 2>&1)
  rc=$?
  expect_code 1 "$rc" "an answer shown for two copies must not cover a third: $out"
  assert_contains "$out" "nothing was answered" "the refusal says nothing closed"
  for id in copy-a copy-b copy-c; do
    assert_not_contains "$( cd "$home" && tasks-axi show "$id" )" "Discard both." \
      "a refused group answer must not reach $id"
  done
  [ -z "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null)" ] \
    || fail "a refused group answer must hand nothing off"

  out=$(FM_HOME="$home" FM_QUEUE_TIMEOUT=60 "$QUEUE" --json 2>&1)
  shown_cmd=$(printf '%s' "$out" | jq -r '.decisions[0].answer | sub("<answer>"; "Discard all three.")')
  out=$(cd "$ROOT" && bash -c "$shown_cmd" 2>&1)
  rc=$?
  expect_code 0 "$rc" "the printed group answer must succeed: $out"
  for id in copy-a copy-b copy-c; do
    assert_contains "$( cd "$home" && tasks-axi show "$id" )" "Discard all three." \
      "the one answer must reach $id's decision record"
  done
  note=$(cat "$home/state/inbox"/*.note)
  assert_contains "$note" "rows=copy-a,copy-b,copy-c" "the one hand-off names every row it closed"
  assert_equals "1" "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" \
    "a group answer is one hand-off"
  out=$(FM_HOME="$home" FM_QUEUE_TIMEOUT=60 "$QUEUE" --json 2>&1)
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.counts.decisions')" \
    "the answered call leaves the open decisions"
  pass "a group answer closes exactly the rows it was shown, through the captain-hold owner"
}

# A secondmate may reuse the id of a row this home holds, and a decision may hold
# only secondmate rows: the group answer closes exactly this home's row, and
# routes every secondmate row by its home in the one hand-off.
test_a_group_answer_spans_homes_without_mistaking_rows() {
  local home snap out rc note
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home group-homes)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ( cd "$home" && tasks-axi add copy-a "Copy copy-a" --repo alpha ) >/dev/null 2>&1 \
    || fail "could not create the fixture row copy-a"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold copy-a \
    --reason "Cleanup refused: copy-a holds uncommitted files. Keep or discard?" --discard >/dev/null 2>&1 \
    || fail "could not hold copy-a for the captain"
  snap=$home/snapshot.json
  # The secondmate rows sort into an earlier project, so a lookup by id alone
  # would find the secondmate copy-a first.
  write_records "$home" "$snap" \
    "$(held copy-a "Cleanup refused: copy-a holds uncommitted files. Keep or discard?" - 1 queued discard | jq -s -c '.')" \
    "$(printf '%s\n' \
      "$(held copy-a "Teardown refused for the Bertha copy-a: 4 files unlanded." - 1 queued discard | in_project aaa)" \
      "$(held twin-x "Choose the window for the Bertha reboot before Friday night." | in_project aaa)" \
      "$(held twin-y "choose the window for the Bertha reboot, before Friday night" | in_project aaa)" \
      | jq -s -c '.')" '[]'

  out=$(FM_HOME="$home" FM_QUEUE_SNAPSHOT="$snap" "$QUEUE" answer copy-a --group \
    --members main:copy-a,mate:copy-a --text "Discard both." 2>&1)
  rc=$?
  expect_code 0 "$rc" "a group answer must close this home's row even when a secondmate reuses its id: $out"
  assert_contains "$( cd "$home" && tasks-axi show copy-a )" "Discard both." \
    "the answer must reach this home's copy-a decision record"
  note=$(cat "$home/state/inbox"/*.note)
  assert_contains "$note" "rows=copy-a" "the hand-off names the row it closed here"
  assert_contains "$note" "mate: copy-a" "the hand-off routes the secondmate copy to its home"

  rm -f "$home/state/inbox"/*.note
  out=$(FM_HOME="$home" FM_QUEUE_SNAPSHOT="$snap" "$QUEUE" answer mate:twin-x --group \
    --members mate:twin-x,mate:twin-y --text "Saturday." 2>&1)
  rc=$?
  expect_code 1 "$rc" "matching prose must not authorize one answer for two secondmate rows: $out"
  assert_contains "$out" "nothing was answered" "the refused group answer says it closed nothing"
  [ -z "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null)" ] \
    || fail "a refused same-reason group answer must hand nothing off"
  pass "group answers follow explicit identity and never matching prose"
}

test_dead_worker_reads_unknown_never_done
test_captain_hold_reads_waiting_on_you
test_text_is_never_clipped
test_a_non_captain_hold_is_not_reported_as_a_failed_worker
test_cut_text_is_disclosed_not_passed_off_as_whole
test_every_row_prints_and_no_bucket_is_capped
test_maintenance_is_grouped_apart
test_unresolved_project_is_reported_not_hidden
test_wave_layers_stay_inside_their_project
test_json_model_parity
test_withheld_records_are_disclosed_with_a_reveal_path
test_refuses_a_non_snapshot_input
test_reads_the_real_snapshot_and_stays_read_only
test_answer_is_handed_off_through_the_home_inbox
test_a_keyed_answer_closes_through_the_captain_hold_owner
test_an_aged_answer_closes_through_the_captain_hold_owner
test_answer_starts_no_worker_and_refuses_what_it_cannot_answer
test_expired_and_deferred_holds_stay_out_of_the_decisions
test_routine_cleanup_is_an_agent_chore_and_discards_rule_once
test_explicit_identity_groups_and_same_reason_stays_distinct
test_an_answered_main_call_does_not_close_an_unmatched_mirror
test_answered_open_hold_hygiene_respects_hold_lifecycles
test_decisions_rank_by_consequence
test_a_group_answer_closes_every_row_of_the_call
test_identity_is_scoped_to_its_home_and_project
test_cut_reasons_and_answered_calls_never_merge_distinct_calls
test_a_group_answer_spans_homes_without_mistaking_rows
