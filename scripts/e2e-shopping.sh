#!/bin/zsh
# End-to-end UI test of the shopping cards (UITests/shopping): real taps on the demo chat's product cards.
# No fixture: the app runs its own demo chat. Usage: scripts/e2e-shopping.sh SIM_UDID
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-shopping.sh SIM_UDID (the UDID of a simulator of your own)}
DD=${HQN_DD:-build/dd}
mkdir -p build
[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $DD test -only-testing:HermesHQNativeUITests/ShoppingTapTests > build/last-e2e-shopping.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-shopping.log | tail -20
echo "e2e-shopping: xcodebuild exit $STATUS"; exit $STATUS
