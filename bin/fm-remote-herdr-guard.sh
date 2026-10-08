#!/usr/bin/env bash
# launchd exec target for the Firstmate-owned dev.firstmate.herdr.fm-remote
# launch agent: make the Aqua login session own the fm-remote Herdr server,
# and keep that server supervised while it is its own session leader.
#
# Usage:
#   fm-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh renders the launch agent as the account's login
# shell running `exec <this script> <herdr> fm-remote` with
# LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false},
# and ThrottleInterval=10, then bootstraps it into gui/<uid>. That domain, not
# the login shell, is what gives this process and every server it forks the
# Aqua audit session and login-keychain access; the login shell only gives the
# server the account's own environment.
# This process does not become the server. It stays alive as the waiting
# supervisor of a forked child that calls setsid(2) before executing herdr, so
# the server is the session leader Herdr requires before it will save this host
# as a machine, while launchd still has exactly one process to supervise and
# still sees the server's own exit status. The supervisor forwards launchd's
# stop signals to that child, so a bootout or kickstart stops the server rather
# than orphaning it, and AbandonProcessGroup stays absent because a
# session-leader child is already outside the job's process group.
# bin/fm-remote-herdr-owner-lib.sh owns the start primitive, and
# docs/verification/runtime-backends.md ("fm-remote server birth and
# login-keychain access") holds the dated evidence.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   no server owns the session socket  -> supervise a fresh session-leader
#                                          `herdr server --session <s>` child
#   the owner is one of this launch agent's own supervised session-leader
#   children                           -> exit 0, leave it alone
#   the owner was born in the Aqua session but leads no session of its own
#   (this job's own historical exec shape, or the Aqua remote-job worker's
#   server)                            -> take the session over, because such a
#                                          server can never be offered to
#                                          another machine's sidebar and
#                                          nothing else would ever replace it
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove) -> `herdr server stop`, wait until the
#                                          socket is released, then supervise a
#                                          fresh session-leader server at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the previous server does not release the socket in time -> exit 1
# A takeover closes every pane in that session; the parent firstmate's
# secondmate liveness sweep relaunches its mates into the supervised server.
# bin/fm-remote-herdr-owner-lib.sh owns the owner discovery, the birth
# classification, and the start primitive; FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS (default 50) bounds the
# release wait in tenths of a second. Every decision prints one line to
# stdout, which launchd routes to the agent's log.
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] || usage
HERDR_BIN=$1
SESSION=$2
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || { printf 'fm-remote-herdr-guard: herdr is not executable: %s\n' "$HERDR_BIN" >&2; exit 1; }
[ -n "$SESSION" ] || usage
command -v jq >/dev/null 2>&1 || { printf 'fm-remote-herdr-guard: jq does not resolve on the launch agent PATH\n' >&2; exit 1; }
fm_remote_herdr_perl_bin >/dev/null || { printf 'fm-remote-herdr-guard: no perl interpreter resolves, so a session-leader server cannot be started\n' >&2; exit 1; }
STOP_WAIT_TENTHS=${FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS:-50}

log() { printf 'fm-remote-herdr-guard: %s\n' "$*"; }

herdr_status() { # prints the session's status JSON, empty when herdr fails
  HERDR_SESSION="$SESSION" "$HERDR_BIN" status --json --session "$SESSION" 2>/dev/null || true
}

status_running() { # <status-json>
  [ "$(printf '%s' "$1" | jq -r '.server.running // false' 2>/dev/null)" = true ]
}

start_server() {
  log "supervising a fresh session-leader herdr server for session $SESSION from this launch agent (pid $$)"
  fm_remote_herdr_supervise_exec "$HERDR_BIN" "$SESSION"
  log "the session-leader server for session $SESSION could not be started"
  exit 1
}

STATUS=$(herdr_status)
if ! status_running "$STATUS"; then
  log "no server owns session $SESSION"
  start_server
fi

SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty' 2>/dev/null)
OWNER=$(fm_remote_herdr_socket_owner "$SOCKET"); OWNER_RC=$?
if [ "$OWNER_RC" -eq 2 ]; then
  log "session $SESSION is running but lsof does not resolve, so its server's birth cannot be proven"
  BIRTH=unknown
elif [ -z "$OWNER" ]; then
  log "session $SESSION is running but no herdr process could be proven to own ${SOCKET:-its socket}"
  BIRTH=unknown
else
  BIRTH=$(fm_remote_herdr_owner_birth "$OWNER")
fi

if fm_remote_herdr_birth_is_supervised "$BIRTH"; then
  log "session $SESSION is served by pid $OWNER, this launch agent's own supervised session-leader child; nothing to do"
  exit 0
fi

if fm_remote_herdr_birth_is_aqua "$BIRTH"; then
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH) but not leading its own session, so Herdr will not offer this host to another machine; taking the session over so its replacement is supervised"
else
  log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
fi
HERDR_SESSION="$SESSION" "$HERDR_BIN" server stop --session "$SESSION" >/dev/null 2>&1 \
  || log "herdr server stop for session $SESSION did not succeed; waiting for the socket anyway"
i=0
while [ "$i" -lt "$STOP_WAIT_TENTHS" ]; do
  if ! status_running "$(herdr_status)"; then
    log "session $SESSION released its socket after $i tenths of a second"
    start_server
  fi
  sleep 0.1
  i=$((i + 1))
done
log "the foreign server for session $SESSION did not release its socket within $STOP_WAIT_TENTHS tenths of a second; exiting 1 so launchd retries"
exit 1
