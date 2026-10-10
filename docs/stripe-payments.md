# Stripe payments

Fieldrush uses Stripe PaymentSheet for card and Apple Pay checkout. New solo
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

- Prices, currency, payer and target game come from authenticated server quotes.
- The app never supplies a trusted successful-payment flag. Stripe's returned
  payment is checked server-side before the database atomically creates a booking.
- Retrying an interrupted checkout reuses the outstanding payment attempt.
- A completed payment that cannot secure its booking is queued for a full refund
  to the original payment method. It is not displayed as a confirmed booking.
- **New Stripe cancellation refunds return to the original card or Apple Pay.**
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
