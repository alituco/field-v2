#!/usr/bin/env bash
# Called only by the serialized staging workflow's final cleanup leg.
set -euo pipefail
readonly staging_project_ref="nfdkdhdevpstfspazbfn"
if [[ "${FIELD_ENVIRONMENT:-}" != staging ||
  "${SUPABASE_PROJECT_REF:-}" != "$staging_project_ref" ||
  "${SUPABASE_URL:-}" != "https://${staging_project_ref}.supabase.co" ||
  -z "${SUPABASE_ACCESS_TOKEN:-}" || -z "${GITHUB_RUN_ID:-}" ||
  -z "${GITHUB_RUN_ATTEMPT:-}" ||
  "${E2E_RUN_ID:-}" != "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" ]]; then
  echo "::error::Refusing E2E auth cleanup outside this serialized staging run." >&2
  exit 64
fi
umask 077
secrets_file="$(mktemp)"
trap 'rm -f "$secrets_file"' EXIT
printf 'DEV=false\nDEV_OTP_ENABLED=false\nDEV_SWITCH_ALLOW_UNAUTHENTICATED=false\nDEV_AUTH_VALID_UNTIL=1970-01-01T00:00:00.000Z\nDEV_OTP_VALID_UNTIL=1970-01-01T00:00:00.000Z\nDEV_SWITCH_VALID_UNTIL=1970-01-01T00:00:00.000Z\n' >"$secrets_file"
supabase secrets set --project-ref "$staging_project_ref" --env-file "$secrets_file" >/dev/null

secret_inventory() {
  local inventory status
  # CLI 2.105.0 --output json is a bare array, unlike --output-format json.
  # Failed or malformed inventories must never be mistaken for an empty list.
  inventory="$(supabase secrets list --project-ref "$staging_project_ref" --output json 2>/dev/null)" || {
    status=$?
    echo "::error::Could not read the staging secret inventory." >&2
    return "$status"
  }
  if ! jq -e -s '
    length == 1 and (.[0] | type == "array" and all(.[];
      type == "object" and (.name | type == "string" and length > 0)
        and (.value | type == "string"))
      and ([.[].name] | length == (unique | length)))
  ' >/dev/null 2>&1 <<<"$inventory"; then
    echo "::error::Invalid staging secret inventory; refusing credential cleanup." >&2
    return 1
  fi
  printf '%s\n' "$inventory"
}

# Setup only creates the first two; the retired switch password may already be
# absent. Bulk deletion of absent names fails in the CLI, including on retries.
readonly retired_secret_names=(DEV_AUTH_SECRET DEV_OTP_PASSWORD DEV_SWITCH_PASSWORD)
present_secrets=()
inventory="$(secret_inventory)"
for secret_name in "${retired_secret_names[@]}"; do
  if jq -e --arg name "$secret_name" 'any(.[]; .name == $name)' >/dev/null <<<"$inventory"; then
    present_secrets+=("$secret_name")
  fi
done
if [[ ${#present_secrets[@]} -gt 0 ]]; then
  supabase secrets unset "${present_secrets[@]}" --project-ref "$staging_project_ref" --yes >/dev/null
fi

inventory="$(secret_inventory)"
for secret_name in "${retired_secret_names[@]}"; do
  if jq -e --arg name "$secret_name" 'any(.[]; .name == $name)' >/dev/null <<<"$inventory"; then
    echo "::error::Temporary staging E2E credentials remain after cleanup." >&2
    exit 1
  fi
done
# The acknowledged set above establishes the fixed closed values. The inventory
# exposes digests, not readable values: verify its control names without logging
# or assuming an undocumented digest algorithm.
for control_name in DEV DEV_OTP_ENABLED DEV_SWITCH_ALLOW_UNAUTHENTICATED \
  DEV_AUTH_VALID_UNTIL DEV_OTP_VALID_UNTIL DEV_SWITCH_VALID_UNTIL; do
  if ! jq -e --arg name "$control_name" 'any(.[]; .name == $name)' >/dev/null <<<"$inventory"; then
    echo "::error::A closed staging E2E authentication control is missing." >&2
    exit 1
  fi
done
echo "The staging E2E authentication window is closed."
