# shellcheck shell=bash
# Per-project waves: the layer a ticket sits in inside its own project's
# dependency graph, and the gate that decides whether it may start now.
#
# Usage: . bin/fm-wave-lib.sh
#   fm_wave_split_row <tsv-line>                       -> the fields in FM_WAVE_FIELDS
#   fm_wave_row_landed <state>                         -> 0 when that state has landed
#   fm_wave_row_waiting <state> <hold>                 -> 0 when that row waits on the captain
#   fm_wave_blocker_clears <state>                     -> 0 when that record no longer holds its dependents
#   fm_wave_row_gate <state> <hold> <kind> <uncleared> -> the row's own gate token
#   fm_wave_plan                                       -> the plan for the TSV rows on stdin
#
# ONE OWNER for the dispatch rule of the captain's work-visibility plan
# (report.md slice 11; AGENTS.md section 7 states it for the agent, and
# bin/fm-wave.sh is the command that applies it).
#
#   - Each project's tickets form their own dependency graph, and the declared
#     blocked-by edges are that graph. A wave is one layer of it: layer 1 has no
#     declared blocker inside its own project.
#   - A ticket may start as soon as its own declared blockers have landed, with
#     no manual step in between: its state is queued, it does not itself wait on
#     the captain, and every declared blocker has landed.
#   - A project's unfinished ticket never holds up another project. The whole
#     computation is per project, so one project's blocked ticket changes
#     nothing about another project's next wave. A declared blocker outside the
#     project still gates dispatch, and never changes the layer, because the
#     layer belongs to the graph it sits in.
#   - An item waiting on the captain holds only the tickets that declare it, and
#     never a project it does not appear in. That wait is an OPEN captain call -
#     a row that has not landed and carries the captain hold - which is the same
#     shape bin/fm-intake.sh leaves behind a grill route, so intake's decision is
#     consumed here rather than restated. A landed row clears its dependents
#     whatever hold metadata it keeps: an answered captain call records its
#     resolution on a closed row and must never hold work again.
#   - A declared blocker that the rows do not carry counts as resolved, and
#     never blocks. That is the backlog owner's own rule for the same edge:
#     tasks-axi derives `blocked` from a blocked-by edge pointing at a task that
#     exists and has not landed, so a missing blocker reads as done. It is what
#     lets a dependent start once its blocker lands and its row is pruned out of
#     the live backlog into the archive, where this read can no longer see it.
#   - A public-followup obligation is never dispatchable work: the backlog owner
#     excludes it from its own ready set, because bin/fm-public-followup.sh
#     delivers it and no worker is ever spawned for it. Its gate says so in
#     every state, so it can never appear in a start list.
#
# Row contract (TSV on stdin, one row per line):
#   <id> <TAB> <project> <TAB> <state> <TAB> <hold> <TAB> <kind> <TAB> <blockers> [<TAB> <extra>]
# where state is queued|in_flight|done, hold is none|captain, kind is the row's
# recorded kind, and blockers is a comma-separated list of declared blocker ids,
# empty for none. Further columns pass through to the output untouched, so a
# caller can carry its own annotation.
#
# Plan contract (TSV on stdout, sorted by project, then layer, then id):
#   <project> <TAB> <wave> <TAB> <id> <TAB> <state> <TAB> <gate> [<TAB> <extra>]
# wave is the row's layer, or 0 when no layer could be computed because the
# declared edges in that project form a cycle. gate is one of:
#   ready            the row may start now
#   blocked-by:<ids> the declared blockers that have not landed
#   waiting-on-you   the row itself waits on the captain
#   in-flight        the row is already running
#   landed           the row is done and cleared
#   obligation       the row is a public-followup obligation, never dispatched
#   cycle            the row's layer could not be computed
#   unknown          the row's state is not one of the three
#
# Portable on bash 3.2: no associative arrays, and every expansion of a
# possibly-empty array is guarded.

# The kind of a promised public reply: an obligation firstmate delivers, never
# work a worker is spawned for. The backlog owner excludes it from its own ready
# set with this same token.
FM_WAVE_OBLIGATION_KIND='public-followup'

# Fields of the row currently split. Split positionally rather than with `read`,
# because tab is IFS whitespace: `read` collapses a run of tabs, so an empty
# field silently shifts every field after it and a row with no blockers would
# parse its annotation as its blocker list.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_WAVE_FIELDS=()

