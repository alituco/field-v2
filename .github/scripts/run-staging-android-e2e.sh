#!/usr/bin/env bash

set -uo pipefail

mode="${1:-run}"
player_journey_target="integration_test/staging_player_journey_test.dart"

# Android integration tests run beside an emulator on a 16 GB GitHub runner.
# Keep compilation in one short-lived Gradle process instead of leaving large
# Gradle and Kotlin daemons resident while the app journey is running.
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false"

required_variables=(
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

if [[ "$mode" == "run" ]]; then
  required_variables+=(ANDROID_SERIAL)
elif [[ "$mode" != "build-only" ]]; then
  echo "::error::Usage: $0 [build-only|run]"
  exit 2
fi

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "::error::$variable_name is required for the staging Android E2E run."
    exit 1
  fi
done

artifact_dir="$GITHUB_WORKSPACE/mobile/build/e2e-artifacts"
mkdir -p "$artifact_dir"

run_bounded_adb() {
  local duration="$1"
  shift

  timeout \
    --signal=TERM \
    --kill-after=5s \
    "$duration" \
    adb -s "$ANDROID_SERIAL" "$@"
}

wait_for_android_online() {
  local label="$1"
  local deadline=$((SECONDS + 60))
  local state

  adb start-server >/dev/null 2>&1 || true
  while ((SECONDS < deadline)); do
    state="$(
      run_bounded_adb 5s get-state 2>/dev/null \
        | tr -d '\r' \
        || true
    )"
    if [[ "$state" == "device" ]]; then
      return 0
    fi

    if [[ "$state" == "offline" ]]; then
      adb reconnect offline >/dev/null 2>&1 || true
    fi
    sleep 2
  done

  echo "::error::The Android emulator was not online before $label."
  return 1
}

common_flutter_configuration_args=(
  --flavor staging
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

if [[ "$mode" == "build-only" ]]; then
  echo "::notice::Prebuilding $player_journey_target before starting the Android emulator."
  cd "$GITHUB_WORKSPACE/mobile" || exit 1
  flutter build apk \
    --debug \
    --target "$player_journey_target" \
    "${common_flutter_configuration_args[@]}"
  exit $?
fi

common_flutter_args=(
  -d "$ANDROID_SERIAL"
  --reporter expanded
  "${common_flutter_configuration_args[@]}"
)

capture_android_diagnostics() {
  local label="$1"
  local package_name="com.field.field.staging"

  echo "::group::Android diagnostics for $label"
  timeout 10s adb devices -l \
    >"$artifact_dir/$label-adb-devices.txt" 2>&1 || true
  run_bounded_adb 10s shell getprop \
    >"$artifact_dir/$label-getprop.txt" 2>&1 || true
  run_bounded_adb 10s shell dumpsys activity activities \
    >"$artifact_dir/$label-activities.txt" 2>&1 || true
  run_bounded_adb 10s shell dumpsys package "$package_name" \
    >"$artifact_dir/$label-package.txt" 2>&1 || true
  run_bounded_adb 10s shell pidof "$package_name" \
    >"$artifact_dir/$label-pid.txt" 2>&1 || true
  run_bounded_adb 15s logcat -d -v threadtime -t 4000 \
    >"$artifact_dir/$label-logcat.txt" 2>&1 || true
  run_bounded_adb 10s exec-out screencap -p \
    >"$artifact_dir/$label-screen.png" 2>/dev/null || true
  free -h >"$artifact_dir/$label-host-memory.txt" 2>&1 || true
  df -h >"$artifact_dir/$label-host-disk.txt" 2>&1 || true
  ps -eo pid,ppid,%cpu,%mem,rss,stat,comm,args \
    >"$artifact_dir/$label-host-processes.txt" 2>&1 || true
  if [[ -d /sys/fs/cgroup ]]; then
    {
      for cgroup_file in \
        /sys/fs/cgroup/memory.current \
        /sys/fs/cgroup/memory.max \
        /sys/fs/cgroup/memory.events \
        /sys/fs/cgroup/memory.events.local \
        /sys/fs/cgroup/memory.stat; do
        if [[ -r "$cgroup_file" ]]; then
          echo "### $cgroup_file"
          cat "$cgroup_file"
        fi
      done
    } >"$artifact_dir/$label-host-cgroup-memory.txt" 2>&1 || true
  fi
  timeout 10s sudo dmesg --ctime \
    >"$artifact_dir/$label-host-kernel.txt" 2>&1 || true
  for crash_path in /tmp/android-runner/emu-crash-*.db; do
    if [[ -d "$crash_path" ]]; then
      tar -czf \
        "$artifact_dir/$label-$(basename "$crash_path").tar.gz" \
        -C "$(dirname "$crash_path")" \
        "$(basename "$crash_path")" || true
    elif [[ -f "$crash_path" ]]; then
      cp "$crash_path" "$artifact_dir/$label-$(basename "$crash_path")" || true
    fi
  done
  echo "::endgroup::"
}

run_flutter_integration_test() {
  local label="$1"
  local watchdog="$2"
  local target="$3"
  local package_name="com.field.field.staging"
  local test_status

  if ! wait_for_android_online "$target"; then
    capture_android_diagnostics "$label"
    return 79
  fi
  run_bounded_adb 20s uninstall "$package_name" >/dev/null 2>&1 || true
  run_bounded_adb 10s logcat -c || true
  echo "::notice::Running $target with a $watchdog host watchdog."

  (
    cd "$GITHUB_WORKSPACE/mobile" || exit 1
    timeout \
      --signal=INT \
      --kill-after=30s \
      "$watchdog" \
      flutter test "$target" "${common_flutter_args[@]}"
  ) 2>&1 | tee "$artifact_dir/$label-flutter-integration.log"
  test_status="${PIPESTATUS[0]}"

  if [[ "$test_status" -eq 124 || "$test_status" -eq 137 ]]; then
    echo "::error::$target stopped responding and exceeded its $watchdog watchdog."
  elif [[ "$test_status" -ne 0 ]]; then
    echo "::error::$target failed with exit code $test_status."
  fi

  if [[ "$test_status" -ne 0 ]]; then
    wait_for_android_online "$target diagnostics" || true
    capture_android_diagnostics "$label"
  fi

  return "$test_status"
}

run_flutter_integration_test \
  "player-journey" \
  "12m" \
  "$player_journey_target"
journey_status="$?"
if [[ "$journey_status" -ne 0 ]]; then
  exit "$journey_status"
fi
