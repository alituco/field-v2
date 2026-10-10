#!/usr/bin/env bash
set -euo pipefail

# Run after the AVD has been created, immediately before emulator launch.
# These are fixed, unused bundles on disposable GitHub-hosted Linux runners.
# Never remove the Android SDK (including the selected system image), Java,
# Flutter, Node, Python, Docker, or the downloaded, prebuilt test APK.
readonly minimum_kib=$((10 * 1024 * 1024))
readonly -a unused_hosted_tools=(
  /usr/share/dotnet
  /usr/share/swift
  /opt/ghc
  /usr/local/.ghcup
  /opt/hostedtoolcache/CodeQL
  /usr/local/share/powershell
)

fail() {
  echo "::error::$*" >&2
  exit 1
}

dry_run=false
if [[ "$#" -gt 1 ]]; then
  fail "Usage: $0 [--dry-run]"
elif [[ "$#" -eq 1 ]]; then
  [[ "$1" == "--dry-run" ]] || fail "Usage: $0 [--dry-run]"
  dry_run=true
fi

# Test seams are accepted only in the unconditionally non-destructive mode.
# A test environment can never accidentally opt in to real cleanup.
if [[ "$dry_run" == false ]] && {
  [[ "${ANDROID_EMULATOR_GUARD_TEST_OS+x}" == x ]] ||
    [[ "${ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB+x}" == x ]]
}; then
  fail "Disk guard test overrides require --dry-run; no cleanup was performed."
fi

host_os="$(/usr/bin/uname -s)"
if [[ "$dry_run" == true && "${ANDROID_EMULATOR_GUARD_TEST_OS+x}" == x ]]; then
  host_os="$ANDROID_EMULATOR_GUARD_TEST_OS"
fi
if [[ "${GITHUB_ACTIONS:-}" != true ||
  "${RUNNER_ENVIRONMENT:-}" != github-hosted ||
  "${RUNNER_OS:-}" != Linux || "$host_os" != Linux ]]; then
  fail "Android emulator disk cleanup requires a GitHub-hosted Linux runner; no cleanup was performed."
fi

avd_directory="${ANDROID_AVD_HOME:-${HOME:?HOME is required}/.android/avd}"
mock_disk=false
if [[ "$dry_run" == true && "${ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB+x}" == x ]]; then
  mock_disk=true
fi

show_disk_usage() {
  if [[ "$mock_disk" == true ]]; then
    echo "::notice::Dry run: using mocked AVD filesystem availability."
  else
    df -h -- / "$avd_directory"
  fi
}

if [[ "$mock_disk" != true && ! -d "$avd_directory" ]]; then
  fail "The AVD directory does not exist: $avd_directory. Run this guard after AVD creation."
fi

echo "::group::Android emulator disk headroom"
show_disk_usage
if [[ "$dry_run" == true ]]; then
  echo "::notice::Dry run: no files will be removed. Fixed cleanup candidates:"
  printf '  %s\n' "${unused_hosted_tools[@]}"
else
  echo "::notice::Removing unused hosted language bundles before emulator launch."
  if ! sudo -n rm -rf -- "${unused_hosted_tools[@]}"; then
    show_disk_usage || true
    fail "Could not remove unused hosted tools; the Android emulator was not launched."
  fi
  show_disk_usage
fi

# Measure the filesystem backing the actual AVD, not just the root mount.
if [[ "$mock_disk" == true ]]; then
  available_kib="$ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB"
else
  available_kib="$(df --output=avail -k -- "$avd_directory" | tail -n 1 | tr -d '[:space:]')"
fi
if [[ ! "$available_kib" =~ ^[0-9]{1,15}$ ]]; then
  fail "Unable to determine free space on the AVD filesystem (expected a KiB count)."
fi
available_kib=$((10#$available_kib))
if (( available_kib < minimum_kib )); then
  fail "Android emulator startup requires at least 10 GiB free on the AVD filesystem after creation; only ${available_kib} KiB remain."
fi

# 10 GiB leaves margin above the API 34 ATD startup disk requirement, even
# after allocating the configured 2048 MiB userdata partition.
echo "::notice::Android emulator disk guard passed: ${available_kib} KiB available (minimum ${minimum_kib} KiB)."
echo "::endgroup::"
