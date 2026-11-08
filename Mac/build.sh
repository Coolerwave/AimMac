#!/bin/bash
# Builds AimMac.app for this Mac. Needs Xcode or the Command Line Tools.
#   ./build.sh        build
#   ./build.sh run    build and open
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AimMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O \
  -o "$APP/Contents/MacOS/AimMac" \
  Sources/*.swift ../Shared/Protocol.swift \
  -framework AppKit -framework CoreBluetooth -framework ApplicationServices

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/game.html "$APP/Contents/Resources/game.html"
cp Resources/duck.html "$APP/Contents/Resources/duck.html"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. After every rebuild macOS may forget the Accessibility
# permission: turn AimMac off and on again in
# System Settings > Privacy & Security > Accessibility.
# Finder/file-provider metadata can make codesign reject a freshly built bundle.
# Only clear attributes on this generated output, never on the source resources.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then
  pkill -x AimMac 2>/dev/null || true
  open "$APP"
fi
