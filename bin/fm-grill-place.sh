#!/usr/bin/env bash
# Place a per-project grill agent in Herdr: one grill workspace per registered
# project, grills packed at most two per tab, never the firstmate workspace.
#
# Usage: fm-grill-place.sh <project> [--token <token>] [--session <name>]
#                            [--launch <command>] [--cwd <path>] [--dry-run]
#
#   <project> is a registered project name from data/projects.md (or a path
#   whose basename is one). --token is that project's sub-project colour token
#   when it declares more than one (e.g. vigil for monorepo). An unresolved
#   project, an undeclared token, or a project whose registry line declares no
#   token is REFUSED loudly and nothing is created: a grill is never placed
#   under a guessed colour.
#
#   The grill's workspace is labelled "<Project> · Grill" (the registry name,
#   first letter capitalized) and tagged project=<token> plus kind=grill; the
#   pane is tagged the same way. The label is display text; the token is the
#   identity every lookup here matches on, so a hand-renamed workspace is still
#   found.
#
#   PLACEMENT: bin/fm-grill-lib.sh owns the captain's packing rule (data/
#   captain.md "Grill lane") and is the only place it is stated; this script is
#   the only caller that acts on it. In short: one grill workspace per project
#   token, reused for every grill of that project and never the firstmate
#   workspace or a worker space; a new grill fills the lowest-numbered tab that
#   still holds room, and only a workspace whose every tab is full grows a new
#   tab, so one project's grills stay in one workspace.
#   The decision is made from that workspace's live tab and pane lists on every
#   run, so it is correct whatever an earlier run or a hand left behind. The tab
#   and pane herdr seeds a brand-new workspace with become the FIRST grill's tab
#   and pane: herdr removes a workspace when its last tab closes, so that tab is
#   filled rather than replaced.
#
#   --launch runs that command line in the new pane (as `sh -lc <command>`);
#   without it the script only places and labels the pane and prints the pane id
#   plus an `launch=` line naming the exact command to run there.
#   --dry-run prints every herdr command it would run, one per line on stderr,
#   and changes nothing.
#
# This helper only ever touches the grill workspace it manages. It never closes,
# moves, or re-labels any other workspace, tab, or pane.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-project-lib.sh
. "$SCRIPT_DIR/fm-project-lib.sh"
# shellcheck source=bin/fm-grill-lib.sh
. "$SCRIPT_DIR/fm-grill-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-grill-place.sh <project> [--token <token>] [--session <name>]
                          [--launch <command>] [--cwd <path>] [--dry-run]

Place a per-project grill in Herdr: one grill workspace per registered project,
at most two grills per tab, never the firstmate workspace. See this script's
header for the placement rule and the refusal conditions.
EOF
}

PROJECT=
TOKEN=
SESSION=
LAUNCH=
CWD=$PWD
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --token) TOKEN=${2:?--token requires a value}; shift 2 ;;
  --token=*) TOKEN=${1#--token=}; shift ;;
  --session) SESSION=${2:?--session requires a value}; shift 2 ;;
  --session=*) SESSION=${1#--session=}; shift ;;
  --launch) LAUNCH=${2:?--launch requires a value}; shift 2 ;;
  --launch=*) LAUNCH=${1#--launch=}; shift ;;
  --cwd) CWD=${2:?--cwd requires a value}; shift 2 ;;
  --cwd=*) CWD=${1#--cwd=}; shift ;;
  --dry-run) DRY_RUN=1; shift ;;
  --*)
    echo "error: unknown option $1" >&2
    usage
    exit 2
    ;;
  *)
    [ -z "$PROJECT" ] || {
      echo "error: only one project may be named" >&2
      exit 2
    }
    PROJECT=$1
    shift
    ;;
  esac
done
[ -n "$PROJECT" ] || {
  usage
  exit 2
}

