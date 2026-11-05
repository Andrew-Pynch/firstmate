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
#   cpu_util          CPU utilization from 0 to 1 over a 200 ms sample, read
#                     the way the pinned T3 Code sampler reads it
#                     (bin/vendor/t3code/HostResources.ts): per-CPU counters
#                     twice, 1 - idle delta / (user+nice+sys+idle+irq) delta,
#                     unobserved when the CPU count changed or no time passed.
#                     Linux reads /proc/stat; macOS runs that same os.cpus()
#                     sample in node or bun (on PATH, or ~/.bun/bin/bun where
#                     omp was installed through Bun), and with neither, or one
#                     that does not answer within 2 s, it is unobserved. Every
#                     probe that can sample waits those 200 ms, whichever
#                     scorer placement uses.
#   mem_avail_bytes   available memory in bytes, as the pinned sampler reads it:
#                     MemAvailable on Linux, free + inactive + speculative pages
#                     on macOS, clamped to mem_total_bytes
#   mem_total_bytes   installed memory in bytes
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
#                                 from <dir>/meminfo, <dir>/loadavg,
#                                 <dir>/cpuinfo, and <dir>/stat in Linux procfs
#                                 format on every platform, taking the second
#                                 CPU read from <dir>/stat.next when it exists
#                                 (test seam; remote probes always read their
#                                 own host)
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

cpu_util=
avail_bytes=
total_bytes=
if [ "$platform" = Darwin ] && [ -z "$place_proc" ]; then
  vm=$(vm_stat 2>/dev/null)
  mem=$(printf '%s\n' "$vm" | awk '
    /page size of/ && !size { for (i = 1; i <= NF; i++) if ($i == "of") size = $(i + 1) + 0 }
    /^Pages free/ { free = $3 + 0 }
    /^Pages inactive/ { inactive = $3 + 0 }
    /^Pages speculative/ { speculative = $3 + 0 }
    /^Pages purgeable/ { purgeable = $3 + 0 }
    END { if (size > 0) printf "%d", (free + inactive + speculative + purgeable) * size / 1073741824 }')
  total=$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d", $1 / 1073741824 }')
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')
  cpus=$(sysctl -n hw.ncpu 2>/dev/null)
  avail_bytes=$(printf '%s\n' "$vm" | awk '
    /page size of/ && !size { for (i = 1; i <= NF; i++) if ($i == "of") size = $(i + 1) + 0 }
    /^Pages free:/ && $3 ~ /^[0-9]+\.$/ { free = $3 + 0; f = 1 }
    /^Pages inactive:/ && $3 ~ /^[0-9]+\.$/ { inactive = $3 + 0; n = 1 }
    /^Pages speculative:/ && $3 ~ /^[0-9]+\.$/ { speculative = $3 + 0; s = 1 }
    END { if (size > 0 && f && n && s) printf "%.0f", (free + inactive + speculative) * size }')
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
  runtime=
  for candidate in node bun "$HOME/.bun/bin/bun"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      runtime=$(command -v "$candidate")
      break
    fi
  done
  cpu_file=
  [ -z "$runtime" ] || cpu_file=$(mktemp "${TMPDIR:-/tmp}/fm-cpu-sample.XXXXXX" 2>/dev/null)
  if [ -n "$cpu_file" ]; then
    # Bounded on its own at 2 s, so a runtime that hangs costs only this
    # sample and never the host's other facts. The sample goes to a file and
    # is never waited on: after 2 s it is KILLed, which no wrapper can ignore,
    # and a descendant still holding the file cannot hold this probe open.
    "$runtime" -e 'const o=require("os");const r=()=>{let i=0,t=0;const c=o.cpus();for(const{times:x}of c){i+=x.idle;t+=x.user+x.nice+x.sys+x.idle+x.irq}return[i,t,c.length]};const a=r();setTimeout(()=>{const b=r(),td=b[1]-a[1],id=b[0]-a[0];if(a[2]===b[2]&&td>0&&id>=0)console.log(Math.min(1,Math.max(0,1-id/td)).toFixed(6))},200)' \
      >"$cpu_file" 2>/dev/null </dev/null &
    sampler=$!
    tries=0
    while kill -0 "$sampler" 2>/dev/null && [ "$tries" -lt 20 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    kill -KILL "$sampler" 2>/dev/null
    cpu_util=$(head -1 "$cpu_file" 2>/dev/null)
    rm -f "$cpu_file"
  fi
else
  proc=${place_proc:-/proc}
  mem=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1048576; exit }' "$proc/meminfo" 2>/dev/null)
  total=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576; exit }' "$proc/meminfo" 2>/dev/null)
  load=$(awk '{ print $1; exit }' "$proc/loadavg" 2>/dev/null)
  cpus=$(grep -c '^processor' "$proc/cpuinfo" 2>/dev/null)
  avail_bytes=$(awk '/^MemAvailable:/ && $2 ~ /^[0-9]+$/ && $3 == "kB" { printf "%.0f", $2 * 1024; exit }' "$proc/meminfo" 2>/dev/null)
  total_bytes=$(awk '/^MemTotal:/ && $2 ~ /^[0-9]+$/ && $3 == "kB" { printf "%.0f", $2 * 1024; exit }' "$proc/meminfo" 2>/dev/null)
  cpu_first=$(awk '/^cpu[0-9]/ { idle += $5; total += $2 + $3 + $4 + $5 + $7; n++ } END { if (n) printf "%.0f %.0f %d", idle, total, n }' "$proc/stat" 2>/dev/null)
  if [ -n "$cpu_first" ]; then
    sleep 0.2
    cpu_next=$proc/stat
    [ -z "$place_proc" ] || [ ! -f "$proc/stat.next" ] || cpu_next=$proc/stat.next
    cpu_util=$(awk -v first="$cpu_first" '/^cpu[0-9]/ { idle += $5; total += $2 + $3 + $4 + $5 + $7; n++ }
      END {
        split(first, a, " ")
        td = total - a[2]; id = idle - a[1]
        if (n == a[3] && td > 0 && id >= 0) { u = 1 - id / td; if (u < 0) u = 0; if (u > 1) u = 1; printf "%.6f", u }
      }' "$cpu_next" 2>/dev/null)
  fi
fi
case "$cpus" in ''|*[!0-9]*|0) cpus= ;; esac
case "$cpu_util" in ''|*[!0-9.]*) cpu_util= ;; esac
case "$avail_bytes" in ''|*[!0-9]*) avail_bytes= ;; esac
case "$total_bytes" in ''|*[!0-9]*) total_bytes= ;; esac
if [ -n "$avail_bytes" ] && [ -n "$total_bytes" ]; then
  avail_bytes=$(awk -v a="$avail_bytes" -v t="$total_bytes" 'BEGIN { printf "%.0f", (a + 0 > t + 0) ? t : a }')
