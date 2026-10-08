#!/usr/bin/env bash
# fm-fleet-resources.sh - one fact command: memory, load, workers, and worker
# headroom on every host this home can place work on.
#
# Usage: fm-fleet-resources.sh [--local | --mate <id>] [--json | --summary]
#        fm-fleet-resources.sh --help
#
# Reads this home and every secondmate registered in data/secondmates.md (a
# remote mate over ssh, a same-machine mate locally), all at once, through
# bin/fm-host-probe-lib.sh, which owns the probe, the transport and its
# timeouts, and the headroom rule:
#   headroom_workers = floor((avail_gib - FM_PLACE_MIN_FREE_GIB) / FM_PLACE_PER_WORKER_GIB)
# bin/fm-place.sh ranks eligible hosts by that number, and bin/fm-spawn.sh
# refuses a local ship or scout spawn when this host's is below 1.
#
# Output, one line per host (plain, the default):
#   RESOURCES home=<local|mate-id> host=<host> avail_gib=<n> total_gib=<n> load_1m=<x> cpus=<n> load_per_core=<x> workers=<n> worker_rss_gib=<x> headroom_workers=<n>
#   RESOURCES home=<mate-id> host=<host> headroom_workers=unknown error=<why the host could not be read>
#   POLICY floor_gib=<n> per_worker_gib=<n>
# A fact the host could not read prints `?`. workers is the host's live omp
# worker processes and worker_rss_gib their resident memory, across every home
# on that host (bin/fm-host-probe-lib.sh owns how they are counted).
#
#   --local       read only this home's host
#   --mate <id>   read only that registered mate's host
#   --json        {"floor_gib":n,"per_worker_gib":n,"hosts":[{...}]} instead,
#                 with null for an unread fact and an "error" string per host
#   --summary     one line for a digest: every host's free/total memory, load
#                 per core, workers, and headroom, joined by " | "
#
# Exit status: 0 every selected host was read, 3 at least one could not be
# read (its row says why), 2 usage.
#
# FM_HOME, FM_ROOT_OVERRIDE, and FM_DATA_OVERRIDE resolve the home exactly as the
# rest of bin/ does; the FM_PLACE_* settings are documented in
# bin/fm-host-probe-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/secondmates.md"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-host-probe-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-host-probe-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-fleet-resources: %s\n' "$1" >&2
  printf 'usage: fm-fleet-resources.sh [--local | --mate <id>] [--json | --summary]\n' >&2
  exit 2
}

SELECT=
FORMAT=plain
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --local) [ -z "$SELECT" ] || die_usage "choose one of --local or --mate"; SELECT=local; shift ;;
    --mate)
      [ -z "$SELECT" ] || die_usage "choose one of --local or --mate"
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--mate needs a registered secondmate id"
      SELECT=$2
      shift 2
      ;;
    --json) [ "$FORMAT" = plain ] || die_usage "choose one of --json or --summary"; FORMAT=json; shift ;;
    --summary) [ "$FORMAT" = plain ] || die_usage "choose one of --json or --summary"; FORMAT=summary; shift ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
done

fm_host_probe_config_valid || die_usage "$FM_HOST_PROBE_ERROR"

CANDIDATES=$(fm_host_probe_candidates "$FM_HOME" "$REGISTRY")
if [ -n "$SELECT" ]; then
  CANDIDATES=$(printf '%s\n' "$CANDIDATES" | awk -v id="$SELECT" '$1 == id')
  [ -n "$CANDIDATES" ] || die_usage "no secondmate '$SELECT' is registered in $REGISTRY"
fi

DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-resources.XXXXXX") || {
  printf 'fm-fleet-resources: no scratch directory could be created\n' >&2
  exit 2
}
trap 'rm -rf "$DIR"' EXIT
N=$(fm_host_probe_run "$DIR" 0 "$CANDIDATES")

