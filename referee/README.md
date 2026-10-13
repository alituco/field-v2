# Field Referee Web App

Mobile-first Next.js app for referees to run clan and solo/Open Queue games,
including the match clock, goals, assists, blue cards, and livestream.

## Setup

Create `referee/.env.local`:

```sh
NEXT_PUBLIC_APP_ENV=staging
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

The service-role key is used only by Next.js API routes. Do not expose it as a `NEXT_PUBLIC_` value.

Use `NEXT_PUBLIC_APP_ENV=local`, `staging`, or `production`. Local and staging
show a permanent environment ribbon; production does not. The app refuses an
explicit staging/production environment when the Supabase project does not
match the guarded Field project.

## Run

```sh
cd referee
npm install
npm run dev -- -p 3001
```

Open `http://localhost:3001` on the referee phone or simulator browser.

## Test

```sh
npm run typecheck
npm test
npm run test:ui
npm run test:e2e -- --list
```

`test:ui` runs isolated admin fields, schedules and referee-clock flows on port 3000 with mocked
authentication/API responses. It does not create accounts, fields or games in
staging. It covers required saved-field selection, the empty-catalogue handoff,
map validation, archive/restore, failed saves, and preserving game drafts.
For the Safari-engine coordinate regressions, install the Playwright WebKit
browser (`npx playwright install webkit`) and run
`FIELD_UI_WEBKIT=1 npm run test:ui`. Coordinates use explicit decimal/range
validation rather than locale-dependent native number inputs.

The Playwright journey under `e2e/` runs against the local production build
connected to Field Staging. GitHub Actions creates its isolated manifest,
executes the referee/admin workflow, verifies Postgres afterward, and cleans
mutable test state. It is guarded for the exact Field Staging project and must
not be pointed at production.

## Saved fields and solo games

Apply `20261011000100_saved_fields_and_game_locations.sql` to the target
database **before** deploying this admin/mobile version. Running Next.js locally
does not automatically apply database migrations.

- Open **Admin → Fields** (`/admin/fields`) to add or edit a pitch. Each field
  requires a name, street address, city/region/country, and valid map coordinates.
- **Create solo game** requires an active saved field. If none exist, it opens
  `/admin/fields/new` and returns to game creation with the new field selected.
- Archiving hides a field from new games; restore it to make it available again.
  Existing games keep their original location snapshot even if a field changes.
- Mobile booking/details display that snapshot; Directions uses the precise pin.
  Legacy games are not assigned invented addresses or coordinates.
- One-off games accept any future date and kickoff, with a 30–180 minute duration
  (default 60). Times are in America/Phoenix. Format stays seven-a-side and USD.
- The same pitch cannot have overlapping non-cancelled games. Adjacent slots and
  parallel games at different pitches are supported.

Catalog access and mutations require an active admin. Players can read their
game's public location, not private catalog/audit data. The database enforces
active-field selection, snapshot consistency, and audit records. Historical and
isolated service-owned test games remain compatible.

## Recurring game schedules

Apply `20261011000200_configurable_solo_schedules.sql` after the saved-fields
migration. Open **Admin → Schedules** (`/admin/schedules`), or use **Recurring
schedules** from Games. Select an active saved pitch, weekdays, kickoff, duration,
start/end dates, price, and booking window (7–84 days; default 28).

- Saving an active schedule opens bookings for eligible future dates within its
  window immediately. A database cron job runs hourly at minute 7 to extend it.
  Next.js does not need to remain open for recurring games to be generated.
- Edits apply only to games not yet generated. Published games keep their times,
  duration, price and location. Pause stops generation, not existing bookings.
- Skip a future date with a reason; removing a skip makes that date eligible
  again. If a game already exists, cancel it from its own game page instead.
  Cancelled or removed generated games are never silently recreated.
- Conflicts (including archived fields) appear in the schedule details. Correct
  the pitch/time or field status and use **Generate next games** to retry.
- Referee clocks default to each game's saved duration, with the existing
  three-hour safety cap. Attendance, refund and team-draw policy rules stay intact.

Schedule configuration and mutation RPCs require an active admin. The hourly
worker is private and runs already-approved active schedules; it cannot be
called by mobile clients. Schedule changes and generated games are audited.
The isolated `supabase/scripts/test_game_schedules.mjs` suite covers permissions,
overlap rejection, date windows, idempotency and preservation of existing games.

## Editing a published game's price

Apply `20261011000300_edit_solo_game_prices.sql` and deploy the updated
`stripe-payment` function. Open an upcoming solo game's overview and choose
**Edit price**. Admins can set free entry or $0.50–$100 per player, with a required
audited reason. Started, cancelled, under-review and legacy games are read-only.

- Only this game's future checkouts use the new price. Recurring schedule
  templates, other generated games and the default price do not change.
- Existing payments are never topped up or automatically refunded by a price
  edit. Valid, unexpired checkouts keep their original server-owned quote.
- Payment history retains the actual original match fee, deposit, total paid and
  completed refunds for each booking, including cancelled/rebooked entries.
  Missing historical amounts are shown as unrecorded, never inferred from the
  game's current price.
- Cancellation refunds still use each booking's original amounts. Concurrent
  admin price changes require an explicit refresh before another save.

`supabase/scripts/test_game_prices.mjs` checks authorization, concurrent edits,
payment-quote preservation and original-amount refunds. Web unit/browser tests
cover validation, audit requests and the payment history UI.

Apply `20261011000400_enforce_bookable_game_prices.sql` with these changes.
New one-off games and new or edited schedule prices accept free entry or
$0.50–$100 in whole cents, matching Stripe's minimum charge. Historical games
and payments retain their recorded prices and remain operable.

## Interest signups

Apply `20261012000600_capture_fieldrush_launch_interest.sql` to the target database
**before** deploying this admin version. Open **Admin → Interest** to view email
signups and existing player applications in the private `season_zero_waitlist`
table. Only active admins can read the list.

The public Fieldrush site and production admin use the same canonical production
database, `zjsjuuhborxrlmdcpvlj`. Staging uses synthetic test entries in its own
database and must not be connected to production.

The list shows signup source, placement and consent date. The **Launch updates**
filter includes earlier player applicants who subsequently subscribe without
changing their original interest or status. An earlier application alone does
not grant launch-update consent. Saving these signups does not send emails.

## Current Flow

- Referee signs in with phone OTP.
- Admin referees can create referee profiles and assign referees to clan or
  Open Queue games.
- Assigned referees see only their own upcoming games.
- Three hours before kickoff, a full Open Queue game appears as White Team vs
  Black Team using its confirmed bookings and automatically balanced teams.
- Start the match timer.
- Record goals with scorer and optional assist.
- Record blue cards. Active cards count down from 2 minutes and alert when the player can return.
- Finish match. The server computes score from recorded goals and applies SR through Supabase.
