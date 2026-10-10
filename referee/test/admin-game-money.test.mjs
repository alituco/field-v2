import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

import { adminGameCurrency, formatGameMoney } from "../src/lib/admin-game-money.ts";

test("game overview resolves persisted solo currency without reinterpreting legacy games", () => {
  assert.equal(adminGameCurrency("SOLO", "USD"), "USD");
  assert.equal(adminGameCurrency("SOLO", "BHD"), "BHD");
  assert.equal(adminGameCurrency("CLAN"), "BHD");
  for (const value of [undefined, null, "", "EUR"]) {
    assert.throws(() => adminGameCurrency("SOLO", value), /missing or unsupported/);
  }
});

test("game and refund amounts retain their currency and exact ledger precision", () => {
  assert.equal(formatGameMoney(13000, "USD"), "$13.00 USD");
  assert.equal(formatGameMoney(6505, "USD"), "$6.505 USD");
  assert.equal(formatGameMoney(0, "USD"), "$0.00 USD");
  assert.equal(formatGameMoney(13000, "BHD"), "13.000 BHD");
  assert.equal(formatGameMoney(6505, "BHD"), "6.505 BHD");
  assert.throws(() => formatGameMoney(NaN, "USD"), /Invalid/);
  assert.throws(() => formatGameMoney(13000.5, "USD"), /Invalid/);
  assert.throws(() => formatGameMoney(13000, "EUR"), /Unsupported/);
});

test("all game refund display paths use the server-derived game currency", () => {
  const source = readFileSync(new URL("../src/app/admin/games/[matchKind]/[gameId]/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(source, /formatBhd/);
  assert.match(source, /formatGameMoney\(refund\.amountFils, detail\.currency\)/);
  assert.match(source, /formatGameMoney\(creditedFils, detail\.currency\)/);
  assert.match(source, /previewRefundLine\(preview, "home", homeLabel, detail\.currency\)/);
  assert.match(source, /previewRefundLine\(preview, "away", awayLabel, detail\.currency\)/);
});
