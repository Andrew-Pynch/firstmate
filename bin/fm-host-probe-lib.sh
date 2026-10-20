#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_HOST_PROBE_* are settings and results for sourcing callers.
# fm-host-probe-lib.sh - the single owner of reading a firstmate host's
# placement facts and of the worker-headroom rule derived from them.
#
# Sourced, never executed. bin/fm-place.sh (the placement decision) and
# bin/fm-fleet-resources.sh (the fact command every other caller runs) both read
# hosts through this file, so the probe, the transport, and the headroom math
# exist exactly once.
#
# The probe snippet runs on the candidate host (locally for this home and for a
# same-machine mate, over ssh for a remote mate) and prints what it observed, one
# key=value per line:
#   platform          uname -s
#   admission_*       the macOS laptop gate's own verdict, exit, and first line
#   nucleus_*         the candidate home's data/nucleus-live-job-check.sh verdict
#                     (only when the caller asks for the Nucleus gate)
#   mem_gib           available memory, whole GiB, rounded down
#   mem_total_gib     installed memory, whole GiB, rounded down
#   load_1m           the 1-minute load average
#   cpus              online logical CPUs
#   workers           live omp worker processes on the host, across every
#                     home there: each process launched with the tracked
#                     .omp/fm-worker-overlay.yml worker overlay, which
#                     bin/fm-spawn.sh passes to every omp worker. Counted from
#                     processes rather than state/*.meta, because a home keeps
#                     records for endpoints that already exited.
#   worker_rss_gib    those processes' summed resident memory, GiB
# A fact the host could not read prints `unobserved`; the snippet never invents
# a value and never reimplements a gate.
#
# Worker headroom (fm_host_probe_headroom) is the one sizing rule:
#   headroom_workers = floor((mem_gib - FM_PLACE_MIN_FREE_GIB) / FM_PLACE_PER_WORKER_GIB)
# clamped at 0. FM_PLACE_MIN_FREE_GIB (default 8) is the memory a host keeps
# free for itself and its supervisor; FM_PLACE_PER_WORKER_GIB (default 3) is
# what one more worker is budgeted to take. Both defaults are measured: big-ron
# froze with 3 GiB available, and omp workers there sit at 0.8 to 4.3 GiB RSS.
#
# Configuration, read when this file is sourced:
#   FM_PLACE_SSH                  transport for remote probes (default ssh)
#   FM_PLACE_SSH_CONNECT_TIMEOUT  ssh connect bound in seconds (default 8)
#   FM_PLACE_HOST_TIMEOUT         whole-probe bound in seconds (default 45)
#   FM_PLACE_MIN_FREE_GIB         memory floor in GiB (default 8)
#   FM_PLACE_PER_WORKER_GIB       memory budget per worker in GiB (default 3)
#   FM_PLACE_PROC_DIR             read memory, load, and CPUs for LOCAL probes
#                                 from <dir>/meminfo, <dir>/loadavg, and
#                                 <dir>/cpuinfo in Linux procfs format on every
#                                 platform (test seam; remote probes always read
#                                 their own host)
# fm_host_probe_config_valid checks them; callers refuse before probing.
#
# Requires bin/fm-timeout-lib.sh and bin/fm-secondmate-registry-lib.sh to be
# sourced first.

FM_HOST_PROBE_SSH="${FM_PLACE_SSH:-ssh}"
FM_HOST_PROBE_SSH_CONNECT_TIMEOUT="${FM_PLACE_SSH_CONNECT_TIMEOUT:-8}"
FM_HOST_PROBE_TIMEOUT="${FM_PLACE_HOST_TIMEOUT:-45}"
FM_HOST_PROBE_MIN_FREE_GIB="${FM_PLACE_MIN_FREE_GIB:-8}"
FM_HOST_PROBE_PER_WORKER_GIB="${FM_PLACE_PER_WORKER_GIB:-3}"
FM_HOST_PROBE_PROC_DIR="${FM_PLACE_PROC_DIR:-}"
FM_HOST_PROBE_ERROR=

