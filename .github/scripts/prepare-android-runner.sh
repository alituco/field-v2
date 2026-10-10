#!/usr/bin/env bash
set -euo pipefail

# This cleanup is only for disposable GitHub-hosted Linux runners. Never run
# it on a developer machine or a persistent self-hosted runner.
if [[ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" || "${RUNNER_OS:-}" != "Linux" ]]; then
  echo "::error::Android disk cleanup requires a GitHub-hosted Linux runner."
  exit 1
fi

df -h /

# Android builds do not use these preinstalled language/tool bundles. Keep
# the Android SDK, Java, Flutter, Node, Python, and Docker intact.
sudo rm -rf -- \
  /usr/share/dotnet \
  /usr/share/swift \
  /opt/ghc \
  /usr/local/.ghcup \
  /opt/hostedtoolcache/CodeQL \
  /usr/local/share/powershell

df -h /
available_kib="$(df --output=avail -k / | tail -n 1 | tr -d '[:space:]')"
minimum_kib=$((20 * 1024 * 1024))
if (( available_kib < minimum_kib )); then
  echo "::error::Android builds require at least 20 GiB free; only ${available_kib} KiB remain."
  exit 1
fi
