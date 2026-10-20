#!/usr/bin/env bash
# Behavior tests for bin/fm-inbox.sh status - the row-state projection.
#
# state/<id>.status is an append-only EVENT log, so its last line is history,
# never the current state. `status` must therefore report every row's state from
# the reconciled read (bin/fm-crew-state.sh through bin/fm-fleet-snapshot.sh)
# and must print unknown with its source when nothing establishes a state. These
# cases drive the renderer through a fixed snapshot, so the contract is pinned
# without a live fleet:
#   (a) last event `done:` but reconciled state working -> the event is never
#       rendered as the state, in either section
#   (b) no establishable state -> unknown with its source, never done
#   (c) a captain hold is an explicit record -> waiting-on-you/captain-hold
#   (d) an in-flight row with no task record -> unknown/no-worker-record
#   (e) an unavailable or unusable snapshot -> rows still listed, each unknown
#       with that source, and the command still exits 0
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX="$ROOT/bin/fm-inbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-status)

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state/inbox" "$HOME_DIR/data" "$HOME_DIR/config"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"

# The status logs the renderer must NEVER read a state from: each ends in a
# terminal-looking event while its reconciled state says otherwise.
printf 'working: starting\nnote: mid-flight detail\ndone: PR merged and cleaned up\n' \
  > "$HOME_DIR/state/alpha.status"
printf 'done: everything finished here\n' > "$HOME_DIR/state/beta.status"

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha - Alpha work (repo: demo) (kind: ship)
- [ ] beta - Beta work (repo: demo) (kind: ship)
- [ ] held-row - Held row (repo: demo) (kind: ship)
- [ ] ghost - Ghost row (repo: demo) (kind: ship)

## Queued
- [ ] queued-row - Queued row (repo: demo) (kind: ship)
EOF

mkdir -p "$TMP_ROOT/fixture"
cat > "$TMP_ROOT/fixture/snapshot.json" <<'EOF'
{
  "tasks": [
    {"id": "alpha", "kind": "ship",
     "current_state": {"state": "working", "source": "run-step", "detail": "running implementation"}},
    {"id": "beta", "kind": "ship",
     "current_state": {"state": "unknown", "source": "none", "detail": "backend target gone"}},
    {"id": "held-row", "kind": "ship",
     "current_state": {"state": "unknown", "source": "none", "detail": "backend target gone"}}
  ],
  "backlog": {"records": [
    {"id": "alpha", "state": "in_flight", "title": "Alpha work", "hold_kind": null},
    {"id": "beta", "state": "in_flight", "title": "Beta work", "hold_kind": null},
    {"id": "held-row", "state": "in_flight", "title": "Held row", "hold_kind": "captain"},
    {"id": "ghost", "state": "in_flight", "title": "Ghost row", "hold_kind": null},
    {"id": "queued-row", "state": "queued", "title": "Queued row", "hold_kind": null}
  ]}
}
EOF

cat > "$TMP_ROOT/fixture/snapshot.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP_ROOT/fixture/snapshot.json"
EOF
chmod +x "$TMP_ROOT/fixture/snapshot.sh"

printf 'not json at all\n' > "$TMP_ROOT/fixture/garbage.json"
cat > "$TMP_ROOT/fixture/garbage.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP_ROOT/fixture/garbage.json"
EOF
chmod +x "$TMP_ROOT/fixture/garbage.sh"

# A reader that dies after printing part of a snapshot: the fragment must never
# be rendered as a generation.
cat > "$TMP_ROOT/fixture/partial.sh" <<EOF
#!/usr/bin/env bash
printf '{"tasks": [{"id": "alpha"}], "bac'
exit 1
EOF
chmod +x "$TMP_ROOT/fixture/partial.sh"

run_status() {  # <snapshot-bin>
  FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_INBOX_SNAPSHOT_BIN="$1" \
    "$INBOX" status 2>/dev/null
}

# --- the good path ----------------------------------------------------------

OUT=$(run_status "$TMP_ROOT/fixture/snapshot.sh") || fail "status exited non-zero on a readable snapshot"

assert_contains "$OUT" "working/run-step · running implementation | alpha - Alpha work" \
  "(a) alpha's in-flight row renders the reconciled working state"
assert_contains "$OUT" "alpha ship | state: working · source: run-step · running implementation" \
  "(a) alpha's worker row renders the reconciled working state"
assert_not_contains "$OUT" "done: PR merged and cleaned up" \
  "(a) the status log's last event is never rendered as the state"
assert_not_contains "$OUT" "done: everything finished here" \
  "(b) a finished-looking event is not rendered when no state was established"
assert_contains "$OUT" "unknown/none · backend target gone | beta - Beta work" \
  "(b) an unestablished state renders unknown with its source"
assert_contains "$OUT" "waiting-on-you/captain-hold | held-row - Held row" \
  "(c) a captain hold renders as waiting-on-you from that explicit record"
assert_contains "$OUT" "unknown/no-worker-record | ghost - Ghost row" \
  "(d) an in-flight row with no task record renders unknown with its source"
assert_not_contains "$OUT" "queued-row - Queued row" \
  "(d) the in-flight section stays scoped to in-flight rows"

# --- the snapshot cannot be read -------------------------------------------

OUT=$(run_status "$TMP_ROOT/fixture/absent.sh") \
  || fail "(e) status exited non-zero when the snapshot reader is missing"
assert_contains "$OUT" "unknown/snapshot-unavailable | alpha - Alpha work" \
  "(e) a missing reader leaves rows listed and explicitly unknown"
assert_not_contains "$OUT" "done:" \
  "(e) a missing reader never falls back to the last status event"

OUT=$(run_status "$TMP_ROOT/fixture/garbage.sh") \
  || fail "(e) status exited non-zero when the snapshot is unusable"
assert_contains "$OUT" "unknown/snapshot-unavailable | beta - Beta work" \
  "(e) an unusable snapshot leaves rows listed and explicitly unknown"
assert_not_contains "$OUT" "done:" \
  "(e) an unusable snapshot never falls back to the last status event"

OUT=$(run_status "$TMP_ROOT/fixture/partial.sh") \
  || fail "(e) status exited non-zero when the reader dies mid-snapshot"
assert_contains "$OUT" "unknown/snapshot-unavailable | alpha - Alpha work" \
  "(e) a partial snapshot is discarded, not rendered as a generation"

pass "fm-inbox.sh status projects reconciled row state, never the last event"
