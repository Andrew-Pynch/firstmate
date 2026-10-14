#!/usr/bin/env bash
# fm-home-binding-lib.sh - which Firstmate home a launched process serves
# (one owner of the resolution order, the code root's served-homes record, the
# per-process resolution record, and the session-start comparison line).
#
# Sourced by bin/fm-session-start.sh and bin/fm-watcher-down.sh, and executed by
# the omp primary extensions (.pi/extensions/lib/fm-home-binding.ts), so a TS
# caller and a shell caller can never resolve the same inputs differently.
# docs/configuration.md "Home binding" owns the operator-facing contract.
#
# WHY THIS EXISTS. Several homes can share one code root (a primary's code root
# that is not its home, and secondmate homes that run the same scripts), and a
# harness restore can relaunch a primary with its working directory but none of
# its environment (Herdr's resume_agents_on_restore reruns `omp --resume=<file>`
# in the pane's cwd). A process that then falls back to "the code root is the
# home" silently serves the wrong state directory. So the home is bound to the
# harness SESSION that was launched for it, and a launch that names no home is
# refused whenever the code root is known to serve another one.
#
# RESOLUTION ORDER (fm_home_binding_resolve <code-root> <recorded> <primary-only>):
#   1. FM_HOME (explicit environment)           source=env
#   2. FM_ROOT_OVERRIDE (test/relocation seam)  source=override
#   3. <recorded>: the home the harness session recorded when it was launched
#      with an explicit FM_HOME (omp: the session's "firstmate-home" custom
#      entry, read back on resume)                source=session
#   4. the code root itself                      source=code-root
# Step 4 is refused when the code root's served-homes record names any other
# existing home: that launch is ambiguous, and no shared default may choose.
# With <primary-only>=1 (the extensions), step 4 on a code root that is not a
# primary checkout (bin/fm-primary-scope-lib.sh, so a linked task worktree) is
# "ineligible": the extension stands down silently, as every primary hook does
# inside a child worktree. An explicit FM_HOME is taken exactly as every shell
# script takes it (a relative one anchored to the caller's working directory);
# a recorded home that no longer exists is refused, never replaced by a
# fallback.
# Results: FM_HOME_BINDING_STATUS=ok|ineligible|refused, FM_HOME_BINDING_HOME,
# FM_HOME_BINDING_SOURCE, FM_HOME_BINDING_MESSAGE.
#
# SERVED-HOMES RECORD (<code-root>/state/.code-root-served-homes). One absolute
# home path per line, appended by fm_home_binding_note_served whenever a
# process on a primary code root resolves an explicit FM_HOME other than the
# code root (the omp extension at launch, bin/fm-session-start.sh when it holds
# the lock), under state/.code-root-served-homes.lock for the whole
# read-modify-write. Entries whose directory no longer exists are ignored;
# `forget` removes one deliberately.
#
# PER-PROCESS RECORD (<runtime-dir>/<pid>, runtime dir
# ${FM_HOME_BINDING_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/firstmate-home-binding-<uid>}).
# The extension's resolution for harness process <pid>, keyed by that
# process's identity (fm_pid_identity) so a reused pid never vouches for a new
# process. Lines: identity=, status=, home=, source=, state=, message=.
#
# SESSION-START LINES (fm_home_binding_report <shell-home> <shell-state> <pid>).
# Prints one fact line, then one actionable line per disagreement:
#   "BOOTSTRAP_INFO: home binding: session start FM_HOME=<h> state=<s>; harness pid <p> launch env FM_HOME=<v|unset> FM_STATE_OVERRIDE=<v|unset>; extension <resolved <state> (source=<src>)|refused|no record>"
#   "HOME_MISMATCH: <what disagrees>; <remedy>"
# A HOME_MISMATCH line names both state directories. The launch environment is
# read from /proc/<pid>/environ (only FM_HOME and FM_STATE_OVERRIDE are
# extracted; no other value is ever printed) and reads `unreadable` where /proc
# is unavailable. No harness pid prints nothing.
#
# CLI (exit 0 ok, 3 ineligible, 4 refused, 2 usage):
#   fm-home-binding-lib.sh resolve [--code-root DIR] [--recorded HOME]
#                                  [--primary-only] [--record-pid PID]
#     Prints status=, home=, source=, message= lines. --record-pid writes the
#     per-process record for PID and, for an explicit FM_HOME on a primary
#     code root, notes that home as served.
#   fm-home-binding-lib.sh note-served|forget [--code-root DIR] HOME
#   fm-home-binding-lib.sh served [--code-root DIR]
#   fm-home-binding-lib.sh report --pid PID [--home HOME] [--state DIR]
# The default code root is this file's own repository root.

