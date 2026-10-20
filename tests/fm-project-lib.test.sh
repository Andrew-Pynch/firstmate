#!/usr/bin/env bash
# Behavior tests for registry-backed project resolution (bin/fm-project-lib.sh).
#
# The resolver is the one place that turns a task's repo plus an optional
# sub-project token into a registered project and its Herdr colour token, so
# these cases pin the contract every caller depends on: a declared token is
# used, a single declared token needs none, a project's declared default is
# reported as such, and every failure returns an explicit unresolved reason
# rather than a plausible-looking token.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-project-lib.sh
. "$ROOT/bin/fm-project-lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-project-lib)
DATA_DIR=$TMP_ROOT/data
mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/projects.md" <<'EOF'
# Projects

- mono [direct-PR +yolo] subprojects=alpha,beta - Org/mono
- solo [local-only] subprojects=solo - Org/solo
- bare [no-mistakes] - Org/bare
EOF
export FM_HOME=$TMP_ROOT
export FM_DATA_OVERRIDE=$DATA_DIR

field() { # <result-key=value stream> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

resolves() { # <repo> <token> <want-project> <want-token> <want-source>
  local out
  out=$(fm_project_resolve_lines "$1" "$2")
  [ "$(field "$out" status)" = resolved ] \
    || fail "$1/$2 should resolve, got: $out"
  [ "$(field "$out" project)" = "$3" ] || fail "$1/$2 project: $out"
  [ "$(field "$out" token)" = "$4" ] || fail "$1/$2 token: $out"
  [ "$(field "$out" source)" = "$5" ] || fail "$1/$2 source: $out"
}

unresolved() { # <repo> <token> <reason-substring>
  local out
  out=$(fm_project_resolve_lines "$1" "$2")
  [ "$(field "$out" status)" = unresolved ] \
    || fail "$1/$2 should be unresolved, got: $out"
  case "$(field "$out" reason)" in
  *"$3"*) ;;
  *) fail "$1/$2 reason should mention '$3', got: $out" ;;
  esac
}

# A repo that declares several tokens without a supplied one resolves to its
# declared default, and says so rather than looking like an explicit choice.
resolves mono '' mono alpha default
# A supplied token wins over the declared default.
resolves mono beta mono beta explicit
# A project that declares exactly one token needs no supplied token.
resolves solo '' solo solo only
resolves solo solo solo solo explicit
# A task's recorded project is a path, so a path resolves by its basename.
resolves "$TMP_ROOT/projects/mono" '' mono alpha default
resolves "$TMP_ROOT/projects/mono/" beta mono beta explicit

# Every failure is explicit. A project whose line declares no colour token is
# reported as exactly that, never given a made-up token.
unresolved stranger '' 'not a registered project'
unresolved bare '' 'declares no colour token'
unresolved mono gamma 'not declared for project "mono"'
unresolved solo alpha 'not declared for project "solo"'
# A project that declares no tokens at all cannot be given one, so even a
# supplied token stays unresolved rather than being trusted on its own.
unresolved bare bare 'declares no colour token'
pass "resolution uses a declared token, a sole token, or the declared default"

# The registry map is what the snapshots thread into jq, so it must carry every
# registered name and exactly the tokens its line declares.
map=$(fm_project_registry_map_json)
printf '%s' "$map" | jq -e '
  (.mono.tokens == ["alpha","beta"])
  and (.solo.tokens == ["solo"])
  and (.bare.tokens == [])
  and (keys | sort == ["bare","mono","solo"])
' >/dev/null || fail "registry map wrong: $map"
printf '%s' "$map" | jq -e 'type == "object"' >/dev/null \
  || fail "registry map must be JSON even from a partial parse"
pass "the registry map exposes each project's declared tokens"

# The JSON form and the jq definition callers splice in must agree with the
# line form the spawn and grill helpers read.
json=$(fm_project_resolve_json mono)
printf '%s' "$json" | jq -e '
  .status == "resolved" and .project == "mono" and .token == "alpha" and .source == "default"
' >/dev/null || fail "resolve_json disagreed with resolve_lines: $json"
jq -n --argjson map "$map" "$FM_PROJECT_JQ_DEFS"' fm_project_resolve("mono"; "beta"; $map)' \
  | jq -e '.status == "resolved" and .token == "beta" and .source == "explicit"' >/dev/null \
  || fail "FM_PROJECT_JQ_DEFS disagreed with the bash resolver"
jq -n --argjson map "$map" "$FM_PROJECT_JQ_DEFS"' fm_project_resolve("firstmate"; null; $map)' \
  | jq -e '.status == "unresolved" and (.reason | test("not a registered project"))' >/dev/null \
  || fail "unresolved reason must survive the jq definitions"
pass "the line, JSON, and jq forms of resolution agree"

# A home with no registry at all is still an explicit unresolved, never a
# crash, never a silent token.
FM_DATA_OVERRIDE=$TMP_ROOT/empty fm_project_resolve_lines mono >/dev/null \
  || fail "a missing registry must not fail the resolver"
out=$(FM_DATA_OVERRIDE=$TMP_ROOT/empty fm_project_resolve_lines mono)
[ "$(field "$out" status)" = unresolved ] || fail "a missing registry must report unresolved: $out"
pass "a missing registry reports unresolved instead of guessing"

echo "ALL TESTS PASSED"
