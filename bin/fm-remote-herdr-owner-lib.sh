#!/usr/bin/env bash
# Who owns a Herdr session socket, was that process born in the Aqua login
# session, and how a fresh fm-remote server is started so it is both a session
# leader and a supervised child of its launch agent.
#
# Source this file; it defines functions only. It is the single owner of the
# socket-owner discovery, the birth classification, and the start primitive
# shared by bin/fm-remote-herdr-guard.sh (the launch agent's exec target) and
# bin/fm-remote-doctor.sh (the readiness check for that session).
#
# Why birth matters: a herdr server, and every pane and agent it later spawns,
# keeps the macOS audit session of whatever started it. Only the Aqua login
# session (the gui/<uid> launchd domain) can read the login keychain without a
# UI prompt. A server started over SSH - herdr's own remote attach does this
# when it finds no server, and it wins the socket at boot because sshd accepts
# connections before the login session exists - runs in sshd's audit session,
# where `security find-generic-password -w` exits 36 (interaction not allowed)
# and every claude pane silently falls back to a stale plaintext credentials
# file and reports "Login expired".
#
# Why session leadership matters: Herdr only offers a session's server to
# another host's sidebar when that server is its own session leader, which it
# reports as the per-session `detached_server_daemon` capability. A server the
# launch agent execs directly keeps launchd's session, so it can never be saved
# as a machine even though its birth is perfect. The start primitive below
# therefore forks a child that calls setsid(2) before executing herdr, while
# the parent stays alive as the waiting supervisor so the launch agent keeps
# one process to supervise and its crash-restart policy still fires.
# docs/verification/runtime-backends.md ("fm-remote server birth and
# login-keychain access") holds the dated evidence for every fact read here.
#
# Functions:
#   fm_remote_herdr_socket_owner <socket-path>
#     Prints the pid of the herdr process that holds <socket-path>, or nothing
#     when no herdr process does. Reads `lsof -U -a -c herdr -F pn`; on macOS
#     `pgrep -f` cannot see the herdr server's argv, so lsof is the owner
#     source. When several herdr processes list the path, the one whose argv
#     runs `server` wins. Returns 2, printing nothing, when lsof does not
#     resolve; the caller decides what an unprovable owner means.
#   fm_remote_herdr_process_env <pid>
#     Prints the process environment as NAME=VALUE lines: `ps -Eww` on darwin
#     (own-uid processes only), /proc/<pid>/environ elsewhere. Used ONLY to
#     reject an SSH birth, never to prove an Aqua one: any same-uid peer can
#     export whatever it likes, and a detached or handed-off server carries
#     whichever launchd variables it inherited.
#   fm_remote_herdr_process_ancestry <pid>
#     Prints "<pid> <command>" for <pid> and each ancestor up to pid 1.
#   fm_remote_herdr_process_sid <pid>
#     Prints the session id the kernel records for <pid>, where the kernel
#     exposes it (/proc/<pid>/stat). Returns 1 on darwin, where getsid(2) is
#     refused across sessions and no ps keyword reports it, so leadership there
#     is proven structurally through the ancestry instead.
#   fm_remote_herdr_pid_is_session_leader <pid>
#     Succeeds when the recorded session id equals <pid>, fails when it does
#     not, and returns 2 when this kernel does not expose it.
#   fm_remote_herdr_owner_birth <pid>
#     Prints exactly one word:
#       ssh         an ancestor that is sshd or herdr's remote-client-bridge
#                   (matched on argv[0] and whole arguments only), or an
#                   SSH_CONNECTION, SSH_CLIENT, or SSH_TTY in the environment
#       supervised  the pid of the gui-exclusive Herdr launch agent job is an
#                   ancestor of this server, so the Aqua job forked it through
#                   the setsid supervisor below
#       launchd     the gui-exclusive Herdr launch agent job IS this process,
#                   the historical exec shape: Aqua-born, but sharing launchd's
#                   session, so Herdr will not save it as a machine
#       worker      the gui-exclusive dev.firstmate.remote-job job is this
#                   process or one of its ancestors
#       unknown     none of the above; no environment marker can earn a
#                   positive verdict
#   fm_remote_herdr_birth_is_aqua <birth>
#     Succeeds for supervised, launchd, and worker. It answers one question
#     only - can this server's panes read the login keychain - and it is NOT
#     the test for leaving a server alone: launchd and worker lead no session
#     of their own, so Herdr will not offer their host to another machine and
#     the guard replaces them. `unknown` is deliberately not Aqua: a server
#     that cannot prove its birth is treated like a foreign one, because
#     leaving it in place silently reproduces the keychain failure.
#   fm_remote_herdr_birth_is_supervised <birth>
#     Succeeds only for supervised: the one birth that is both Aqua-born and
#     its own session leader, so it is what both the guard's leave-alone
#     decision and the doctor's readiness verdict test.
#   fm_remote_herdr_supervise_exec <herdr-path> <session>
#     Replaces this process with the waiting supervisor of a fresh
#     session-leader server. Never returns on success; returns 1 when no perl
#     interpreter resolves.
#   fm_remote_herdr_start_detached <herdr-path> <session>
#     Starts the same session-leader server without a supervisor, for a host
#     with no launch agent to supervise it, and prints its pid.

