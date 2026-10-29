# Fieldrush production launch

Production setup, a successful build, a TestFlight upload, App Review approval,
and public release are separate milestones. Use this checklist with the
protected deployment history and real-device evidence.

## Resource identities

| Resource | Production identity |
| --- | --- |
| App Store app | Fieldrush: Pickup Soccer, Apple ID `6827873998` |
| Installed iOS app name | Fieldrush |
| iOS Bundle ID | `com.alialtaraif.field` |
| Android application ID | `gg.fieldrush.app` |
| Apple team | `69B646V2WM` |
| Apple Pay merchant | `merchant.com.alialtaraif.fieldrush.production` |
| Distribution profile | Fieldrush Production App Store |
| Supabase project | Field Production, `zjsjuuhborxrlmdcpvlj` |
| Firebase project | Fieldrush Production, `fieldrush-production` |
| Firebase iOS app | `1:399491660668:ios:3c3f530cba58ba30d5c2f9` |
| Firebase sender | `399491660668` |
| Production push service account | `fieldrush-push-dispatch@fieldrush-production.iam.gserviceaccount.com` |
| Stripe account | FieldRush LLC, `acct_1UKqAfPlKLuHSd4J` |
| GitHub environment / release branch | `production` / `prod` |

Staging uses separate Supabase and Firebase projects and separate native app
identities. Never copy test users, fake games, balances, developer login routes,
or staging-only callback URLs into production.

The dedicated production push account uses the Firebase Cloud Messaging API
role on the production Firebase project. Its server credential is held only in
restricted local setup storage and production Supabase Edge secrets; public
Firebase app configuration is supplied separately to mobile builds. Production
push switches remain off until the rollout and device checks in
[production push](production-push.md) are complete.

## Store listing

The production listing uses version `1.0.0`, the Sports category, and subtitle
`Find games. Play. Get ranked.`. Keep its screenshots and descriptions aligned
with the features actually available in the submitted production build.

Verified public resources:

- Website: <https://www.fieldrush.gg>
- Support/contact: <https://www.fieldrush.gg/about>
- Privacy: <https://www.fieldrush.gg/privacy>
- Account/data/recording requests: <https://www.fieldrush.gg/legal>
- Terms: <https://www.fieldrush.gg/terms>
- Recording policy: <https://www.fieldrush.gg/recording>

The app targets adults aged 18+. Its privacy and age declarations must account
for profiles, public avatars/bios and clips, following, reports/support, match
statistics, purchases/refunds, notification identifiers, recording/streaming,
and any enabled prize/referral features. Absence of an analytics SDK does not
mean that the app collects no data. Reconcile the final build, provider SDKs,
live privacy policy, and operator practices before publishing declarations.

Prepare real production screenshots, review contact details, and reliable
reviewer access to the principal app functions. Native iOS currently uses phone
sign-in; Google sign-in/link buttons are intentionally hidden there. Reviewer
access must not enable staging developer authentication in production or rely
on an operator forwarding a personal SMS.

Choose manual App Store release so that publication can follow completed
production qualification and Apple approval.

## Authentication and operations

The production Auth site URL is `https://www.fieldrush.gg`; the native callback
allowlist must include exactly `com.alialtaraif.field://auth-callback/`.
Configure actual production SMS/SMTP credentials with their providers. Provider
secrets returned by management configuration reads may be redacted/digested;
never copy those representations as working credentials.

Verify phone signup/login, wrong/expired OTP, throttling, restart recovery,
contact-email verification/change, logout, and account deletion with the final
build. Keep `PRODUCTION_EMAIL_DELIVERY_ENABLED=false` until SMTP/Auth templates
and real inbox delivery pass. Deletion separately requires the exact production
runtime and `FIELDRUSH_ACCOUNT_DELETION_ENABLED=true`; recent authentication,
outstanding obligations, and anonymization rules continue to apply.

Provision genuine production staff access, policies, venues, prices and games.
Configure production admin hosting and recording/streaming services used at
launch. Check backup availability immediately before migrations. A completed
daily backup and PITR are different capabilities; do not claim PITR is enabled
merely because a daily backup exists.

## Payment and release sequence

1. Configure live Stripe keys, expected account ID, exact production webhook and
   safe worker secret in the protected production environment. Confirm native
   Apple Pay processing credentials belong to the intended Stripe account.
2. Review and merge setup changes through staging. Complete full staging push
   CI, hosted player/admin journeys, and the explicit verified release record.
3. Promote the identical reviewed tree into `prod`, then pass exact-commit CI.
4. Use the protected [backend deployment](../.github/DEPLOYMENT.md) with
   `DEPLOY_PRODUCTION`, `BACKUP_VERIFIED`, and `LIVE_STRIPE_READY` only when each
   assertion is true. The live account/webhook preflight precedes mutations.
5. Check production health, authentication/privacy boundaries, actual SMS/email
   delivery, live Stripe account/webhook settings, deletion configuration and
   other services enabled for internal testing.
6. Use the protected [production iOS upload](production-ios.md) to obtain the
   internal TestFlight qualification build. Then qualify that actual build on
   real devices: phone/email login and recovery, a deliberately authorized live
   payment and original-method refund, deletion and its safeguards, staff
   operations, and enabled recording/notification features. Local/mock tests
   and readiness probes do not establish those live outcomes.
7. Finish those live checks plus store assets/declarations and reliable reviewer
   access before selecting the exact qualified build for App Review. Publish
   manually after Apple approval when operations are ready. The first internal
   TestFlight upload does not submit the app or make it public.

Signing and server credentials belong outside this repository. Local setup
material is stored under `$HOME/.config/fieldrush/production/` with restricted
directory/file permissions; GitHub receives signing/deploy credentials only in
its protected `production` environment. Never attach private keys, provider
secrets, phone codes, credential snapshots or fixture passwords to a pull request
or CI artifact.
