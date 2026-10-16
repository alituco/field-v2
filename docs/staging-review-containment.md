# Staging review containment

This branch contains findings 1, 2, 4, 6, 7, 8 and the existing staff-account fix
(9) from the staging review. It does not change the production deletion gate,
replace the rating replay design, or release production.

| Finding | Containment |
| --- | --- |
| 1: staging dev authentication | Restricted to service-owned, current-run synthetic fixtures, reserved phones/roles and a strong run capability with a mandatory finite window. No endpoint provisioning/password reset. CI provisions first and closes authentication in final/failure cleanup. See `supabase/README.md` for cleanup and residual session limitations. |
| 2: partial goal writes / stale legacy SR | One atomic, audited, idempotent add/undo action. Legacy finalized edits cannot change W/D/L or the rating margin multiplier while retaining old awards. The v2 reviewed correction/replay path remains supported. |
| 4: forged clan creation records | Authenticated inserts must start at 1500 SR, zero wins/losses. Existing historical records are not rewritten or presumed fraudulent. |
| 6: direct clan archive | Raw authenticated archive writes are denied. The owner archive action retains live-fixture checks and atomic request/membership cleanup. |
| 7: replacement alert fanout | Default-off open-spots preference, canonical city/role/division/account/one-game eligibility, bounded asynchronous fanout, idempotent receipts and matching phone-push outbox. Eligibility and the original opt-in are rechecked at dispatch. |
| 8: unknown old Stripe checkout | Bounded positive-only provider recovery; never automatic negative Search/list-based expiry. Ambiguity creates an audited review case; operator resolution requires explicit evidence. See `docs/stripe-checkout-recovery.md`. |
| 9: staff provisioning | Preserve existing public/private identity, Auth credentials and linked providers. Grant staff authorization through an atomic guarded action, not a password/name overwrite. |

The branch also includes the previously requested incomplete-signup account
switch fix, preference/event wiring, and Activity read/dismiss synchronization.

## Release boundaries

- No merge, deployment approval, normal-user sign-out, booking cancellation,
  payment/refund mutation, or production change is performed by opening the PR.
- The exposed staging dev endpoints were separately disabled and their windows
  expired as immediate security containment; both returned HTTP 404 afterward.
- Migrations, admin/referee code, payment functions and mobile changes must be
  reviewed and deployed together through the normal staging workflow.
- Phone-push code is implemented but default-off. Firebase service credentials,
  staging provisioning/profile entitlements and an explicitly enabled build are
  still required for activation. Real Android and TestFlight iPhone delivery must
  be tested after activation. No real push is sent by the automated regressions.
- Database tests are isolated/rollback-only. Managed Auth, realtime delivery,
  cron/network execution and simultaneous multi-connection races require the
  normal staging checks; PGlite schema contracts do not prove those services.
