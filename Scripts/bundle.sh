#!/bin/bash
# Builds NotchActivity.app from the Swift package.
#   Scripts/bundle.sh            -> build/NotchActivity.app
# Environment:
#   CODESIGN_IDENTITY   signing identity (default "-", ad-hoc). A stable identity such as
#                       "Apple Development: you@example.com (TEAMID)" keeps privacy
#                       permissions (Calendar, Automation) across rebuilds.
#   VERSION             marketing version (default: contents of VERSION file)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${BUNDLE_ID:-com.harrisonbraun.notchactivity}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/NotchActivity.app"

echo "==> Compiling (release)"
swift build -c release 2>&1 | grep -E "error|warning|Compiling|Build complete" | grep -v "^\[" || true
BIN="$(swift build -c release --show-bin-path)"
[ -x "$BIN/NotchActivity" ] || { echo "error: build failed" >&2; exit 1; }

echo "==> Assembling $APP ($VERSION, build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchActivity" "$APP/Contents/MacOS/NotchActivity"
cp "$BIN/notch" "$APP/Contents/Resources/notch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/notch"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> Built $APP"
