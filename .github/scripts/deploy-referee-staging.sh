#!/usr/bin/env bash

set -euo pipefail

if [[ "${GITHUB_REF:-}" != "refs/heads/staging" ]]; then
  echo "::error::The referee staging PWA may only deploy from refs/heads/staging."
  exit 1
fi

for variable in VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID; do
  if [[ -z "${!variable:-}" ]]; then
    echo "::error::The staging GitHub environment is missing ${variable}."
    exit 1
  fi
done

deployment_output="$({
  cd referee
  npx --yes vercel@56.5.0 deploy \
    --prod \
    --yes \
    --token "$VERCEL_TOKEN" 2>&1
})"
printf '%s\n' "$deployment_output"
deployment_url="$(
  printf '%s\n' "$deployment_output" \
    | grep -Eo 'https://[^[:space:]"[:cntrl:]]+\.vercel\.app' \
    | tail -n 1 \
    || true
)"

if [[ -z "$deployment_url" ]]; then
  echo "::error::Vercel did not return a deployment URL."
  exit 1
fi

echo "Deployed Field Ops Staging to ${deployment_url}"

wait_for_url() {
  local url="$1"
  local attempt

  for attempt in {1..30}; do
    if curl \
      --fail \
      --location \
      --silent \
      --show-error \
      --connect-timeout 10 \
      --max-time 30 \
      "$url" >/dev/null; then
      return 0
    fi
    sleep 5
  done

  echo "::error::${url} did not become healthy after deployment."
  return 1
}

wait_for_url "$deployment_url"

manifest="$(curl --fail --location --silent --show-error \
  --connect-timeout 10 --max-time 30 \
  "${deployment_url}/manifest.webmanifest")"

jq -e '
  .name == "Field Ops Staging" and
  .short_name == "Field STG" and
  .display == "standalone" and
  .scope == "/" and
  ([.icons[].sizes] | index("192x192") != null) and
  ([.icons[].sizes] | index("512x512") != null)
' <<<"$manifest" >/dev/null

service_worker_headers="$(curl --fail --silent --show-error \
  --head --connect-timeout 10 --max-time 30 \
  "${deployment_url}/sw.js")"

grep -Eiq '^content-type: application/javascript' <<<"$service_worker_headers"
grep -Eiq '^cache-control: .*no-store' <<<"$service_worker_headers"
grep -Eiq '^x-robots-tag: .*noindex' <<<"$service_worker_headers"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "deployment_url=${deployment_url}" >>"$GITHUB_OUTPUT"
fi
