# Test phase: 7407154933dfd4b6dd70fb909957439f4f295f60

The approved missing-objective fixture correction was already committed at HEAD. No source or test changes were required in this phase.

## Scope and outcomes

- Full targeted Pi branch extension regression passed, including away entry, parking primary processing, and presenting pending outcomes after archive.
- Installed Pi 1.4.0 was also driven in RPC mode with the actual branch extension. An isolated home stored a captain outcome while away: no processing turn opened. After archive and a new session, the real runtime emitted the processing message containing that outcome. There was intentionally no provider configured and no successful model completion is claimed. The initial probe used get_messages for a custom visible entry; correcting the observer to read actual session entries resolved that setup mismatch.
- Installed Pi context lifecycle retained the branch presentation record on same-conversation reopen and removed it after new_session; native reload/resume hooks preserved/cleared the main record respectively. Branch model work was not required; no successful branch model response is claimed.
- Real fm-spawn/Git preflight in isolated repositories converged freshly published submodule pins and refused both pruned-origin and stale-backup-only commits, preserving parent/submodule heads. The terminal allocator was simulated; this proves checkout/preflight behavior, not a worker model run.
- Real fm-on encoding, host route/send output, parent metadata update, correlated reply, and restart selector carried the host-confirmed code root, including spaces, through restart. The local loopback transport simulated only agent lifecycle and its acknowledgement. This is a local transport integration proof, not a live remote-host or Herdr relaunch proof.
- A real OMP 18.11.0 process in a private tmux server survived missing-code-root and incompatible-Claude relaunch refusals with byte-identical metadata. Private server was torn down. Long absolute socket path and endpoint naming setup errors were corrected before the successful run.
- Real wake-drain CLI presented decisions once, re-presented a long-tail change, honored explicit reveal, and removed resolved decisions. Real spawn CLI refused conflicting OMP profile/account pins before launch.
- Installed Claude, Pi, and OMP account checks passed using synthetic local credential roots; OMP profile flag and environment precedence were exercised without submitting model prompts. pi-signed was not installed; no pi-signed proof is claimed. The ordinary pi wrapper was bypassed with its already-installed package entrypoint to avoid downloads or tool upgrades.
- Native trace helper API exercised off/on, a persisted carrier across recovery, and malformed-carrier replacement. This is API validation, not a live worker transport.
- Real generated current-page HTML was served locally and driven in Chromium at 1440x900 and 390x844. Filtering produced zero results, clearing restored the row, and tapping the mobile row opened inline detail with no horizontal overflow. Desktop, mobile, and expanded mobile screenshots are retained. No answer or decision was submitted.

## Supporting targeted regressions

Passed: fm-wake-drain-open-decisions, fm-sessionstart-nudge, fm-remote-secondmate-relaunch, fm-trace-context-lib, fm-self-repo-role, the two selected OMP profile/conflict cases, and the full fm-pi-branch-extension script. OMP selected fixtures used a copied sibling runtime inside this worktree so their isolated homes did not violate the production home-inside-code-root guard.

The external-pause case passed when selected with FM_TEST_ONLY. An earlier argv-based attempt started the script's default test list; it was stopped after its first case and superseded by the correctly selected invocation. No complete repository suite, linter, formatter, static-analysis command, or other gate phase was run.

## Delivery boundary

Fork-only publication is explicitly excluded from this Test scenario requirement by the current decision. Native Push, PR, and CI phases own actual publication and remote checks. This phase performed no publication, no pipeline control, no real fleet mutation, no remote-host lifecycle, and no Herdr lifecycle operation. Fixtures and copies were confined to the worktree; evidence is in the dedicated evidence directory.

## Reproduction

Create .test-r5/tmp under the worktree before running the saved drivers. Each driver owns isolated local fixture directories; run from this worktree. The selected OMP profile script additionally needs .test-r5/runtime copied from this worktree's bin, .omp, .pi, .agents, and AGENTS.md. Use the installed Pi package entrypoint recorded in the logs, not a package-manager launcher.

Cleanup: private Pi/OMP processes, tmux server, Chromium, browser bridge sessions, and HTTP server were stopped; .test-r5 and all generated runtime copies/caches were removed. No source or test edits remain.
