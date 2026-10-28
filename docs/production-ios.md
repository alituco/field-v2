# Production iOS build and upload

The production App Store Connect record is **Fieldrush: Pickup Soccer**,
Apple ID **6827873998**, Bundle ID **com.alialtaraif.field**, and Apple team
**69B646V2WM**. The installed app display name remains **Fieldrush**.

The manual **Upload production iOS to TestFlight** workflow builds, signs,
validates and uploads that app. It does not submit the app to App Review or
publish it. The first internal TestFlight build is for production qualification.
Real-device checks and the store listing/review declarations are required before App Review;
a TestFlight upload does not assert those checks have already passed.

## Prerequisites

Use the protected GitHub `production` environment, restricted to branch `prod`,
with its existing reviewer rules. Configure these environment variables:

| Variable | Required value |
| --- | --- |
| `APPLE_TEAM_ID` | `69B646V2WM` |
| `IOS_PRODUCTION_BUNDLE_ID` | `com.alialtaraif.field` |
| `PRODUCTION_EMAIL_DELIVERY_ENABLED` | `true` only after production SMTP/Auth and real inbox checks; otherwise `false` |
| `PRODUCTION_PUSH_NOTIFICATIONS_ENABLED` | `true` only after production Firebase/APNs/backend/device qualification; otherwise `false` |

The existing repository variables `PRODUCTION_SUPABASE_PROJECT_REF` and
`PRODUCTION_SUPABASE_PUBLISHABLE_KEY` must identify Field Production. The mobile
build accepts only a publishable key or a legacy production `anon` JWT, never a
secret/service-role key.

Required protected production secrets:

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY` (downloaded `.p8` contents)
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64` (Apple Distribution `.p12`)
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_PRODUCTION_PROVISIONING_PROFILE_BASE64`
- `STRIPE_PUBLISHABLE_KEY` (the production `pk_live_…` public key)

An existing valid Apple Distribution identity and App Store Connect API key may
be reused if they authorize this team/app. GitHub cannot reveal existing secret
values; use the securely held originals when configuring another environment.
Never commit credentials or attach them to review artifacts.

Create an App Store distribution profile named **Fieldrush Production App Store**
for the production Bundle ID. Enable Apple Pay and assign
**merchant.com.alialtaraif.fieldrush.production**. If phone push will be enabled, also
enable Push Notifications and regenerate the profile with production APNs.
The uploader validates profile identity, expiration, distribution type and
entitlements before importing the signing certificate.

Production uses its own Apple Pay merchant and processing certificate so the
staging merchant `merchant.com.alialtaraif.fieldrush` can retain its active
certificate. Obtain the production payment-processing CSR from the intended
live Stripe account, issue the certificate for the production merchant, and
upload that certificate back to the same live account. Never replace staging's
certificate to activate production. The production workflow passes the isolated
merchant to Flutter's `APPLE_MERCHANT_ID` client setting; staging keeps its
existing merchant and build settings.

## Phone push opt-in

When production push is qualified, set these **public client configuration**
variables in the production environment:

- `PUSH_FIREBASE_API_KEY`
- `PUSH_FIREBASE_PROJECT_ID`
- `PUSH_FIREBASE_SENDER_ID`
- `PUSH_FIREBASE_IOS_APP_ID` for the registered production iOS Firebase app

The uploader passes `PUSH_FIREBASE_IOS_BUNDLE_ID=com.alialtaraif.field`
explicitly. A staging Firebase app ID, mismatched sender, or missing configuration
blocks a push-enabled build. APNs `.p8` keys and Firebase service-account
credentials are server/provider secrets and must never enter Flutter defines.

The default production native configuration includes Apple Pay only. A
push-enabled upload selects `Info-production-push.plist` and
`Runner-production-push.entitlements` through Runner-only build settings, leaving
Pods settings alone. Firebase Messaging auto-init stays disabled until in-app
consent. Both the archive and exported IPA are checked for production identity,
Apple Pay, expected version/build, callback scheme, and the requested push mode.

## Dispatch

1. Qualify the reviewed staging tree through full CI and the hosted player/admin
   journeys, then promote that identical tree to `prod`.
2. Complete CI and the protected production backend deployment for the exact
   `prod` commit. Check production health, intended authentication/privacy
   boundaries, actual SMS/email delivery, live Stripe account/webhook settings,
   deletion configuration and the other services enabled for this build. These
   are readiness checks for internal testing, not a claim that a real payment,
   refund or account deletion has already been exercised.
3. In **Actions → Upload production iOS to TestFlight → Run workflow**, select
   `prod`, enter `BUILD_PRODUCTION_IOS`, and enter
   `PRODUCTION_BACKEND_READY_FOR_TESTFLIGHT` after those readiness checks.
4. Approve the protected production environment when requested. The workflow
   repeats the exact release-evidence gate and read-only production health/privacy
   smoke check before signing. It never grants anonymous access to satisfy a probe.
5. Wait for App Store Connect processing, then assign the production build only
   to the intended internal TestFlight testers. Qualify the actual build on real
   devices: phone/email login and recovery, a deliberately authorized live payment
   and original-method refund, account deletion and its safeguards, staff
   operations, and every enabled recording/notification feature. Use genuine
   operator-owned accounts and real operational data; do not seed fake production
   games or claim mock tests prove live outcomes.
6. Complete these live checks, final privacy/age declarations, screenshots and
   reliable reviewer access before selecting the qualified build for App Review.
   TestFlight readiness is not App Review approval or permission to publish.

The workflow checks exact-commit CI and production backend deployment plus an
identical successful staging deployment before requesting production access and
again after approval. Xcode 26+ and Flutter 3.44.1 are required. Build numbers are
derived from this workflow's run number and attempt. Trigger a new run after
99 attempts. Rerunning an older workflow after a newer successful production
upload is rejected before signing, including after environment approval. Do not
reuse this numbering scheme outside this workflow; a separate manual upload
with a higher build number still requires reconciling the App Store Connect
version/build history before this pipeline can upload again.

The run summary records whether email delivery and phone push were compiled in.
Do not describe a disabled/unqualified feature as available in the store listing.
Before App Review, verify the archive's SDK privacy manifests/privacy report,
complete Apple privacy and age-rating declarations, and provide reviewer access
that does not require waiting for a personal SMS or a scheduled match.

For failures, only build/export/upload logs are retained for seven days. Signing
files, API keys and the temporary keychain are removed by the uploader's cleanup;
they are never uploaded as artifacts.