# fm_host_probe_config_valid: returns 1 with FM_HOST_PROBE_ERROR set when a
# configured number is not usable.
fm_host_probe_config_valid() {
  FM_HOST_PROBE_ERROR=
  case "$FM_HOST_PROBE_MIN_FREE_GIB" in
    ''|*[!0-9]*) FM_HOST_PROBE_ERROR="FM_PLACE_MIN_FREE_GIB must be a non-negative integer"; return 1 ;;
  esac
  case "$FM_HOST_PROBE_PER_WORKER_GIB" in
    ''|*[!0-9]*|0) FM_HOST_PROBE_ERROR="FM_PLACE_PER_WORKER_GIB must be a positive integer"; return 1 ;;
  esac
  case "$FM_HOST_PROBE_TIMEOUT" in
    ''|*[!0-9]*|0) FM_HOST_PROBE_ERROR="FM_PLACE_HOST_TIMEOUT must be a positive integer"; return 1 ;;
  esac
  return 0
}

# The snippet runs before the tool PATH is trusted, so it widens PATH for the
# macOS laptop's projected helpers and the Docker CLI the Nucleus check needs.
fm_host_probe_snippet() {
  cat <<'SNIPPET'
place_home=${place_home:-}
place_nucleus=${place_nucleus:-1}
place_proc=${place_proc:-}
case ":$PATH:" in
  *":/opt/homebrew/bin:"*) ;;
  *) PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH" ;;
esac
export PATH

platform=$(uname -s 2>/dev/null) || platform=
printf 'platform=%s\n' "${platform:-unobserved}"

if [ "$platform" = Darwin ]; then
  gate=
  if command -v laptop-worker-availability >/dev/null 2>&1; then
    gate=$(command -v laptop-worker-availability)
  else
    for candidate in \
      "$HOME/.local/bin/laptop-worker-availability" \
      "$HOME/personal/personal-agent-monorepo/packages/workstation-config/bin/laptop-worker-availability" \
      "$HOME/work/personal-agent-monorepo/packages/workstation-config/bin/laptop-worker-availability"; do
      [ -x "$candidate" ] && { gate=$candidate; break; }
    done
  fi
  if [ -n "$gate" ]; then
    gate_out=$("$gate" 2>&1)
    gate_rc=$?
    printf 'admission_verdict=%s\n' "$(printf '%s\n' "$gate_out" | sed -n 's/^\([A-Z][A-Z]*\):.*/\1/p' | head -1)"
    printf 'admission_exit=%s\n' "$gate_rc"
    printf 'admission_detail=%s\n' "$(printf '%s\n' "$gate_out" | head -1)"
  else
    printf 'admission_verdict=missing\n'
    printf 'admission_exit=127\n'
    printf 'admission_detail=%s\n' 'the laptop availability gate is not installed on this host'
  fi
else
  printf 'admission_verdict=not-applicable\n'
  printf 'admission_exit=0\n'
  printf 'admission_detail=%s\n' "platform $platform is not a macOS laptop"
fi

if [ "$place_nucleus" = 1 ]; then
  check=$place_home/data/nucleus-live-job-check.sh
  if [ -f "$check" ]; then
    if command -v bash >/dev/null 2>&1; then
      check_out=$(bash "$check" 2>&1)
    else
      check_out=$(sh "$check" 2>&1)
    fi
    check_rc=$?
    check_first=$(printf '%s\n' "$check_out" | head -1)
    printf 'nucleus_verdict=%s\n' "$(printf '%s\n' "$check_first" | sed -n 's/^\([A-Z][A-Z]*\):.*/\1/p')"
    printf 'nucleus_exit=%s\n' "$check_rc"
    printf 'nucleus_detail=%s\n' "$check_first"
  else
    printf 'nucleus_verdict=missing\n'
    printf 'nucleus_exit=127\n'
    printf 'nucleus_detail=%s\n' "no Nucleus admission check at $check"
  fi
fi

