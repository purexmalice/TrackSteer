#!/usr/bin/env bash
# Sign, notarize and staple TrackSteer for distribution.
#
# Run this yourself -- it needs your keychain unlocked and your Apple
# credentials, neither of which should be handled by anything but you.
#
# One-time setup is described in NOTARIZING.md. Once that is done this script
# is the whole release process.
set -euo pipefail

APP="TrackSteer.app"
ZIP="TrackSteer-notarized.zip"
PROFILE="${NOTARY_PROFILE:-tracksteer}"

command -v xcrun >/dev/null || { echo "Xcode command line tools not found"; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')

if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate found."
  echo "See NOTARIZING.md -- step 1 creates it, and only you can do that."
  exit 1
fi
echo "signing as: $IDENTITY"

[ -d "$APP" ] || bash build.sh "$PWD" >/dev/null

# Hardened runtime is required for notarization. The app needs no entitlements
# beyond it: Accessibility is granted by the user at runtime, not declared here.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "submitting to Apple (this usually takes a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Staple the ticket into the app so it validates without a network round trip.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done. $ZIP is notarized and ready to upload."
echo "Users will no longer see the 'developer cannot be verified' warning,"
echo "and Accessibility permission will survive updates."
