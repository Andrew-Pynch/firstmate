#!/usr/bin/env bash
# tests/fm-remote-herdr-owner-lib.test.sh - the Herdr session-socket owner parser.
#
# Drives the real fm_remote_herdr_socket_owner from
# bin/fm-remote-herdr-owner-lib.sh against lsof field output. The socket path
# reaches the NAME field in two host shapes: macOS writes the bare path, while
# Linux lsof appends the socket type ("<path> type=STREAM"), and a comparison
# that expects only one shape reports a live, healthy server as unowned. The
# scripted cases pin the exact-path comparison and its near misses on every
# host; the live case binds a real unix socket held by a process lsof names
# herdr, so the same path is proven against the host's own lsof wherever that
# construction resolves. The dated NAME-field evidence for both shapes lives in
# docs/verification/runtime-backends.md ("fm-remote server birth and
# login-keychain access").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-owner-lib)
mkdir -p "$TMP_ROOT"
# The function resolves the socket's directory with pwd -P, so the fixture root
# must already be resolved: an unresolved symlinked temp root (macOS /tmp) would
# make every expected path disagree with the comparison under test.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

HOLDER_PIDS=()
trap 'if [ "${#HOLDER_PIDS[@]}" -gt 0 ]; then kill "${HOLDER_PIDS[@]}" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
REAL_LSOF=$(command -v lsof || true)
# Every case reaches lsof through this shim, so no case has to reshape PATH: a
# scripted case hands the parser the field output its own host's lsof would
# print, and a case that leaves FM_TEST_SOCKET_FIELDS unset falls through to
# that real lsof.
cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_SOCKET_FIELDS:-}" ]; then
  cat "$FM_TEST_SOCKET_FIELDS"
  exit 0
fi
exec "${FM_TEST_REAL_LSOF:-lsof}" "$@"
SH
chmod +x "$FAKEBIN/lsof"
PATH="$FAKEBIN:$PATH"
# The shim needs the absolute target: resolving bare `lsof` again would find
# the shim itself.
export FM_TEST_REAL_LSOF=${REAL_LSOF:-lsof}

SOCKET_DIR="$TMP_ROOT/sessions/fm-remote"
SOCKET="$SOCKET_DIR/herdr.sock"
mkdir -p "$SOCKET_DIR"
FAKE_PID=42001

fields() { # <file> <line...>: the -F output one lsof run would print
  local file=$1
  shift
  printf '%s\n' "$@" > "$file"
}

owner_from() { # <fields-file> <socket-path>: the function's verdict for it
  (
    export FM_TEST_SOCKET_FIELDS=$1
    fm_remote_herdr_socket_owner "$2"
  )
}

# --- both NAME-field shapes name the owner -----------------------------------

fields "$TMP_ROOT/macos-fields" "p$FAKE_PID" "n$SOCKET"
assert_equals "$FAKE_PID" "$(owner_from "$TMP_ROOT/macos-fields" "$SOCKET")" \
  "the bare macOS NAME field did not name the socket owner"

fields "$TMP_ROOT/linux-fields" "p$FAKE_PID" "n$SOCKET type=STREAM"
assert_equals "$FAKE_PID" "$(owner_from "$TMP_ROOT/linux-fields" "$SOCKET")" \
  "the Linux NAME field carrying the socket type did not name the socket owner"
pass "lsof's bare and socket-type-suffixed NAME fields both name the socket owner"

# --- the comparison stays exact ---------------------------------------------

assert_unowned() { # <msg> <name-field>
  fields "$TMP_ROOT/near-miss-fields" "p$FAKE_PID" "$2"
  assert_equals "" "$(owner_from "$TMP_ROOT/near-miss-fields" "$SOCKET")" "$1"
}

assert_unowned "a path that only extends the socket path was accepted" \
  "n$SOCKET.bak type=STREAM"
assert_unowned "another socket in the same session directory was accepted" \
  "n$SOCKET_DIR/herdr-client.sock type=STREAM"
assert_unowned "a path below the socket path was accepted" \
  "n$SOCKET/extra"
assert_unowned "a leading space was trimmed instead of compared exactly" \
  "n $SOCKET type=STREAM"
assert_unowned "trailing whitespace was trimmed instead of compared exactly" \
  "n$SOCKET "
assert_unowned "an anonymous socket carrying no path at all was accepted" \
  "ntype=STREAM"
pass "near-match NAME fields are never reported as the socket's owner"

# --- spaces in the path, and the resolved-path comparison --------------------

SPACED_DIR="$TMP_ROOT/dir with spaces"
mkdir -p "$SPACED_DIR"
SPACED="$SPACED_DIR/herdr.sock"
fields "$TMP_ROOT/spaced-fields" "p$FAKE_PID" "n$SPACED type=STREAM"
assert_equals "$FAKE_PID" "$(owner_from "$TMP_ROOT/spaced-fields" "$SPACED")" \
  "a socket path containing spaces was not matched"
