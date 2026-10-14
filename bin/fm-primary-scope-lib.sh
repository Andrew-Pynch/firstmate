#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root, whether or not its state dir
# exists yet. A valid secondmate marker force-includes a linked secondmate
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a linked firstmate checkout serving as the code root of
# a separate primary home: FM_HOME names that home explicitly, the home is
# itself a genuine primary root, and this process is not a ship or scout
# worker (bin/fm-spawn.sh marks every worker with FM_TASK_ID). A primary run
# from a linked checkout of its own home's repository is that shape; a task
# worktree carries FM_TASK_ID and names no home, so it stays exempt.
fm_linked_code_root_serves_home() {
  local root=$1 home=${FM_HOME:-} canonical_root canonical_home
  [ -z "${FM_TASK_ID:-}" ] && [ -n "$home" ] || return 1
  [ -f "$root/AGENTS.md" ] && [ -d "$root/bin" ] || return 1
  canonical_root=$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
  canonical_home=$(CDPATH='' cd -P -- "$home" 2>/dev/null && pwd -P) || return 1
  [ "$canonical_root" != "$canonical_home" ] || return 1
  fm_primary_root_matches "$canonical_home"
}

# Return 0 when $1 is a genuine primary root, or a linked code root serving a
# separate primary home, whose effective state dir $2 already exists.
fm_primary_scope_matches() {
  { fm_primary_root_matches "$1" || fm_linked_code_root_serves_home "$1"; } && [ -d "$2" ]
}
