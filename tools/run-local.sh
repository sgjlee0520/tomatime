#!/bin/zsh
# Build Tomatime (ad-hoc signed, sandboxed like the store build), install to ~/Applications, launch.
# Usage: tools/run-local.sh [--fast]   (--fast: every "minute" is one second)
set -e
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project Tomatime.xcodeproj -scheme Tomatime -configuration Release \
  -derivedDataPath build/local -quiet build
pkill -x Tomatime || true
rm -rf ~/Applications/Tomatime.app
cp -R build/local/Build/Products/Release/Tomatime.app ~/Applications/
open ~/Applications/Tomatime.app --args "$@"
