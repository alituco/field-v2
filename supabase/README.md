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

The seed command is idempotent. It reuses existing fake auth users by phone,
refreshes their profiles, removes seeded follows, profile highlights, career
rows, fake clan data, fixture scorer rows, and recreates the seeded app data.

## Reset All Game Schedule Data (Destructive)

Use this development-only reset when you need a clean fixture and Open Queue
schedule. It permanently removes the current game schedule data before seeding
the canonical Tuesday/Friday schedule, so do not run it against production:

```sh
deno run --allow-env --allow-net --env-file=.env --env-file=referee/.env.local supabase/scripts/reset_game_schedule_data.ts --confirm
```

Pass `--clear-only` to delete the game schedule data without creating the
replacement seed data. Pass `--skip-cloudflare` to leave the associated remote
Cloudflare Stream recordings untouched; those recordings can remain orphaned
after their database records are removed. Both flags still require `--confirm`.

Verify the clean data, permanent time split, paired match days, historical
appearances, and both upcoming-game limits:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_permanent_game_schedule.ts
```

Verify the authenticated Fixtures feed includes both completed and upcoming
solo games with accurate scores, player counts, and caller-only booking data:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_open_queue_fixture_feed.ts
```

Verify that Player Rankings use confirmed games from the selected season and
exclude players with fewer than two games:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_season_player_rankings.ts
```

Only referee-confirmed appearances marked `played = true` count. Fixtures
inserted directly as `FINAL` without a recorded lineup are intentionally
excluded rather than guessing which clan members participated.

Verify the two-upcoming-game limits for clans and solo players:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_scheduling_limits.ts
```

After adding the solo referee/match-control migration, backfill the existing
development schedule with referee assignments and recording-aligned solo goal
timelines without resetting any games:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/seed_open_queue_match_history.ts
```

Then verify solo match details, Career history, goal timestamps, and referee
assignments together:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_open_queue_match_system.ts
```

After applying the Open Queue Player SR migration, verify exact role-preserving
team balance, frozen team averages, the clan-and-solo rating ledger, and the
public calculation history payload:

```sh
deno run --allow-env --allow-net --env-file=.env supabase/scripts/verify_open_queue_player_sr_system.ts
```

Player SR uses the same `PLAYER_ELO_V1` calculation for confirmed clan and solo
appearances. Open Queue teams are frozen as soon as all 12 position-specific
spots fill. If a player cancels and the game reopens, those team snapshots are
cleared and the next fill is balanced again using current Player SR.

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
