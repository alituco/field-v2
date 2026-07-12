# Supabase Dev Data

This project uses the hosted Supabase dev project for fake users, profiles,
follows, clans, fixtures, and scorer stats. Keep service-role secrets only in
the repo-root `.env`. Never put a service-role key in `mobile/.env.mobile` or
any Flutter build config.

Profile photos use Supabase Storage bucket `profile-avatars`. The migration
creates the bucket and storage policies. Users can upload only into a folder
named after their own auth user id.

## Root `.env`

From the repo root, create or update `.env` with:

```sh
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
DEV_SEED_PASSWORD=
```

`DEV_SEED_PASSWORD` can be any strong throwaway password with at least 6
characters. It is only used for the fake auth users created by the seed script.

## Seed Fake Users And App Data

Apply migrations before seeding:

```sh
supabase db push
```

Run from the repo root:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/seed_dev_data.ts
```

The command is idempotent. It reuses existing fake auth users by phone,
refreshes their profiles, removes seeded follows, profile highlights, career
rows, fake clan data, fixture scorer rows, and recreates the seeded app data.

Seeded fake users:

```text
+97338883671  Zara Haddad
+97338883672  Omar Saleh
+97338883673  Noor Khalid
+97338883674  Maya Faris
+97338883675  Sami Nasser
+97338883676  Lina Abbas
+97338883677  Rami Darwish
+97338883678  Hala Mansour
+97338883679  Madeline Coffey (free agent)
```

Seeded fake clans:

```text
NRYL  Neon Royals
MMAV  Mint Mavericks
CDRF  Crimson Drift
```

Seeded fake fixtures include open, scheduled, live, and final match states.
Final fixtures include scorers and assists so the profile stats and future
leaderboard data have real rows to read immediately.

Seeded fake follows connect the fake users so the Profile screen's Following
and Fans counts open populated People lists.

## Fixed-Code Dev Login

The Flutter app skips real SMS for the seeded fake phones and sends verification
to the `dev-phone-login` Edge Function. Configure the function with Supabase
secrets:

```sh
supabase secrets set \
  DEV_OTP_ENABLED=true \
  DEV_OTP_CODE=000000 \
  DEV_OTP_PASSWORD='replace-with-a-strong-dev-password' \
  DEV_OTP_USERS_JSON='{"+97338883671":"Zara Haddad","+97338883672":"Omar Saleh","+97338883673":"Noor Khalid","+97338883674":"Maya Faris","+97338883675":"Sami Nasser","+97338883676":"Lina Abbas","+97338883677":"Rami Darwish","+97338883678":"Hala Mansour"}'
```

The existing single-phone dev login still works if these secrets are also set:

```sh
supabase secrets set \
  DEV_OTP_PHONE=+97338883670 \
  DEV_OTP_NAME='Dev Player'
```

Deploy the function after changing secrets or code:

```sh
supabase functions deploy dev-phone-login
```

To test as a fake user, sign out in the app, enter one of the fake phone
numbers, and use code `000000`.

Do not enable `DEV_OTP_ENABLED=true` on any production Supabase project.

## Dev User Switching

With `DEV=true` in `mobile/.env.mobile`, the current user's Profile screen
shows a searchable account switcher. The switch is performed by the
authenticated `dev-switch-user` Edge Function, so the service-role key never
ships in Flutter.

Enable and deploy it only on the hosted development project:

```sh
supabase secrets set DEV=true
supabase secrets set DEV_SWITCH_ALLOW_UNAUTHENTICATED=true
supabase functions deploy dev-switch-user --no-verify-jwt
```

Phone-only users use the existing `DEV_OTP_PASSWORD` secret. You can instead
set a separate strong password with:

```sh
supabase secrets set DEV_SWITCH_PASSWORD='replace-with-a-strong-dev-password'
```

Set `DEV=false` in both Flutter and Supabase, or do not deploy this function,
for production. Client-side `DEV=true` alone cannot enable impersonation.
`DEV_SWITCH_ALLOW_UNAUTHENTICATED` exists only to recover revoked fake-user
sessions and must never be enabled outside the isolated development project.

## Cloudflare Stream Recording Webhook

The `cloudflare-stream-webhook` Edge Function verifies Cloudflare's signed
recording notifications and attaches a ready replay to its fixture. It is
deployed without Supabase JWT verification because Cloudflare authenticates
with the `Webhook-Signature` header instead.

The hosted development project is already registered. For a separate Supabase
or Cloudflare environment, deploy the function, register its public URL as the
account's Stream webhook, and store the returned signing secret as
`CLOUDFLARE_STREAM_WEBHOOK_SECRET`. Cloudflare permits one Stream recording
webhook per account, so use a separate Cloudflare account for production or
route one webhook to both environments deliberately.
