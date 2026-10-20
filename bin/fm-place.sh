#!/usr/bin/env bash
# fm-place.sh - farm placement decision: which home takes a queued row.
#
# Usage: fm-place.sh [--item <key>] [--handoff]
#        fm-place.sh --help
#
# One decision for one queued ship or scout row, in this order:
#
#   1. This home (the local firstmate home) when it is under the captain's
#      live-worker cap and above the memory floor.
#   2. The first registered secondmate, in data/secondmates.md order, whose host
#      passes every admission gate.
#   3. A refusal naming every gate that failed on every candidate.
#
# The captain's shape: the primary coordinates, idle machines take work, and
# eligibility gates the choice. The captain never names a host, so no gate here
# is optional and UNKNOWN is not a softer pass: a gate that could not be
# observed refuses exactly like a gate that failed, because admitting work onto
# a host whose state is unknown is choosing to start work nobody can supervise.
#
# Gate owners, reused rather than reimplemented:
#
#   cap      the captain's own line in data/captain.md, the single owner of the
#            live-worker ceiling: "maximum <N> live workers". A cap that cannot
#            be read refuses the local home; there is no built-in fallback
#            number, because a stale default admits work the captain did not
#            authorize. The live-worker count comes from the recorded tasks in
#            state/*.meta and bin/fm-backend.sh's recovery-grade endpoint state,
#            never from a status-log line, which records events rather than
#            current state. A non-live endpoint verdict counts toward the cap
#            unless it is confidently dead, so an endpoint that could not be
#            observed can only move work to another machine, never overfill this
#            one.
#   memory   available memory on the candidate host, read locally or over ssh.
#            FM_PLACE_MIN_FREE_GIB (default 4) is the placement floor; the
#            captain raised the cap on 2026-09-15 with 20 GiB free, so 4 GiB is
#            a conservative single-worker floor, not a derived ratio.
#   laptop   packages/workstation-config/bin/laptop-worker-availability in
#            personal-agent-monorepo owns lid, power, and household occupancy on
#            the two macOS laptops, including Cassidy's active-use gate on
#            tiny-tina. Only exit 0 (AVAILABLE) admits work. The gate is not
#            applicable to a host whose own platform is not Darwin; that
#            distinction is read from the gate's own platform fact.
#   nucleus  the candidate home's own data/nucleus-live-job-check.sh, run on the
#            candidate host, owns simulation admission. Only IDLE and exit 0
#            admit work. Applied to remote mates only: the captain's rule binds
#            new remote placement, and this home's own core cap is the local
#            lever.
#
# A registered mate whose host cannot be reached reports unknown and is refused
# with the transport error; that is also the state of tiny-tina, which this home
# has no inbound route to, so she is never placed on and never silently assumed
# usable.
#
# Output is one line:
#
#   PLACE home=<local|mate-id> host=<host> <facts> reason=<what passed>
#   REFUSE <candidate>(<failed gates>); <candidate>(<failed gates>) ...
#
# Exit status: 0 placed, 3 refused (every gate reason is printed), 2 usage or a
# missing prerequisite to decide.
#
# --handoff applies the decision for a mate: it moves the queued row to that
# mate's own backlog through bin/fm-backlog-handoff.sh, which owns the move and
# refuses anything that is not a Queued row, then sends the placement reason to
# that mate through bin/fm-send.sh. It never starts work itself. A local
# decision has nothing to hand off - dispatch it locally through
# bin/fm-spawn.sh - and --handoff prints that instead of moving anything.
#
# --item <key> validates the row first: it must exist and be Queued, and its
# recorded kind must be ship or scout, the two kinds this policy places. An In
# flight, Done, held, or non-ship/scout row is refused by name before any host
# is probed.
#
# Test seams (each one is an external observation, so tests drive the real
# parsing and the real decision table rather than a second code path):
#   FM_PLACE_SSH                  transport for remote probes (default ssh)
#   FM_PLACE_SSH_CONNECT_TIMEOUT  ssh connect bound in seconds (default 8)
#   FM_PLACE_HOST_TIMEOUT         whole-probe bound in seconds (default 45)
#   FM_PLACE_MIN_FREE_GIB         memory floor in GiB (default 4)
#   FM_PLACE_CAPTAIN_FILE         captain preference file owning the cap
#   FM_PLACE_STATE_DIR            state directory holding task metadata
# FM_ROOT_OVERRIDE, FM_HOME, FM_DATA_OVERRIDE and FM_STATE_OVERRIDE resolve the
# home exactly as the rest of bin/ does.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CAPTAIN_FILE="${FM_PLACE_CAPTAIN_FILE:-$DATA/captain.md}"
REGISTRY="$DATA/secondmates.md"
LOCAL_STATE="${FM_PLACE_STATE_DIR:-$STATE}"
SSH_BIN="${FM_PLACE_SSH:-ssh}"
SSH_CONNECT_TIMEOUT="${FM_PLACE_SSH_CONNECT_TIMEOUT:-8}"
HOST_TIMEOUT="${FM_PLACE_HOST_TIMEOUT:-45}"
MIN_FREE_GIB="${FM_PLACE_MIN_FREE_GIB:-4}"
HANDOFF_CMD="$SCRIPT_DIR/fm-backlog-handoff.sh"
SEND_CMD="$SCRIPT_DIR/fm-send.sh"
TASKS_AXI="$SCRIPT_DIR/fm-tasks-axi.sh"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

