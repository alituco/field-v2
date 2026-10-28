import { strict as assert } from "node:assert";
import {
  assertJourneyKickoffWindow,
  selectJourneySlots,
} from "./game_slots.ts";

const now = new Date("2026-10-21T03:38:12.123Z");
const HOUR = 3600000;

Deno.test("played fixture fits S0 check-in while cancellation retains advance refund coverage", () => {
  const [match, cancellation] = selectJourneySlots(now, []);
  assert.ok(match.getTime() - now.getTime() >= 12 * HOUR);
  assert.ok(match.getTime() - now.getTime() < 24 * HOUR);
  assert.ok(cancellation.getTime() - now.getTime() >= 72 * HOUR);
  assert.equal(match.getUTCSeconds(), 0);
  assert.equal(match.getUTCMilliseconds(), 0);
  assertJourneyKickoffWindow(match.toISOString(), now);
  assertJourneyKickoffWindow(
    match.toISOString(),
    new Date(now.getTime() + 2 * HOUR),
  );
});

Deno.test("fixtures work every weekday, not only Tuesday and Friday", () => {
  for (let day = 0; day < 7; day++) {
    const date = new Date(now.getTime() + day * 24 * HOUR);
    const [match] = selectJourneySlots(date, []);
    assertJourneyKickoffWindow(match.toISOString(), date);
  }
});

Deno.test("occupied minutes are skipped without changing existing games", () => {
  const [first] = selectJourneySlots(now, []);
  const existing = [{ starts_at: first.toISOString(), status: "FULL" }];
  const before = structuredClone(existing);
  const [next] = selectJourneySlots(now, existing);
  assert.equal(next.getTime(), first.getTime() + 60000);
  assert.deepEqual(existing, before);
});

Deno.test("cancelled games do not block slots but final and live games do", () => {
  const [first] = selectJourneySlots(now, []);
  for (const status of ["FINAL", "LIVE", "OPEN", "FULL"]) {
    assert.notEqual(
      selectJourneySlots(now, [{ starts_at: first.toISOString(), status }])[0]
        .getTime(),
      first.getTime(),
    );
  }
  assert.equal(
    selectJourneySlots(now, [{
      starts_at: first.toISOString(),
      status: "CANCELLED",
    }])[0].getTime(),
    first.getTime(),
  );
});

Deno.test("feed visibility rejects crowded candidates rather than altering normal fixtures", () => {
  const existing = Array.from(
    { length: 39 },
    (_, i) => ({
      starts_at: new Date(now.getTime() + i * 60000).toISOString(),
      status: "OPEN",
    }),
  );
  assert.throws(() => selectJourneySlots(now, existing), /discoverable/);
  assert.equal(selectJourneySlots(now, existing.slice(0, 38)).length, 2);
});

Deno.test("exhausted near-term slots never fall back outside the kickoff window", () => {
  const [first] = selectJourneySlots(now, []);
  const existing = Array.from(
    { length: 12 * 60 },
    (_, i) => ({
      starts_at: new Date(first.getTime() + i * 60000).toISOString(),
      status: "FINAL",
    }),
  );
  assert.throws(
    () => selectJourneySlots(now, existing),
    /required kickoff window/,
  );
});

Deno.test("kickoff guard accepts exact boundaries and rejects stale, far-future or malformed dates", () => {
  for (const hours of [-24, 0, 24]) {
    assertJourneyKickoffWindow(
      new Date(now.getTime() + hours * HOUR).toISOString(),
      now,
    );
  }
  for (const hours of [-24.01, 24.01, 72]) {
    assert.throws(() =>
      assertJourneyKickoffWindow(
        new Date(now.getTime() + hours * HOUR).toISOString(),
        now,
      ), /24h/);
  }
  assert.throws(() => assertJourneyKickoffWindow("invalid", now));
  assert.throws(() => selectJourneySlots(new Date("invalid"), []));
});
