# Spawn-time submodule convergence: live evidence

Validated `d2378f0861869dc580b6398320063cc033ec42da` with the real `bin/fm-spawn.sh`, Git repositories and local file:// origins, Treehouse v2.3.0, tmux, and installed Codex 0.142.3. No fake terminal, allocator, Git, harness executable, or login was used in the live checks.

## Reproduce

From the gate worktree, run `bash live-spawn-driver.sh` using the attached driver. It creates a marked disposable home and fixture repositories inside `.test-tmp`, uses the supported `fm-lab-home.sh tmux-dir` helper for an ephemeral private socket, starts the actual Codex CLI in a `primary` session on `tmux -L fm-lab`, and drives each public spawn command through that socket. The ordinary absolute `<worktree>/l/tmux/tmux-501/fm-lab` socket exceeds macOS's Unix-socket path limit; the supported short-directory helper resolved that setup limitation without changing system configuration.

The stock Treehouse allocator skipped an already-dirty slot and allocated another one during initial setup. To actively exercise spawn's independent safety boundary, the final driver sets `diff.ignoreSubmodules=all` **only in the acquiring terminal's Git environment**. The supervisor's actual spawn command has no such override. The real allocator therefore hands it the intended drifted or unsafe slot, and spawn must independently converge or refuse. Every scenario verifies the returned task copy is the seeded slot, not another newly allocated copy. This is an explicit adversarial allocator configuration, not a stub.

The Codex worker terminals reached their genuine folder-trust dialogs. No trust-store consent was manufactured or persisted; no claim is made about a subsequent model turn. These checks cover the changed pre-launch product surface: fresh fetches, containment, pin checkout, clean Git state, launch publication or refusal. Folder-trust handling is not changed by this patch.

## Observable results

See the named sections in `extended-live-spawn.log` for full spawn output, before/after parent and child commit IDs, porcelain status, refreshed origin branches, persisted task metadata, and actual worker terminal captures.

| Section | User action and result |
| --- | --- |
| `reset-pin` | Spawn after main moves its child pin: parent reaches current main, child reaches the new recorded pin, clean status, task published. |
| `named-reset` | Spawn from a clean main slot targeting `release/pin`: spawn's own reset introduces drift, which converges to the release pin before task publication. |
| `drifted-pin` | Spawn an already-stranded slot: child moves to the recorded pin; clean status and task publication. |
| `stale-topic` | Narrow child origin's fetch refspec to main, delete topic upstream while retaining origin/topic locally, then spawn: stale topic is pruned, both original HEADs remain intact, no task published. |
| `stale-topic-reset` | Start clean with a topic gitlink, narrow fetch to main, delete topic upstream, then target a different base: post-reset containment refuses, the original topic child HEAD and its file survive, no task published. |
| `live-topic` | Narrow fetch to main but advance an extant topic upstream: spawn refreshes origin/topic to its new tip, proves the old child commit contained, and converges to the pin. |
| `unique-commit` | Spawn with an unpushed child commit: child and parent HEADs survive, launch refused, no task published. |
| `mirror-only` | Vouch for a unique child commit only through a non-origin remote ref: still refused; child and parent HEADs survive. |
| `dirty-child` | Leave an untracked child file beside gitlink drift: refusal preserves both HEADs and the file, no task published. |
| `failed-fetch` | Set child's origin to an unavailable repository: refusal preserves both HEADs, no task published. |
| `missing-pin` | Publish a parent gitlink whose child commit is unavailable upstream: pin checkout fails, original child HEAD survives, no task published. |
| `uninitialized` | Leave child uninitialized while moving its recorded pin: spawn succeeds cleanly and `ui/.git` remains absent. |

All final live scenarios passed. Initial allocator selection and socket-path problems were fixture/setup issues and were corrected before the final run. Lab teardown killed only its private tmux server and removed the disposable home and all fixture repositories in the same command turn.

## Targeted behavioral regressions

`TMPDIR="$PWD/.test-tmp" FM_TEST_EVIDENCE=1 bash tests/fm-spawn-pool-base-freshen.test.sh` passed. This test file uses a simulated terminal and real Git repositories; its results are not labelled live. Its broader related checks cover dirty superproject work, origin-less diagnostics, scout/direct-PR delivery paths, repeat refresh, default and named bases, isolation, and the new narrowed-refspec regression.

The same current test file was run against a disposable archive of the pre-review-fix commit `778d6fa` (`HEAD^`). It failed specifically with `spawn trusted a deleted topic outside the configured refspec (drifted)`. See `pre-fix-regression.log`. Thus the added behavioral regression reproduces the reported stale-ref failure before the fix, and the current source passes it.

No complete repository suite, linters, formatters, static analysis, other pipeline phases, host configuration edits, push, PR, or CI commands were run. This is a CLI/Git-state change, not a rendered UI change; screenshots were not needed. Attached transcripts and persisted Git/task-state observations are the product evidence.
