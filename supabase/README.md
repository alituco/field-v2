# Supabase Dev Data

Field Staging contains fake users, profiles, follows, clans, fixtures, and
scorer stats. Local Supabase is disposable. Field Production contains real
data only. Dev seed/reset scripts reject Field Production even if a production
env file is supplied accidentally.

Keep service-role secrets only in ignored server-side env files. Never put a
service-role key in a Flutter env/build config.

Profile photos use Supabase Storage bucket `profile-avatars`. The migration
creates the bucket and storage policies. Users can upload only into a folder
named after their own auth user id.

## Season 0 v2 rating rollout

Migrations `20261014001000` through `20261014001800` add the prospective
`field-sr-season0-v2` solo-match policy. The activation flag defaults to **off**.
Existing games retain their pinned policy; activation does not reset players,
seed existing accounts again, or convert previously created games.

The approved adaptations retain independent Outfield and Keeper pools, with one
new-account assessment seeding both. Each pool reveals SR after two lifetime
counted appearances; season-specific minimums still govern leaderboard/prize
qualification. During placement the signed-in player sees their own current SR
as **Predicted**. The owner-only snapshot is separate from public ranks, profiles,
and match history, which continue hiding numeric SR until two counted games.
Blue cards last 120 wall-clock seconds (including pauses), and
the referee confirms actual return. While suspended, the player retains their
rating contribution but earns no participation/protection time. Below ten actual
playing minutes, conduct permits negative adjustments only and no counted
appearance. Pre-kickoff moves preserve parties and formation, with recorded
consent for present movers; already revealed teams are not silently reshuffled.

The flag controls **new-game policy assignment only**, not the entire migration:
new-account assessment requirements and public lifetime-rating visibility take
effect when their migrations are installed. Coordinate the mobile, referee/admin
and database release; an older client cannot complete the newly required
assessment. Do not treat switching the flag off as a schema/client rollback.

Before enabling the policy:

1. Run the workflow's fresh-schema replay, normal local seed and SQL verifiers,
   Flutter tests/builds, and referee tests/browser checks. The isolated PGlite
   suites verify application SQL but substitute managed auth/storage/cron/network
   contracts; they do not replace the real Supabase checks.
2. On a disposable multi-connection PostgreSQL/Supabase database, test duplicate
   finish requests, finish versus correction, activation versus game creation,
   and booking/party mutations versus assignment/start. Verify atomic rollback,
   no duplicate active awards, and bounded lock/statement behavior.
3. Verify the updated mobile onboarding and hidden/revealed ratings, and the
   referee participation, blue-card return, pause, finish and admin-review paths
   against staging. Keep the policy disabled until compatible clients and
   referee tools are available. Do not use live bookings as test fixtures.
4. An authorized admin can then use **Season settings → Solo rating policy →
   Enable Season 0 v2 for future games**, entering a reason and confirming scope.
   Subsequent manually created and schedule-generated games receive the policy;
   already-created future games do not change.

If rollout needs to stop, disable it for future games through the same audited
control. Games already pinned to v2 still require the v2 tools. Do not delete
audit evidence, rewrite settled history, or reset ratings as a rollback strategy.

## Account deletion and wallet forfeiture

Account deletion permanently removes wallet access and forfeits the remaining
BHD and USD balances; it does not refund or transfer those balances. The mobile
confirmation and deletion endpoint require explicit acknowledgement. Migration
`20261014002000`, the deletion Edge Function and the updated mobile client must
roll out together. Older deletion requests fail closed without acknowledgement.
Wallet debits are append-only `ACCOUNT_DELETION_FORFEITURE` records in the final
Auth deletion transaction, not in the preparation/Storage step. A failed deletion
rolls back the debit. Unsettled payments/refunds and other deletion obligations
still block deletion; historical ledger and transaction evidence remain intact.

## Server-side environment files

The legacy root `.env` and `.env.staging` point to Field Staging. Create them
from `.env.example` with:

```sh
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
DEV_SEED_PASSWORD=
```