run_herdr() { # <herdr-args...>
  if [ "$DRY_RUN" -eq 1 ]; then
    # A dry run is a trace: every command it would run goes to stderr, so the
    # result lines stay machine-readable on stdout.
    printf 'herdr %s --session %s\n' "$*" "$SESSION" >&2
    return 0
  fi
  fm_backend_herdr_cli "$SESSION" "$@"
}

RESOLVED=$(fm_project_resolve_lines "$PROJECT" "$TOKEN") || {
  echo "error: project resolution failed for $PROJECT" >&2
  exit 1
}
R_STATUS=
R_PROJECT=
R_TOKEN=
R_SOURCE=
R_REASON=
while IFS= read -r line; do
  case "$line" in
  status=*) R_STATUS=${line#*=} ;;
  project=*) R_PROJECT=${line#*=} ;;
  token=*) R_TOKEN=${line#*=} ;;
  source=*) R_SOURCE=${line#*=} ;;
  reason=*) R_REASON=${line#*=} ;;
  esac
done <<EOF
$RESOLVED
EOF
if [ "$R_STATUS" != resolved ]; then
  echo "error: refusing to place a grill: $R_REASON" >&2
  exit 1
fi

LABEL=$(fm_grill_workspace_label "$R_PROJECT")
fm_backend_source herdr || {
  echo "error: the herdr backend adapter could not be loaded" >&2
  exit 1
}
[ -n "${SESSION:-}" ] || SESSION=$(fm_backend_herdr_session)

WORKSPACES=$(run_herdr workspace list) || {
  echo "error: could not list herdr workspaces in session '$SESSION'" >&2
  exit 1
}
if [ "$DRY_RUN" -eq 1 ]; then
  # A dry run still shows the shape it would act on, but with no live read to
  # act on it plans the cold case.
  WORKSPACES='{"result":{"workspaces":[]}}'
fi
WS=$(fm_grill_workspace_find "$WORKSPACES" "$R_TOKEN" "$LABEL")

if [ -z "$WS" ]; then
  OUT=$(run_herdr workspace create --cwd "$CWD" --label "$LABEL" --no-focus) || {
    echo "error: could not create the grill workspace '$LABEL'" >&2
    exit 1
  }
  if [ "$DRY_RUN" -eq 1 ]; then
    # A dry run has no live response to read, so it plans the cold case: the
    # workspace it would create, whose seeded tab and pane take this grill.
    WS='<new-workspace>'
    TAB='<seeded-tab>'
    PANE='<seeded-pane>'
  else
    WS=$(printf '%s' "$OUT" | jq -r '.result.workspace.workspace_id // empty')
    TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty')
    PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$WS" ] && [ -n "$TAB" ] && [ -n "$PANE" ] || {
      echo "error: herdr returned no workspace, seeded tab, or pane id for '$LABEL'" >&2
      exit 1
    }
    # The same rule the packing decision applies to a pane it did not create:
    # nothing is ever written into a pane that reports an agent. A fresh pane
    # reports none, so this only fires if herdr changes what create returns.
    SEEDED_AGENT=$(printf '%s' "$OUT" | jq -r '.result.root_pane.agent_status // "unknown"')
    [ "$SEEDED_AGENT" = unknown ] || {
      echo "error: herdr reported agent '$SEEDED_AGENT' on the pane it seeded workspace $WS with; refusing to write a grill into it" >&2
      exit 1
    }
  fi
  # run_herdr traces instead of calling herdr under --dry-run, so the tag every
  # placement owes the workspace is part of what a dry run prints.
  run_herdr workspace report-metadata "$WS" --source firstmate \
    --token "project=$R_TOKEN" --token "kind=grill" >/dev/null || {
    echo "error: could not tag the grill workspace $WS" >&2
    exit 1
  }
  # herdr labels the tab it seeds a workspace with "1". This grill now lives
  # there, so the tab takes the same label as every later grill tab; a label is
  # display text only, so a failure to set it is reported and placement goes on.
  run_herdr tab rename "$TAB" "grill-$R_TOKEN" >/dev/null || {
    echo "note: could not label the grill tab $TAB as grill-$R_TOKEN; herdr keeps its own label and the grill is placed and tagged regardless" >&2
  }
  PLAN="fill $TAB $PANE"