ITEM=
HANDOFF=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-place: %s\n' "$1" >&2
  printf 'usage: fm-place.sh [--item <key>] [--handoff]\n' >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --item)
      [ "$#" -ge 2 ] || die_usage "--item needs a backlog key"
      ITEM=$2
      shift 2
      ;;
    --item=*)
      ITEM=${1#--item=}
      shift
      ;;
    --handoff)
      HANDOFF=1
      shift
      ;;
    *)
      die_usage "unexpected argument: $1"
      ;;
  esac
done

case "$MIN_FREE_GIB" in
  ''|*[!0-9]*) die_usage "FM_PLACE_MIN_FREE_GIB must be a non-negative integer" ;;
esac
case "$HOST_TIMEOUT" in
  ''|*[!0-9]*|0) die_usage "FM_PLACE_HOST_TIMEOUT must be a positive integer" ;;
esac

# --- the row under consideration -------------------------------------------

ITEM_KIND=
ITEM_TITLE=
ITEM_REFUSAL=

# fm_place_load_item: read the row's state and kind from tasks-axi, the single
# owner of the backlog format. Refuses a row this policy does not place, naming
# what it found. On refusal sets ITEM_REFUSAL and returns 1.
fm_place_load_item() {
  local show state kind title
  if ! fm_tasks_axi_compatible >/dev/null 2>&1; then
    ITEM_REFUSAL='the backlog row could not be read: a compatible tasks-axi is required'
    return 1
  fi
  if ! show=$("$TASKS_AXI" show "$ITEM" 2>&1); then
    ITEM_REFUSAL="row $ITEM was not found in this home's backlog"
    return 1
  fi
  state=$(printf '%s\n' "$show" | sed -n 's/^  state:[[:space:]]*//p' | head -1)
  kind=$(printf '%s\n' "$show" | sed -n 's/^  kind:[[:space:]]*//p' | head -1)
  title=$(printf '%s\n' "$show" | sed -n 's/^  title:[[:space:]]*//p' | head -1)
  case "$state" in
    queued) ;;
    '')
      ITEM_REFUSAL="row $ITEM has no readable state in this home's backlog"
      return 1
      ;;
    *)
      ITEM_REFUSAL="row $ITEM is $state, and only a queued row is placed"
      return 1
      ;;
  esac
  case "$kind" in
    ship|scout) ;;
    ''|-)
      ITEM_REFUSAL="row $ITEM records no kind, and only ship and scout rows are placed"
      return 1
      ;;
    *)
      ITEM_REFUSAL="row $ITEM is kind $kind, and only ship and scout rows are placed"
      return 1
      ;;
  esac

  ITEM_KIND=$kind
  ITEM_TITLE=$title
  return 0
}