`DEV_SEED_PASSWORD` can be any strong throwaway password with at least 6
characters. It is only used for the fake auth users created by the seed script.

`.env.production` points to Field Production. Never pass it to a seed, reset,
or verifier command. The scripts also hard-deny the exact production ref as a
second safety layer.

For local verification, start/reset Docker Supabase and use the credentials
from `supabase status -o env`; CI performs this automatically.

## Seed fake users in local Supabase

The complete fake history seed is intentionally local-only. It creates rated
fixtures and immutable reliability audit rows, so start from a clean local
database and run it once:

```sh
supabase db reset
./supabase/scripts/seed_local.sh
```

The seed refuses hosted staging and production, and it refuses a second local
run instead of trying to delete rated or audited history. Run `supabase db
reset` whenever you want a fresh copy. Hosted staging keeps its own test
scenarios and uses targeted, non-destructive verifier scripts.

Historical matches are seeded through referee-authoritative attendance,
atomic lineup start, and atomic completion. This produces real ON_TIME
attendance, Player SR events, and match history without fake no-show strikes.

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
appearances. Open Queue parties close and White/Black teams are frozen three
hours before kickoff, provided all 12 position-specific spots are full. A game
that fills after that cutoff is assigned immediately. If a player cancels and
the game reopens, those team snapshots are cleared and the next fill is balanced
again using current Player SR.

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

Seeded fake fixtures include open, scheduled, and final match states. Final
fixtures include audited check-ins, played lineups, scorers, and assists so
profile stats, Player SR, and future leaderboard data have real rows to read
immediately. Each fake clan's configured rating and record is its background
history baseline; the visible seeded fixtures are then applied chronologically
through the normal rating path.

Seeded fake follows connect the fake users so the Profile screen's Following
and Fans counts open populated People lists.

## Local seed login and isolated staging E2E authentication

Loopback-only local seed login still accepts the development code for an
existing local seed user. It never creates users or resets their passwords.

Hosted fixed-code login and switching are **not** human account-switching
features. They reject production and remain unavailable unless a protected CI
run has configured all of the following:

- A service-owned synthetic fixture with matching protected
  `app_metadata.fieldrush_e2e`, reserved role/phone and current run ID.
- A generated per-run capability, separate from the public six-digit code,
  supplied only by test entrypoints in `x-fieldrush-e2e-secret`.
- A valid explicit UTC expiry, at most two hours away. CI selects 90 minutes.
- For switching, a valid JWT belonging to another fixture in that same run.

The service fixture setup runs before enabling the auth window. Existing real
players and ordinary staff cannot be tagged or reset by these endpoints.
Neither endpoint creates users, modifies metadata, resets passwords or mints
magic links. Historical phone allowlists and unauthenticated recovery flags
cannot bypass these checks.

The serialized staging workflow always closes its auth window after the final
journey or preparation failure. Owned-fixture cleanup revokes refresh sessions,
rotates synthetic passwords, clears current-run markers and retires temporary
staff access. The cleanup action then disables both functions' gates, expires
their windows and removes capability/password secrets. Supabase access JWTs can
remain cryptographically valid until expiry; no immediate JWT invalidation is
claimed. Real account credentials are never part of this cleanup.

If a runner is forcibly terminated before cleanup executes, the HTTP run window
still expires, but Supabase Auth does not itself give fixture passwords an
expiry. A leaked test password could remain usable until verified synthetic
cleanup rotates it. Keep encrypted handoffs/APKs private, and run ownership-
checked cleanup before reusing accounts from an interrupted run. The next
service setup also rotates the approved synthetic pool's passwords; it must
never auto-tag or repair an ordinary account at a reserved test phone.

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

## Profile Goal Clips

`profile-goal-clip` exposes authenticated download and profile-save workflows
for finished clan and solo recordings. The database RPC verifies that the
signed-in user scored or assisted a selected goal and prevents that player from
adding the same goal twice. A scorer and the credited assister can each save the
same goal. Any signed-in viewer can download any goal without saving it. The
function uses the source recording duration to apply the same replay-origin
selection as the app, then returns exact Cloudflare live-instant HLS and MP4
URLs covering 10 seconds before the goal through 20 seconds after it.

