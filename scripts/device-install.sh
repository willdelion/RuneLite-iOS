#!/bin/bash
# Developer helper: re-sign the device build with a free Apple ID profile and install it on a connected iPhone.
# Profiles from a personal team last 7 days; rerun this to refresh. Most players should use SideStore/AltStore instead.
#   DEVICE     device UDID (xcrun devicectl list devices)
#   BUNDLE_ID  bundle id registered to your team, e.g. com.yourname.runelite
#   IDENTITY   signing identity (security find-identity -v -p codesigning)
#   PROVISION  folder with an Xcode stub project (Stub.xcodeproj) that uses BUNDLE_ID and your team
set -e
cd "$(dirname "$0")/.."
: "${DEVICE:?set DEVICE to your iPhone UDID}"
: "${BUNDLE_ID:?set BUNDLE_ID to a bundle id registered to your team}"
: "${IDENTITY:?set IDENTITY to your Apple Development signing identity}"
PROVISION=${PROVISION:-~/Developer/RuneLiteIOS-provision}

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
