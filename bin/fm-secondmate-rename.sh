#!/usr/bin/env bash
# fm-secondmate-rename.sh - one supported rename of a persistent second mate's id.
#
# Usage:
#   fm-secondmate-rename.sh <old-id> <new-id> [--stopped] [--keep-home-path]
#
#   Rename the persistent second mate <old-id> to <new-id> through supported
#   paths only: nothing here hand-edits a marker, a registry line, or a home.
#   The parent half owns the registry route, the parent task records, and the
#   remote reply channel; the home half (markers, the home's own per-id state
#   records, the stale endpoint, and the optional home-directory move) is owned
#   by bin/fm-secondmate-rename-lib.sh and runs directly for a LOCAL route, or
#   inside that home's own host through
#   "bin/fm-on.sh <old-id> fm-remote-secondmate-control.sh rename" for a REMOTE
#   route.
#
#   A rename is only safe while the mate is stopped: a live agent keeps its old
#   id in its own runtime, its endpoint label, and its steering inbox. The
#   helper therefore reads the recorded endpoint and refuses while it reports a
#   live agent, whatever the caller passes. --stopped is the caller's proof for
#   the case the helper cannot verify from here (a remote host that is
#   unreachable, so the endpoint verdict is unknown); it never overrides a
#   positively live endpoint. Stop the mate first, through the control plane
#   that owns that placement:
#     local:  bin/fm-control.sh <old-id> exit
#     remote: bin/fm-on.sh <old-id> fm-remote-secondmate-control.sh exit <old-id>
#
#   The home directory moves to the machine-named path whenever its final path
#   component still carries the old id (fm-homes/bertha-pilot -> fm-homes/bertha)
#   so no live record keeps the old name. --keep-home-path renames the identity
#   only and leaves the path alone; a linked worktree (a treehouse-leased home)
#   is never moved and refuses without that flag.
#
#   Ordering, and what a partial failure leaves behind:
#     1. read-only preflight: ids, registry route, marker identity, endpoint
#        verdict, home-move safety, and every record this helper will not rewrite
#        (an unsettled pending reply, a decision binding, a reconcile request)
#        refuse here, before anything changes;
#     2. the remote reply source is retired (bin/fm-procevent-remote-reply.sh,
#        which itself refuses while a captured result is unhandled);
#     3. its cursor, receipts, and captures move to the new source id;
#     4. the home half runs (markers, home state records, endpoint, home move);
#     5. the parent records move (state/*, data/<id>, the parent task record);
#     6. the registry line is rewritten atomically;
#     7. the reply source is re-armed under the new id.
#   A failure between 2 and 7 leaves the mate renamed only up to that point and
#   reports the exact step; the reply channel is re-armed with
#   "bin/fm-procevent-remote-reply.sh arm <id>" for whichever id the registry
#   then names.
#
#   The rename retires the stopped endpoint, so the mate comes back through the
#   ordinary recovery respawn rather than a relaunch:
#     bin/fm-spawn.sh <new-id> --secondmate
#   which re-resolves its harness and profile from current config exactly like
#   any other respawn.
#
#   The helper prints one schema=fm-secondmate-rename.v1 block:
#     old_id= / new_id= / home= / moved= / endpoint= / reply_source= / respawn=
#   It exits non-zero, naming every path it found still carrying the old id,
#   when a survivor remains that it does not own.
#   The registry summary and scope text are the mate's own charter prose and are
#   left as written: they describe the duties the mate still has, so a charter
#   that names the Pilot project keeps naming it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; a secondmate rename refuses to resolve a home implicitly" >&2
  exit 1
fi
FM_HOME=$(cd "$FM_HOME" && pwd -P)
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-rename-lib.sh
. "$SCRIPT_DIR/fm-secondmate-rename-lib.sh"

OLD=
NEW=
STOPPED=0
KEEP_PATH=no
ROUTE_REMOTE=0
ROUTE_HOME=
ROUTE_HOST=
ROUTE_ROOT=
OLD_HOME=
NEW_HOME=
MOVE_STATE=no
ENDPOINT_STATE=absent
REPLY_SOURCE=absent
LOCK=
LOCK_HELD=0

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

