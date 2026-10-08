#!/usr/bin/env bash
# fm-status-serve.sh - loopback-only status and decision service.
# Usage: FM_HOME=<home> bin/fm-status-serve.sh
# Port is config/status-page-port (default 8795). Mount via tailscale serve /fm-status.
# Only state/status-page-public/index.html is served; private home data stays private.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-status-serve.py" "$@"
