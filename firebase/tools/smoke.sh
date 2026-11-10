#!/bin/zsh
# Run inside: npx firebase emulators:exec --project demo-tomatime --only auth,firestore "zsh tools/smoke.sh"
# Needs a dev build first: tools/run-dev.sh --build
set -e
APP=../build/dev/Build/Products/Release/Tomatime.app/Contents/MacOS/Tomatime
LOG=../build/smoke-app.log
$APP --emulator --smoke > $LOG 2>&1 &
P=$!
for i in {1..30}; do kill -0 $P 2>/dev/null || break; sleep 1; done
kill $P 2>/dev/null && echo "app still running after 30 s (no --smoke support?)"
OUT=$(grep '^SMOKE' $LOG || true)
echo "$OUT"
node tools/smoke.mjs "${OUT#SMOKE }"
node tools/fake-member.mjs join "${OUT#SMOKE }" Mina
