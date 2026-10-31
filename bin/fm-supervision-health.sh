#!/usr/bin/env bash
# Independent, home-scoped supervision health check and systemd user units.
# Usage: FM_HOME=/absolute/home bin/fm-supervision-health.sh check|run|install|doctor
# check samples once; run watches freshness for one FM_POLL window, with bounded I/O.
# install writes a per-home service/timer under XDG_CONFIG_HOME/systemd/user and
# enables it through systemctl --user. No sudo, packages, or daemon are needed.
# doctor checks unit contents, enabled/active timer state, and service failures.
# FM_SUPERVISION_UNIT_DIR overrides the unit directory for isolated managers.
# Config cadence: config/watch.env, then config/x-mode.env, default FM_POLL=15.
# Freshness: newest existing watcher beacon or successful drain timestamp.
# One incident uses state/.primary-loss-alert and its existing sibling lock.
# A listener-health receipt records delivery-uncertain before sending, followed
# by delivery-sent or delivery-failed; uncertainty is never retried automatically.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FM_HOME:?FM_HOME must name the supervised home}"
case "$FM_HOME" in /*) ;; *) echo 'supervision-health: FM_HOME must be absolute' >&2; exit 2 ;; esac
export FM_HOME
export FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=/dev/null
[ ! -f "$FM_CONFIG_OVERRIDE/watch.env" ] || . "$FM_CONFIG_OVERRIDE/watch.env"
# shellcheck source=/dev/null
[ ! -f "$FM_CONFIG_OVERRIDE/x-mode.env" ] || . "$FM_CONFIG_OVERRIDE/x-mode.env"
export FM_POLL="${FM_POLL:-15}"
if [[ ! $FM_POLL =~ ^0*[1-9][0-9]*$ ]]; then
  echo 'supervision-health: FM_POLL must be a positive integer' >&2
  exit 2
fi
case "${1:-}" in
  _probe)
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    fm_backend_recorded_target_exists "$2"
    ;;
  _owner)
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$SCRIPT_DIR/fm-session-lock-lib.sh"
    fm_session_lock_inspect "$FM_STATE_OVERRIDE"
    [ "$FM_LOCK_INSPECT_STATE" = held ]
    ;;
  _incident|_clear)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    lock="$STATE/.primary-loss-alert.lock"
    marker="$STATE/.primary-loss-alert"
    queued_marker="$STATE/.primary-loss-queued"
    write_incident_receipt() {
      local tmp
      tmp=$(mktemp "$STATE/.primary-loss-receipt.XXXXXX") || return 1
      if ! printf '%s\n%s\n' "$incident" "$1" > "$tmp" || ! mv -f "$tmp" "$marker"; then
        rm -f "$tmp"
        return 1
      fi
    }
    fm_lock_acquire_wait_bounded "$lock" 1 || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    if python3 "$SCRIPT_DIR/fm-supervision-health.py" fresh; then
      rm -f "$marker" "$queued_marker"
      exit 0
    fi
    [ "$1" != _clear ] || exit 0
    [ ! -L "$marker" ] && [ ! -d "$marker" ] || { echo 'supervision-health: unsafe incident marker' >&2; exit 1; }
    reason='check: primary-supervision-lost: home supervision stopped checking in while work is still live; restart firstmate to resume supervision'
    [ ! -L "$queued_marker" ] && [ ! -d "$queued_marker" ] || { echo 'supervision-health: unsafe queue marker' >&2; exit 1; }
    sender=
    if [ -s "$marker" ]; then
      incident=$(head -n 1 "$marker")
      case "$incident" in
        listener-health:*) ;;
        *) exit 0 ;;
      esac
    else
      incident="listener-health:$$:$(date +%s)"
      write_incident_receipt delivery-uncertain
      "$SCRIPT_DIR/fm-telegram-send.sh" "$reason" &
      sender=$!
    fi
    queued=0
    if [ "$(cat "$queued_marker" 2>/dev/null || true)" = "$incident" ]; then
      queued=1
    elif fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 1; then
      if fm_wake_queued_keys_locked check | grep -Fx primary-supervision-lost >/dev/null \
        || fm_wake_append_locked check primary-supervision-lost "$reason"; then
        if printf '%s\n' "$incident" > "$queued_marker"; then
          queued=1
        fi
      fi
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fi
    fm_lock_release "$lock"
    trap - EXIT
    if [ -n "$sender" ]; then
      delivery='delivery-sent'
      wait "$sender" || delivery='delivery-failed'
      if fm_lock_acquire_wait_bounded "$lock" 1; then
        if [ "$(head -n 1 "$marker" 2>/dev/null || true)" = "$incident" ]; then
          write_incident_receipt "$delivery"
        fi
        fm_lock_release "$lock"
      fi
    fi
    if [ "$queued" -ne 1 ]; then
      echo 'supervision-health: could not queue primary-supervision-lost; publication remains pending' >&2
    fi
    python3 "$SCRIPT_DIR/fm-supervision-health.py" delivery
    ;;
  check|run|install|doctor)
    exec python3 "$SCRIPT_DIR/fm-supervision-health.py" "$1"
    ;;
  *) echo 'usage: FM_HOME=/absolute/home fm-supervision-health.sh check|run|install|doctor' >&2; exit 2 ;;
esac
