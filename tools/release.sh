#!/bin/zsh
# Mac App Store build: archive, sign (Apple Distribution + profile "Tomatime Store 20261110"),
# export build/export/Tomatime.pkg signed with the installer cert.
# Usage: tools/release.sh [--upload]   Bump CURRENT_PROJECT_VERSION in project.yml before every upload.
set -e
cd "${0:A:h}/.."
K=~/.appstoreconnect/distribution/sign.keychain-db
security unlock-keychain -p "" $K
security list-keychains -d user -s $K ~/Library/Keychains/login.keychain-db
xcodegen generate --quiet
rm -rf build/Tomatime.xcarchive build/export
xcodebuild -project Tomatime.xcodeproj -scheme Tomatime -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Tomatime.xcarchive -quiet archive \
  TOMATIME_SIGN_IDENTITY="Apple Distribution" TOMATIME_PROFILE="Tomatime Store 20261110" \
  TOMATIME_ENTITLEMENTS=tools/Store.entitlements OTHER_CODE_SIGN_FLAGS="--keychain $K"
xcodebuild -exportArchive -archivePath build/Tomatime.xcarchive -exportPath build/export \
  -exportOptionsPlist tools/ExportOptions.plist -quiet
pkgutil --check-signature build/export/Tomatime.pkg | sed -n 1,4p
if [[ "$1" == --upload ]]; then
  source ~/.appstoreconnect/asc.env  # ASC_KEY_ID, ASC_ISSUER_ID (kept out of the repo)
  xcrun altool --upload-app -t macos -f build/export/Tomatime.pkg \
    --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID
fi
