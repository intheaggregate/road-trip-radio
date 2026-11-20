#!/usr/bin/env bash
set -euo pipefail
out="$1"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for k,ds in reversed(list(json.load(sys.stdin)["devices"].items())) if "iOS" in k for d in ds if "iPhone" in d["name"]))')"
xcrun simctl boot "$device" || xcrun simctl bootstatus "$device" -b
xcodebuild -project RoadTripRadio.xcodeproj -scheme RoadTripRadio -configuration Debug \
  -sdk iphonesimulator -destination "id=$device" -derivedDataPath "$out/sim" build
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$out/sim/Build/Products/Debug-iphonesimulator/RoadTripRadio.app"
xcrun simctl launch "$device" app.roadtripradio.personal
sleep 4
xcrun simctl io "$device" screenshot "$out/Drive.png"
test -s "$out/Drive.png"
