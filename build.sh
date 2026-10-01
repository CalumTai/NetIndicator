#!/bin/zsh
# Builds NetIndicator.app into ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/NetIndicator.app"
pkill -x NetIndicator 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/NetIndicator"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.netindicator</string>
    <key>CFBundleName</key><string>NetIndicator</string>
    <key>CFBundleExecutable</key><string>NetIndicator</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
open "$APP"
echo "Installed and launched: $APP"
