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
# backend endpoint, recorded PR) with the last line of its state/*.status;
# data/secondmates.md for each secondmate's host, scope, and projects (a remote
# secondmate's routed lines arrive in its local state/<mate>.status);
# bin/fm-tasks-axi.sh for backlog titles, captain-held rows (with the
# `Captain hold set:` stamp bin/fm-captain-hold.sh writes), and Done rows; the
# configured markdown done archive; the still-open decisions fold of
# bin/fm-classify-lib.sh; bin/fm-backend.sh's cheap endpoint-presence read for
# each local endpoint; and GitHub (gh) for PRs merged in the last 7 d across the
# GitHub repositories data/projects.md names, cached under state/.current-page
# for FM_CURRENT_PAGE_FORGE_TTL seconds (default 300) and skipped entirely with
# FM_CURRENT_PAGE_NO_FORGE=1. A failed GitHub read keeps the last good list and
# says so on the page.
#
# The open-decision fold runs over a private mirror (state/.current-page/fold,
# hard links to each status log plus its task kind), so its incremental cursors
# stay private: the wake drain's own cursors and presentation records are never
# read or written, and rendering never claims or acknowledges a wake.
#
# Page: one screen at 1440x900, four panes plus an inspector, driven from the
# keyboard (? lists the keys: j/k move, h/l or Tab change pane, 1-4 jump,
# Enter opens the selected item's link, y copies its command, / filters every
# pane, L opens the keeper log). It keeps to what Linear does not hold and
# links out for the rest through the curated `links`. Every item carries an
# age the page script keeps current, and the page re-fetches itself every 10 s
# and swaps its panes in place (no reload; the reader's pane, selection, and
# filter stay), so a need that disappears scores as a cleared call. The top bar
# reads STALE once the page has not re-rendered for 10 minutes. Above the panes,
# a Wins strip links the curated `wins` (work that demonstrably shipped); over
# it, and over Your answers, the mouse wheel scrolls the strip sideways, not the page.
# At 760 px wide or less (a phone) the panes stack, items open in place instead
# of in the inspector, Done today and Held calls start folded (tap a pane header),
# keyboard hints are hidden, and type and tap targets grow to phone size. The
# page writes manifest.json and its icons beside itself, so Add to Home Screen
# opens it as a standalone app.
# Task documents: every item tied to a task (a need's task and who, a held call,
# a worker, a Done record) lists that task's worker documents in its inspector.
# They are each data/<task>/*.md except brief.md and launch-brief.md, plus any
# .md under data/ that the task's status log names in a report=, plan= or
# review= key, rendered with bin/fm_md.py beside the page as <task>-<name>.html;
# the six most recently changed show, and a page is re-rendered only when its
# source is newer. A source that looks like it holds a credential is neither
# rendered nor linked, and its old page is removed.
# Answers: with answers_origin set (bin/fm-current-answers.sh's header), every
# captain call (Needs you and Held calls) carries its options as buttons - the
# curated "options", else lettered choices, yes/no, merge/close, or
# approve/reject named in its words - plus a one-line text box. A first tap arms
# an option and a second sends it. Its receipt is one line: a glyph (sending,
# in Main's inbox, read, replied), what you said, and Main's reply, which
# expands; the page reads /api/answers every 10 s. An answer whose call left the
# page sits in the one-row Your answers strip (newest first, with a count) while
# Main has not replied; a reply stays 24 h, or until it has been on screen for a
# minute. Each render publishes the
# answerable calls with their revisions to state/.current-page/decisions.json.
#   1 Needs you: curated needs re-checked within FM_CURRENT_PAGE_CONFIRM_HOURS
#     (default 2), plus captain calls Main held within that window that no need
#     covers yet. A need tied to a backlog row ("task") leaves the page the moment
#     that row stops being an open captain hold (answered, released, done, or
#     deferred). Raw status lines never reach this pane.
#   2 Running: workers whose recorded local endpoint is present now and whose last
#     status is not paused, done, or failed, each with its PR link and the
#     curated plain line (used only while re-checked within the window and newer
#     than the worker's last status) or else that status reduced to plain words;
#     then second mates by their routed status, then live but parked workers.
#   3 Done today: merged PRs by the fleet's GitHub identity and finished tasks from
#     the last 24 h, grouped by initiative. A Done record that links a merged PR
#     absorbs it, so one piece of work shows once. Older work and PRs merged by
#     others stay in Linear and GitHub.
#   4 Held calls: needs not re-checked within the window, older captain calls, and
#     calls deferred to a later date.
#
# Keeper contract: exactly one keeper (an Opus worker) edits only the curated file
# and the notes file, re-checking every need at least every FM_CURRENT_PAGE_CONFIRM_HOURS.
#
# Curated file (keeper-maintained JSON object):
#   checked "<ISO time>" or epoch               the keeper's last full re-check
#   needs  [{"t", "why", "task", "link", "link_label", "do", "message", "to",
#            "options", "rec", "asked", "checked", "who", "machine"}]
#          "t": one-line title; "why": one line on why it matters.
#          "task": the backlog id this need answers; omit only for asks that
#                have no backlog row.
#          "link": the direct URL to act on; "link_label" overrides its short
#                label. "do": optional exact action; wrap each command in single
#                backticks for monospace text and its Copy button.
#          "asked": when it was asked (default: the row's hold-set stamp).
#          "checked": this need's own re-check time (default: top-level checked).
#          "options", "rec": answer buttons (chips when answers are off), the recommended one marked.
#          "message", "to": recipient-ready text with a Copy message button that
#                copies the exact raw string, its text folded below.
#          "who", "machine": the worker or second mate it concerns and its host.
#   why    {"<task-id>": "<one-line title>"}    worker titles
#   plain  {"<task-id>": {"text", "at"}}        worker line and when it was written
#   hide   ["<task-id>", ...]                   workers left off the page
#   mates  {"<id>": {"machine", "scope"}}       secondmate host and scope
#   links  [{"label", "url"}]                   link-outs in the top bar (O opens the first)
#   wins   [{"t", "url", "why", "kind"}]        up to 10 Wins cards: title, the link that
#          shows the success, one line on why it matters, optional short link label
#   initiatives [{"id", "title", "match"}]
#          "match": {"project_tokens": [...], "linear_projects": [...],
#                    "title_keywords": [...]} uses OR within and across lists.
#          Literal, case-insensitive title keywords take priority (longest wins),
#          then Linear project id/name, then exact project token; ties use array
#          order. Give broad repositories narrow title keywords. Unmatched work
#          goes to Other.
#   completed [{"id", "title", "completed", "url", "project_token", "linear_project"}]
#          Optional Done tickets from Linear or another source, with an ISO date
#          or timestamp and an evidence URL. Only explicit completion records
#          count, never an In Review or cancelled item.
# A date-only completion counts as today on its own date. A missing or
# malformed file is named in a banner, and Needs you then shows only new calls.
# The notes format is owned by fm-current-page.py's header; bin/fm_md.py renders all Markdown.
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
