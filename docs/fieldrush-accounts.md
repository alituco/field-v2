# Fieldrush account setup

This foundation replaces the mobile app’s signup and account entry flow with the supplied Fieldrush design. It supports phone OTP and Google, requires a verified phone and an adult birthday, and keeps account identity separate from public player profiles. Games, payments, rankings, the main Home screen and the website remain outside this design phase.

## What is implemented

- Native cream and forest onboarding with the prototype’s bundled Outfit and Plus Jakarta Sans fonts, welcome artwork, international country picker defaulting to US +1, OTP entry, personal details, username availability and review.
- Real Supabase phone OTP and browser Google OAuth. Login and recovery do not create a new phone account. Google signup must add and verify a phone on the same authenticated account.
- Server-persisted onboarding drafts. Completion is authoritative database state, never an editable auth metadata flag.
- Private first name, last name, birthday and contact email. Public names are first name plus last initial, for example `Alex R.`. Public profile queries cannot read phone or birthday.
- Unique lowercase usernames of 3–20 letters, digits, dots or underscores. Reserved staff, brand and technical names include separator-obfuscated and numeric-suffix variants; ordinary names such as `devin` remain usable.
- Backend 18+ validation, versioned Terms and Privacy acceptance, and a persisted signup handoff. The full Home coachmark tour belongs to the later Home redesign.
- Account settings, Google linking, verified phone change, recovery and guarded deletion. Birthday corrections after signup require support.

## Hosted staging setup

The local code does not deploy itself, erase staging or migrate existing users automatically. Before running this branch against hosted staging:

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

- Bootstrap login `+97338883672`: set `app_metadata.fieldrush_e2e=true` and `app_metadata.fieldrush_e2e_role=bootstrap`. Setup completes its onboarding through the same authenticated RPC as the app.
- Disposable onboarding actor `+97339009100`: set `app_metadata.fieldrush_e2e=true` and `app_metadata.fieldrush_e2e_role=onboarding`, or remove that specific verified test actor so setup can recreate it.

Never use editable `user_metadata` as permission to delete a real account. Subsequent fixture resets require the protected markers and the exact reserved phone. These existing Bahrain-format numbers are isolated legacy test infrastructure, not the new app's default country or market.

### Local verification on this branch

All 293 Flutter tests, Flutter analysis, the staging iOS simulator build, 18 CI-listed Deno tests and the new rollback-only database regression passed. Android compilation remains unverified because this machine has no Android SDK. Real hosted SMS, Google OAuth and hosted E2E have not been run for this branch.

Eight existing SQL verifiers passed with real-signup synthetic fixtures inside rollback transactions. `verify_match_resolution_control_plane.sql` still fails with `Same-score clan correction did not restore exactly the explicit Player SR lineup`; the same failure was reproduced on the unchanged baseline without this migration. It is a separate match-resolution issue, not a passing check.

## Fresh data and release boundaries

No old user or game has been deleted. Existing users need to complete the new server-owned account requirements before participating. A fresh staging cutover requires a separate reviewed backup and reset plan; do not apply a destructive reset to the existing project as part of an app build.

The consent links currently open `https://field.bh/terms` and `https://field.bh/privacy`, using acceptance version `fieldrush-v1`. Before onboarding external Fieldrush testers, update and review those published documents for the new market and product. Do not treat the old Bahrain website text as an approved new-market policy.

No Apple login is included, as requested. Check the iOS distribution requirements before public release; this implementation does not establish App Store approval.
