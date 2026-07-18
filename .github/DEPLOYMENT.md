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

The five verification jobs contain placeholders only and cannot read or
modify a hosted database. Only the conditional, protected `deploy-staging`
job receives staging credentials, and only after every verification job
succeeds on a real `staging` push.

The marketing site is the separate
[`alituco/field-bh`](https://github.com/alituco/field-bh) repository. Its own
workflow runs tests, lint, type-check, and build. Vercel remains its deploy
target.

## Staging deployment

After all five checks succeed on a `staging` push, the conditional
`deploy-staging` job in the same `CI` run performs the idempotent deployment.
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
7. records a successful GitHub `staging` deployment for production promotion.

It never resets or seeds hosted staging. The daily **Staging smoke** repeats
the non-mutating hosted check at 05:15 UTC.

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
- secret `SUPABASE_ACCESS_TOKEN`
- secret `SUPABASE_DB_PASSWORD` for Field Staging

GitHub environment `production`:

- deployment branch restricted to `prod`
- at least one required reviewer
- prevent self-review and admin bypass when the plan supports them
- secret `SUPABASE_ACCESS_TOKEN`
- secret `SUPABASE_DB_PASSWORD` for Field Production
- variable `DEPLOY_RECORDING_FUNCTIONS=false` initially

The Supabase access token is an account-level credential. Generate it under
Supabase account access tokens and store it only in the two protected GitHub
environments. Service-role keys are deliberately not stored in this
repository's Actions settings.

Runtime secrets such as Cloudflare credentials, webhook secrets, and staging
OTP configuration belong in each Supabase project's Edge Function secrets.

The repository default branch is `prod`; `staging` shares the real project
history. After the first workflow run, protect both branches, block force
pushes/deletion, and require these checks:

- `Flutter Android, analyze, and test`
- `Flutter iOS flavor builds`
- `Referee web checks`
- `Broadcaster checks`
- `Supabase schema and behavior`

## Promotion flow

1. Branch from `staging`.
2. Open a pull request into `staging`.
3. Merge only after all five CI jobs pass.
4. Wait for the staging deployment and smoke test.
5. Test the staging app and admin/referee experience.
6. Promote the tested staging tree into `prod` through review.
7. Wait for CI on the resulting `prod` commit.
8. Dispatch production. The workflow accepts a different merge SHA only when
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
