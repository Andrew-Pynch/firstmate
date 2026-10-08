# shellcheck shell=bash
# Pure intake-routing decisions: the route an incoming request takes, and the
# record that route leaves on the item.
#
# Usage: . bin/fm-intake-lib.sh
#   fm_intake_class_valid <class>                      -> 0 for one of the four
#   fm_intake_class_order <class>...                   -> canonical, deduplicated
#   fm_intake_classes_join <class>...                  -> one comma-separated line
#   fm_intake_route <class>...                         -> "delegate" | "grill"
#   fm_intake_reason_normalize <text>                  -> one trimmed line
#   fm_intake_reason_valid <normalized-text>           -> 0 when recordable
#   fm_intake_started_valid <normalized-text>          -> 0 when emittable
#   fm_intake_route_line <route> <reason> [<class>...] -> the recorded line
#   fm_intake_is_route_line <line>                     -> 0 for a route record
#   fm_intake_is_started_line <line>                   -> 0 for a started record
#   fm_intake_line_route <line>                        -> the recorded route
#   fm_intake_line_classes <line>                      -> the recorded classes
#   fm_intake_line_reason <line>                       -> the recorded reason
#
# ONE OWNER for the captain's intake-routing rule (AGENTS.md section 7 "Intake
# and authority"; data/pam-work-visibility-grill/report.md slice 10): route an
# incoming request by what is still UNDECIDED.
#
#   delegate  no open choice is declared, so the request is dispatched without a
#             captain round;
#   grill     at least one open choice needs product judgment, an engineering
#             assumption, protected state, or authorization, so the request is
#             held for the captain through bin/fm-captain-hold.sh's `hold`.
#
# The four class tokens are the entire test. They are what the caller declares
# after reading the request, so the route is derived from the open choices
# rather than asserted beside them and can never disagree with them.
# A missing FACT is not one of the four: a classification that rests on an
# unestablished fact is researched first and never guessed, which is why
# bin/fm-intake.sh refuses to route while one is outstanding instead of routing
# on the guess.
#
# The recorded line is the durable half of the decision and the only thing
# bin/fm-intake.sh's `show` reads back:
#
#   Intake route: delegate - <one-line reason>
#   Intake route: grill [product-judgment, authorization] - <one-line reason>
#
# An item holds at most one route line, replaced in place when the request is
# routed again, so the line always describes the decision that stands. Once the
# request's single started line has been emitted, the item carries the
# `Intake started:` line that proves it, which is what keeps one request to one
# announced start however many tickets it later grows.

FM_INTAKE_CLASSES=(product-judgment engineering-assumption protected-state authorization)
FM_INTAKE_ROUTE_PREFIX='Intake route: '
FM_INTAKE_STARTED_PREFIX='Intake started: '
FM_INTAKE_REASON_MAX=200
FM_INTAKE_STARTED_MAX=300

fm_intake_class_valid() { # <class>
  local want=${1:-} class
  for class in "${FM_INTAKE_CLASSES[@]}"; do
    [ "$class" = "$want" ] && return 0
  done
  return 1
}

# Canonical order, one entry per class, whatever order and repetition the caller
# declared: the route is a property of the SET of open choices, so the record
# does not depend on how the caller happened to spell them.
fm_intake_class_order() { # <class>...
  local class declared
  for class in "${FM_INTAKE_CLASSES[@]}"; do
    for declared in "$@"; do
      if [ "$class" = "$declared" ]; then
        printf '%s\n' "$class"
        break
      fi
    done
  done
}

fm_intake_classes_join() { # <class>...
  local class first=1 joined=''
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    if [ "$first" -eq 1 ]; then
      joined=$class
      first=0
    else
      joined="$joined, $class"
    fi
  done < <(fm_intake_class_order "$@")
  printf '%s' "$joined"
}

# Delegate unless an open choice is declared. Every argument is validated so an
# unspellable class is refused by the caller rather than silently routed as an
# open decision.
fm_intake_route() { # <class>...
  local class
  for class in "$@"; do
    fm_intake_class_valid "$class" || return 2
  done
  if [ "$#" -eq 0 ]; then
    printf 'delegate\n'
  else
    printf 'grill\n'
  fi
}

# One line, because the record is one line: every run of whitespace collapses to
# a single space and both ends are trimmed.
fm_intake_reason_normalize() { # <text>
  printf '%s' "${1:-}" | LC_ALL=C tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# One line of text at most <max> bytes with no control character in it.
fm_intake_text_valid() { # <normalized-text> <max-bytes>
  local text=${1:-} max=${2:-0}
  [ -n "$text" ] || return 1
  [ "$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')" -le "$max" ] || return 1
  case "$text" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# A recordable reason additionally avoids parentheses, which the backlog's own
# hold tags reserve: the same reason is what a grill hands to
# bin/fm-captain-hold.sh, and tasks-axi refuses a hold reason containing them.
fm_intake_reason_valid() { # <normalized-text>
  fm_intake_text_valid "${1:-}" "$FM_INTAKE_REASON_MAX" || return 1
  case "${1:-}" in
    *'('* | *')'*) return 1 ;;
  esac
  return 0
}

# The captain-facing started line is chat, so unlike a reason it may contain
# parentheses; it is still one bounded line.
fm_intake_started_valid() { # <normalized-text>
  fm_intake_text_valid "${1:-}" "$FM_INTAKE_STARTED_MAX"
}

fm_intake_route_line() { # <route> <reason> [<class>...]
  local route=${1:?route is required} reason=${2:-}
  shift 2
  if [ "$#" -gt 0 ]; then
    printf '%s%s [%s] - %s\n' "$FM_INTAKE_ROUTE_PREFIX" "$route" "$(fm_intake_classes_join "$@")" "$reason"
  else
    printf '%s%s - %s\n' "$FM_INTAKE_ROUTE_PREFIX" "$route" "$reason"
  fi
}

# The recorded proof that this request's single started line has been emitted.
# The line the captain reads is the text alone; this is what the item carries.
fm_intake_started_line() { # <text>
  printf '%s%s\n' "$FM_INTAKE_STARTED_PREFIX" "${1:?started text is required}"
}

fm_intake_is_route_line() { # <line>
  case "${1:-}" in
    "$FM_INTAKE_ROUTE_PREFIX"*) return 0 ;;
  esac
  return 1
}

fm_intake_is_started_line() { # <line>
  case "${1:-}" in
    "$FM_INTAKE_STARTED_PREFIX"*) return 0 ;;
  esac
  return 1
}

# 0 when the note already carries an emitted started line, which is what makes
# one request announce exactly one start.
fm_intake_note_started() { # <note-body>
  local line
  while IFS= read -r line; do
    fm_intake_is_started_line "$line" && return 0
  done <<<"${1:-}"
  return 1
}

fm_intake_line_route() { # <line>
  local rest=${1#"$FM_INTAKE_ROUTE_PREFIX"}
  printf '%s\n' "${rest%% *}"
}

fm_intake_line_classes() { # <line>
  local rest=${1#"$FM_INTAKE_ROUTE_PREFIX"} without
  without=${rest#*[}
  if [ "$without" = "$rest" ]; then
    printf '\n'
  else
    printf '%s\n' "${without%%]*}"
  fi
}

fm_intake_line_reason() { # <line>
  local rest=${1#"$FM_INTAKE_ROUTE_PREFIX"}
  printf '%s\n' "${rest#* - }"
}
