# Fieldrush account setup

This foundation replaces the mobile app’s signup and account entry flow with the supplied Fieldrush design. It supports phone OTP and Google, requires a verified phone and an adult birthday, and keeps account identity separate from public player profiles. Home, account details, You, Fixtures, solo game details and Ranks now have native Fieldrush layouts. Historical clan screens and the website have not received that full visual redesign.

## What is implemented

- Native cream and forest onboarding with the prototype’s bundled Outfit and Plus Jakarta Sans fonts, welcome artwork, international country picker defaulting to US +1, OTP entry, personal details, username availability and review.
- Real Supabase phone OTP and browser Google OAuth. Login and recovery do not create a new phone account. Google signup must add and verify a phone on the same authenticated account.
- Server-persisted onboarding drafts. Completion is authoritative database state, never an editable auth metadata flag.
- Private first name, last name, birthday and contact email. Public names are first name plus last initial, for example `Alex R.`. Public profile queries cannot read phone or birthday.
- Unique lowercase usernames of 3–20 letters, digits, dots or underscores. Reserved staff, brand and technical names include separator-obfuscated and numeric-suffix variants; ordinary names such as `devin` remain usable.
- Backend 18+ validation and versioned Terms and Privacy acceptance. Finishing signup opens Home immediately; no welcome confirmation or tour-completion step is required.
- Account settings, Google linking, verified phone change, recovery and guarded deletion. Birthday corrections after signup require support.

## Home and account details

Home uses real bookings, positions, game capacity, notifications, public player search and season ratings. It shows an empty position picker until a game is booked, then the upcoming game, with additional bookings below. Streaks are intentionally omitted. Account details provides inline name, username and email editing, avatar upload/reset, verified phone changes, and a server-owned home city. Navigating away from unsaved edits requires confirmation.

New Phoenix solo games are 7v7: one goalkeeper, three defenders and three attackers per team. Prices default to **USD 13 per player**, and admins can set a different whole-cent USD price when creating a game. The existing Tuesday/Friday 8:30–9:30 PM schedule now uses Phoenix time for new solo games. Division boundaries are 1100, 1300, 1500 and 1650 SR, with two rated placement games. Phoenix is the launch city; self-service city changes are not enabled.

Existing 6v6 games, midfielder bookings and historical clan games retain their original rules and BHD currency. Previously rated accounts retain their market and history. Only completed, unrated Fieldrush accounts without legacy game, payment or wallet obligations move to Phoenix. This is not a database reset.

## You and profile settings

The private You tab now follows the prototype: identity and Edit, Following/Fans, the division or placement card, current-season results, last five results, real clips, reliability, and grouped settings. Public player profiles remain separate and do not load private account or wallet information. Social rows open actual profiles; clips and match history open their existing detail screens. Unavailable data stays visibly unavailable rather than becoming invented zeroes or lifetime statistics.

Notification preferences use the existing authenticated settings RPCs and wait for server confirmation before changing a switch. The wallet displays exact, separate currency balances through `get_my_fieldrush_wallet`, now deployed to staging. Payment methods explains the existing checkout flow; it does not pretend to store cards, support wallet spending, or provide a transaction ledger. Support, sign-out confirmation and the staging-only profile switcher remain accessible.

You-page verification: all 378 Flutter tests and Flutter analysis passed. Ranked and placement layouts were rendered with the bundled fonts, including 320px/large-text checks; real profile, notification preferences and match history were checked in the staging iOS simulator. The later ranking reset below enables hosted placement against the player's existing market. Phoenix market and wallet migrations were subsequently deployed in the October 10 rollout below.

## Fixtures, booking and Ranks

Fixtures uses real Phoenix/USD games, local match dates, recorded status, booking membership and scores. Cards open a dedicated game page; they do not book immediately. Legacy fixture UI remains separate for historical clan/6v6 behavior. New clan bookings stay disabled.

The Play flow follows the prototype: select any combination of Keeper, Defender and Attacker → choose a matching game → review the game and suggested position → verify the exact server quote → native Stripe payment → confirmed booking. Home enters the same matching-game step with all selected positions preserved. Suggestions choose the most open slots among those preferences; an earlier out-of-position alternative requires an explicit selection. Opening a specific game lets the player choose an available role before checkout. Availability and price are rechecked, changed terms require confirmation, and ambiguous payment retries recover an existing booking/intent rather than bypassing payment verification.

The supplied HTML is a visual/flow reference, not a source of production transactions. No sample players, fake card balances or sample game prices are used. Games remain 60 minutes, as agreed, and the screens use each game's actual duration, admin-policy assignment cutoff and cancellation policy; the prototype's 90-minute duration and three-hour draw are not installed as new rules. Current default solo pricing remains USD 13, configurable through admin.

