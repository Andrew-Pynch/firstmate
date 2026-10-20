#!/usr/bin/env bash
# fm-telegram-send.sh - send plain text to this home's configured Telegram chat.
# Usage: FM_HOME=<home> bin/fm-telegram-send.sh <text>...
# Loads FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CHAT_ID from <home>/.env using
# Bun's dotenv reader. Prints only Telegram message ids, never credentials.
# Arguments beginning with -- are refused as message text; --help shows usage.
# See fm-telegram-bridge.ts for chunking and transport failure semantics.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SELF_DIR/.." && pwd)}"
export FM_HOME
if [ "$#" -eq 0 ] || [ "${1:-}" = --help ]; then
  printf 'Usage: FM_HOME=<home> %s <text>...\n' "$0"
  if [ "$#" -eq 0 ]; then exit 1; fi
  exit 0
fi
exec bun --env-file="$FM_HOME/.env" "$SELF_DIR/fm-telegram-bridge.ts" send "$@"
