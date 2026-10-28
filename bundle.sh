#!/bin/bash
# Build a release binary and wrap it in TokenStatsBar.app (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
# Only the app: the test harness products use @testable import and do not build in release.
swift build -c release --product TokenStatsBar
app=TokenStatsBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/TokenStatsBar "$app/Contents/MacOS/TokenStatsBar"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenStatsBar</string>
<key>CFBundleIdentifier</key><string>com.evadnoob.tokenstatsbar</string>
<key>CFBundleName</key><string>TokenStatsBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$app"
echo "Built $app"