# --- host probe -------------------------------------------------------------

# The probe snippet runs on the candidate host (locally for this home, over ssh
# for a mate) and reports what it observed, one key=value per line. It runs the
# gate owners and prints each one's own verdict; it never reimplements a gate
# and never invents a verdict it could not read. It runs before the tool PATH is
# trusted, so it widens PATH for the macOS laptop's projected helpers and the
# Docker CLI the Nucleus check needs.
print_probe_snippet() {
  cat <<'SNIPPET'
place_home=${place_home:-}
place_nucleus=${place_nucleus:-1}
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

case "$platform" in
  Darwin)
    mem=$(vm_stat 2>/dev/null | awk '
      /page size of/ && !size { for (i = 1; i <= NF; i++) if ($i == "of") size = $(i + 1) + 0 }
      /^Pages free/ { free = $3 + 0 }
      /^Pages inactive/ { inactive = $3 + 0 }
      /^Pages speculative/ { speculative = $3 + 0 }
      /^Pages purgeable/ { purgeable = $3 + 0 }
      END { if (size > 0) printf "%d", (free + inactive + speculative + purgeable) * size / 1073741824 }')
    ;;
  *)
    mem=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1048576; exit }' /proc/meminfo 2>/dev/null)
    ;;
esac
printf 'mem_gib=%s\n' "${mem:-unobserved}"
SNIPPET
}

# fm_place_probe_local <home> <nucleus 0|1>: prints the report on stdout.
#
# The snippet travels as a command argument, never on stdin: bin/fm-timeout-lib.sh
# runs the bounded command as a background job, so a here-document attached to
# that call is not the child's stdin.
fm_place_probe_local() {
  local snippet
  snippet=$(print_probe_snippet)
  place_home=$1
  place_nucleus=$2
  export place_home place_nucleus
  fm_run_timed "$HOST_TIMEOUT" sh -c "$snippet" </dev/null
}

# fm_place_probe_remote <host> <home> <nucleus 0|1>: prints the report on
# stdout; transport failures land on stderr for the caller's refusal reason.
fm_place_probe_remote() {
  local host=$1 home=$2 nucleus=$3 snippet
  snippet=$(print_probe_snippet)
  fm_run_timed "$HOST_TIMEOUT" "$SSH_BIN" \
    -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" \
    "$host" "place_home=$home; place_nucleus=$nucleus; export place_home place_nucleus
$snippet" </dev/null
}

# --- gate evaluation --------------------------------------------------------

fm_place_field() {  # <key> <report>
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1
}

# REASONS holds the gate failures of the candidate under evaluation, joined by
# "; " and empty when it passes. It is a global rather than a return value
# because the candidate's probe report is published beside it, and a command
# substitution would evaluate the candidate in a subshell that discards both.
REASONS=
fm_place_note() {  # <reason>
  REASONS="${REASONS}${REASONS:+; }$1"
}

