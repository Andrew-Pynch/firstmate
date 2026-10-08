#!/usr/bin/env bash
# Behavior tests for the --project-token flag contract on bin/fm-spawn.sh.
#
# The flag carries a task's Herdr colour token, so the spawn must refuse it
# where it cannot mean anything (a secondmate home, a relaunch that keeps its
# recorded label) and refuse a value that would split into two metadata tokens.
# These are parse-time refusals: they happen before any endpoint, worktree, or
# record exists, which is what makes them cheap to assert here without a live
# backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-label)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

spawn() { # <args...>
  # The advisory guard banner is not this test's subject; drop its report lines
  # from the captured output while preserving the spawn's own exit status.
  local status
  FM_HOME="$HOME_DIR" FM_GATE_REFUSE_BYPASS=1 "$SPAWN" "$@" >"$TMP_ROOT/spawn.out" 2>&1
  status=$?
  grep -v '^●' "$TMP_ROOT/spawn.out" || true
  return "$status"
}

expect_refusal() { # <expected-substring> <args...>
  local want=$1
  shift
  local out
  if out=$(spawn "$@"); then
    fail "spawn should have refused: $*"
  fi
  case "$out" in
  *"$want"*) ;;
  *) fail "refusal for '$*' should mention '$want', got: $out" ;;
  esac
}

expect_refusal "--project-token requires a value" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token
expect_refusal "--project-token requires a non-empty value" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token=
expect_refusal "must be one whitespace-free token" some-task "$TMP_ROOT" \
  --mode local-only --yolo on --project-token 'two tokens'
# A secondmate's display identity is its own home workspace, not one project.
expect_refusal "applies to a ship or scout spawn" secondmate-task --secondmate --project-token pilot
pass "the project-token flag refuses a missing, empty, split, or secondmate value"

# No spawn happened, so the home holds no task record at all.
[ -e "$HOME_DIR/state/some-task.meta" ] && fail "a refused spawn must not write a task record"
pass "a refused project-token spawn leaves no task record"

# Run the public spawn command against a stateful Herdr protocol fixture.
# Both homes must place the task directly outside the parent's workspace.
# This proves Firstmate's behavior, not persistence in a live Herdr server.
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid
for shape in primary secondmate primary-flat secondmate-flat unmatched-parent; do
  dir="$TMP_ROOT/$shape"
  home="$dir/home"
  project="$dir/project"
  wt="$dir/wt"
  id="label-$shape"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  # The session lock's production namespace is machine-private. Redirect only
  # that provider boundary in an isolated code copy, never the labeling code.
  mkdir -p "$dir/code"
  cp -R "$ROOT/bin" "$dir/code/bin"
  # shellcheck disable=SC2016 # Expand this variable when the copied backend runs, not while generating it.
  printf '\nfm_backend_herdr_presentation_lock_namespace() { printf "%%s" "$FM_LABEL_STUB_LOCKS"; }\n' \
    >> "$dir/code/bin/backends/herdr.sh"
  mkdir -m 700 "$dir/locks"
  fm_git_worktree "$project" "$wt" "fm-$id"
  fm_test_spawn_brief "$home" "$id"
  parent_label=firstmate
  if [[ "$shape" = secondmate* ]]; then
    printf 'mate-label\n' > "$home/.fm-secondmate-home"
    parent_label=2ndmate-mate-label
  fi
  if [[ "$shape" = *-flat ]]; then
    printf 'off\n' > "$home/config/herdr-presentation-spaces"
  elif [ "$shape" = unmatched-parent ]; then
    parent_label=unmatched
  fi
  printf '%s\n' '- project [local-only] subprojects=pilot,parts - Org/project' > "$home/data/projects.md"
  fake=$(fm_test_make_spawn_fakebin "$dir/fake" codex)
  cp "$ROOT/tests/assets/fm-spawn-herdr-stub.py" "$fake/herdr"
  stub_state="$dir/herdr.json"
  jq -n --arg label "$parent_label" '{
    calls:[],
    workspaces:[{workspace_id:"w1",label:$label,focused:true,active_tab_id:"w1:t1"}],
    tabs:[{workspace_id:"w1",tab_id:"w1:t1",label:"Main",focused:true}],
    panes:[{workspace_id:"w1",tab_id:"w1:t1",pane_id:"w1:p1"}]
  }' > "$stub_state"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/code" FM_SPAWN_NO_GUARD=1 \
    FM_LABEL_STUB_STATE="$stub_state" FM_LABEL_STUB_WT="$wt" FM_LABEL_STUB_LOCKS="$dir/locks" \
    HERDR_SESSION=label-fixture PATH="$fake:$PATH" \
    bash "$dir/code/bin/fm-spawn.sh" "$id" "$project" 'true' --harness codex \
      --mode local-only --yolo off --backend herdr --project-token parts 2>&1) \
    || fail "$shape project-label spawn failed: $out"
  jq -e --arg parent "$parent_label" '
    (.workspaces[] | select(.workspace_id == "w1") | .label == $parent and .tokens == null)
    and (.workspaces[] | select(.workspace_id == "w2") | .tokens.project == "parts")
    and (.panes[] | select(.pane_id == "w2:p1") | .tokens.project == "parts")
    and ([.tabs[] | select(.workspace_id == "w1")] | length == 1)
    and ([.calls[] | select(.[0:2] == ["tab","create"] and
       (index("--workspace") as $i | .[$i + 1] == "w1"))] | length == 0)
  ' "$stub_state" >/dev/null || fail "$shape spawn changed its parent or lost the explicit project token"
  assert_grep 'project_token=parts' "$home/state/$id.meta" "explicit subproject identity was not recorded"
  assert_grep 'herdr_workspace_id=w2' "$home/state/$id.meta" "task workspace identity was not recorded"
  pass "$shape spawn labels its new workspace and pane without creating a worker in the parent"
done

echo "ALL TESTS PASSED"
