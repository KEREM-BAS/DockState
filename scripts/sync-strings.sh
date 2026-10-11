#!/bin/bash
# Extracts user-facing strings from the app's Swift sources into
# DockState/Localizable.xcstrings (Xcode does this automatically when building in
# the IDE; this script does the same from the command line / CI).
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="build/DerivedData"
xcodebuild -project DockState.xcodeproj -scheme DockState -configuration Debug \
  -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=$(uname -m)" \
  SWIFT_EMIT_LOC_STRINGS=YES build -quiet

FILES=$(find "$DERIVED/Build/Intermediates.noindex/DockState.build" -name "*.stringsdata" -path "*arm64*" -o -name "*.stringsdata" -path "*x86_64*" | sort -u)
ARGS=()
for f in $FILES; do ARGS+=(--stringsdata "$f"); done
xcrun xcstringstool sync DockState/Localizable.xcstrings "${ARGS[@]}"
echo "Synced $(echo "$FILES" | wc -l | tr -d ' ') files into DockState/Localizable.xcstrings"
