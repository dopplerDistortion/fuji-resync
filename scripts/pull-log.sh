#!/bin/bash
# Copy Documents/resync.log off the iPhone, over the cable or over Wi-Fi.
# Usage: scripts/pull-log.sh [destination]. Set RESYNC_DEVICE to pick a phone.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/device.sh

bundle_id="${RESYNC_BUNDLE_ID:-ing.goksen.resync}"
destination="${1:-.build/logs/resync.log}"

mkdir -p "$(dirname "$destination")"
xcrun devicectl device copy from --device "$RESYNC_DEVICE" \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --source Documents/resync.log --destination "$destination"
