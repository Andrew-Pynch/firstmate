#!/usr/bin/env bash
# fm-intake.sh - record how an incoming request was routed, and why.
#
# Usage:
#   fm-intake.sh route <item-id> --reason <one-line> [--open <class>]...
#                                [--started <line>] [--fact <text>]...
#   fm-intake.sh show <item-id>
#
# Route an incoming request by what is still undecided. The rule itself, and the
# record format, are owned once by bin/fm-intake-lib.sh; AGENTS.md section 7
# states the rule for the agent and this script is how it is recorded.
#
# `route` records the decision ON the item and prints the request's single
# started line. The route is derived from the open choices the caller declares,
# never asserted beside them, so the record can never disagree with the choices
# it was built from:
#
#   --open <class>   one choice the request cannot be dispatched past. Any class
#                    routes it to the captain: the item is recorded as a grill
#                    and held through bin/fm-captain-hold.sh `hold` in the same
#                    call. With no class the request is a delegate route and is
#                    dispatched without a captain round. Repeatable. Valid
#                    classes are the four owned by the library:
#                    product-judgment, engineering-assumption, protected-state,
#                    authorization.
#
#   --reason <text>  why the route is what it is, recorded verbatim on the item.
#                    One line of at most 200 bytes, and no parentheses: the
#                    backlog's hold tags reserve them, and a grill hands this
#                    same reason to the captain-hold owner.
#
#   --started <line> the captain-facing line that says this request started. It
#                    is printed to stdout, and only as this request's FIRST
#                    started line: the item records the fact, so researching
#                    more and re-routing never announces one request twice, and a
#                    ticket is never routed at all, which is what keeps a
#                    request to one line however many tickets it grows. A
#                    request held for the captain has not started, so --started
#                    with a grill route is refused rather than announced.
#
#   --fact <text>    a fact this classification depends on that is not
#                    established yet. Routing REFUSES while one is given,
#                    because a route resting on a guessed fact is worse than no
#                    route: research it first. This is not a third route, it is
#                    a request that has not been classified yet. Repeatable.
#
# The record is the durable half: one `Intake route:` line on the item, replaced
# in place when the request is routed again, plus the `Intake started:` line once
# the started line has been emitted. Every other line of the item's note is left
# where it is, so a hold stamp or a resolution block written by another owner
# survives untouched. `show` prints both recorded lines.
#
# A home that records its backlog by hand cannot have the note stamped for it;
# the exact line is printed for the operator to add instead, the started line is
# withheld until that record exists, and the captain hold still happens.
#
# Exit status:
#   0  the route is recorded, and the started line printed when one is due;
#   1  an operational failure that names itself: unknown item, unusable backlog;
#   2  a usage or contract error;
#   3  refused until the named facts are researched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-intake-lib.sh
. "$SCRIPT_DIR/fm-intake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-intake: %s\n' "$*" >&2
  exit 1
}

# Read one item into ITEM_SHOW. A read that could not finish inside its bound is
# not absence: it stops the command by name, so a wedged backend never becomes a
# report that the captain's request does not exist.
ITEM_SHOW=
show_item() { # <item-id>
  local data status=0 reason
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  ITEM_SHOW=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${ITEM_SHOW%%$'\n'*}
    fail "${reason:-tasks-axi show $1 exceeded its backlog read bound}"
  fi
  return "$status"
}

