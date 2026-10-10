#!/usr/bin/env bash

set -euo pipefail

readonly staging_project_ref="nfdkdhdevpstfspazbfn"
readonly staging_supabase_url="https://${staging_project_ref}.supabase.co"
readonly bootstrap_phone="+97339009098"

required_variables=(
  E2E_BOOTSTRAP_PHONE
  E2E_DEV_OTP_CODE
  E2E_TEST_PASSWORD
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
if [[ "${#E2E_TEST_PASSWORD}" -lt 16 ]]; then
  echo "::error::E2E_TEST_PASSWORD must be at least 16 characters."
  exit 64
fi

readonly dev_users_json='{"+97339009098":"E2E Bootstrap Player","+97338883670":"Dev Player","+97338883671":"Ali Hassan","+97338883672":"Omar Saleh","+97338883673":"Noor Khalid","+97338883674":"Yousef Ahmed","+97338883675":"Sami Nasser","+97338883676":"Salman Abbas","+97338883677":"Rami Darwish","+97338883678":"Hamad Mansour"}'

echo "Configuring the staging-only fixed-code login for this E2E run."
supabase secrets set \
  --project-ref "$SUPABASE_PROJECT_REF" \
  DEV=true \
  DEV_OTP_ENABLED=true \
  DEV_OTP_CODE="$E2E_DEV_OTP_CODE" \
  DEV_OTP_PASSWORD="$E2E_TEST_PASSWORD" \
  DEV_OTP_USERS_JSON="$dev_users_json" \
  DEV_SWITCH_PASSWORD="$E2E_TEST_PASSWORD" \
  DEV_SWITCH_ALLOW_UNAUTHENTICATED=false

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

for attempt in {1..12}; do
  status="$(
    curl \
      --silent \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST \
      --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
      --header "authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
      --header "content-type: application/json" \
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
