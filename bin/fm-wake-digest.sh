#!/usr/bin/env bash
# fm-wake-digest.sh - one compact, lossless view of a wake drain, plus a
# recorded acknowledgement that never has to be retyped.
#
# Usage:
#   fm-wake-digest.sh          run bin/fm-wake-drain.sh, keep its full output,
#                              record its WAKE_ACK_REQUIRED cutoff, print a digest
#   fm-wake-digest.sh --ack    after handling, run the recorded acknowledgement
#   fm-wake-digest.sh --full   reprint the full output of the last digested drain
#
# bin/fm-wake-drain.sh stays the single owner of claiming, presenting,
# acknowledging, and recovery generations; this script only reshapes what the
# drain printed and replays the exact cutoff the drain named. It never acks on
# its own: --ack is a separate, explicit call the supervisor makes after
# handling, exactly like the WAKE_ACK_REQUIRED command it replaces, so an
# interruption before --ack still leaves every presented row durable.
#
# Digest rules, so nothing actionable is dropped:
#   - signal rows collapse to one line listing the union of every key and every
#     path named in their reasons (as basenames), with the sequence range;
#   - every other wake row prints as "wake <type> #<seq>: <reason>";
#   - the WAKE_ACK_REQUIRED line becomes one "ack:" line naming this script;
#   - the guard's "queued wakes pending - drain them" line is dropped, because
#     the rows it counts are exactly the ones this drain just presented and that
#     --ack will consume (the guard's other queued-wake warnings are kept);
#   - every other line prints verbatim, in order.
# The full combined drain output is kept in state/.wake-digest.<actor>.out and
# the cutoff in state/.wake-digest.<actor>.ack (actor from FM_SUPERVISION_ACTOR,
# default main), both mode 0600 and replaced atomically. A drain that prints no
# acknowledgement removes the recorded cutoff, because the drain re-presents
# every unacknowledged row with a fresh cutoff each time. --ack removes the
# record only after the drain accepted it and only if no newer digest replaced
# it meanwhile; with nothing recorded it says so and exits 0.
# The exit status of the default and --ack modes is the drain's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DRAIN="$SCRIPT_DIR/fm-wake-drain.sh"

usage() {
  echo "usage: fm-wake-digest.sh [--ack | --full]" >&2
  exit 2
}

ACTOR=${FM_SUPERVISION_ACTOR:-main}
case "$ACTOR" in
  main|branch) ;;
  *) echo "error: unknown FM_SUPERVISION_ACTOR '$ACTOR' (expected main or branch)" >&2; exit 2 ;;
esac
OUT_FILE="$STATE/.wake-digest.$ACTOR.out"
ACK_FILE="$STATE/.wake-digest.$ACTOR.ack"

[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: state directory is unavailable: $STATE" >&2
  exit 1
}

# publish <dest> <content-file>: atomic 0600 replace inside the state dir.
publish() {
  chmod 0600 "$2" && mv -f -- "$2" "$1"
}

ack_record_valid() {  # <file> -> sets REC_SEQ REC_GEN
  local seq gen extra
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  { IFS= read -r seq; IFS= read -r gen; IFS= read -r extra; } < "$1" || true
  [ -z "${extra:-}" ] || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  case "$gen" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  REC_SEQ=$seq
  REC_GEN=$gen
}

do_ack() {
  local snapshot rc
  if [ ! -e "$ACK_FILE" ] && [ ! -L "$ACK_FILE" ]; then
    echo "wake digest: nothing recorded to acknowledge"
    return 0
  fi
  if ! ack_record_valid "$ACK_FILE"; then
    echo "error: recorded acknowledgement $ACK_FILE is malformed; run bin/fm-wake-digest.sh again and handle what it presents" >&2
    return 1
  fi
  snapshot="$REC_SEQ $REC_GEN"
  rc=0
  "$DRAIN" --ack-through "$REC_SEQ" --recovery-generation "$REC_GEN" || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Remove only the record this call consumed: a digest that ran meanwhile
    # recorded a newer cutoff for rows this acknowledgement did not cover.
    if ack_record_valid "$ACK_FILE" && [ "$REC_SEQ $REC_GEN" = "$snapshot" ]; then
      rm -f -- "$ACK_FILE"
    fi
    printf 'wake digest: acknowledged through %s\n' "${snapshot%% *}"
  fi
  return "$rc"
}

