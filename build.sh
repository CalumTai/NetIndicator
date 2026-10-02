#!/bin/zsh
# Builds NetIndicator.app into ~/Applications and launches it.
# Any arguments are passed to the app, e.g. `./build.sh --demo --open` to preview the panel with sample data.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/NetIndicator.app"

# Compile first so a build error leaves the installed copy untouched.
mkdir -p .build
swiftc -O Sources/*.swift -o .build/NetIndicator

pkill -x NetIndicator 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/NetIndicator "$APP/Contents/MacOS/NetIndicator"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.netindicator</string>
    <key>CFBundleName</key><string>NetIndicator</string>
    <key>CFBundleExecutable</key><string>NetIndicator</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key>
    <string>macOS only reveals Wi-Fi network names to apps with Location access. NetIndicator uses it to list nearby networks and never stores your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS only reveals Wi-Fi network names to apps with Location access. NetIndicator uses it to list nearby networks and never stores your location.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
if (( $# )); then open "$APP" --args "$@"; else open "$APP"; fi
echo "Installed and launched: $APP"
