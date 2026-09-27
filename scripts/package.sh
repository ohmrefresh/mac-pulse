#!/usr/bin/env bash
# Builds a distributable DMG (ADR 0001: Developer ID, notarized, hardened runtime, no sandbox).
#
#   scripts/package.sh                                    # local test build: ad-hoc signed, NOT notarized
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=macpulse scripts/package.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials macpulse --apple-id <id> --team-id <TEAMID>
set -euo pipefail

cd "$(dirname "$0")/.."
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD=.build/package
DIST=dist

if [[ -n "$NOTARY_PROFILE" && -z "$DEVELOPER_ID" ]]; then
  echo "error: notarization needs DEVELOPER_ID (Apple rejects ad-hoc signatures)" >&2
  exit 1
fi

VERSION="$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)"
[[ -n "$VERSION" ]] || { echo "error: MARKETING_VERSION not found in project.yml" >&2; exit 1; }

echo "==> Building Release $VERSION"
xcodegen generate >/dev/null
xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$BUILD" build >/dev/null
APP="$BUILD/Build/Products/Release/MacPulse.app"

# Re-sign explicitly so the hardened runtime and secure timestamp are guaranteed, whatever
# the build settings did (notarization requires both).
echo "==> Signing"
if [[ -n "$DEVELOPER_ID" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --options runtime --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
if ! codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "error: hardened runtime flag missing from signature" >&2
  exit 1
fi

echo "==> Creating DMG"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/MacPulse-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Mac Pulse" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null

if [[ -z "$DEVELOPER_ID" ]]; then
  echo
  echo "LOCAL TEST BUILD: $DMG"
  echo "Ad-hoc signed and not notarized — Gatekeeper will block it on other Macs."
  exit 0
fi

codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo
  echo "SIGNED, NOT NOTARIZED: $DMG  (set NOTARY_PROFILE to notarize)"
  exit 0
fi

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo
echo "READY TO DISTRIBUTE: $DMG"
