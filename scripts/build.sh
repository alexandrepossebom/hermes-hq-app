#!/bin/zsh
# Build (and optionally test) for the simulator. Usage: scripts/build.sh [test] [SIM_UDID]
# Uses ./build/dd as derived data, so separate worktrees never share build products.
set -e
cd "$(dirname "$0")/.."
# [duo] Xcode 27.2 as scripts/ship.py (the Duo's sensor column); DEVELOPER_DIR set by the caller wins.
[[ -z $DEVELOPER_DIR && -d /Applications/Xcode-27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer
ACTION=${1:-build}; SIM=${2:-${HQ_SIM:-00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A}}
# HQ_IDENTITY=original builds the Hermes HQ record's app (project-original.yml); default: native.
[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
xcodegen generate -q
mkdir -p build
# Builds and test runs step behind everything else on this Mac (it also runs Hermes: on 2026-11-18 a test run here
# stalled the gateway for 25 minutes and both apps said they couldn't reach it). HQ_NICE=0 runs at full priority.
NICE=(nice -n ${HQ_NICE:-10}); [[ ${HQ_NICE:-10} == 0 ]] && NICE=()
$NICE xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd $ACTION -quiet > build/last-$ACTION.log 2>&1 && STATUS=0 || STATUS=$?
grep -v -E '^(note:|\s*$)|appintentsmetadataprocessor' build/last-$ACTION.log | tail -80
echo "xcodebuild $ACTION exit $STATUS"; exit $STATUS
