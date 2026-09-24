#!/bin/bash
# Regenerates the README assets from synthetic demo data (see make-demo-data.sh):
#   docs/screenshot-light.png, docs/screenshot-dark.png, docs/screenshot-dark-detail.png, docs/cli.txt
# Uses the app's --snapshot mode and the CLI with --root; never reads ~/.claude or the scan cache.
# Dates and times follow your macOS region settings.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="${TMPDIR:-/tmp}"
DEMO="$(mktemp -d "${tmp%/}/claude-time-demo.XXXXXX")"
trap 'rm -rf "$DEMO"' EXIT
Scripts/make-demo-data.sh "$DEMO" >/dev/null

swift build --product ClaudeTime
swift build --product claude-time
BIN="$(swift build --show-bin-path)"

mkdir -p docs
"$BIN/ClaudeTime" --snapshot docs/screenshot-light.png --root "$DEMO"
"$BIN/ClaudeTime" --snapshot docs/screenshot-dark.png --root "$DEMO" --dark
"$BIN/ClaudeTime" --snapshot docs/screenshot-dark-detail.png --root "$DEMO" --dark --select payments-api

cli() { "$BIN/claude-time" --root "$DEMO" --no-cache "$@"; }
{
    echo '$ claude-time'
    cli
    echo
    echo '$ claude-time payments-api'
    cli payments-api
} > docs/cli.txt
echo "wrote docs/cli.txt"
