#!/usr/bin/env bash
# fm-place.sh - farm placement decision: which home takes a queued row.
#
# Usage: fm-place.sh [--item <key>] [--handoff]
#        fm-place.sh --help
#
# One decision for one queued ship or scout row. Every candidate - this home
# (the local firstmate home) and every registered secondmate in
# data/secondmates.md - is probed concurrently, and:
#
#   1. Among the candidates that pass every admission gate, the one with the
#      most worker headroom wins (bin/fm-host-probe-lib.sh owns the headroom
#      rule). A tie prefers this home, then registry order.
#   2. When none passes, a refusal names every gate that failed on every
#      candidate.
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
#   memory   available memory on the candidate host, read locally or over ssh,
#            as worker headroom: the host must have room for at least one more
#            worker above FM_PLACE_MIN_FREE_GIB at FM_PLACE_PER_WORKER_GIB each.
#            bin/fm-host-probe-lib.sh owns the rule and both defaults, and the
#            same rule gates a local bin/fm-spawn.sh.
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
#   PLACE home=<local|mate-id> host=<host> <facts> headroom_workers=<n> ranked=<id>:<n>... reason=<what passed>
#   REFUSE <candidate>(<failed gates>); <candidate>(<failed gates>) ...
#
# ranked= lists every eligible candidate with its headroom, best first.
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
# parsing and the real decision table rather than a second code path): the
# FM_PLACE_* probe settings bin/fm-host-probe-lib.sh documents, plus
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
# shellcheck source=bin/fm-host-probe-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-host-probe-lib.sh"

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

fm_host_probe_config_valid || die_usage "$FM_HOST_PROBE_ERROR"

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

# --- gate evaluation --------------------------------------------------------

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
  platform=$(fm_host_probe_field platform "$report")
  case "$platform" in
    ''|unobserved)
      fm_place_note 'platform: the host operating system could not be read'
      return 0
      ;;
  esac

  adm=$(fm_host_probe_field admission_verdict "$report")
  detail=$(fm_host_probe_field admission_detail "$report")
  case "$adm" in
    not-applicable | AVAILABLE) ;;
    '') fm_place_note 'laptop gate: the gate produced no verdict' ;;
    *) fm_place_note "laptop gate: $detail" ;;
  esac

  if [ "$nucleus_gate" = 1 ]; then
    nv=$(fm_host_probe_field nucleus_verdict "$report")
    ne=$(fm_host_probe_field nucleus_exit "$report")
    nd=$(fm_host_probe_field nucleus_detail "$report")
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

  mem=$(fm_host_probe_field mem_gib "$report")
  case "$mem" in
    ''|*[!0-9]*)
      fm_place_note 'memory: available memory could not be read on the host'
      ;;
    *)
      [ "$(fm_host_probe_headroom "$mem")" -ge 1 ] || \
        fm_place_note "memory: ${mem} GiB available leaves no room for a worker above the ${FM_HOST_PROBE_MIN_FREE_GIB} GiB floor at ${FM_HOST_PROBE_PER_WORKER_GIB} GiB per worker"
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

# --- decision ---------------------------------------------------------------

# fm_place_positive_reason <report>: the passing facts behind a placement.
fm_place_positive_reason() {
  local report=$1 platform adm nv mem facts
  platform=$(fm_host_probe_field platform "$report")
  adm=$(fm_host_probe_field admission_verdict "$report")
  nv=$(fm_host_probe_field nucleus_verdict "$report")
  mem=$(fm_host_probe_field mem_gib "$report")
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

# fm_place_decide: probes every candidate at once, then ranks the eligible ones
# by worker headroom. A strictly larger headroom is needed to displace an
# earlier candidate, so a tie keeps this home (always first), then registry
# order.
fm_place_decide() {
  local dir n i id host home remote headroom best=-1 ranked='' tied='' mates=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-place.XXXXXX") || {
    REFUSALS='probe: no scratch directory could be created'
    return 2
  }
  n=$(fm_host_probe_run "$dir" 1 "$(fm_host_probe_candidates "$FM_HOME" "$REGISTRY")")
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    read -r id host home remote < "$dir/$i.candidate"
    [ "$id" = local ] || mates=$((mates + 1))
    REASONS=$(cat "$dir/$i.reason")
    PLACE_REPORT=$(cat "$dir/$i.report")
    if [ -z "$REASONS" ]; then
      if [ "$id" = local ]; then
        fm_place_eval_report 0 "$PLACE_REPORT"
        fm_place_cap_gate
      else
        fm_place_eval_report 1 "$PLACE_REPORT"
      fi
    fi
    if [ -n "$REASONS" ]; then
      REFUSALS="${REFUSALS}${REFUSALS:+; }$id($REASONS)"
      continue
    fi
    headroom=$(fm_host_probe_headroom "$(fm_host_probe_field mem_gib "$PLACE_REPORT")")
    ranked="$ranked $id:$headroom"
    if [ "$headroom" -gt "$best" ]; then
      best=$headroom
      tied=''
      PLACED_HOME=$id
      PLACED_HOST=$host
      PLACED_DETAIL="$(fm_place_positive_reason "$PLACE_REPORT") headroom_workers=$headroom"
      [ "$id" != local ] || \
        PLACED_DETAIL="$PLACED_DETAIL live=${LIVE_COUNTED}/${CAP_VALUE} (alive=${LIVE_ALIVE} unknown=${LIVE_UNKNOWN})"
    elif [ "$headroom" -eq "$best" ]; then
      tied="${tied}${tied:+,}$id"
    fi
  done
  rm -rf "$dir"
  if [ -z "$PLACED_HOME" ]; then
    [ "$mates" -gt 0 ] || REFUSALS="$REFUSALS; no secondmate is registered in $REGISTRY"
    return 3
  fi
  ranked=$(printf '%s' "$ranked" | tr ' ' '\n' | sed '/^$/d' | sort -t: -k2,2nr -s | tr '\n' ',' | sed 's/,$//')
  PLACED_DETAIL="$PLACED_DETAIL ranked=$ranked"
  PLACED_REASON="the eligible host with the most worker headroom ($best)"
  [ -z "$tied" ] || PLACED_REASON="$PLACED_REASON, tied with $tied and kept by tie order (this home first, then registry order)"
  return 0
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
