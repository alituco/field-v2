#!/usr/bin/env bash

set -uo pipefail

required_variables=(
  ANDROID_SERIAL
  E2E_ADMIN_PHONE
  E2E_BOOTSTRAP_PHONE
  E2E_CANCELLATION_GAME_ID
  E2E_DEV_OTP_CODE
  E2E_MAIN_PHONE
  E2E_MATCH_GAME_ID
  E2E_ONBOARDING_PHONE
  E2E_PARTY_TARGET_PHONE
  E2E_PARTY_TARGET_PROFILE_ID
  E2E_REPORT_DETAILS
  E2E_RUN_ID
  E2E_SUPPORT_DETAILS
  E2E_TEST_PASSWORD
  GITHUB_WORKSPACE
  SUPABASE_PUBLISHABLE_KEY
  SUPABASE_URL
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "::error::$variable_name is required for the staging Android E2E run."
    exit 1
  fi
done

artifact_dir="$GITHUB_WORKSPACE/mobile/build/e2e-artifacts"
mkdir -p "$artifact_dir"

common_flutter_args=(
  --flavor staging
  -d "$ANDROID_SERIAL"
  --reporter expanded
  --dart-define=APP_ENV=staging
  --dart-define=SUPABASE_URL="$SUPABASE_URL"
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY"
  --dart-define=DEV=true
  --dart-define=E2E_MAIN_PHONE="$E2E_MAIN_PHONE"
  --dart-define=E2E_PARTY_TARGET_PHONE="$E2E_PARTY_TARGET_PHONE"
  --dart-define=E2E_PARTY_TARGET_PROFILE_ID="$E2E_PARTY_TARGET_PROFILE_ID"
  --dart-define=E2E_ADMIN_PHONE="$E2E_ADMIN_PHONE"
  --dart-define=E2E_ONBOARDING_PHONE="$E2E_ONBOARDING_PHONE"
  --dart-define=E2E_TEST_PASSWORD="$E2E_TEST_PASSWORD"
  --dart-define=E2E_RUN_ID="$E2E_RUN_ID"
  --dart-define=E2E_MATCH_GAME_ID="$E2E_MATCH_GAME_ID"
  --dart-define=E2E_CANCELLATION_GAME_ID="$E2E_CANCELLATION_GAME_ID"
  --dart-define=E2E_REPORT_DETAILS="$E2E_REPORT_DETAILS"
  --dart-define=E2E_SUPPORT_DETAILS="$E2E_SUPPORT_DETAILS"
  --dart-define=E2E_BOOTSTRAP_PHONE="$E2E_BOOTSTRAP_PHONE"
  --dart-define=E2E_DEV_OTP_CODE="$E2E_DEV_OTP_CODE"
)

capture_android_diagnostics() {
  local label="$1"
  local package_name="com.field.field.staging"

  echo "::group::Android diagnostics for $label"
  adb devices -l >"$artifact_dir/$label-adb-devices.txt" 2>&1 || true
  adb shell getprop >"$artifact_dir/$label-getprop.txt" 2>&1 || true
  adb shell dumpsys activity activities \
    >"$artifact_dir/$label-activities.txt" 2>&1 || true
  adb shell dumpsys package "$package_name" \
    >"$artifact_dir/$label-package.txt" 2>&1 || true
  adb shell pidof "$package_name" \
    >"$artifact_dir/$label-pid.txt" 2>&1 || true
  adb logcat -d -v threadtime -t 4000 \
    >"$artifact_dir/$label-logcat.txt" 2>&1 || true
  adb exec-out screencap -p \
    >"$artifact_dir/$label-screen.png" 2>/dev/null || true
  echo "::endgroup::"
}

run_flutter_integration_test() {
  local label="$1"
  local watchdog="$2"
  local target="$3"
  local package_name="com.field.field.staging"

  adb wait-for-device
  adb uninstall "$package_name" >/dev/null 2>&1 || true
  adb logcat -c || true
  echo "::notice::Running $target with a $watchdog host watchdog."

  (
    cd "$GITHUB_WORKSPACE/mobile" || exit 1
    timeout \
      --signal=INT \
      --kill-after=30s \
      "$watchdog" \
      flutter test "$target" "${common_flutter_args[@]}"
  ) 2>&1 | tee "$artifact_dir/$label-flutter-integration.log"
  local test_status
  test_status="${PIPESTATUS[0]}"

  if [[ "$test_status" -eq 124 || "$test_status" -eq 137 ]]; then
    echo "::error::$target stopped responding and exceeded its $watchdog watchdog."
  elif [[ "$test_status" -ne 0 ]]; then
    echo "::error::$target failed with exit code $test_status."
  fi

  if [[ "$test_status" -ne 0 ]]; then
    capture_android_diagnostics "$label"
  fi

  return "$test_status"
}

run_flutter_integration_test \
  "boot" \
  "12m" \
  "integration_test/staging_boot_test.dart"
boot_status="$?"
if [[ "$boot_status" -ne 0 ]]; then
  exit "$boot_status"
fi

run_flutter_integration_test \
  "player-journey" \
  "20m" \
  "integration_test/staging_player_journey_test.dart"
journey_status="$?"
if [[ "$journey_status" -ne 0 ]]; then
  exit "$journey_status"
fi