do_full() {
  if [ -f "$OUT_FILE" ] && [ ! -L "$OUT_FILE" ]; then
    cat -- "$OUT_FILE"
  else
    echo "wake digest: no digested drain recorded yet"
  fi
}

# render <full-output-file>: print the digest (rules in the header).
render() {
  awk -F '\t' '
    function base(p,   n, parts) { n = split(p, parts, "/"); return parts[n] }
    function add(name) { if (name != "" && !(name in seen)) { seen[name] = 1; names[++nn] = name } }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if ($3 == "signal") {
        nsig++
        if (lo == "" || $2 + 0 < lo) lo = $2 + 0
        if ($2 + 0 > hi) hi = $2 + 0
        add($4)
        reason = $0
        sub(/^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t/, "", reason)
        sub(/^signal: */, "", reason)
        nw = split(reason, words, / +/)
        for (i = 1; i <= nw; i++) if (words[i] ~ /\//) add(base(words[i]))
        if (!sigpos) { sigpos = ++nl; lines[sigpos] = "" }
        next
      }
      reason = $0
      sub(/^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t/, "", reason)
      lines[++nl] = "wake " $3 " #" $2 ": " reason
      next
    }
    /^WAKE_ACK_REQUIRED: / {
      n = split($0, w, / +/)
      for (i = 1; i <= n; i++) {
        if (w[i] == "--ack-through") seq = w[i + 1]
        if (w[i] == "--recovery-generation") gen = w[i + 1]
      }
      lines[++nl] = "ack: after handling run bin/fm-wake-digest.sh --ack (through " seq ", generation " gen ")"
      next
    }
    /^WARNING: queued wakes pending - drain them with bin\/fm-wake-drain\.sh before anything else\.$/ { next }
    { lines[++nl] = $0 }
    END {
      if (sigpos) {
        s = ""
        for (i = 1; i <= nn; i++) s = s (i > 1 ? " " : "") names[i]
        range = (lo == hi) ? "#" lo : "#" lo "-" hi
        lines[sigpos] = "wake signal x" nsig " " range ": " s
      }
      for (i = 1; i <= nl; i++) print lines[i]
    }
  ' "$1"
}

do_digest() {
  local tmp_out tmp_ack rc seq gen
  tmp_out=$(mktemp "$STATE/.wake-digest.$ACTOR.out.XXXXXX") || exit 1
  rc=0
  "$DRAIN" > "$tmp_out" 2>&1 || rc=$?
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$tmp_out" | tail -n 1)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\2/p' "$tmp_out" | tail -n 1)
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    tmp_ack=$(mktemp "$STATE/.wake-digest.$ACTOR.ack.XXXXXX") || { rm -f -- "$tmp_out"; exit 1; }
    if ! { printf '%s\n%s\n' "$seq" "$gen" > "$tmp_ack" && publish "$ACK_FILE" "$tmp_ack"; }; then
      rm -f -- "$tmp_ack" "$tmp_out"
      echo "error: could not record the acknowledgement; use the WAKE_ACK_REQUIRED line from bin/fm-wake-drain.sh directly" >&2
      exit 1
    fi
  else
    rm -f -- "$ACK_FILE"
  fi
  render "$tmp_out"
  publish "$OUT_FILE" "$tmp_out" || rm -f -- "$tmp_out"
  printf 'full: bin/fm-wake-digest.sh --full\n'
  return "$rc"
}

case "${1:-}" in
  '') [ "$#" -le 1 ] || usage; do_digest ;;
  --ack) [ "$#" -eq 1 ] || usage; do_ack ;;
  --full) [ "$#" -eq 1 ] || usage; do_full ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
