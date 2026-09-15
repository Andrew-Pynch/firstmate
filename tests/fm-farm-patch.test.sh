#!/usr/bin/env bash
# tests/fm-farm-patch.test.sh - behavior tests for bin/fm-farm-patch.sh.
#
# The contract under test: a fork keeps its own fixes as a named patch set that
# lives off the default branch, so the default branch stays an ancestor of
# origin and still fast-forwards. Three properties carry that contract, and each
# one is driven through the tool itself rather than through its internals:
#   - the set is enumerable, in application order
#   - a replay either lands the whole set or changes nothing, and a conflict
#     stops, reports, and leaves the target where it was
#   - a checkout's content is comparable to what the set produces, so "every
#     code root carries the same patch content" is provable
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-farm-patch)
trap fm_test_cleanup EXIT

TOOL="$ROOT/bin/fm-farm-patch.sh"

# A store with two patches that compose, over a repo whose own history holds the
# base the manifest records. Writes the base commit to <dir>/base and echoes the
# store directory.
make_store() {  # <dir> -> echoes <dir>/store
  local dir=$1
  local repo=$dir/repo
  local base
  mkdir -p "$dir/store"
  fm_git_init_commit "$repo"
  printf 'one\n' > "$repo/a.txt"
  printf 'two\n' > "$repo/b.txt"
  git -C "$repo" add a.txt b.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add files'
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'one\npatched-a\n' > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'fix(a): patch a'
  git -C "$repo" diff "$base" HEAD > "$dir/store/0001-a.patch"
  printf 'two\npatched-b\n' > "$repo/b.txt"
  printf 'three\n' > "$repo/c.txt"
  git -C "$repo" add b.txt c.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'fix(b): patch b'
  git -C "$repo" diff HEAD~1 HEAD > "$dir/store/0002-b.patch"
  fm_git_add_origin "$repo" "$dir/origin.git"
  printf '%s\n' "$base" > "$dir/base"
  {
    printf 'series\t%s\t2026-09-14\ttest fixture\n' "$base"
    printf 'patch\t0001\ta\t0001-a.patch\tfixture\tfirst fixture patch\tfix(a): patch a\n'
    printf 'patch\t0002\tb\t0002-b.patch\tfixture\tsecond fixture patch\tfix(b): patch b\n'
  } > "$dir/store/manifest"
  printf '%s\n' "$dir/store"
}

# A store whose only patch cannot apply: it expects context the base never had.
make_conflicting_store() {  # <dir> -> echoes <dir>/store
  local dir=$1
  mkdir -p "$dir/store"
  cat > "$dir/store/0001-never.patch" <<'PATCH'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-# something this base never held
+# patched
PATCH
  {
    printf 'series\t-\t2026-09-14\ttest fixture\n'
    printf 'patch\t0001\tnever\t0001-never.patch\tfixture\tnever applies\tfix: never\n'
  } > "$dir/store/manifest"
  printf '%s\n' "$dir/store"
}

test_list_is_ordered_and_enumerable() {
  local store out
  store=$(make_store "$TMP_ROOT/list")
  out=$("$TOOL" --store "$store" list) || fail "list failed: $out"
  assert_contains "$out" 'patches	2' "list must report the number of patches"
  [ "$(printf '%s\n' "$out" | grep -c '^000[12]')" = 2 ] \
    || fail "list must name both patches: $out"
  [ "$(printf '%s\n' "$out" | sed -n '/^0001/p' | cut -f2)" = a ] \
    || fail "list must print the patches in application order: $out"
  pass "list names the set in application order"
}

