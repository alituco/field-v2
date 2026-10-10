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

The five verification jobs contain placeholders only and cannot read or
modify a hosted database. The conditional, protected staging jobs receive
staging credentials only after every verification job succeeds on a real
`staging` push. CI infrastructure PRs also boot a secret-free Android emulator
using the same configuration as the protected player journey.

The marketing site is the separate
[`alituco/field-bh`](https://github.com/alituco/field-bh) repository. Its own
workflow runs tests, lint, type-check, and build. Vercel remains its deploy
target.

## Staging deployment

After all five checks succeed on a `staging` push, the conditional
`prepare-staging-e2e` job in the same `CI` run performs the idempotent deployment.
Keeping the deploy on the real `staging` ref makes GitHub's protected
environment branch rule effective. Staging runs are not canceled midway
through a migration. GitHub may replace an older queued run, but the latest
cumulative `staging` tree is always the state that is verified and deployed.

It:

1. accepts only branch `staging` and Field's exact staging ref;
2. dry-runs, applies, and dry-runs migrations again;
3. checks critical tables/RPCs and requires a published reliability policy;
4. deploys the recording/clip functions and staging-only login functions;
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
11. requires deployment/build, Android, browser verification, and cleanup to
    succeed in the final `deploy-staging` gate before recording a successful
    GitHub `staging` deployment for production promotion;
12. builds Field Staging with Xcode 26, signs it for App Store distribution,
    and uploads it to App Store Connect for the `admins` internal TestFlight
    group.

It never resets hosted staging or touches ordinary staging users and games.
E2E records are tagged with the run id. Mutable records are cleaned after every
run; immutable attendance, wallet, reliability, and match audit facts remain
tagged when database policy correctly prevents their deletion. Test logs,
failure screenshots, Playwright reports/traces, and the local referee server
log are retained for seven days. Cross-job APK, manifest, and temporary test
password transfers are authenticated/encrypted with AES-256-GCM using a
run-scoped key derived from the protected staging credential, with one-day
artifact retention. Plaintext fixture credentials are never uploaded.

To retry a failed hosted journey after cleanup, rerun the **Deploy staging and
build player E2E** job (and its dependent jobs), not just Android. This creates
fresh fixtures and a matching APK without rerunning the five successful base
verification jobs. A failed or skipped journey never qualifies for TestFlight,
PWA deployment, or production promotion.

The daily **Staging smoke** repeats the non-mutating hosted check at 05:15 UTC.

`supabase/config.toml` is local-development configuration. Hosted Auth,
network, and provider settings are managed in each Supabase dashboard; a
config-only repository change does not push those dashboard settings.

## Production deployment

Production is manual and protected. From
**Actions → Deploy Supabase production → Run workflow**:

1. select `prod`;
2. type `DEPLOY_PRODUCTION`;
3. verify Supabase backup/PITR availability and type `BACKUP_VERIFIED`;
4. receive approval from the protected `production` GitHub environment.

Before migration, the workflow requires:

- successful CI for the exact `prod` commit;
- a successful staging deployment with the identical Git tree;
- Field's exact production and staging refs;
- the required environment credentials.

The deploy script removes `dev-phone-login` and `dev-switch-user` from the
guarded production project before touching its schema, never deploys them
there, never seeds/resets hosted data, and verifies again after deployment.
The workflow skips recording-function updates until the production Cloudflare
secrets and webhook are ready; then set production variable
`DEPLOY_RECORDING_FUNCTIONS=true`. Setting it to `false` does not delete an
already deployed function.

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
- secrets `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID`, and
  `APP_STORE_CONNECT_PRIVATE_KEY` for the App Store Connect team API key
- secrets `IOS_DISTRIBUTION_CERTIFICATE_BASE64` and
  `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` for the exported Apple Distribution
  identity
- secret `IOS_STAGING_PROVISIONING_PROFILE_BASE64` for the manual
  `Field Staging App Store` provisioning profile

GitHub environment `production`:

- deployment branch restricted to `prod`
- at least one required reviewer
- prevent self-review and admin bypass when the plan supports them
- secret `SUPABASE_ACCESS_TOKEN`
- secret `SUPABASE_DB_PASSWORD` for Field Production
- variable `DEPLOY_RECORDING_FUNCTIONS=false` initially

The Supabase access token is an account-level credential. Generate it under
Supabase account access tokens and store it only in the two protected GitHub
environments. The staging service-role key is required for isolated hosted E2E
setup and server-side referee routes. Keep it only in the protected `staging`
environment; do not add the production service-role key to this CI workflow.

Runtime secrets such as Cloudflare credentials, webhook secrets, and staging
OTP configuration belong in each Supabase project's Edge Function secrets.

The repository default branch is `prod`; `staging` shares the real project
history. Repository settings protect both branches, block force
pushes/deletion, require pull requests, and require these checks:

- `Flutter Android, analyze, and test`
- `Flutter iOS flavor builds`
- `Referee web checks`
- `Broadcaster checks`
- `Supabase schema and behavior`

## Promotion flow

1. Branch from `staging`.
2. Open a pull request into `staging`.
3. Merge only after all five CI jobs pass.
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
- real payment processing (current match payments are still simulated)
- Vercel `field-bh` production env values

For the public waitlist, set Vercel's production `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` from the Field Production project, then redeploy.
Two existing real applications have already been copied to production.
