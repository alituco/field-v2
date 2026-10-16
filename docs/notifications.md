# Fieldrush notifications

The player app keeps recipient-owned Activity receipts in Supabase. Optional
notification generation and push delivery both honor the saved preferences.
Read, dismiss and source validity are rechecked before a queued push is sent.
Payment, account, safety and operational messages are not optional categories.

## Implemented behavior

- Confirmed upcoming matches: deduplicated reminders near 24 hours and 2 hours.
- Open solo spots: a separate **default-off** preference. Only active accounts
  in the game's discovery city, eligible for the released position/division and
  without any other upcoming/active registration (solo, clan or reserve) or
  unresolved checkout can receive the offer.
  Cancellation enqueues one job; a minute sweep scans at most four jobs and 100
  opted-in city accounts per job, outside the locked cancellation transaction.
  New opt-ins never replay old jobs. Each offer's canonical source, capacity,
  eligibility and consent are checked again before phone-push delivery. Filling,
  expiring or replacing an offer invalidates its queued alert.
- Clan call-ups: an explicit successful captain roster confirmation, not an
  automatically created roster or a broadcast to every clan member.
- Party invitations: the existing invite flow. Dismissing its Activity receipt
  does not accept/decline the invitation or prevent action in the game screen.
- Ladder moves: committed qualified city/role rankings; first observation and
  changing primary city are silent. Outfield and Keeper remain independent.
- Replays: authoritative ready Cloudflare recordings of finished games, only
  for actual participants. No historical notification blast on installation.
- News/offers: an explicit service-only admin publication with consent, stable
  publication ID, recorded actor/reason and expiry. No automatic campaigns or
  new dashboard campaign composer are enabled by this change.

Only new notifications enqueue push for currently registered devices. Registering
a device or opting back in does not send a backlog. Receipts are idempotent;
FCM delivery itself is at-least-once after an unknown/lost acknowledgement.
Provider acceptance is not proof that a device displayed a notification.

The lock-screen preview is deliberately generic and carries only a notification
ID. A tap opens the signed-in account's canonical Activity. Neither push titles
nor entity IDs grant access or select a private destination from untrusted data.

## Staging Firebase apps

Project `fieldrush-1cfe5`, sender/project number `756208653017`:

| Platform | Actual staging application ID |
| --- | --- |
| iOS | `com.alialtaraif.field.staging` |
| Android | `com.field.field.staging` |

These IDs intentionally differ. Android's OAuth redirect scheme is not its
Android application/package ID. Public Firebase client identifiers are in
`mobile/lib/src/notifications/firebase_staging_options.dart`; no service-account
private key or APNs key belongs in a mobile binary or the repository.

`PUSH_NOTIFICATIONS_ENABLED` defaults to `false`. An opted-in staging/local build
also requires the matching enabled server capability and explicit device/user
permission. Production and web push remain disabled. An account cannot inherit
another account's consent on a shared installation.

## Apple setup before activation

1. Enable Push Notifications for the **staging** Apple App ID.
2. Create an APNs key restricted to the staging topic. TestFlight requires the
   Production APNs environment; local development devices use Sandbox. Upload
   the appropriate key(s) directly to Firebase's iOS Cloud Messaging settings
   with their Key ID and the Apple Team ID. Keep `.p8` files private.
3. Regenerate the staging provisioning profile to include `aps-environment`.
   Preserve the existing Apple Pay merchant entitlement.
4. Enable Background fetch and Remote notifications background modes in the
   staging push configuration, as required by Firebase's Flutter setup guide.
   Keep the default/production configuration unchanged until its own rollout.
5. Opt into `Runner-staging-push.entitlements` and the matching APNs environment
   using the documented `Push-staging.xcconfig.example`. It is deliberately not
   selected by default: the existing TestFlight signing profile cannot sign an
   entitlement it does not yet support.
6. Build with the push flag enabled only after profile/configuration validation.
   Merely uploading an APNs key does not update the installed app.

The example xcconfig is not automatically included, and the current release
workflow does not set the push flag. Before activation, explicitly select the
staging push native overrides for the intended configuration and add
`--dart-define=PUSH_NOTIFICATIONS_ENABLED=true` to that approved staging build.
The normal CI/TestFlight path remains off until this deliberate build/signing
configuration change is reviewed; provider keys alone cannot enable an old binary.

References: [Firebase Flutter setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started),
[Apple APNs keys](https://developer.apple.com/help/account/keys/create-a-private-key/).

## Protected server setup (not automatic deployment)

Deploying this code installs the migrations and default-off Edge Function. It
does **not** enable delivery, configure provider credentials or send a test push.

After explicit staging activation approval:

1. Enable FCM HTTP v1 for the Firebase project. Create a dedicated server service
   account with the FCM send permission for this project. Store its JSON only in
   the staging Edge Function secret `FIREBASE_SERVICE_ACCOUNT_JSON`.
2. Generate a strong random worker secret. Store it as `PUSH_WORKER_SECRET` in
   the staging Edge runtime; do not pass it in CLI arguments or log it.
3. Set `PUSH_DELIVERY_ENABLED=true` and `FIELD_ENVIRONMENT=staging` in that
   runtime. The worker rejects any other hosted Supabase project, production,
   user JWTs and an incorrect worker secret.
4. Through the protected service administration path, call
   `configure_push_delivery('fieldrush-1cfe5', true)` then
   `configure_push_dispatch(endpoint_url_to_use, worker_secret_to_use, true)`.
   The endpoint must be exactly
   `https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch`.
   Bind the secret as a private request parameter, not a literal in saved SQL.
   The second call stores the scheduler credential in Vault, never in the cron
   command or a public table. Do not print database error payloads containing
   input parameters.
5. Verify capability, scheduler flags and provider setup without revealing
   secret values. Then test a consented real Android device and a TestFlight
   iPhone, including foreground/background/cold-start taps and sign-out. Launch
   the new build at least once before testing. Android requires Google Play
   services; a force-stopped Android app or a manually swiped-away iOS app may
   need reopening before background reception resumes. In the foreground the
   implementation intentionally refreshes Activity without displaying an OS
   alert, badge or sound.

The one-minute dispatcher does nothing until both private enable flags are on.
The five-minute event sweep can still populate ordinary in-app Activity with
push disabled. Queue claims are leased, recipient/device binding is checked
again immediately before dispatch, transient failures back off, and only an
explicit FCM `UNREGISTERED` result retires the exact dispatched token.

To stop sending, disable dispatch with
`configure_push_dispatch(null, null, false)`, disable delivery capability, and/or
set the Edge flag to false. No key deletion is required to stop dispatch.

## Privacy and limitations

Normal sign-out attempts to revoke the server binding while the JWT is valid,
delete the provider token, clear consent and invalidate in-flight registration work.
Monotonic binding versions and server tombstones prevent late registration from
undoing a revocation. Forced session changes are also handled. If a device is
offline or provider/network errors prevent both revocation and provider token
deletion, no app can guarantee cancellation of an already queued OS notification;
generic previews prevent it exposing another account's private content.
Pending cleanup is persisted before network requests, retried on resume and
every 30 seconds while the app is foregrounded, and must finish provider cleanup
before a different account can enable notifications. The retry never requests
permission or registers a device by itself.

Real APNs/FCM delivery, newly signed Android/iOS binaries, OS notification
presentation and managed cron/network behavior still require staging device
tests. Isolated tests make no provider requests. Production release/signing,
web push and a marketing composer are separate work.
