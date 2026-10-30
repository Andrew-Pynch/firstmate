# Supervisor command cheat sheet

The twelve commands Main runs most, one line each, from the code root with `FM_HOME` set to the home being supervised.
Each script's header and `--help` own its full flags and contract; read them before using a flag not shown here.

1. Answer a captain hold: `bin/fm-captain-hold.sh answer <task-id> --decision-file <path> [--release]` (the captain's exact words go in the file, there is no inline text flag; `--release` resumes a gated work item instead of closing it).
2. Hold a task for the captain: `bin/fm-captain-hold.sh hold <task-id> --reason <reason> [--title <title>] [--until YYYY-MM-DD]` (`--title` creates the task when none exists).
3. List held rows with hold fields: `bin/fm-tasks-axi.sh list --state held --fields hold_kind,hold_reason,hold_until` (`list` has no `--json`; `--fields` adds columns).
4. Steer a worker: `bin/fm-send.sh <task-id> [--resolve-key <key>]... <text...>` (`--resolve-key` closes the keyed decision or blocker this text answers).
5. Merge a task PR: `bin/fm-pr-merge.sh <task-id> <pr-url>` (approved local-only landing is `bin/fm-merge-local.sh <task-id>`).
6. Register a PR merge poll: `bin/fm-pr-check.sh <task-id> <pr-url>`.
7. Clean up a task: `bin/fm-teardown.sh <task-id>` (`--force` only when the captain explicitly said to discard the work).
8. Spawn a ship: `bin/fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--harness <name>] [--model <name>] [--effort <level>]` (after `bin/fm-brief.sh <task-id> <repo-name> --mode <mode>` wrote the brief).
9. Spawn a scout: `bin/fm-spawn.sh <task-id> <project-dir> --scout [--harness <name>] [--model <name>] [--effort <level>]`.
10. Relaunch a secondmate on another checkout: `bin/fm-control.sh <mate-id> relaunch --code-root <dir> [--note <text> | --note-file <path>]` (a ship or scout relaunch requires the note).
11. Acknowledge a drain: run `bin/fm-wake-drain.sh`, handle every wake, then run the exact `bin/fm-wake-drain.sh --ack-through <SEQUENCE> --recovery-generation <GENERATION>` line it printed as `WAKE_ACK_REQUIRED`.
12. Read a worker's current state: `bin/fm-crew-state.sh <task-id>` (a status line is a wake event; this is current truth).
