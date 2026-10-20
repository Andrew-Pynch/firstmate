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
test_answer_starts_no_worker_and_refuses_what_it_cannot_answer
