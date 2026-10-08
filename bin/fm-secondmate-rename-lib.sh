#!/usr/bin/env bash
# shellcheck disable=SC2034 # output globals for sourcing callers.
# bin/fm-secondmate-rename-lib.sh - the single owner of the HOME-SIDE half of a
# persistent secondmate id rename.
#
# A rename has two halves and therefore two owners. The parent home's route and
# task records belong to bin/fm-secondmate-rename.sh, which is also the only
# entry point an operator calls. The secondmate HOME's own identity belongs
# here: the validated marker pair, every per-id state record inside the home,
# the stale recorded endpoint, and the optional home-directory move. Both
# callers use this file, so the home half has exactly one implementation:
#   - bin/fm-secondmate-rename.sh, directly, for a LOCAL route;
#   - bin/fm-remote-secondmate-control.sh's `rename` verb (bin/fm-on.sh), for a
#     REMOTE route, so the rewrite happens inside that home's own host.
#
# Nothing here is a hand edit. Every write uses the shape its owner already
# owns: the parent record is parsed by bin/fm-secondmate-parent-lib.sh and
# re-published from those parsed fields, the identity marker is republished
# through the same tmp+mv completion point bin/fm-home-seed.sh uses (and LAST,
# so it stays the seed-completion point), name changes are ordinary renames that
# refuse on a collision, and a dead endpoint is retired through the backend's
# own kill path (bin/fm-backend.sh) so nothing hand-rolls a pane close.
#
# Bounded-token rule: an id is only rewritten where it is delimited by the start
# or end of the name or by one of `.`, `-`, `_`, or `/`. A mate called
# `bertha-pilot` is therefore renamed in `bertha-pilot.meta`,
# `.seen-bertha-pilot_status`, and `remote-reply-bertha-pilot.1.result`, while an
# unrelated task called `pilot-night-linear` or `pilot-assay-ux-01-workspace` is
# never touched.
#
# Globals, all inputs or outputs of fm_secondmate_rename_home:
#   FM_SECONDMATE_RENAME_ENDPOINT  absent | removed | retained
#   FM_SECONDMATE_RENAME_HOME      the home path after the call
#   FM_SECONDMATE_RENAME_MOVED     yes | no
#   FM_SECONDMATE_RENAME_RENAMED   count of renamed home-side records

FM_SECONDMATE_RENAME_ENDPOINT=absent
FM_SECONDMATE_RENAME_HOME=
FM_SECONDMATE_RENAME_MOVED=no
FM_SECONDMATE_RENAME_RENAMED=0

