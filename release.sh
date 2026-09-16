#!/bin/bash
# Builds Faden and uploads it to TestFlight.
#
# Prerequisites (one-off, in App Store Connect / the Developer Portal):
#   1. Bundle ID dev.eigenhand.perbu registered
#   2. App record created (name, primary language, SKU)
#   3. API key with the "App Manager" role — already sitting under
#      ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#
# Usage:  ASC_ISSUER_ID=<issuer-uuid> ./release.sh
set -euo pipefail

# Local configuration, if there is any (it is in .gitignore).
[ -f .release.env ] && . ./.release.env

# No default: a hard-wired key ID is a detail about somebody else's account, and a
# fork would quietly try to sign with it.
KEY_ID="${ASC_KEY_ID:?ASC_KEY_ID is missing. Put it in .release.env; the ID is part of the file name under ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8}"
: "${ASC_ISSUER_ID:?Issuer ID is missing. Either put it in .release.env or prefix the call with ASC_ISSUER_ID=... . You will find it in App Store Connect > Users and Access > Integrations > App Store Connect API, above the key list.}"

ARCHIVE="build/Faden.xcarchive"
EXPORT="build/export"

# App Store Connect rejects uploads built with an Xcode beta (error 90534). If the
# active selection is a beta and a regular Xcode is installed beside it, this build
# switches over to the regular one — only for this script; the global selection
# stays untouched.
if xcode-select -p | grep -qi "beta" && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "==> Building with $(defaults read /Applications/Xcode.app/Contents/Info.plist CFBundleShortVersionString) instead of the beta"
fi

echo "==> Generating the project"
xcodegen generate

echo "==> Bumping the build number"
BUILD=$(date +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Faden/Info.plist 2>/dev/null || true

echo "==> Archiving"
xcodebuild -project Faden.xcodeproj -scheme Faden \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath build/dd \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

echo "==> Checking the network"
curl -s -o /dev/null --max-time 15 https://appstoreconnect.apple.com || {
  echo "    App Store Connect is unreachable — try again later."
  exit 1
}

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# From here on without the DEVELOPER_DIR override: the detour to the regular Xcode
# applies to the build only (Apple rejects beta builds). Its altool, by contrast,
# fails with "Defaults.properties couldn't be opened" while the beta's runs — so
# each tool gets the Xcode it works with.
unset DEVELOPER_DIR

echo "==> Validating"
xcrun altool --validate-app -f "$EXPORT/Faden.ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app -f "$EXPORT/Faden.ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Waiting for Apple to process it, then assigning to the internal group"
./assign-build.sh "$BUILD" || {
  echo "    (assignment not completed — check in App Store Connect)"
}

echo "==> Done."