cleanup() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --stopped) STOPPED=1 ;;
      --keep-home-path) KEEP_PATH=yes ;;
      -h|--help) usage 0 ;;
      -*)
        printf 'error: unknown option: %s\n' "$arg" >&2
        usage
        ;;
      *)
        if [ -z "$OLD" ]; then
          OLD=$arg
        elif [ -z "$NEW" ]; then
          NEW=$arg
        else
          printf 'error: unexpected argument: %s\n' "$arg" >&2
          usage
        fi
        ;;
    esac
  done
  [ -n "$OLD" ] && [ -n "$NEW" ] || usage
  fm_secondmate_rename_valid_id "$OLD" || die "invalid secondmate id: $OLD"
  fm_secondmate_rename_valid_id "$NEW" || die "invalid secondmate id: $NEW"
  [ "$OLD" != "$NEW" ] || die "renaming $OLD to itself is not a rename"
}

maybe_stop_command() {
  if [ "$ROUTE_REMOTE" -eq 1 ]; then
    printf 'bin/fm-on.sh %s fm-remote-secondmate-control.sh exit %s' "$OLD" "$OLD"
  else
    printf 'bin/fm-control.sh %s exit' "$OLD"
  fi
}

load_route() {
  secondmate_registry_line_for_id "$REG" "$OLD" || die "no parseable registry route for secondmate $OLD in $REG"
  ROUTE_REMOTE=$SECONDMATE_REGISTRY_REMOTE
  ROUTE_HOME=$SECONDMATE_REGISTRY_HOME
  ROUTE_HOST=$SECONDMATE_REGISTRY_HOST
  ROUTE_ROOT=$SECONDMATE_REGISTRY_ROOT
  if secondmate_registry_line_for_id "$REG" "$NEW" 2>/dev/null; then
    die "secondmate $NEW is already registered at $SECONDMATE_REGISTRY_HOME"
  fi
  [ -n "$ROUTE_HOME" ] || die "registry route for $OLD records no home"
  OLD_HOME=$ROUTE_HOME
  NEW_HOME=$ROUTE_HOME
}

preflight_registry() {
  mkdir -p "$STATE" || die "could not create the state directory $STATE"
  LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$LOCK" || die "the secondmate registry could not be locked"
  LOCK_HELD=1
  secondmate_registry_validate_bindings "$REG" secondmate_registry_path_key \
    || die "${SECONDMATE_REGISTRY_ERROR:-secondmate registry is invalid}"
}

preflight_local_identity() {
  local marker parent_record
  [ "$ROUTE_REMOTE" -eq 0 ] || return 0
  [ -d "$OLD_HOME" ] && [ ! -L "$OLD_HOME" ] || die "secondmate home is unavailable or unsafe: $OLD_HOME"
  OLD_HOME=$(cd "$OLD_HOME" && pwd -P) || die "secondmate home could not be resolved: $ROUTE_HOME"
  NEW_HOME=$OLD_HOME
  marker="$OLD_HOME/.fm-secondmate-home"
  parent_record="$OLD_HOME/.fm-secondmate-parent"
  [ -f "$marker" ] && [ ! -L "$marker" ] || die "secondmate identity marker is missing or unsafe: $marker"
  [ "$(cat "$marker")" = "$OLD" ] || die "home $OLD_HOME is marked for $(cat "$marker"), not $OLD"
  fm_secondmate_parent_record_parse "$parent_record" || die "secondmate parent record is missing, unsafe, or invalid: $parent_record"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die "secondmate $OLD is registered as a local route but its home records a ${FM_SECONDMATE_PARENT_ROUTE} parent"
  [ "$FM_SECONDMATE_PARENT_HOME" = "$FM_HOME" ] \
    || die "secondmate parent record names $FM_SECONDMATE_PARENT_HOME, not this home $FM_HOME"
}

