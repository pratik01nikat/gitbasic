#!/bin/bash
# Installs a simulator build of Folio on an iPad simulator and captures
# screenshots of the main screens using the debug-only -FolioScreenshot mode.
# Usage: screenshots.sh <path to Folio.app> <output folder>
set -euo pipefail

APP_PATH="$1"
OUT="$2"
BUNDLE_ID="com.example.folio"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ipads = [d for runtime, ds in sorted(devices.items(), reverse=True) if "iOS" in runtime
         for d in ds if d["name"].startswith("iPad")]
for prefix in ["iPad Pro 11", "iPad Air 11", "iPad Pro 13", "iPad Air 13", "iPad"]:
    for d in ipads:
        if d["name"].startswith(prefix):
            print(d["udid"]); print(d["name"], file=sys.stderr); sys.exit(0)
sys.exit("No iPad simulator available")
')
echo "Simulator: $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP_PATH"
# The Simulator app must be open for the rotate shortcut to reach the device.
open -a Simulator --args -CurrentDeviceUDID "$UDID"
sleep 8

rotate() {
  # Simulator: Device > Rotate Left / Right (Cmd + arrow).
  local key="$1"
  osascript -e 'tell application "Simulator" to activate' \
            -e "tell application \"System Events\" to key code $key using command down" || echo "rotate failed"
  sleep 3
}

shoot() {
  local name="$1" scene="$2" orientation="$3"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -FolioScreenshot "$scene" -FolioOrientation "$orientation" >/dev/null
  sleep 12
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  # simctl captures the portrait framebuffer; turn landscape shots upright.
  if [ "$orientation" = landscape ]; then sips -r 90 "$OUT/$name.png" >/dev/null; fi
  echo "Captured $name ($(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/ {print $2}' | paste -sd x -))"
}

shoot 1-library library portrait
shoot 2-reader-pin-tool reader portrait
shoot 3-pins-sidebar pins portrait
shoot 4-book-and-whiteboard split portrait
shoot 5-whiteboard board portrait
shoot 9-ink-calibration calibration portrait

rotate 124  # right arrow: landscape
shoot 6-reader-landscape reader landscape
shoot 7-pins-sidebar-landscape pins landscape
shoot 8-book-and-whiteboard-landscape split landscape
