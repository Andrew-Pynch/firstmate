# T3 Code placement scorer pin

This directory is an unmodified copy of the T3 Code host selector and its resource sampler, pinned to one stable upstream release.
Firstmate never executes these files at placement time.
`bin/fm-placement-scorer-lib.sh` owns the Firstmate adapter that ports the selector, and `bin/fm-host-probe-lib.sh` owns the probe that ports the sampler's CPU and memory facts.
`tests/fm-place.test.sh` runs the vendored selector under Bun against the same vectors as the adapter, so the port cannot drift from this copy unnoticed.

## Pin

- Repository: <https://github.com/pingdotgg/t3code> (MIT, copyright 2026 T3 Tools Inc.).
- Release: tag `v0.1.7`, commit `322f6544dfad0a3c8a0c8cbecf2c7f7874b14268`.
- Selector origin: commit `420fd76f60433fe05b8d2c76f4fbde430dc49968`, pull request 9895 by `maria-rcks`; the selector is unchanged from that commit through the tag.

| File here | Upstream path at the pinned commit | Git blob | SHA-256 |
|---|---|---|---|
| `load-balancing.ts` | `packages/client-runtime/src/load-balancing.ts` | `0b938c6c090e458c0544d9421d1b9a459c0f0b8a` | `de5f8fe45b5d20c752f578e17cc2c85a299561f1921f3adebe3272ebf42f52d1` |
| `HostResources.ts` | `apps/server/src/resourceTelemetry/HostResources.ts` | `4788689046af396c9216455e6f51d9e4095a2ed1` | `bf3914795597138620ef253af61d85817ed7b8a5072d4088e70c17a5d23a806a` |
| `resourceTelemetry.ts.lines-9-16` | lines 9-16 of `packages/contracts/src/resourceTelemetry.ts` (the `HostResourcesSnapshot` contract) | `5e7045515f1f4639667ab619d554da9709852191` (whole file) | `07515932a6b9352e14eaa8759a2518e32776773d909766b44c8d0a6a529c38de` (excerpt) |
| `LICENSE` | `LICENSE` | `55ee675bb1de9e580b69f3dd68684df2a4dffba7` | `935d8f2af0c703f9c39517ee57cc4930b19d02d533be930b63f0e82f93614b43` |

Check the copy with `git hash-object` and `sha256sum` on the files above; both must print the values in the table.

## What Firstmate takes from it

- The selector's rejection rules and score, `weight * cpuCount * (1 - cpuUtilization) * (availableMemoryBytes / totalMemoryBytes)`, with its strict `>` comparison, so the first of equal scores in candidate order wins.
- The sampler's CPU utilization: two per-CPU counter reads 200 ms apart, `1 - idle delta / (user + nice + sys + idle + irq) delta`, unobserved when the CPU count changed or no time passed.
- The sampler's available memory: `MemAvailable` on Linux, and free plus inactive plus speculative pages on macOS.

Firstmate does not take the sampler's 5-second cache, the client's polling hook, or the settings UI.
Every Firstmate admission gate still runs first, and the selector only ranks the candidates that passed them.

## Updating the pin

A Firstmate maintainer updates the pin by hand, and only to a named stable T3 Code tag, never to `main` or a nightly.
Copy the new upstream files over these, diff them against this copy, port any change into the adapter or the probe, refresh every row of the table, and run `tests/fm-place.test.sh` and `tests/fm-fleet-resources.test.sh` with Bun installed so the shared vectors compare the new selector with the adapter.