# fm_place_eval_report <nucleus 0|1> <report>: sets REASONS from the report's own
# verdicts. No gate is inferred from another gate's verdict.
fm_place_eval_report() {
  local nucleus_gate=$1 report=$2 platform adm detail nv ne nd mem
  REASONS=
  platform=$(fm_place_field platform "$report")
  case "$platform" in
    ''|unobserved)
      fm_place_note 'platform: the host operating system could not be read'
      return 0
      ;;
  esac

  adm=$(fm_place_field admission_verdict "$report")
  detail=$(fm_place_field admission_detail "$report")
  case "$adm" in
    not-applicable | AVAILABLE) ;;
    '') fm_place_note 'laptop gate: the gate produced no verdict' ;;
    *) fm_place_note "laptop gate: $detail" ;;
  esac

  if [ "$nucleus_gate" = 1 ]; then
    nv=$(fm_place_field nucleus_verdict "$report")
    ne=$(fm_place_field nucleus_exit "$report")
    nd=$(fm_place_field nucleus_detail "$report")
    case "$nv" in
      IDLE)
        case "$ne" in
          0) ;;
          '') fm_place_note 'nucleus: the admission check reported IDLE without an exit status' ;;
          *) fm_place_note "nucleus: the admission check reported IDLE but exited $ne" ;;
        esac
        ;;
      '') fm_place_note 'nucleus: the admission check produced no verdict' ;;
      *)
        nd=${nd#"$nv: "}
        fm_place_note "nucleus: $nv${nd:+: $nd}"
        ;;
    esac
  fi

  mem=$(fm_place_field mem_gib "$report")
  case "$mem" in
    ''|*[!0-9]*)
      fm_place_note 'memory: available memory could not be read on the host'
      ;;
    *)
      [ "$mem" -ge "$MIN_FREE_GIB" ] || \
        fm_place_note "memory: ${mem} GiB available, below the ${MIN_FREE_GIB} GiB placement floor"
      ;;
  esac
}

# --- local capacity ---------------------------------------------------------

fm_place_cap() {  # prints the captain's live-worker ceiling, or nothing
  [ -f "$CAPTAIN_FILE" ] || return 0
  sed -n 's/.*maximum[[:space:]][[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*live[[:space:]][[:space:]]*worker.*/\1/p' \
    "$CAPTAIN_FILE" | head -1
}

# fm_place_live_workers: prints "<counted> <alive> <unknown>" for this home.
fm_place_live_workers() {
  local meta kind backend target verdict counted=0 alive=0 unknown=0
  for meta in "$LOCAL_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict=unknown
    case "$verdict" in
      alive)
        alive=$((alive + 1))
        counted=$((counted + 1))
        ;;
      dead) ;;
      *)
        unknown=$((unknown + 1))
        counted=$((counted + 1))
        ;;
    esac
  done
  printf '%s %s %s' "$counted" "$alive" "$unknown"
}

# fm_place_cap_gate: adds the local capacity reason to REASONS when this home may
# not take more work, and publishes the cap and count facts a placement reports.
fm_place_cap_gate() {
  local counts
  CAP_VALUE=$(fm_place_cap)
  case "$CAP_VALUE" in
    ''|*[!0-9]*)
      fm_place_note "cap: no \"maximum <N> live workers\" line could be read from $CAPTAIN_FILE"
      return 0
      ;;
  esac
  counts=$(fm_place_live_workers)
  LIVE_COUNTED=${counts%% *}
  LIVE_ALIVE=${counts#* }
  LIVE_ALIVE=${LIVE_ALIVE%% *}
  LIVE_UNKNOWN=${counts##* }
  if [ "$LIVE_COUNTED" -ge "$CAP_VALUE" ]; then
    fm_place_note "cap: $LIVE_COUNTED live workers recorded against the $CAP_VALUE-worker ceiling (alive=$LIVE_ALIVE unknown=$LIVE_UNKNOWN)"
  fi
}

# fm_place_local_reasons: sets REASONS to every reason this home may not take
# work, and PLACE_REPORT to its probe report when the probe succeeded.
fm_place_local_reasons() {
  local report rc errfile
  REASONS=
  PLACE_REPORT=
  CAP_VALUE=
  LIVE_COUNTED=0
  LIVE_ALIVE=0
  LIVE_UNKNOWN=0
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-place-probe.XXXXXX") || errfile=/dev/null
  report=$(fm_place_probe_local "$FM_HOME" 0 2>"$errfile")
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$report" ]; then
    if [ -s "$errfile" ]; then
      REASONS="probe: $(head -1 "$errfile")"
    else
      REASONS="probe: this home could not be read (exit $rc)"
    fi
    rm -f "$errfile"
    return 0
  fi
  rm -f "$errfile"
  PLACE_REPORT=$report
  fm_place_eval_report 0 "$report"
  fm_place_cap_gate
}

# --- mate candidates --------------------------------------------------------

fm_place_mate_records() {  # prints "<id> <host> <home> <remote>" per registry record
  local reg=$1 line id
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*) ;;
      *) continue ;;
    esac
    secondmate_registry_parse_line "$line" || continue
    id=$SECONDMATE_REGISTRY_ID
    printf '%s %s %s %s\n' "$id" "${SECONDMATE_REGISTRY_HOST:-same-machine}" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_REMOTE"
  done < "$reg"
}

