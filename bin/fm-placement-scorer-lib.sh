#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_PLACEMENT_SCORER* are results for sourcing callers.
# fm-placement-scorer-lib.sh - the single owner of how bin/fm-place.sh ranks the
# candidates that already passed every admission gate, and of the
# config/placement-scorer file that chooses the ranking.
#
# Sourced, never executed. Ranking runs only after the cap, laptop, Nucleus,
# memory headroom, platform, and transport gates in bin/fm-place.sh; a scorer
# can drop an eligible candidate, never admit one those gates refused.
#
# Scorers:
#   headroom  the default: the most worker headroom wins, and a tie keeps this
#             home, then registry order (bin/fm-host-probe-lib.sh owns the
#             headroom rule, bin/fm-place.sh applies it).
#   t3        the T3 Code v0.1.7 host selector, ported from the pinned copy in
#             bin/vendor/t3code/load-balancing.ts (bin/vendor/t3code/UPSTREAM.md
#             owns the pin). It rejects a candidate whose weight is not above 0,
#             whose sample is more than 15 s old or more than 5 s in the future,
#             whose CPU utilization is unobserved or at least 0.95, whose total
#             memory or CPU count is not above 0, or whose available memory is
#             at most 5% of total, and ranks the rest by
#               weight * cpus * (1 - cpu_util) * (mem_avail_bytes / mem_total_bytes)
#             The first candidate with the strictly highest score wins, as
#             upstream's `score > bestScore` does, so candidate order (this
#             home, then registry order) breaks a tie. A fact the probe could
#             not read rejects the candidate, as a missing upstream snapshot
#             does. The sample time is when this home received that host's
#             report (bin/fm-host-probe-lib.sh dates each report separately),
#             so the freshness window measures the time from that receipt to
#             the decision. One deliberate difference: a malformed
#             receipt time is rejected here, where upstream's NaN comparison
#             would pass it; Firstmate stamps that time itself, so no host can
#             supply one.
#
# config/placement-scorer (optional, private to the home): blank lines and
# lines whose first non-blank character is # are ignored, and exactly one
# setting line remains:
#   headroom
#   t3 [<candidate-id>=<weight> ...]
# A candidate id is `local` (this home) or a secondmate id registered in
# data/secondmates.md. A weight is an integer from 0 through 100, and an omitted
# candidate weighs 50, T3 Code's default; 0 keeps that host out of t3 ranking.
# A missing file means headroom. An unreadable file, a second setting line, an
# unknown scorer, an extra token after headroom, a malformed or out-of-range
# weight, an unknown id, or a repeated id is a configuration error, which
# bin/fm-place.sh refuses with exit 2 before it probes any host.
#
# Functions:
#   fm_placement_scorer_load <file> <known-ids>
#       Reads the file and sets FM_PLACEMENT_SCORER (headroom or t3) and
#       FM_PLACEMENT_SCORER_WEIGHTS ("<id>=<weight> ..." as configured).
#       <known-ids> is the space-separated candidate id list. Returns 1 with
#       FM_PLACEMENT_SCORER_ERROR set on a configuration error.
#   fm_placement_scorer_weight <id>
#       Prints the weight the loaded configuration gives <id>.
#   fm_placement_t3_score <now-ms>
#       Reads one candidate per stdin line,
#         <id> <weight> <cpus> <cpu_util> <mem_avail_bytes> <mem_total_bytes> <sampled_at_ms>
#       with `unobserved` for a fact the probe could not read, and prints, in
#       input order, `candidate <id> score <score>` or
#       `candidate <id> reject <reason>`, then `winner <id>` (or `winner -`
#       when every candidate was rejected) and `ranked <id>:<score>,...` (best
#       first, ties in input order, scores to two decimals; empty after
#       `ranked ` when none scored).

FM_PLACEMENT_SCORER=headroom
FM_PLACEMENT_SCORER_WEIGHTS=
FM_PLACEMENT_SCORER_ERROR=
FM_PLACEMENT_T3_NAME=t3code-v0.1.7
FM_PLACEMENT_T3_DEFAULT_WEIGHT=50