FM_HOME_BINDING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$FM_HOME_BINDING_LIB_DIR/fm-primary-scope-lib.sh"

FM_HOME_BINDING_STATUS=
FM_HOME_BINDING_HOME=
FM_HOME_BINDING_SOURCE=
FM_HOME_BINDING_MESSAGE=

# Print the physical path of existing directory $1, or $1 unchanged.
fm_home_binding_canonical() {
  local dir=$1 resolved
  resolved=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P) || resolved=
  printf '%s\n' "${resolved:-$dir}"
}

fm_home_binding_is_home_dir() {  # <path>: absolute existing directory
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ]
}

fm_home_binding_served_file() {  # <code-root>
  printf '%s/state/.code-root-served-homes\n' "$1"
}

# Print each existing home in <code-root>'s served record other than the code
# root itself, one per line.
fm_home_binding_served_others() {  # <code-root>
  local root file line canonical_root
  root=$1
  file=$(fm_home_binding_served_file "$root")
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  canonical_root=$(fm_home_binding_canonical "$root")
  while IFS= read -r line || [ -n "$line" ]; do
    fm_home_binding_is_home_dir "$line" || continue
    [ "$(fm_home_binding_canonical "$line")" = "$canonical_root" ] && continue
    printf '%s\n' "$line"
  done < "$file"
}

