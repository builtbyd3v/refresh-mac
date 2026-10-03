#!/bin/sh
# Builds dist/Refresh.app (menu bar only, ad-hoc signed).
set -e
cd "$(dirname "$0")/.."
swift build -c release --product RefreshApp
app=dist/Refresh.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/RefreshApp "$app/Contents/MacOS/Refresh"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.devgoswami.refresh</string>
  <key>CFBundleName</key><string>Refresh</string>
  <key>CFBundleExecutable</key><string>Refresh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "built $app"
