#!/bin/zsh
# Development-signed build with the store entitlements (Sign in with Apple, iCloud, keychain group), run in place.
# Usage: tools/run-dev.sh [--build] [app args…]   --build: build only. App args e.g. --emulator, --fast.
# Needs profile "Tomatime Dev 20261110" (this Mac registered) and the Apple Development cert in the login keychain.
set -e
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project Tomatime.xcodeproj -scheme Tomatime -configuration Release -derivedDataPath build/dev -quiet build \
  TOMATIME_SIGN_IDENTITY="Apple Development" TOMATIME_PROFILE="Tomatime Dev 20261110" \
  TOMATIME_ENTITLEMENTS=tools/Store.entitlements
APP=build/dev/Build/Products/Release/Tomatime.app
[[ "$1" == --build ]] && exit 0
pkill -x Tomatime || true
open -n "$APP" --args "$@"