# Rewrite <code-root>'s served record atomically with <home> added (add) or
# removed (forget), holding the record's lock for the whole read-modify-write
# so two homes starting from one code root never drop each other's entry.
# Returns 1 when the lock or the record cannot be taken or written.
fm_home_binding_served_edit() {  # <add|forget> <code-root> <home>
  local lock="$2/state/.code-root-served-homes.lock" attempt=0 rc
  mkdir -p "$2/state" 2>/dev/null || return 1
  fm_home_binding_load_wake_lib || return 1
  while ! fm_lock_try_acquire "$lock"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || return 1
    sleep 0.05
  done
  fm_home_binding_served_edit_locked "$@"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

fm_home_binding_served_edit_locked() {  # <add|forget> <code-root> <home>
  local action=$1 root=$2 home=$3 file tmp line canonical found=0
  file=$(fm_home_binding_served_file "$root")
  [ ! -L "$file" ] || return 1
  canonical=$(fm_home_binding_canonical "$home")
  if [ "$action" = add ] && [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$(fm_home_binding_canonical "$line")" = "$canonical" ] && return 0
    done < "$file"
  fi
  [ "$action" = forget ] && [ ! -f "$file" ] && return 0
  tmp=$(mktemp "$root/state/.code-root-served-homes.XXXXXX" 2>/dev/null) || return 1
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if [ "$(fm_home_binding_canonical "$line")" = "$canonical" ]; then
        found=1
        continue
      fi
      printf '%s\n' "$line"
    done < "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  [ "$action" = add ] && printf '%s\n' "$canonical" >> "$tmp"
  if [ "$action" = forget ] && [ "$found" -eq 0 ]; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Note <home> as served from <code-root> when the code root is a primary
# checkout and <home> is not the code root itself. A linked task worktree is
# never noted, so a test or worker run never turns its checkout ambiguous.
fm_home_binding_note_served() {  # <code-root> <home>
  local root=$1 home=$2
  fm_home_binding_is_home_dir "$home" || return 0
  fm_primary_root_matches "$root" || return 0
  [ "$(fm_home_binding_canonical "$home")" = "$(fm_home_binding_canonical "$root")" ] && return 0
  fm_home_binding_served_edit add "$root" "$home"
}

fm_home_binding_set() {  # <status> <home> <source> <message>
  FM_HOME_BINDING_STATUS=$1
  FM_HOME_BINDING_HOME=$2
  FM_HOME_BINDING_SOURCE=$3
  FM_HOME_BINDING_MESSAGE=$4
}

fm_home_binding_resolve() {  # <code-root> <recorded-home> <primary-only 0|1>
  local root=$1 recorded=$2 primary_only=${3:-0} others list
  if [ -n "${FM_HOME:-}" ]; then
    # An explicit home is taken as every shell script takes it; a relative one
    # is anchored to the caller's working directory, never validated away.
    case "$FM_HOME" in
      /*) fm_home_binding_set ok "$FM_HOME" env "" ;;
      *) fm_home_binding_set ok "$PWD/$FM_HOME" env "" ;;
    esac
    return 0
  fi
  if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
    fm_home_binding_set ok "$FM_ROOT_OVERRIDE" override ""
    return 0
  fi
  if [ -n "$recorded" ]; then
    if fm_home_binding_is_home_dir "$recorded"; then
      fm_home_binding_set ok "$recorded" session ""
    else
      fm_home_binding_set refused "" "" "this harness session was launched for Firstmate home '$recorded', which no longer exists; relaunch it with FM_HOME=<home>"
    fi
    return 0
  fi
  if [ "$primary_only" = 1 ] && ! fm_primary_root_matches "$root"; then
    fm_home_binding_set ineligible "" "" "code root $root is not a primary Firstmate checkout and this process names no home"
    return 0
  fi
  others=$(fm_home_binding_served_others "$root")
  if [ -n "$others" ]; then
    list=$(printf '%s\n' "$others" | paste -sd ',' - | sed 's/,/, /g')
    fm_home_binding_set refused "" "" "FM_HOME is unset and this harness session recorded no home, but code root $root also serves $list, so falling back to $root/state is ambiguous; relaunch with FM_HOME=<home> (for omp: FM_HOME=<home> omp --resume=<session>)"
    return 0
  fi
  fm_home_binding_set ok "$root" code-root ""
}

fm_home_binding_runtime_dir() {
  printf '%s\n' "${FM_HOME_BINDING_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/firstmate-home-binding-$(id -u)}"
}

fm_home_binding_load_wake_lib() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_HOME_BINDING_LIB_DIR/fm-wake-lib.sh"
}

fm_home_binding_identity() {  # <pid>
  fm_home_binding_load_wake_lib || return 1
  fm_pid_identity "$1"
}

# Write the per-process record for <pid> from the current FM_HOME_BINDING_*
# result. Best-effort: a record that cannot be written only leaves session
# start without the extension's view, which it reports as "no record".
fm_home_binding_record() {  # <pid>
  local pid=$1 dir identity tmp state=
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(fm_home_binding_identity "$pid") || return 1
  dir=$(fm_home_binding_runtime_dir)
  mkdir -p "$dir" 2>/dev/null && [ -O "$dir" ] && [ ! -L "$dir" ] && chmod 700 "$dir" 2>/dev/null || return 1
  [ "$FM_HOME_BINDING_STATUS" = ok ] && state=${FM_STATE_OVERRIDE:-$FM_HOME_BINDING_HOME/state}
  tmp=$(mktemp "$dir/.$pid.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'identity=%s\nstatus=%s\nhome=%s\nsource=%s\nstate=%s\nmessage=%s\n' \
    "$identity" "$FM_HOME_BINDING_STATUS" "$FM_HOME_BINDING_HOME" "$FM_HOME_BINDING_SOURCE" \
    "$state" "$FM_HOME_BINDING_MESSAGE" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$pid" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

fm_home_binding_record_field() {  # <record-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'
}

# Print the value of <name> from <pid>'s launch environment, `unset` when it is
# absent, or return 1 when the environment cannot be read. Only the named
# variable is ever extracted.
fm_home_binding_launch_env() {  # <pid> <name>
  local pid=$1 name=$2 environ=${FM_PROC_ROOT_OVERRIDE:-/proc}/$1/environ value
  [ -r "$environ" ] || return 1
  value=$(tr '\0' '\n' < "$environ" 2>/dev/null | sed -n "s/^$name=//p" | sed -n '1p') || return 1
  printf '%s\n' "${value:-unset}"
}

fm_home_binding_report() {  # <shell-home> <shell-state> <harness-pid>
  local home=$1 state=$2 pid=$3 record env_home env_state ext_status ext_state ext_source ext_message
  local identity canon_state remedy ext_desc
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  canon_state=$(fm_home_binding_canonical "$state")
  env_home=$(fm_home_binding_launch_env "$pid" FM_HOME) || env_home=unreadable
  env_state=$(fm_home_binding_launch_env "$pid" FM_STATE_OVERRIDE) || env_state=unreadable
  record="$(fm_home_binding_runtime_dir)/$pid"
  ext_status=
  if [ -f "$record" ] && [ ! -L "$record" ] && [ -O "$record" ] && identity=$(fm_home_binding_identity "$pid") \
    && [ "$(fm_home_binding_record_field "$record" identity)" = "$identity" ]; then
    ext_status=$(fm_home_binding_record_field "$record" status)
    ext_state=$(fm_home_binding_record_field "$record" state)
    ext_source=$(fm_home_binding_record_field "$record" source)
    ext_message=$(fm_home_binding_record_field "$record" message)
  fi
  case "$ext_status" in
    ok) ext_desc="resolved $ext_state (source=$ext_source)" ;;
    refused) ext_desc="refused to bind a home" ;;
    ineligible) ext_desc="stood down (not a primary checkout)" ;;
    *) ext_desc="no record" ;;
  esac
  printf 'BOOTSTRAP_INFO: home binding: session start FM_HOME=%s state=%s; harness pid %s launch env FM_HOME=%s FM_STATE_OVERRIDE=%s; extension %s\n' \
    "$home" "$state" "$pid" "$env_home" "$env_state" "$ext_desc"
  remedy="relaunch the harness with FM_HOME=$home (omp: FM_HOME=$home omp --resume=<session>), or rerun bin/fm-session-start.sh with the FM_HOME the harness serves if that is the intended home"
  if [ "$ext_status" = ok ] && [ "$(fm_home_binding_canonical "$ext_state")" != "$canon_state" ]; then
    printf 'HOME_MISMATCH: the harness extensions in pid %s act on %s but this session start acted on %s; %s\n' \
      "$pid" "$ext_state" "$state" "$remedy"
  elif [ "$ext_status" = refused ]; then
    printf 'HOME_MISMATCH: the harness extensions in pid %s refused to act on any home (%s), so nothing watches %s; %s\n' \
      "$pid" "$ext_message" "$state" "$remedy"
  fi
  case "$env_home" in
    unset|unreadable) ;;
    *)
      if [ "$(fm_home_binding_canonical "$env_home")" != "$(fm_home_binding_canonical "$home")" ]; then
        printf 'HOME_MISMATCH: harness pid %s was launched with FM_HOME=%s, so its hooks act on %s/state, but this session start acted on %s; %s\n' \
          "$pid" "$env_home" "$env_home" "$state" "$remedy"
      fi
      ;;
  esac
  case "$env_state" in
    unset|unreadable) ;;
    *)
      if [ "$(fm_home_binding_canonical "$env_state")" != "$canon_state" ]; then
        printf 'HOME_MISMATCH: harness pid %s was launched with FM_STATE_OVERRIDE=%s but this session start acted on %s; %s\n' \
          "$pid" "$env_state" "$state" "$remedy"
      fi
      ;;
  esac
}

fm_home_binding_usage() {
  cat >&2 <<'EOF'
usage: fm-home-binding-lib.sh resolve [--code-root DIR] [--recorded HOME] [--primary-only] [--record-pid PID]
       fm-home-binding-lib.sh note-served|forget [--code-root DIR] HOME
       fm-home-binding-lib.sh served [--code-root DIR]
       fm-home-binding-lib.sh report --pid PID [--home HOME] [--state DIR]
EOF
  exit 2
}

fm_home_binding_main() {
  local command=${1:-} root recorded='' primary_only=0 record_pid='' pid='' home='' state='' rc
  root=$(cd "$FM_HOME_BINDING_LIB_DIR/.." && pwd)
  [ "$#" -gt 0 ] || fm_home_binding_usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --code-root) [ "$#" -ge 2 ] || fm_home_binding_usage; root=$2; shift 2 ;;
      --recorded) [ "$#" -ge 2 ] || fm_home_binding_usage; recorded=$2; shift 2 ;;
      --primary-only) primary_only=1; shift ;;
      --record-pid) [ "$#" -ge 2 ] || fm_home_binding_usage; record_pid=$2; shift 2 ;;
      --pid) [ "$#" -ge 2 ] || fm_home_binding_usage; pid=$2; shift 2 ;;
      --home) [ "$#" -ge 2 ] || fm_home_binding_usage; home=$2; shift 2 ;;
      --state) [ "$#" -ge 2 ] || fm_home_binding_usage; state=$2; shift 2 ;;
      -*) fm_home_binding_usage ;;
      *) break ;;
    esac
  done
  case "$command" in
    resolve)
      [ "$#" -eq 0 ] || fm_home_binding_usage
      fm_home_binding_resolve "$root" "$recorded" "$primary_only"
      if [ -n "$record_pid" ]; then
        fm_home_binding_record "$record_pid" || true
        if [ "$FM_HOME_BINDING_SOURCE" = env ]; then
          fm_home_binding_note_served "$root" "$FM_HOME_BINDING_HOME" || true
        fi
      fi
      printf 'status=%s\nhome=%s\nsource=%s\nmessage=%s\n' "$FM_HOME_BINDING_STATUS" \
        "$FM_HOME_BINDING_HOME" "$FM_HOME_BINDING_SOURCE" "$FM_HOME_BINDING_MESSAGE"
      case "$FM_HOME_BINDING_STATUS" in
        ok) return 0 ;;
        ineligible) return 3 ;;
        *) return 4 ;;
      esac
      ;;
    note-served|forget)
      [ "$#" -eq 1 ] || fm_home_binding_usage
      fm_home_binding_is_home_dir "$1" || { echo "fm-home-binding: '$1' is not an existing absolute directory" >&2; return 1; }
      if [ "$command" = forget ]; then
        fm_home_binding_served_edit forget "$root" "$1"
      else
        fm_home_binding_note_served "$root" "$1"
      fi
      rc=$?
      [ "$rc" -eq 0 ] || echo "fm-home-binding: could not update $(fm_home_binding_served_file "$root")" >&2
      return "$rc"
      ;;
    served)
      [ "$#" -eq 0 ] || fm_home_binding_usage
      fm_home_binding_served_others "$root"
      ;;
    report)
      [ "$#" -eq 0 ] && [ -n "$pid" ] || fm_home_binding_usage
      home=${home:-${FM_HOME:-$root}}
      state=${state:-${FM_STATE_OVERRIDE:-$home/state}}
      fm_home_binding_report "$home" "$state" "$pid"
      ;;
    *) fm_home_binding_usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_home_binding_main "$@"
  exit
fi
