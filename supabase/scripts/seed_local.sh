#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

for command_name in docker supabase deno; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop is not running." >&2
  exit 1
fi

# config.toml references disabled local integrations. Keep their required
# placeholders out of developer shell setup and out of the generated seed file.
export OPENAI_API_KEY="${OPENAI_API_KEY:-local-placeholder}"
export SUPABASE_AUTH_SMS_TWILIO_AUTH_TOKEN="${SUPABASE_AUTH_SMS_TWILIO_AUTH_TOKEN:-local-placeholder}"
export SUPABASE_AUTH_EXTERNAL_APPLE_SECRET="${SUPABASE_AUTH_EXTERNAL_APPLE_SECRET:-local-placeholder}"
export S3_HOST="${S3_HOST:-local.invalid}"
export S3_REGION="${S3_REGION:-local}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-local-placeholder}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-local-placeholder}"

seed_password="${DEV_SEED_PASSWORD:-LocalField_Only_42!}"
env_file="$(mktemp "${TMPDIR:-/tmp}/field-local-seed.XXXXXX")"
trap 'rm -f "$env_file"' EXIT

supabase status -o env \
  --override-name api.url=SUPABASE_URL \
  --override-name auth.anon_key=SUPABASE_PUBLISHABLE_KEY \
  --override-name auth.service_role_key=SUPABASE_SERVICE_ROLE_KEY \
  >"$env_file"
printf '\nDEV_SEED_PASSWORD=%s\n' "$seed_password" >>"$env_file"
chmod 600 "$env_file"

deno run \
  --allow-env \
  --allow-net \
  --env-file="$env_file" \
  supabase/scripts/seed_dev_data.ts

deno run \
  --allow-env \
  --allow-net \
  --env-file="$env_file" \
  supabase/scripts/seed_open_queue_data.ts
