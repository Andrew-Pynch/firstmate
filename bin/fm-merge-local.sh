#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward a
# clean local target branch to the exact fm/<id> task commit.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward. With no target options and
# no recorded selection it preserves the original behavior exactly: it lands in
# the recorded project's default branch checkout and records nothing, so an
# interrupted default attempt never pins the task to a target. An explicit
# override requires both an existing local branch and the linked worktree
# already cleanly checked out on it, and is recorded before the fast-forward so
# a later call and cleanup read the same selection; this command never fetches,
# pushes, switches branches, forces, or discards.
# The task's existing per-task control and metadata locks serialize the
# captain-hold and task-incarnation checks through target provenance recording
# and the fast-forward. A still-held or unreadable row refuses before mutation,
# so approval must be recorded as an `answer --release` first.
# Usage: fm-merge-local.sh <task-id> [--target-branch <branch> --target-worktree <path>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
TARGET_BRANCH_ARG=
TARGET_WORKTREE_ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-branch)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$TARGET_BRANCH_ARG" ] || {
        echo "error: --target-branch requires a single non-empty value" >&2
        exit 2
      }
      TARGET_BRANCH_ARG=$2
      shift 2
      ;;
    --target-worktree)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$TARGET_WORKTREE_ARG" ] || {
        echo "error: --target-worktree requires a single non-empty value" >&2
        exit 2
      }
      TARGET_WORKTREE_ARG=$2
      shift 2
      ;;
    *)
      echo "error: invalid local merge request" >&2
      exit 2
      ;;
  esac
done
if { [ -n "$TARGET_BRANCH_ARG" ] && [ -z "$TARGET_WORKTREE_ARG" ]; } \
   || { [ -z "$TARGET_BRANCH_ARG" ] && [ -n "$TARGET_WORKTREE_ARG" ]; }; then
  echo "error: --target-branch and --target-worktree must be supplied together" >&2
  exit 2
