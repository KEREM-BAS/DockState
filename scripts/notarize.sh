#!/bin/bash
# Notarizes and staples DockState with Apple's notary service.
#
#   scripts/notarize.sh app                  # dist/DockState.app (submitted as a zip)
#   scripts/notarize.sh dist/DockState-1.0.0.dmg
#
# Notarize the app first (so the app itself carries a stapled ticket and launches offline),
# then build the DMG and notarize that too.
#
# Credentials (App Store Connect API key — recommended for CI):
#   NOTARY_KEY_PATH   path to the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID     key ID
#   NOTARY_ISSUER_ID  issuer ID
# or (Apple ID):
#   APPLE_ID, APPLE_APP_PASSWORD (app-specific password), APPLE_TEAM_ID
set -euo pipefail
TARGET="${1:?usage: notarize.sh app|<dmg>}"
# Resolve paths given relative to the caller's directory before moving to the repo root.
absolute() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
[[ "$TARGET" == "app" ]] || TARGET="$(absolute "$TARGET")"
[[ -z "${NOTARY_KEY_PATH:-}" ]] || NOTARY_KEY_PATH="$(absolute "$NOTARY_KEY_PATH")"
cd "$(dirname "$0")/.."


if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${APPLE_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "error: no notarization credentials provided" >&2
  exit 1
fi

if [[ "$TARGET" == "app" ]]; then
  ZIP="dist/DockState-notarize.zip"
  trap 'rm -f "$ZIP"' EXIT
  ditto -c -k --keepParent dist/DockState.app "$ZIP"
  xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait --timeout 30m
  xcrun stapler staple dist/DockState.app
  xcrun stapler validate dist/DockState.app
  spctl --assess --type execute --verbose dist/DockState.app
  echo "Notarized and stapled dist/DockState.app"
else
  xcrun notarytool submit "$TARGET" "${AUTH[@]}" --wait --timeout 30m
  xcrun stapler staple "$TARGET"
  xcrun stapler validate "$TARGET"
  spctl --assess --type open --context context:primary-signature --verbose "$TARGET"
  NAME="$(basename "$TARGET")"
  (cd "$(dirname "$TARGET")" && shasum -a 256 "$NAME" > "$NAME.sha256")
  echo "Notarized and stapled $TARGET"
fi
