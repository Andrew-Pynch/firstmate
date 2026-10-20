#!/usr/bin/env bash
# tests/fm-secondmate-rename.test.sh - the supported secondmate rename, local and
# remote, driven end to end through the real scripts.
#
# Coverage anchored here (must not regress):
#   - a live endpoint refuses the rename, with and without --stopped, and names
#     the exact control-plane stop for that placement
#   - a linked worktree (a treehouse-leased home) refuses the home move
#   - a rename that keeps its home path leaves every path field alone, in the
#     home's own records and in the parent's, and moves only the id fields
#   - a home with live child work refuses the move before the parent reply
#     channel is retired, so a refusal cannot strand the mate without one
#   - an unsettled pending reply for the mate refuses before anything changes
#   - the local path: registry line, parent task record, per-id state records,
#     the presentation-cursor row, the stopped endpoint, and the machine-named
#     home directory all move, and the registry validates afterwards
#   - the remote path drives the home half through bin/fm-on.sh and
#     bin/fm-remote-secondmate-control.sh rename, on the mate's own host
#   - the remote reply source is retired, its cursor migrates to the new source
#     id, and the source is re-armed under the new id
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-secondmate-rename)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$CLAIMS"

OLD=bertha-pilot
NEW=bertha
REMOTE_HOST_ALIAS="remote-mac"

