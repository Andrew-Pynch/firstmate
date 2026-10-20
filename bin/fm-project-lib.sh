# shellcheck shell=bash
# Registry-backed project resolution: name or path -> registered project + its
# Herdr colour token.
#
# Usage: . bin/fm-project-lib.sh
#   fm_project_registry_file                 -> the registry path this home reads
#   fm_project_registry_map_json             -> {"<name>":{"tokens":["<t>",...]},...}
#   fm_project_resolve_lines <repo> [<tok>]  -> key=value lines (shell callers)
#   fm_project_resolve_json  <repo> [<tok>]  -> the same result as one JSON object
#   fm_project_display_name  <name>          -> the registry name for a label
# Splicing callers (bin/fm-fleet-snapshot.sh, bin/fm-bearings-snapshot.sh) use
# instead: splice "$FM_PROJECT_JQ_DEFS" ahead of a jq program and call
# fm_project_resolve($repo; $token; $map), where $map is
# fm_project_registry_map_json's output.
#
# ONE OWNER for "which registered project, with which colour token, does this
# row belong to". data/projects.md is the registry; this library is the only
# place that parses it into a project/token answer, so the spawn-time Herdr
# label, the fleet view, and the bearings projection can never disagree about a
# row's colour token.
#
# A row's colour token is the Herdr display token `project=<token>` (data/
# captain.md "Herdr sidebar labels"). The token is display metadata only, never
# task ownership, and its colour lives in Andrew's Herdr sidebar configuration,
# which is never duplicated here.
#
# Registry line format (data/projects.md; docs/configuration.md owns the
# schema):
#   - <name> [<mode>[ +yolo]] [subprojects=<t1>[,<t2>...]] - <desc> (added <date>)
# `subprojects=` is optional and whitespace-free. Its FIRST token is the
# project's declared default, used only when a caller supplies no sub-project
# token; a result resolved that way reports source=default so no caller has to
# guess why it got that token. A project with no `subprojects=` field resolves
# only when a caller supplies a token it declares, which cannot happen, so such
# a project reports unresolved naming exactly that missing field.
#
# Resolution is never a silent default: an unregistered repo, a project that
# declares no token, a token that project does not declare, and a row that
# names no project at all each return status=unresolved with a reason string a
# caller prints verbatim. Adding a project to the registry is project intake
# (.agents/skills/project-management/SKILL.md), never something this library
# invents.
#
# Resolution input is the project name as firstmate records it: the basename of
# the task's `project=` path (state/<id>.meta) or the backlog row's `repo:`
# field. An absolute path is accepted and reduced to its basename, matching
# bin/fm-project-mode.sh's own convention.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
# shellcheck disable=SC2016 # jq variables, not shell ones; the program is single-quoted by design.
FM_PROJECT_JQ_DEFS='
  def fm_project_repo_name:
    if . == null then ""
    else (sub("/+$"; "") | split("/") | last // "")
    end;
  def fm_project_resolve($repo; $token; $map):
    (($repo // "") | fm_project_repo_name) as $name
    | if ($name | length) == 0 then
        {status:"unresolved", project:null, token:null, source:null,
         reason:"this row names no project"}
      elif ($map[$name] // null) == null then
        {status:"unresolved", project:null, token:null, source:null,
         reason:("repo \"\($name)\" is not a registered project; register it in data/projects.md")}
      else
        ($map[$name].tokens // []) as $tokens
        | if ($tokens | length) == 0 then
            {status:"unresolved", project:$name, token:null, source:null,
             reason:("project \"\($name)\" declares no colour token; add subprojects=<token> to its registry line in data/projects.md")}
          elif (($token // "") | length) > 0 then
            if ($tokens | index($token)) != null then
              {status:"resolved", project:$name, token:$token, source:"explicit", reason:null}
            else
              {status:"unresolved", project:$name, token:null, source:null,
               reason:("sub-project \"\($token)\" is not declared for project \"\($name)\" (declared: \($tokens | join(", ")))")}
            end
          elif ($tokens | length) == 1 then
            {status:"resolved", project:$name, token:$tokens[0], source:"only", reason:null}
          else
            {status:"resolved", project:$name, token:$tokens[0], source:"default", reason:null}
          end
      end;
'

fm_project_registry_file() {
  local home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  printf '%s\n' "${FM_DATA_OVERRIDE:-$home/data}/projects.md"
}

fm_project_registry_map_json() {
  local reg
  reg=$(fm_project_registry_file)
  if [ ! -f "$reg" ]; then
    printf '{}\n'
    return 0
  fi
  awk '
    $1 == "-" && $2 != "" {
      tokens = ""
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^subprojects=/) { tokens = substr($i, 13); break }
      }
      printf "%s\t%s\n", $2, tokens
    }
  ' "$reg" | jq -R -s '
    [ splits("\n") | select(length > 0) | capture("^(?<name>[^\t]*)\t(?<tokens>.*)$") ]
    | map({key:.name,
           value:{tokens:(.tokens | if . == "" then [] else split(",") | map(select(. != "")) end)}})
    | from_entries'
}

fm_project_resolve_json() {
  local repo=${1:-} token=${2:-} map
  map=$(fm_project_registry_map_json) || return 1
  jq -n --arg repo "$repo" --arg token "$token" --argjson map "$map" \
    "$FM_PROJECT_JQ_DEFS"' fm_project_resolve($repo; $token; $map)'
}

# Shell-readable form of the same result: one key=value per line, values never
# containing a newline. reason= is empty when resolved.
fm_project_resolve_lines() {
  fm_project_resolve_json "${1:-}" "${2:-}" | jq -r '
    "status=\(.status)",
    "project=\(.project // "")",
    "token=\(.token // "")",
    "source=\(.source // "")",
    "reason=\(.reason // "")"'
}

# The label a per-project grill workspace carries. Herdr labels are free text;
# the registry name is capitalized for display only, and the token - not this
# label - is the identity a caller matches on.
fm_project_display_name() {
  local name=${1:-}
  if [ -z "$name" ]; then
    printf '\n'
    return 0
  fi
  printf '%s%s\n' "$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')" "${name:1}"
}
