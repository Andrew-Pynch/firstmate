#!/usr/bin/env bash
# fm-share.sh - explicit share links: give someone outside the captain's tailnet one
# artifact, and nothing else, behind an unguessable revocable link.
#
# Usage:
#   bin/fm-share.sh add <path> [--label <text>] [--json]   publish a copy, print its link
#   bin/fm-share.sh list [--json]                           every live share, newest first
#   bin/fm-share.sh revoke <token>                          take one share down at once
#   bin/fm-share.sh serve                                   run the share server (foreground)
#
# add copies <path> (a file, or a folder that has an index.html) into
# <share root>/<token>/<name>, where <token> is 24 random URL-safe characters
# (144 bits) and <name> is the basename reduced to [A-Za-z0-9._-]. The copy is a
# snapshot: later edits to the source do not reach the link; share again for a new
# one. A folder is copied without its symlinks or hidden entries, and its link
# opens <name>/index.html. It prints https://<share origin>/<token>/<name>. A
# record of the share (source, label, time) is written to the records folder,
# outside anything served. revoke renames the token folder away in one step, then
# deletes the copy and the record; the link answers 404 from then on. list also
# shows token folders made by hand (no record), with a link for each of their
# files, so they stay visible and revocable.
#
# Configuration (environment wins, then FM_HOME's config/current-page):
#   FM_SHARE_ORIGIN or share_origin=https://<host>:<port>   the origin links are
#       minted under (for big-ron, https://big-ron.tail3f4961.ts.net:8450). With it
#       set, and answers_origin set, the Deck shows its share controls.
#   FM_SHARE_LISTEN or share_listen=<host>:<port>   default 127.0.0.1:8450; only a
#       loopback or tailnet address is accepted (bin/fm-current-answers.sh's rule).
#   FM_SHARE_ROOT     the served folder, default ~/.local/share/fm-share
#   FM_SHARE_RECORDS  the records folder, default ${XDG_STATE_HOME:-~/.local/state}/fm-share
#
# Serving contract (serve): GET and HEAD only. "/" answers 200 with an empty page,
# never a listing. Only /<token>/<path to a file> answers with content, where the
# token names an existing token folder, every path part is non-empty and not
# hidden, the resolved file is a regular file inside that folder, and no part is a
# symlink. Every other request - a token folder itself, any folder, a hidden or
# staging entry, an unknown or revoked token, a traversal - answers 404 with the
# same empty page. Responses carry Cache-Control: no-store, nosniff,
# Referrer-Policy: no-referrer, and X-Robots-Tag: noindex. Nothing else on the
# machine is reachable through it.
#
# Running it on big-ron (the Deck stays on 8449, tailnet only; 8450 is the only
# port a shared-in user can reach):
#   systemd-run --user --unit=fm-share -p Restart=always -p Nice=10 \
#     -E FM_HOME=<home> <code root>/bin/fm-share.sh serve
#   tailscale serve --bg --https=8450 http://127.0.0.1:8450
# and in the tailnet policy file, one grant per invited user by account, never
# autogroup:shared (keep existing grants unchanged when cutting over):
#   {"src": ["<account>@github"], "dst": ["big-ron"], "ip": ["tcp:8450"]}
# with policy tests denying that account big-ron:22, :443, and :8449. No SSH
# rule (tailnet policy "ssh" section) may name a shared user, so a shared-in
# user reaches this server and nothing else.
#
# The Deck (bin/fm-current-page.sh) offers a share button on each artifact it links
# and lists live shares with a revoke button; its endpoint
# (bin/fm-current-answers.sh, POST /share and /share/revoke) calls this module.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_share.py" "$@"
