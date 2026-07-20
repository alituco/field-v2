import assert from "node:assert/strict";
import test from "node:test";

import {
  parseAdminSoloGameCreateInput,
  parseAdminSoloGameRemoveInput,
} from "../src/lib/admin-solo-games.ts";

test("admin can prepare a Tuesday solo game in the fixed Bahrain slot", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-21",
    venue: " TFA, Saar ",
    priceBhd: "3.500",
    ageLabel: " 16+ ",
  });

  assert.deepEqual(input, {
    matchDate: "2099-07-21",
    startsAt: "2099-07-21T17:30:00.000Z",
    venue: "TFA, Saar",
    priceFils: 3500,
    ageLabel: "16+",
  });
});

test("admin can prepare a Friday solo game", () => {
  const input = parseAdminSoloGameCreateInput({
    matchDate: "2099-07-24",
    venue: "Saar City",
    priceBhd: "0",
    ageLabel: "All ages",
  });
  assert.equal(input.startsAt, "2099-07-24T17:30:00.000Z");
  assert.equal(input.priceFils, 0);
});

test("admin cannot create a solo game on another weekday", () => {
  assert.throws(
    () =>
      parseAdminSoloGameCreateInput({
        matchDate: "2099-07-22",
        venue: "TFA, Saar",
        priceBhd: "3.000",
        ageLabel: "16+",
      }),
    /Tuesday or Friday/,
  );
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
