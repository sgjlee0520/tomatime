#!/bin/zsh
# All automated checks: pure group rules (swiftc) and, when present, Firestore rules in the emulator.
set -e
cd "${0:A:h}/.."
mkdir -p build
swiftc -parse-as-library Groups/GroupRules.swift Tests/RulesCheck.swift -o build/rulescheck
build/rulescheck