# fm_secondmate_rename_valid_id: the id charset every secondmate surface accepts.
fm_secondmate_rename_valid_id() {  # <id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_secondmate_rename_replace_bounded: print <text> with every BOUNDED
# occurrence of <old> replaced by <new>. A caller detects "nothing changed" by
# comparing the printed value with its input; this function never publishes a
# global, because every call site reads it through command substitution and a
# subshell would silently drop that state.
fm_secondmate_rename_replace_bounded() {  # <text> <old> <new>
  local text=$1 old=$2 new=$3 head before after
  local out='' rest=$text
  if [ -z "$old" ]; then
    printf '%s' "$text"
    return 0
  fi
  while :; do
    head=${rest%%"$old"*}
    if [ "$head" = "$rest" ]; then
      out="$out$rest"
      break
    fi
    before=
    [ -z "$head" ] || before=${head: -1}
    after=${rest:$(( ${#head} + ${#old} )):1}
    case "$before" in
      ''|.|-|_|/|:|'=') ;;
      *) before=bad ;;
    esac
    case "$after" in
      ''|.|-|_|/|:|'=') ;;
      *) after=bad ;;
    esac
    if [ "$before" = bad ] || [ "$after" = bad ]; then
      out="$out$head$old"
    else
      out="$out$head$new"
    fi
    rest=${rest:$(( ${#head} + ${#old} ))}
  done
  printf '%s' "$out"
}

# fm_secondmate_rename_sweep_dir: rename every entry of <dir> whose own name
# carries a bounded occurrence of <old>. A destination that already exists, a
# symlinked entry, and a failed rename each refuse, naming the exact path.
fm_secondmate_rename_sweep_dir() {  # <dir> <old> <new>
  local dir=$1 old=$2 new=$3 entry base planned
  [ -d "$dir" ] || return 0
  dir=${dir%/}
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=$(basename "$entry")
    planned=$(fm_secondmate_rename_replace_bounded "$base" "$old" "$new")
    [ "$planned" != "$base" ] || continue
    if [ -e "$dir/$planned" ] || [ -L "$dir/$planned" ]; then
      printf 'error: refusing to rename %s: destination %s already exists\n' "$entry" "$dir/$planned" >&2
      return 1
    fi
    mv -- "$entry" "$dir/$planned" || {
      printf 'error: could not rename %s\n' "$entry" >&2
      return 1
    }
    FM_SECONDMATE_RENAME_RENAMED=$((FM_SECONDMATE_RENAME_RENAMED + 1))
  done
  return 0
}

# fm_secondmate_rename_herdr_label_present: 0 when a Herdr workspace still
# carries <label> in <session>. The adapter's own CLI wrapper is used directly
# because the label being checked belongs to the OLD id while $FM_HOME still
# names the old home: the adapter's label helper would answer for the home, not
# for the workspace this rename is retiring. A read that cannot be made at all
# reports present, so an unverifiable close is never reported as gone.
fm_secondmate_rename_herdr_label_present() {  # <session> <label>
  local session=$1 label=$2 list found
  command -v jq >/dev/null 2>&1 || return 0
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  found=$(printf '%s' "$list" | jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null | head -1)
  [ -n "$found" ]
}

# fm_secondmate_rename_retire_endpoint: retire one recorded endpoint record.
# A live agent refuses outright. A positively dead endpoint is removed through
# the backend's own kill path, so a pane or workspace cannot keep the old label.
# A missing endpoint needs nothing. An ambiguous, unreadable, or unverified
# verdict removes nothing and reports `retained`, because this layer never
# guesses that an endpoint is gone.
fm_secondmate_rename_retire_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 state
  FM_SECONDMATE_RENAME_ENDPOINT=absent
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  if ! fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null; then
    # An unattributable record is never guessed at and never rewritten: the
    # caller's --stopped attestation already allowed the rename past the gate,
    # and this layer keeps the record in place rather than acting on an endpoint
    # it cannot identify.
    printf 'warning: the endpoint record at %s does not validate as an endpoint for %s; it is left in place\n' "$meta" "$id" >&2
    FM_SECONDMATE_RENAME_ENDPOINT=retained
    return 0
  fi
  state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")
  case "$state" in
    alive)
      printf 'error: the endpoint recorded at %s still reports a live agent; stop it before renaming\n' "$meta" >&2
      return 1
      ;;
    dead)
      if fm_backend_kill "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"; then
        FM_SECONDMATE_RENAME_ENDPOINT=removed
        if [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] \
          && fm_secondmate_rename_herdr_label_present "${FM_BACKEND_VALIDATED_TARGET%%:*}" "2ndmate-$id"; then
          printf 'warning: Herdr workspace %s still exists in session %s after its endpoint was closed; remove it so nothing keeps the old name\n' \
            "2ndmate-$id" "${FM_BACKEND_VALIDATED_TARGET%%:*}" >&2
          FM_SECONDMATE_RENAME_ENDPOINT=retained
        fi
      else
        printf 'warning: the recorded endpoint at %s could not be removed through the %s backend; it is left in place\n' \
          "$meta" "$FM_BACKEND_VALIDATED_BACKEND" >&2
        FM_SECONDMATE_RENAME_ENDPOINT=retained
      fi
      ;;
    missing) ;;
    *)
      printf 'warning: the recorded endpoint at %s reports %s; it is left in place\n' "$meta" "$state" >&2
      FM_SECONDMATE_RENAME_ENDPOINT=retained
      ;;
  esac
  return 0
}

