#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
AIMONITOR_OUTPUT="${1:?Usage: bash scripts/package-macos.sh /absolute/output.dmg}"
[[ "$AIMONITOR_OUTPUT" = /*.dmg ]] || { echo 'An absolute .dmg output path is required.' >&2; exit 1; }
[[ ! -e "$AIMONITOR_OUTPUT" && ! -e "$AIMONITOR_OUTPUT.sha256" ]] || { echo 'Output already exists; choose a new filename.' >&2; exit 1; }
AIMONITOR_STAGE=$(mktemp -d /tmp/aimonitor-package.XXXXXX)
AIMONITOR_SIGN_IDENTITY="${AIMONITOR_SIGN_IDENTITY:--}"
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$AIMONITOR_STAGE/build"
AIMONITOR_PRODUCTS="$AIMONITOR_STAGE/build/out/Products/Release"
AIMONITOR_APP="$AIMONITOR_STAGE/root/AIMonitor.app"
mkdir -p "$AIMONITOR_APP/Contents/MacOS" "$AIMONITOR_APP/Contents/Resources"
ditto "$AIMONITOR_PRODUCTS/aimonitor-app" "$AIMONITOR_APP/Contents/MacOS/aimonitor-app"
ditto "$AIMONITOR_PRODUCTS/AIMonitor_aimonitor-app.bundle" "$AIMONITOR_APP/Contents/Resources/AIMonitor_aimonitor-app.bundle"
cp app/Info.plist "$AIMONITOR_APP/Contents/Info.plist"
cp app/AppIcon.icns "$AIMONITOR_APP/Contents/Resources/AppIcon.icns"
cp docs/MAC_INSTALL.txt "$AIMONITOR_STAGE/root/安装说明.txt"
ln -s /Applications "$AIMONITOR_STAGE/root/Applications"
git ls-files -z --cached --others --exclude-standard -- Package.swift Sources app | sort -zu | xargs -0 shasum -a 256 > "$AIMONITOR_STAGE/root/SOURCE-SHA256.txt"
{
    printf 'AI Monitor %s / Cat Observatory UI\n' "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Info.plist)"
    printf 'Built UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
    printf 'Source HEAD: '; git rev-parse HEAD
    printf 'Source tree: current working tree; see SOURCE-SHA256.txt\n'
    printf 'Architecture: Universal 2 (arm64 + x86_64)\nMinimum macOS: 14.0\nNotarization: NOT NOTARIZED\n'
    swift --version
} > "$AIMONITOR_STAGE/root/BUILD-PROVENANCE.txt"
if [[ "$AIMONITOR_SIGN_IDENTITY" == '-' ]]; then
    codesign --force --options runtime --sign - --timestamp=none "$AIMONITOR_APP"
else
    codesign --force --options runtime --timestamp --sign "$AIMONITOR_SIGN_IDENTITY" "$AIMONITOR_APP"
fi
codesign --verify --deep --strict --verbose=2 "$AIMONITOR_APP"
plutil -lint "$AIMONITOR_APP/Contents/Info.plist"
AIMONITOR_ARCHS="$(lipo "$AIMONITOR_APP/Contents/MacOS/aimonitor-app" -archs)"
[[ " $AIMONITOR_ARCHS " == *' arm64 '* && " $AIMONITOR_ARCHS " == *' x86_64 '* ]] || {
    echo "Expected a Universal 2 app (arm64 + x86_64); found: $AIMONITOR_ARCHS" >&2
    exit 1
}
# grep, not rg: this runs under /bin/bash, where ripgrep is often absent — and
# a missing command made this `if` quietly false, so the check never ran.
if strings "$AIMONITOR_APP/Contents/MacOS/aimonitor-app" | grep -E -q -- '--render-review|--demo-window'; then
    echo 'DEBUG review entry point leaked into Release.' >&2; exit 1
fi
(cd "$AIMONITOR_STAGE/root"; find AIMonitor.app -type f -print0 | sort -z | xargs -0 shasum -a 256 > MANIFEST-SHA256.txt)
hdiutil create -volname 'AIMonitor Cat Observatory' -srcfolder "$AIMONITOR_STAGE/root" -format UDZO "$AIMONITOR_OUTPUT"
hdiutil verify "$AIMONITOR_OUTPUT"
(cd "$(dirname "$AIMONITOR_OUTPUT")"; shasum -a 256 "$(basename "$AIMONITOR_OUTPUT")" > "$(basename "$AIMONITOR_OUTPUT").sha256")
printf 'Package: %s\nStaging: %s\n' "$AIMONITOR_OUTPUT" "$AIMONITOR_STAGE"
