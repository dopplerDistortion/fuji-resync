# Sourced by deploy.sh and pull-log.sh. Sets RESYNC_DEVICE to $RESYNC_DEVICE or the first paired iPhone.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ -z "${RESYNC_DEVICE:-}" ]; then
    json="$(mktemp)"
    trap 'rm -f "$json"' EXIT
    xcrun devicectl list devices --json-output "$json" >/dev/null
    RESYNC_DEVICE="$(python3 - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("deviceType") == "iPhone" and conn.get("pairingState") == "paired":
        print(hw["udid"])
        break
PY
)"
fi

if [ -z "$RESYNC_DEVICE" ]; then
    echo "no paired iPhone found. set RESYNC_DEVICE to its UDID." >&2
    exit 1
fi
