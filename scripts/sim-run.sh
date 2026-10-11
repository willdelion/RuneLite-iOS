#!/bin/bash
# Build for iOS Simulator, ad-hoc sign, install and auto-launch RuneLite on the booted simulator.
set -e
cd "$(dirname "$0")/.."
J=$HOME/.local/jdk/zulu8.96.0.205-ca-jdk8.0.504-macosx_aarch64/Contents/Home/bin
rm -rf JavaApp/build && make java JOBS=1 BOOTJDK=$J > ../build-java.log 2>&1 && make payload PLATFORM=7 BOOTJDK=$J > ../build-payload.log 2>&1 || { grep -E " error:|Error" ../build-payload.log | head -20; exit 1; }
APP=artifacts/Payload/AngelAuraAmethyst.app
find "$APP" -type f | while read -r f; do
  if file "$f" | grep -q Mach-O; then codesign -f -s - "$f" >/dev/null 2>&1 || true; fi
done
codesign -f -s - "$APP" >/dev/null 2>&1
xcrun simctl install booted "$APP"
SIMCTL_CHILD_RUNELITE_DEBUG_INPUT=1 SIMCTL_CHILD_JIT_FLAGS=0 SIMCTL_CHILD_AUTO_RUNELITE=1 xcrun simctl launch --terminate-running-process booted org.angelauramc.amethyst