cleanup() {
  local worker_pid='' wait_attempt=0
  FM_HOME="$TMP_ROOT/local-parent" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  FM_HOME="$TMP_ROOT/remote-parent" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid" 2>/dev/null || true)
    [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null
    while [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null && [ "$wait_attempt" -lt 100 ]; do
      wait_attempt=$((wait_attempt + 1))
      sleep 0.05
    done
  fi
  rm -rf -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

seed_home_markers() { # <home> <id> <route> <parent>
  local home=$1 id=$2 route=$3 parent=$4
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf 'home instructions\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  if [ "$route" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  fi
}

write_parent_meta() { # <meta> <id> <home> <project> <placement:local|remote>
  local meta=$1 id=$2 home=$3 project=$4 placement=$5
  {
    if [ "$placement" = remote ]; then
      printf 'window=remote:%s\n' "$id"
    else
      printf 'window=firstmate:fm-%s\n' "$id"
    fi
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$home"
    printf 'project=%s\n' "$project"
    printf 'harness=codex\n'
    printf 'kind=secondmate\n'
    printf 'mode=secondmate\n'
    printf 'yolo=off\n'
    printf 'tasktmp=/tmp/fm-%s\n' "$id"
    printf 'model=\n'
    printf 'effort=\n'
    printf 'home=%s\n' "$home"
    if [ "$placement" = remote ]; then
      # A remote mate's code root is its HOST's Firstmate checkout, which is the
      # registry root - never a path under the mate home.
      printf 'code_root=%s\n' "$project"
    else
      printf 'code_root=%s\n' "$home"
    fi
    printf 'projects=monorepo\n'
    if [ "$placement" = remote ]; then
      printf 'remote_host=%s\n' "$REMOTE_HOST_ALIAS"
      printf 'remote_root=%s\n' "$project"
      printf 'remote_backend=herdr\n'
      printf 'remote_herdr_session=fm-remote\n'
      printf 'remote_target=fm-remote:missing-pane\n'
    else
      printf 'backend=tmux\n'
    fi
  } > "$meta"
}

# --- local case --------------------------------------------------------------

LOCAL_PARENT="$TMP_ROOT/local-parent"
LOCAL_BASE="$TMP_ROOT/fm-homes"
LOCAL_HOME="$LOCAL_BASE/$OLD"
LOCAL_FAKEBIN=
LOCAL_LOG="$TMP_ROOT/local-tmux.log"
LOCAL_WINDOW=
LOCAL_PANE_COMMAND=

setup_local() {
  mkdir -p "$LOCAL_PARENT/data" "$LOCAL_PARENT/state" "$LOCAL_BASE"
  LOCAL_FAKEBIN=$(make_fake_tmux "$TMP_ROOT/local-fake")
  seed_home_markers "$LOCAL_HOME" "$OLD" local "$LOCAL_PARENT"
  printf -- '- %s - Own explicitly routed Pilot work on big-bertha. (home: %s; scope: bounded Pilot work; projects: monorepo; added 2026-09-12)\n' \
    "$OLD" "$LOCAL_HOME" > "$LOCAL_PARENT/data/secondmates.md"
  mkdir -p "$LOCAL_PARENT/data/$OLD"
  printf 'charter\n' > "$LOCAL_PARENT/data/$OLD/brief.md"
  write_parent_meta "$LOCAL_PARENT/state/$OLD.meta" "$OLD" "$LOCAL_HOME" "$LOCAL_PARENT" local
  printf 'done: previous work\n' > "$LOCAL_PARENT/state/$OLD.status"
  : > "$LOCAL_PARENT/state/.seen-$OLD""_status"
  mkdir -p "$LOCAL_PARENT/state/$OLD.inbox/handled"
  printf 'pending request\n' > "$LOCAL_PARENT/state/$OLD.inbox/001.msg"
  printf 'pid=1\n' > "$LOCAL_PARENT/state/.remote-inherit-$OLD.lock"
  printf '%s\t123:456\t10\t5\n' "$OLD" > "$LOCAL_PARENT/state/.status-presentation-cursor"
  printf 'other-task\t1:2\t3\t4\n' >> "$LOCAL_PARENT/state/.status-presentation-cursor"
  mkdir -p "$LOCAL_HOME/state/parent-route"
  printf 'done: home work\n' > "$LOCAL_HOME/state/parent-route/$OLD.status"
  : > "$LOCAL_LOG"
}

run_local() { # <extra args...>
  LOCAL_RC=0
  LOCAL_OUT=$(PATH="$LOCAL_FAKEBIN:$PATH" FM_HOME="$LOCAL_PARENT" \
    FM_FAKE_TMUX_LOG="$LOCAL_LOG" FM_FAKE_TMUX_WINDOW="$LOCAL_WINDOW" \
    FM_FAKE_TMUX_PANE_COMMAND="$LOCAL_PANE_COMMAND" \
    "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" "$@" 2>&1) || LOCAL_RC=$?
}

case_local_refuses_live_endpoint() {
  LOCAL_WINDOW="firstmate:fm-$OLD"
  LOCAL_PANE_COMMAND=codex
  run_local
  [ "$LOCAL_RC" -ne 0 ] || fail "a live secondmate endpoint must refuse the rename"
  assert_contains "$LOCAL_OUT" "still reports a live agent" "the refusal did not name the live endpoint"
  assert_contains "$LOCAL_OUT" "bin/fm-control.sh $OLD exit" "the refusal did not name the local stop command"
  run_local --stopped
  [ "$LOCAL_RC" -ne 0 ] || fail "--stopped must never override a positively live endpoint"
  assert_grep "- $OLD - " "$LOCAL_PARENT/data/secondmates.md" "a refused rename rewrote the registry line"
  assert_present "$LOCAL_HOME/.fm-secondmate-home" "a refused rename moved the home"
  pass "local: a live endpoint refuses the rename, with or without --stopped"
}

case_local_refuses_linked_worktree() {
  LOCAL_WINDOW=
  LOCAL_PANE_COMMAND=
  printf 'gitdir: /elsewhere/.git/worktrees/bertha-pilot\n' > "$LOCAL_HOME/.git"
  run_local
  [ "$LOCAL_RC" -ne 0 ] || fail "a linked worktree must refuse the home move"
  assert_contains "$LOCAL_OUT" "treehouse-leased home must be re-seeded" "the linked-worktree refusal was not actionable"
  assert_present "$LOCAL_BASE/$OLD/.fm-secondmate-home" "a refused home move left the home half-done"
  rm -f "$LOCAL_HOME/.git"
  pass "local: a linked worktree refuses the home move"
}

# A rename that keeps its home path must not rewrite a single path, because the
# machine-named path it would name does not exist: the home's own child records
# keep pointing at the projects and worktrees under the home that is still
# there. The id fields are the only ones that follow the id. This is the defect
# where every child meta in a kept home came to name a path nobody created.
case_local_keeps_every_path_when_the_home_is_kept() {
  local world parent base home fakebin
  world="$TMP_ROOT/keep-path-world"
  parent="$world/parent"
  base="$world/fm-homes"
  home="$base/$OLD"
  mkdir -p "$parent/data" "$parent/state" "$base"
  fakebin=$(make_fake_tmux "$world/fake")
  seed_home_markers "$home" "$OLD" local "$parent"
  printf -- '- %s - kept path. (home: %s; scope: s; projects: monorepo; added 2026-09-12)\n' "$OLD" "$home" \
    > "$parent/data/secondmates.md"
  write_parent_meta "$parent/state/$OLD.meta" "$OLD" "$home" "$parent" local
  # A child task record whose work lives under the mate's own home, plus one line
  # that carries the mate id inside a longer token, which the bounded rule must
  # leave alone.
  mkdir -p "$home/state"
  {
    printf 'window=firstmate:fm-child\n'
    printf 'endpoint_task_id=child\n'
    printf 'worktree=%s/projects/monorepo/wt\n' "$home"
    printf 'project=%s/projects/monorepo\n' "$home"
    printf 'home=%s\n' "$home"
    printf 'code_root=%s\n' "$home"
    printf 'tasktmp=/tmp/fm-child\n'
    printf 'note=%s-nightly\n' "$OLD"
    printf 'harness=codex\n'
    printf 'kind=ship\n'
  } > "$home/state/child.meta"
  cp "$home/state/child.meta" "$world/child.before"

  WORLD_RC=0
  WORLD_OUT=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_FAKE_TMUX_LOG="$world/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$world/fake/pane.txt" \
    "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" --keep-home-path 2>&1) || WORLD_RC=$?
  [ "$WORLD_RC" -eq 0 ] || fail "the kept-path rename failed: $WORLD_OUT"
  assert_contains "$WORLD_OUT" "home=$home" "the kept-path rename did not report the home it kept"
  assert_contains "$WORLD_OUT" "moved=no" "the kept-path rename claimed it moved the home"
  assert_present "$home/.fm-secondmate-home" "the kept-path rename moved the home anyway"
  assert_absent "$base/$NEW" "the kept-path rename created the machine-named path"
  cmp -s "$world/child.before" "$home/state/child.meta" \
    || fail "a kept home rewrote a child record's paths:"$'\n'"$(diff "$world/child.before" "$home/state/child.meta")"
  assert_grep "code_root=$home" "$parent/state/$NEW.meta" "the parent record moved the code root off the kept home"
  assert_grep "window=firstmate:fm-$NEW" "$parent/state/$NEW.meta" "the parent record kept the old window handle"
  assert_grep "endpoint_task_id=$NEW" "$parent/state/$NEW.meta" "the parent record kept the old endpoint binding"
  pass "local: a kept home renames the identity and leaves every path where it is"
}

case_local_refuses_pending_reply() {
  mkdir -p "$LOCAL_PARENT/state/pending-replies"
  cat > "$LOCAL_PARENT/state/pending-replies/0001" <<EOF
schema=fm-pending-reply.v1
task_id=$OLD
phase=awaiting_report
EOF
  run_local
  [ "$LOCAL_RC" -ne 0 ] || fail "an unsettled pending reply must refuse the rename"
  assert_contains "$LOCAL_OUT" "pending-replies/0001" "the refusal did not name the pending reply record"
  assert_present "$LOCAL_HOME/.fm-secondmate-home" "the pending-reply refusal mutated the home"
  rm -f "$LOCAL_PARENT/state/pending-replies/0001"
  pass "local: an unsettled pending reply refuses before anything changes"
}

case_local_refuses_registered_new_id() {
  printf -- '- %s - another mate already answers to this name. (home: %s; scope: s; projects: monorepo; added 2026-09-13)\n' \
    "$NEW" "$LOCAL_BASE/$NEW" >> "$LOCAL_PARENT/data/secondmates.md"
  run_local
  [ "$LOCAL_RC" -ne 0 ] || fail "an id that is already registered must refuse the rename"
  assert_contains "$LOCAL_OUT" "already registered" "the collision refusal was not named"
  assert_present "$LOCAL_HOME/.fm-secondmate-home" "the collision refusal mutated the home"
  grep -v -- "- $NEW - another mate already answers to this name" "$LOCAL_PARENT/data/secondmates.md" \
    > "$LOCAL_PARENT/data/secondmates.tmp" \
    || fail "could not restore the registry fixture"
  mv -f "$LOCAL_PARENT/data/secondmates.tmp" "$LOCAL_PARENT/data/secondmates.md"
  pass "local: an already registered new id refuses the rename"
}

case_local_needs_proof_when_unverifiable() {
  # A record the local backend cannot attribute is neither alive nor proven
  # stopped: the mate must have been stopped for real, which only the caller can
  # attest.
  local world parent base home fakebin
  world="$TMP_ROOT/unverifiable-world"
  parent="$world/parent"
  base="$world/fm-homes"
  home="$base/$OLD"
  mkdir -p "$parent/data" "$parent/state" "$base"
  fakebin=$(make_fake_tmux "$world/fake")
  seed_home_markers "$home" "$OLD" local "$parent"
  printf -- '- %s - unverifiable world. (home: %s; scope: s; projects: monorepo; added 2026-09-12)\n' "$OLD" "$home" \
    > "$parent/data/secondmates.md"
  write_parent_meta "$parent/state/$OLD.meta" "$OLD" "$home" "$parent" local
  sed -i "s|^window=.*|window=firstmate:fm-someone-else|" "$parent/state/$OLD.meta"

  WORLD_RC=0
  WORLD_OUT=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_FAKE_TMUX_LOG="$world/tmux.log" \
    "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" 2>&1) || WORLD_RC=$?
  [ "$WORLD_RC" -ne 0 ] || fail "an unattributable endpoint must refuse without --stopped"
  assert_contains "$WORLD_OUT" "--stopped" "the refusal did not name the caller's proof"

  WORLD_RC=0
  WORLD_OUT=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_FAKE_TMUX_LOG="$world/tmux.log" \
    "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" --stopped 2>&1) || WORLD_RC=$?
  [ "$WORLD_RC" -eq 0 ] || fail "--stopped must let an unverifiable endpoint through: $WORLD_OUT"
  assert_present "$base/$NEW/.fm-secondmate-home" "the proven-stopped rename did not complete"
  pass "local: an unattributable endpoint needs the caller's proof, and accepts it"
}

