# Definition of done
Delivery contract: mode=direct-PR forge=forgejo
Ship branch: fm/validation
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `tea` that is ready for review, not a draft.
If this repo has `.claude/skills/starcube-pr/SKILL.md`, end the PR body with a `## Provenance` section of four bullets: `**Skills:**` names of skills whose body you loaded this run (`none recorded` if your transcript shows none), `**Worker:**` harness and model plus `Sol: reviewed` or `Sol: not run`, `**Plan:**` and `**Report:**` paths or `none`. It is informational, never a readiness gate; invent nothing and omit home paths, hosts, and secrets.
Before you report done, read the PR back from the forge and confirm it is not a draft (`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<number>` must show `draft` as false, where <owner>/<repo> and <number> come from your PR URL); Forgejo marks a draft by a work-in-progress title prefix such as `WIP:`, so if it is a draft, remove that prefix with `tea pulls edit <number> --repo <owner>/<repo> --title '<title without the prefix>'`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url}` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
