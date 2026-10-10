# Tap Payments

Field uses Tap's native Flutter checkout for paid solo bookings and clan
fixtures. The app may display Apple Pay, BenefitPay, Visa, and Mastercard. Tap
ultimately controls which methods appear for the configured merchant, device,
country, and test account.

## Security model

- `TAP_SECRET_KEY` is read only by the `tap-payment` and
  `tap-payment-webhook` Supabase Edge Functions.
- Flutter never receives the secret key. It receives a short-lived checkout
  configuration containing the Tap public key and a server-generated hash.
- Field calculates the amount again on the server. The app cannot choose or
  alter the amount.
- A booking or clan fixture is finalized only after Field retrieves the charge
  directly from Tap and verifies its captured status, amount, BHD currency,
  transaction reference, and merchant.
- Payment attempts and their linked resources are stored for reconciliation
  and audit.

## Test locally

Keep the Tap test values in the repository-root `.env.staging`. Do not put the
Tap secret key in `mobile/.env.local`, `mobile/.env.staging`, or any committed
file.

From the repository root:

```sh
supabase start
supabase db reset
./supabase/scripts/seed_local.sh
supabase functions serve --env-file .env.staging --no-verify-jwt
```

Keep that terminal open. In another terminal:

```sh
cd mobile
flutter run --flavor staging --dart-define-from-file=.env.local
```

Use a seeded local player, select a paid solo or clan flow, and press
`Continue to Secure Checkout`.

For local sign-in, use a seeded number such as `+97338883672`. No SMS is sent;
enter the local verification code `000000`. This bypass is accepted only by
the loopback Docker Supabase environment (and the separately configured hosted
staging test accounts), never production.

The checkout's final confirmation works locally because Field retrieves the
charge directly from Tap. Tap cannot deliver its webhook to `localhost`, so
webhook recovery must be tested later on an HTTPS staging deployment.

## Device requirements

- iOS deployment target: 16.6 or later.
- Android minimum SDK: 24 or later.
- Apple Pay should be tested on a physical, compatible iPhone. Tap must have
  the Field staging bundle identifier and Apple Pay enabled for the test
  merchant.
- BenefitPay must be enabled for the Tap test merchant and should be verified
  on a supported Bahrain device/account.
- Visa and Mastercard can use the current test credentials supplied by Tap.

If Apple Pay or BenefitPay does not appear while card checkout works, first
confirm method activation and the staging bundle identifier with Tap. That is
usually merchant configuration rather than a Field app error.

## Before deploying

Set these as Supabase Edge Function secrets in each hosted environment:

```text
TAP_SECRET_KEY
TAP_PUBLIC_KEY
TAP_MERCHANT_ID
TAP_WEBHOOK_URL
```

Then deploy `tap-payment` and `tap-payment-webhook`, apply the payment
migration, and run a test charge in that environment. Do not reuse test keys in
production.