else
  TABS=$(run_herdr tab list --workspace "$WS") || {
    echo "error: could not list tabs in the grill workspace $WS" >&2
    exit 1
  }
  PANES=$(run_herdr pane list --workspace "$WS") || {
    echo "error: could not list panes in the grill workspace $WS" >&2
    exit 1
  }
  PLAN=$(fm_grill_plan_tab "$TABS" "$PANES") || {
    echo "error: could not read the grill workspace $WS state from herdr" >&2
    exit 1
  }
  case "$PLAN" in
  fill\ *)
    TAB=${PLAN#fill }
    PANE=${TAB#* }
    TAB=${TAB%% *}
    ;;
  split\ *)
    TAB=${PLAN#split }
    SPLIT_FROM=${TAB#* }
    TAB=${TAB%% *}
    [ -n "$TAB" ] && [ -n "$SPLIT_FROM" ] || {
      echo "error: herdr reported no splittable pane in the grill workspace $WS" >&2
      exit 1
    }
    # Split an EXISTING pane of that tab: herdr pane split addresses a pane, and
    # the new pane inherits the tab. The pane ids present before the split are
    # remembered so the new one can be identified even if the response shape
    # changes.
    BEFORE=$(run_herdr pane list --workspace "$WS" | jq -r --arg tab "$TAB" \
      '[ (.result.panes // [])[] | select(.tab_id == $tab) | .pane_id ] | join("\n")')
    OUT=$(run_herdr pane split --pane "$SPLIT_FROM" --direction right --cwd "$CWD") || {
      echo "error: could not add a second grill pane to tab $TAB" >&2
      exit 1
    }
    PANE=$(printf '%s' "$OUT" | jq -r '.result.pane.pane_id // .result.new_pane.pane_id // empty')
    if [ -z "$PANE" ]; then
      AFTER=$(run_herdr pane list --workspace "$WS" | jq -r --arg tab "$TAB" \
        '[ (.result.panes // [])[] | select(.tab_id == $tab) | .pane_id ] | join("\n")')
      PANE=$(printf '%s\n' "$AFTER" | grep -vxF -e "$BEFORE" | grep -v '^$' | head -n 1 || true)
    fi
    ;;
  new-tab)
    OUT=$(run_herdr tab create --workspace "$WS" --cwd "$CWD" --label "grill-$R_TOKEN" --no-focus) || {
      echo "error: could not create a grill tab in workspace $WS" >&2
      exit 1
    }
    TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty')
    PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty')
    ;;
  *)
    echo "error: could not decide where to place the grill in workspace $WS (herdr planned: ${PLAN:-nothing})" >&2
    exit 1
    ;;
  esac
  [ -n "$TAB" ] && [ -n "$PANE" ] || {
    echo "error: could not identify the grill tab and pane in workspace $WS" >&2
    exit 1
  }
fi

# Every pane a grill lands in is tagged with the project token and the grill
# kind, in every path: that tag is what the next placement reads back to decide
# whether a tab is full.
run_herdr pane report-metadata "$PANE" --source firstmate \
  --token "project=$R_TOKEN" --token "kind=grill" >/dev/null || {
  echo "error: could not tag the grill pane $PANE" >&2
  exit 1
}

printf 'session=%s\nworkspace=%s\nlabel=%s\ntab=%s\npane=%s\nproject=%s\ntoken=%s\ntoken_source=%s\nplacement=%s\n' \
  "$SESSION" "$WS" "$LABEL" "$TAB" "$PANE" "$R_PROJECT" "$R_TOKEN" "$R_SOURCE" "$PLAN"
if [ -n "$LAUNCH" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'launch=%s\n' "$LAUNCH"
  else
    run_herdr pane run "$PANE" sh -lc "$LAUNCH" >/dev/null || {
      echo "error: could not launch the grill command in pane $PANE" >&2
      exit 1
    }
    printf 'launched=yes\n'
  fi
fi
