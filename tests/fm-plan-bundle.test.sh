#!/usr/bin/env bash
# Exercise the local bundle CLI: scrubbed publication bytes, digests, source
# preservation, and all-or-nothing refusal of residual leaks.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-plan-bundle)
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/bundles"

bundle() {
  FM_HOME="$TMP_ROOT/home" HOME="$TMP_ROOT/user.[literal]#home" TMPDIR="$TMP_ROOT/bundles" \
    bash "$ROOT/bin/fm-plan-bundle.sh" "$@"
}

assert_refused() { # <task-id>
  local rc=0
  bundle "$1" > "$TMP_ROOT/refused.out" 2> "$TMP_ROOT/refused.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "unsafe or missing input did not exit 1"
  [ ! -s "$TMP_ROOT/refused.out" ] || fail "refusal printed publication output"
  [ -s "$TMP_ROOT/refused.err" ] || fail "refusal did not explain the error"
  [ -z "$(find "$TMP_ROOT/bundles" -mindepth 1 -print)" ] || fail "refusal retained a bundle"
}

test_scrub_and_digest() {
  local task output dir expected digest name
  task="$TMP_ROOT/home/data/scrub"
  mkdir -p "$task"
  printf 'home: %s/project\n' "$TMP_ROOT/user.[literal]#home" > "$task/brief.md"
  cat >> "$task/brief.md" <<'FIXTURE'
host: big-ron.tail012abc.ts.net
ips: 100.64.0.1 100.127.255.254
outside: 100.63.255.255 100.128.0.1
FIXTURE
  cat > "$task/report.md" <<'FIXTURE'
tokens: ghp_fixture gho_fixture ghu_fixture ghs_fixture ghr_fixture github_pat_fixture xoxa-fixture xoxb-fixture xoxp-fixture xoxr-fixture xoxs-fixture sk-fixture
assignments: API_TOKEN=fixture APP_SECRET=fixture API_KEY=fixture DB_PASSWORD=fixture
quoted: API_TOKEN="fixture with spaces" DB_PASSWORD='fixture with spaces'
escaped: DB_PASSWORD="alpha\"secret phrase" APP_SECRET='alpha\'secret phrase'
backslashes: API_KEY="alpha\\" TOKEN='beta\\'
ampersands: DB_PASSWORD="alpha&beta" API_TOKEN='alpha&beta' SECRET=alpha&beta
literal values: API_KEY="alpha\&beta" APP_SECRET="cost$5 &copy;"
ordinary: task-id ask-user mask-value
delimited: (sk-fixture),[ghp_fixture];"xoxb-fixture"
public result
FIXTURE
  cat > "$task/plan.html" <<'FIXTURE'
<h1>Plan</h1>
<p>100.100.10.20</p>
<p title="A &amp; B">&quot;safe text&quot; &#34; &#x27;</p>
<code>DB_PASSWORD=fixture </code>
<code>API_KEY="fixture with spaces" </code><span>&quot;</span>
FIXTURE
  cp "$task/report.md" "$TMP_ROOT/original-report.md"
  printf 'not an artifact\n' > "$task/ignored.txt"
  output=$(bundle scrub) || fail 'scrubbable fixture was refused'
  dir=$(printf '%s\n' "$output" | sed -n 's/^bundle=//p')
  [ -d "$dir" ] || fail 'bundle directory was not returned'
  cat > "$TMP_ROOT/expected-brief" <<EOF
home: ~/project
host: <tailnet-host>
ips: <tailnet-ip> <tailnet-ip>
outside: 100.63.255.255 100.128.0.1
EOF
  cmp -s "$TMP_ROOT/expected-brief" "$dir/brief.md" || fail 'path, host, or CGNAT scrub changed the wrong bytes'
  cat > "$TMP_ROOT/expected-report" <<'EXPECTED'
tokens: <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted> <redacted>
assignments: <redacted> <redacted> <redacted> <redacted>
quoted: <redacted> <redacted>
escaped: <redacted> <redacted>
backslashes: <redacted> <redacted>
ampersands: <redacted> <redacted> <redacted>
literal values: <redacted> <redacted>
ordinary: task-id ask-user mask-value
delimited: (<redacted>),[<redacted>];"<redacted>"
public result
EXPECTED
  cmp -s "$TMP_ROOT/expected-report" "$dir/report.md" || fail 'token or assignment scrub differs'
  cat > "$TMP_ROOT/expected-plan" <<'EXPECTED'
<h1>Plan</h1>
<p><tailnet-ip></p>
<p title="A &amp; B">&quot;safe text&quot; &#34; &#x27;</p>
<code><redacted> </code>
<code><redacted> </code><span>&quot;</span>
EXPECTED
  cmp -s "$TMP_ROOT/expected-plan" "$dir/plan.html" || fail 'HTML scrub changed safe markup or missed plain credentials'
  cmp -s "$TMP_ROOT/original-report.md" "$task/report.md" || fail 'source report changed'
  [ ! -e "$dir/ignored.txt" ] || fail 'bundle copied an unapproved file'
  for name in brief.md report.md plan.html; do
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(sha256sum "$dir/$name")
    else
      digest=$(shasum -a 256 "$dir/$name")
    fi
    expected="${digest%% *}  $name"
    printf '%s\n' "$output" | grep -Fxq "$expected" || fail "digest does not bind the scrubbed $name bytes"
  done
  rm -rf -- "$dir"
  pass 'all leak classes scrubbed, digests match, sources unchanged'
}

