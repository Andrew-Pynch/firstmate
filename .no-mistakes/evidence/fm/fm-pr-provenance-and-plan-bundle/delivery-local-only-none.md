# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/validation
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/validation`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/validation` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
