# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/validation
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi` that is ready for review, not a draft.
If this repo has `.claude/skills/starcube-pr/SKILL.md`, end the PR body with a `## Provenance` section of four bullets: `**Skills:**` names of skills whose body you loaded this run (`none recorded` if your transcript shows none), `**Worker:**` harness and model plus `Sol: reviewed` or `Sol: not run`, `**Plan:**` and `**Report:**` paths or `none`. It is informational, never a readiness gate; invent nothing and omit home paths, hosts, and secrets.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url}` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
