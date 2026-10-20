#!/usr/bin/env bash
# Cross-language entry point for the outstanding-notification claim and the
# replayed-notification decision.
#
# A primary harness integration delivers one supervisor notification per
# actionable watcher cycle. While the supervisor is busy and cannot drain, those
# notifications stack up even though the durable queue already coalesces and one
# acknowledgement retires every row a drain presented. This script is how a
# harness integration asks, atomically, whether one more notification adds
# anything. bin/fm-wake-lib.sh's fm_wake_notify_claim owns the rule and the
# state/.wake-announced-through record; this file only exposes it to callers
# that are not shell, the same way fm-watch-arm.sh --handling-delivered does.
# A notification replayed from an earlier session asks `replay` instead, which
# fm_wake_notify_replay owns.
#
# Commands:
#   fm-wake-notify.sh claim   # prints "deliver" or "skip"; claim is recorded on deliver
#   fm-wake-notify.sh replay  # reads a replayed notification on stdin; prints "skip",
#                             # or "deliver" and then the message to deliver
#   fm-wake-notify.sh state   # prints the recorded sequence, or "none"
#   fm-wake-notify.sh --help
#
# `claim` and `replay` exit 0 whenever they produced a decision, so a caller
# reads the printed word rather than the exit status. They exit 1 only when no
# decision could be made safely, and a caller that cannot decide MUST deliver
# the original notification: a missed notification is worse than a duplicate
# one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-wake-notify.sh claim | replay | state
  claim   decide whether one more supervisor notification adds anything;
          prints "deliver" or "skip" and records the claim when delivering
  replay  decide what a notification replayed from an earlier session still
          owes; reads it on stdin, prints "skip" or "deliver" and the message
  state   print the recorded covered sequence, or "none"
EOF
}

case "${1:-}" in
  claim)
    [ "$#" -eq 1 ] || { echo "fm-wake-notify: claim takes no arguments" >&2; exit 2; }
    fm_wake_notify_claim
    case $? in
      0) echo deliver ;;
      1) echo skip ;;
      *) echo "fm-wake-notify: the notification claim could not be decided safely" >&2; exit 1 ;;
    esac
    ;;
  replay)
    [ "$#" -eq 1 ] || { echo "fm-wake-notify: replay takes no arguments" >&2; exit 2; }
    replay_message=$(cat) || { echo "fm-wake-notify: the replayed notification could not be read" >&2; exit 1; }
    replay_owed=$(fm_wake_notify_replay "$replay_message")
    case $? in
      0) printf 'deliver\n%s\n' "$replay_owed" ;;
      1) echo skip ;;
      *) echo "fm-wake-notify: the replayed notification could not be decided safely" >&2; exit 1 ;;
    esac
    ;;
  state)
    [ "$#" -eq 1 ] || { echo "fm-wake-notify: state takes no arguments" >&2; exit 2; }
    _fm_wake_notify_record_read || printf 'none'
    printf '\n'
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
