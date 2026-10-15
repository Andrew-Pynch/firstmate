# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash
Ship branch: fm/validation
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task, and skip nothing else: `review`, `test`, `document`, and `lint` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.
That first `done:` is the handoff that starts the pipeline; it is not a request to publish.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

Because `push` is skipped, the pipeline's fixes DO NOT arrive in your checkout: each fix round commits onto a branch inside no-mistakes' own local gate repository, and with no push nothing carries those commits back to you.
Your tree never goes dirty and nothing interrupts you, so a passed run whose fixes are still in the gate looks exactly like a passed run whose fixes you already have.
You may not publish until you have closed that gap:
1. After the run reaches its outcome, read `branch_sync.next_action` from `no-mistakes axi status`.
2. When its code is `recover_custody`, run the exact command that status prints - `no-mistakes axi sync --recover` - and confirm `branch_sync.state` comes back `custody_returned` on a clean tree. The printed command is authoritative if it differs. The `run_pipeline` next action status reports after recovery is not an instruction to run again: the recovered head is the one the passed run validated, so publish it.
3. Confirm with `git log` that `fm/validation` now carries every fix commit the run made, whether or not step 2 was needed.
An unrecovered fix round is an unfinished task, never housekeeping: publishing without it is how the UNFIXED code reaches review.
Your ready report is refused while the run still holds your branch, while its outcome is missing or not passing, or while your HEAD's tree differs from the run's result.

When the run's outcome is passed, passed-with-skips, or passed-with-override and step 3 holds, publish.
The squashed change carries only the oldest commit's message, so the pipeline's own fix commits never reach the reviewer's description; your report is how they reach the captain.
After publishing and immediately before your ready report, append one line `note [at=<epoch>]: pipeline changes: {finding} - {fix it made}; {finding} - {fix it made}` to the status file, one short clause per finding the run fixed, taken from the run's `fixes` table and the gate findings its drive calls returned (`no-mistakes axi logs --step <step> --full` has the detail); write `note [at=<epoch>]: pipeline changes: none` when it fixed nothing.
Publish from this copy with `gerrit-axi`, never with `git push`:
1. Run `git fetch origin` so the server's branch tip is in this repository; `gerrit-axi` reads its base off the server and refuses when that tip is not here.
2. Run `gerrit-axi publish --squash --json`, adding `--branch <b>` only when the task names a target branch other than the server's default.
   It is one push to `refs/for/<branch>` that turns every commit since your branch left the server's branch into ONE change carrying the oldest commit's message, so that message is the review description: make it the one you want reviewed.
   It keeps any `Change-Id` a commit already carries and stamps one into the oldest commit when it has none, rewriting your local branch's messages only.
   Never edit, remove, or regenerate a `Change-Id`: a different one creates a different change and orphans the first one's review, while the same one adds a patch set to it.
   Never pass `--stack`: a stack of changes is not published from this fleet until it can be watched by its membership pinned when its watch is armed, and the watch follows exactly one change.
3. Read the record it prints: `ok` must be `true`, and the one row of its `changes` table is your change. Its `url` is the change URL; when `url` is null, write `https://<host>/c/<project>/+/<change>` from your `origin` remote's host and that row's `project` and `change`.
   A failure prints a typed error record instead; fix what it names and publish again, which updates the same change rather than creating another.
Then append `done [at=<epoch>]: PR {change url} published for review` to the status file and stop. You are finished.
That `done:` is accepted only when the change's current patch set on the server carries this copy's HEAD tree, so commit nothing after publishing; if you must change the work, commit it and publish again before reporting done.
A `done:` whose URL is not the canonical `https://<host>/c/<project>/+/<number>` change URL is refused.
There is no pull request, no `gh-axi` call, and no forge CI result to report: a human reviewer approves and submits the change on the server, and firstmate relays that outcome.
