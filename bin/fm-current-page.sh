#!/usr/bin/env bash
# fm-current-page.sh - render one live "current" HTML page for the captain from
# this home's durable records, and keep it fresh as those records change.
#
# Usage:
#   FM_HOME=<home> bin/fm-current-page.sh [render] [--out <page.html>] [--notes <notes.md>] [--curated <curated.json>]
#   FM_HOME=<home> bin/fm-current-page.sh watch  [--out <page.html>] [--notes <notes.md>] [--curated <curated.json>]
#
# Paths. Flags win; otherwise the home's gitignored config/current-page is read:
# its first plain non-comment line names the page, and optional `notes=<path>`
# and `curated=<path>` lines name the two human inputs (relative paths resolve
# against the home). With no page path it renders nothing and exits 2. Notes
# default to current-notes.md and the curated file to current-curated.json, both
# beside the page. Every write is atomic (temp file plus rename), so a server
# reading the page never sees a partial file.
#
# Sources, read only: every state/*.meta (task, kind, project and token, host,
# model, worktree, recorded PR) with the last line of its state/*.status;
# data/secondmates.md for each secondmate's host, scope, and projects (a remote
# secondmate's routed lines arrive in its local state/<mate>.status);
# bin/fm-tasks-axi.sh for backlog titles and held rows; the still-open
# decisions fold of bin/fm-classify-lib.sh; and GitHub (gh) for PRs merged in
# the last 24 h across the GitHub repositories data/projects.md names, cached
# under state/.current-page for FM_CURRENT_PAGE_FORGE_TTL seconds (default 300)
# and skipped entirely with FM_CURRENT_PAGE_NO_FORGE=1. A failed GitHub read
# keeps the last good list and says so on the page.
#
# The open-decision fold runs over a private mirror (state/.current-page/fold,
# hard links to each status log plus its task kind), so its incremental cursors
# stay private: the wake drain's own cursors and presentation records are never
# read or written, and rendering never claims or acknowledges a wake.
#
# Page sections: NEXT for Andrew and Needs you, both taken only from the curated
# file and never from raw status lines; free notes; Live workstreams, each card
# showing the curated plain line or else its last status line reduced to plain
# words (home data/ paths, links, and [name=value] tags removed) plus a count of
# its still-open decisions (a blocked or needs-decision key drops out once a
# resolved line with that key lands), with rows paused, finished, or quiet for
# FM_CURRENT_PAGE_QUIET_HOURS (default 48) folded below unless a decision is
# open on them; Landed today (fleet PRs first, others folded); and Held. Filter
# chips select by machine, by mate (Main or a secondmate id), and by project;
# the selection lives in the URL fragment and survives the page's one-minute
# reload.
#
# Curated file (keeper-maintained JSON object):
#   next   {"do", "why", "unblocks"}            the NEXT box
#   needs  [{"t", "why", "who", "machine"}]     Needs you cards; "who" is a task
#                                               or secondmate id and sets filters
#   why    {"<task-id>": "<one-line title>"}    card titles
#   plain  {"<task-id>": "<plain status>"}      card text instead of the status line
#   hide   ["<task-id>", ...]                   rows left off the page
#   mates  {"<id>": {"machine", "scope"}}       secondmate host and scope
# A missing or malformed file shows an empty NEXT with the problem named.
# The notes file is free Markdown rendered above the filters.
#
# Trigger. `watch` stays in the foreground and renders on every change to a
# state/*.status or state/*.meta file, data/backlog.md, the notes file, or the
# curated file, with
# at most one render per FM_CURRENT_PAGE_DEBOUNCE_SECS (default 10; a quiet
# change renders at once, a burst coalesces), plus an idle refresh every
# FM_CURRENT_PAGE_IDLE_SECS (default 300). It uses inotifywait when installed
# and otherwise polls every FM_CURRENT_PAGE_POLL_SECS (default 2);
# FM_CURRENT_PAGE_POLL=1 forces polling. It is a separate process that only
# reads firstmate records, so it never blocks or delays supervision; run it
# under a user service manager, for example:
#   systemd-run --user --unit=fm-current-page -p Restart=always -p Nice=10 \
#     -E FM_HOME=<home> <code root>/bin/fm-current-page.sh watch
# Renders are serialized by a lock under state/.current-page, so a manual
# render beside a running watcher is safe.
#
# FM_CURRENT_PAGE_HOST overrides the local machine name (default: short
# hostname). FM_CURRENT_PAGE_REASON labels a manual render on the page.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-current-page.py" "$@"