case_local_renames() {
  # The recorded window still exists in the session inventory, and its live
  # process is a shell, so the backend positively reports the agent gone and the
  # endpoint itself must be retired rather than left holding the old label.
  LOCAL_WINDOW="firstmate:fm-$OLD"
  LOCAL_PANE_COMMAND=zsh
  run_local
  [ "$LOCAL_RC" -eq 0 ] || fail "the local rename failed: $LOCAL_OUT"
  assert_contains "$LOCAL_OUT" "home=$LOCAL_BASE/$NEW" "the rename did not report the machine-named home"
  assert_contains "$LOCAL_OUT" "endpoint=removed" "the dead endpoint was not reported as retired"

  assert_grep "- $NEW - Own explicitly routed Pilot work on big-bertha. (home: $LOCAL_BASE/$NEW; scope: bounded Pilot work; projects: monorepo; added 2026-09-12)" \
    "$LOCAL_PARENT/data/secondmates.md" "the registry line was not re-emitted for the new id"
  assert_no_grep "$OLD" "$LOCAL_PARENT/data/secondmates.md" "the registry still names the old id"
  FM_HOME="$LOCAL_PARENT" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "the registry no longer validates after the rename"

  assert_present "$LOCAL_BASE/$NEW/.fm-secondmate-home" "the home was not moved to its machine name"
  assert_absent "$LOCAL_BASE/$OLD" "the old home path survived the rename"
  [ "$(cat "$LOCAL_BASE/$NEW/.fm-secondmate-home")" = "$NEW" ] || fail "the identity marker was not rewritten"
  cmp -s <(printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LOCAL_PARENT") \
    "$LOCAL_BASE/$NEW/.fm-secondmate-parent" || fail "the parent record was not republished from its parsed fields"

  assert_absent "$LOCAL_PARENT/state/$OLD.meta" "the old parent task record survived"
  assert_grep "window=firstmate:fm-$NEW" "$LOCAL_PARENT/state/$NEW.meta" "the parent record keeps the old window handle"
  assert_grep "endpoint_task_id=$NEW" "$LOCAL_PARENT/state/$NEW.meta" "the parent record keeps the old endpoint binding"
  assert_grep "tasktmp=/tmp/fm-$NEW" "$LOCAL_PARENT/state/$NEW.meta" "the parent record keeps the old task tmp path"
  assert_grep "worktree=$LOCAL_BASE/$NEW" "$LOCAL_PARENT/state/$NEW.meta" "the parent record keeps the old home path"

  assert_absent "$LOCAL_PARENT/state/$OLD.status" "the old status log survived"
  assert_present "$LOCAL_PARENT/state/$NEW.status" "the status log was not renamed"
  assert_absent "$LOCAL_PARENT/state/.seen-$OLD""_status" "the old seen marker survived"
  assert_present "$LOCAL_PARENT/state/$NEW.inbox/001.msg" "the steering inbox was not renamed with its pending record"
  assert_present "$LOCAL_PARENT/state/.remote-inherit-$NEW.lock" "the id-keyed sidecar was not renamed"
  assert_absent "$LOCAL_PARENT/data/$OLD" "the charter brief directory was not renamed"
  assert_present "$LOCAL_PARENT/data/$NEW/brief.md" "the charter brief did not move"
  assert_present "$LOCAL_BASE/$NEW/state/parent-route/$NEW.status" "the home's own per-id record was not renamed"

  assert_grep "	123:456	10	5" "$LOCAL_PARENT/state/.status-presentation-cursor" "the presentation cursor row did not move"
  assert_no_grep "$OLD" "$LOCAL_PARENT/state/.status-presentation-cursor" "the presentation cursor still keys the old id"
  assert_grep 'other-task' "$LOCAL_PARENT/state/.status-presentation-cursor" "an unrelated cursor row was disturbed"

  assert_grep "kill-window -t =firstmate:=fm-$OLD" "$LOCAL_LOG" "the dead endpoint was not retired through the tmux backend"
  pass "local: registry, task record, state records, endpoint, and home all move together"
}

# --- remote case -------------------------------------------------------------

REMOTE_PARENT="$TMP_ROOT/remote-parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_BASE="$TMP_ROOT/remote-homes"
REMOTE_HOME="$REMOTE_BASE/$OLD"
FAKEBIN=
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
SSH_COUNT="$TMP_ROOT/ssh.count"

setup_remote() {
  mkdir -p "$REMOTE_PARENT/data" "$REMOTE_PARENT/state" "$REMOTE_ROOT" "$REMOTE_BASE" "$TMP_ROOT/remote-jobs"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
  seed_home_markers "$REMOTE_HOME" "$OLD" remote "$REMOTE_HOST_ALIAS"
  # The host runs the tracked scripts from its own code root.
  ( cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - . ) \
    | ( cd "$REMOTE_ROOT" && tar -xf - )
  git -C "$REMOTE_ROOT" init -q -b main
  git -C "$REMOTE_ROOT" config user.email test@example.com
  git -C "$REMOTE_ROOT" config user.name Test
  git -C "$REMOTE_ROOT" add -A
  git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
  install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
    "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"

  cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
  chmod +x "$FAKEBIN/fake-ssh"

  # A remote route, its parent task record, its status stream, and the reply
  # source the parent runs against it (with a live cursor and a captured result
  # to migrate).
  printf -- '- %s - Own explicitly routed Pilot work on big-bertha. (host: %s; root: %s; home: %s; scope: bounded Pilot work; projects: monorepo; added 2026-09-12)\n' \
    "$OLD" "$REMOTE_HOST_ALIAS" "$REMOTE_ROOT" "$REMOTE_HOME" > "$REMOTE_PARENT/data/secondmates.md"
  mkdir -p "$REMOTE_PARENT/data/$OLD"
  printf 'charter\n' > "$REMOTE_PARENT/data/$OLD/brief.md"
  write_parent_meta "$REMOTE_PARENT/state/$OLD.meta" "$OLD" "$REMOTE_HOME" "$REMOTE_ROOT" remote
  printf 'done: remote work\n' > "$REMOTE_PARENT/state/$OLD.status"
  mkdir -p "$REMOTE_PARENT/state/remote-replies" "$REMOTE_PARENT/state/procevent-inbox"
  {
    printf 'schema=fm-remote-reply-cursor.v1\n'
    printf 'offset=17\n'
    printf 'prefix_sha256=%s\n' "$(printf 'seed' | sha256sum | awk '{print $1}')"
  } > "$REMOTE_PARENT/state/remote-replies/$OLD.cursor"
  printf 'handled\n' > "$REMOTE_PARENT/state/procevent-inbox/remote-reply-$OLD.1.handled"

  # The mate's own host: the private parent-route endpoint record plus its
  # steering inbox.
  mkdir -p "$REMOTE_HOME/state/parent-route/$OLD.inbox"
  printf 'pending request\n' > "$REMOTE_HOME/state/parent-route/$OLD.inbox/001.msg"
  {
    printf 'window=fm-remote:missing-pane\n'
    printf 'endpoint_task_id=%s\n' "$OLD"
    printf 'worktree=%s\n' "$REMOTE_HOME"
    printf 'project=%s\n' "$REMOTE_ROOT"
    printf 'harness=codex\n'
    printf 'kind=secondmate\n'
    printf 'mode=secondmate\n'
    printf 'yolo=off\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=fm-remote\n'
    printf 'herdr_workspace_id=w1\n'
    printf 'herdr_tab_id=t1\n'
    printf 'herdr_pane_id=missing-pane\n'
    printf 'home=%s\n' "$REMOTE_HOME"
    printf 'code_root=%s\n' "$REMOTE_ROOT"
  } > "$REMOTE_HOME/state/parent-route/$OLD.meta"
}

remote_env() {
  FM_HOME="$REMOTE_PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  "$@"
}

# A home that still has live child work cannot be moved, and that refusal must
# land before the parent retires the reply channel: otherwise the mate keeps its
# old id with no channel left for it to answer on. The refusal is decided on the
# mate's own host, because only that host can see its child work.
case_remote_refuses_a_live_child_before_retiring_the_reply_source() {
  remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" arm "$OLD" >/dev/null \
    || fail "could not arm the reply source for the live-child fixture"
  assert_present "$REMOTE_PARENT/state/procevent/remote-reply-$OLD.source" "the fixture did not register the reply source"
  assert_present "$REMOTE_PARENT/state/remote-replies/$OLD.cursor" "the fixture has no reply cursor to migrate"
  cp "$REMOTE_PARENT/state/remote-replies/$OLD.cursor" "$TMP_ROOT/remote-reply-cursor.before"

  printf '{"next":3,"workspaces":[{"workspace_id":"w1","label":"child","cwd":"%s"}],"tabs":[{"tab_id":"w1:t2","label":"1","workspace_id":"w1","pane_id":"w1:p2"}],"typed":{"w1:p2":true},"working":{}}\n' \
    "$REMOTE_HOME" > "$HERDR_STATE"
  {
    printf 'window=fm-remote:w1:p2\n'
    printf 'endpoint_task_id=child\n'
    printf 'worktree=%s/projects/monorepo/wt\n' "$REMOTE_HOME"
    printf 'project=%s/projects/monorepo\n' "$REMOTE_HOME"
    printf 'harness=codex\n'
    printf 'kind=ship\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=fm-remote\n'
    printf 'herdr_workspace_id=w1\n'
    printf 'herdr_tab_id=w1:t2\n'
    printf 'herdr_pane_id=w1:p2\n'
  } > "$REMOTE_HOME/state/child.meta"

  CHILD_RC=0
  CHILD_OUT=$(remote_env "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" 2>&1) || CHILD_RC=$?
  [ "$CHILD_RC" -ne 0 ] || fail "a home carrying live child work must refuse the move: $CHILD_OUT"
  assert_contains "$CHILD_OUT" "still report a live agent" "the refusal did not name the live child work"
  assert_present "$REMOTE_PARENT/state/procevent/remote-reply-$OLD.source" \
    "the refused rename retired the parent reply channel"
  assert_present "$REMOTE_PARENT/state/remote-replies/$OLD.cursor" \
    "the refused rename migrated the reply cursor"
  assert_absent "$REMOTE_PARENT/state/remote-replies/$NEW.cursor" \
    "the refused rename published a cursor for an id that was never created"
  assert_present "$REMOTE_HOME/.fm-secondmate-home" "the refused rename mutated the home"
  assert_absent "$REMOTE_BASE/$NEW" "the refused rename created the machine-named path"

  rm -f "$REMOTE_HOME/state/child.meta"
  reset_remote_herdr_fixture "$HERDR_STATE"
  # The retirement this case's cleanup runs deletes the mate's own reply cursor,
  # which the case after this one migrates; put the fixture back exactly as found.
  remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" retire "$OLD" >/dev/null 2>&1 || true
  cp "$TMP_ROOT/remote-reply-cursor.before" "$REMOTE_PARENT/state/remote-replies/$OLD.cursor"
  pass "remote: live child work refuses the move before the parent channel is retired"
}

case_remote_renames() {
  remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" arm "$OLD" >/dev/null \
    || fail "could not arm the reply source for the remote fixture"
  assert_present "$REMOTE_PARENT/state/procevent/remote-reply-$OLD.source" "the fixture did not register the reply source"

  REMOTE_RC=0
  REMOTE_OUT=$(remote_env "$ROOT/bin/fm-secondmate-rename.sh" "$OLD" "$NEW" 2>&1) || REMOTE_RC=$?
  [ "$REMOTE_RC" -eq 0 ] || fail "the remote rename failed: $REMOTE_OUT"
  assert_contains "$REMOTE_OUT" "home=$REMOTE_BASE/$NEW" "the remote rename did not report the machine-named home"
  [ "$(cat "$SSH_COUNT")" -gt 0 ] || fail "the remote half never reached the mate's host"

  assert_grep "- $NEW - Own explicitly routed Pilot work on big-bertha. (host: $REMOTE_HOST_ALIAS; root: $REMOTE_ROOT; home: $REMOTE_BASE/$NEW; scope: bounded Pilot work; projects: monorepo; added 2026-09-12)" \
    "$REMOTE_PARENT/data/secondmates.md" "the remote registry line was not re-emitted for the new id"
  assert_no_grep "$OLD" "$REMOTE_PARENT/data/secondmates.md" "the remote registry still names the old id"
  FM_HOME="$REMOTE_PARENT" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "the remote registry no longer validates after the rename"

  assert_present "$REMOTE_BASE/$NEW/.fm-secondmate-home" "the remote home was not moved on its host"
  assert_absent "$REMOTE_BASE/$OLD" "the old remote home path survived"
  [ "$(cat "$REMOTE_BASE/$NEW/.fm-secondmate-home")" = "$NEW" ] || fail "the remote identity marker was not rewritten"
  cmp -s <(printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=%s\n' "$REMOTE_HOST_ALIAS") \
    "$REMOTE_BASE/$NEW/.fm-secondmate-parent" || fail "the remote parent record was not republished"
  assert_present "$REMOTE_BASE/$NEW/state/parent-route/$NEW.inbox/001.msg" "the host-local steering inbox was not renamed"
  assert_present "$REMOTE_BASE/$NEW/state/parent-route/$NEW.meta" "the host-local endpoint record was not renamed"
  # The record's id field follows the id, its home fields follow the home that
  # moved, and a path outside that home is left exactly where it is.
  assert_grep "endpoint_task_id=$NEW" "$REMOTE_BASE/$NEW/state/parent-route/$NEW.meta" \
    "the host record kept the old endpoint binding"
  assert_grep "home=$REMOTE_BASE/$NEW" "$REMOTE_BASE/$NEW/state/parent-route/$NEW.meta" \
    "the host record kept the old home path"
  assert_grep "worktree=$REMOTE_BASE/$NEW" "$REMOTE_BASE/$NEW/state/parent-route/$NEW.meta" \
    "the host record kept the old worktree path"
  assert_grep "code_root=$REMOTE_ROOT" "$REMOTE_BASE/$NEW/state/parent-route/$NEW.meta" \
    "the home move rewrote the code root outside the home"

  assert_grep "window=remote:$NEW" "$REMOTE_PARENT/state/$NEW.meta" "the parent record keeps the old window handle"
  assert_grep "home=$REMOTE_BASE/$NEW" "$REMOTE_PARENT/state/$NEW.meta" "the parent record keeps the old home path"
  assert_absent "$REMOTE_PARENT/data/$OLD" "the charter brief directory was not renamed"

  # The reply channel migrates: the retired source leaves nothing behind, its
  # cursor keeps its offset under the new id, and the new source is armed.
  assert_absent "$REMOTE_PARENT/state/procevent/remote-reply-$OLD.source" "the retired reply source survived"
  assert_present "$REMOTE_PARENT/state/procevent/remote-reply-$NEW.source" "the reply source was not re-armed under the new id"
  assert_absent "$REMOTE_PARENT/state/remote-replies/$OLD.cursor" "the old reply cursor survived"
  assert_grep 'offset=17' "$REMOTE_PARENT/state/remote-replies/$NEW.cursor" "the reply cursor did not carry its offset across the rename"
  assert_absent "$REMOTE_PARENT/state/procevent-inbox/remote-reply-$OLD.1.handled" "the captured reply record kept the old source id"
  assert_present "$REMOTE_PARENT/state/procevent-inbox/remote-reply-$NEW.1.handled" "the captured reply record was not migrated"
  assert_no_grep "$OLD" "$REMOTE_PARENT/state/remote-replies/$NEW.cursor" "the migrated cursor still names the old id"

  # The stop verb Main needs before a rename is the same delegation as relaunch:
  # it reaches the ordinary local control plane on that host, which answers with
  # its own verdict for this endpoint.
  # The documented way back is the ordinary recovery respawn, which requires the
  # host to classify the renamed endpoint as a recoverable state.
  STATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" "$NEW" fm-remote-secondmate-control.sh state "$NEW" 2>&1) \
    || fail "the renamed remote endpoint could not be read back"
  case "$STATE_OUT" in
    dead|missing) ;;
    *) fail "the renamed remote endpoint reads '$STATE_OUT', which blocks the recovery respawn" ;;
  esac

  EXIT_RC=0
  EXIT_OUT=$(remote_env "$ROOT/bin/fm-on.sh" "$NEW" fm-remote-secondmate-control.sh exit "$NEW" 2>&1) || EXIT_RC=$?
  case "$EXIT_OUT" in
    *"recorded endpoint is gone"*) [ "$EXIT_RC" -ne 0 ] || fail "exit accepted an endpoint its own plane calls gone" ;;
    *already-stopped*) [ "$EXIT_RC" -eq 0 ] || fail "exit reported already-stopped but failed" ;;
    *) fail "the exit verb did not reach the local control plane on that host: $EXIT_OUT" ;;
  esac
  pass "remote: the host half runs through fm-on, the reply channel migrates, and the stop verb delegates"
}

setup_local
case_local_refuses_live_endpoint
case_local_refuses_linked_worktree
case_local_keeps_every_path_when_the_home_is_kept
case_local_refuses_pending_reply
case_local_refuses_registered_new_id
case_local_renames
case_local_needs_proof_when_unverifiable

setup_remote
case_remote_refuses_a_live_child_before_retiring_the_reply_source
case_remote_renames

echo "ALL TESTS PASSED"