test_private_keys_refused_before_bundle_creation() {
  local name marker placement
  mkdir -p "$TMP_ROOT/home/data/private-key" "$TMP_ROOT/no-mktemp"
  cat > "$TMP_ROOT/no-mktemp/mktemp" <<'SHIM'
#!/usr/bin/env bash
printf 'bundle creation attempted\n' >&2
exit 99
SHIM
  chmod +x "$TMP_ROOT/no-mktemp/mktemp"
  for name in brief.md report.md plan.html; do
    for marker in '-----BEGIN PRIVATE KEY-----' '-----BEGIN RSA PRIVATE KEY-----' \
      '-----BEGIN EC PRIVATE KEY-----' '-----BEGIN OPENSSH PRIVATE KEY-----' \
      '-----BEGIN ENCRYPTED PRIVATE KEY-----' '-----END PRIVATE KEY-----'; do
      for placement in plain assignment; do
        printf 'safe brief\n' > "$TMP_ROOT/home/data/private-key/brief.md"
        printf 'safe report\n' > "$TMP_ROOT/home/data/private-key/report.md"
        printf 'safe plan\n' > "$TMP_ROOT/home/data/private-key/plan.html"
        if [ "$placement" = plain ]; then
          printf 'safe heading\n\n%s\nfixture-private-material\n%s\n' "$marker" "${marker/BEGIN/END}" \
            > "$TMP_ROOT/home/data/private-key/$name"
        else
          printf 'safe heading\n\nAPI_KEY="%s"\nfixture-private-material\n' "$marker" \
            > "$TMP_ROOT/home/data/private-key/$name"
        fi
        PATH="$TMP_ROOT/no-mktemp:$PATH" assert_refused private-key
        [ "$(cat "$TMP_ROOT/refused.err")" = "error: bundle refused: private key marker in $name:3" ] \
          || fail 'private key refusal did not report only artifact and line before bundle creation'
      done
    done
  done
  pass 'raw private keys refuse before bundle creation with only artifact and line diagnostics'
}

test_unsupported_quoted_assignments_refused() {
  local assignment
  mkdir -p "$TMP_ROOT/home/data/unterminated"
  for assignment in 'DB_PASSWORD="alpha\"secret phrase' "APP_SECRET='alpha\\'secret phrase" \
    'API_KEY=alpha"secret phrase"' 'API_TOKEN="alpha"suffix"secret phrase"'; do
    printf '%s\ncontinued credential\n' "$assignment" > "$TMP_ROOT/home/data/unterminated/report.md"
    assert_refused unterminated
    [ "$(cat "$TMP_ROOT/refused.err")" = 'error: bundle refused: residual leak or unreadable file in report.md' ] \
      || fail 'unsupported quoting exposed credential bytes'
  done
  pass 'unterminated, multiline, and concatenated quoted assignments refuse without leaked bytes'
}

