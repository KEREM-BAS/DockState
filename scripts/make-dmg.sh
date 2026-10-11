#!/bin/bash
# Packages dist/DockState.app into a drag-to-install disk image.
#
#   scripts/make-dmg.sh <version>
#
# Signs the DMG when DEVELOPER_ID_APPLICATION is set. Notarize afterwards with
# scripts/notarize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-dmg.sh <version>}"
SUFFIX="${DMG_SUFFIX:-}"
DMG="dist/DockState-${VERSION}${SUFFIX}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto dist/DockState.app "$STAGE/DockState.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DockState" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Created $DMG"
