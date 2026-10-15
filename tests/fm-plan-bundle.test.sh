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
-----BEGIN RSA PRIVATE KEY-----
fixture-private-material
-----END RSA PRIVATE KEY-----
public result
FIXTURE
  printf '<h1>Plan</h1>\n<p>100.100.10.20</p>\n' > "$task/plan.html"
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
<redacted>
public result
EXPECTED
  cmp -s "$TMP_ROOT/expected-report" "$dir/report.md" || fail 'token, assignment, or private-key scrub differs'
  [ "$(cat "$dir/plan.html")" = $'<h1>Plan</h1>\n<p><tailnet-ip></p>' ] || fail 'HTML artifact was not scrubbed'
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
test_residual_leaks_refuse_entire_bundle
test_cgnat_guard_refuses_a_missed_scrub
test_optional_inputs_and_invalid_tasks
echo 'all fm-plan-bundle tests passed'
