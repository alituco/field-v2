# Fieldrush notifications

The player app keeps recipient-owned Activity receipts in Supabase. Optional
notification generation and push delivery both honor the saved preferences.
Read, dismiss and source validity are rechecked before a queued push is sent.
Payment, account, safety and operational messages are not optional categories.

## Implemented behavior

- Confirmed solo matches: deduplicated reminders near 24 hours and 2 hours
  **before check-in**, using the game's saved arrival terms and venue timezone.
  A final reminder runs five minutes before the strict check-in deadline, only
  while a confirmed player has no referee-recorded arrival and play has not
  started. Late bookings do not replay missed reminder thresholds. A nearby
  team announcement includes arrival details and replaces the 2-hour reminder.
- Published teams and actual changes to the recipient's team; material saved
  schedule, venue or field changes; Fieldrush cancellations and forced booking
  removals with the actual refund state. Deferred observers see the final
  transaction rather than intermediate roster or payment edits. Existing games
  are baselined silently when the migration is installed.
- Asynchronous real Stripe checkout outcomes: a secured booking, a pending or
  fully processed refund after an unsuccessful booking, or release of an
  uncaptured authorization. The visible foreground checkout acknowledges only
  its displayed outcome; a 20-second queue grace lets that acknowledgement win.
  A new refund outcome remains unread even if an earlier pending state was seen.
- Games entering review/reopened, and reviewed or materially corrected results.
  This rollout does not introduce ordinary result/SR, replay or referral pushes.
- Recorded solo attendance decisions and resulting sanctions are combined into
  one alert per incident. Appeal decisions include regained eligibility where
  applicable; time-based restriction expiry is observed without historical spam.
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
- Party invitations: the existing invite flow, expiring at the saved party lock
  (normally three hours before kickoff). Dismissing its Activity receipt
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

The selected player rollout sends phone previews only for the approved events
above. Other existing Activity events retain their current in-app behavior.
Game reminders/team notices show the actual arrival information; checkout copy
distinguishes charge refunds from authorization releases. Financial amounts,
disciplinary evidence and private staff notes remain behind sign-in.

Push data carries only a notification ID. A tap fetches the current signed-in
owner's canonical receipt before opening its game, private payment history,
reliability/appeal panel or decision. An unavailable/obsolete receipt falls back
to Activity. Signed-out taps retain only that opaque ID; a different account
cannot retrieve its contents. Every send rechecks ownership, device binding,
preferences, current source and expiry. Provider TTL is capped at the event
deadline, so a last-call reminder cannot wait offline for another hour.

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
5. The staging TestFlight uploader selects `Runner-staging-push.entitlements`,
   `Info-staging-push.plist`, and production APNs through Runner-only build
   settings. It rejects a profile without production APNs or the existing Apple
   Pay merchant, and verifies both the signed archive and exported IPA retain
   these entitlements, background modes, and consent-controlled SDK auto-init.
6. Build with the push flag enabled only after profile/configuration validation.
   Merely uploading an APNs key does not update the installed app.

The staging TestFlight uploader passes
`--dart-define=PUSH_NOTIFICATIONS_ENABLED=true`. Ordinary local/CI builds keep
the flag off and their existing native defaults. For a separate Release-staging
build, `Push-staging.xcconfig.example` documents the explicit native overrides;
it is not automatically included. Production and web remain disabled. Provider
keys alone cannot enable an already installed binary, and the server activation
below and user consent are still required for delivery.

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
Its bounded fifty-device batch reserves forty-eight slots for urgent operational alerts
(including reminders and party invitations), one for routine optional updates, and one
for marketing. Unused capacity is filled in priority order. A news publication
cannot hold a due reminder behind its entire audience, and lower lanes retain
capacity during sustained urgent traffic. Priority is derived from the stored
notification type, not supplied by clients. Source expiry caps each delivery's
deadline; expired/exhausted rows consume no delivery slots.
Urgent claims prefer the nearest expiry so an older tomorrow reminder cannot
hold a five-minute check-in warning behind it. Provider delivery remains best
effort; [FCM may collapse offline notifications](https://firebase.google.com/docs/cloud-messaging/customize-messages/collapsible-message-types),
and Activity is the durable record.
The one-minute event sweep can still populate ordinary in-app Activity with
push disabled. Queue claims are leased, recipient/device binding is checked
again immediately before dispatch, transient failures back off, and only an
explicit FCM `UNREGISTERED` result retires the exact dispatched token.

To stop sending, disable dispatch with
`configure_push_dispatch(null, null, false)`, disable delivery capability, and/or
set the Edge flag to false. No key deletion is required to stop dispatch.

## Privacy and limitations

On iOS, the client waits up to six seconds for asynchronous APNs registration
after permission and explicit opt-in, then offers a retry if Apple is not ready.
FlutterFire's deletion wrapper requires an APNs token even for cleanup, and the
native single-token API requires existing checkin credentials. iOS cleanup uses
Firebase's public `deleteData` operation through an app-owned native channel, so
fresh installs can clear messaging registrations without either prerequisite.
Failed deletion still blocks account rebinding; cleanup never enables auto-init.
The opt-in native SDK
check is `flutter test integration_test/push_cleanup_native_test.dart --flavor
staging -d <disposable-simulator-id> --dart-define=APP_ENV=staging
--dart-define=VERIFY_NATIVE_PUSH_CLEANUP=true`. It contacts staging Firebase;
Supabase is mocked and no player device or phone notification is created.

Normal sign-out attempts to revoke the server binding while the JWT is valid,
delete the provider token, clear consent and invalidate in-flight registration work.
Monotonic binding versions and server tombstones prevent late registration from
undoing a revocation. Forced session changes are also handled. If a device is
offline or provider/network errors prevent both revocation and provider token
deletion, no app can guarantee cancellation of an already queued OS notification;
disciplinary and financial-detail previews remain generic. An already delivered
game/checkout preview can remain in the phone's notification history; signing
out cannot recall a notification already accepted by the OS. Opening it still
requires the correct signed-in owner and a fresh canonical receipt lookup.
Pending cleanup is persisted before network requests, retried on resume and
every 30 seconds while the app is foregrounded, and must finish provider cleanup
before a different account can enable notifications. The retry never requests
permission or registers a device by itself.

Real APNs/FCM delivery, newly signed Android/iOS binaries, OS notification
presentation and managed cron/network behavior still require staging device
tests. Isolated tests make no provider requests. Production release/signing,
web push and a marketing composer are separate work.
