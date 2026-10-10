# Field Mobile

Flutter app for Field.

## Environments

Field has separate native `staging` and `production` flavors. Local development
uses the staging flavor so it can never overwrite the production app on a
device.

From `mobile/`, run one of:

```sh
# Local Supabase (Docker must be running)
flutter run --flavor staging --dart-define-from-file=.env.local

# Hosted Field Staging
flutter run --flavor staging --dart-define-from-file=.env.staging

# Field Production
flutter run --flavor production --dart-define-from-file=.env.production
```

Each environment file uses:

```sh
APP_ENV=local # or staging / production
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
DEV=true
PROFILE_SWITCHER_ENABLED=true
```

Use the Supabase publishable key in the app. Never put a secret or service-role
key in Flutter. Do not pass the repo root `.env` into Flutter builds.

`PROFILE_SWITCHER_ENABLED=true` exposes the staging-only **Swap profile** tool.
The app rejects this flag in production, and the matching backend function is
guarded to the exact Field Staging project and removed from production deploys.

`DEV=true` enables the remaining development-only tools. Staging TestFlight can
therefore keep `DEV=false` while still allowing approved testers to swap users.
Both flags must be `false` in production. The app validates the native flavor,
environment label, and expected Supabase project before initializing; an
invalid combination stops on a configuration screen.

Local and staging builds have a visible ribbon. Production has no ribbon.

The legacy `.env.mobile` file is still the developer's hosted-staging source,
but new commands should use `.env.staging`.

## Local database

From the repository root:

```sh
supabase start
supabase db reset
supabase status
supabase stop
```

`supabase db reset` rebuilds the local database from every migration and adds
only the local historical reliability-policy bootstrap. It never targets a
hosted project. To add the complete fake users and match history afterward,
run `./supabase/scripts/seed_local.sh` from the repository root.

## Test

```sh
flutter analyze
flutter test
```

See [Stripe Payments](../docs/stripe-payments.md) for the secure local checkout
setup, supported payment methods, and device requirements.

The hosted Android journey lives in
`integration_test/staging_player_journey_test.dart`. CI provisions its isolated
accounts and games, supplies per-run `--dart-define` values, and runs it only
inside the protected staging deployment. Do not point it at production or run
it without the matching fixture manifest.

The two iOS schemes are `staging` and `production`. Android uses matching
product flavors and installs staging as `com.field.field.staging`.
