#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release

APP="YouGotMentioned.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/YouGotMentioned "$APP/Contents/MacOS/"
strip "$APP/Contents/MacOS/YouGotMentioned"
cp Info.plist "$APP/Contents/"
cp YouGotMentioned.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

echo "Done → $PWD/$APP"
echo ""
echo "Drag YouGotMentioned.app to /Applications to install."
