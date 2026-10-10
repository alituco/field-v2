#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_SERIAL:?ANDROID_SERIAL is required for the Android boot preflight}"

if [[ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" != 1 ]]; then
  echo "::error::Android did not report a completed boot."
  exit 1
fi

for attempt in {1..12}; do
  if [[ "$(adb -s "$ANDROID_SERIAL" get-state | tr -d '\r')" != device ]]; then
    echo "::error::Android went offline during boot preflight (check $attempt)."
    exit 79
  fi
  adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_HOME
  sleep 5
done

df -h /
echo "Android booted and remained online for the runtime check."
