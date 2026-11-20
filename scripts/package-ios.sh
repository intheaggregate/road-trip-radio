#!/usr/bin/env bash
set -euo pipefail
out="$1"
mkdir -p "$out/Payload"
xcodebuild -project RoadTripRadio.xcodeproj -scheme RoadTripRadio -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$out/device" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app="$out/device/Build/Products/Release-iphoneos/RoadTripRadio.app"
xcrun lipo -verify_arch arm64 "$app/RoadTripRadio"
/usr/bin/plutil -lint "$app/Info.plist"
ditto "$app" "$out/Payload/RoadTripRadio.app"
(cd "$out" && /usr/bin/ditto -c -k --keepParent Payload RoadTripRadio.ipa)
unzip -tq "$out/RoadTripRadio.ipa"
