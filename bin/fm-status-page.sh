#!/usr/bin/env bash
# fm-status-page.sh - atomically publish one filtered page under state/status-page-public.
# Usage: FM_HOME=<home> bin/fm-status-page.sh
# Opt in to fleet activity events with config/fleet-ledger in that home.
# The private cursor and answer receipts live under state/.status-page, never served.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-status-page.py" "$@"
