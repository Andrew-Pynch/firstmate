#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/andrewpynch/.no-mistakes/evidence/01M4E2CNFR6HQA3KNXQJP9NDRB
LAB=$(mktemp -d "$ROOT/.test-tmp/fm-lab.XXXXXX")
SOCKET=
cleanup() {
  if [ -n "$SOCKET" ]; then
    TMUX_TMPDIR="$SOCKET" tmux -L fm-lab kill-server 2>/dev/null || true
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
# The documented helper owns short ephemeral socket directories: the absolute
# worktree path exceeds macOS sockaddr_un's limit with the stock tmux suffix.
SOCKET=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
ln -s "$SOCKET" "$LAB/tmux"
mkdir -p "$LAB/tmux"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'codex\n' > "$LAB/config/crew-harness"
touch "$LAB/config/supervision-host-off"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME='Live Spawn Probe' GIT_AUTHOR_EMAIL='probe@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export TREEHOUSE_ROOT="$LAB/treehouse" DISABLE_AUTOUPDATER=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_SPAWN_NO_GUARD FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -e FM_HOME="$LAB" codex
# Only this private server is inspected or controlled.
sleep 3
export TMUX=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
tmux -L fm-lab set-option -g default-shell /bin/bash
tmux -L fm-lab set-option -g default-command 'bash --noprofile --norc'
# Export the isolated pool into each worker shell through the lab server.
tmux -L fm-lab set-environment -g TREEHOUSE_ROOT "$TREEHOUSE_ROOT"
tmux -L fm-lab set-environment -g GIT_CONFIG_GLOBAL /dev/null
tmux -L fm-lab set-environment -g GIT_CONFIG_NOSYSTEM 1
tmux -L fm-lab set-environment -g GIT_ALLOW_PROTOCOL file
# Deliberately ignore submodule changes only in Treehouse's acquisition shell.
# The real spawn process does not inherit this override: its safety check must
# independently refuse unique and dirty child work even if the allocator did not.
tmux -L fm-lab set-environment -g GIT_CONFIG_COUNT 1
tmux -L fm-lab set-environment -g GIT_CONFIG_KEY_0 diff.ignoreSubmodules
tmux -L fm-lab set-environment -g GIT_CONFIG_VALUE_0 all
tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/lab-primary.txt"

make_case() {
  local name=$1
  CASE="$LAB/projects/$name"
  SUB="$LAB/remotes/$name-child"
  ORIGIN="$LAB/remotes/$name-parent.git"
  mkdir -p "$SUB" "$CASE"
  git -C "$SUB" init -qb main
  printf 'pin one\n' > "$SUB/lib.txt"
  git -C "$SUB" add lib.txt; git -C "$SUB" commit -qm pin-one
  PIN1=$(git -C "$SUB" rev-parse HEAD)
  git -C "$CASE" init -qb main
  git -C "$CASE" submodule --quiet add "file://$SUB" ui
  git -C "$CASE" commit -qm initial
  git clone -q --bare "$CASE" "$ORIGIN"
  git -C "$CASE" remote add origin "file://$ORIGIN"
  git -C "$CASE" fetch -q origin
  WT=$(cd "$CASE"; treehouse get --lease)
  git -C "$WT" submodule --quiet update --init
  treehouse return "$WT"
  printf 'pin two\n' > "$SUB/lib.txt"; git -C "$SUB" commit -qam pin-two
  PIN2=$(git -C "$SUB" rev-parse HEAD)
  git -C "$CASE/ui" fetch -q origin
  git -C "$CASE/ui" checkout -q "$PIN2"
  git -C "$CASE" commit -qam advance-pin
  if [ "$name" = named-reset ]; then
    git -C "$CASE" push -q origin HEAD:release/pin
  else
    git -C "$CASE" push -q origin main
  fi
  TARGET=$(git -C "$CASE" rev-parse HEAD)
  if [ "$name" = named-reset ]; then
    git -C "$CASE" reset -q --hard origin/main
    git -C "$CASE" submodule --quiet update --checkout
  fi
  FRESH_TOPIC=
}

brief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n\n## Captain\047s intent\nObserve a disposable spawn validation fixture without changing it.\n\n## Firstmate spec\nDo not run tools, write files, start validation, push, open a PR, or touch any non-fixture path. Reply only SPAWN_PROBE_READY and wait.\n' > "$LAB/data/$1/brief.md"
}

