#!/bin/bash
# Build, install and launch on an iPhone, over the cable or over Wi-Fi.
# Needs Config/Local.xcconfig. Set RESYNC_DEVICE to pick a phone.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/device.sh

bundle_id="${RESYNC_BUNDLE_ID:-ing.goksen.resync}"
derived=.build/device

xcodegen generate
xcodebuild -project Resync.xcodeproj -scheme Resync \
    -destination "id=$RESYNC_DEVICE" -derivedDataPath "$derived" \
    -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$RESYNC_DEVICE" "$derived/Build/Products/Debug-iphoneos/Resync.app"
xcrun devicectl device process launch --device "$RESYNC_DEVICE" "$bundle_id"
