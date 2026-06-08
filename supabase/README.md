# Supabase Dev Data

This project uses the hosted Supabase dev project for fake users and clans. Keep
service-role secrets only in the repo-root `.env`. Never put a service-role key
in `mobile/.env.mobile` or any Flutter build config.

## Root `.env`

From the repo root, create or update `.env` with:

```sh
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
DEV_SEED_PASSWORD=
```

`DEV_SEED_PASSWORD` can be any strong throwaway password with at least 6
characters. It is only used for the fake auth users created by the seed script.

## Seed Fake Users And Clans

Apply migrations before seeding:

```sh
supabase db push
```

Run from the repo root:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/seed_dev_data.ts
```

The command is idempotent. It reuses existing fake auth users by phone,
refreshes their profiles, removes seeded fake clan data, and recreates the
seeded clans and fixtures.

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
```

Seeded fake clans:

```text
NRYL  Neon Royals
MMAV  Mint Mavericks
CDRF  Crimson Drift
```

Seeded fake fixtures include open, scheduled, live, and final match states so
the fixtures board and detail screens have data immediately.

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
