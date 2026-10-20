# Staging administrator profile switching

The mobile staging switcher uses `staging-admin-session`, not the isolated CI
`dev-switch-user` fixture transport. The endpoint requires a real, authenticated,
active `referee_profiles` administrator and the exact Fieldrush staging project.
It can select any existing, non-deleted, non-banned staging player account.

Every successful switch records `STAGING_ACCOUNT_SWITCH` in `admin_audit_events`
before returning a token. Audit failure blocks the switch. No passwords, contact
details, linked identities, or Auth session tables are changed.

Test sessions expire after 15 minutes and have no refresh token. Their signed
`fieldrush_staging_actor` claim identifies the initiating administrator. Such a
token cannot authorize another switch. The app retains the real administrator
session in memory for subsequent switches and preserves only the real login in
the existing on-device Supabase session storage. Restarting returns to that
login; the expiry timer also restores it. Signing out clears the retained login.

## Staging-only configuration

- `STAGING_ADMIN_SWITCH_ENABLED=true`
- `STAGING_IMPERSONATION_JWT_SECRET`: the staging project's existing legacy JWT
  signing secret, stored only in hosted Edge Function secrets. Never bundle this
  secret in the app, commit it, or configure it in production.

The function verifies bearer tokens with Supabase Auth itself, so gateway legacy
JWT verification is disabled for this endpoint. A valid staff row alone is not
enough: the calling token must also be a normal Auth session, not an impersonated
one. Existing automated-test capability/window restrictions remain unchanged.

The deploy script deploys this endpoint only to staging and includes it in the
production-forbidden function list. Production is additionally rejected by the
function's exact-project guard, even if its feature flag is accidentally enabled.

Actions taken while switched affect actual **staging** data. Use synthetic users
for destructive tests. This is not a production support impersonation feature.
