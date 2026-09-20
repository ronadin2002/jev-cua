#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${JEV_OUTPUT_DIR:-$SOURCE_DIR/dist}"
APP="$OUTPUT_DIR/Jev Voice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework ApplicationServices -framework Security -framework Carbon "$SOURCE_DIR"/Sources/*.swift -o "$APP/Contents/MacOS/JevVoice"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$SOURCE_DIR/AppIcon.icns" ]; then cp "$SOURCE_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
if [ -f "$SOURCE_DIR/Tests/FullRequest.aiff" ]; then cp "$SOURCE_DIR/Tests/FullRequest.aiff" "$APP/Contents/Resources/FullRequest.aiff"; fi
if [ -f "$SOURCE_DIR/Tests/Demo.wav" ]; then cp "$SOURCE_DIR/Tests/Demo.wav" "$APP/Contents/Resources/Demo.wav"; fi
SIGNING_IDENTITY="${JEV_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier ai.jev.voice --entitlements "$SOURCE_DIR/Entitlements.plist" "$APP"
printf 'Built %s\n' "$APP"
