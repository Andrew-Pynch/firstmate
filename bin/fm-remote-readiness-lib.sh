#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - what a remote second-mate launch is allowed to
# proceed against: the host readiness gate sequence, and the verified worker
# runtimes a remote second mate may run on.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#   fm_remote_secondmate_harness_supported <harness>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# True when <harness> is a verified worker runtime a remote second mate may run
# on. ONE owner for the parent-side spawn gate (bin/fm-spawn.sh) and the
# host-local launch and relaunch gates (bin/fm-remote-secondmate-control.sh),
# so a runtime can never be accepted on one side of the transport and refused
# on the other.
#
# This is the secondmate-capable subset of the verified adapters: muse, gemini,
# and rovo carry no primary supervision protocol and bin/fm-spawn.sh refuses
# them for every secondmate, local or remote. omp additionally depends on its
# own cwd-only extension auto-discovery for a secondmate's supervision, which
# bin/fm-spawn.sh proves per launch rather than assuming here.
fm_remote_secondmate_harness_supported() { # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) return 0 ;;
  esac
  return 1
}
