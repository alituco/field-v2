#!/usr/bin/env bash

set -euo pipefail

target="${1:-}"
project_ref="${2:-}"
readonly staging_project_ref="nfdkdhdevpstfspazbfn"
readonly production_project_ref="zjsjuuhborxrlmdcpvlj"

if [[ "$target" != "staging" && "$target" != "production" ]]; then
  echo "Usage: $0 <staging|production> <supabase-project-ref>" >&2
  exit 64
fi

if [[ ! "$project_ref" =~ ^[a-z0-9]{20}$ ]]; then
  echo "Supabase project ref must be exactly 20 lowercase letters or digits." >&2
  exit 64
fi

if [[ "$target" == "staging" ]]; then
  expected_project_ref="$staging_project_ref"
else
  expected_project_ref="$production_project_ref"
fi
if [[ "$project_ref" != "$expected_project_ref" ]]; then
  echo "Refusing to deploy ${target}: this is not Field's exact ${target} project ref." >&2
  exit 64
fi

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" || -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "SUPABASE_ACCESS_TOKEN and SUPABASE_DB_PASSWORD are required." >&2
  exit 64
fi

# Production is a coordinated live payment cutover, never a schema-only deploy.
# Validate every credential and the live provider account/webhook BEFORE even
# removing a forbidden function or touching the database. The protected workflow
# additionally requires the tested staging tree and a verified backup.
if [[ "$target" == production ]]; then
  stripe_reconcile_secret="${STRIPE_RECONCILE_SECRET:-}"
  if [[ "${PRODUCTION_STRIPE_LIVE_ROLLOUT:-}" != LIVE_STRIPE_READY ||
    ! "${STRIPE_SECRET_KEY:-}" =~ ^(sk|rk)_live_[A-Za-z0-9_]+$ ||
    ! "${STRIPE_PUBLISHABLE_KEY:-}" =~ ^pk_live_[A-Za-z0-9_]+$ ||
    ! "${STRIPE_WEBHOOK_SECRET:-}" =~ ^whsec_[A-Za-z0-9_]+$ ||
    ! "${STRIPE_WEBHOOK_ENDPOINT_ID:-}" =~ ^we_[A-Za-z0-9]+$ ||
    ! "${STRIPE_ACCOUNT_ID:-}" =~ ^acct_[A-Za-z0-9]+$ ||
    ! "$stripe_reconcile_secret" =~ ^[A-Za-z0-9_-]+$ ||
    ${#stripe_reconcile_secret} -lt 32 || ${#stripe_reconcile_secret} -gt 512 ]]; then
    echo "Production live Stripe cutover requires LIVE_STRIPE_READY, live keys, the expected account/webhook and a strong worker secret. No production changes were made." >&2
    exit 64
  fi
  SUPABASE_PROJECT_REF="$project_ref" node .github/scripts/configure-stripe-production.mjs --preflight
fi

# Fail before migrations rather than leaving a partially upgraded checkout.
if [[ "$target" == staging ]]; then
  stripe_reconcile_secret="${STRIPE_RECONCILE_SECRET:-}"
  if [[ "${STRIPE_SECRET_KEY:-}" != sk_test_* ||
    "${STRIPE_PUBLISHABLE_KEY:-}" != pk_test_* ||
    "${STRIPE_WEBHOOK_SECRET:-}" != whsec_* ||
    ! "${STRIPE_WEBHOOK_ENDPOINT_ID:-}" =~ ^we_[A-Za-z0-9]+$ ||
    ${#stripe_reconcile_secret} -lt 32 ]]; then
    echo "Stripe sandbox keys, webhook signing secret and a 32+ character worker secret are required for staging." >&2
    exit 64
  fi
fi

production_function_list() {
  supabase functions list \
    --project-ref "$project_ref" \
    --output-format json
}

staging_secret_list() {
  local inventory
  # CLI 2.105.0 --output json preserves the raw array; --output-format json
  # instead wraps it in a success event. Never treat a failed list as empty.
  inventory="$(supabase secrets list --project-ref "$project_ref" --output json)" || return $?
  if ! jq -e -s '
    length == 1 and (.[0] | type == "array" and all(.[];
      type == "object" and (.name | type == "string" and length > 0)))
  ' >/dev/null 2>&1 <<<"$inventory"; then
    echo "Supabase returned an invalid secret inventory; refusing retired-secret cleanup." >&2
    return 1
  fi
  printf '%s\n' "$inventory"
}

if [[ "$target" == "production" ]]; then
  # Remove known development backdoors before touching the production schema.
  # The exact project-ref guard above makes this cleanup target-specific.
  function_list="$(production_function_list)"
  for forbidden_function in dev-phone-login dev-switch-user staging-admin-session; do
    if jq -e --arg name "$forbidden_function" \
      '.[] | select(.name == $name)' >/dev/null <<<"$function_list"; then
      echo "Removing forbidden ${forbidden_function} function from production."
      supabase functions delete "$forbidden_function" \
        --project-ref "$project_ref" \
        --yes
    fi
  done

  function_list="$(production_function_list)"
  if jq -e \
    '.[] | select(.name == "dev-phone-login" or .name == "dev-switch-user" or .name == "staging-admin-session")' \
    >/dev/null <<<"$function_list"; then
    echo "A staging-only authentication function still exists in production." >&2
    exit 1
  fi
fi

echo "Linking the ${target} Supabase project."
supabase link --project-ref "$project_ref" --yes

echo "Previewing pending ${target} migrations."
supabase db push --linked --include-all --dry-run --yes

echo "Applying pending ${target} migrations."
# Intentionally omit --include-seed. Hosted environments are never seeded by
# deployment; local seed data is applied only by local reset workflows.
# --include-all is required when an approved migration is merged after a newer
# migration has already reached the hosted project. Supabase still applies only
# migrations missing from its history table; this allows those pending files to
# be applied in timestamp order instead of failing before deployment.
supabase db push --linked --include-all --yes

echo "Verifying that ${target} has no pending migrations."
supabase db push --linked --include-all --dry-run --yes

echo "Verifying critical ${target} schema and policy invariants."
supabase db query \
  --linked \
  --file .github/scripts/verify-hosted-schema.sql

deploy_function() {
  local function_name="$1"
  shift
  echo "Deploying ${function_name} to ${target}."
  # Bundle through Supabase's API so hosted deployment does not download a
  # Docker Edge Runtime image on a separate, uncached CI runner.
  supabase functions deploy "$function_name" \
    --project-ref "$project_ref" \
    --use-api \
    "$@" \
    --yes
}

# Both hosted environments require the matching Stripe handlers and recovery
# worker. Only staging may deploy the separate developer authentication routes.
if [[ "$target" == "staging" || "$target" == "production" ]]; then
  # Do not put server keys in CLI arguments or print the temporary secret file.
  stripe_secrets_file="$(mktemp)"
  chmod 600 "$stripe_secrets_file"
  trap 'rm -f "$stripe_secrets_file"' EXIT
  printf 'STRIPE_SECRET_KEY=%s\nSTRIPE_WEBHOOK_SECRET=%s\nSTRIPE_RECONCILE_SECRET=%s\nFIELD_ENVIRONMENT=%s\n' \
    "$STRIPE_SECRET_KEY" "$STRIPE_WEBHOOK_SECRET" "$STRIPE_RECONCILE_SECRET" "$target" \
    >"$stripe_secrets_file"
  supabase secrets set \
    --project-ref "$project_ref" \
    --env-file "$stripe_secrets_file"
  rm -f "$stripe_secrets_file"
  trap - EXIT

  deploy_function stripe-payment --no-verify-jwt
  deploy_function stripe-payment-webhook --no-verify-jwt
  deploy_function stripe-payment-reconcile --no-verify-jwt
  if [[ "$target" == "staging" ]]; then
    SUPABASE_PROJECT_REF="$project_ref" node .github/scripts/configure-stripe-staging.mjs
  else
    SUPABASE_PROJECT_REF="$project_ref" node .github/scripts/configure-stripe-production.mjs
  fi

  # Remove retired endpoints only after their replacements are deployed.
  function_list="$(production_function_list)"
  for retired_function in tap-payment tap-payment-webhook; do
    if jq -e --arg name "$retired_function" '.[] | select(.name == $name)' \
      >/dev/null <<<"$function_list"; then
      supabase functions delete "$retired_function" --project-ref "$project_ref" --yes
    fi
  done
  # Repeated deployments may find none or only some of these retired secrets.
  # Keep the exact allowlist and fail on real listing/deletion errors.
  retired_secret_names=(TAP_SECRET_KEY TAP_PUBLIC_KEY TAP_MERCHANT_ID TAP_APPLE_PAY_ENABLED TAP_WEBHOOK_URL)
  present_retired_secrets=()
  secret_list="$(staging_secret_list)"
  for retired_secret in "${retired_secret_names[@]}"; do
    if jq -e --arg name "$retired_secret" 'any(.[]; .name == $name)' \
      >/dev/null <<<"$secret_list"; then
      present_retired_secrets+=("$retired_secret")
    fi
  done
  if [[ ${#present_retired_secrets[@]} -gt 0 ]]; then
    supabase secrets unset "${present_retired_secrets[@]}" --project-ref "$project_ref" --yes
  fi
  secret_list="$(staging_secret_list)"
  for retired_secret in "${retired_secret_names[@]}"; do
    if jq -e --arg name "$retired_secret" 'any(.[]; .name == $name)' \
      >/dev/null <<<"$secret_list"; then
      echo "Retired payment secrets remain after cleanup; refusing to complete deployment." >&2
      exit 1
    fi
  done

  # The handler validates Auth tokens and recent authentication itself. It is
  # additionally disabled until FIELDRUSH_ACCOUNT_DELETION_ENABLED is set.
  deploy_function fieldrush-delete-account --no-verify-jwt

  # Default-off until Firebase/APNs, signing capabilities and a separate guarded
  # worker configuration are ready. Deployment never enables push or reads its
  # service-account key into logs/CLI arguments.
  deploy_function fieldrush-push-dispatch --no-verify-jwt

fi

if [[ "$target" == "staging" ]]; then
  # Cloudflare authenticates its webhook with Webhook-Signature, so this
  # endpoint cannot require a Supabase user JWT.
  deploy_function cloudflare-stream-webhook --no-verify-jwt
  deploy_function profile-goal-clip

  # These functions deliberately never deploy to production.
  # This endpoint creates the staging-only bootstrap session, so no user JWT
  # exists yet. Its own exact-project, allow-listed phone, code, and expiry
  # checks are the authentication boundary.
  deploy_function dev-phone-login --no-verify-jwt
  deploy_function dev-switch-user --no-verify-jwt
  deploy_function staging-admin-session --no-verify-jwt
elif [[ "${DEPLOY_RECORDING_FUNCTIONS:-false}" == "true" ]]; then
  # Production recording stays opt-in until its separate Cloudflare secrets
  # and webhook routing have been configured.
  deploy_function cloudflare-stream-webhook --no-verify-jwt
  deploy_function profile-goal-clip
else
  echo "Skipping production recording functions until DEPLOY_RECORDING_FUNCTIONS=true."
fi

if [[ "$target" == "production" ]]; then
  function_list="$(production_function_list)"
  if jq -e '.[] | select(.name == "dev-phone-login" or .name == "dev-switch-user" or .name == "staging-admin-session")' \
    >/dev/null <<<"$function_list"; then
    echo "A staging-only authentication function exists in production." >&2
    exit 1
  fi
fi

echo "Supabase ${target} deployment completed."