test_replay_lands_the_whole_set() {
  local dir store repo target tip base
  dir="$TMP_ROOT/replay"
  store=$(make_store "$dir")
  repo="$dir/repo"
  target="$dir/target"
  base=$(cat "$dir/base")
  git -C "$repo" worktree add --detach -q "$target" "$base"
  fm_git_identity
  "$TOOL" --store "$store" replay "$target" > "$dir/out" 2>&1 \
    || fail "replay failed: $(cat "$dir/out")"
  [ "$(cat "$target/a.txt")" = "one
patched-a" ] || fail "patch 0001 must land a.txt: $(cat "$target/a.txt")"
  [ "$(cat "$target/b.txt")" = "two
patched-b" ] || fail "patch 0002 must land b.txt: $(cat "$target/b.txt")"
  tip=$(git -C "$target" rev-parse HEAD)
  [ "$(git -C "$repo" rev-parse refs/farm-patches/previous)" = "$base" ] \
    || fail "the tip the target left must be recorded before it moves"
  [ "$(git -C "$repo" rev-parse refs/farm-patches/current)" = "$tip" ] \
    || fail "the new lineage must be recorded"
  [ ! -e "$target.fm-patch-scratch" ] || fail "a clean replay must remove its scratch worktree"
  "$TOOL" --store "$store" replay "$target" > "$dir/out2" 2>&1 \
    || fail "a second replay over landed content must succeed: $(cat "$dir/out2")"
  [ "$(git -C "$target" rev-parse HEAD)" = "$tip" ] \
    || fail "replaying an unchanged base must reproduce the same tip"
  pass "replay lands the whole set, records both tips, and reproduces itself"
}

test_check_distinguishes_content() {
  local dir store repo reference target out base replayed_set unpatched_set
  dir="$TMP_ROOT/check"
  store=$(make_store "$dir")
  repo="$dir/repo"
  reference="$dir/reference"
  target="$dir/target"
  base=$(cat "$dir/base")
  git -C "$repo" worktree add --detach -q "$reference" "$base"
  git -C "$repo" worktree add --detach -q "$target" "$base"
  fm_git_identity
  # The expectation is what a replay produces, so one replay has to run before
  # any checkout can be compared against the set.
  "$TOOL" --store "$store" replay "$reference" > /dev/null 2>&1 \
    || fail "the reference replay failed"
  replayed_set=$("$TOOL" --store "$store" check "$reference") \
    || fail "check on the replayed target must match"
  assert_contains "$replayed_set" 'matched' "check must report the matched count"
  out=$("$TOOL" --store "$store" check "$target") && fail "check on an unpatched target must report differences: $out"
  assert_contains "$out" 'differs' "an unpatched target must report the modified files as differing"
  assert_contains "$out" 'absent' "an unpatched target must report the produced files it lacks as absent"
  unpatched_set=$(printf '%s\n' "$out" | sed -n 's/^set	//p')
  [ "$(printf '%s\n' "$replayed_set" | sed -n 's/^set	//p')" != "$unpatched_set" ] \
    || fail "the two contents must not share a set identity"
  pass "check separates an unpatched checkout from a replayed one by content"
}

test_replay_refuses_dirty_and_conflicting_targets() {
  local dir store repo target out rc base
  local bad_store bad_target
  dir="$TMP_ROOT/refuse"
  store=$(make_store "$dir")
  repo="$dir/repo"
  target="$dir/target"
  base=$(cat "$dir/base")
  git -C "$repo" worktree add --detach -q "$target" "$base"
  fm_git_identity
  printf 'unlanded\n' > "$target/UNLANDED.txt"
  out=$("$TOOL" --store "$store" replay "$target" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a dirty target must be refused"
  assert_contains "$out" 'unlanded changes' "the refusal must name what it refused"
  [ -f "$target/UNLANDED.txt" ] || fail "a refusal must leave the unlanded file alone"

  rm -f "$target/UNLANDED.txt"
  bad_store=$(make_conflicting_store "$dir")
  bad_target="$dir/bad-target"
  git -C "$repo" worktree add --detach -q "$bad_target" "$base"
  out=$("$TOOL" --store "$bad_store" --base "$base" replay "$bad_target" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a patch that cannot apply must stop the replay"
  assert_contains "$out" 'conflict' "the replay must report the patch it stopped on"
  [ "$(git -C "$bad_target" rev-parse HEAD)" = "$base" ] \
    || fail "a conflicted replay must leave the target where it was"
  [ -z "$(git -C "$bad_target" status --porcelain)" ] \
    || fail "a conflicted replay must not half-write the target: $(git -C "$bad_target" status --porcelain)"
  [ -e "$bad_target.fm-patch-scratch" ] \
    || fail "a conflicted replay must leave its scratch worktree for inspection"

  # A checkout that is on its default branch must never be repointed: detaching
  # it there is the diverged state the whole mechanism exists to prevent.
  local plain_clone="$dir/plain"
  git clone -q "$dir/origin.git" "$plain_clone"
  out=$("$TOOL" --store "$store" replay "$plain_clone" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "replaying a checkout that sits on its default branch must be refused"
  assert_contains "$out" 'default branch' "the refusal must name the branch it refuses to detach"
  [ "$(git -C "$plain_clone" symbolic-ref --quiet --short HEAD)" = main ] \
    || fail "the refusal must leave the checkout on its default branch"
  pass "replay refuses unlanded work, a conflict, and a checkout on its default branch"
}

test_list_is_ordered_and_enumerable
test_replay_lands_the_whole_set
test_check_distinguishes_content
test_replay_refuses_dirty_and_conflicting_targets

echo "# fm-farm-patch.test.sh: all assertions passed"
