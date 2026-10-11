#!/bin/bash
# Notarizes and staples a DMG with Apple's notary service.
#
#   scripts/notarize.sh dist/DockState-1.0.0.dmg
#
# Credentials (App Store Connect API key — recommended for CI):
#   NOTARY_KEY_PATH   path to the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID     key ID
#   NOTARY_ISSUER_ID  issuer ID
# or (Apple ID):
#   APPLE_ID, APPLE_APP_PASSWORD (app-specific password), APPLE_TEAM_ID
set -euo pipefail
DMG="${1:?usage: notarize.sh <dmg>}"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${APPLE_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "error: no notarization credentials provided" >&2
  exit 1
fi

xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 30m
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Notarized and stapled $DMG"
