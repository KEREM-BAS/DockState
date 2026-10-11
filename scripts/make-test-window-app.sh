#!/bin/bash
# Builds Tools/TestWindow into build/DockStateTestWindow.app for the end-to-end self-test:
#
#   scripts/make-test-window-app.sh
#   open build/DockStateTestWindow.app
#   open -n -a "$PWD/build/DerivedData/Build/Products/Debug/DockStateDev.app" --args \
#     -DockStateSelfTest /tmp/selftest.txt -DockStateSelfTestApp app.dockstate.testwindow \
#     -DockStateSelfTestFile "$PWD/build/DockStateTestWindow.app"
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/DockStateTestWindow.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Tools/TestWindow/main.swift -o "$APP/Contents/MacOS/DockStateTestWindow"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.dockstate.testwindow</string>
  <key>CFBundleName</key><string>DockStateTestWindow</string>
  <key>CFBundleExecutable</key><string>DockStateTestWindow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
