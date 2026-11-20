#!/usr/bin/env bash
set -euo pipefail
out="$1"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
device="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
limit = tuple(map(int, sys.argv[1].split(".")))
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    if not match:
        continue
    version = tuple(map(int,match[1].split("-")))
    if (17,) <= version <= limit:
        candidates.extend((version, d["name"] == "iPhone 16 Pro", d["udid"]) for d in devices if "iPhone" in d["name"])
if not candidates:
    sys.exit("No compatible iPhone simulator for selected Xcode SDK " + sys.argv[1])
print(max(candidates)[2])' "$sdk")"
xcrun simctl boot "$device" || xcrun simctl bootstatus "$device" -b
xcodebuild -project RoadTripRadio.xcodeproj -scheme RoadTripRadio -configuration Debug \
  -sdk iphonesimulator -destination "id=$device" -derivedDataPath "$out/sim" build
xcrun simctl bootstatus "$device" -b
sim_app="$out/sim/Build/Products/Debug-iphonesimulator/RoadTripRadio.app"
# Exercise a filled-in station using the same resource that the personal kit supplies.
cat > "$sim_app/InterstateProgram.json" <<'JSON'
{"version":1,"name":"Demo drive","cues":[{"id":"demo","trigger":"departure","label":"Starting point","reason":"A departure song.","tracks":[{"title":"Test song","artist":"Test musician"}],"path":[{"latitude":10,"longitude":10}],"radius":4000}]}
JSON
codesign --force --sign - "$sim_app"
xcrun simctl install "$device" "$sim_app"
xcrun swiftc scripts/VerifyScreen.swift -o "$out/check-screen"
xcrun simctl launch "$device" app.roadtripradio.personal
for attempt in 1 2 3 4 5; do
  sleep 4
  xcrun simctl io "$device" screenshot "$out/Drive.png"
  if "$out/check-screen" "$out/Drive.png"; then
    xcodebuild -project RoadTripRadio.xcodeproj -scheme RoadTripRadio -configuration Debug \
      -destination "id=$device" -derivedDataPath "$out/sim" -parallel-testing-enabled NO \
      -only-testing:RoadTripRadioUITests test
    exit 0
  fi
done
echo "The iPhone did not display the Drive screen." >&2
exit 1
