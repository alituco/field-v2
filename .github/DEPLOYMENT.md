# Field environments and delivery

Field has three isolated Supabase environments:

| Environment | Data | App build | Branch |
| --- | --- | --- | --- |
| Local | Disposable Docker data | Staging flavor with `APP_ENV=local` | Any |
| Staging | Fake players and test scenarios | Staging flavor/ribbon | `staging` |
| Production | Real Field data only | Production flavor, no ribbon | `prod` |

The exact hosted projects are guarded in the app and deployment scripts. A
mistyped ref, lookalike hostname, flavor mismatch, or `DEV=true` production
build fails closed.

## Automated checks

`CI` runs for pull requests and pushes to `staging` and `prod`:

- Flutter analysis and tests
- Android staging debug and production release builds
- iOS staging simulator build and unsigned production release build
- referee/admin type-check, tests, and production build
- broadcaster dependency install and syntax check
- Deno formatting/type-checks for every Edge Function
- Deno formatting/type-checks for every local seed/reset/verifier script
- all migrations replayed on a fresh local Supabase stack
- database lint at error severity
- a local integration scenario covering concurrent final-spot booking,
  no-waitlist enforcement, capacity limits, policy-backed cancellation,
  wallet refund, and `FULL` to `OPEN`
- fake-data seeding from an empty local database
- rollback-only reliability, moderation, support, and clan-forfeit contracts
- a protected hosted-staging Android journey covering onboarding, solo booking,
  party invitations, cancellation, reports, and support
- a protected hosted-staging referee/admin browser journey covering attendance
  correction, full check-in, kickoff, a goal, full-time, and the moderation and
  support inboxes
- a signed staging iOS build uploaded to TestFlight after every successful
  hosted-staging deployment and E2E run

Fast deployment/workflow contract tests run before any expensive jobs. The six
verification jobs use placeholders only and cannot access hosted data. On a
`staging` push, protected backend deployment starts after fast contracts, Flutter
analysis/tests, and database verification; Android/iOS flavor builds run in
parallel. The final release gate still requires every verification and hosted
journey to succeed. CI infrastructure PRs also boot a secret-free Android emulator.

PRs select relevant checks from changed paths: referee-only changes do not build
iOS/Android, native-platform changes check that platform, and mobile test-only
changes run Flutter tests. An exact allowlist of CI/deploy files covered by the
fast contract suite does not rebuild unchanged apps on the PR; the full staging
push tests the release pipeline once after merge. Backend, other workflow/native
tooling, shared, or unrecognized changes conservatively run all baseline checks.
Every staging push runs the full release
plan. Intentionally skipped checks are distinguished from failures by the required
aggregate gate; a skipped required check is a failure.