test_unquoted_escaped_assignments_refused() {
  local assignment name
  mkdir -p "$TMP_ROOT/home/data/escaped-value"
  for name in brief.md report.md plan.html; do
    for assignment in 'DB_PASSWORD=alpha\ secretphrase' $'API_TOKEN=alpha\\\tsecretphrase' \
      $'APP_SECRET=alpha\\\nsecretphrase' $'API_KEY=alpha\\\nsecretphrase\\\nlastfragment' \
      'DB_PASSWORD=alpha\\secretphrase'; do
      printf 'safe brief\n' > "$TMP_ROOT/home/data/escaped-value/brief.md"
      printf 'safe report\n' > "$TMP_ROOT/home/data/escaped-value/report.md"
      printf 'safe plan\n' > "$TMP_ROOT/home/data/escaped-value/plan.html"
      printf '%s\n' "$assignment" > "$TMP_ROOT/home/data/escaped-value/$name"
      cp "$TMP_ROOT/home/data/escaped-value/$name" "$TMP_ROOT/original-escaped"
      assert_refused escaped-value
      [ "$(cat "$TMP_ROOT/refused.err")" = "error: bundle refused: residual leak or unreadable file in $name" ] \
        || fail 'unquoted escaped assignment exposed credential fragments'
      cmp -s "$TMP_ROOT/original-escaped" "$TMP_ROOT/home/data/escaped-value/$name" \
        || fail 'refusal changed the original escaped assignment'
    done
  done
  pass 'unquoted escaped spaces, tabs, backslashes, and continuations refuse without credential fragments'
}

test_html_encoded_assignments_refused() {
  local entity assignment
  mkdir -p "$TMP_ROOT/home/data/encoded-value"
  printf 'safe brief\n' > "$TMP_ROOT/home/data/encoded-value/brief.md"
  printf 'safe report\n' > "$TMP_ROOT/home/data/encoded-value/report.md"
  for entity in '&quot;' '&apos;' '&#34;' '&#39;' '&#034;' '&#x22;' '&#X22;' '&#x27;' \
    '&bsol;' '&#92;' '&#x5c;' '&Tab;' '&amp;quot;'; do
    for assignment in "DB_PASSWORD=${entity}alpha secretphrase${entity}" \
      "APP_SECRET=alpha${entity}secretphrase moresecret" \
      "API_KEY=\"alpha${entity}secretphrase\"" \
      "API_TOKEN='alpha${entity}secretphrase'" \
      "DB_PASSWORD=\"alpha\\${entity}secretphrase\""; do
      printf '<code>%s </code>\n' "$assignment" > "$TMP_ROOT/home/data/encoded-value/plan.html"
      cp "$TMP_ROOT/home/data/encoded-value/plan.html" "$TMP_ROOT/original-encoded"
      assert_refused encoded-value
      [ "$(cat "$TMP_ROOT/refused.err")" = 'error: bundle refused: residual leak or unreadable file in plan.html' ] \
        || fail 'HTML-encoded assignment exposed credential fragments'
      cmp -s "$TMP_ROOT/original-encoded" "$TMP_ROOT/home/data/encoded-value/plan.html" \
        || fail 'refusal changed the original HTML-encoded assignment'
    done
  done
  pass 'HTML-encoded quotes and escapes refuse without output, credential fragments, or retained bundles'
}