fm_placement_scorer_load() {
  local file=$1 known=" $2 " line setting='' token id weight seen=' '
  FM_PLACEMENT_SCORER=headroom
  FM_PLACEMENT_SCORER_WEIGHTS=
  FM_PLACEMENT_SCORER_ERROR=
  [ -e "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_PLACEMENT_SCORER_ERROR="$file is not a readable file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    if [ -n "$setting" ]; then
      FM_PLACEMENT_SCORER_ERROR="$file has more than one setting line; put the scorer and every weight on one line"
      return 1
    fi
    setting=$line
  done < "$file"
  if [ -z "$setting" ]; then
    FM_PLACEMENT_SCORER_ERROR="$file names no scorer; write headroom or t3"
    return 1
  fi
  local -a tokens
  read -r -a tokens <<<"$setting"
  set -- "${tokens[@]}"
  case "$1" in
    headroom)
      if [ "$#" -gt 1 ]; then
        FM_PLACEMENT_SCORER_ERROR="$file: headroom takes no weights (got: $2)"
        return 1
      fi
      return 0
      ;;
    t3) shift ;;
    *)
      FM_PLACEMENT_SCORER_ERROR="$file: unknown scorer '$1'; write headroom or t3"
      return 1
      ;;
  esac
  for token in "$@"; do
    case "$token" in
      ?*=?*) ;;
      *)
        FM_PLACEMENT_SCORER_ERROR="$file: '$token' is not <candidate-id>=<weight>"
        return 1
        ;;
    esac
    id=${token%%=*}
    weight=${token#*=}
    case "$weight" in
      *[!0-9]*)
        FM_PLACEMENT_SCORER_ERROR="$file: weight '$weight' for $id is not an integer from 0 through 100"
        return 1
        ;;
    esac
    if [ "${#weight}" -gt 3 ] || [ "$weight" -gt 100 ]; then
      FM_PLACEMENT_SCORER_ERROR="$file: weight '$weight' for $id is not an integer from 0 through 100"
      return 1
    fi
    case "$known" in
      *" $id "*) ;;
      *)
        FM_PLACEMENT_SCORER_ERROR="$file: '$id' is neither local nor a secondmate registered in data/secondmates.md"
        return 1
        ;;
    esac
    case "$seen" in
      *" $id "*)
        FM_PLACEMENT_SCORER_ERROR="$file: $id is weighted more than once"
        return 1
        ;;
    esac
    seen="$seen$id "
    FM_PLACEMENT_SCORER_WEIGHTS="${FM_PLACEMENT_SCORER_WEIGHTS}${FM_PLACEMENT_SCORER_WEIGHTS:+ }$id=$((10#$weight))"
  done
  FM_PLACEMENT_SCORER=t3
  return 0
}

fm_placement_scorer_weight() {  # <id>
  local pair
  for pair in $FM_PLACEMENT_SCORER_WEIGHTS; do
    if [ "${pair%%=*}" = "$1" ]; then
      printf '%s' "${pair#*=}"
      return 0
    fi
  done
  printf '%s' "$FM_PLACEMENT_T3_DEFAULT_WEIGHT"
}

fm_placement_t3_score() {  # <now-ms>
  awk -v now="$1" '
    function num(v) { return v ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ }
    function verdict(  w, c, u, a, t, at, mem) {
      w = $2; c = $3; u = $4; a = $5; t = $6; at = $7
      if (c == "unobserved" || a == "unobserved" || t == "unobserved") return "reject the host reported no complete resource sample"
      if (!num(c) || !num(a) || !num(t)) return "reject the resource sample is malformed"
      if (!num(w)) return "reject weight " w " is not a number"
      if (w + 0 <= 0) return "reject weight " w " keeps this host out of t3 ranking"
      if (!num(at)) return "reject the sample receipt time is malformed"
      if (now - at > 15000) return "reject the sample is " (now - at) " ms old, past the 15000 ms freshness window"
      if (at > now + 5000) return "reject the sample is " (at - now) " ms in the future, past the 5000 ms allowance"
      if (u == "unobserved") return "reject CPU utilization was not observed"
      if (!num(u)) return "reject CPU utilization " u " is malformed"
      if (u + 0 >= 0.95) return "reject CPU utilization " u " is at or above 0.95"
      if (t + 0 <= 0) return "reject total memory " t " bytes is not above 0"
      if (c + 0 <= 0) return "reject CPU count " c " is not above 0"
      mem = (a + 0) / (t + 0)
      if (mem <= 0.05) return "reject available memory " a " of " t " bytes is at or below 5%"
      score[NR] = (w + 0) * (c + 0) * (1 - (u + 0)) * mem
      return "score " sprintf("%.17g", score[NR])
    }
    NF {
      n++
      ids[n] = $1
      v = verdict()
      print "candidate", $1, v
      if (v ~ /^score /) {
        scored[n] = 1
        sc[n] = score[NR]
        if (sc[n] > best) { best = sc[n]; win = $1 }
      }
    }
    END {
      print "winner", (win == "" ? "-" : win)
      m = 0
      for (i = 1; i <= n; i++) if (scored[i]) order[++m] = i
      for (i = 2; i <= m; i++) {
        k = order[i]
        for (j = i - 1; j >= 1 && sc[order[j]] < sc[k]; j--) order[j + 1] = order[j]
        order[j + 1] = k
      }
      line = ""
      for (i = 1; i <= m; i++) line = line (i > 1 ? "," : "") ids[order[i]] ":" sprintf("%.2f", sc[order[i]])
      print "ranked", line
    }
  '
}