fi
printf 'mem_gib=%s\n' "${mem:-unobserved}"
printf 'mem_total_gib=%s\n' "${total:-unobserved}"
printf 'load_1m=%s\n' "${load:-unobserved}"
printf 'cpus=%s\n' "${cpus:-unobserved}"
printf 'cpu_util=%s\n' "${cpu_util:-unobserved}"
printf 'mem_avail_bytes=%s\n' "${avail_bytes:-unobserved}"
printf 'mem_total_bytes=%s\n' "${total_bytes:-unobserved}"

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

# fm_host_probe_now_ms: this home's clock in epoch milliseconds. Bash 5's
# EPOCHREALTIME gives milliseconds; elsewhere (stock macOS Bash 3.2) it is
# whole seconds times 1000.
fm_host_probe_now_ms() {
  local t=${EPOCHREALTIME:-} frac
  t=${t/,/.}
  case "$t" in
    [0-9]*.[0-9][0-9][0-9]*)
      frac=${t#*.}
      printf '%s%s' "${t%%.*}" "${frac:0:3}"
      ;;
    *) printf '%s000' "$(date +%s)" ;;
  esac
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
# it writes <dir>/<N>.candidate, <dir>/<N>.report, and <dir>/<N>.reason; it
# writes <dir>/received, this home's clock in epoch milliseconds when the last
# host answered; and it prints the candidate count. That one receipt time
# dates every report, the way the pinned T3 Code client dates a sample by its
# own receipt rather than by the host's clock: the fleet is read as one unit
# for one decision, so a slow host never ages the others' reports. This home
# never runs the Nucleus gate: the captain's rule binds new remote placement,
# and its own core cap is the local lever.
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
  fm_host_probe_now_ms > "$dir/received"
  printf '%s' "$n"
}
