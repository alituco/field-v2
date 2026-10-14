# Stripe payments

Fieldrush embeds Stripe's native payment-method selector in the solo checkout.
Players select a method alongside the game, position and server-quoted total,
then use Fieldrush's Pay button. Card entry, Apple Pay / Google Pay authorization and bank
authentication remain Stripe/system-owned secure UI; the app never handles raw
card details. Legacy callers retain PaymentSheet compatibility. New solo
games are priced in USD ($13 by default, configurable by admins). The US Stripe
account cannot charge BHD. Historical BHD games, payments and wallet balances
are preserved, but their old checkout is unavailable. **Clan games are disabled**;
their future default is $80 per team. New payments are USD only; historical
amounts are never silently converted or relabeled.

## Configuration

The repository-root ignored `.env.staging` and GitHub **staging** environment
need these server-only secrets:

| Name | Purpose |
| --- | --- |
| `STRIPE_SECRET_KEY` | Stripe sandbox secret key (`sk_test_…`) |
| `STRIPE_WEBHOOK_SECRET` | Signing secret for the staging webhook (`whsec_…`) |
| `STRIPE_RECONCILE_SECRET` | Random worker credential of at least 32 characters |

`STRIPE_PUBLISHABLE_KEY` (`pk_test_…`) is also stored in the GitHub staging
environment and in `mobile/.env.staging`. The mobile file includes
`APPLE_MERCHANT_ID=merchant.com.alialtaraif.fieldrush`. **Never** copy a secret
key, webhook secret, service-role key, or worker credential into a mobile
environment file or `--dart-define`.

The staging deployment uses three Edge Functions:

- `stripe-payment`: authenticated prepare, confirm and cancel requests.
- `stripe-payment-webhook`: validates Stripe's signature against the unchanged
  request body before processing an event.
- `stripe-payment-reconcile`: authenticated server-only recovery worker for
  interrupted payments, missed webhooks and queued refunds.

Stripe's sandbox webhook URL is
`https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/stripe-payment-webhook`.
Subscribe to `payment_intent.succeeded`, `payment_intent.payment_failed`,
`payment_intent.processing`, `payment_intent.canceled`, `refund.created`,
`refund.updated` and `refund.failed`. Use the signing secret belonging to this
endpoint, not a local Stripe CLI listener. A scheduled reconciliation worker
must remain enabled even when no players have the app open.

The GitHub staging variable `STRIPE_WEBHOOK_ENDPOINT_ID` identifies this
endpoint. Deployment validates the endpoint's URL, test mode and API version,
stores the worker authorization in Supabase Vault, schedules it every five
minutes, and enables the webhook. The endpoint can stay disabled while this
branch is under review; it must not deliver events to an undeployed handler.

## Booking and refund guarantees

- Opening checkout or choosing a payment method does not create a payment or
  booking. The embedded selector loads from a read-only quote; server `prepare`
  runs only after an explicit Pay/Confirm booking action, including free games.
- USD amounts remain stored in the legacy thousandths columns. Embedded Stripe
  amounts use cents (`amount_fils / 10`) after exact-precision validation. A
  different prepared total is cancelled/reconciled and must be reviewed again.
- Native selection is disabled during confirmation. A dismissed card-entry
  form is not a cancelled payment; an actual confirmation cancellation is
  reconciled with the server. The native view is disposed before navigation.
- A completed native payment stays in server-verification mode if the response
  is lost or the session expires. Resume checks the same attempt; it does not
  assume a failed charge or ask for a replacement payment.
- Prices, currency, payer and target game come from authenticated server quotes.
- The app never supplies a trusted successful-payment flag. Stripe's returned
  payment is checked server-side before the database atomically creates a booking.
- Retrying an interrupted checkout reuses the outstanding payment attempt.
- A completed payment that cannot secure its booking is queued for a full refund
  to the original payment method. It is not displayed as a confirmed booking.
- **New Stripe cancellation refunds return to the original payment method.**
  The policy determines the eligible amount, including deposits; it does not
  redirect the money into Field Wallet.
- Refund requests are durable, capped at the captured amount and idempotent.
  Requested/processing refunds are distinct from confirmed successful refunds.
  An admin retry must not create another refund if Stripe already accepted one.
- A refund issued directly in Stripe is recorded and flagged in admin **Needs
  attention**, even when no cancellation exists. It does not automatically
  cancel a valid booking. Policy cancellations can still complete, but additional
  money transfers stay on a visible manual-review hold until the external refund
  and the amount owed have been reconciled. Do not clear that hold or issue a
  second Dashboard refund merely to make the alert disappear.
- Historical wallet credits and legacy payment records remain auditable. Existing
  applied migrations are kept so a fresh database can replay its complete history;
  they are not active dependencies on the retired provider.

Admin → Games → **Booking prices · USD** controls the future clan team price
($80 by default). Clan checkout remains paused; editing that price does not
enable it. Solo prices remain configurable per game, with $13 as the default.

## Repairing an abandoned retired-provider checkout

