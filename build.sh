#!/bin/zsh
# Builds NetIndicator.app (Intel + Apple Silicon, macOS 13+) into ~/Applications and launches it.
# Any arguments are passed to the app, e.g. `./build.sh --demo --open` to preview the panel with sample data.
# `./build.sh --package` instead writes a release zip to .build/ without installing anything.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

# Compile both architectures first, so a build error leaves the installed copy untouched.
mkdir -p .build
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o ".build/NetIndicator-$arch"
done

BUNDLE=".build/NetIndicator.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
lipo -create .build/NetIndicator-arm64 .build/NetIndicator-x86_64 -output "$BUNDLE/Contents/MacOS/NetIndicator"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.netindicator</string>
    <key>CFBundleName</key><string>NetIndicator</string>
    <key>CFBundleExecutable</key><string>NetIndicator</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key>
    <string>macOS only reveals Wi-Fi network names to apps with Location access. NetIndicator uses it to list nearby networks and never stores your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS only reveals Wi-Fi network names to apps with Location access. NetIndicator uses it to list nearby networks and never stores your location.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE"

if [[ "${1:-}" == "--package" ]]; then
    ZIP=".build/NetIndicator-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    echo "Packaged: $ZIP"
    exit 0
fi

APP="$HOME/Applications/NetIndicator.app"
pkill -x NetIndicator 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$HOME/Applications"
cp -R "$BUNDLE" "$APP"
if (( $# )); then open "$APP" --args "$@"; else open "$APP"; fi
echo "Installed and launched: $APP"