json_str() {  # <text>: a JSON string literal
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

json_num() {  # <value>: the number, or null
  case "$1" in
    ''|*[!0-9.]*|.*|*.) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

shown() {  # <value>: the value, or ? when unread
  case "$1" in ''|unobserved) printf '?' ;; *) printf '%s' "$1" ;; esac
}

RC=0
PLAIN=
SUMMARY=
JSON_HOSTS=
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i + 1))
  read -r id host _home _remote < "$DIR/$i.candidate"
  reason=$(cat "$DIR/$i.reason")
  report=$(cat "$DIR/$i.report")
  label=$host
  [ "$id" = local ] || label="$host ($id)"
  if [ -n "$reason" ]; then
    RC=3
    PLAIN="${PLAIN}RESOURCES home=$id host=$host headroom_workers=unknown error=$reason
"
    SUMMARY="${SUMMARY}${SUMMARY:+ | }$label unreadable: $reason"
    JSON_HOSTS="${JSON_HOSTS}${JSON_HOSTS:+,}{\"home\":$(json_str "$id"),\"host\":$(json_str "$host"),\"avail_gib\":null,\"total_gib\":null,\"load_1m\":null,\"cpus\":null,\"load_per_core\":null,\"workers\":null,\"worker_rss_gib\":null,\"headroom_workers\":null,\"error\":$(json_str "$reason")}"
    continue
  fi
  avail=$(fm_host_probe_field mem_gib "$report")
  total=$(fm_host_probe_field mem_total_gib "$report")
  load=$(fm_host_probe_field load_1m "$report")
  cpus=$(fm_host_probe_field cpus "$report")
  workers=$(fm_host_probe_field workers "$report")
  rss=$(fm_host_probe_field worker_rss_gib "$report")
  per_core=$(fm_host_probe_load_per_core "$load" "$cpus")
  headroom=$(fm_host_probe_headroom "$avail")
  [ -n "$headroom" ] || RC=3
  PLAIN="${PLAIN}RESOURCES home=$id host=$host avail_gib=$(shown "$avail") total_gib=$(shown "$total") load_1m=$(shown "$load") cpus=$(shown "$cpus") load_per_core=$(shown "$per_core") workers=$(shown "$workers") worker_rss_gib=$(shown "$rss") headroom_workers=$(shown "$headroom")
"
  SUMMARY="${SUMMARY}${SUMMARY:+ | }$label $(shown "$avail")/$(shown "$total") GiB free, load $(shown "$per_core")/core, $(shown "$workers") workers using $(shown "$rss") GiB, headroom $(shown "$headroom")"
  JSON_HOSTS="${JSON_HOSTS}${JSON_HOSTS:+,}{\"home\":$(json_str "$id"),\"host\":$(json_str "$host"),\"avail_gib\":$(json_num "$avail"),\"total_gib\":$(json_num "$total"),\"load_1m\":$(json_num "$load"),\"cpus\":$(json_num "$cpus"),\"load_per_core\":$(json_num "$per_core"),\"workers\":$(json_num "$workers"),\"worker_rss_gib\":$(json_num "$rss"),\"headroom_workers\":$(json_num "$headroom"),\"error\":null}"
done

case "$FORMAT" in
  plain)
    printf '%s' "$PLAIN"
    printf 'POLICY floor_gib=%s per_worker_gib=%s\n' "$FM_HOST_PROBE_MIN_FREE_GIB" "$FM_HOST_PROBE_PER_WORKER_GIB"
    ;;
  summary)
    printf 'fleet resources (floor %s GiB, %s GiB per worker): %s\n' \
      "$FM_HOST_PROBE_MIN_FREE_GIB" "$FM_HOST_PROBE_PER_WORKER_GIB" "$SUMMARY"
    ;;
  json)
    printf '{"floor_gib":%s,"per_worker_gib":%s,"hosts":[%s]}\n' \
      "$FM_HOST_PROBE_MIN_FREE_GIB" "$FM_HOST_PROBE_PER_WORKER_GIB" "$JSON_HOSTS"
    ;;
esac
exit "$RC"
