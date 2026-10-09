#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Install for the current user by default. Set APP_PATH explicitly to choose a
# different .app bundle location (for example /Applications/AIMonitor.app).
APP_PATH="${APP_PATH:-$HOME/Applications/AI Monitor.app}"
case "$APP_PATH" in
    /*.app) ;;
    *)
        echo "APP_PATH must be an absolute path ending in .app" >&2
        exit 2
        ;;
esac

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aimonitor-build.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

swift build -c release --scratch-path "$SCRATCH"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp app/Info.plist "$APP_PATH/Contents/Info.plist"
cp app/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$SCRATCH/release/aimonitor-app" "$APP_PATH/Contents/MacOS/"
rm -rf "$APP_PATH/Contents/Resources/AIMonitor_aimonitor-app.bundle"
cp -R "$SCRATCH/release/AIMonitor_aimonitor-app.bundle" "$APP_PATH/Contents/Resources/"
rm -rf "$APP_PATH/Contents/MacOS/AIMonitor_aimonitor-app.bundle"
codesign --force --sign - --timestamp=none "$APP_PATH"
open "$APP_PATH"
echo "Installed and opened: $APP_PATH"
