#!/usr/bin/env bash
# Prepare a scrubbed, local-only plan bundle for reviewer-facing publication.
#
# Usage: fm-plan-bundle.sh <task-id>
# Reads existing brief.md, report.md, and plan.html from FM_HOME/data/<task-id>
# (FM_HOME defaults to FM_ROOT_OVERRIDE or this script's repository root).
# Copies only those files to a private mktemp directory under TMPDIR (or /tmp),
# leaving the sources unchanged. At least one file must exist.
# Replaces HOME with ~, tailnet hosts and CGNAT IPs with placeholders, supported
# GitHub/Slack/sk- tokens and TOKEN/SECRET/KEY/PASSWORD assignments with <redacted>,
# and PEM private-key blocks with <redacted>. Remaining /home/, .ts.net, CGNAT,
# or PRIVATE KEY text refuses the entire bundle without printing leaked bytes.
# Failure removes the temporary directory; success leaves it for Main and prints
# one `sha256  filename` line per file followed by `bundle=<directory>`.
# Dependencies: Bash, sed -E, grep, mktemp, cp, mv, rm, and sha256sum or shasum.
#
# Main then publishes the scrubbed report/brief and digest table through Linear
# MCP save_document (parent = the task issue), attaches plan.html through
# prepare_attachment_upload, and reads the document back with get_document.
# This tool does no network I/O. The bucket is NOT used: deepstar/AGENTS.md:282
# prohibits agent bucket writes and write credentials.
set -euo pipefail
umask 077

usage() { printf 'Usage: fm-plan-bundle.sh <task-id>\n'; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  ''|.|..|*[!A-Za-z0-9._-]*) die 'task-id must be one directory name (letters, digits, dot, underscore, hyphen)' ;;
esac
[ -n "${HOME:-}" ] && [ "$HOME" != / ] || die 'HOME must name a non-root home directory'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
SOURCE="$FM_HOME/data/$1"
[ -d "$SOURCE" ] || die 'task data directory does not exist'

BUNDLE=$(mktemp -d "${TMPDIR:-/tmp}/fm-plan-bundle.XXXXXX")
cleanup() { [ -z "$BUNDLE" ] || rm -rf -- "$BUNDLE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Escape an arbitrary HOME as an ERE literal, including the sed delimiter.
home_pattern=$(printf '%s\n' "${HOME%/}" | sed 's/[][\\.^$*+?(){}|#]/\\&/g')
cgnat='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+'
files=()
for name in brief.md report.md plan.html; do
  [ -e "$SOURCE/$name" ] || continue
  [ -f "$SOURCE/$name" ] || die 'bundle inputs must be regular files'
  cp -- "$SOURCE/$name" "$BUNDLE/$name"
  sed -E \
    -e "s#$home_pattern#~#g" \
    -e 's#[A-Za-z0-9-]+\.tail[0-9a-f]+\.ts\.net#<tailnet-host>#g' \
    -e "s#$cgnat#<tailnet-ip>#g" \
    -e 's#(gh[pousr]_|github_pat_|xox[abprs]-|sk-)[A-Za-z0-9_-]+#<redacted>#g' \
    -e "s#[A-Z0-9_]*(TOKEN|SECRET|KEY|PASSWORD)=(\"[^\"]*\"|'[^']*'|[^[:space:]]+)#<redacted>#g" \
    -e '/-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----/,/-----END ([A-Z0-9]+ )*PRIVATE KEY-----/{
/-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----/c\
<redacted>
d
}' "$BUNDLE/$name" > "$BUNDLE/.scrubbed"
  mv -- "$BUNDLE/.scrubbed" "$BUNDLE/$name"
  rc=0
  LC_ALL=C grep -Ei "/home/|\.ts\.net|$cgnat|PRIVATE KEY" "$BUNDLE/$name" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || die "bundle refused: residual leak or unreadable file in $name"
  files+=("$name")
done
[ "${#files[@]}" -gt 0 ] || die 'no brief.md, report.md, or plan.html found'

# Delay all publication output until every copied file passes the leak check.
for name in "${files[@]}"; do
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$BUNDLE/$name")
  else
    digest=$(shasum -a 256 "$BUNDLE/$name")
  fi
  printf '%s  %s\n' "${digest%% *}" "$name"
done
printf 'bundle=%s\n' "$BUNDLE"
BUNDLE=''
