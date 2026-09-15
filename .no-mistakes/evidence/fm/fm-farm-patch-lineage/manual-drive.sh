#!/usr/bin/env bash
# Manual product drive for bin/fm-farm-patch.sh against real git repositories.
set -u
TOOL="$1"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-patch-drive.XXXXXX")
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME='Farm Test' GIT_AUTHOR_EMAIL='farm@example.invalid'
export GIT_COMMITTER_NAME='Farm Test' GIT_COMMITTER_EMAIL='farm@example.invalid'
export GIT_AUTHOR_DATE='2026-09-14T00:00:00+00:00' GIT_COMMITTER_DATE='2026-09-14T00:00:00+00:00'
G() { git -C "$1" "${@:2}"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
echo "WORK=$WORK"
echo "TOOL=$TOOL"
mkdir -p "$WORK/store"

# --- upstream seed repo -----------------------------------------------------
mkdir -p "$WORK/seed"
git -C "$WORK/seed" init -q -b main
printf 'one\n' > "$WORK/seed/a.txt"; printf 'two\n' > "$WORK/seed/b.txt"
git -C "$WORK/seed" add -A; git -C "$WORK/seed" commit -qm 'upstream: a,b'
BASE=$(git -C "$WORK/seed" rev-parse HEAD)
printf 'upstream: baseline (recorded base) = %s\n' "$BASE"
git clone -q --bare "$WORK/seed" "$WORK/origin.git"
git -C "$WORK/seed" remote add origin "$WORK/origin.git"
git -C "$WORK/seed" push -q origin main

# --- farm fixes captured as an explicit patch set (written outside the repo) -
git -C "$WORK/seed" checkout -q -b farm-fixes
printf 'one\npatched-a\n' > "$WORK/seed/a.txt"
git -C "$WORK/seed" add -A; git -C "$WORK/seed" commit -qm 'fix(a): farm patch a'
git -C "$WORK/seed" diff "$BASE" HEAD > "$WORK/store/0001-a.patch"
printf 'two\npatched-b\n' > "$WORK/seed/b.txt"; printf 'three\n' > "$WORK/seed/c.txt"
git -C "$WORK/seed" add -A; git -C "$WORK/seed" commit -qm 'fix(b): farm patch b'
git -C "$WORK/seed" diff HEAD~1 HEAD > "$WORK/store/0002-b.patch"
git -C "$WORK/seed" checkout -q main
{
  printf 'series\t%s\t2026-09-14\tfarm fixes over upstream baseline\n' "$BASE"
  printf 'patch\t0001\ta\t0001-a.patch\tship\tfarm patch a\tfix(a): farm patch a\n'
  printf 'patch\t0002\tb\t0002-b.patch\tship\tfarm patch b\tfix(b): farm patch b\n'
} > "$WORK/store/manifest"

# --- Ron (host A), mate (host B), and an unpatched clone, all before advance -
git clone -q "$WORK/origin.git" "$WORK/ron"
git clone -q "$WORK/origin.git" "$WORK/mate"
git clone -q "$WORK/origin.git" "$WORK/fresh"

echo; echo "=== SCENARIO 1: list is explicit and ordered ==="
run "$TOOL" --store "$WORK/store" list

echo; echo "=== SCENARIO 2: replay lands the whole set on Ron (detached) ==="
run git -C "$WORK/ron" checkout -q --detach "$BASE"
run "$TOOL" --store "$WORK/store" replay "$WORK/ron"
printf 'ron a.txt: %s\n' "$(cat "$WORK/ron/a.txt" | tr '\n' '|')"
printf 'ron b.txt: %s\n' "$(cat "$WORK/ron/b.txt" | tr '\n' '|')"
printf 'ron c.txt present: %s\n' "$([ -f "$WORK/ron/c.txt" ] && echo yes || echo no)"
printf 'ron HEAD detached: %s\n' "$(git -C "$WORK/ron" symbolic-ref -q HEAD || echo detached)"

echo; echo "=== SCENARIO 3: Ron default branch stays ancestor of origin (fast-forwardable) ==="
run git -C "$WORK/ron" merge-base --is-ancestor main origin/main
printf 'is-ancestor main origin/main exit above (0 = still fast-forwardable)\n'

echo; echo "=== SCENARIO 4: check proves identical content vs unpatched host ==="
run "$TOOL" --store "$WORK/store" check "$WORK/ron"
run "$TOOL" --store "$WORK/store" check "$WORK/mate"

echo; echo "=== SCENARIO 5: mate replays the same store -> same set identity ==="
run git -C "$WORK/mate" checkout -q --detach "$BASE"
run "$TOOL" --store "$WORK/store" replay "$WORK/mate"
RON_SET=$("$TOOL" --store "$WORK/store" check "$WORK/ron" | sed -n 's/^set\t//p')
MATE_SET=$("$TOOL" --store "$WORK/store" check "$WORK/mate" | sed -n 's/^set\t//p')
printf 'ron  set identity: %s\nmate set identity: %s\nidentical: %s\n' "$RON_SET" "$MATE_SET" "$([ "$RON_SET" = "$MATE_SET" ] && echo yes || echo no)"

echo; echo "=== SCENARIO 6: upstream advances; unpatched machine fast-forwards unchanged ==="
BEFORE=$(git -C "$WORK/fresh" rev-parse main)
printf 'upstream\n' > "$WORK/seed/w.txt"; git -C "$WORK/seed" add -A
git -C "$WORK/seed" commit -qm 'upstream: w'; git -C "$WORK/seed" push -q origin main
run git -C "$WORK/fresh" fetch -q origin
run git -C "$WORK/fresh" merge -q --ff-only origin/main
AFTER=$(git -C "$WORK/fresh" rev-parse main)
printf 'fresh main before=%s after=%s advanced=%s\n' "$BEFORE" "$AFTER" "$([ "$BEFORE" != "$AFTER" ] && echo yes || echo no)"

echo; echo "=== SCENARIO 6b: Ron's default branch also still fast-forwards ==="
run git -C "$WORK/ron" fetch -q origin
run git -C "$WORK/ron" checkout -q main
run git -C "$WORK/ron" merge -q --ff-only origin/main
printf 'ron main now: %s (upstream: %s)\n' "$(git -C "$WORK/ron" rev-parse --short main)" "$(git -C "$WORK/ron" rev-parse --short origin/main)"

echo; echo "=== SCENARIO 7: replay onto newer upstream tip (--base origin/main) ==="
git -C "$WORK/ron" worktree add -q --detach "$WORK/advance" "$BASE"
run "$TOOL" --store "$WORK/store" --base origin/main replay "$WORK/advance"
printf 'advance w.txt present: %s\n' "$([ -f "$WORK/advance/w.txt" ] && echo yes || echo no)"
printf 'advance on upstream tip + patches: %s\n' "$(git -C "$WORK/advance" rev-parse --short HEAD~2 2>/dev/null)"
printf 'advance content a.txt: %s\n' "$(cat "$WORK/advance/a.txt" | tr '\n' '|')"

echo; echo "=== SCENARIO 8: adversarial - conflict stops, reports, target untouched ==="
mkdir -p "$WORK/badstore"
cat > "$WORK/badstore/0001-never.patch" <<'PATCH'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-# something this base never held
+# patched
PATCH
{
  printf 'series\t-\t2026-09-14\tnever applies\n'
  printf 'patch\t0001\tnever\t0001-never.patch\tfixture\tnever applies\tfix: never\n'
} > "$WORK/badstore/manifest"
git -C "$WORK/ron" worktree add -q --detach "$WORK/badtarget" "$BASE"
BEFORE=$(git -C "$WORK/badtarget" rev-parse HEAD)
run "$TOOL" --store "$WORK/badstore" --base origin/main replay "$WORK/badtarget"
AFTER=$(git -C "$WORK/badtarget" rev-parse HEAD)
printf 'bad target moved: %s (before=%s after=%s)\n' "$([ "$BEFORE" = "$AFTER" ] && echo no || echo YES-BAD)" "$BEFORE" "$AFTER"
printf 'bad target porcelain: [%s]\n' "$(git -C "$WORK/badtarget" status --porcelain)"
printf 'scratch left for inspection: %s\n' "$([ -e "$WORK/badtarget.fm-patch-scratch" ] && echo yes || echo no)"

echo; echo "=== SCENARIO 9: adversarial - dirty target refused ==="
git -C "$WORK/ron" worktree add -q --detach "$WORK/dirtytarget" "$BASE"
printf 'unlanded\n' > "$WORK/dirtytarget/UNLANDED.txt"
run "$TOOL" --store "$WORK/store" replay "$WORK/dirtytarget"
printf 'unlanded file still present: %s\n' "$([ -f "$WORK/dirtytarget/UNLANDED.txt" ] && echo yes || echo no)"

echo; echo "=== SCENARIO 10: adversarial - checkout on default branch refused ==="
git clone -q "$WORK/origin.git" "$WORK/ondefault"
run "$TOOL" --store "$WORK/store" replay "$WORK/ondefault"
printf 'ondefault still on: %s\n' "$(git -C "$WORK/ondefault" symbolic-ref --short HEAD)"

echo; echo "=== SCENARIO 11: adversarial - relative target lands scratch beside itself, not inside ==="
git -C "$WORK/ron" worktree add -q --detach "$WORK/reltarget" "$BASE"
( cd "$WORK" && run "$TOOL" --store store replay reltarget )
printf 'scratch inside target (BAD if present): %s\n' "$([ -e "$WORK/reltarget/reltarget.fm-patch-scratch" ] && echo YES-BAD || echo no)"
printf 'scratch beside target (clean on success): %s\n' "$([ -e "$WORK/reltarget.fm-patch-scratch" ] && echo present || echo clean)"
printf 'reltarget content a.txt: %s\n' "$(cat "$WORK/reltarget/a.txt" | tr '\n' '|')"

echo; echo "=== SCENARIO 12: adversarial - unresolvable recorded base refused ==="
git clone -q --depth 1 "file://$WORK/origin.git" "$WORK/shallow"
git -C "$WORK/shallow" checkout -q --detach HEAD
SB=$(git -C "$WORK/shallow" rev-parse HEAD)
run "$TOOL" --store "$WORK/store" replay "$WORK/shallow"
SA=$(git -C "$WORK/shallow" rev-parse HEAD)
printf 'shallow moved: %s\n' "$([ "$SB" = "$SA" ] && echo no || echo YES-BAD)"

echo; echo "=== SCENARIO 13: back-to-back replays keep each prior tip reachable ==="
run "$TOOL" --store "$WORK/store" replay "$WORK/reltarget"
run "$TOOL" --store "$WORK/store" replay "$WORK/reltarget"
printf 'history refs:\n'; git -C "$WORK/reltarget" for-each-ref --format='%(refname) %(objectname:short)' refs/farm-patches

echo; echo "=== SCENARIO 14: HEAD-relative --base is resolved once against the target ==="
mkdir -p "$WORK/hbseed" "$WORK/hbstore"
git -C "$WORK/hbseed" init -q -b main
printf 'base\n' > "$WORK/hbseed/base.txt"; git -C "$WORK/hbseed" add -A; git -C "$WORK/hbseed" commit -qm 'U1'
printf 'u2\n' > "$WORK/hbseed/u2.txt"; git -C "$WORK/hbseed" add -A; git -C "$WORK/hbseed" commit -qm 'U2'
printf 'u3\n' > "$WORK/hbseed/u3.txt"; git -C "$WORK/hbseed" add -A; git -C "$WORK/hbseed" commit -qm 'U3'
HB_BASE=$(git -C "$WORK/hbseed" rev-parse HEAD)
cat > "$WORK/hbstore/0001-p1.patch" <<'PATCH'
diff --git a/p1.txt b/p1.txt
new file mode 100644
--- /dev/null
+++ b/p1.txt
@@ -0,0 +1 @@
+p1
PATCH
cat > "$WORK/hbstore/0002-p2.patch" <<'PATCH'
diff --git a/p2.txt b/p2.txt
new file mode 100644
--- /dev/null
+++ b/p2.txt
@@ -0,0 +1 @@
+p2
PATCH
{
  printf 'series\t%s\t2026-09-14\thead-relative probe\n' "$HB_BASE"
  printf 'patch\t0001\tp1\t0001-p1.patch\tfixture\tp1\tfix: p1\n'
  printf 'patch\t0002\tp2\t0002-p2.patch\tfixture\tp2\tfix: p2\n'
} > "$WORK/hbstore/manifest"
printf 'u4\n' > "$WORK/hbseed/u4.txt"; git -C "$WORK/hbseed" add -A; git -C "$WORK/hbseed" commit -qm 'U4'
HB_TARGET=$(git -C "$WORK/hbseed" worktree add -q --detach "$WORK/hb-target" HEAD && printf '%s' "$WORK/hb-target")
run "$TOOL" --store "$WORK/hbstore" --base HEAD~1 replay "$WORK/hb-target"
out=$(run "$TOOL" --store "$WORK/hbstore" check "$WORK/hb-target")
printf 'HEAD-relative --base expected line: %s\n' "$(printf '%s\n' "$out" | grep '^summary')"
printf 'p1 landed: %s, p2 landed: %s (double-resolution would also record upstream u3.txt)\n' \
  "$([ -f "$WORK/hb-target/p1.txt" ] && echo yes || echo no)" "$([ -f "$WORK/hb-target/p2.txt" ] && echo yes || echo no)"
echo; echo "DONE WORK=$WORK"
