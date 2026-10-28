# Recovering an unresolved Stripe checkout

An expired local checkout is **not evidence of non-payment**. An existing Stripe
PaymentIntent can still be payable, and an unknown create acknowledgement may
have been lost. Never delete a payment row, bypass the one-game guard, or recreate
an old attempt after its original idempotency window.

## Automatic and player recovery

Known provider IDs continue through ordinary retrieve/cancel/capture/refund
reconciliation. A missing ID older than 23 hours uses the provider's PaymentIntent
**List API**, not Search. Stripe documents that Search is eventually consistent
and recommends List APIs for immediately available data:
[Stripe data freshness](https://docs.stripe.com/search#data-freshness),
[PaymentIntent listing](https://docs.stripe.com/api/payment_intents/list),
[idempotency retention](https://docs.stripe.com/api/idempotent_requests).

Recovery scans a fixed creation range in pages of 100, at most three pages and
20 seconds per invocation. Its cursor and sanitized candidate evidence are
persisted. Subsequent runs resume incomplete scans. A complete unique match must
pass the exact Fieldrush attempt ID, owner, purpose, transaction reference,
amount, currency, card-only contract, its immutable per-attempt capture method
and payment environment. Older attempts remain automatic; updated mobile
explicitly negotiates manual capture for new solo attempts.
The recovered ID is durably linked, then retrieved again before existing
financial reconciliation. No recovery code creates a new PaymentIntent.
For a manual authorization, reconciliation reserves the game/role before capture.
An abandoned or unbookable authorization is voided; an uncertain provider
capture/cancellation retains its private capacity reservation until verified.

Empty results, conflicting matches, incomplete scans and provider outages never
release the lease. They create a stable support reference. Completed ambiguous
scans have a 15-minute retry cooldown; incomplete scans can resume after a minute.
The scheduled reconciler processes up to ten unsettled attempts within its
existing invocation deadline. On the exact earlier-checkout quote error, the app
calls the authenticated `stripe-payment` action `recover` once and retries its
original SQL quote once only after confirmed resolution. All booking guards stay.

## Explicit operator review

The initial release intentionally has no new admin composer/dashboard surface.
Authorized operators use the service-only RPCs through an existing secure server
or controlled SQL session. Never put a service key or provider evidence in chat,
client code, browser storage or a checked-in script.

1. Call `admin_list_stripe_checkout_recovery(actor_admin_id)` to inspect the
   case, its exact local attempt, provider candidates and `updated_at` version.
   A normal player JWT cannot call this RPC or read either private recovery table.
2. Independently inspect the correct Stripe account and test/live environment.
   Verify the immutable Fieldrush metadata and all provider payments, charges,
   refunds and outstanding processing states. Keep a durable restricted evidence
   reference, such as an internal investigation or Stripe support case.
3. Only when that investigation proves no provider payment exists, call
   `admin_resolve_stripe_checkout_recovery` with:
   - `actor_admin_id`: the active administrator performing the review;
   - `case_id_to_use`: the exact recovery case;
   - `resolution_to_use`: `NO_PAYMENT_EXISTS`;
   - `evidence_reference_to_use` and `reason_to_use`: nonempty detailed evidence
     reference and review reason (10–1,000 characters each);
   - `expected_updated_at`: the exact current version returned by the list RPC;
   - `provider_evidence_to_use`: `null`.
   This is an explicit accountable administrator attestation, **not** an automated
   claim that an empty List result proves absence. It requires a completed empty
   scan, no local provider ID/charge, no linked booking/fixture/refund and an old
   still-pending Stripe attempt.
4. For multiple candidates, do not select one or cancel a captured payment.
   Resolve the provider investigation first. `ALL_PROVIDER_PAYMENTS_CANCELLED`
   requires freshly retrieved, sanitized evidence for **every** recorded candidate,
   each provider-confirmed `canceled`, with zero received amount and the same
   verified metadata/amount/currency/mode. Use the service helper
   `recoveryEvidence(payment)` to omit client secrets and card/customer details.
   Captured, processing, succeeded, missing, foreign or incomplete evidence is
   refused. Any money received must follow normal refund/reconciliation—not this
   release mechanism.

The operation locks the original attempt and case, rejects stale versions and
active scans, preserves immutable payment history, marks only that checkout
`CANCELLED`, and appends both a private recovery event and admin audit event.
Normal booking can proceed only after the original guard sees that confirmed
terminal state. Deployment never invokes this operator action automatically.