Game details expose the live roster, team assignment, match timeline, stream/recording, clips, venue directions, party management and a server-previewed cancellation refund. Party and booking permissions remain enforced by the existing backend. Refunds return to the original payment method under the saved policy.

Ranks shows Phoenix Solo, two-game placement, authoritative season standing, podium, nearby ranks and a paginated full ladder. Clan rankings show Coming soon. It does not move legacy players into Phoenix or fabricate week-over-week movement. Apply `20261011000000_fieldrush_leaderboard_pages.sql` with the normal backend rollout **before releasing this mobile version**; the new authenticated, bounded read RPC provides pagination and excludes deleted profiles consistently from the authoritative ranking helper. It does not reset ratings or change division thresholds. This branch alone does not deploy that migration.

Run `flutter analyze --no-pub` and `flutter test --no-pub` from `mobile`. The focused suites are `fieldrush_booking_flow_test.dart`, `fieldrush_fixture_booking_navigation_test.dart`, `fieldrush_fixture_page_test.dart`, `fieldrush_game_detail_screen_test.dart` and `fieldrush_leaderboard_test.dart`. The isolated SQL harness is `PGLITE_MODULE=/path/to/node_modules/@electric-sql/pglite node supabase/scripts/test_fieldrush_leaderboard.mjs`; this supplements full Supabase replay and hosted device/payment E2E, not replaces them.

Local verification: all 465 Flutter tests passed with two test workers, plus 33 leaderboard, 63 ranking-reset and 39 Phoenix-market isolated PostgreSQL checks. Native layouts were rendered with the bundled fonts and checked at narrow widths with enlarged text. The staging iOS simulator build passed. Hosted E2E selectors/assertions were updated and statically analyzed, but the hosted mutation journey and this migration have not been run against staging as part of this branch.

### Player ranking resets

`20261009010000_add_player_rating_reset_periods.sql` adds a privileged, explicit reset operation. Installing the migration alone does **not** reset users. A reset starts all player ratings at the internal 1200 SR baseline with zero current-period matches, wins, draws, losses and rating change. The app shows **Placement, 0/2** rather than that hidden baseline. Two new rated games reveal a division.

The service-role-only `reset_player_rankings(request_id_to_use uuid, reason_to_use text)` requires a unique request ID and a reason. Reuse the same request ID when retrying an uncertain outcome; it returns the original result instead of erasing new progress. Before calling it, take a private database backup and finish or cancel every started unfinished match. The function also refuses live, paused, running and recorded-start matches, takes private recovery snapshots, and rebases only future unstarted lineup SR snapshots without changing teams.

Past games, rating events, archived seasons, refunds, strikes, clan rankings and account data are preserved. Both a timestamp and ledger-sequence boundary exclude prior events from current placement, including future-dated test results. Old score corrections and appeals cannot change the new player SR or counters; verified-injury refunds still run. Home and You use current-period results while match history retains the original rating details. This is a **player ranking reset**, not a season, market, reliability or clan-data reset.

On October 10, 2026 (UTC), this migration and one explicit reset were applied to **hosted staging only**: all 121 player ratings returned 0/2 placement, and all 482 rating-event rows were verified unchanged. The reset rebased one future solo booking; game counts, booking counts and player regions were unchanged. Private local backup and verification records are under the gitignored `scratch/ranking-resets/2026-10-10/`; database snapshots are in `fieldrush_rating_private`. No October 10 market/payment migrations or production changes were deployed by this reset.

Verification: 385 Flutter tests, Flutter analysis, 63 isolated PostgreSQL checks, a hosted rollback rehearsal with all 121 player season RPCs, post-commit database comparisons, and the staging simulator placement display passed. Run the targeted SQL fixture with `PGLITE_MODULE=/path/to/node_modules/@electric-sql/pglite node supabase/scripts/test_player_rating_reset.mjs`. This fixture is not a complete Supabase migration replay.

### Staging rollout and payment boundary

The following October 10 migrations were applied to hosted staging in timestamp order, inside one transaction, after a private backup and rollback-only rehearsal:

- `20261010000000_fieldrush_phoenix_game_format.sql`: versioned solo formats, Phoenix schedule, team allocation, account market and policy snapshots.
- `20261010000100_fieldrush_usd_wallet_isolation.sql`: currency-safe payment intent checks and separate USD wallet accounting.
- `20261010000200_move_fresh_fieldrush_accounts_to_phoenix.sql`: guarded migration of eligible fresh accounts only.
- `20261010000500_fieldrush_home_activity.sql`: recipient-only notification read acknowledgements.