# A shown scalar field arrives as a bare string when it is one line and as a
# JSON-encoded string when it is several; decode the second so a multi-line note
# is rewritten rather than truncated at its first line.
decode_shown_value() { # <shown-value>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

item_field() { # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

item_body() { # <show-output>
  decode_shown_value "$(item_field "$1" body)"
}

# The note with this route recorded: the previous route line replaced in place,
# the started marker left alone unless this call is the one that emits it, and
# every other line preserved in order.
rewrite_note() { # <body> <route-line> [started-line]
  local body=${1:-} route_line=${2:?route line is required} started_line=${3:-}
  if [ -z "$body" ]; then
    if [ -n "$started_line" ]; then
      printf '%s\n%s' "$route_line" "$started_line"
    else
      printf '%s' "$route_line"
    fi
    return 0
  fi
  # The two values travel in the environment, not through `awk -v`, because -v
  # expands backslash escapes: a reason containing a backslash would be recorded
  # as something other than what the caller wrote. The record prefixes come from
  # their owner for the same reason they exist at all: one definition.
  printf '%s\n' "$body" |
    FM_INTAKE_ROUTE_RECORD=$route_line FM_INTAKE_STARTED_RECORD=$started_line \
      FM_INTAKE_ROUTE_PREFIX=$FM_INTAKE_ROUTE_PREFIX \
      FM_INTAKE_STARTED_PREFIX=$FM_INTAKE_STARTED_PREFIX \
      awk '
    BEGIN {
      route_line = ENVIRON["FM_INTAKE_ROUTE_RECORD"]
      started_line = ENVIRON["FM_INTAKE_STARTED_RECORD"]
      route_prefix = ENVIRON["FM_INTAKE_ROUTE_PREFIX"]
      started_prefix = ENVIRON["FM_INTAKE_STARTED_PREFIX"]
      wrote_route = 0
      wrote_started = 0
    }
    substr($0, 1, length(route_prefix)) == route_prefix {
      if (wrote_route) next
      print route_line
      wrote_route = 1
      next
    }
    substr($0, 1, length(started_prefix)) == started_prefix {
      if (wrote_started) next
      wrote_started = 1
      if (started_line != "") { print started_line; next }
      print
      next
    }
    { print }
    END {
      if (!wrote_route) print route_line
      if (!wrote_started && started_line != "") print started_line
    }
  '
}

record_note() { # <item-id> <note>
  local id=$1 note=$2 tmp
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-intake-note.XXXXXX") \
    || fail "cannot stage the route record"
  if ! printf '%s\n' "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the route record for $id"
  fi
  if ! fm_backlog_mutate "$DATA" update "$id" --body-file "$tmp" --archive-body; then
    rm -f -- "$tmp"
    fail "could not record the intake route on $id: ${FM_BACKLOG_TRANSITION_ERROR:-unknown error}"
  fi
  rm -f -- "$tmp"
}

command_route() {
  local id=${1:-} flag value reason='' started='' route line note started_record='' prior_started=0
  local record_status=0 recorded=1 started_text='' class fact body
  local -a open=() facts=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason | --open | --started | --fact)
        flag=$1
        [ "$#" -ge 2 ] || {
          printf 'fm-intake: %s requires a value\n' "$flag" >&2
          usage >&2
          exit 2
        }
        value=$2
        case "$flag" in
          --reason) reason=$value ;;
          --open) open+=("$value") ;;
          --started) started=$value ;;
          --fact) facts+=("$value") ;;
        esac
        shift 2
        ;;
      *)
        printf 'fm-intake: unknown argument %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  reason=$(fm_intake_reason_normalize "$reason")
  fm_intake_reason_valid "$reason" || {
    printf 'fm-intake: --reason must be one line of at most %s bytes and without parentheses, got: %s\n' \
      "$FM_INTAKE_REASON_MAX" "$reason" >&2
    exit 2
  }
  for class in ${open[@]+"${open[@]}"}; do
    fm_intake_class_valid "$class" || {
      printf "fm-intake: unknown open-decision class '%s'; valid classes: %s\n" \
        "$class" "$(fm_intake_classes_join "${FM_INTAKE_CLASSES[@]}")" >&2
      exit 2
    }
  done
  route=$(fm_intake_route ${open[@]+"${open[@]}"}) || {
    usage >&2
    exit 2
  }

  if [ "${#facts[@]}" -gt 0 ]; then
    printf 'fm-intake: %s is not routed: this classification depends on facts that are not established yet. Research them first, never guess:\n' "$id" >&2
    for fact in "${facts[@]}"; do
      printf '  %s\n' "$fact" >&2
    done
    exit 3
  fi

  if [ -n "$started" ] && [ "$route" = grill ]; then
    printf 'fm-intake: %s is held for the captain, so it has not started; drop --started\n' "$id" >&2
    exit 2
  fi

  show_item "$id" || fail "no backlog item $id in this home"
  [ "$(item_field "$ITEM_SHOW" state)" != 'done' ] \
    || fail "$id is already closed; a route records work that has not landed yet"
  body=$(item_body "$ITEM_SHOW")
  if fm_intake_note_started "$body"; then
    prior_started=1
  fi
  if [ -n "$started" ]; then
    started_text=$(fm_intake_reason_normalize "$started")
    fm_intake_started_valid "$started_text" || {
      printf 'fm-intake: --started must be one line of at most %s bytes\n' "$FM_INTAKE_STARTED_MAX" >&2
      exit 2
    }
    if [ "$prior_started" -eq 0 ]; then
      started_record=$(fm_intake_started_line "$started_text")
    else
      started_text=''
    fi
  fi

  line=$(fm_intake_route_line "$route" "$reason" ${open[@]+"${open[@]}"})
  note=$(rewrite_note "$body" "$line" "$started_record")

  fm_backlog_transition_applies "$CONFIG" "$DATA" request || record_status=$?
  case "$record_status" in
    0) record_note "$id" "$note" ;;
    1)
      recorded=0
      started_text=''
      printf 'fm-intake: %s; add this line to %s by hand, and send its started line with it:\n  %s\n' \
        "${FM_BACKLOG_TRANSITION_SKIP:-this home records its backlog by hand}" "$id" "$line" >&2
      ;;
    *) fail "${FM_BACKLOG_TRANSITION_ERROR:-the backlog backend is unusable}" ;;
  esac

  if [ "$route" = grill ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --reason "$reason" >/dev/null \
      || fail "could not hold $id for the captain"
  fi

  [ "$recorded" -eq 1 ] || return 0
  [ -z "$started_text" ] || printf '%s\n' "$started_text"
}

command_show() {
  local id=${1:-} body line found=0
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  show_item "$id" || fail "no backlog item $id in this home"
  body=$(item_body "$ITEM_SHOW")
  while IFS= read -r line; do
    if fm_intake_is_route_line "$line" || fm_intake_is_started_line "$line"; then
      printf '%s\n' "$line"
      found=1
    fi
  done <<<"$body"
  [ "$found" -eq 1 ] || fail "no intake route is recorded on $id"
}

case "${1:-}" in
  route) shift; command_route "$@" ;;
  show) shift; command_show "$@" ;;
  -h | --help) usage; exit 0 ;;
  *)
    usage >&2
    exit 2
    ;;
esac
