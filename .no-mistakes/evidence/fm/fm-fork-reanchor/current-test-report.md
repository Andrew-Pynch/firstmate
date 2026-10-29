# Current Test phase: three authorized local proofs

Target: 7407154933dfd4b6dd70fb909957439f4f295f60.

All three authorized proofs were executed again against the production CLI and passed within the requested isolated local boundary. No source or tracked test changes were made. The seven unchanged scenario results from test-phase-r5.md are retained as explicitly requested, without adding another proof requirement.

## Observed behavior

- Remote route and restart selection: production fm-on encoding, host route serialization, parent metadata update, durable send, correlated reply and restart selection executed against local fixture homes. The host-confirmed root differed from both the parent's previous root and the requested root. Parent metadata recorded the host-confirmed value; the next restart request selected that same value. The transport executed the actual host route serializer rather than echoing a constructed response. The restart request was deliberately refused after capture (expected exit 3, unknown outcome); no replacement is claimed. The host endpoint state was preseeded, and the local transport substituted route readback for the first relaunch. This proves the requested metadata/selection behavior, not an actual host move, remote SSH deployment, or Herdr lifecycle.
- Trace recovery: real fm-spawn launched a local executable worker through a private real tmux server. Two distinct process IDs received the same persisted W3C traceparent, equal to the task metadata carrier. Invalid --traceparent input was rejected before another worker or metadata change. The worker is a deterministic environment recorder, not the vendor Claude model runtime.
- External pause: real fm-watch, tmux inventory/capture and crew-state code observed an explicit pause. No stale wake appeared during the first five seconds despite a one-second wedge threshold. The real elapsed twelve-second configured cadence then emitted the external-wait recheck after 11.22 seconds of watcher runtime (the status was written shortly before watcher startup), without wedge escalation. No test clock or timestamp aging was used in this process proof.

## Commands executed

- python3 .test-current/remote-proof.py
- python3 .test-current/local-process-proofs.py
- TMPDIR="$PWD/.test-current/tmp" bash tests/fm-remote-secondmate-relaunch.test.sh
- TMPDIR="$PWD/.test-current/tmp" FM_TEST_ONLY=test_explicit_external_pause_uses_only_the_long_cadence bash tests/fm-watch-triage-pause.test.sh

Both focused supporting regression commands exited zero. The baseline scripts use boundary fixtures and are supporting regression evidence, not independent live proofs.

## Evidence

current-remote-proof.log and current-remote-requests.jsonl show route readback and the next restart request. current-remote-parent.meta and current-remote-host.meta preserve the resulting records. current-persisted-restart-request.txt is the actual durable request consumed and acknowledged by the fixture.
current-process-proof.log, current-worker-environments.jsonl and current-trace-task.meta show actual spawn output, received process environments and persisted carrier.
current-pause-output.txt and current-pause-wake-queue.txt show the actual external-wait recheck.
The current-*.py driver files reproduce these proofs from this worktree; create .test-current/tmp first.

The seven retained results remain documented in test-phase-r5.md and its linked logs. Existing desktop/mobile screenshots current-page-desktop-r5.png, current-page-mobile-r5.png and current-page-mobile-detail-r5.png retain visual evidence for the unchanged current-page scenario; no UI change or new browser proof was introduced in this phase.

## Boundaries and cleanup

Actual fork-only publication remains excluded from pre-publication Test requirements; native Push, PR and CI phases own publication and broad checks. No pipeline-control command, publication, linter, formatter, static analysis or full repository suite was run. No real fleet, real remote target, shared home, credential store or Herdr lifecycle was touched.
The process proof terminated its private tmux server and worker, and the watcher exited at the expected recheck. The local inbox consumer terminated. The temporary .test-current tree was removed after saving evidence; final git status was clean.
