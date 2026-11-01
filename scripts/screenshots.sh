#!/bin/bash
# App Store screenshots from the simulator, with a clean status bar.
# Writes PNGs to build/screenshots/<device>/. Set RESYNC_SIM to pick other simulators.
# App Store Connect needs the 6.9" size (1320 × 2868); iPhone 18 Pro Max gives it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

sims=("${RESYNC_SIM:-iPhone 18 Pro Max}")
xcodegen generate

for sim in "${sims[@]}"; do
    out="build/screenshots/${sim// /-}"
    bundle="build/screenshots/${sim// /-}.xcresult"
    rm -rf "$out" "$bundle"
    mkdir -p "$out"
    xcrun simctl boot "$sim" 2>/dev/null || true
    xcrun simctl bootstatus "$sim" -b >/dev/null
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    TEST_RUNNER_RESYNC_SHOTS=1 xcodebuild -project Resync.xcodeproj -scheme Resync \
        -destination "platform=iOS Simulator,name=$sim" \
        -only-testing:ResyncUITests/AppStoreScreenshots \
        -resultBundlePath "$bundle" -quiet test
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$out"
    # Name the files after their attachments.
    python3 - "$out" <<'PY'
import json, os, sys
out = sys.argv[1]
for entry in json.load(open(os.path.join(out, "manifest.json"))):
    for a in entry.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        if name.startswith("appstore-"):
            os.replace(os.path.join(out, a["exportedFileName"]),
                       os.path.join(out, name.split("_")[0].removesuffix(".png") + ".png"))
PY
    xcrun simctl status_bar "$sim" clear
    echo "screenshots: $out"
done
