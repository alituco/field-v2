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

production_function_list() {
  supabase functions list \
    --project-ref "$project_ref" \
    --output-format json
}

if [[ "$target" == "production" ]]; then
  # Remove known development backdoors before touching the production schema.
  # The exact project-ref guard above makes this cleanup target-specific.
  function_list="$(production_function_list)"
  for forbidden_function in dev-phone-login dev-switch-user; do
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
    '.[] | select(.name == "dev-phone-login" or .name == "dev-switch-user")' \
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
  supabase functions deploy "$function_name" \
    --project-ref "$project_ref" \
    "$@" \
    --yes
}

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
  if jq -e '.[] | select(.name == "dev-phone-login" or .name == "dev-switch-user")' \
    >/dev/null <<<"$function_list"; then
    echo "A staging-only authentication function exists in production." >&2
    exit 1
  fi
fi

echo "Supabase ${target} deployment completed."
