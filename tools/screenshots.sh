#!/bin/zsh
# App Store screenshots for iPhone (6.9", iPhone 17 Pro Max) and Apple Watch (Ultra 3, 49 mm) from the
# simulators, using the Debug-only -demo states (TimerModel / WatchModel). Output: store/screenshots-ios/.
set -e
cd "${0:A:h}/.."
OUT=store/screenshots-ios; mkdir -p $OUT
xcodegen generate -q
xcodebuild -project Tomatime.xcodeproj -scheme TomatimeiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios build -quiet
xcodebuild -project Tomatime.xcodeproj -scheme TomatimeWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath build/watch build -quiet
sim() {  # name, device type, runtime → udid (created once)
  local id=$(xcrun simctl list devices | grep "$1 (" | head -1 | grep -oE '[0-9A-F-]{36}')
  [[ -n $id ]] || id=$(xcrun simctl create "$1" "$2" "$3")
  xcrun simctl boot $id 2>/dev/null || true
  echo $id
}
shot() {  # udid, bundle path, file, demo...
  local id=$1 app=$2 file=$3; shift 3
  xcrun simctl terminate $id com.sgjlee.tomatime${APPSUFFIX} 2>/dev/null || true
  xcrun simctl launch $id com.sgjlee.tomatime${APPSUFFIX} "$@" > /dev/null
  sleep 4
  xcrun simctl io $id screenshot $OUT/$file > /dev/null 2>&1
  echo $OUT/$file
}
P=$(sim "Tomatime Shots iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-26-3)
xcrun simctl status_bar $P override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl uninstall $P com.sgjlee.tomatime 2>/dev/null || true
xcrun simctl install $P build/ios/Build/Products/Debug-iphonesimulator/Tomatime.app
APPSUFFIX=""
shot $P x iphone-1-pick.png
shot $P x iphone-2-clock.png -demo clock
shot $P x iphone-3-numbers.png -demo running
shot $P x iphone-4-break.png -demo done
W=$(sim "Tomatime Shots Watch" com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm com.apple.CoreSimulator.SimRuntime.watchOS-26-2)
xcrun simctl uninstall $W com.sgjlee.tomatime.watchkitapp 2>/dev/null || true
xcrun simctl install $W build/watch/Build/Products/Debug-watchsimulator/Tomatime.app
APPSUFFIX=".watchkitapp"
xcrun simctl launch $W com.sgjlee.tomatime.watchkitapp > /dev/null; sleep 10  # first launch is slow
shot $W x watch-1-clock.png -demo clock
shot $W x watch-2-time.png -demo running
shot $W x watch-3-break.png -demo done
xcrun simctl terminate $W com.sgjlee.tomatime.watchkitapp; xcrun simctl launch $W com.sgjlee.tomatime.watchkitapp > /dev/null; sleep 4
xcrun simctl io $W screenshot $OUT/watch-4-pick.png > /dev/null 2>&1; echo $OUT/watch-4-pick.png
