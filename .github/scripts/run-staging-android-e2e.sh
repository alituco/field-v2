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

set +e
(
  cd "$GITHUB_WORKSPACE/mobile" || exit 1
  flutter test integration_test/staging_player_journey_test.dart \
    --flavor staging \
    -d "$ANDROID_SERIAL" \
    --dart-define=APP_ENV=staging \
    --dart-define=SUPABASE_URL="$SUPABASE_URL" \
    --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
    --dart-define=DEV=true \
    --dart-define=E2E_MAIN_PHONE="$E2E_MAIN_PHONE" \
    --dart-define=E2E_PARTY_TARGET_PHONE="$E2E_PARTY_TARGET_PHONE" \
    --dart-define=E2E_PARTY_TARGET_PROFILE_ID="$E2E_PARTY_TARGET_PROFILE_ID" \
    --dart-define=E2E_ADMIN_PHONE="$E2E_ADMIN_PHONE" \
    --dart-define=E2E_ONBOARDING_PHONE="$E2E_ONBOARDING_PHONE" \
    --dart-define=E2E_TEST_PASSWORD="$E2E_TEST_PASSWORD" \
    --dart-define=E2E_RUN_ID="$E2E_RUN_ID" \
    --dart-define=E2E_MATCH_GAME_ID="$E2E_MATCH_GAME_ID" \
    --dart-define=E2E_CANCELLATION_GAME_ID="$E2E_CANCELLATION_GAME_ID" \
    --dart-define=E2E_REPORT_DETAILS="$E2E_REPORT_DETAILS" \
    --dart-define=E2E_SUPPORT_DETAILS="$E2E_SUPPORT_DETAILS" \
    --dart-define=E2E_BOOTSTRAP_PHONE="$E2E_BOOTSTRAP_PHONE" \
    --dart-define=E2E_DEV_OTP_CODE="$E2E_DEV_OTP_CODE"
) 2>&1 | tee "$artifact_dir/flutter-integration.log"
test_status="${PIPESTATUS[0]}"
set -e

if [[ "$test_status" -ne 0 ]]; then
  adb exec-out screencap -p >"$artifact_dir/failure.png" || true
  adb logcat -d -v time flutter:I '*:S' >"$artifact_dir/logcat.txt" || true
fi

exit "$test_status"