fi
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This precedes reading the task
# record, because the wrong actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
MERGE_META_TMP=
merge_control_cleanup() {
  [ -z "$MERGE_META_TMP" ] || rm -f -- "$MERGE_META_TMP"
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
MERGE_META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$MERGE_META_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(fm_meta_get "$META" project)
TASK_WT=$(fm_meta_get "$META" worktree)
MODE=$(fm_meta_get "$META" mode)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

canonical_dir() {
  [ -d "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

git_common_dir() {
  local path common
  path=$1
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  canonical_dir "$common"
}

worktree_registered() {
  local repo=$1 worktree=$2
  git -C "$repo" worktree list --porcelain 2>/dev/null \
    | grep -Fxq -- "worktree $worktree"
}

record_local_target() {
  local state_device meta_device line
  state_device=$(fm_pr_file_device "$STATE") || return 1
  meta_device=$(fm_pr_file_device "$META") || return 1
  [ "$state_device" = "$meta_device" ] || return 1
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || return 1
  MERGE_META_TMP=$(mktemp "$STATE/.fm-local-target.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      local_target_branch=*|local_target_worktree=*) ;;
      *) printf '%s\n' "$line" >> "$MERGE_META_TMP" || return 1 ;;
    esac
  done < "$META"
  printf 'local_target_branch=%s\nlocal_target_worktree=%s\n' \
    "$TARGET_BRANCH" "$TARGET_WT" >> "$MERGE_META_TMP" || return 1
  chmod 0600 "$MERGE_META_TMP" || return 1
  fm_pr_private_file_valid "$MERGE_META_TMP" 600 "$state_device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || return 1
  mv -f -- "$MERGE_META_TMP" "$META" || return 1
  MERGE_META_TMP=
  [ "$(fm_meta_get "$META" spawn_gen)" = "$MERGE_EXPECTED_SPAWN_GEN" ] \
    && [ "$(fm_meta_get "$META" local_target_branch)" = "$TARGET_BRANCH" ] \
    && [ "$(fm_meta_get "$META" local_target_worktree)" = "$TARGET_WT" ]
}

PROJECT_ROOT=$(canonical_dir "$PROJ") || {
  echo "error: recorded project is not an available working copy: $PROJ" >&2
  exit 1
}
PROJECT_COMMON=$(git_common_dir "$PROJECT_ROOT") || {
  echo "error: recorded project is not a git repository: $PROJECT_ROOT" >&2
  exit 1
}
TASK_WT=$(canonical_dir "$TASK_WT") || {
  echo "error: recorded task worktree is unavailable: $TASK_WT" >&2
  exit 1
}
if [ "$(git_common_dir "$TASK_WT" || true)" != "$PROJECT_COMMON" ] \
   || ! worktree_registered "$PROJECT_ROOT" "$TASK_WT"; then
  echo "error: recorded task worktree is not a linked copy of $PROJECT_ROOT" >&2
  exit 1
fi

BRANCH="fm/$ID"
RECORDED_TARGET_BRANCH=$(fm_meta_get "$META" local_target_branch)
RECORDED_TARGET_WT=$(fm_meta_get "$META" local_target_worktree)
if { [ -n "$RECORDED_TARGET_BRANCH" ] && [ -z "$RECORDED_TARGET_WT" ]; } \
   || { [ -z "$RECORDED_TARGET_BRANCH" ] && [ -n "$RECORDED_TARGET_WT" ]; }; then
  echo "error: task $ID has incomplete local target provenance; refusing" >&2
  exit 1
fi
if [ -n "$RECORDED_TARGET_BRANCH" ]; then
  RECORDED_TARGET_WT=$(canonical_dir "$RECORDED_TARGET_WT") || {
    echo "error: task $ID's recorded local target copy is unavailable: $RECORDED_TARGET_WT" >&2
    exit 1
  }
fi
RECORD_TARGET=0
if [ -n "$TARGET_BRANCH_ARG" ]; then
  RECORD_TARGET=1
  TARGET_WT=$(canonical_dir "$TARGET_WORKTREE_ARG") || {
    echo "error: requested local target copy is unavailable: $TARGET_WORKTREE_ARG" >&2
    exit 1
  }
  TARGET_BRANCH=$TARGET_BRANCH_ARG
  if [ -n "$RECORDED_TARGET_BRANCH" ] \
     && { [ "$RECORDED_TARGET_BRANCH" != "$TARGET_BRANCH" ] \
       || [ "$RECORDED_TARGET_WT" != "$TARGET_WT" ]; }; then
    echo "error: task $ID already records local target $RECORDED_TARGET_BRANCH in $RECORDED_TARGET_WT; refusing a different target" >&2
    exit 1
  fi
elif [ -n "$RECORDED_TARGET_BRANCH" ]; then
  TARGET_BRANCH=$RECORDED_TARGET_BRANCH
  TARGET_WT=$RECORDED_TARGET_WT
else
  TARGET_BRANCH=$(default_branch) || {
    echo "error: cannot determine default branch for $PROJECT_ROOT; expected origin/HEAD, main, or master" >&2
    exit 1
  }
  TARGET_WT=$PROJECT_ROOT
fi

git check-ref-format "refs/heads/$TARGET_BRANCH" >/dev/null 2>&1 || {
  echo "error: invalid local target branch '$TARGET_BRANCH'" >&2
  exit 1
}
if [ "$(git_common_dir "$TARGET_WT" || true)" != "$PROJECT_COMMON" ] \
   || ! worktree_registered "$PROJECT_ROOT" "$TARGET_WT"; then
  echo "error: requested local target $TARGET_WT is not a linked copy of $PROJECT_ROOT" >&2
  exit 1
fi
[ "$TARGET_WT" != "$TASK_WT" ] || {
  echo "error: task worktree cannot also be the local landing target" >&2
  exit 1
}

hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac

TASK_CUR=$(git -C "$TASK_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$TASK_CUR" = "$BRANCH" ] || {
  echo "error: recorded task worktree is on '$TASK_CUR', expected '$BRANCH'; refusing" >&2
  exit 1
}
TASK_OID=$(git -C "$TASK_WT" rev-parse --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) || {
  echo "error: branch $BRANCH does not exist in $PROJECT_ROOT" >&2
  exit 1
}
[ "$(git -C "$TASK_WT" rev-parse --verify HEAD 2>/dev/null || true)" = "$TASK_OID" ] || {
  echo "error: task branch identity changed in $TASK_WT; refusing" >&2
  exit 1
}
TARGET_CUR=$(git -C "$TARGET_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$TARGET_CUR" = "$TARGET_BRANCH" ] || {
  echo "error: $TARGET_WT is on '$TARGET_CUR', expected local target branch '$TARGET_BRANCH'; refusing" >&2
  exit 1
}
TARGET_OID=$(git -C "$TARGET_WT" rev-parse --verify "refs/heads/$TARGET_BRANCH^{commit}" 2>/dev/null) || {
  echo "error: local target branch $TARGET_BRANCH does not exist in $TARGET_WT" >&2
  exit 1
}
[ "$(git -C "$TARGET_WT" rev-parse --verify HEAD 2>/dev/null || true)" = "$TARGET_OID" ] || {
  echo "error: local target branch identity changed in $TARGET_WT; refusing" >&2
  exit 1
}
if [ -n "$(git -C "$TARGET_WT" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $TARGET_WT has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi
if ! git -C "$TARGET_WT" merge-base --is-ancestor "$TARGET_OID" "$TASK_OID"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET_BRANCH (it has diverged)." >&2
  echo "Have the worker rebase $BRANCH onto $TARGET_BRANCH, then retry." >&2
  exit 1
fi

if [ "$RECORD_TARGET" = 1 ]; then
  record_local_target || {
    echo "error: could not record task $ID's authoritative local target; refusing before merge" >&2
    exit 1
  }
  if [ "$(git -C "$TASK_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" != "$BRANCH" ] \
     || [ "$(git -C "$TASK_WT" rev-parse --verify HEAD 2>/dev/null || true)" != "$TASK_OID" ] \
     || [ "$(git -C "$TARGET_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" != "$TARGET_BRANCH" ] \
     || [ "$(git -C "$TARGET_WT" rev-parse --verify HEAD 2>/dev/null || true)" != "$TARGET_OID" ] \
     || [ -n "$(git -C "$TARGET_WT" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "error: task or local target identity changed while recording provenance; refusing" >&2
    exit 1
  fi
fi

before=$(git -C "$TARGET_WT" rev-parse --short "$TARGET_OID")
merge_status=0
git -C "$TARGET_WT" merge --ff-only "$TASK_OID" >/dev/null || merge_status=$?
fm_lock_release "$MERGE_META_LOCK" || true
MERGE_META_LOCK=
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
[ "$(git -C "$TARGET_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$TARGET_BRANCH" ] \
  && [ "$(git -C "$TARGET_WT" rev-parse --verify HEAD 2>/dev/null || true)" = "$TASK_OID" ] || {
    echo "error: local target identity changed during merge; inspect $TARGET_WT before cleanup" >&2
    exit 1
  }
after=$(git -C "$TARGET_WT" rev-parse --short "$TASK_OID")
echo "merged $BRANCH into local $TARGET_BRANCH ($before -> $after) in $TARGET_WT"
