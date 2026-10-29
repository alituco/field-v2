# Production Android bundle and Google Play

The permanent Android application ID is **`gg.fieldrush.app`**; its installed name
is **Fieldrush**. Staging keeps **`com.field.field.staging`** and its existing
callback/signing behavior. Native production authentication and payment return
URLs use `com.alialtaraif.field://auth-callback/` and
`com.alialtaraif.field://safepay`.

The manual **Build production Android App Bundle** workflow prepares a signed,
validated AAB for the first manual Play Console internal-testing upload. It
does not upload to Google Play, submit a review, or publish the app. Building
successfully and passing binary checks do not qualify real device behavior.

## Protected configuration

Use the existing GitHub `production` environment, restricted to `prod` with its
existing reviewer protections. Add these secrets only there:

- `ANDROID_UPLOAD_KEYSTORE_BASE64`: the protected PKCS12 upload keystore encoded
  as base64; keep a separate protected backup outside Git.
- `ANDROID_UPLOAD_STORE_PASSWORD`
- `ANDROID_UPLOAD_KEY_ALIAS`
- `ANDROID_UPLOAD_KEY_PASSWORD`

Set these public environment variables:

| Variable | Value |
| --- | --- |
| `ANDROID_PRODUCTION_PACKAGE_ID` | `gg.fieldrush.app` |
| `ANDROID_UPLOAD_CERTIFICATE_SHA256` | SHA-256 of the upload certificate, 64 hex digits or colon-separated hex pairs |
| `PRODUCTION_ANDROID_PUSH_NOTIFICATIONS_ENABLED` | `false` |
| `PRODUCTION_EMAIL_DELIVERY_ENABLED` | `true` only after production email qualification; otherwise `false` |

The workflow reuses the production Supabase project/public client key variables
and protected `STRIPE_PUBLISHABLE_KEY` live client key. Server keys, provider
service-account JSON, private certificates and login codes must never become
Flutter defines, source files, logs or artifacts.

The Gradle production release uses the upload identity supplied by the protected
builder. A generic secret-free CI production release is unsigned; production
never falls back to a debug key. The protected build rejects missing/partial
signing credentials and verifies the final signer against the pinned certificate.
Temporary key/password files and raw command logs are deleted on exit. Failed
commands can print only a bounded, credential-redacted diagnostic tail; raw logs
are never uploaded as artifacts.

## Release sequence

1. Review changes into `staging`; complete the full push CI and hosted player/admin
   journeys. Promote that identical successful tree into `prod`.
2. Complete exact-commit prod CI and the protected production backend deployment.
   Read-only health and anonymous privacy checks must pass. Existing release
   evidence is checked before and again after production environment approval;
   a previous successful deployment of different code does not qualify this SHA.
3. Dispatch **Build production Android App Bundle** from `prod`, entering
   `BUILD_PRODUCTION_ANDROID` and `PRODUCTION_BACKEND_READY_FOR_ANDROID` after
   checking the asserted provider/backend readiness.
4. Download its seven-day artifact. It contains only the signed `.aab`,
   `SHA256SUMS` and public `release.json`. Version name comes from
   `mobile/pubspec.yaml`; version code is `workflow run number × 100 + attempt`.
   Attempts must be 1–99 and remain below Play's version-code limit. Start a new
   run after a newer successful Android build; do not rerun an older version.
5. In the verified FieldRush LLC Play Console organization, create the app and
   use Play App Signing. Google may generate/manage the separate app-signing
   key; this workflow's key authorizes uploads. Confirm the permanent package
   before the first upload. Upload the AAB to internal testing first.
6. Install the Play-delivered build on a real Android device and qualify phone
   and email authentication, recovery, Google sign-in/link, account deletion,
   booking, live payments, authorized original-method refunds, and every enabled
   feature. Test the actual enabled flow; staging fixtures/mock results and
   successful iPhone tests do not prove these Android outcomes.
7. Complete the Android store assets, Data Safety/content declarations, account
   deletion URL and reliable reviewer access. Select the qualified build and
   submit for review; release only when operations are ready.

The builder pins Flutter **3.44.1**, Android Build Tools **36.0.0**, and official
Google bundletool **1.18.3**, whose download is checked against its pinned SHA-256.
It verifies the AAB format/signature/certificate, final package/version,
target SDK at least **36**, nondebuggable manifest and production callback
schemes. It checks native ELF layout, the AAB's requested 16 KB packaging, and
the ZIP alignment/signature of a generated universal APK. These are binary
layout checks; runtime testing on a 16 KB device/emulator remains necessary.
See [Google's page-size guide](https://developer.android.com/guide/practices/page-sizes)
and [bundletool documentation](https://developer.android.com/tools/bundletool).

## Android-specific provider qualification

Google OAuth and Google Pay retain their existing product configuration. Verify
production Google OAuth credentials/consent and the browser-to-app callback
before submission. Native Google Pay uses US/USD and the production Stripe key;
check the status of its separate Google production-access request, using the
Gateway integration and required screenshots, then test a signed release on a
physical Android device. This document does not establish that approval was
granted or rejected. See [Stripe's Android Google Pay setup](https://docs.stripe.com/google-pay?platform=android).

Android push is deliberately off and is independent of the iOS rollout switch.
Enabling it later requires a distinct production Android Firebase registration,
matching public app ID/API key/package, backend readiness and real device opt-in,
delivery, account-switch and opt-out qualification. Do not reuse a staging app ID
or assume the iOS API key has suitable Android restrictions. See
[production push](production-push.md).

The upload certificate and Google's app-signing certificate are separate. Use
the **Play app-signing** certificate fingerprints when a production API/provider
requires the identity of the app installed from Google Play.
