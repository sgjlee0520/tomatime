#!/bin/zsh
# Direct-download Mac build (outside the App Store): Developer ID signed, notarized, stapled .dmg.
# Output: build/direct/Tomatime-<version>.dmg   Usage: tools/release-direct.sh
# Needs "Developer ID Application: Songgun Lee" in sign.keychain-db (cert W95YNF555V, key devid.key) and the
# profile "Tomatime Direct 20261114" (MAC_APP_DIRECT): iCloud needs a profile. Sign in with Apple isn't allowed outside the
# App Store, so this build compiles with DIRECT: Groups sign in anonymously (invite code + name), see codeSignIn.
set -e
cd "${0:A:h}/.."
[[ -f GoogleService-Info.plist ]] || { echo "GoogleService-Info.plist missing (gitignored): the build would ship without Groups"; exit 1; }
K=~/.appstoreconnect/distribution/sign.keychain-db
security unlock-keychain -p "" $K
security list-keychains -d user -s $K ~/Library/Keychains/login.keychain-db
source ~/.appstoreconnect/asc.env  # ASC_KEY_ID, ASC_ISSUER_ID (kept out of the repo)
xcodegen generate --quiet
OUT=build/direct; rm -rf $OUT; mkdir -p $OUT
xcodebuild -project Tomatime.xcodeproj -scheme Tomatime -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $OUT/Tomatime.xcarchive -quiet archive \
  TOMATIME_SIGN_IDENTITY="Developer ID Application" TOMATIME_PROFILE="Tomatime Direct 20261114" \
  TOMATIME_ENTITLEMENTS=tools/Direct.entitlements OTHER_CODE_SIGN_FLAGS="--keychain $K --timestamp" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DIRECT'
cat > $OUT/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>teamID</key><string>976B3SJZGY</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>provisioningProfiles</key><dict><key>com.sgjlee.tomatime</key><string>Tomatime Direct 20261114</string></dict>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath $OUT/Tomatime.xcarchive -exportPath $OUT/app -exportOptionsPlist $OUT/ExportOptions.plist -quiet
APP=$OUT/app/Tomatime.app
VER=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
DMG=$OUT/Tomatime-$VER.dmg
# The .dmg: the app plus an Applications link to drag it onto.
mkdir -p $OUT/dmg && cp -R $APP $OUT/dmg/ && ln -s /Applications $OUT/dmg/Applications
hdiutil create -quiet -volname "Tomatime" -srcfolder $OUT/dmg -fs HFS+ -format UDZO $DMG
codesign --sign "Developer ID Application" --keychain $K --timestamp $DMG
# Apple's malware check, then attach the ticket so it opens offline too.
xcrun notarytool submit $DMG --key ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 \
  --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID --wait
xcrun stapler staple -q $DMG
spctl -a -t open --context context:primary-signature -v $DMG
# A .zip too (easy to send): the app's ticket is attached so it opens offline as well.
xcrun stapler staple -q $APP
ditto -c -k --keepParent $APP $OUT/Tomatime-$VER.zip
spctl -a -t exec -v $APP
echo $DMG $OUT/Tomatime-$VER.zip
