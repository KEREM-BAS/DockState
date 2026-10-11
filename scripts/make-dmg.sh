#!/bin/bash
# Packages dist/DockState.app into a drag-to-install disk image.
#
#   scripts/make-dmg.sh <version>
#
# Signs the DMG when DEVELOPER_ID_APPLICATION is set. Notarize afterwards with
# scripts/notarize.sh. Set DMG_SUFFIX (e.g. "-unsigned") to mark unsigned builds.
# In GitHub Actions the DMG path is also written to the step output "dmg".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-dmg.sh <version>}"
SUFFIX="${DMG_SUFFIX:-}"
NAME="DockState-${VERSION}${SUFFIX}.dmg"
DMG="dist/$NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto dist/DockState.app "$STAGE/DockState.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DockState" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"
fi
# Checksum file names only the DMG, so `shasum -c` works next to the download.
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
cat "$DMG.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "dmg=$DMG" >> "$GITHUB_OUTPUT"; fi
echo "Created $DMG"
