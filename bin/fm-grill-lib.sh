# shellcheck shell=bash
# Pure placement decisions for per-project grill agents in Herdr.
#
# Usage: . bin/fm-grill-lib.sh
#   fm_grill_workspace_label <project-name>          -> "<Name> · Grill"
#   fm_grill_workspace_find <workspaces-json> <token> <label> -> workspace id, or empty
#   fm_grill_plan_tab <tabs-json>                    -> "reuse <tab_id>" | "new-tab"
#
# ONE OWNER for the captain's grill-packing rule (data/captain.md "Grill
# lane"): grills share a tab, at most FM_GRILL_PER_TAB per tab, and a new tab
# appears only once every tab of that project's grill workspace is full. The
# captain's words are "no third grill gets new tab. only ever 2 grills per tab"
# (data/pam-fleet-semantics-grill/report.md Q7), confirmed by round 3 Q10 "new
# tab, packed in pairs". bin/fm-grill-place.sh is the only caller that acts on
# these answers; keeping the decisions here is what lets them be tested without
# a live Herdr session.
#
# Every pane inside a grill workspace is a grill of that one project, which is
# why a tab's own pane_count is the authoritative count and no pane metadata
# has to be read back (herdr's client exposes no metadata read path).

# fm_grill_workspace_label is built from the registry's project name, so this
# library owns that one dependency rather than requiring every caller to load
# the project resolver first.
# shellcheck source=bin/fm-project-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-project-lib.sh"

FM_GRILL_PER_TAB=${FM_GRILL_PER_TAB:-2}
FM_GRILL_WORKSPACE_SUFFIX=' · Grill'

# The grill workspace's display label. Herdr labels are free text; the colour
# token, not this string, is what a lookup matches on, so a hand-renamed
# workspace is still found.
fm_grill_workspace_label() { # <project-name>
  printf '%s%s\n' "$(fm_project_display_name "${1:-}")" "$FM_GRILL_WORKSPACE_SUFFIX"
}

# The project's grill workspace id: label AND colour token must both match, so a
# second workspace that merely shares the label is never adopted. Prints nothing
# when the project has no grill workspace yet.
fm_grill_workspace_find() { # <workspaces-json> <token> <label>
  printf '%s' "${1:-}" | jq -r --arg token "${2:-}" --arg want "${3:-}" '
    [ (.result.workspaces // [])[]
      | select(.label == $want and (.tokens.project // "") == $token)
      | .workspace_id ]
    | .[0] // empty' 2>/dev/null
}

# Where the next grill goes: the lowest-numbered tab that still holds fewer than
# FM_GRILL_PER_TAB panes, or a new tab when every tab is full (including when
# the workspace holds no tabs yet).
fm_grill_plan_tab() { # <tabs-json>
  local json=${1:-}
  printf '%s' "$json" | jq -r --argjson limit "$FM_GRILL_PER_TAB" '
    [ (.result.tabs // [])[]
      | select((.pane_count // 0) < $limit)
      | {id:(.tab_id // empty), n:(.number // 0)} ]
    | map(select(.id != ""))
    | sort_by(.n)
    | if length == 0 then "new-tab" else "reuse \(.[0].id)" end' 2>/dev/null \
    || printf 'new-tab\n'
}
