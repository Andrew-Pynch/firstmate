# shellcheck shell=bash
# Pure placement decisions for per-project grill agents in Herdr.
#
# Usage: . bin/fm-grill-lib.sh
#   fm_grill_workspace_label <project-name>          -> "<Name> · Grill"
#   fm_grill_workspace_find <workspaces-json> <token> <label> -> workspace id, or empty
#   fm_grill_plan_tab <tabs-json> <panes-json>       -> the placement decision
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
# The count that rule needs comes from the LIVE pane list of that workspace, not
# from a tab's own pane_count: a pane is a grill only when its own `kind=grill`
# token says so, and a pane is only ever written into when herdr reports no agent
# registered on it (docs/verification/runtime-backends.md "Grill workspace
# placement metadata" records the measured shape). A pane that is neither - the
# idle shell a new workspace is seeded with, or one opened by hand - therefore
# never occupies a grill slot, and the next grill fills it instead of splitting a
# neighbour.

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
#
# `(.tokens // {}).x` rather than `.tokens.x` matters here: this fleet's jq is
# jaq, which errors instead of returning null when a key's value is indexed and
# missing, and an untagged workspace in the same session has no `tokens` at all.
# An error there would silently read as "this project has no grill workspace"
# and plant a second one beside the first on every placement.
fm_grill_workspace_find() { # <workspaces-json> <token> <label>
  printf '%s' "${1:-}" | jq -r --arg token "${2:-}" --arg want "${3:-}" '
    [ (.result.workspaces // [])[]
      | select(.label == $want and ((.tokens // {}).project // "") == $token)
      | .workspace_id ]
    | .[0] // empty' 2>/dev/null
}

# Where the next grill goes, decided from that workspace's live tab list and
# live pane list, and reported as one of:
#   fill <tab-id> <pane-id>   the lowest-numbered tab with a free slot holds an
#                             idle pane - untagged and agent-free - which the
#                             grill takes
#   split <tab-id> <pane-id>  that tab holds only grills; split one of them and
#                             take the new pane, which writes into nothing
#   new-tab                   no tab can take the grill: every tab already holds
#                             FM_GRILL_PER_TAB grills, or its only free pane
#                             reports an agent this helper must not write into
# Tabs are considered in the order herdr numbers them, so a tab that frees up
# is refilled before a later tab, and no pane is ever counted twice.
fm_grill_plan_tab() { # <tabs-json> <panes-json>
  local tabs=${1:-} panes=${2:-} empty='{"result":{"panes":[]}}'
  [ -n "$panes" ] || panes=$empty
  printf '%s' "$tabs" | jq -r --argjson limit "$FM_GRILL_PER_TAB" \
    --argjson panes "$panes" '
    [ ($panes.result.panes // [])[]
      | {tab:(.tab_id // ""), pane:(.pane_id // ""),
         grill:(((.tokens // {}).kind // "") == "grill"),
         free:(((.agent_status // "unknown") == "unknown"))} ] as $p
    | [ (.result.tabs // [])[]
        | {id:(.tab_id // ""), n:(.number // 0)}
        | select(.id != "") ]
    | sort_by(.n)
    | map(. as $t
          | {id:$t.id,
             grills:([$p[] | select(.tab == $t.id and .grill)] | length),
             idle:([$p[] | select(.tab == $t.id and (.grill | not) and .free) | .pane] | first // ""),
             grill:( [$p[] | select(.tab == $t.id and .grill) | .pane] | first // "")})
    | map(select(.grills < $limit))
    | if length == 0 then "new-tab"
      else (.[0]
            | if .idle != "" then "fill \(.id) \(.idle)"
              elif .grill != "" then "split \(.id) \(.grill)"
              else "new-tab" end)
      end'
}
