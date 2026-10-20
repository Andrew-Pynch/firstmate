#!/usr/bin/env bash
# Default-on live guard for the tracked omp worker posture overlay's advisor pin.
#
# What a worker session's advisor resolves to is a fact only the installed omp
# can answer: `--config` is one config layer among several, and omp resolves an
# unset `advisor` role through its `slow` priority chain, a premium reasoning
# model. No fixture can prove which layer wins, so this guard gives the live
# agent profile a temporary, higher-priority host overlay with a deliberately
# premium advisor, then asserts the tracked worker overlay beats it twice:
# through omp's own config dump and through a real session's `/advisor status`
# report. The live profile supplies only authentication and is never written.
# It fails naming omp and the reported text instead of degrading quietly.
#
# The first half needs no model and no credential, so it always runs. The second
# half is a live resolution, which omp only performs for a provider whose
# credential is present, so it runs where the pinned provider is authenticated
# and capability-skips by name where it is not. Neither half spends a token.
#
# Run it after every omp upgrade and before trusting a refreshed advisor posture:
# the layer precedence, the rpc builtin dispatch, and the credential gate are all
# vendor surfaces, not Firstmate contracts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/.omp/fm-worker-overlay.yml"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_OMP_WORKER_OVERLAY_LIVE_E2E omp jq

[ -f "$OVERLAY" ] || fail "the tracked worker posture overlay is missing at $OVERLAY"

# The pin this guard exists to defend. A deliberate change to the worker advisor
# updates this constant in the same commit.
EXPECTED_ADVISOR=deepseek/deepseek-v4-flash
EXPECTED_PROVIDER=${EXPECTED_ADVISOR%%/*}
# The posture of the host profile the guard stands in for: the premium advisor
# role the overlay has to beat, and the premium model omp resolves an unset
# advisor role to through its `slow` chain.
CONFLICT_ADVISOR=xai-oauth/grok-4.6:high
CONFLICT_SLOW=openai-codex/gpt-5.6-sol:high

OMP_VERSION=$(omp --version 2>/dev/null || true)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-worker-overlay.XXXXXX")
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

HOST_OVERLAY="$TMP_ROOT/host.yml"
printf 'advisor:\n  enabled: true\nmodelRoles:\n  advisor: %s\n  slow: %s\n' \
  "$CONFLICT_ADVISOR" "$CONFLICT_SLOW" > "$HOST_OVERLAY"

# The advisor role omp resolves from the config layers alone. `config get`
# reports the merged record without calling a model or consulting a credential,
# so this half is deterministic on any machine.
layer_advisor() { # <worker overlay, empty for host layer only>
  (
    cd "$TMP_ROOT" &&
      PI_CONFIG_FILES="$HOST_OVERLAY${1:+:$1}" omp config get modelRoles --json 2>/dev/null
  ) | jq -r '.value.advisor // ""'
}

host_layer=$(layer_advisor '')
[ "$host_layer" = "$CONFLICT_ADVISOR" ] \
  || fail "omp $OMP_VERSION did not read the guard's isolated host profile, so the pin cannot be shown to beat it: got '$host_layer'"
pass "omp $OMP_VERSION: the isolated host profile resolves its premium advisor $CONFLICT_ADVISOR"

pinned_layer=$(layer_advisor "$OVERLAY")
[ "$pinned_layer" = "$EXPECTED_ADVISOR" ] \
  || fail "the tracked overlay does not pin the worker advisor to $EXPECTED_ADVISOR; omp $OMP_VERSION resolved '$pinned_layer' from the config layers"
pass "omp $OMP_VERSION: the tracked overlay pins the worker advisor role to $EXPECTED_ADVISOR over the premium host profile"

# The same pin as a real session reports it, through omp's rpc builtin dispatch,
# which starts no turn. omp only builds an advisor for a provider it holds a
# credential for, so this reports `no_model` on a machine without one and is
# gated rather than asserted there.
session_advisor() {
  (
    cd "$TMP_ROOT" &&
      printf '{"id":"probe","type":"prompt","message":"/advisor status"}\n' \
        | PI_CONFIG_FILES="$HOST_OVERLAY" OMP_SKIP_SETUP=1 \
          omp --mode rpc --no-session --cwd "$TMP_ROOT" --config "$OVERLAY" 2>/dev/null
  ) | jq -r 'select(.type == "command_output") | .text | select(length > 0)'
}
if omp token "$EXPECTED_PROVIDER" >/dev/null 2>&1; then
  reported=$(session_advisor)
  case "$reported" in
    *"($EXPECTED_PROVIDER/"*) ;;
    *) fail "a session carrying the tracked overlay did not run an advisor on $EXPECTED_PROVIDER; omp $OMP_VERSION reported: $reported" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "  • "*"[paused]"*) ;;
      "  • "*)
        case "$line" in
          *" ($EXPECTED_PROVIDER/"*) ;;
          *) fail "a session carrying the tracked overlay ran a non-$EXPECTED_PROVIDER advisor; omp $OMP_VERSION reported: $reported" ;;
        esac ;;
    esac
  done <<<"$reported"
  pass "omp $OMP_VERSION: every running advisor in a session carrying the tracked overlay uses $EXPECTED_PROVIDER"
else
  printf 'skip: %s is not authenticated here, so the live session advisor report is unavailable\n' "$EXPECTED_PROVIDER"
fi
