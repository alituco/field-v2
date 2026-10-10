import assert from "node:assert/strict";
import test from "node:test";

import {
  parseAdminSoloGameCreateInput,
  parseAdminSoloGameRemoveInput,
} from "../src/lib/admin-solo-games.ts";

test("admin can prepare a Tuesday solo game in the Phoenix slot", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-21",
    venue: " Phoenix Sports Park ",
    priceUsd: "13.50",
    ageLabel: " 18+ ",
  });

  assert.deepEqual(input, {
    matchDate: "2099-07-21",
    startsAt: "2099-07-22T03:30:00.000Z",
    venue: "Phoenix Sports Park",
    priceFils: 13500,
    ageLabel: "18+",
  });
});

test("admin can prepare a Friday solo game", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-24",
    venue: "Phoenix Sports Park",
    priceUsd: "0",
    ageLabel: "18+",
  });
  assert.equal(input.startsAt, "2099-07-25T03:30:00.000Z");
  assert.equal(input.priceFils, 0);
});

test("admin cannot create a solo game on another weekday", () => {
  assert.throws(
    () =>
      parseAdminSoloGameCreateInput({
        matchDate: "2099-07-22",
        venue: "Phoenix Sports Park",
        priceUsd: "13.00",
        ageLabel: "18+",
      }),
    /Tuesday or Friday/,
  );
});

test("USD price defaults to13 and stays configurable in whole cents", () => {
  const base = { matchDate: "2099-07-24", venue: "Phoenix Sports Park", ageLabel: "18+" };
  assert.equal(parseAdminSoloGameCreateInput(base).priceFils, 13000);
  assert.equal(parseAdminSoloGameCreateInput({ ...base, priceUsd: "9.99" }).priceFils, 9990);
  for (const priceUsd of ["13.001", "-1", "101", "NaN", "1e2"]) {
    assert.throws(() => parseAdminSoloGameCreateInput({ ...base, priceUsd }), /Price/);
  }
  assert.throws(() => parseAdminSoloGameCreateInput({ ...base, priceBhd: "3.000" }), /Refresh/);
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