An expired `LEGACY` attempt can still hold the one-game checkout limit. The
Stripe recovery worker intentionally processes only Stripe payments. For a
verified unpaid legacy attempt on a cancelled solo game, operators can run
`supabase/scripts/expire_unpaid_legacy_checkout.sql` in a transaction with
transaction-local `field.repair_intent_id`, `field.repair_profile_id`,
`field.repair_game_id`, `field.repair_admin_id`, and `field.repair_reason` settings.
The admin ID must identify the active administrator authorizing the repair.
Keep specific account identifiers in the private execution inputs.

First run the transaction with `ROLLBACK` and review the result. Then repeat
with `COMMIT` for the authorized record. The script locks and checks the exact
owner, game and attempt; refuses any provider, capture, booking or refund
evidence; and records full before/after snapshots in the admin audit history.
It expires only that attempt and is idempotent for the same recorded repair.
It does not change the one-game guard or enable automatic legacy cleanup.
This maintenance script is not a migration and is never run by deployment.

## Apple Pay and native builds

The staging App ID is `com.alialtaraif.field.staging`, Apple team `69B646V2WM`.
Its Apple Pay entitlement and provisioning profile must include
`merchant.com.alialtaraif.fieldrush`. Stripe must have the payment-processing
certificate created from Stripe's own CSR. Regenerate the App Store provisioning
profile after changing capabilities and update
`IOS_STAGING_PROVISIONING_PROFILE_BASE64` in the GitHub staging environment.

The TestFlight script validates the profile and includes only the publishable
key and public merchant identifier in the app. Real-device Apple Pay testing is
still required; a successful simulator build alone does not prove wallet payment.

## Google Pay on Android

Android checkout uses Stripe's Google Pay integration in both the embedded
payment selector and the legacy PaymentSheet flow. The shared configuration
sets the merchant country to `US`, the currency to `USD`, and `testEnv: true`
unless `APP_ENV=production`. Stripe still decides whether Google Pay is available
on the device; the app does not show a fake wallet button or store the player's
card. Cards saved in Google Wallet belong to that wallet; this does not enable
Fieldrush saved-card accounts. Payment settings describe Google Pay on Android,
Apple Pay on iOS, and cards elsewhere.

`mobile/android/app/src/main/AndroidManifest.xml` enables
`com.google.android.gms.wallet.api.enabled`. No additional staging credentials
or database migration are required. Google Pay uses the existing Stripe
PaymentIntent, booking verification, cancellation and refund flow. The server
records Stripe's `google_pay` card-wallet type as `GOOGLE_PAY`.

Verify on a physical Android phone with a Google account and a payment method
in Google Wallet, in a supported country. Use Stripe test keys and Google's test
card suite; emulator tests do not verify wallet authorization. Check success,
cancellation, reopening checkout and original-method refunds against Stripe's
sandbox records. See [Stripe's Google Pay testing guide](https://docs.stripe.com/google-pay?platform=android#test-google-pay).

Before live payments, submit the Android app through the Google Pay & Wallet
Console using integration type **Gateway**, provide the required screenshots,
and obtain approval. Configure proper Android release signing: the current
`mobile/android/app/build.gradle.kts` release build still uses the debug signing
configuration, which is unsuitable for Google Pay production. Live rollout
also requires production wallet mode and live Stripe keys. See
[Google's production requirements](https://developers.google.com/pay/api/android/guides/test-and-deploy/publish-your-integration).

## Local testing

After the matching backend migration and functions are available, run:

```sh
cd mobile
flutter run --flavor staging --dart-define-from-file=.env.staging
```

Use Stripe's [documented test cards](https://docs.stripe.com/testing), never a
real card number in test mode. Exercise a successful card, decline, 3D Secure,
cancel, lost connection after payment, repeated checkout, a full game after
payment and partial/full cancellation refunds. Check both the app's booking and
the Stripe sandbox transaction/refund status.

For a fully local stack, use a separate ignored server environment with
`FIELD_ENVIRONMENT=local`, the local Supabase credentials and Stripe test keys.
Forward the events above using Stripe CLI to the local webhook and use that
listener's signing secret. Keep local and hosted signing secrets separate.

CI's guarded `STAGING_E2E` payment path does not charge Stripe and is not a
substitute for these Stripe sandbox tests. It must be restricted to server-marked
test users and that run's isolated fixtures.

The explicit provider smoke test uses only Stripe's predefined test payment
methods, refuses live keys and refunds/cancels every attempt on completion:

```sh
deno run --allow-env --allow-net --env-file=.env.staging supabase/scripts/verify_stripe_sandbox.ts
```

It checks that mobile/server keys belong to the same sandbox as well as provider
behavior, not the database booking lifecycle. Run
`supabase/scripts/verify_stripe_payment_system.sql` against an isolated local
Supabase database for payment permissions, capacity races, booking finalization,
cancellations and refund-ledger assertions.

## Rollout

Deploy the neutral payment/refund migration, Stripe functions, worker scheduling,
admin app and matching mobile build together. The deployment removes retired
payment functions and server secrets only after their replacements are deployed.
Do not discard historical financial rows or edit applied migrations to erase the
old provider's history. Production activation and live keys are a separate rollout.
The deployment script blocks production before any mutation until a coordinated
live Stripe rollout is implemented.
