#!/usr/bin/env bash

set -euo pipefail

readonly staging_project_ref="nfdkdhdevpstfspazbfn"
readonly staging_supabase_url="https://${staging_project_ref}.supabase.co"
readonly bootstrap_phone="+97339009098"

required_variables=(
  E2E_BOOTSTRAP_PHONE
  E2E_DEV_OTP_CODE
  E2E_TEST_PASSWORD
  E2E_RUN_ID
  FIELD_ENVIRONMENT
  SUPABASE_ACCESS_TOKEN
  SUPABASE_PROJECT_REF
  SUPABASE_PUBLISHABLE_KEY
  SUPABASE_URL
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "::error::$variable_name is required to configure staging E2E auth."
    exit 64
  fi
done

if [[ "$FIELD_ENVIRONMENT" != "staging" ]]; then
  echo "::error::Staging E2E auth can only be configured for staging."
  exit 64
fi
if [[ "$SUPABASE_PROJECT_REF" != "$staging_project_ref" ]]; then
  echo "::error::Refusing to configure E2E auth outside Field Staging."
  exit 64
fi
if [[ "$SUPABASE_URL" != "$staging_supabase_url" ]]; then
  echo "::error::SUPABASE_URL is not the exact Field Staging URL."
  exit 64
fi
if [[ "$E2E_BOOTSTRAP_PHONE" != "$bootstrap_phone" ]]; then
  echo "::error::The E2E bootstrap phone is not the approved staging account."
  exit 64
fi
if [[ ! "$E2E_DEV_OTP_CODE" =~ ^[0-9]{6}$ ]]; then
  echo "::error::E2E_DEV_OTP_CODE must contain exactly six digits."
  exit 64
fi
if [[ ${#E2E_TEST_PASSWORD} -lt 32 || ${#E2E_TEST_PASSWORD} -gt 256 ||
  ! "$E2E_TEST_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ||
  ! "$E2E_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "::error::E2E auth requires a strong per-run capability and a valid run ID."
  exit 64
fi

umask 077
secrets_file="$(mktemp)"
headers_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$secrets_file" "$headers_file" "$response_file"' EXIT
valid_until="$(node -e 'process.stdout.write(new Date(Date.now()+90*60*1000).toISOString())')"
printf 'DEV=true\nDEV_OTP_ENABLED=true\nDEV_OTP_CODE=%s\nDEV_OTP_PASSWORD=%s\nDEV_AUTH_SECRET=%s\nDEV_AUTH_RUN_ID=%s\nDEV_AUTH_VALID_UNTIL=%s\nDEV_OTP_VALID_UNTIL=%s\nDEV_SWITCH_VALID_UNTIL=%s\nDEV_SWITCH_ALLOW_UNAUTHENTICATED=false\n' \
  "$E2E_DEV_OTP_CODE" "$E2E_TEST_PASSWORD" "$E2E_TEST_PASSWORD" "$E2E_RUN_ID" \
  "$valid_until" "$valid_until" "$valid_until" >"$secrets_file"
printf 'apikey: %s\nauthorization: Bearer %s\ncontent-type: application/json\nx-fieldrush-e2e-secret: %s\n' \
  "$SUPABASE_PUBLISHABLE_KEY" "$SUPABASE_PUBLISHABLE_KEY" "$E2E_TEST_PASSWORD" >"$headers_file"
echo "Configuring a short-lived, capability-protected staging E2E window."
supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" --env-file "$secrets_file" >/dev/null
rm -f "$secrets_file"

for attempt in {1..12}; do
  status="$(
    curl \
      --silent \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST \
      --header "@$headers_file" \
      --data "$(
        jq -nc \
          --arg phone "$E2E_BOOTSTRAP_PHONE" \
          --arg token "$E2E_DEV_OTP_CODE" \
          '{phone: $phone, token: $token}'
      )" \
      "$SUPABASE_URL/functions/v1/dev-phone-login"
  )"

  if [[ "$status" == "200" ]] &&
    jq -e \
      '.access_token | type == "string" and length > 0' \
      "$response_file" >/dev/null &&
    jq -e \
      '.refresh_token | type == "string" and length > 0' \
      "$response_file" >/dev/null; then
    echo "Staging E2E fixed-code login is ready."
    exit 0
  fi

  if [[ "$attempt" -lt 12 ]]; then
    sleep 5
  fi
done

error_message="$(
  jq -r \
    'if .error | type == "string" then .error else "unknown response" end' \
    "$response_file" 2>/dev/null || echo "unknown response"
)"
echo "::error::Staging E2E login verification failed ($status): $error_message"
exit 1