The marketing site is the separate
[`alituco/field-bh`](https://github.com/alituco/field-bh) repository. Its own
workflow runs tests, lint, type-check, and build. Vercel remains its deploy
target.

## Staging deployment

After fast contracts, Flutter tests, and database checks pass, `backend-staging`
deploys and smoke-tests the backend. `prepare-staging-e2e` then creates fixtures
and builds the player APK, without waiting for the parallel native flavor builds.
Keeping the deploy on the real `staging` ref makes GitHub's protected
environment branch rule effective. Staging runs are not canceled midway
through a migration. GitHub may replace an older queued run, but the latest
cumulative `staging` tree is always the state that is verified and deployed.

It:

1. accepts only branch `staging` and Field's exact staging ref;
2. dry-runs, applies, and dry-runs migrations again;
3. checks critical tables/RPCs and requires a published reliability policy;
4. deploys Stripe and recording/clip functions plus staging-only login functions;
   retired payment secrets are removed only if present, with absence verified;
5. runs a read-only hosted health/schema smoke;
6. proves private waitlist and policy tables return explicit authorization
   failures to anonymous users;
7. creates a uniquely tagged, isolated E2E account and match fixture;
8. builds the player-journey APK, then runs it without recompilation on a fresh
   Android runner with a 2 GiB userdata partition and a disk-space check after
   SDK installation and AVD creation, immediately before boot;
9. runs referee and admin workflows against a local production build connected
   to hosted staging;
10. verifies the resulting database state and removes mutable test fixtures;
11. requires every baseline check, deployment, Android/browser journey, and
    inline cleanup to succeed in `deploy-staging`; a separate staging-push-only
    job records the verified deployment (PR jobs have no deployment-write token);
12. builds Field Staging with Xcode 26, signs it for App Store distribution,
    and uploads it to App Store Connect for the `admins` internal TestFlight
    group.

It never resets hosted staging or touches ordinary staging users and games.
E2E records are tagged with the run id. Started jobs clean mutable records inside
their existing approval: preparation on failure, Android on failure or completion
of player-only diagnostics, and browser always. Cleanup can recover the encrypted
manifest after dependency setup or normal restoration fails. It does not need a
separate deployment approval. A hard runner termination or cancellation between
protected jobs can still prevent cleanup; the next approved preparation recovers
stale tagged state. The encrypted handoff also remains available for approved
manual cleanup for one day. Immutable attendance, wallet, reliability, and match audit facts remain
tagged when database policy correctly prevents their deletion. Test logs,
failure screenshots, Playwright reports/traces, and the local referee server
log are retained for seven days. Cross-job APK, manifest, and temporary test
password transfers are authenticated/encrypted with AES-256-GCM using a
run-scoped key derived from the protected staging credential, with one-day
artifact retention. Plaintext fixture credentials are never uploaded.

### Short feedback loop

Before pushing CI/deploy edits, run the same credential-free contract suite locally:

```sh
bash .github/scripts/check-ci.sh
```

For a focused hosted retry, choose **Actions → CI → Run workflow → staging**:

| Mode | What runs | Native flavor builds / publishing |
| --- | --- | --- |
| `backend` | Contracts, deploy, hosted smoke; no fixtures | Neither |
| `player` | Contracts, Flutter tests, DB verification, deploy, fresh Android player journey, cleanup | Neither |
| `journey` | Player scope plus referee checks and sequential browser journey | Neither |
| `full` | All baseline checks and hosted journeys | Builds, but no publishing |

For example:

```sh
gh workflow run ci.yml --ref staging -f mode=backend
gh workflow run ci.yml --ref staging -f mode=player
```

These commands are alternatives; run only the scope needed. Diagnostics use the
reviewed commit selected on `staging`, never arbitrary unmerged candidate code,
and retain the protected environment approval. They share the automatic staging
run's concurrency lock, so shared test accounts/migrations cannot overlap. A queued
diagnostic waits for an active staging run; never cancel a migration to jump ahead.

For an unchanged commit, GitHub's rerun-job option avoids repeating successful
prerequisites. After fixture cleanup, restart **Prepare and build staging player
E2E** with its dependents, not Android alone. New fixtures require a new APK because
run IDs, game IDs, and credentials are compiled into it. Dependency caches are
reused; fixture-bearing APKs are not reused across new runs. Reruns use the original
commit, so a code fix needs a new staging commit/run. A diagnostic, failed journey,
or skipped required check never qualifies for TestFlight/PWA or production promotion.

Keep manual staging testing separate from the reserved `field_e2e_*` CI accounts.
Before new fixtures are created, setup checks that their checkout leases are clear.
Cleanup expires only unpaid, expired `LEGACY` attempts belonging to protected test
accounts and cancelled, admin-owned, tagged E2E games; it keeps the payment history
and an admin audit event. Stripe, captured, linked, or ordinary-game attempts are
left untouched and reported for explicit reconciliation, not silently discarded.

The daily **Staging smoke** repeats the non-mutating hosted check at 05:15 UTC.

`supabase/config.toml` is local-development configuration. Hosted Auth,
network, and provider settings are managed in each Supabase dashboard; a
config-only repository change does not push those dashboard settings.

Phone push notifications have a separate, default-off staging setup and device
qualification gate. Deploying the push worker does not activate it, install a
Firebase service-account credential or enable the mobile build flag. See
[notification setup and privacy safeguards](../docs/notifications.md) before
configuring Firebase/APNs, staging signing profiles, Vault or delivery switches.

## Production deployment

Production is manual and protected. From
**Actions → Deploy Supabase production → Run workflow**:

1. select `prod`;
2. type `DEPLOY_PRODUCTION`;
3. verify Supabase backup/PITR availability and type `BACKUP_VERIFIED`;
4. confirm the coordinated live Stripe cutover with `LIVE_STRIPE_READY`;
5. receive approval from the protected `production` GitHub environment.

Before migration, the workflow requires:

- successful CI for the exact `prod` commit;
- the explicit verified staging release record with the identical Git tree and
  completed successful full staging push CI, including hosted journeys;
- Field's exact production and staging refs;
- the required environment credentials and live Stripe account/webhook preflight.

The deploy script removes `dev-phone-login`, `dev-switch-user`, and
`staging-admin-session` from the
guarded production project before touching its schema, never deploys them
there, never seeds/resets hosted data, and verifies again after deployment.
The workflow skips recording-function updates until the production Cloudflare
secrets and webhook are ready; then set production variable
`DEPLOY_RECORDING_FUNCTIONS=true`. Setting it to `false` does not delete an
already deployed function.

The live Stripe account must match `STRIPE_ACCOUNT_ID`, have charges and payouts
enabled, and use the exact production webhook URL/API version. All live provider
checks run before Supabase mutations. The deployment installs matching payment
handlers, the recovery worker, and default-off deletion/push handlers. Account
deletion and phone notifications still require their own explicit runtime
activation and qualification.

See [production iOS](../docs/production-ios.md) for protected signing and
TestFlight uploads, [production push](../docs/production-push.md) for isolated
Firebase/APNs setup, and [production launch](../docs/production-launch.md) for
the store record and remaining operational checks.

Migrations are forward-only. If a release fails after a migration, preserve
data and ship a corrective migration; never use `db reset` or rewrite applied
production migration history. For data-changing migrations, confirm the
project's backup/PITR state before typing `BACKUP_VERIFIED`.

## GitHub configuration

Repository variables:

| Variable | Value |
| --- | --- |
| `STAGING_SUPABASE_PROJECT_REF` | `nfdkdhdevpstfspazbfn` |
| `PRODUCTION_SUPABASE_PROJECT_REF` | `zjsjuuhborxrlmdcpvlj` |
| `STAGING_SUPABASE_PUBLISHABLE_KEY` | Staging public publishable key |
| `PRODUCTION_SUPABASE_PUBLISHABLE_KEY` | Production public publishable key |

GitHub environment `staging`:

- deployment branch restricted to `staging`
- one required reviewer before deployment credentials are released
- secret `SUPABASE_ACCESS_TOKEN`
- secret `SUPABASE_DB_PASSWORD` for Field Staging
- secret `SUPABASE_SERVICE_ROLE_KEY` for Field Staging, used only by the
  protected E2E fixture/verifier and the local referee server
- variable `APPLE_TEAM_ID=69B646V2WM`
- variable `IOS_STAGING_BUNDLE_ID=com.alialtaraif.field.staging`
- variable `TESTFLIGHT_INTERNAL_GROUP=admins`
- secret `SUPABASE_PUBLISHABLE_KEY` for the staging app build
- secrets `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY` from Stripe sandbox
- secret `STRIPE_WEBHOOK_SECRET` for the staging payment webhook
- secret `STRIPE_RECONCILE_SECRET`, a randomly generated 32+ character worker key
- variable `STRIPE_WEBHOOK_ENDPOINT_ID` for that sandbox webhook
- secrets `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID`, and
  `APP_STORE_CONNECT_PRIVATE_KEY` for the App Store Connect team API key
- secrets `IOS_DISTRIBUTION_CERTIFICATE_BASE64` and
  `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` for the exported Apple Distribution
  identity
- secret `IOS_STAGING_PROVISIONING_PROFILE_BASE64` for the manual
  `Field Staging App Store` provisioning profile

The profile must include the Apple Pay merchant
`merchant.com.alialtaraif.fieldrush`. See [Stripe payments](../docs/stripe-payments.md)
for event subscriptions and testing. The deployment configures a five-minute
Supabase cron worker with its credential stored in Vault. It enables the verified
sandbox webhook after deploying its handler. Production uses its own live keys,
expected account/webhook, explicit cutover confirmation, and protected release
gates; staging setup does not activate production processing.

GitHub environment `production`:

- deployment branch restricted to `prod`
- at least one required reviewer
- prevent self-review and admin bypass when the plan supports them
- secret `SUPABASE_ACCESS_TOKEN`
- secret `SUPABASE_DB_PASSWORD` for Field Production
- secrets `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY` from the live account
  (`rk_live_…` or `sk_live_…`, and `pk_live_…`). Prefer a restricted backend key
  with Accounts read, Payment Intents write, Charges and Refunds write, and
  Webhook Endpoints write. Both server key formats must pass the same live
  account and exact production webhook checks before deployment.
- secret `STRIPE_WEBHOOK_SECRET` for the exact production Stripe webhook
- secret `STRIPE_RECONCILE_SECRET`, 32–512 base64url/hex-safe characters
  (`A–Z`, `a–z`, `0–9`, `_`, `-`); `openssl rand -hex 32` is suitable
- variables `STRIPE_ACCOUNT_ID` and `STRIPE_WEBHOOK_ENDPOINT_ID` for that live
  account and webhook
- variable `DEPLOY_RECORDING_FUNCTIONS=false` initially

The production iOS workflow additionally needs the protected signing/API secrets
and public client variables listed in [production iOS](../docs/production-ios.md).
Private signing keys and server credentials never belong in Flutter defines or
repository files.

The Supabase access token is an account-level credential. Generate it under
Supabase account access tokens and store it only in the two protected GitHub
environments. The staging service-role key is required for isolated hosted E2E
setup and server-side referee routes. Keep it only in the protected `staging`
environment; do not add the production service-role key to this CI workflow.

Runtime secrets such as Cloudflare credentials, webhook secrets, and staging
OTP configuration belong in each Supabase project's Edge Function secrets.

The repository default branch is `prod`; `staging` shares the real project history.
Recommended branch protection requires **Required checks and staging release gate**
and blocks force pushes/deletion. This always-reported aggregate validates every
check selected by the change plan, including intentional skips; do not require an
obsolete renamed job. These workflow changes do not modify repository protection
or environment reviewer settings.

## Promotion flow

1. Branch from `staging`.
2. Open a pull request into `staging`.
3. Merge only after the required check plan passes.
4. Approve the protected staging deployment.
5. Wait for the staging deployment, Android journey, and referee/admin browser
   journey to pass.
6. Wait for App Store Connect to process the automatically uploaded staging
   build. Members of the `admins` internal group receive it through TestFlight.
7. Review the seven-day failure artifacts when the protected E2E or TestFlight
   gate fails.
8. Promote the tested staging tree into `prod` through review.
9. Wait for CI on the resulting `prod` commit.
10. Dispatch production. The workflow accepts a different merge SHA only when
   its complete Git tree is identical to the successfully deployed staging
   tree.

Keep migrations backward-compatible with the currently released mobile app.
Add new schema/API behavior before removing old behavior.

## Remaining account-level launch setup

Code cannot configure these safely:

- production Auth site URL, redirect allow-list, and SMS provider
- the first real production admin/referee account
- production Cloudflare Stream secrets and webhook
- production Stripe live processing and original-payment-method refund verification
- Vercel `field-bh` production env values

For the public waitlist, set Vercel's production `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` from the Field Production project, then redeploy.
Two existing real applications have already been copied to production.
