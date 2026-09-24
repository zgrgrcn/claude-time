#!/bin/bash
# Generates synthetic Claude Code transcripts (six fictional projects, last 30 days) for demos,
# screenshots and manual testing. Nothing is read from or written to ~/.claude.
#
#   Scripts/make-demo-data.sh [OUT_DIR] [--days N] [--seed N]
#
# Without OUT_DIR it creates a new temp folder. Prints the folder and commands to try.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days|--seed)
            [[ $# -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; }
            args+=("$1" "$2"); shift 2 ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) out="$1"; shift ;;
    esac
done
if [[ -z "$out" ]]; then
    tmp="${TMPDIR:-/tmp}"
    out="$(mktemp -d "${tmp%/}/claude-time-demo.XXXXXX")"
fi

python3 "$here/demo_data.py" ${args[@]+"${args[@]}"} "$out"
out="$(cd "$out" && pwd -P)"

cat <<EOF

Try it (from the repository root):
  swift run claude-time --root "$out" --no-cache
  swift run claude-time --root "$out" --no-cache payments-api
  swift run ClaudeTime --snapshot "$out.png" --root "$out" --select payments-api
EOF
