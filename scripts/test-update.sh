#!/bin/bash
# End-to-end test of in-app updates (Sparkle), entirely on this Mac:
#
#   scripts/test-update.sh
#   SIGN_IDENTITY="Apple Development: Name (ID)" scripts/test-update.sh
#
# With SIGN_IDENTITY the copies are signed like a release (hardened runtime, Sparkle's
# helpers signed inside out, no XPC services), which also exercises Sparkle's team-ID
# checks between the app and its installer. Without it they are ad-hoc signed.
#
# Builds DockState Dev, makes an "old" 0.0.1 and a "new" 0.0.2 copy signed for a
# throw-away EdDSA key, serves 0.0.2 (DMG + appcast) from a local web server and checks:
#   1. a DMG whose signature doesn't match is refused, and the old app stays as it is;
#   2. a correctly signed update is downloaded, installed over the old app and relaunched.
# Never touches an installed DockState (Dev builds have their own bundle ID).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dockstate-update-test.XXXXXX")" && pwd -P)"  # real path: relaunched apps run from it
PORT="${PORT:-8765}"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "• Building DockState Dev"
xcodebuild -project DockState.xcodeproj -scheme DockState -configuration Debug \
  -derivedDataPath build/UpdateTest -clonedSourcePackagesDirPath build/SourcePackages \
  -destination "platform=macOS,arch=$(uname -m)" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO \
  build -quiet
BUILT="build/UpdateTest/Build/Products/Debug/DockStateDev.app"

echo "• Making a throw-away signing key"
cat > "$WORK/key.swift" <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
PUBLIC_KEY="$(swift "$WORK/key.swift" "$WORK/private.key")"

# copy <version> <build> <dir>: a copy of the Dev build with that version and the test key.
copy() {
  local app="$3/DockStateDev.app"
  mkdir -p "$3"
  ditto "$BUILT" "$app"
  plutil -replace CFBundleShortVersionString -string "$1" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$2" "$app/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$app/Contents/Info.plist"
  # Packaged like scripts/build-release.sh: no XPC services, helpers signed inside out,
  # hardened runtime; ad-hoc copies get only the entitlement to load Sparkle.framework.
  local fw="$app/Contents/Frameworks/Sparkle.framework" identity="${SIGN_IDENTITY:--}"
  local entitlements=()
  [[ -z "${SIGN_IDENTITY:-}" ]] && entitlements=(--entitlements Config/AdHoc.entitlements)
  rm -rf "$fw/Versions/B/XPCServices" "$fw/XPCServices"
  for item in "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app" "$fw"; do
    codesign --force --sign "$identity" --options=runtime "$item" 2>/dev/null
  done
  codesign --force --sign "$identity" --options=runtime ${entitlements[@]+"${entitlements[@]}"} "$app" 2>/dev/null
  local signature
  signature="$(codesign -dv "$app" 2>&1)"
  if [[ "$signature" != *",runtime)"* && "$signature" != *"(runtime)"* ]]; then
    echo "error: $app isn't signed with the hardened runtime" >&2
    exit 1
  fi
}
copy 0.0.1 1 "$WORK/old"
copy 0.0.2 2 "$WORK/new"

echo "• Publishing 0.0.2 on http://localhost:$PORT"
mkdir -p "$WORK/site"
DMG="$WORK/site/DockStateDev-0.0.2.dmg"
hdiutil create -volname "DockState Dev" -srcfolder "$WORK/new" -format UDZO -quiet "$DMG"
printf '## What’s new\n* Test update\n' > "$WORK/notes.md"
appcast() {
  # Never a SPARKLE_ED_PRIVATE_KEY from the environment: only the throw-away key.
  SPARKLE_ED_PRIVATE_KEY= APP="$WORK/new/DockStateDev.app" OUT="$WORK/site/appcast.xml" SPARKLE_KEY_FILE="$1" \
    DOWNLOAD_URL="http://localhost:$PORT/$(basename "$DMG")" \
    scripts/make-appcast.sh 0.0.2 "$DMG" "$WORK/notes.md" >/dev/null
}
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown
sleep 1

version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }

# run <log>: launches the old app in update-test mode (check now, install right away).
run() {
  "$WORK/old/DockStateDev.app/Contents/MacOS/DockStateDev" \
    -DockStateUpdateTest YES -DockStateUpdateTestLog "$1" \
    -SUFeedURL "http://localhost:$PORT/appcast.xml" \
    -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES -SUHasLaunchedBefore YES \
    >/dev/null 2>&1 &
  APP_PID=$!
  disown
}

FAILED=0
echo "• 1/2 Update signed with another key is refused"
cat > "$WORK/other.swift" <<'EOF'
import CryptoKit
import Foundation
try Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
  .write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
EOF
swift "$WORK/other.swift" "$WORK/other.key"
# make-appcast.sh refuses a mismatched key, so tamper with its output like an attacker would.
appcast "$WORK/private.key"
SIGN_UPDATE="$(find build/SourcePackages/artifacts -type f -name sign_update -path '*/bin/*' ! -path '*old_dsa*' | head -1)"
OTHER_SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$WORK/other.key" -p "$DMG")"
sed -i '' "s#sparkle:edSignature=\"[^\"]*\"#sparkle:edSignature=\"$OTHER_SIGNATURE\"#" "$WORK/site/appcast.xml"
run "$WORK/refused.log"
for _ in $(seq 1 30); do
  grep -qE "aborted|cycle finished" "$WORK/refused.log" 2>/dev/null && break
  sleep 1
done
kill "$APP_PID" 2>/dev/null || true
sleep 1
if grep -q "found 0.0.2" "$WORK/refused.log" 2>/dev/null && grep -qE "aborted|cycle finished: " "$WORK/refused.log" \
  && [[ "$(version_of "$WORK/old/DockStateDev.app")" == "0.0.1" ]]; then
  echo "  PASS: refused, still 0.0.1"
else
  echo "  FAIL"; FAILED=1
fi
sed 's/^/    /' "$WORK/refused.log" 2>/dev/null || true

echo "• 2/2 Signed update installs and relaunches"
appcast "$WORK/private.key"
run "$WORK/update.log"
UPDATED=""
for _ in $(seq 1 60); do
  if [[ -f "$WORK/old/DockStateDev.app/Contents/Info.plist" && "$(version_of "$WORK/old/DockStateDev.app" 2>/dev/null)" == "0.0.2" ]]; then
    UPDATED=yes; break
  fi
  sleep 1
done
RELAUNCHED=""
for _ in $(seq 1 15); do
  if pgrep -f "$WORK/old/DockStateDev.app/Contents/MacOS/DockStateDev" >/dev/null; then RELAUNCHED=yes; break; fi
  sleep 1
done
if [[ -n "$UPDATED" && -n "$RELAUNCHED" ]] && grep -q "installing 0.0.2" "$WORK/update.log"; then
  echo "  PASS: now 0.0.2, relaunched"
else
  echo "  FAIL (updated: ${UPDATED:-no}, relaunched: ${RELAUNCHED:-no})"; FAILED=1
fi
sed 's/^/    /' "$WORK/update.log" 2>/dev/null || true

exit "$FAILED"
