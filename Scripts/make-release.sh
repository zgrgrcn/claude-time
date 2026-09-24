#!/bin/bash
# Builds a universal (arm64 + x86_64) ClaudeTime.app and claude-time CLI, signs them ad hoc and
# packages them into dist/:
#
#   dist/ClaudeTime-<version>-macos-universal.zip    ClaudeTime.app
#   dist/claude-time-<version>-macos-universal.zip   claude-time
#   dist/SHA256SUMS
#
# Then unzips both into a temp folder and checks them: architectures, signatures, versions, the
# CLI on generated demo data and the app's --snapshot mode (also under Rosetta when available).
# Installs nothing and leaves .build/ alone (it builds in build/release-scratch).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/ClaudeTimeCore/Version.swift)
[[ -n "$VERSION" ]] || { echo "can't read the version from Sources/ClaudeTimeCore/Version.swift" >&2; exit 1; }

ARCHS=(arm64 x86_64)
SCRATCH=build/release-scratch
OUT=build/release
APP="$OUT/ClaudeTime.app"
APP_ZIP="ClaudeTime-$VERSION-macos-universal.zip"
CLI_ZIP="claude-time-$VERSION-macos-universal.zip"

step() { printf '\n==> %s\n' "$*"; }

step "Building $VERSION for ${ARCHS[*]}"
app_slices=()
cli_slices=()
for arch in "${ARCHS[@]}"; do
    swift build -c release --arch "$arch" --scratch-path "$SCRATCH" --product ClaudeTime
    swift build -c release --arch "$arch" --scratch-path "$SCRATCH" --product claude-time
    bin=$(swift build -c release --arch "$arch" --scratch-path "$SCRATCH" --show-bin-path)
    app_slices+=("$bin/ClaudeTime")
    cli_slices+=("$bin/claude-time")
done

step "Assembling $APP and $OUT/claude-time"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ClaudeTime" "${app_slices[@]}"
lipo -create -output "$OUT/claude-time" "${cli_slices[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "Signing ad hoc"
codesign --force --sign - --timestamp=none --identifier com.zgrgrcn.claude-time.cli "$OUT/claude-time"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$OUT/claude-time"
codesign --verify --deep --strict "$APP"

step "Packaging into dist/"
mkdir -p dist
rm -f "dist/$APP_ZIP" "dist/$CLI_ZIP" dist/SHA256SUMS
# --norsrc --noextattr: no AppleDouble "._*" entries (local xattrs such as com.apple.provenance).
ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/$APP_ZIP"     # ClaudeTime.app/...
ditto -c -k --norsrc --noextattr "$OUT/claude-time" "dist/$CLI_ZIP"      # claude-time at the top level
(cd dist && shasum -a 256 "$APP_ZIP" "$CLI_ZIP" > SHA256SUMS)

step "Verifying the zips"
tmp="${TMPDIR:-/tmp}"
CHECK=$(mktemp -d "${tmp%/}/claude-time-release.XXXXXX")
trap 'rm -rf "$CHECK"' EXIT
(cd dist && shasum -a 256 -c SHA256SUMS)
[[ "$(unzip -Z1 "dist/$CLI_ZIP")" == "claude-time" ]] || { echo "$CLI_ZIP should contain only claude-time" >&2; exit 1; }
if unzip -Z1 "dist/$APP_ZIP" | grep -v '^ClaudeTime\.app/' | grep -q .; then
    echo "$APP_ZIP should contain only ClaudeTime.app" >&2; exit 1
fi
ditto -x -k "dist/$APP_ZIP" "$CHECK"
ditto -x -k "dist/$CLI_ZIP" "$CHECK"
UNZIPPED_APP="$CHECK/ClaudeTime.app"
for bin in "$UNZIPPED_APP/Contents/MacOS/ClaudeTime" "$CHECK/claude-time"; do
    archs=$(lipo -archs "$bin")
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { echo "$bin: unexpected architectures: $archs" >&2; exit 1; }
    echo "$(basename "$bin"): $archs"
done
codesign --verify --deep --strict "$UNZIPPED_APP"
[[ -x "$CHECK/claude-time" ]] || { echo "claude-time lost its executable bit" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNZIPPED_APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$("$CHECK/claude-time" --version)" == "claude-time $VERSION" ]]
Scripts/make-demo-data.sh "$CHECK/demo" >/dev/null
"$CHECK/claude-time" --root "$CHECK/demo" --no-cache >/dev/null
"$UNZIPPED_APP/Contents/MacOS/ClaudeTime" --snapshot "$CHECK/snapshot.png" --root "$CHECK/demo"
if arch -x86_64 /usr/bin/true 2>/dev/null; then  # Rosetta is installed: run the Intel slices too
    arch -x86_64 "$CHECK/claude-time" --root "$CHECK/demo" --no-cache >/dev/null
    arch -x86_64 "$UNZIPPED_APP/Contents/MacOS/ClaudeTime" --snapshot "$CHECK/snapshot-x86_64.png" --root "$CHECK/demo"
fi

step "Done"
ls -lh "dist/$APP_ZIP" "dist/$CLI_ZIP"
cat dist/SHA256SUMS
