# Test phase round 6: three authorized isolated local proofs

Target: 7407154933dfd4b6dd70fb909957439f4f295f60.
No source or permanent test changes were needed. No fourth proof was added.
The seven previously passed scenario results are retained unchanged, by reference to test-phase-r5.md; they were not regenerated or newly claimed as executed in this round.

## Results

1. **Host-confirmed code root: PASS within the authorized local boundary.**
   `python3 .test-r6/remote-proof.py` exercised production fm-remote-secondmate-relaunch.sh, fm-on.sh, fm-remote-secondmate-control.sh route/send, fm-send.sh, fm-secondmate-report.sh, and fm-secondmate-restart.sh.
   The isolated host endpoint was seeded with a confirmed root distinct from both the parent's old root and the requested root. The local transport ran the real host route serializer, and the parent recorded the host-confirmed value. A running local fixture consumer read the real durable inbox, persisted the request, and replied with its correlation token through the production report helper. The subsequent real restart request carried the confirmed root.
   The transport deliberately refused that final restart after capturing it. The product correctly reported an unknown restart outcome and exited 3. This intentional refusal is not a product failure or a completed replacement claim.
   Scope limitation: this proves route serialization, parent metadata publication, correlated acknowledgement, and next-request selection. Host confirmation was preseeded; no actual host move, remote SSH server, agent replacement, or Herdr lifecycle was performed. The transport is local, not evidence of a live remote deployment.

2. **Persisted trace and malformed carrier: PASS.**
   `python3 .test-r6/local-process-proofs.py` ran the production spawn CLI through an isolated real tmux server to a local executable worker that records its actual process environment. The first process received exactly the metadata carrier. After its window was removed, recovery spawned a different PID with the identical persisted carrier. The malformed `--traceparent` input was refused by the real CLI before any extra worker appeared or existing metadata changed.
   This is actual process/terminal delivery evidence, with a deterministic local worker; it does not claim a vendor-model response or a real external worker service.

3. **Explicit external pause: PASS.**
   The same process fixture ran the real watcher, real tmux inventory and capture, and real crew-state command. With an explicit external-pause status and a one-second wedge threshold, there was no stale wake after five seconds. Without aging files or mocking the clock, the configured twelve-second long cadence produced its external-wait recheck after 11.22 seconds of watcher runtime (the status was written shortly before startup). No wedge escalation appeared.
   The production twelve-second setting is the test's accelerated cadence, not a claim that the default long interval was observed in wall-clock time.

## Focused baselines

- `TMPDIR="$PWD/.test-r6/tmp" bash tests/fm-remote-secondmate-relaunch.test.sh`: PASS, seven behavioral checks.
- `TMPDIR="$PWD/.test-r6/tmp" FM_TEST_ONLY=test_explicit_external_pause_uses_only_the_long_cadence bash tests/fm-watch-triage-pause.test.sh`: PASS.
- `TMPDIR="$PWD/.test-r6/tmp" bash tests/fm-trace-context-spawn.test.sh`: first five cases PASS, then setup refusal: the duplicate-secondmate fixture places its home inside the repository because TMPDIR must remain in this worktree. Product reports `secondmate home cannot be inside the firstmate repo`. This is a workspace-boundary fixture incompatibility, not evidence of a trace failure. No code or test correction was made. The focused actual-process proof above establishes the authorized trace behavior without that nested secondmate setup.

## Phase boundary and cleanup

Actual fork-only publication is excluded from pre-publication behavioral requirements. Native Push, PR, and CI phases alone own publication and broad checks. No publication, pipeline control, lint, formatter, static analysis, or whole-repository test suite was run here. No real fleet or remote target was used. No real Herdr command or lifecycle was run; the remote fixture's disconnected terminal edge is an executable that refuses every command.

The temporary tmux server was killed by the driver, the watcher exited after its recheck, the local inbox consumer stopped, and temporary fixture files were removed from the worktree. Scripts and observed outputs are retained beside this report. The final worktree status was verified clean after cleanup.
