#!/usr/bin/env bash
# fm-md-page.sh - render a Markdown report as one keyboard-driven HTML page in
# the captain-page theme, so a served report reads as a document, not raw text.
#
# Usage:
#   bin/fm-md-page.sh <report.md|page.html>...
#   bin/fm-md-page.sh <report.md|page.html> -o <out.html> [--title <title>]
#
# A .md source writes <name>.html beside it. An .html source is re-rendered in
# place, and only when it carries Markdown: either a page this script wrote
# (the verbatim source rides along in <script id="md-src">, so re-rendering is
# lossless and idempotent) or an older wrapper page whose only content is
# <pre> blocks that each open with a Markdown heading (their link line is kept).
# Any other HTML page is left untouched and named on stderr; the exit code is 1
# when any source was refused, 2 on a usage error. Writes are atomic.
#
# The page: a "back to Deck" link fixed at the top and bottom (/deck/),
# an outline pane with the current section lit, a reading-progress bar, and vim
# keys (j/k scroll, n/p next/previous heading, gg/G, d/u, gb back to Deck, t
# toggles the outline, za/zM/zR fold one/all/none, ? help).
# bin/fm_md.py's header owns the supported Markdown subset and the theme.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_md.py" "$@"
