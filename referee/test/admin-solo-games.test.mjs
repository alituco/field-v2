import assert from "node:assert/strict";
import test from "node:test";

import {
  parseAdminSoloGameCreateInput,
  parseAdminSoloGameRemoveInput,
} from "../src/lib/admin-solo-games.ts";

const fieldId = "82fb1e65-dc06-4990-930b-c090a15d577e";

test("admin can prepare a Tuesday solo game in the Phoenix slot", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-21",
    fieldId,
    priceUsd: "13.50",
    ageLabel: " 18+ ",
  });

  assert.deepEqual(input, {
    matchDate: "2099-07-21",
    startsAt: "2099-07-22T03:30:00.000Z",
    durationMinutes: 60,
    fieldId,
    priceFils: 13500,
    ageLabel: "18+",
  });
});

test("admin can prepare a Friday solo game", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-24",
    fieldId,
    priceUsd: "0",
    ageLabel: "18+",
  });
  assert.equal(input.startsAt, "2099-07-25T03:30:00.000Z");
  assert.equal(input.priceFils, 0);
});

test("admin can create Saturday and other weekdays with a custom kickoff and duration", () => {
  const base = { fieldId, priceUsd: "13.00", ageLabel: "18+", kickoffTime: "18:15", durationMinutes: 90 };
  for (const day of [20, 21, 22, 23, 24, 25, 26]) {
    const input = parseAdminSoloGameCreateInput({ ...base, matchDate: `2099-07-${day}` });
    assert.equal(input.startsAt, `2099-07-${day + 1}T01:15:00.000Z`);
    assert.equal(input.durationMinutes, 90);
  }
});

test("dates, kickoff and duration remain strictly validated", () => {
  const base = { fieldId, priceUsd: "13.00", ageLabel: "18+", matchDate: "2099-07-25" };
  for (const kickoffTime of ["24:00", "9:30", "12:60", "noon", "20:30:00", ""]) assert.throws(() => parseAdminSoloGameCreateInput({ ...base, kickoffTime }), /kickoff/);
  for (const durationMinutes of [29, 181, 60.5, "90", false, NaN]) assert.throws(() => parseAdminSoloGameCreateInput({ ...base, durationMinutes }), /Duration/);
  for (const matchDate of ["2099-02-29", "2099-04-31", "2000-01-01"]) assert.throws(() => parseAdminSoloGameCreateInput({ ...base, matchDate }), /date|future/);
});

test("USD price defaults to13 and stays configurable in whole cents", () => {
  const base = { matchDate: "2099-07-24", fieldId, ageLabel: "18+" };
  assert.equal(parseAdminSoloGameCreateInput(base).priceFils, 13000);
  assert.equal(parseAdminSoloGameCreateInput({ ...base, priceUsd: "9.99" }).priceFils, 9990);
  for (const priceUsd of ["13.001", "-1", "101", "NaN", "1e2"]) {
    assert.throws(() => parseAdminSoloGameCreateInput({ ...base, priceUsd }), /Price/);
  }
  assert.throws(() => parseAdminSoloGameCreateInput({ ...base, priceBhd: "3.000" }), /Refresh/);
});

test("free-text venues and forged locations cannot replace a saved field", () => {
  const base = { matchDate: "2099-07-24", ageLabel: "18+" };
  for (const invalid of [undefined, null, "", "Phoenix Sports Park", "bad-id", 12]) {
    assert.throws(() => parseAdminSoloGameCreateInput({ ...base, fieldId: invalid, venue: "Fake park" }), /Choose a saved field/);
  }
  const input = parseAdminSoloGameCreateInput({ ...base, fieldId, venue: "Fake park", latitude: 1, longitude: 2 });
  assert.equal(input.fieldId, fieldId);
  assert.equal(input.venue, undefined);
  assert.equal(input.latitude, undefined);
});

test("admin removal requires a meaningful audit reason", () => {
  assert.throws(
    () => parseAdminSoloGameRemoveInput({ reason: "empty" }),
    /between 8 and 1000/,
  );
  assert.deepEqual(
    parseAdminSoloGameRemoveInput({
      reason: "Created for the wrong matchday.",
    }),
    { reason: "Created for the wrong matchday." },
  );
});
