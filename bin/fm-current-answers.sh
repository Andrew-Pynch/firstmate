#!/usr/bin/env bash
# fm-current-answers.sh - the current page's answer endpoint: the captain taps an
# option on a Needs-you item (phone or desktop) and the answer reaches Main as one
# durable inbox note, with a receipt the page shows until Main's reply lands.
#
# Usage:
#   FM_HOME=<home> bin/fm-current-answers.sh
#
# Configuration, in the home's gitignored config/current-page (the same file
# bin/fm-current-page.sh reads):
#   answers_origin=https://<host>[:port]   the exact origin the page is served from.
#                                          Required; with it set the page renders
#                                          answer buttons, without it the endpoint
#                                          refuses to start and the page has none.
#   answers_listen=<host>:<port>           default 127.0.0.1:8451. Only a loopback or
#                                          tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48)
#                                          address is accepted; front it with the
#                                          tailnet-only `tailscale serve` path that
#                                          already serves the page, for example
#                                          `tailscale serve --bg --https=8449 --set-path /api http://127.0.0.1:8451`.
# FM_CURRENT_ANSWERS_ORIGIN and FM_CURRENT_ANSWERS_LISTEN override the two lines.
#
# Routes (an `/api` prefix is accepted and stripped, so it works whether or not
# the proxy strips its mount path):
#   POST /answer    {"key", "rev", "rid", "option" | "text"} -> 200 {"state":"received","note":<id>,...}
#   GET  /answers   the last 48 h of answers, newest per decision, each with
#                   state received (in Main's inbox), seen (Main acknowledged the
#                   note), or answered (Main published a reply), and the reply text.
#   GET  /health
#
# Security contract for POST /answer, each check refusing before anything is queued:
#   - same origin: Origin must equal answers_origin (Referer under it when no Origin
#     is sent), and Sec-Fetch-Site, when sent, must be same-origin -> else 403;
#   - Content-Type application/json only -> else 415, so a plain HTML form cannot post;
#   - X-FM-Answer-Token must be a token bin/fm-current-page.py minted at render
#     (HMAC over the render time with the 0600 key in state/.current-page/answer-secret,
#     valid 24 h) -> else 403; the custom header also forces a CORS preflight that
#     this server never approves;
#   - key and rev must match a decision in the renderer's latest
#     state/.current-page/decisions.json -> else 409 (gone or stale), so a phone tab
#     left open cannot answer a decision that was replaced; the page refreshes on 409;
#   - an option must be one the decision offers; free text is one line, at most 500 chars.
# An accepted answer is `bin/fm-inbox.sh note --request-id current-page-<rid>` (a
# retried tap replays the same note instead of waking Main twice) whose first line
# is `current-page-answer row=<backlog id> key=<key> rev=<rev>`, and one ledger line
# in state/.current-page/answers.jsonl. It never closes a hold or changes a
# backlog row itself: Main acts on the note and publishes `bin/fm-inbox.sh reply`.
#
# Run it under a user service manager, for example:
#   systemd-run --user --unit=fm-current-answers -p Restart=always -p Nice=10 \
#     -E FM_HOME=<home> <code root>/bin/fm-current-answers.sh
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_current_answers.py" "$@"