# fm_secondmate_rename_live_children: print one line per child worker endpoint in
# <home> that still reports a live agent. A home carrying live child work must
# not be moved out from under those panes.
fm_secondmate_rename_live_children() {  # <home>
  local home=$1 meta id state
  for meta in "$home"/state/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || id=$(basename "$meta" .meta)
    fm_secondmate_rename_valid_id "$id" || continue
    fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null || continue
    state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")
    [ "$state" = alive ] || continue
    printf '%s\n' "$meta"
  done
  return 0
}

# fm_secondmate_rename_rewrite_meta_refs: rewrite the two references a home's
# own endpoint metadata carries - the absolute home path it points at, and the
# id it is bound to (`endpoint_task_id`, and any window or task-tmp value that
# embeds the id) - inside each named file, atomically. Every other byte is
# preserved, because every other field belongs to another owner. Files that need
# neither replacement are left untouched.
fm_secondmate_rename_rewrite_meta_refs() {  # <old-path> <new-path> <old-id> <new-id> <file>...
  local old_path=$1 new_path=$2 old_id=$3 new_id=$4 file line changed=0
  shift 4
  for file in "$@"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    changed=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *"$old_path"*)
          line=${line//"$old_path"/"$new_path"}
          changed=1
          ;;
      esac
      case "$line" in
        *"$old_id"*)
          line=${line//"$old_id"/"$new_id"}
          changed=1
          ;;
      esac
      printf '%s\n' "$line"
    done < "$file" > "$file.fm-rename.$$" || return 1
    if [ "$changed" -eq 1 ]; then
      mv -f -- "$file.fm-rename.$$" "$file" || return 1
    else
      rm -f -- "$file.fm-rename.$$"
    fi
  done
  return 0
}