test_command_substitution_assignments_refused() {
  local format assignment name
  mkdir -p "$TMP_ROOT/home/data/substitution"
  for name in brief.md report.md plan.html; do
    while IFS= read -r format; do
      assignment=${format/'%s'/"$TMP_ROOT/executed"}
      printf 'safe brief\n' > "$TMP_ROOT/home/data/substitution/brief.md"
      printf 'safe report\n' > "$TMP_ROOT/home/data/substitution/report.md"
      printf 'safe plan\n' > "$TMP_ROOT/home/data/substitution/plan.html"
      printf '%s\n' "$assignment" > "$TMP_ROOT/home/data/substitution/$name"
      cp "$TMP_ROOT/home/data/substitution/$name" "$TMP_ROOT/original-substitution"
      assert_refused substitution
      [ "$(cat "$TMP_ROOT/refused.err")" = "error: bundle refused: residual leak or unreadable file in $name" ] \
        || fail 'command substitution refusal exposed credential fragments'
      [ ! -e "$TMP_ROOT/executed" ] || fail 'artifact command substitution was evaluated'
      cmp -s "$TMP_ROOT/original-substitution" "$TMP_ROOT/home/data/substitution/$name" \
        || fail 'refusal changed the original command substitution'
    done <<'FORMATS'
DB_PASSWORD=$(echo "alpha secretphrase" > "%s")
DB_PASSWORD=`echo "alpha secretphrase" > "%s"`
API_TOKEN="$(echo "alpha secretphrase" > "%s")"
APP_SECRET="`echo "alpha secretphrase" > "%s"`"
API_KEY=prefix$(echo "alpha secretphrase" > "%s")suffix
API_KEY=prefix`echo "alpha secretphrase" > "%s"`suffix
FORMATS
  done
  pass 'command substitutions refuse without evaluation, credential fragments, or retained bundles'
}

test_residual_leaks_refuse_entire_bundle() {
  local leak
  mkdir -p "$TMP_ROOT/home/data/leak"
  printf 'safe brief\n' > "$TMP_ROOT/home/data/leak/brief.md"
  # Each value survives the scrub intentionally, exercising the separate guard.
  for leak in '/home/someone-else/project' 'host.other.ts.net' 'PRIVATE KEY'; do
    printf '%s\n' "$leak" > "$TMP_ROOT/home/data/leak/report.md"
    assert_refused leak
    if grep -Fq "$leak" "$TMP_ROOT/refused.err"; then
      fail 'refusal printed leaked bytes'
    fi
  done
  pass 'residual home, tailnet, and private-key leaks refuse without output or retained files'
}

test_cgnat_guard_refuses_a_missed_scrub() {
  local real_sed
  real_sed=$(command -v sed)
  mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/home/data/missed-ip"
  # Simulate a scrub miss in the external transformer, through the public CLI.
  # This proves that the independent post-transform leak guard also covers IPs.
  cat > "$TMP_ROOT/fakebin/sed" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = -E ]; then
  for last in "$@"; do :; done
  cat "$last"
else
  exec "$REAL_SED" "$@"
fi
SHIM
  chmod +x "$TMP_ROOT/fakebin/sed"
  printf '100.64.1.2\n' > "$TMP_ROOT/home/data/missed-ip/report.md"
  REAL_SED="$real_sed" PATH="$TMP_ROOT/fakebin:$PATH" assert_refused missed-ip
  pass 'independent CGNAT leak guard refuses a simulated scrub miss'
}

test_optional_inputs_and_invalid_tasks() {
  local output dir
  mkdir -p "$TMP_ROOT/home/data/only-report" "$TMP_ROOT/home/data/empty"
  printf 'safe report\n' > "$TMP_ROOT/home/data/only-report/report.md"
  output=$(bundle only-report) || fail 'report-only bundle was refused'
  dir=$(printf '%s\n' "$output" | sed -n 's/^bundle=//p')
  cmp -s "$dir/report.md" "$TMP_ROOT/home/data/only-report/report.md" || fail 'safe report changed'
  [ ! -e "$dir/brief.md" ] && [ ! -e "$dir/plan.html" ] || fail 'missing inputs were invented'
  rm -rf -- "$dir"
  assert_refused empty
  assert_refused absent
  assert_refused ../escape
  pass 'existing optional inputs accepted; empty, absent, and traversal tasks refused'
}

test_scrub_and_digest
test_private_keys_refused_before_bundle_creation
test_unsupported_quoted_assignments_refused
test_unquoted_escaped_assignments_refused
test_html_encoded_assignments_refused
test_command_substitution_assignments_refused
test_residual_leaks_refuse_entire_bundle
test_cgnat_guard_refuses_a_missed_scrub
test_optional_inputs_and_invalid_tasks
echo 'all fm-plan-bundle tests passed'
