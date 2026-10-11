#!/bin/bash
# Signs a release DMG for Sparkle and writes the appcast that announces it.
#
#   SPARKLE_ED_PRIVATE_KEY=… scripts/make-appcast.sh <version> <dmg> [notes.md]
#
# The app reads https://github.com/KEREM-BAS/DockState/releases/latest/download/appcast.xml,
# so each stable release carries its own appcast.xml with one item. Run this after the DMG
# is notarized and stapled: stapling changes the file, and with it the signature.
#
# The private key comes from $SPARKLE_ED_PRIVATE_KEY or from the file $SPARKLE_KEY_FILE
# (exported with `generate_keys -x`). Optional: $APP (default dist/DockState.app, the app
# inside the DMG), $OUT (default dist/appcast.xml), $DOWNLOAD_URL (default: the DMG on the
# GitHub release v<version>).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$1"
DMG="$2"
NOTES="${3:-}"
APP="${APP:-dist/DockState.app}"
OUT="${OUT:-dist/appcast.xml}"
REPO_URL="https://github.com/KEREM-BAS/DockState"
DOWNLOAD_URL="${DOWNLOAD_URL:-$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")}"

SIGN_UPDATE="$(find build/SourcePackages/artifacts -type f -name sign_update -path '*/bin/*' ! -path '*old_dsa*' 2>/dev/null | head -1)"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "error: Sparkle's sign_update not found; build first (scripts/build-release.sh)" >&2
  exit 1
fi

# Prints: sparkle:edSignature="…" length="…"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
elif [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG")"
else
  echo "error: set SPARKLE_ED_PRIVATE_KEY or SPARKLE_KEY_FILE" >&2
  exit 1
fi
if [[ ! "$SIGNATURE" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]]; then
  echo "error: unexpected output from sign_update" >&2
  exit 1
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
BUILD="$(plist CFBundleVersion)"
SHORT="$(plist CFBundleShortVersionString)"
MIN_OS="$(plist LSMinimumSystemVersion)"
if [[ "$SHORT" != "$VERSION" ]]; then
  echo "error: $APP is version $SHORT, expected $VERSION" >&2
  exit 1
fi

DESCRIPTION=""
if [[ -n "$NOTES" && -s "$NOTES" ]]; then
  TEXT="$(cat "$NOTES")"
  # The notes go into CDATA, which can't contain its own terminator.
  TEXT="${TEXT//]]>/]]]]><![CDATA[>}"
  DESCRIPTION="      <description sparkle:format=\"markdown\"><![CDATA[$TEXT]]></description>"
fi

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DockState</title>
    <link>$REPO_URL</link>
    <item>
      <title>DockState $SHORT</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$SHORT</sparkle:fullReleaseNotesLink>
$DESCRIPTION
      <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT"
echo "Wrote $OUT ($SHORT, build $BUILD)"