if [ "$platform" = Darwin ] && [ -z "$place_proc" ]; then
  mem=$(vm_stat 2>/dev/null | awk '
    /page size of/ && !size { for (i = 1; i <= NF; i++) if ($i == "of") size = $(i + 1) + 0 }
    /^Pages free/ { free = $3 + 0 }
    /^Pages inactive/ { inactive = $3 + 0 }
    /^Pages speculative/ { speculative = $3 + 0 }
    /^Pages purgeable/ { purgeable = $3 + 0 }
    END { if (size > 0) printf "%d", (free + inactive + speculative + purgeable) * size / 1073741824 }')
  total=$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d", $1 / 1073741824 }')
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')
  cpus=$(sysctl -n hw.ncpu 2>/dev/null)
else
  proc=${place_proc:-/proc}
  mem=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1048576; exit }' "$proc/meminfo" 2>/dev/null)
  total=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576; exit }' "$proc/meminfo" 2>/dev/null)
  load=$(awk '{ print $1; exit }' "$proc/loadavg" 2>/dev/null)
  cpus=$(grep -c '^processor' "$proc/cpuinfo" 2>/dev/null)
fi
case "$cpus" in ''|*[!0-9]*|0) cpus= ;; esac
printf 'mem_gib=%s\n' "${mem:-unobserved}"
printf 'mem_total_gib=%s\n' "${total:-unobserved}"
printf 'load_1m=%s\n' "${load:-unobserved}"
printf 'cpus=%s\n' "${cpus:-unobserved}"

workers=$(ps -A -o rss= -o args= 2>/dev/null | awk '
  BEGIN { overlay = "/fm-worker-overlay.yml" }
  {
    for (i = 2; i < NF; i++) {
      f = $(i + 1)
      if ($i == "--config" && length(f) >= length(overlay) && substr(f, length(f) - length(overlay) + 1) == overlay) {
        n++
        rss += $1
        break
      }
    }
  }
  END { printf "%d %.1f", n, rss / 1048576 }')
printf 'workers=%s\n' "${workers%% *}"
printf 'worker_rss_gib=%s\n' "${workers##* }"
SNIPPET
}

# fm_host_probe_local <home> <nucleus 0|1>: prints the report on stdout.
#
# The snippet travels as a command argument, never on stdin: bin/fm-timeout-lib.sh
# runs the bounded command as a background job, so a here-document attached to
# that call is not the child's stdin.
fm_host_probe_local() {
  local snippet
  snippet=$(fm_host_probe_snippet)
  place_home=$1 place_nucleus=$2 place_proc=$FM_HOST_PROBE_PROC_DIR \
    fm_run_timed "$FM_HOST_PROBE_TIMEOUT" sh -c "$snippet" </dev/null
}

# fm_host_probe_remote <host> <home> <nucleus 0|1>: prints the report on
# stdout; transport failures land on stderr for the caller's refusal reason.
fm_host_probe_remote() {
  local host=$1 home=$2 nucleus=$3 snippet
  snippet=$(fm_host_probe_snippet)
  fm_run_timed "$FM_HOST_PROBE_TIMEOUT" "$FM_HOST_PROBE_SSH" \
    -o BatchMode=yes -o "ConnectTimeout=$FM_HOST_PROBE_SSH_CONNECT_TIMEOUT" \
    "$host" "place_home=$home; place_nucleus=$nucleus; export place_home place_nucleus
$snippet" </dev/null
}

fm_host_probe_field() {  # <key> <report>
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1
}

# fm_host_probe_headroom <mem_gib>: prints the worker headroom, or nothing when
# the memory reading is not a number.
fm_host_probe_headroom() {
  local mem=$1
  case "$mem" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$mem" -le "$FM_HOST_PROBE_MIN_FREE_GIB" ]; then
    printf '0'
  else
    printf '%s' $(((mem - FM_HOST_PROBE_MIN_FREE_GIB) / FM_HOST_PROBE_PER_WORKER_GIB))
  fi
}

