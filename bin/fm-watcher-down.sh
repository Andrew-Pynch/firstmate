#!/usr/bin/env bash
# fm-watcher-down.sh - the WATCHER DOWN banner a primary shows at the start of
# its next turn when supervision has been off too long.
#
# Usage: FM_HOME=<home> fm-watcher-down.sh
#   Prints one banner line and exits 0 when ALL of these hold for the home's
#   state directory, and prints nothing (exit 0) otherwise:
#     - state/.lock names a live harness process (a session holds the lock);
#     - the home needs supervision (fm_supervision_status in
#       bin/fm-supervision-lib.sh: work in flight, an event source, a
#       registered check, or a relay poll);
#     - no watcher has touched state/.last-watcher-beat for at least the
#       threshold (state/.lock's age stands in when no beat was ever written).
#   The threshold is FM_WATCHER_DOWN_BANNER_MINUTES (default 10) minutes, raised
#   to fm_poll_derived_grace when that is longer, so a slow poll cadence or an
#   away-mode daemon between one-shot watchers never reads as down.
#   The banner names the outage length, the state directory, the lock owner,
#   what needs supervision, and the harness repair line from
#   bin/fm-supervision-instructions.sh --repair-line.
#
# Why: the turn-end guard only fires when a turn ends. A primary that sits idle
# while its watcher is dead ends no turn, so the outage stays silent until the
# captain happens to look; the omp watch extension runs this at every agent
# start (docs/turnend-guard.md "Watcher-down banner") so the next turn opens
# with the outage instead.
# Read-only: it never arms, repairs, or writes anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) echo "usage: fm-watcher-down.sh" >&2; exit 2 ;;
esac

LOCK_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in ''|*[!0-9]*|0|1) exit 0 ;; esac
kill -0 "$LOCK_PID" 2>/dev/null || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

MINUTES=${FM_WATCHER_DOWN_BANNER_MINUTES:-10}
case "$MINUTES" in ''|*[!0-9]*|0) MINUTES=10 ;; esac
THRESHOLD=$((MINUTES * 60))
GRACE=$(fm_poll_derived_grace)
[ "$GRACE" -le "$THRESHOLD" ] || THRESHOLD=$GRACE

BEAT="$STATE/.last-watcher-beat"
if [ -e "$BEAT" ]; then
  AGE=$(fm_path_age "$BEAT")
  SINCE="no watcher beat for"
else
  AGE=$(fm_path_age "$STATE/.lock")
  SINCE="no watcher has ever beaten since the session lock was taken, for"
fi
case "$AGE" in ''|*[!0-9]*) exit 0 ;; esac
[ "$AGE" -ge "$THRESHOLD" ] || exit 0

fm_harness_pid_alive "$LOCK_PID" || exit 0
fm_supervision_status "$STATE"
[ "$FM_SUP_NEEDED" = true ] || exit 0

NEED="$FM_SUP_IN_FLIGHT task(s) in flight"
[ "$FM_SUP_SOURCES" -eq 0 ] || NEED="$NEED, $FM_SUP_SOURCES event source(s)"
[ "$FM_SUP_CHECKS" -eq 0 ] || NEED="$NEED, $FM_SUP_CHECKS registered check(s)"
[ ! -f "$STATE/x-watch.check.sh" ] || NEED="$NEED, the relay poll"

AFK=0
[ -e "$STATE/.afk" ] && AFK=1
X_MODE=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE=1
REPAIR=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$AFK" --x-mode "$X_MODE" --repair-line 2>/dev/null) \
  || REPAIR='restore watcher supervision according to the session-start operating block'

printf 'WATCHER DOWN - %s %dh%02dm in %s while pid %s holds this home'"'"'s session lock (%s); no wake, merge, or blocker reaches this conversation until supervision is restored. %s\n' \
  "$SINCE" "$((AGE / 3600))" "$(((AGE % 3600) / 60))" "$STATE" "$LOCK_PID" "$NEED" "$REPAIR"
