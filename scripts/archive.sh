#!/bin/bash
# Archive a Release build and upload it to App Store Connect (it shows up in TestFlight).
# Needs Config/Local.xcconfig with DEVELOPMENT_TEAM, the Hotspot entitlements and a Mapbox token,
# an Xcode account signed in to that team, and the app's record in App Store Connect.
# The build number is the time, so every upload is new. ARCHIVE_ONLY=1 skips the upload.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

local_cfg=Config/Local.xcconfig
[ -f "$local_cfg" ] || { echo "missing $local_cfg (copy Config/Local.xcconfig.example)" >&2; exit 1; }
grep -qE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' "$local_cfg" || { echo "set DEVELOPMENT_TEAM in $local_cfg" >&2; exit 1; }
grep -qE '^RESYNC_ENTITLEMENTS *= *App/Support/Resync-Hotspot.entitlements' "$local_cfg" \
    || echo "warning: the build won't join the camera's Wi-Fi by itself (RESYNC_ENTITLEMENTS isn't set)" >&2
grep -qE '^MAPBOX_ACCESS_TOKEN *= *pk\.' "$local_cfg" \
    || echo "warning: no Mapbox token, the build will use Apple's map" >&2

build="${RESYNC_BUILD:-$(date -u +%Y%m%d%H%M)}"
archive="build/Resync-$build.xcarchive"

xcodegen generate
xcodebuild -project Resync.xcodeproj -scheme Resync -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" -quiet archive
echo "archived: $archive (build $build)"

[ "${ARCHIVE_ONLY:-0}" = 1 ] && exit 0
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist Config/ExportOptions.plist \
    -exportPath "build/export-$build" -allowProvisioningUpdates
echo "uploaded build $build. It appears in App Store Connect → TestFlight after processing."