FM_REMOTE_HERDR_AGENT_LABEL=dev.firstmate.herdr.fm-remote
FM_REMOTE_HERDR_WORKER_LABEL=dev.firstmate.remote-job

fm_remote_herdr_socket_owner() { # <socket-path>
  local socket=$1 real pid='' line candidates='' candidate cmd
  [ -n "$socket" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 2
  real=$(CDPATH='' cd -- "$(dirname "$socket")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$socket")") || real=$socket
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        [ -n "$pid" ] || continue
        case "${line#n}" in
          "$socket"|"$real") candidates="${candidates}${pid}"$'\n' ;;
        esac
        ;;
    esac
  done < <(lsof -U -a -c herdr -F pn 2>/dev/null)
  [ -n "$candidates" ] || return 0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    cmd=$(ps -o command= -p "$candidate" 2>/dev/null || true)
    case " $cmd " in *' server '*) printf '%s\n' "$candidate"; return 0 ;; esac
  done <<EOF2
$candidates
EOF2
  printf '%s\n' "${candidates%%$'\n'*}"
}

fm_remote_herdr_process_env() { # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ"
    return 0
  fi
  ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true
}

fm_remote_herdr_process_ancestry() { # <pid>
  local pid=$1 depth=0 line ppid
  while [ "$depth" -lt 64 ]; do
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 0 ] || return 0
    line=$(ps -o ppid=,command= -p "$pid" 2>/dev/null) || return 0
    [ -n "$line" ] || return 0
    ppid=$(printf '%s' "$line" | awk '{print $1}')
    printf '%s %s\n' "$pid" "$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
    [ "$pid" -ne 1 ] || return 0
    pid=$ppid
    depth=$((depth + 1))
  done
}

# Field 6 of /proc/<pid>/stat is the session id; the comm field can contain
# spaces and parentheses, so everything up to the last ") " is dropped first.
fm_remote_herdr_process_sid() { # <pid>
  local pid=$1 stat rest sid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/stat" ] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${stat##*') '}
  sid=$(printf '%s\n' "$rest" | awk '{print $4}')
  case "$sid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$sid"
}

fm_remote_herdr_pid_is_session_leader() { # <pid>
  local sid
  sid=$(fm_remote_herdr_process_sid "$1") || return 2
  [ "$sid" = "$1" ]
}

