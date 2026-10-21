# Field staging E2E fixtures

These scripts create, verify, and clean the isolated database state used by
Field's hosted staging end-to-end tests.

They fail closed unless the target is either:

- the exact source-controlled Field Staging project; or
- a loopback local Supabase instance.

The production project is explicitly denied by
`supabase/scripts/_shared/environment_guard.ts`.

## Lifecycle

1. `setup_staging.ts` creates or refreshes the tagged test accounts, cancels
   transient state from interrupted runs, creates two tagged future solo games,
   seeds 13 of 14 places in a Phoenix USD match, and writes a non-secret
   manifest.
2. `verify_staging.ts --phase=prepared` proves the fixture is ready before UI
   automation starts.
3. The mobile/referee/admin E2E journeys use IDs and exact text markers from the
   manifest.
4. `verify_staging.ts --phase=complete` checks the durable result directly in
   Postgres: onboarding, booking/cancellation, party acceptance, referee
   attendance corrections, match result, Player SR ledger, report, and support
   ticket.
5. `cleanup_staging.ts` closes remaining transient games and queues, removes the
   temporary referee assignment, and resets the reusable accounts to a safe
   baseline.

The played fixture starts 12–23 hours after setup so real Season 0 check-in,
team assignment and kickoff are inside the ±24-hour window. The separate
cancellation fixture stays 72–96 hours ahead to retain advance-refund coverage.
Both use whole-minute, 30-minute Phoenix slots; existing games are never moved.
Prepared verification rejects an out-of-window played fixture.

The browser journey checks everyone in, exercises a check-in correction, assigns
teams, starts the match and records a goal. It then waits for **30 real minutes of
server playing time** before normal finalization. There is no clock backdating,
rating bypass or shortened production rule. Its test budget is 35 minutes and
the browser job budget is 55 minutes (including build/cleanup); ordinary UI
actions remain limited to 15 seconds. This replaces the obsolete instant-finish
assumption from the pre-Season-0 journey.

Final matches and their Player SR, attendance, wallet, and audit records are
intentionally immutable. Cleanup retains this tagged history instead of
weakening production integrity rules for tests.

## Required environment

```sh
export SUPABASE_URL='https://nfdkdhdevpstfspazbfn.supabase.co'
export SUPABASE_SERVICE_ROLE_KEY='...'
export FIELD_ENVIRONMENT='staging'
export E2E_CONFIRM_TARGET='FIELD_STAGING_E2E'
export E2E_RUN_ID='local-e2e-001'
export E2E_TEST_PASSWORD='a-generated-value-at-least-16-characters'
export E2E_ONBOARDING_PHONE='+973...'
export E2E_MANIFEST_PATH='/tmp/field-e2e-manifest.json'
```

GitHub Actions should generate and mask `E2E_TEST_PASSWORD`; it must never be
written to the manifest or uploaded as an artifact. The onboarding phone must be
reserved for automation and must not be one of the fixed 14-player or admin test
accounts.

The optional `E2E_BOOTSTRAP_PHONE` and `E2E_DEV_OTP_CODE` values describe the
staging-only bootstrap login used before the test switches into the manifest's
isolated accounts. The OTP defaults to `000000`.

## Commands

```sh
deno run --allow-env --allow-net --allow-write \
  supabase/scripts/e2e/setup_staging.ts

deno run --allow-env --allow-net --allow-read \
  supabase/scripts/e2e/verify_staging.ts --phase=prepared

# Run the Flutter/referee/admin journeys here.

deno run --allow-env --allow-net --allow-read \
  supabase/scripts/e2e/verify_staging.ts --phase=complete

deno run --allow-env --allow-net --allow-read \
  supabase/scripts/e2e/cleanup_staging.ts
```

Run cleanup from an `always()`/`finally` step so an interrupted UI test does not
leave active games or unresolved E2E queues.

To validate the safety configuration without writing data:

```sh
deno run --allow-env --allow-net --allow-write \
  supabase/scripts/e2e/setup_staging.ts --dry-run
```

For local Supabase, use its loopback URL and set `FIELD_ENVIRONMENT=local`.
`E2E_CONFIRM_TARGET` is only required for hosted staging.

## Manifest contract

The JSON manifest is versioned and contains only non-secret IDs, fake phone
numbers, game times, and run-specific text markers. Important entries are:

- `accounts.main`: fully onboarded player used for booking and match journeys.
- `accounts.partyTarget`: player that accepts the party invitation.
- `accounts.onboarding`: separate user prepared with missing name/DOB metadata.
- `accounts.admin`: active isolated admin/referee.
- `games.match`: 13 seeded bookings; the mobile test books the final place.
- `games.cancellation`: empty game used to verify cancellation and reopening.
- `markers.reportDetails` and `markers.supportDetails`: exact text used to find
  the mobile submissions without depending on unrelated staging records.

Do not put passwords, service-role keys, access tokens, or refresh tokens in the
manifest.