Viewers can also select a custom range from the full replay. The server checks
the trusted final-match recording and enforces a range within the source video
of at most 60 seconds. Custom clips can either be downloaded immediately or
saved to the caller's profile. Instant clips depend on the original match
recording, so that recording must remain in Cloudflare Stream. Whole-match MP4
downloads use Cloudflare's generated-download API and may require polling while
Cloudflare prepares the file.

Configure the Cloudflare account credentials used to create clips and MP4
downloads, then deploy the authenticated function with JWT verification:

```sh
supabase secrets set \
  CLOUDFLARE_ACCOUNT_ID='replace-with-account-id' \
  CLOUDFLARE_STREAM_API_TOKEN='replace-with-stream-write-token'
supabase functions deploy profile-goal-clip
```

The existing `CLOUDFLARE_STREAM_CUSTOMER_CODE` secret is also required. The API
accepts these POST bodies:

```json
{
  "action": "create",
  "source_type": "CLAN",
  "match_id": "fixture-or-solo-game-uuid",
  "event_id": "goal-event-uuid",
  "title": "Top corner finish"
}
```

```json
{ "action": "status", "highlight_id": "profile-highlight-uuid" }
```

Both actions return `{ "highlight": { ... } }`. A `202` response means the
request needs another status check. Owners can poll all of their clips; any
authenticated viewer can poll a public clip. Private clips return `404` to
non-owners. A public viewer's status request is read-only: only the owner can
trigger recovery mutations for an incomplete clip. `processing_status` and
`download_status` are stored for recovery and legacy compatibility.

Download any goal without adding it to a profile:

```json
{
  "action": "goal_download",
  "source_type": "SOLO",
  "match_id": "solo-game-uuid",
  "event_id": "goal-event-uuid"
}
```

The response is `{ "media": { ... } }`. `media` contains `video_url`,
`download_url`, `thumbnail_url`, the formatted `duration`, numeric
`duration_seconds`, and numeric `start_seconds` / `end_seconds` replay bounds.

Create a custom replay clip for immediate download:

```json
{
  "action": "custom_clip",
  "source_type": "CLAN",
  "match_id": "fixture-uuid",
  "start_seconds": 42.5,
  "end_seconds": 88.25,
  "save_to_profile": false
}
```

Set `save_to_profile` to `true` and include a 2–80 character `title` to
receive `{ "highlight": { ... } }` instead of `{ "media": { ... } }`.

Enable or poll a whole-match MP4 download:

```json
{
  "action": "full_game_download",
  "source_type": "CLAN",
  "match_id": "fixture-uuid"
}
```

The response status is `PROCESSING`, `READY`, or `FAILED`. A ready response
includes `download_url`; call the same action again while processing.

Clips are public by default. Public clips can be read by any authenticated
user; private clips remain readable by their owner. Legacy clips are migrated
as public. Change only one of your own clips with:

```json
{
  "action": "update_visibility",
  "highlight_id": "profile-highlight-uuid",
  "is_public": false
}
```

The response is `{ "highlight": { ... } }`, including the authoritative
`is_public` value. Delete only one of your own clips with:

```json
{
  "action": "delete",
  "highlight_id": "profile-highlight-uuid"
}
```

The response is `{ "deleted": true, "highlight_id": "..." }`. Direct
client inserts, updates, and deletes on `profile_highlights` are revoked so
ownership checks cannot be bypassed; these authenticated function actions are
the supported mutation API.

Verify visibility RLS, owner-only mutations, private view counting, and remote
cleanup with:

```sh
deno run --allow-env --allow-net --env-file=.env \
  supabase/scripts/verify_profile_clip_privacy.ts
```

Record one view when profile-clip playback actually begins with:

```sql
select public.record_profile_highlight_view('profile-highlight-uuid');
```
