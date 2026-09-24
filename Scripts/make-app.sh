#!/bin/bash
# Builds ClaudeTime.app (menu bar app, this Mac's architecture) into build/ and the claude-time CLI
# into .build/release/. Pass --install to copy the app to /Applications, link the CLI to
# ~/.local/bin/claude-time and launch the app. For universal release zips see make-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/ClaudeTimeCore/Version.swift)
[[ -n "$VERSION" ]] || { echo "can't read the version from Sources/ClaudeTimeCore/Version.swift" >&2; exit 1; }

swift build -c release --product ClaudeTime
swift build -c release --product claude-time

APP=build/ClaudeTime.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeTime "$APP/Contents/MacOS/ClaudeTime"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP ($VERSION)"
echo "cli:   .build/release/claude-time"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ClaudeTime 2>/dev/null || true
    rm -rf /Applications/ClaudeTime.app
    cp -R "$APP" /Applications/ClaudeTime.app
    mkdir -p "$HOME/.local/bin"
    ln -sf "$PWD/.build/release/claude-time" "$HOME/.local/bin/claude-time"
    open /Applications/ClaudeTime.app
    echo "installed: /Applications/ClaudeTime.app, ~/.local/bin/claude-time"
fi