The rehearsal exercised actual admin game creation, USD quoting, 7v7 policy snapshots, rejection of MID bookings, market-isolated feeds and account/wallet RPCs. Its synthetic game was rolled back. Post-commit comparisons verified all 163 existing games, 1,054 bookings, 482 rating events, historical policy snapshots, published policies and BHD balances were preserved. No games were seeded and no production data was changed. Private backup and verification records are under the gitignored `scratch/phoenix-rollout/2026-10-10/`.

**Stripe is the checkout provider for Fieldrush.** See [Stripe payments](stripe-payments.md) for sandbox setup, native Apple Pay, original-payment-method refunds and the coordinated backend/mobile rollout. Preserve historical payment and refund records when retiring the previous provider; do not erase financial history.

The admin PWA can be deployed independently, without triggering TestFlight:

```sh
gh workflow run smoke-supabase-staging.yml \
  --repo alituco/field-v2 --ref staging -f deploy_admin=true
```

That manual workflow runs hosted staging API smoke checks and admin tests/type-checking, then publishes only the configured `field-ops-staging` Vercel project. It does not apply migrations or build/upload a mobile binary. This source promotion uses an explicit `[skip ci]` merge marker to avoid the ordinary push workflow's automatic TestFlight path; normal future staging pushes retain their existing CI behavior.

Historical USD and BHD wallet credits are never converted or combined. Database amount fields retain their existing integer-thousandths contract (`13000` means USD 13.00 for USD games). New Stripe cancellation refunds return to the original payment method, not the wallet. The ledger retains exact policy amounts; Stripe transfers whole cents with rounding carried across refunds on the same payment. This extension does not add wallet spending.

Use `flutter analyze` and `flutter test` in `mobile`, and `npm test` plus `npm run typecheck` in `referee`. The isolated PostgreSQL fixture checks in `supabase/scripts/test_fieldrush_market.mjs` cover both formats, assignments, policies and wallet isolation. They supplement, rather than replace, a complete local Supabase migration replay and hosted device/payment checks.

Local verification for this extension: 345 Flutter tests, Flutter analysis, 73 admin tests, admin type-checking and production build, 26 Deno tests, and 39 isolated PostgreSQL checks passed. The staging iOS simulator build also passed. Full Supabase migration replay was unavailable because the local Docker daemon was stopped. That run did not exercise real USD checkout or a complete 14-player check-in → match completion → refund journey. The subsequent Stripe branch updates the hosted E2E fixture contract to Phoenix, 14 players and USD13; a hosted run is still required after coordinated deployment.

## Hosted staging setup

The account migration was applied to hosted staging on October 9, 2026 and account loading was verified in the simulator. Deployments do not erase staging or automatically complete onboarding for existing users. For another environment, or to finish optional staging features:

1. Review and apply `supabase/migrations/20261009000000_create_fieldrush_accounts.sql` to **staging only**, after the existing migrations. It deliberately stops if a different PostgREST pre-request hook exists; compose the hooks before deployment rather than overwriting one.
2. Deploy `fieldrush-delete-account`. The function accepts only the exact existing staging project or local Supabase, validates the bearer token through Auth, and then calls an authenticated database RPC. Keep `verify_jwt = false` in its function configuration for ES256 compatibility; this does not remove handler authentication.
3. Add the **server-side** Edge Function secret `FIELDRUSH_ACCOUNT_DELETION_ENABLED=true` when deletion is ready to test. Never put the service-role key or this server setting into mobile environment files.
4. Keep Phone and Google enabled in Supabase Auth. In URL Configuration, allow `com.alialtaraif.field.staging://auth-callback/`. The Google web OAuth client redirects to the project’s Supabase `/auth/v1/callback` URL; Supabase then redirects to the app. The existing bundle IDs remain unchanged.
5. Enable **manual identity linking** in Supabase Auth for Account settings → Connect Google. Google identities already attached to a different account are not silently transferred or merged. Sign into the original phone account and link the unused Google identity there. See [Supabase identity linking](https://supabase.com/docs/reference/dart/auth-linkidentity) and [mobile redirects](https://supabase.com/docs/guides/auth/native-mobile-deep-linking?platform=flutter).
6. Keep the Google consent screen’s permitted test users up to date while the Google project is in testing mode. Test with an actual permitted Google account and a phone that can receive Twilio SMS.

The production callback is separately registered in the binary as `com.alialtaraif.field://auth-callback/`; production activation is **not** part of this branch. Account deletion remains blocked on production by the server guard.

## Email and recovery

Set `EMAIL_DELIVERY_ENABLED=false` in mobile staging configuration for now (it defaults to false). Email is required as a contact field, but collecting it does not prove ownership and does not enable email login or recovery. An email returned and verified by Google is shown as verified only when it matches the saved contact email.

Before enabling email delivery, configure Supabase SMTP, confirm the email-change template supports OTP codes, and test secure email change, old-address confirmation and callback behavior. The UI re-reads server state and never treats sending a message as verification. Changing the compile-time flag requires rebuilding the app.

Recovery currently works through a verified phone or a previously linked Google identity. Replacing a lost phone number still needs the old phone’s OTP in the account UI; a reviewed support or recent-provider reauthentication flow is a separate addition. An unverified email, name or birthday cannot recover an account.

## Deletion behavior

Deletion requires explicit confirmation and recent actual authentication, not merely a refreshed session. Outstanding games, clan ownership, staff access, wallet credit, payments or refunds produce an actionable refusal; deleting an account never silently issues a refund or drops an obligation.

When deletion can proceed, the account is locked, avatar objects are removed through Storage, and Auth credentials and private account rows are deleted. Historical game and payment references retain an anonymized player ID. A failed storage or Auth operation returns a failure and leaves deletion pending for retry or support; it is never reported as success.

Refunds arriving during pending deletion remain allowed. The final database deletion rechecks obligations and refuses deletion if credit has arrived; wallet mutations cannot silently credit an already deleted account. Cleanup of legacy Cloudflare recordings and other historical provider data is separate from this fresh-account foundation.

## Run and verify

From `mobile`, after staging setup:

```sh
flutter pub get
flutter run --flavor staging --dart-define-from-file=.env.staging
```

Mobile `.env.staging` needs `APP_ENV=staging`, the staging `SUPABASE_URL`, and its **publishable** `SUPABASE_PUBLISHABLE_KEY`. Do not copy the root backend secrets into this file.

Run `flutter analyze` and `flutter test` from `mobile`. Account regressions are in `fieldrush_auth_screen_test.dart`, `fieldrush_account_screen_test.dart`, `fieldrush_account_gate_test.dart`, `fieldrush_account_repository_test.dart` and `date_of_birth_onboarding_test.dart`. Database assertions live in `supabase/scripts/verify_fieldrush_accounts.sql` and must run in a rollback-only transaction against local/test infrastructure.

On a simulator or device, verify signup, logout/login, app restart during an incomplete draft, wrong and expired OTP, rate limiting, browser cancellation, Google callback, linking conflicts, phone change and refusal/success paths for deletion. Automated repository and widget tests do not prove hosted Google, Twilio or SMTP configuration.

The hosted player journey uses an injected, integration-test-only OTP transport for its reserved staging bootstrap number. Normal app builds always use real Supabase OTP. E2E actors complete the same server onboarding RPC; only the protected, disposable onboarding actor starts without a public profile. This automated transport does not test real SMS delivery.

For the first transition from the old suite, the existing reserved test accounts may lack protected ownership markers. Setup stops deliberately until an administrator verifies ownership:

- Bootstrap login `+97339009098`: the staging-only login function creates this dedicated fixture with protected `app_metadata.fieldrush_e2e=true` and `app_metadata.fieldrush_e2e_role=bootstrap`. It refuses to reuse an unmarked account. Setup completes its onboarding through the same authenticated RPC as the app. The earlier bootstrap player at `+97338883672` is no longer used by CI.
- Disposable onboarding actor `+97339009100`: set `app_metadata.fieldrush_e2e=true` and `app_metadata.fieldrush_e2e_role=onboarding`, or remove that specific verified test actor so setup can recreate it.

Never use editable `user_metadata` as permission to delete a real account. Subsequent fixture resets require the protected markers and the exact reserved phone. These existing Bahrain-format numbers are isolated legacy test infrastructure, not the new app's default country or market.

### Earlier account-foundation verification (October 9)

All 293 Flutter tests, Flutter analysis, the staging iOS simulator build, 18 CI-listed Deno tests and the new rollback-only database regression passed. Android compilation remains unverified because this machine has no Android SDK. Real hosted SMS, Google OAuth and hosted E2E have not been run for this branch.

Eight existing SQL verifiers passed with real-signup synthetic fixtures inside rollback transactions. `verify_match_resolution_control_plane.sql` still fails with `Same-score clan correction did not restore exactly the explicit Player SR lineup`; the same failure was reproduced on the unchanged baseline without this migration. It is a separate match-resolution issue, not a passing check.

## Fresh data and release boundaries

No old user or game has been deleted. Existing users need to complete the new server-owned account requirements before participating. A fresh staging cutover requires a separate reviewed backup and reset plan; do not apply a destructive reset to the existing project as part of an app build.

The consent links currently open `https://field.bh/terms` and `https://field.bh/privacy`, using acceptance version `fieldrush-v1`. Before onboarding external Fieldrush testers, update and review those published documents for the new market and product. Do not treat the old Bahrain website text as an approved new-market policy.

No Apple login is included, as requested. Check the iOS distribution requirements before public release; this implementation does not establish App Store approval.
