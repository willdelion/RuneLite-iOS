#!/bin/bash
# Re-sign the device build with the free Apple ID profile and install it on the connected iPhone.
# Profiles from a personal team last 7 days; rerun this to refresh.
set -e
cd "$(dirname "$0")/.."
DEVICE=${DEVICE:-00008150-000E69801EC1401C}
BUNDLE_ID=${BUNDLE_ID:-com.willdel.sideload.runelite}
IDENTITY=${IDENTITY:-"Apple Development: flyarkovskyav@gmail.com (FASRW287V3)"}
PROVISION=~/Developer/RuneLiteIOS-provision

# Refresh the profile through the stub project (Xcode handles the Apple ID side)
xcodebuild -project $PROVISION/Stub.xcodeproj -scheme Stub -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build -quiet
PROF=$(ls -t ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision | while read -r p; do
  grep -q "$BUNDLE_ID" "$p" && { echo "$p"; break; }
done)

W=$PROVISION/sign; rm -rf $W; mkdir -p $W
cp -R artifacts/Payload/AngelAuraAmethyst.app $W/
APP=$W/AngelAuraAmethyst.app
cp "$PROF" $APP/embedded.mobileprovision
plutil -replace CFBundleIdentifier -string $BUNDLE_ID $APP/Info.plist
security cms -D -i "$PROF" > $W/prof.plist
plutil -extract Entitlements xml1 -o $W/ent.plist $W/prof.plist

find "$APP" -type f | while read -r f; do
  if [ "$f" != "$APP/AngelAuraAmethyst" ] && file "$f" | grep -q Mach-O; then
    codesign -f -s "$IDENTITY" --timestamp=none "$f" >/dev/null 2>&1 || true
  fi
done
for fw in "$APP"/Frameworks/*.framework; do xattr -cr "$fw"; codesign -f -s "$IDENTITY" --timestamp=none "$fw"; done
xattr -cr "$APP"
codesign -f -s "$IDENTITY" --timestamp=none --entitlements $W/ent.plist "$APP"
codesign --verify --deep --strict "$APP"
xcrun devicectl device install app --device $DEVICE "$APP"
