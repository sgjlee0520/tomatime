#!/bin/zsh
# All automated checks: pure group rules (swiftc) and, when present, Firestore rules in the emulator.
set -e
cd "${0:A:h}/.."
mkdir -p build
swiftc -parse-as-library Groups/GroupRules.swift Tests/RulesCheck.swift -o build/rulescheck
build/rulescheck
# Own ports (firebase.test.json), so it runs while a staging emulator (firebase.json) is up.
export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"
cd firebase
npx firebase emulators:exec --config firebase.test.json --project demo-tomatime --only firestore "npm test" > ../build/rules-test.log 2>&1 \
  || { tail -40 ../build/rules-test.log; exit 1; }
grep -E "ℹ (pass|fail)" ../build/rules-test.log