fm_wave_split_row() { # <tsv-line>
  FM_WAVE_FIELDS=()
  local rest=${1:-} field
  while :; do
    field=${rest%%$'\t'*}
    FM_WAVE_FIELDS+=("$field")
    if [ "$field" = "$rest" ]; then
      break
    fi
    rest=${rest#*$'\t'}
  done
}

# Blockers of a record, deduplicated in declared order. A splitter rather than a
# pipe, because a blocker list is a few tokens long at most and a subprocess per
# row would cost more than the whole computation.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_WAVE_BLOCKER_TOKENS=()

fm_wave_blocker_tokens() { # <comma-separated-blockers>
  FM_WAVE_BLOCKER_TOKENS=()
  local rest=${1:-} token existing
  while [ -n "$rest" ]; do
    token=${rest%%,*}
    if [ "$token" = "$rest" ]; then
      rest=''
    else
      rest=${rest#*,}
    fi
    [ -n "$token" ] || continue
    for existing in ${FM_WAVE_BLOCKER_TOKENS[@]+"${FM_WAVE_BLOCKER_TOKENS[@]}"}; do
      [ "$existing" = "$token" ] && continue 2
    done
    FM_WAVE_BLOCKER_TOKENS+=("$token")
  done
}

# A record has landed when its own state says so. This deliberately reads the
# recorded state and nothing else: reconciling that record against reality is
# the queue-truth owner's job, not this gate's.
fm_wave_row_landed() { # <state>
  [ "${1:-}" = "done" ]
}

# An open captain call: the row has not landed and it carries the captain hold.
# A landed row is never waiting, because a captain call on it has already been
# answered and its resolution is recorded with the same hold metadata.
fm_wave_row_waiting() { # <state> <hold>
  [ "${1:-}" != "done" ] && [ "${2:-}" = "captain" ]
}

# A blocker clears its dependents once it has landed.
fm_wave_blocker_clears() { # <state>
  fm_wave_row_landed "${1:-}"
}

fm_wave_row_gate() { # <state> <hold> <kind> <uncleared-blockers>
  local state=${1:-} hold=${2:-} kind=${3:-} uncleared=${4:-}
  if [ "$state" = "done" ]; then
    printf 'landed\n'
    return 0
  fi
  if [ "$kind" = "$FM_WAVE_OBLIGATION_KIND" ]; then
    printf 'obligation\n'
    return 0
  fi
  case "$state" in
    in_flight)
      if fm_wave_row_waiting "$state" "$hold"; then printf 'waiting-on-you\n'; else printf 'in-flight\n'; fi
      ;;
    queued)
      if [ -n "$uncleared" ]; then
        printf 'blocked-by:%s\n' "$uncleared"
      elif fm_wave_row_waiting "$state" "$hold"; then
        printf 'waiting-on-you\n'
      else
        printf 'ready\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

# The whole computation: layers first, then each row's own gate. Layers are
# relaxed one pass per row, which is enough for a graph without cycles; a row
# still unlayered after that sits in a cycle and is reported rather than
# dispatched, because a cycle is a broken edge set and not a schedule.
fm_wave_plan() {
  local -a ids=() projects=() states=() holds=() kinds=() blockers=() extras=() layers=() out=()
  local line id gate uncleared blocker
  local count=0 index=0 other=0 pass=0 changed=0 max_layer=0 pending=0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fm_wave_split_row "$line"
    id=${FM_WAVE_FIELDS[0]:-}
    [ -n "$id" ] || continue
    ids+=("$id")
    projects+=("${FM_WAVE_FIELDS[1]:-}")
    states+=("${FM_WAVE_FIELDS[2]:-}")
    holds+=("${FM_WAVE_FIELDS[3]:-}")
    kinds+=("${FM_WAVE_FIELDS[4]:-}")
    blockers+=("${FM_WAVE_FIELDS[5]:-}")
    extras+=("${FM_WAVE_FIELDS[6]:-}")
    layers+=("0")
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0

  while [ "$pass" -lt "$count" ]; do
    changed=0
    index=0
    while [ "$index" -lt "$count" ]; do
      if [ "${layers[index]}" = 0 ]; then
        max_layer=0
        pending=0
        fm_wave_blocker_tokens "${blockers[index]}"
        for blocker in ${FM_WAVE_BLOCKER_TOKENS[@]+"${FM_WAVE_BLOCKER_TOKENS[@]}"}; do
          other=0
          while [ "$other" -lt "$count" ]; do
            [ "${ids[other]}" = "$blocker" ] && break
            other=$((other + 1))
          done
          # A blocker this project does not record, or records in another
          # project, gates dispatch but is not a layer of this graph.
          [ "$other" -lt "$count" ] || continue
          [ "${projects[other]}" = "${projects[index]}" ] || continue
          if [ "${layers[other]}" = 0 ]; then
            pending=1
            break
          fi
          [ "${layers[other]}" -gt "$max_layer" ] && max_layer=${layers[other]}
        done
        if [ "$pending" -eq 0 ]; then
          layers[index]=$((max_layer + 1))
          changed=1
        fi
      fi
      index=$((index + 1))
    done
    [ "$changed" -eq 1 ] || break
    pass=$((pass + 1))
  done

  index=0
  while [ "$index" -lt "$count" ]; do
    uncleared=''
    fm_wave_blocker_tokens "${blockers[index]}"
    for blocker in ${FM_WAVE_BLOCKER_TOKENS[@]+"${FM_WAVE_BLOCKER_TOKENS[@]}"}; do
      other=0
      while [ "$other" -lt "$count" ]; do
        [ "${ids[other]}" = "$blocker" ] && break
        other=$((other + 1))
      done
      if [ "$other" -lt "$count" ]; then
        fm_wave_blocker_clears "${states[other]}" && continue
      else
        # A declared blocker no row carries reads as resolved, which is the
        # backlog owner's rule for the same edge (see the header).
        continue
      fi
      uncleared=${uncleared:+$uncleared,}$blocker
    done
    if [ "${layers[index]}" = 0 ]; then
      gate=cycle
    else
      gate=$(fm_wave_row_gate "${states[index]}" "${holds[index]}" "${kinds[index]}" "$uncleared")
    fi
    out+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
      "${projects[index]}" "${layers[index]}" "${ids[index]}" \
      "${states[index]}" "$gate" "${extras[index]}")")
    index=$((index + 1))
  done

  printf '%s\n' "${out[@]}" |
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3
}