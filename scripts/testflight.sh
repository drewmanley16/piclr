#!/usr/bin/env bash
# Archive, export, and upload pickleball.ai to TestFlight.
#
# Prereqs (one-time):
#   1) App Store Connect API key generated (Users and Access -> Integrations
#      -> App Store Connect API -> generate a key with "App Manager" role).
#      Save the .p8 to ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#   2) An app record exists in App Store Connect for the bundle id below.
#
# Usage:
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
#     scripts/testflight.sh
set -euo pipefail

SCHEME="PickleballAI"
PROJECT="PickleballAI.xcodeproj"
ARCHIVE="build/PickleballAI.xcarchive"
EXPORT_DIR="build/export"
BUNDLE_ID="com.pickleball.ai"

: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API key id}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer id}"

# Build number comes from project.yml (CURRENT_PROJECT_VERSION). Bump it there
# before each upload — App Store Connect requires it to increase within a version.
echo "==> Build number: $(grep CURRENT_PROJECT_VERSION project.yml | head -1 | grep -oE '[0-9]+')"

echo "==> Archiving (device, Release)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
  clean archive

# ExportOptions.plist uses manual signing with the "pickleball ai App Store"
# provisioning profile (App Manager API keys can't do cloud signing on export).
echo "==> Exporting .ipa…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist

IPA=$(ls "$EXPORT_DIR"/*.ipa | head -1)
echo "==> Uploading $IPA to App Store Connect…"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Done. Build will appear in TestFlight after processing (a few minutes)."