# fm_place_remote_reasons <host> <home> <nucleus 0|1> <remote 0|1>: sets REASONS
# to every reason the candidate may not take work, and PLACE_REPORT to its probe
# report when the probe succeeded.
fm_place_remote_reasons() {
  local host=$1 home=$2 nucleus=$3 remote=$4 report rc errfile
  REASONS=
  PLACE_REPORT=
  case "$home" in
    /*) ;;
    *)
      REASONS='registry: the recorded home path is not absolute'
      return 0
      ;;
  esac
  case "$home" in
    *[!A-Za-z0-9._/-]*)
      REASONS='registry: the recorded home path cannot be quoted for the host'
      return 0
      ;;
  esac
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-place-probe.XXXXXX") || errfile=/dev/null
  if [ "$remote" = 1 ]; then
    report=$(fm_place_probe_remote "$host" "$home" "$nucleus" 2>"$errfile")
  else
    report=$(fm_place_probe_local "$home" "$nucleus" 2>"$errfile")
  fi
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$report" ]; then
    if [ -s "$errfile" ]; then
      REASONS="reach: $(head -1 "$errfile")"
    elif [ "$rc" -eq 124 ]; then
      REASONS="reach: the host did not answer within ${HOST_TIMEOUT}s, so its state is unknown"
    else
      REASONS="reach: the host could not be observed (probe exit $rc), so its state is unknown"
    fi
    rm -f "$errfile"
    return 0
  fi
  rm -f "$errfile"
  PLACE_REPORT=$report
  fm_place_eval_report "$nucleus" "$report"
}

# --- decision ---------------------------------------------------------------

# fm_place_positive_reason <report>: the passing facts behind a placement.
fm_place_positive_reason() {
  local report=$1 platform adm nv mem facts
  platform=$(fm_place_field platform "$report")
  adm=$(fm_place_field admission_verdict "$report")
  nv=$(fm_place_field nucleus_verdict "$report")
  mem=$(fm_place_field mem_gib "$report")
  facts="platform=$platform"
  case "$adm" in
    AVAILABLE) facts="$facts laptop=available" ;;
    *) facts="$facts laptop=not-applicable" ;;
  esac
  [ "$nv" != IDLE ] || facts="$facts nucleus=idle"
  facts="$facts free_gib=$mem"
  printf '%s' "$facts"
}

PLACED_HOME=
PLACED_HOST=
PLACED_REASON=
PLACED_DETAIL=
REFUSALS=
PLACE_REPORT=
CAP_VALUE=
LIVE_COUNTED=0
LIVE_ALIVE=0
LIVE_UNKNOWN=0

fm_place_decide() {
  local records id host home remote
  fm_place_local_reasons
  if [ -z "$REASONS" ]; then
    PLACED_HOME=local
    PLACED_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'this-home')
    PLACED_REASON="under the live-worker cap with memory available"
    PLACED_DETAIL="$(fm_place_positive_reason "$PLACE_REPORT") live=${LIVE_COUNTED}/${CAP_VALUE} (alive=${LIVE_ALIVE} unknown=${LIVE_UNKNOWN})"
    return 0
  fi
  REFUSALS="local($REASONS)"

  records=$(fm_place_mate_records "$REGISTRY")
  if [ -z "$records" ]; then
    REFUSALS="$REFUSALS; no secondmate is registered in $REGISTRY"
    return 3
  fi
  while IFS=' ' read -r id host home remote; do
    [ -n "$id" ] || continue
    fm_place_remote_reasons "$host" "$home" 1 "$remote"
    if [ -z "$REASONS" ]; then
      PLACED_HOME=$id
      PLACED_HOST=$host
      PLACED_REASON="the first registered mate whose host passed every admission gate"
      PLACED_DETAIL=$(fm_place_positive_reason "$PLACE_REPORT")
      return 0
    fi
    REFUSALS="$REFUSALS; $id($REASONS)"
  done <<EOF
$records
EOF
  return 3
}

# --- handoff ----------------------------------------------------------------

# fm_place_delivery_id <row key>: the placement instruction's fire-and-forget
# delivery id, derived from the row so a repeated handoff of the same row reuses
# one id and the mate's enqueue stays idempotent. bin/fm-send.sh requires
# exactly 16 lowercase hex characters.
fm_place_delivery_id() {
  local hex=
  if command -v sha256sum >/dev/null 2>&1; then
    hex=$(printf 'fm-place:%s' "$1" | sha256sum | cut -c1-16)
  elif command -v shasum >/dev/null 2>&1; then
    hex=$(printf 'fm-place:%s' "$1" | shasum -a 256 | cut -c1-16)
  fi
  case "$hex" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf '%s' "$hex"
      ;;
    *) return 1 ;;
  esac
}

fm_place_handoff() {
  local message out delivery_id
  if [ "$PLACED_HOME" = local ]; then
    printf 'PLACE home=local host=%s %s reason=%s handoff=none (a local row is dispatched here with bin/fm-spawn.sh)\n' \
      "$PLACED_HOST" "$PLACED_DETAIL" "$PLACED_REASON"
    return 0
  fi
  [ -n "$ITEM" ] || die_usage "--handoff needs --item so there is a row to move"
  if ! out=$("$HANDOFF_CMD" "$PLACED_HOME" "$ITEM" 2>&1); then
    printf 'REFUSE handoff to %s failed: %s\n' "$PLACED_HOME" "$(printf '%s\n' "$out" | tail -1)"
    return 3
  fi
  if ! delivery_id=$(fm_place_delivery_id "$ITEM"); then
    printf 'REFUSE row %s moved to %s, but no sha256 tool is available to derive the placement instruction id\n' \
      "$ITEM" "$PLACED_HOME"
    return 3
  fi
  message="Farm placement sent $ITEM ($ITEM_KIND) here: $PLACED_REASON."
  if [ -n "$ITEM_TITLE" ]; then
    message="Farm placement sent $ITEM here: $ITEM_TITLE. Placement reason: $PLACED_REASON."
  fi
  if ! FM_HOME="$FM_HOME" "$SEND_CMD" "$PLACED_HOME" --fire-and-forget "$delivery_id" "$message" >/dev/null 2>&1; then
    printf 'REFUSE row %s moved to %s, but the placement instruction could not be delivered\n' "$ITEM" "$PLACED_HOME"
    return 3
  fi
  printf 'PLACE home=%s host=%s %s reason=%s handoff=moved row %s to %s and instructed it\n' \
    "$PLACED_HOME" "$PLACED_HOST" "$PLACED_DETAIL" "$PLACED_REASON" "$ITEM" "$PLACED_HOME"
  return 0
}

# --- main -------------------------------------------------------------------

if [ -n "$ITEM" ]; then
  if ! fm_place_load_item; then
    printf 'REFUSE %s\n' "$ITEM_REFUSAL"
    exit 3
  fi
fi

if fm_place_decide; then
  :
else
  rc=$?
  printf 'REFUSE %s\n' "$REFUSALS"
  exit "$rc"
fi

if [ "$HANDOFF" -eq 1 ]; then
  if fm_place_handoff; then
    exit 0
  fi
  exit 3
fi

printf 'PLACE home=%s host=%s %s reason=%s\n' \
  "$PLACED_HOME" "$PLACED_HOST" "$PLACED_DETAIL" "$PLACED_REASON"
