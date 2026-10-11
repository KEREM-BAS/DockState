#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release DockState.app into dist/.
#
#   scripts/build-release.sh [version]
#
# Signing:
#   - If DEVELOPER_ID_APPLICATION is set (e.g. "Developer ID Application: Name (TEAMID)")
#     and that identity is in the keychain, the app is signed with it, hardened runtime
#     and secure timestamp — ready for notarization.
#   - Otherwise the app is ad-hoc signed. It runs, but Gatekeeper will warn users;
#     such builds must be labelled "unsigned" when published.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="dist"
ARCHIVE="build/DockState.xcarchive"
rm -rf "$ARCHIVE" "$DIST/DockState.app"
mkdir -p "$DIST"

SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  )
  echo "Signing with: $DEVELOPER_ID_APPLICATION"
else
  echo "warning: DEVELOPER_ID_APPLICATION not set — building an ad-hoc signed (unsigned) app" >&2
fi

xcodebuild archive \
  -project DockState.xcodeproj -scheme DockState -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${SIGN_ARGS[@]}" -quiet

ditto "$ARCHIVE/Products/Applications/DockState.app" "$DIST/DockState.app"
echo "Architectures: $(lipo -archs "$DIST/DockState.app/Contents/MacOS/DockState")"
codesign --verify --deep --strict --verbose=1 "$DIST/DockState.app"
echo "Built $DIST/DockState.app ($VERSION, build $BUILD_NUMBER)"
