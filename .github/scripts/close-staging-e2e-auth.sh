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
supabase secrets unset DEV_AUTH_SECRET DEV_OTP_PASSWORD DEV_SWITCH_PASSWORD \
  --project-ref "$staging_project_ref" --yes >/dev/null
echo "The staging E2E authentication window is closed."
