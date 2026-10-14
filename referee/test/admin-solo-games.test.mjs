import assert from "node:assert/strict";
import test from "node:test";

import {
  parseAdminSoloGameCreateInput,
  parseAdminSoloGameRemoveInput,
  cityKickoffToUtc,
  cityToday,
} from "../src/lib/admin-solo-games.ts";

const fieldId = "82fb1e65-dc06-4990-930b-c090a15d577e";

test("kickoff follows the trusted competition-city timezone, not a client offset", () => {
  assert.equal(cityKickoffToUtc("2027-07-01", "20:30", "America/Phoenix"), "2027-07-02T03:30:00.000Z");
  assert.equal(cityKickoffToUtc("2027-07-01", "20:30", "America/New_York"), "2027-07-02T00:30:00.000Z");
  assert.equal(cityKickoffToUtc("2027-01-01", "20:30", "America/New_York"), "2027-01-02T01:30:00.000Z");
  assert.equal(cityKickoffToUtc("2027-07-01", "00:00", "Asia/Kolkata"), "2027-06-30T18:30:00.000Z");
  const input = parseAdminSoloGameCreateInput({ fieldId, matchDate: "2099-07-21", kickoffTime: "20:30", ageLabel: "18+", timezone: "America/Phoenix" }, "America/New_York");
  assert.equal(input.startsAt, "2099-07-22T00:30:00.000Z");
});

test("DST gaps and repeated wall times are explicit errors instead of silently moving games", () => {
  assert.throws(() => cityKickoffToUtc("2027-03-14", "02:30", "America/New_York"), /does not exist/);
  assert.throws(() => cityKickoffToUtc("2027-11-07", "01:30", "America/New_York"), /happens twice/);
  assert.throws(() => cityKickoffToUtc("2027-01-01", "20:30", "Invalid/City"), /invalid timezone/);
  assert.equal(cityToday("America/Phoenix", new Date("2027-07-02T04:00:00Z")), "2027-07-01");
  assert.equal(cityToday("America/New_York", new Date("2027-07-02T04:00:00Z")), "2027-07-02");
});

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
    highestDivision: 1,
    lowestDivision: 5,
    goalkeepersPerSide: 1,
    defendersPerSide: 2,
    attackersPerSide: 4,
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

test("division range defaults to unrestricted and strictly validates ordered whole-number divisions", () => {
  const base = { fieldId, priceUsd: "13.00", ageLabel: "18+", matchDate: "2099-07-25" };
  assert.deepEqual(
    {
      highestDivision: parseAdminSoloGameCreateInput(base).highestDivision,
      lowestDivision: parseAdminSoloGameCreateInput(base).lowestDivision,
    },
    { highestDivision: 1, lowestDivision: 5 },
  );
  const restricted = parseAdminSoloGameCreateInput({ ...base, highestDivision: 2, lowestDivision: 4 });
  assert.equal(restricted.highestDivision, 2);
  assert.equal(restricted.lowestDivision, 4);

  for (const highestDivision of [null, "2", 0, 6, 2.5, NaN]) {
    assert.throws(
      () => parseAdminSoloGameCreateInput({ ...base, highestDivision }),
      /Highest division/,
    );
  }
  for (const lowestDivision of [null, "4", 0, 6, 4.5, NaN]) {
    assert.throws(
      () => parseAdminSoloGameCreateInput({ ...base, lowestDivision }),
      /Lowest division/,
    );
  }
  assert.throws(
    () => parseAdminSoloGameCreateInput({ ...base, highestDivision: 4, lowestDivision: 2 }),
    /Highest division must be less than or equal/,
  );
});

test("USD price defaults to $13 and accepts free games or whole cents from $0.50 to $100", () => {
  const base = { matchDate: "2099-07-24", fieldId, ageLabel: "18+" };
  assert.equal(parseAdminSoloGameCreateInput(base).priceFils, 13000);
  assert.equal(parseAdminSoloGameCreateInput({ ...base, priceUsd: "9.99" }).priceFils, 9990);
  for (const priceUsd of ["0", "0.00", 0, "0.50", 0.5, "100.00", 100]) {
    assert.equal(parseAdminSoloGameCreateInput({ ...base, priceUsd }).priceFils, Math.round(Number(priceUsd) * 1000));
  }
  for (const priceUsd of ["0.01", "0.49", 0.01, 0.49, "13.001", "-1", "100.01", "101", "NaN", "1e2"]) {
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