# fm_host_probe_load_per_core <load_1m> <cpus>: two-decimal load per CPU, or
# nothing when either reading is missing.
fm_host_probe_load_per_core() {
  case "$1" in ''|unobserved) return 0 ;; esac
  case "$2" in ''|*[!0-9]*|0) return 0 ;; esac
  awk -v l="$1" -v c="$2" 'BEGIN { if (l ~ /^[0-9.]+$/) printf "%.2f", l / c }'
}

fm_host_probe_this_host() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'this-home'
}

# fm_host_probe_candidates <home> <registry>: prints "<id> <host> <home> <remote>"
# for this home (id `local`) and then every registered mate in registry order.
fm_host_probe_candidates() {
  local home=$1 reg=$2 line
  printf 'local %s %s 0\n' "$(fm_host_probe_this_host)" "$home"
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*) ;;
      *) continue ;;
    esac
    secondmate_registry_parse_line "$line" || continue
    printf '%s %s %s %s\n' "$SECONDMATE_REGISTRY_ID" "${SECONDMATE_REGISTRY_HOST:-same-machine}" \
      "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_REMOTE"
  done < "$reg"
}

# _fm_host_probe_one <prefix> <id> <host> <home> <remote> <nucleus>: writes
# <prefix>.report and <prefix>.reason (empty when the host was read).
_fm_host_probe_one() {
  local prefix=$1 id=$2 host=$3 home=$4 remote=$5 nucleus=$6 report rc reason=
  : > "$prefix.report"
  if [ "$id" != local ]; then
    case "$home" in
      /*) ;;
      *) reason='registry: the recorded home path is not absolute' ;;
    esac
    case "$home" in
      *[!A-Za-z0-9._/-]*) reason=${reason:-'registry: the recorded home path cannot be quoted for the host'} ;;
    esac
  fi
  if [ -z "$reason" ]; then
    if [ "$remote" = 1 ]; then
      report=$(fm_host_probe_remote "$host" "$home" "$nucleus" 2>"$prefix.err")
    else
      report=$(fm_host_probe_local "$home" "$nucleus" 2>"$prefix.err")
    fi
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$report" ]; then
      if [ "$id" = local ]; then
        if [ -s "$prefix.err" ]; then
          reason="probe: $(head -1 "$prefix.err")"
        else
          reason="probe: this home could not be read (exit $rc)"
        fi
      elif [ -s "$prefix.err" ]; then
        reason="reach: $(head -1 "$prefix.err")"
      elif [ "$rc" -eq 124 ]; then
        reason="reach: the host did not answer within ${FM_HOST_PROBE_TIMEOUT}s, so its state is unknown"
      else
        reason="reach: the host could not be observed (probe exit $rc), so its state is unknown"
      fi
    else
      printf '%s\n' "$report" > "$prefix.report"
    fi
  fi
  printf '%s' "$reason" > "$prefix.reason"
}

# fm_host_probe_run <dir> <mate-nucleus 0|1> <candidates>: probes every
# candidate line (fm_host_probe_candidates format) concurrently, so the whole
# read is bounded by one host's timeout rather than their sum. For the Nth line
# it writes <dir>/<N>.candidate, <dir>/<N>.report, and <dir>/<N>.reason, and
# prints the candidate count. This home never runs the Nucleus gate: the
# captain's rule binds new remote placement, and its own core cap is the local
# lever.
fm_host_probe_run() {
  local dir=$1 nucleus=$2 candidates=$3 n=0 id host home remote gate pid
  local -a pids=()
  while IFS=' ' read -r id host home remote; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    printf '%s %s %s %s\n' "$id" "$host" "$home" "$remote" > "$dir/$n.candidate"
    gate=$nucleus
    [ "$id" != local ] || gate=0
    _fm_host_probe_one "$dir/$n" "$id" "$host" "$home" "$remote" "$gate" &
    pids+=("$!")
  done <<EOF
$candidates
EOF
  for pid in "${pids[@]+"${pids[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done
  printf '%s' "$n"
}
