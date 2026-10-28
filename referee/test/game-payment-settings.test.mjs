import assert from "node:assert/strict";
import test from "node:test";
import { parseGamePaymentSettingsUpdate } from "../src/lib/game-payment-settings.ts";

const input = { clanPriceUsd: "80.00", reason: "Set the future team price before launch", expectedUpdatedAt: "2026-10-10T12:00:00.123456+00:00" };

test("future clan price is USD whole cents with exact optimistic revision", () => {
  assert.deepEqual(parseGamePaymentSettingsUpdate(input), { priceFils: 80000, reason: input.reason, expectedUpdatedAt: input.expectedUpdatedAt });
  assert.equal(parseGamePaymentSettingsUpdate({ ...input, clanPriceUsd: "80.25" }).priceFils, 80250);
});
test("price editing cannot enable clans, choose another currency or change an actor", () => {
  for (const extra of [{ clan_enabled: true }, { clan_games_enabled_to_use: true }, { currency: "BHD" }, { actor_admin_id: "attacker" }, { priceBhd: 80 }]) {
    assert.throws(() => parseGamePaymentSettingsUpdate({ ...input, ...extra }), /remain paused/);
  }
});
test("price editing rejects unsupported precision, ranges and incomplete audit data", () => {
  for (const clanPriceUsd of ["80.001", "-1", "0", "0.49", "1000.01", "Infinity", ""]) {
    assert.throws(() => parseGamePaymentSettingsUpdate({ ...input, clanPriceUsd }));
  }
  assert.throws(() => parseGamePaymentSettingsUpdate({ ...input, reason: "short" }));
  assert.throws(() => parseGamePaymentSettingsUpdate({ ...input, reason: "x".repeat(1001) }));
  assert.throws(() => parseGamePaymentSettingsUpdate({ ...input, expectedUpdatedAt: "invalid" }));
});