# The pid launchd reports for <label> in gui/<uid>, printed only when that
# label is loaded in gui/<uid> and NOT in user/<uid>. Exclusivity is what makes
# the pid proof: a label loaded in both domains can be answering for the
# Background job, which has no keychain access.
fm_remote_herdr_gui_job_pid() { # <uid> <label>
  local uid=$1 label=$2 job pid
  [ -n "$uid" ] && [ -n "$label" ] || return 1
  job=$(launchctl print "gui/$uid/$label" 2>/dev/null) || return 1
  ! launchctl print "user/$uid/$label" >/dev/null 2>&1 || return 1
  pid=$(printf '%s\n' "$job" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

fm_remote_herdr_owner_birth() { # <pid>
  local pid=$1 ancestry uid job_pid
  ancestry=$(fm_remote_herdr_process_ancestry "$pid")
  if printf '%s\n' "$ancestry" | fm_remote_herdr_ancestry_has_ssh_origin; then
    printf 'ssh\n'
    return 0
  fi
  if fm_remote_herdr_process_env "$pid" | grep -q -E '^SSH_(CONNECTION|CLIENT|TTY)='; then
    printf 'ssh\n'
    return 0
  fi
  uid=$(id -u 2>/dev/null) || uid=
  if job_pid=$(fm_remote_herdr_gui_job_pid "$uid" "$FM_REMOTE_HERDR_AGENT_LABEL"); then
    if [ "$job_pid" = "$pid" ]; then
      printf 'launchd\n'
      return 0
    fi
    if printf '%s\n' "$ancestry" | fm_remote_herdr_ancestry_has_pid "$job_pid"; then
      printf 'supervised\n'
      return 0
    fi
  fi
  if job_pid=$(fm_remote_herdr_gui_job_pid "$uid" "$FM_REMOTE_HERDR_WORKER_LABEL"); then
    if [ "$job_pid" = "$pid" ] \
      || printf '%s\n' "$ancestry" | fm_remote_herdr_ancestry_has_pid "$job_pid"; then
      printf 'worker\n'
      return 0
    fi
  fi
  printf 'unknown\n'
}

# Reads "<pid> <command>" ancestry lines on stdin and succeeds when one of
# them IS sshd (argv[0] sshd or sshd-session, including the "sshd-session:
# user@notty" process title) or IS herdr's SSH remote attach (argv[0] herdr
# with the whole-word argument remote-client-bridge). Only argv[0] and whole
# arguments are matched: an ancestor whose free-text arguments merely mention
# those words, such as an agent carrying a brief, must not count.
fm_remote_herdr_ancestry_has_ssh_origin() {
  awk '
    {
      argv0 = $2
      sub(/.*\//, "", argv0)
      sub(/:$/, "", argv0)
      if (argv0 == "sshd" || argv0 == "sshd-session") { found = 1 }
      if (argv0 == "herdr") {
        for (i = 3; i <= NF; i++) if ($i == "remote-client-bridge") { found = 1 }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Reads the same ancestry lines and succeeds when <pid> is one of them. The
# kernel maintains that chain, so a same-uid peer cannot place itself under a
# launchd job it does not belong to. Both matchers read to end of input rather
# than exiting on the first hit: a long ancestry (a launch agent's argv can be
# kilobytes) would otherwise leave the producing printf writing to a closed
# pipe and reporting it.
fm_remote_herdr_ancestry_has_pid() { # <pid>
  awk -v want="$1" '$1 == want { found = 1 } END { exit found ? 0 : 1 }'
}

fm_remote_herdr_birth_is_aqua() { # <birth>
  case "$1" in supervised|launchd|worker) return 0 ;; esac
  return 1
}

fm_remote_herdr_birth_is_supervised() { # <birth>
  [ "$1" = supervised ]
}

# --- starting a session-leader server ---------------------------------------
#
# macOS has no setsid(1) and bash cannot call setsid(2), so the one system
# interpreter every supported macOS ships (/usr/bin/perl, with POSIX::setsid)
# performs the fork. The same program runs on Linux, where POSIX::setsid is
# equally portable.
fm_remote_herdr_perl_bin() {
  if [ -x /usr/bin/perl ]; then
    printf '/usr/bin/perl\n'
    return 0
  fi
  command -v perl 2>/dev/null || return 1
}

# supervise: fork a child that becomes a session leader and executes the
#   server, forward the launch agent's stop signals to it, wait for it, and
#   exit with its status so a crash stays a crash for the restart policy.
# detach: the same child, with its standard streams released, and an immediate
#   parent exit after printing the child's pid.
fm_remote_herdr_start_program() {
  cat <<'PERL'
use strict;
use warnings;
use POSIX ();
my $mode = shift @ARGV;
die "fm-remote-herdr-start: need a command to run\n" unless @ARGV > 1;
$| = 1;
my $child = fork();
die "fm-remote-herdr-start: fork failed: $!\n" unless defined $child;
if ($child == 0) {
  POSIX::setsid() != -1 or die "fm-remote-herdr-start: setsid failed: $!\n";
  if ($mode eq 'detach') {
    open(STDIN, '<', '/dev/null') or die "fm-remote-herdr-start: stdin: $!\n";
    open(STDOUT, '>>', '/dev/null') or die "fm-remote-herdr-start: stdout: $!\n";
    open(STDERR, '>>', '/dev/null') or die "fm-remote-herdr-start: stderr: $!\n";
  }
  exec(@ARGV) or die "fm-remote-herdr-start: exec $ARGV[0] failed: $!\n";
}
if ($mode eq 'detach') {
  print "$child\n";
  exit 0;
}
for my $sig (qw(TERM INT HUP QUIT)) {
  $SIG{$sig} = sub { kill($sig, $child) };
}
my $status;
while (1) {
  my $reaped = waitpid($child, 0);
  if ($reaped == $child) { $status = $?; last }
  next if $reaped == -1 && $! == POSIX::EINTR();
  die "fm-remote-herdr-start: waitpid failed: $!\n";
}
exit(128 + ($status & 127)) if $status & 127;
exit($status >> 8);
PERL
}

fm_remote_herdr_supervise_exec() { # <herdr-path> <session>
  local perl
  perl=$(fm_remote_herdr_perl_bin) || return 1
  exec "$perl" -e "$(fm_remote_herdr_start_program)" supervise "$1" server --session "$2"
}

fm_remote_herdr_start_detached() { # <herdr-path> <session>
  local perl pid
  perl=$(fm_remote_herdr_perl_bin) || return 1
  pid=$("$perl" -e "$(fm_remote_herdr_start_program)" detach "$1" server --session "$2") || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}
