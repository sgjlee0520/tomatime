#!/bin/zsh
# Archive the iPhone app (with the Watch app inside) and upload it to App Store Connect / TestFlight.
# Signing and upload go through the Apple ID signed in to Xcode (Settings → Accounts): the App Store Connect
# API key has no cloud-signing permission and cannot register the watch App Group.
set -e
cd "${0:A:h}/.."
[[ -f GoogleService-Info.plist ]] || { echo "GoogleService-Info.plist missing (Firebase config, kept out of git)"; exit 1; }
xcodegen generate -q
rm -rf build/TomatimeiOS.xcarchive
xcodebuild archive -project Tomatime.xcodeproj -scheme TomatimeiOS -destination 'generic/platform=iOS' \
  -archivePath build/TomatimeiOS.xcarchive -allowProvisioningUpdates > build/archive-ios.log 2>&1 || { grep -E "error:" build/archive-ios.log | sort -u | head -20; exit 1; }
xcodebuild -exportArchive -archivePath build/TomatimeiOS.xcarchive -exportOptionsPlist tools/ExportOptions-ios.plist \
  -exportPath build/export-ios -allowProvisioningUpdates > build/export-ios.log 2>&1 || { grep -E "error" build/export-ios.log | sort -u | head -20; exit 1; }
grep -E "Upload succeeded|EXPORT SUCCEEDED|Uploaded" build/export-ios.log | head -3
