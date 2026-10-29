# Test-phase reproduction

Target: b6c3dad78168a54c9e6ef8f8a01ef8a92df6905d.

Live drivers are `live-guards-driver-r3.py` and `pi-live-driver-r3.py`.
Run from the target worktree after creating `.test-r3/tmp`. They create isolated lab homes; the Herdr driver uses the guarded lab helper and tears its named session down. Pi uses the installed SDK in RPC mode, with offline isolated state and no model prompts. The Pi proof covers session identity and presentation-record lifecycle, not successful model response delivery.

The submodule proof runs only `test_drifted_slot_converges_after_fresh_fetch` and `test_stale_backup_ref_does_not_prove_submodule_publication` from `tests/fm-spawn-pool-base-freshen.test.sh`, with added output of the real CLI result and Git HEAD values. Git and production spawn logic are real; allocator and terminal are test doubles, so these cases are not counted live.

The failing Pi regression runs only `test_away_record_parks_main_and_presents_after_archive` from `tests/fm-pi-branch-extension.test.sh`. Its SDK is a test double. The unchanged fixture omits --objective on its second enter call.

Initial baseline runs with TMPDIR inside the worktree triggered the existing prohibition against secondmate homes nested in the code root. An exact `git archive HEAD` copy inside `.test-r3/source` with sibling temporary fixtures passed the relevant control and OMP pin cases. Native remote restart still failed there; the same isolated case passed using the original source with the test toolchain's normal /tmp directory, as permitted for incidental test temporary files. Remote restart code-root/default/per-mate/legacy cases also passed using that layout. None of these transport-double tests are counted live.

Current-page screenshots show the actual generated product HTML, served locally, at 1440x900 and 390x844. Browser checks exercised filtering and expanding a mobile row. No answer was submitted. The curated decision is synthetic isolated test data.