remote_verb_probe() {
  local out rc=0
  [ "$ROUTE_REMOTE" -eq 1 ] || return 0
  out=$("$SCRIPT_DIR/fm-on.sh" "$OLD" fm-remote-secondmate-control.sh rename </dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 255 ]; then
    printf 'error: host %s could not be reached to confirm the rename helper is available; the route is preserved\n' "$ROUTE_HOST" >&2
    exit 1
  fi
  # The host's own usage text is the readiness proof: an un-updated code root
  # answers "unknown command" instead, and the rename must not begin a mutation
  # it cannot finish on that host.
  case "$out" in
    *"fm-remote-secondmate-control.sh rename <old-id> <new-id>"*) return 0 ;;
  esac
  printf 'error: the Firstmate code root on %s (%s) does not carry the rename verb yet; update that host, then retry\n' \
    "$ROUTE_HOST" "$ROUTE_ROOT" >&2
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  exit 1
}

endpoint_verdict() {
  local out rc=0
  if [ "$ROUTE_REMOTE" -eq 1 ]; then
    out=$("$SCRIPT_DIR/fm-on.sh" "$OLD" fm-remote-secondmate-control.sh state "$OLD" </dev/null 2>/dev/null) || rc=$?
    if [ "$rc" -eq 255 ]; then
      printf 'transport-unknown'
      return 0
    fi
    [ "$rc" -eq 0 ] || {
      printf 'unknown'
      return 0
    }
    printf '%s' "$(printf '%s\n' "$out" | tail -1)"
    return 0
  fi
  if [ ! -f "$STATE/$OLD.meta" ] || [ -L "$STATE/$OLD.meta" ]; then
    printf 'missing'
    return 0
  fi
  if ! fm_backend_validate_task_endpoint "$STATE/$OLD.meta" "$OLD" 2>/dev/null; then
    printf 'unreadable'
    return 0
  fi
  fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"
}

preflight_endpoint() {
  local verdict stop_cmd
  verdict=$(endpoint_verdict)
  case "$verdict" in
    alive)
      stop_cmd=$(maybe_stop_command)
      die "secondmate $OLD still reports a live agent; stop it first ($stop_cmd), then rerun this rename"
      ;;
    dead|missing) ;;
    transport-unknown)
      # The rename needs that host again for its home half, so an unreachable
      # host is a hard refusal: --stopped cannot substitute for a transport the
      # rest of the operation has to use.
      die "host ${ROUTE_HOST} is unreachable, so its home half cannot run; reconcile that host and rerun"
      ;;
    *)
      [ "$STOPPED" -eq 1 ] || {
        stop_cmd=$(maybe_stop_command)
        die "the endpoint verdict for $OLD is '$verdict', which this home cannot verify; stop the mate ($stop_cmd) and rerun with --stopped"
      }
      ;;
  esac
  return 0
}