fields "$TMP_ROOT/spaced-near-fields" "p$FAKE_PID" "n$SPACED_DIR/other herdr.sock type=STREAM"
assert_equals "" "$(owner_from "$TMP_ROOT/spaced-near-fields" "$SPACED")" \
  "a longer spaced path was accepted as the socket"

REAL_DIR="$TMP_ROOT/real-session"
LINK_DIR="$TMP_ROOT/link-session"
mkdir -p "$REAL_DIR"
ln -s "$REAL_DIR" "$LINK_DIR"
fields "$TMP_ROOT/symlinked-fields" "p$FAKE_PID" "n$REAL_DIR/herdr.sock type=STREAM"
assert_equals "$FAKE_PID" "$(owner_from "$TMP_ROOT/symlinked-fields" "$LINK_DIR/herdr.sock")" \
  "a socket reached through a symlinked directory no longer matched"
pass "spaces inside the path survive, and the resolved path still matches"

# --- the caller-facing boundaries are unchanged ------------------------------

rc=0
fm_remote_herdr_socket_owner "" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "an empty socket path was not refused"

# Every tool the function needs, minus lsof itself, so the case exercises the
# real "lsof does not resolve" boundary rather than a broken path.
NO_LSOF_PATH=$(fm_test_base_path_sans "$PATH" lsof)
rc=0
( PATH=$NO_LSOF_PATH; fm_remote_herdr_socket_owner "$SOCKET" ) >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an absent lsof was not reported as unresolved"
pass "an empty path and an absent lsof keep their exit status"

# --- the same path against a live socket and the host's own lsof -------------

# lsof selects the holder with -c herdr, so the fixture process has to be named
# herdr. Linux names a process from the path it was executed as, so a symlink to
# the interpreter presents it. macOS 26.6.2 names it from the resolved
# executable instead (comm read /Library/Develop... for the same symlink), so
# this construction cannot resolve there and the case reports a named
# capability skip rather than pretending to pass. The interpreter is proved by
# creating a unix socket, because a stub python3 that cannot import socket
# would otherwise fail the case where it should skip.
LIVE_PY=
if command -v python3 >/dev/null 2>&1; then
  LIVE_PY=$(python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX); print(sys.executable)' 2>/dev/null || true)
fi
if [ -z "$REAL_LSOF" ] || [ -z "$LIVE_PY" ]; then
  echo "skip: live socket proof: this host needs lsof and a python3 that can create a unix socket"
else
  HOLDER_DIR="$TMP_ROOT/holder"
  mkdir -p "$HOLDER_DIR"
  ln -sf "$LIVE_PY" "$HOLDER_DIR/herdr"
  # Bound under its own short, registered root: a unix socket path is capped
  # near 104 bytes, and the case's own temp root plus the long suffix crosses
  # that on macOS 26.6.2, where a 107-byte path failed bind with "AF_UNIX path
  # too long" while this shape (63 bytes there, 70 once resolved) binds. The
  # library already reaps a root it created, so no second cleanup path.
  LIVE_DIR=$(fm_test_tmproot fmso) || fail "cannot create a short socket directory"
  LIVE_SOCKET="$LIVE_DIR/s"
  "$HOLDER_DIR/herdr" -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120})" "$LIVE_SOCKET" server --session fm-remote &
  LIVE_HOLDER_PID=$!
  HOLDER_PIDS+=("$LIVE_HOLDER_PID")
  i=0
  while [ "$i" -lt 100 ] && [ ! -S "$LIVE_SOCKET" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -S "$LIVE_SOCKET" ]; then
    echo "skip: live socket proof: the fixture could not bind $LIVE_SOCKET on $(uname -s), so only the scripted NAME-field cases cover this host"
  else
    live_field=$(lsof -U -a -c herdr -Fpn 2>/dev/null | grep -F -m1 "n$LIVE_SOCKET" || true)
    if [ -z "$live_field" ]; then
      case "$(uname -s)" in
        Linux)
          fail "lsof -c herdr did not name the live fixture holder on Linux, where a process is named from the path it was executed as"
          ;;
        *)
          echo "skip: live socket proof: this host's lsof does not name the fixture holder ($(uname -s) names a process from its resolved executable), so only the scripted NAME-field cases cover it"
          ;;
      esac
    else
      case "$live_field" in
        "n$LIVE_SOCKET") live_shape="bare path" ;;
        "n$LIVE_SOCKET type="*) live_shape="path plus socket type" ;;
        *) fail "the host's lsof named the live socket in an unrecognized NAME field: [$live_field]" ;;
      esac
      assert_equals "$LIVE_HOLDER_PID" "$(fm_remote_herdr_socket_owner "$LIVE_SOCKET")" \
        "the live socket's holder was not identified through the host's own lsof"
      pass "a live unix socket held by a herdr-named process is identified through the host's lsof ($live_shape NAME field)"
    fi
  fi
fi