snapshot() {
  printf 'superproject HEAD=%s recorded-pin=%s\n' "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" rev-parse HEAD:ui)"
  printf 'parent status:\n'; git -C "$WT" status --porcelain
  if [ -e "$WT/ui/.git" ]; then
    printf 'child-HEAD=%s\n' "$(git -C "$WT/ui" rev-parse HEAD)"
    printf 'child status:\n'; git -C "$WT/ui" status --porcelain
    printf 'child origin branches:\n'; git -C "$WT/ui" for-each-ref --format='%(refname) %(objectname)' refs/remotes/origin
  else
    printf 'child remains uninitialized (ui/.git absent)\n'
  fi
}

run_case() {
  local name=$1 result=0 id="probe-$1"
  make_case "$name"
  case "$name" in
    reset-pin|named-reset|uninitialized) ;;
    *) git -C "$WT" fetch -q origin; git -C "$WT" reset -q --hard origin/main ;;
  esac
  case "$name" in
    stale-topic|live-topic)
      git -C "$SUB" checkout -qb topic "$PIN1"
      printf 'unique topic work\n' > "$SUB/topic.txt"
      git -C "$SUB" add topic.txt; git -C "$SUB" commit -qm topic
      TOPIC=$(git -C "$SUB" rev-parse HEAD)
      git -C "$WT/ui" fetch -q origin
      git -C "$WT/ui" checkout -q "$TOPIC"
      git -C "$WT/ui" config --replace-all remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
      if [ "$name" = stale-topic ]; then
        git -C "$SUB" checkout -q main; git -C "$SUB" branch -q -D topic
      else
        printf 'advanced topic\n' >> "$SUB/topic.txt"; git -C "$SUB" commit -qam advanced-topic
        FRESH_TOPIC=$(git -C "$SUB" rev-parse HEAD)
      fi
      git -C "$WT/ui" fetch -q --prune origin
      ;;
    unique-commit|mirror-only)
      printf 'local-only child work\n' > "$WT/ui/local.txt"
      git -C "$WT/ui" add local.txt; git -C "$WT/ui" commit -qm local-only
      if [ "$name" = mirror-only ]; then git -C "$WT/ui" update-ref refs/remotes/mirror/kept "$(git -C "$WT/ui" rev-parse HEAD)"; fi
      ;;
    stale-topic-reset)
      git -C "$SUB" checkout -qb topic "$PIN1"
      printf 'topic work outside narrowed fetch\n' > "$SUB/topic.txt"
      git -C "$SUB" add topic.txt; git -C "$SUB" commit -qm topic
      TOPIC=$(git -C "$SUB" rev-parse HEAD)
      git -C "$WT/ui" fetch -q origin; git -C "$WT/ui" checkout -q "$TOPIC"
      git -C "$WT/ui" config --replace-all remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
      git -C "$CASE/ui" fetch -q origin; git -C "$CASE/ui" checkout -q "$TOPIC"
      git -C "$CASE" commit -qam topic-pin; git -C "$CASE" push -q origin main
      git -C "$WT" fetch -q origin; git -C "$WT" reset -q --hard origin/main
      git -C "$CASE/ui" checkout -q "$PIN2"
      git -C "$CASE" checkout -qb release/pin; git -C "$CASE" commit -qam release-pin
      git -C "$CASE" push -q origin release/pin
      TARGET=$(git -C "$CASE" rev-parse HEAD)
      git -C "$SUB" checkout -q main; git -C "$SUB" branch -q -D topic
      git -C "$WT/ui" fetch -q --prune origin
      git -C "$CASE" checkout -q main; git -C "$CASE/ui" checkout -q "$TOPIC"
      ;;
    dirty-child) printf 'keep dirty child work\n' > "$WT/ui/keep.txt" ;;
    mixed-dirt) printf 'keep parent work\n' > "$WT/keep.txt" ;;
    failed-fetch) git -C "$WT/ui" remote set-url origin "file://$LAB/absent-child.git" ;;
    missing-pin)
      printf 'unpublished pin\n' > "$CASE/ui/unpublished.txt"
      git -C "$CASE/ui" add unpublished.txt; git -C "$CASE/ui" commit -qm unpublished-pin
      git -C "$CASE" commit -qam missing-pin; git -C "$CASE" push -q origin main
      TARGET=$(git -C "$CASE" rev-parse HEAD)
      ;;
    uninitialized) git -C "$WT" submodule deinit -q --all ;;
  esac
  brief "$id"
  local -a extra=()
  if [ "$name" = named-reset ] || [ "$name" = stale-topic-reset ]; then
    extra=(--base-branch release/pin)
    printf '\n# Setup\nYou are in a disposable git worktree of this project, at a detached HEAD on a clean copy of its base branch.\nBase branch: release/pin\n' >> "$LAB/data/$id/brief.md"
  fi
  printf '\n=== %s: before spawn ===\n' "$name"
  snapshot
  OLDCHILD=$(git -C "$WT/ui" rev-parse HEAD)
  OLDPARENT=$(git -C "$WT" rev-parse HEAD)
  printf '$ FM_HOME=<disposable lab> bin/fm-spawn.sh %s <fixture project> --scout --harness codex --backend tmux %s\n' "$id" "${extra[*]-}"
  "$ROOT/bin/fm-spawn.sh" "$id" "$CASE" --scout --harness codex --backend tmux "${extra[@]}" > "$LAB/$name.out" 2>&1 || result=$?
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/$name.out"
  printf 'spawn exit=%s\n' "$result"
  printf '=== %s: after spawn ===\n' "$name"
  snapshot
  if [ -f "$LAB/state/$id.meta" ]; then
    printf 'published task metadata:\n'; grep -E '^(worktree|window|harness|kind)=' "$LAB/state/$id.meta"
    actual=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/$id.meta")
    [ "$actual" = "$WT" ] || { printf 'ERROR: product chose a different slot: %s\n' "$actual"; return 1; }
  else
    printf 'task metadata absent\n'
  fi
  case "$name" in
    reset-pin|named-reset|drifted-pin|live-topic|uninitialized)
      [ "$result" = 0 ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$TARGET" ] && [ -z "$(git -C "$WT" status --porcelain)" ] || return 1
      if [ "$name" != uninitialized ]; then
        [ "$(git -C "$WT/ui" rev-parse HEAD)" = "$PIN2" ] || return 1
      else
        [ ! -e "$WT/ui/.git" ] || return 1
      fi
      ;;
    *)
      [ "$result" != 0 ] && [ ! -f "$LAB/state/$id.meta" ] && [ "$(git -C "$WT/ui" rev-parse HEAD)" = "$OLDCHILD" ] || return 1
      if [ "$name" != missing-pin ] && [ "$name" != stale-topic-reset ]; then
        [ "$(git -C "$WT" rev-parse HEAD)" = "$OLDPARENT" ] || return 1
      fi
      ;;
  esac
  if [ "$name" = live-topic ]; then
    [ "$(git -C "$WT/ui" rev-parse origin/topic)" = "$FRESH_TOPIC" ] || return 1
  fi
  if [ "$name" = stale-topic ] || [ "$name" = stale-topic-reset ]; then
    [ "$(git -C "$WT/ui" rev-parse HEAD)" = "$TOPIC" ] && [ -f "$WT/ui/topic.txt" ] || return 1
    ! git -C "$WT/ui" rev-parse --verify origin/topic >/dev/null 2>&1 || return 1
    if [ "$name" = stale-topic-reset ]; then
      [ "$(git -C "$WT" rev-parse HEAD)" = "$TARGET" ] || return 1
      grep -q 'which a fresh fetch of its origin cannot prove pushed' "$LAB/$name.out" || return 1
    fi
  fi
  if [ "$name" = dirty-child ]; then [ -f "$WT/ui/keep.txt" ] || return 1; fi
  if [ -f "$LAB/state/$id.meta" ]; then
    sleep 2
    printf 'worker terminal:\n'
    tmux -L fm-lab capture-pane -p -t "primary:fm-$id" -S -120
  fi
  printf 'SCENARIO_RESULT %s pass\n' "$name"
}
for scenario in reset-pin named-reset drifted-pin stale-topic stale-topic-reset live-topic unique-commit mirror-only dirty-child failed-fetch missing-pin uninitialized; do
  run_case "$scenario" || { printf 'SCENARIO_RESULT %s fail\n' "$scenario"; exit 1; }
done
printf '\nLab cleanup: private tmux server only; disposable home and fixture repositories removed on exit.\n'