# Every record this helper deliberately does not rewrite refuses the rename
# while it is present, instead of being left silently pointing at the old id.
preflight_foreign_records() {
  local rec phase survived=0
  local -a survivors=()
  if [ -d "$STATE/pending-replies" ]; then
    for rec in "$STATE/pending-replies"/*; do
      [ -f "$rec" ] && [ ! -L "$rec" ] || continue
      grep -qxF "task_id=$OLD" "$rec" 2>/dev/null || continue
      phase=$(sed -n 's/^phase=//p' "$rec" | tail -1)
      [ "$phase" != resolved ] || continue
      survivors+=("$rec (phase=${phase:-unknown})")
    done
  fi
  for rec in "$STATE/decision-bindings"/* "$STATE/reconcile-requests"/*; do
    [ -e "$rec" ] || [ -L "$rec" ] || continue
    case "$(basename "$rec")" in
      *"$OLD"*) survivors+=("$rec") ;;
    esac
  done
  [ "${#survivors[@]}" -eq 0 ] || survived=1
  if [ "$survived" -eq 1 ]; then
    printf 'error: these records still name %s and this helper does not own them; settle or clear them first:\n' "$OLD" >&2
    printf 'error: %s\n' "${survivors[@]}" >&2
    exit 1
  fi
  return 0
}

preflight_plan() {
  [ ! -e "$DATA/$NEW" ] && [ ! -L "$DATA/$NEW" ] || die "refusing to rename: $DATA/$NEW already exists"
  [ ! -e "$STATE/$NEW.meta" ] && [ ! -L "$STATE/$NEW.meta" ] \
    || die "refusing to rename: $STATE/$NEW.meta already exists"
  [ ! -e "$DATA/remote-secondmates/$NEW" ] && [ ! -L "$DATA/remote-secondmates/$NEW" ] \
    || die "refusing to rename: $DATA/remote-secondmates/$NEW already exists"
  return 0
}

# The reply channel has two id-keyed families with different owners, and the
# order matters. The cursor, the per-capture receipts, and the caught-up
# watermark live under $STATE/remote-replies keyed by the MATE id, and
# bin/fm-procevent-remote-reply.sh's own retirement deletes them by that id, so
# they migrate FIRST: a fresh source must continue from the old offset rather
# than replay the mate's whole parent-replies.status into its status channel.
# The registration, runner sidecars, and captured results are keyed by the
# SOURCE id (remote-reply-<id>) inside $STATE/procevent and
# $STATE/procevent-inbox, and they migrate after that retirement has quiesced
# the runner.
reply_source_migrate_cursors() {
  [ "$ROUTE_REMOTE" -eq 1 ] || return 0
  fm_secondmate_rename_sweep_dir "$STATE/remote-replies" "$OLD" "$NEW" \
    || die "could not migrate a remote reply cursor"
  return 0
}

reply_source_retire() {
  local out rc=0
  [ "$ROUTE_REMOTE" -eq 1 ] || return 0
  out=$("$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire "$OLD" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: the remote reply source for %s could not be retired:\n' "$OLD" >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    exit 1
  fi
  REPLY_SOURCE=migrated
  return 0
}

reply_source_migrate_source() {
  [ "$ROUTE_REMOTE" -eq 1 ] || return 0
  fm_secondmate_rename_sweep_dir "$STATE/procevent" "$OLD" "$NEW" \
    || die "could not migrate a procevent sidecar"
  fm_secondmate_rename_sweep_dir "$STATE/procevent-inbox" "$OLD" "$NEW" \
    || die "could not migrate a captured reply result"
  return 0
}

home_rewrite() {
  local out rc=0 keep_arg result
  if [ "$ROUTE_REMOTE" -eq 0 ]; then
    fm_secondmate_rename_retire_endpoint "$STATE/$OLD.meta" "$OLD" || exit 1
    keep_arg=no
    [ "$KEEP_PATH" = no ] || keep_arg=yes
    fm_secondmate_rename_home "$OLD" "$NEW" "$OLD_HOME" "$keep_arg" || exit 1
    NEW_HOME=$FM_SECONDMATE_RENAME_HOME
    MOVE_STATE=$FM_SECONDMATE_RENAME_MOVED
    ENDPOINT_STATE=$FM_SECONDMATE_RENAME_ENDPOINT
    return 0
  fi
  keep_arg=
  [ "$KEEP_PATH" = no ] || keep_arg=--keep-home-path
  if [ -n "$keep_arg" ]; then
    out=$("$SCRIPT_DIR/fm-on.sh" "$OLD" fm-remote-secondmate-control.sh rename "$OLD" "$NEW" "$keep_arg" </dev/null 2>&1) || rc=$?
  else
    out=$("$SCRIPT_DIR/fm-on.sh" "$OLD" fm-remote-secondmate-control.sh rename "$OLD" "$NEW" </dev/null 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'error: the remote half of the rename did not complete (host %s, code root %s):\n' "$ROUTE_HOST" "$ROUTE_ROOT" >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    case "$rc" in
      255) printf 'error: remote completion is unknown; reconcile on %s before retrying\n' "$ROUTE_HOST" >&2 ;;
    esac
    exit "$rc"
  fi
  result=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
  [ -n "$result" ] || {
    printf 'error: the remote rename returned no home path:\n' >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    exit 1
  }
  NEW_HOME=$result
  MOVE_STATE=$(printf '%s\n' "$out" | sed -n 's/^moved=//p' | tail -1)
  ENDPOINT_STATE=$(printf '%s\n' "$out" | sed -n 's/^endpoint=//p' | tail -1)
  [ -n "$MOVE_STATE" ] || MOVE_STATE=no
  [ -n "$ENDPOINT_STATE" ] || ENDPOINT_STATE=absent
  return 0
}

# Rewrite the parent task record in place: the window handle, the endpoint task
# binding, and the home/worktree paths it carries. Every other line is preserved
# byte for byte, because every other line belongs to another owner.
rewrite_parent_meta() {
  local meta="$STATE/$OLD.meta" line value tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  tmp="$STATE/.$NEW.meta.fm-rename.$$"
  : > "$tmp" || die "could not write $tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      window=*)
        value=${line#window=}
        line="window=${value//"$OLD"/"$NEW"}"
        ;;
      endpoint_task_id=*)
        value=${line#endpoint_task_id=}
        line="endpoint_task_id=${value//"$OLD"/"$NEW"}"
        ;;
      worktree=*|home=*)
        value=${line#*=}
        line="${line%%=*}=${value//"$OLD_HOME"/"$NEW_HOME"}"
        ;;
      tasktmp=*)
        value=${line#tasktmp=}
        line="tasktmp=${value//"$OLD"/"$NEW"}"
        ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
  done < "$meta"
  mv -f -- "$tmp" "$STATE/$NEW.meta" || die "could not publish $STATE/$NEW.meta"
  rm -f -- "$meta"
}

parent_records_move() {
  rewrite_parent_meta
  fm_secondmate_rename_sweep_dir "$STATE" "$OLD" "$NEW" || die "could not rename a parent state record"
  presentation_cursor_migrate
  if [ -e "$DATA/$OLD" ] || [ -L "$DATA/$OLD" ]; then
    mv -- "$DATA/$OLD" "$DATA/$NEW" || die "could not rename $DATA/$OLD"
  fi
  if [ -d "$DATA/remote-secondmates/$OLD" ]; then
    mv -- "$DATA/remote-secondmates/$OLD" "$DATA/remote-secondmates/$NEW" \
      || die "could not rename $DATA/remote-secondmates/$OLD"
  fi
  return 0
}

# state/<id>.status is presented by a byte cursor held per task id inside
# $STATE/.status-presentation-cursor (bin/fm-classify-lib.sh owns that
# manifest). The status file itself is renamed, which preserves its dev:inode
# identity, so migrating that one row key keeps the renamed mate's presentation
# cursor intact; leaving the row behind would read as a brand-new log and
# re-present its whole history. Every other row and column is preserved byte for
# byte, under the same lock bin/fm-classify-lib.sh writes with.
presentation_cursor_migrate() {
  local manifest="$STATE/.status-presentation-cursor" lock tmp line first rest collision=0
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 0
  lock="$STATE/.status-presentation-lock"
  fm_lock_acquire_wait "$lock" || die "the status presentation lock could not be acquired"
  tmp="$manifest.tmp.$$"
  : > "$tmp" || {
    fm_lock_release "$lock" || true
    die "could not stage $tmp"
  }
  while IFS= read -r line || [ -n "$line" ]; do
    first=${line%%$'\t'*}
    rest=${line#"$first"}
    case "$first" in
      "$OLD") first=$NEW ;;
      "$NEW") collision=1 ;;
    esac
    printf '%s%s\n' "$first" "$rest" >> "$tmp"
  done < "$manifest"
  if [ "$collision" -eq 1 ]; then
    rm -f -- "$tmp"
    fm_lock_release "$lock" || true
    die "refusing to migrate the presentation cursor for $OLD: $NEW already has a row"
  fi
  mv -f -- "$tmp" "$manifest" || {
    fm_lock_release "$lock" || true
    die "could not publish $manifest"
  }
  fm_lock_release "$lock" || true
  return 0
}
# The registry line is re-emitted from the fields
# bin/fm-secondmate-registry-lib.sh parses, never by editing the text in place:
# the old id must vanish from the id position, the home field, and any prose that
# names it, while summary, scope, projects, and the added date survive verbatim.
registry_line_rewrite() {  # <line>
  local summary scope projects added home line
  secondmate_registry_parse_line "$1" || return 1
  summary=$(fm_secondmate_rename_replace_bounded "$SECONDMATE_REGISTRY_SUMMARY" "$OLD" "$NEW")
  scope=$(fm_secondmate_rename_replace_bounded "$SECONDMATE_REGISTRY_SCOPE" "$OLD" "$NEW")
  projects=$SECONDMATE_REGISTRY_PROJECTS
  added=$SECONDMATE_REGISTRY_ADDED
  home=${SECONDMATE_REGISTRY_HOME//"$OLD_HOME"/"$NEW_HOME"}
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    printf -- '- %s - %s (host: %s; root: %s; home: %s; scope: %s; projects: %s; added %s)\n' \
      "$NEW" "$summary" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" "$home" \
      "$scope" "$projects" "$added"
  else
    printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' \
      "$NEW" "$summary" "$home" "$scope" "$projects" "$added"
  fi
}

registry_rewrite() {
  local tmp line rewritten
  tmp="$REG.tmp.$$"
  : > "$tmp" || die "could not write $tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    rewritten=$line
    case "$line" in
      "- $OLD "*|"- $OLD")
        rewritten=$(registry_line_rewrite "$line") \
          || die "the registry line for $OLD could not be re-emitted"
        ;;
    esac
    printf '%s\n' "$rewritten" >> "$tmp"
  done < "$REG"
  mv -f -- "$tmp" "$REG" || die "could not publish $REG"
  return 0
}

reply_source_arm() {
  local out rc=0
  [ "$ROUTE_REMOTE" -eq 1 ] || return 0
  out=$("$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$NEW" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: the reply source was not re-armed for %s; run bin/fm-procevent-remote-reply.sh arm %s\n' "$NEW" "$NEW" >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    exit 1
  fi
  return 0
}

verify_no_survivors() {
  local dir path base planned survived=0
  local -a survivors=()
  for dir in "$STATE" "$STATE/procevent" "$STATE/procevent-inbox" "$STATE/remote-replies" "$DATA"; do
    [ -d "$dir" ] || continue
    for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      base=$(basename "$path")
      planned=$(fm_secondmate_rename_replace_bounded "$base" "$OLD" "$NEW")
      [ "$planned" != "$base" ] || continue
      survivors+=("$path")
    done
  done
  if [ "${#survivors[@]}" -gt 0 ]; then
    survived=1
  fi
  if [ "$survived" -eq 1 ]; then
    printf 'error: rename completed, but these records still carry %s and need attention:\n' "$OLD" >&2
    printf 'error: %s\n' "${survivors[@]}" >&2
    return 1
  fi
  return 0
}

report() {
  printf 'schema=fm-secondmate-rename.v1\n'
  printf 'old_id=%s\n' "$OLD"
  printf 'new_id=%s\n' "$NEW"
  printf 'home=%s\n' "$NEW_HOME"
  printf 'moved=%s\n' "${MOVE_STATE:-no}"
  printf 'endpoint=%s\n' "${ENDPOINT_STATE:-absent}"
  printf 'reply_source=%s\n' "$REPLY_SOURCE"
  printf 'respawn=bin/fm-spawn.sh %s --secondmate\n' "$NEW"
  printf "notice: the registry summary and scope text are this mate's charter prose and were left as written\n" >&2
  [ "${ENDPOINT_STATE:-absent}" = retained ] || return 0
  printf 'notice: a recorded endpoint or workspace could not be proven removed; reconcile it on %s before relying on the new name\n' \
    "${ROUTE_HOST:-this host}" >&2
}

main() {
  parse_args "$@"
  preflight_registry
  load_route
  preflight_local_identity
  remote_verb_probe
  preflight_endpoint
  preflight_foreign_records
  preflight_plan
  reply_source_migrate_cursors
  reply_source_retire
  reply_source_migrate_source
  home_rewrite
  parent_records_move
  registry_rewrite
  reply_source_arm
  "$SCRIPT_DIR/fm-home-seed.sh" validate >/dev/null || die "the secondmate registry is invalid after the rename"
  verify_no_survivors || exit 1
  report
}

main "$@"
