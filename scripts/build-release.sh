#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release DockState.app into dist/.
#
#   scripts/build-release.sh [version]
#
# Signing:
#   - If DEVELOPER_ID_APPLICATION is set (e.g. "Developer ID Application: Name (TEAMID)")
#     and that identity is in the keychain, the app is signed with it, hardened runtime
#     and secure timestamp — ready for notarization.
#   - Otherwise the app is ad-hoc signed, without the hardened runtime. It runs, but
#     Gatekeeper will warn users; such builds must be labelled "unsigned" when published.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="dist"
ARCHIVE="build/DockState.xcarchive"
rm -rf "$ARCHIVE" "$DIST/DockState.app"
mkdir -p "$DIST"

# Ad-hoc builds run without the hardened runtime: it would refuse to load Sparkle.framework
# (no team ID), and they can't be notarized anyway.
SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  )
  echo "Signing with: $DEVELOPER_ID_APPLICATION"
else
  echo "warning: DEVELOPER_ID_APPLICATION not set — building an ad-hoc signed (unsigned) app" >&2
fi

xcodebuild archive \
  -project DockState.xcodeproj -scheme DockState -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
  -clonedSourcePackagesDirPath build/SourcePackages -onlyUsePackageVersionsFromResolvedFile \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${SIGN_ARGS[@]}" -quiet

ditto "$ARCHIVE/Products/Applications/DockState.app" "$DIST/DockState.app"

# Sparkle (in-app updates). DockState isn't sandboxed, so Sparkle's XPC services aren't
# needed. Archiving re-signs only the framework itself; its helpers keep Sparkle's ad-hoc
# signature, which notarization rejects. Sign them inside out, then the app again.
FW="$DIST/DockState.app/Contents/Frameworks/Sparkle.framework"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  SIGN=(codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options=runtime)
else
  SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" --preserve-metadata=entitlements,requirements,flags "$DIST/DockState.app"
echo "Architectures: $(lipo -archs "$DIST/DockState.app/Contents/MacOS/DockState")"
codesign --verify --deep --strict --verbose=1 "$DIST/DockState.app"
echo "Built $DIST/DockState.app ($VERSION, build $BUILD_NUMBER)"
