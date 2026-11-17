#!/bin/zsh
# Checks for the Windows app (windows/): its rules, then the timer and Groups against the local Firebase
# emulators with the real security rules. No windows are shown. Usage: tools/test-windows.sh
set -e
cd "${0:A:h}/../windows"
npm test 2>&1 | grep -E "^(✖|ℹ (pass|fail))|not ok" || true
export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"
cd ../firebase
npx firebase emulators:exec --project demo-tomatime --only auth,firestore "cd ../windows && npm run test:live" > ../build/windows-test.log 2>&1 \
  || { grep -vE "^\s*$" ../build/windows-test.log | tail -60; exit 1; }
grep -E "^(✔|✖)|ℹ (pass|fail)" ../build/windows-test.log
# The real windows, clicked through while hidden (nothing appears on screen).
npx firebase emulators:exec --project demo-tomatime --only auth,firestore "cd ../windows && npx electron . --emulator --fast --selftest" > ../build/windows-selftest.log 2>&1 \
  || { grep -E "^ok|SELFTEST|Error" ../build/windows-selftest.log | tail -40; exit 1; }
grep -cE "^ok" ../build/windows-selftest.log | sed 's/$/ window checks ok/'; grep SELFTEST ../build/windows-selftest.log
