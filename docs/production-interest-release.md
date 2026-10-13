# Production website interest collection

This release enables the already-deployed website to save email-only launch
interest in Field Production's existing private `season_zero_waitlist` table.
The rest of the app stays on its current production version.

The release includes only migration `20261012000600` and a private schema
prerequisite. The migration is byte-for-byte identical to the one tested and
deployed on staging. It retains existing applications and adds two server-only
RPCs, consent metadata, and shared rate limiting. No email is sent.

## Release

After this production commit passes CI, dispatch **Production interest
collection** on `prod` with confirmation `DEPLOY_INTEREST_ONLY`. The isolated
verification job replays only the original three waitlist migrations and the
interest migration, and verifies signup, duplicates, application preservation,
rate limiting, and access controls.

The deploy job uses the existing protected `production` environment. Its human
reviewer must approve it. The script accepts only Field Production, this exact
migration, and the reviewed release invocation. It does not run `db push`,
deploy Edge Functions, change Auth, or activate payments.

Before changes, the script encrypts a scoped snapshot with AES-256-GCM and a
key derived using scrypt from the protected production database password. Only
the encrypted backup is retained as a GitHub artifact for 30 days. No contact
data is logged. Keep the password used for the release available if restoration
is needed; the envelope includes its random salt and IV.

The SQL change and its migration-history entry commit together. The transaction
locks the interest table, checks it still matches the backup, and proves all
existing application fields are unchanged. A changed preimage or unknown
schema fails before commit. Rerunning an already-installed release verifies
its schema and permissions; it does not reapply the migration.

## Website configuration and verification

The Vercel Production environment must have `FIELD_ENVIRONMENT=production`,
`SUPABASE_URL=https://zjsjuuhborxrlmdcpvlj.supabase.co`, and the production
server-only `SUPABASE_SERVICE_ROLE_KEY`. `ALLOW_TEST_LAUNCH_SIGNUPS` should be
false. Preview and development must not receive a production server key.

After deployment, submit a unique controlled test address through the live
form, verify the saved row and original consent/placement, and repeat the
submission to verify one row remains. No email provider is called. Remove only
the exact verification row after recording the result. Check anonymous clients
cannot read the list or invoke either RPC.

View real signups through the Field Production Supabase dashboard for now.
The staging admin remains connected to staging; a production admin rollout is
separate.

## Recovery

If verification fails, keep collected data and correct the specific issue. To
pause collection, disable the website's signup configuration or revoke the
server's execute privilege on the signup RPC. Do not drop new columns, delete
real signups, restore `full_name NOT NULL`, or rewrite applied migration history.
The ordinary app production workflow remains unchanged.