# fm_secondmate_rename_home: rewrite one secondmate home from <old> to <new>.
# Validates the identity pair first, renames the home's per-id state records,
# optionally moves the home directory to its machine-named path, rewrites the
# home paths its own worker records carry, and publishes the parent record and
# then the identity marker. Sets FM_SECONDMATE_RENAME_HOME and
# FM_SECONDMATE_RENAME_MOVED.
fm_secondmate_rename_home() {  # <old-id> <new-id> <home> <keep-path: yes|no>
  local old=$1 new=$2 home=$3 keep=$4
  local marker parent_record route parent_home parent_host base planned dest file
  local -a move_paths=()

  fm_secondmate_rename_valid_id "$old" || { printf 'error: invalid secondmate id: %s\n' "$old" >&2; return 1; }
  fm_secondmate_rename_valid_id "$new" || { printf 'error: invalid secondmate id: %s\n' "$new" >&2; return 1; }
  [ "$old" != "$new" ] || { printf 'error: renaming %s to itself is not a rename\n' "$old" >&2; return 1; }
  [ -d "$home" ] && [ ! -L "$home" ] || {
    printf 'error: secondmate home is unavailable or unsafe: %s\n' "$home" >&2
    return 1
  }
  home=$(cd "$home" && pwd -P) || return 1
  marker="$home/.fm-secondmate-home"
  parent_record="$home/.fm-secondmate-parent"
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    printf 'error: secondmate identity marker is missing or unsafe: %s\n' "$marker" >&2
    return 1
  }
  [ "$(cat "$marker")" = "$old" ] || {
    printf 'error: secondmate home %s is marked for %s, not %s\n' "$home" "$(cat "$marker")" "$old" >&2
    return 1
  }
  fm_secondmate_parent_record_parse "$parent_record" || {
    printf 'error: secondmate parent record is missing, unsafe, or invalid: %s\n' "$parent_record" >&2
    return 1
  }
  route=$FM_SECONDMATE_PARENT_ROUTE
  parent_home=$FM_SECONDMATE_PARENT_HOME
  parent_host=$FM_SECONDMATE_PARENT_HOST

  FM_SECONDMATE_RENAME_HOME=$home
  FM_SECONDMATE_RENAME_MOVED=no
  FM_SECONDMATE_RENAME_RENAMED=0

  base=$(basename "$home")
  planned=$(fm_secondmate_rename_replace_bounded "$base" "$old" "$new")
  if [ "$keep" = yes ] || [ "$planned" = "$base" ]; then
    dest=$home
  else
    dest="$(dirname "$home")/$planned"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      printf 'error: refusing to move the home to %s: that path already exists\n' "$dest" >&2
      return 1
    fi
    if [ -f "$home/.git" ]; then
      printf 'error: refusing to move the linked worktree at %s: a treehouse-leased home must be re-seeded at its new name instead, or rerun with --keep-home-path to rename the identity only\n' "$home" >&2
      return 1
    fi
    if [ ! -w "$(dirname "$home")" ]; then
      printf 'error: refusing to move the home to %s: %s is not writable\n' "$dest" "$(dirname "$home")" >&2
      return 1
    fi
  fi

  if [ "$dest" != "$home" ]; then
    local live
    live=$(fm_secondmate_rename_live_children "$home")
    if [ -n "$live" ]; then
      printf 'error: refusing to move the home to %s: these child work records still report a live agent\n' "$dest" >&2
      printf 'error: %s\n' "$live" >&2
      return 1
    fi
  fi

  fm_secondmate_rename_sweep_dir "$home/state" "$old" "$new" || return 1
  fm_secondmate_rename_sweep_dir "$home/state/parent-route" "$old" "$new" || return 1

  if [ "$dest" != "$home" ]; then
    mv -- "$home" "$dest" || {
      printf 'error: could not move the secondmate home to %s\n' "$dest" >&2
      return 1
    }
    FM_SECONDMATE_RENAME_MOVED=yes
  fi

  for file in "$dest"/state/*.meta "$dest"/state/parent-route/*.meta; do
    [ -e "$file" ] || continue
    move_paths+=("$file")
  done
  if [ "${#move_paths[@]}" -gt 0 ]; then
    fm_secondmate_rename_rewrite_meta_refs "$home" "$dest" "$old" "$new" "${move_paths[@]}" || return 1
  fi
  if [ "$FM_SECONDMATE_RENAME_MOVED" = yes ]; then
    FM_SECONDMATE_RENAME_HOME=$dest
  fi

  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=%s\n' "$route"
    case "$route" in
      local) printf 'parent_home=%s\n' "$parent_home" ;;
      remote) [ -z "$parent_host" ] || printf 'parent_host=%s\n' "$parent_host" ;;
    esac
  } > "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-parent.tmp.$$" || return 1
  mv -f -- "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-parent.tmp.$$" \
    "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-parent" || return 1
  printf '%s\n' "$new" > "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-home.tmp.$$" || return 1
  mv -f -- "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-home.tmp.$$" \
    "$FM_SECONDMATE_RENAME_HOME/.fm-secondmate-home" || return 1

  # The moved home's published summary ledger carries its absolute home path.
  # Republish it through its own producer, best effort: the ledger is a derived
  # document and its producer owns the format, so this never hand-writes it, and
  # a home from an older code root simply keeps the ledger its own watcher will
  # refresh on its next interval.
  if [ "$FM_SECONDMATE_RENAME_MOVED" = yes ] \
    && [ -x "$FM_SECONDMATE_RENAME_HOME/bin/fm-home-summary-refresh.sh" ]; then
    FM_HOME="$FM_SECONDMATE_RENAME_HOME" FM_ROOT_OVERRIDE="$FM_SECONDMATE_RENAME_HOME" \
      FM_STATE_OVERRIDE="$FM_SECONDMATE_RENAME_HOME/state" \
      FM_DATA_OVERRIDE="$FM_SECONDMATE_RENAME_HOME/data" \
      FM_PROJECTS_OVERRIDE="$FM_SECONDMATE_RENAME_HOME/projects" \
      "$FM_SECONDMATE_RENAME_HOME/bin/fm-home-summary-refresh.sh" --best-effort >/dev/null 2>&1 || true
  fi
  return 0
}
