# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when their work merged, and when they were cleaned up.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the four event names below                         |
| `task`  | The firstmate task id the record is about                 |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

Example:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
```

## Limits

- Status records normally come from the supervision monitor's regular poll, so they may trail the status line by one poll interval.
  Lines written while no monitor runs are picked up on its next run.
  Recording `task.merged` or `task.cleaned_up` first records that task's pending status lines.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in its live tasks' logs are recorded on the first poll, while tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events and a separate record when a PR is first recorded;
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.

## Status page

`bin/fm-status-page.sh` uses `fm-bearings-snapshot.sh --json --fields page` without GitHub polling and this ledger to publish `state/status-page-public/index.html`.
Its cursor and decision receipts stay in `state/.status-page`, outside the served document root.
When `config/fleet-ledger` exists, the existing detached home-summary publisher refreshes the page after successful summary publication; there is no second timer.
Run `FM_HOME=<home> bin/fm-status-page.sh` once for the initial page, then `FM_HOME=<home> bin/fm-status-serve.sh` as a persistent local service.
The server listens only on `127.0.0.1`, using `config/status-page-port` or port `8795` when absent.
Mount it on the tailnet with `tailscale serve --bg --set-path=/fm-status 8795`; use the configured port instead of `8795` when overridden.
Only the HTML and its decision endpoint are reachable through that mount, not the operational home's raw records.
Read access is tailnet-only; writing an answer also requires the exact Tailscale Serve login in local `config/status-page-owner`, one of the last 20 render tokens not yet used, and a same-origin browser POST from the served `.ts.net` host.
Serve strips caller-supplied identity headers before it adds its own; direct loopback requests without an identity header are rejected (local processes remain in the host trust boundary).
Submitting an accepted card calls `fm-inbox.sh note --request-id`, consumes that form token, and refreshes the page with the recorded option and UTC time on the card; Main handles the resulting inbox check.
Rejected decision forms redirect to the current page with an alert instead of leaving the browser on an error response.
Do not enable Funnel or publish this route to the public internet.
