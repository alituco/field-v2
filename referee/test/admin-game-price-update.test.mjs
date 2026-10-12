import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import { parseGamePriceUpdate } from "../src/lib/admin-game-price-update.ts";

const base = { priceUsd: "15.50", expectedPriceFils: 13000, reason: "Saturday promotional price" };
const id = "10000000-0000-4000-8000-000000000001";
test("game price edits accept USD whole cents, free games, increases and reductions", () => {
  assert.deepEqual(parseGamePriceUpdate(base), { priceFils: 15500, expectedPriceFils: 13000, reason: base.reason });
  for (const priceUsd of ["0", "0.50", "9.99", "100.00"]) assert.equal(parseGamePriceUpdate({ ...base, priceUsd }).priceFils, Math.round(Number(priceUsd) * 1000));
});
test("invalid prices, missing revisions, short reasons and payment-adjustment attempts are rejected", () => {
  for (const priceUsd of ["-1", "101", "0.49", "13.001", "1e1", "", "NaN", 13, null]) assert.throws(() => parseGamePriceUpdate({ ...base, priceUsd }));
  for (const change of [{ expectedPriceFils: null }, { expectedPriceFils: "13000" }, { expectedPriceFils: -1 }, { reason: "short" }, { refund: true }, { actor_admin_id: id }, { amount_paid_fils: 5000 }]) assert.throws(() => parseGamePriceUpdate({ ...base, ...change }));
});

function route(actor, error = null) {
  const calls = [];
  const response = { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) };
  const modules = {
    "next/server": { NextResponse: response },
    "@/lib/admin-game-price-update": { parseGamePriceUpdate },
    "@/lib/referee-session": {
      requireReferee: async () => actor ? { referee: actor, db: { rpc: async (...args) => { calls.push(args); return { data: { price_fils: 15500, currency: "USD" }, error }; } } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (value) => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/games/[matchKind]/[gameId]/price/route.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => modules[name] });
  return { calls, PATCH: exports.PATCH };
}
const request = (body = base) => ({ json: async () => body });
const params = (changes = {}) => ({ params: Promise.resolve({ gameId: id, matchKind: "solo", ...changes }) });
test("price updates require authenticated admin access before any database mutation", async () => {
  for (const [actor, status] of [[null, 401], [{ role: "referee", profileId: id }, 403]]) {
    const api = route(actor);
    assert.equal((await api.PATCH(request(), params())).status, status);
    assert.equal(api.calls.length, 0);
  }
});
test("price endpoint validates the game, supplies the actor, and does not touch bookings or payments", async () => {
  const api = route({ role: "admin", profileId: id });
  assert.equal((await api.PATCH(request(), params())).status, 200);
  assert.equal(api.calls[0][0], "admin_update_open_queue_game_price");
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls[0][1])), { actor_admin_id: id, game_id_to_use: id, price_fils_to_use: 15500, expected_price_fils: 13000, reason_to_use: base.reason });
  for (const changes of [{ matchKind: "clan" }, { gameId: "bad-id" }]) assert.equal((await api.PATCH(request(), params(changes))).status, 400);
  assert.equal(api.calls.length, 1);
});
test("stale price and locked-state errors are returned as conflicts, not successful updates", async () => {
  const api = route({ role: "admin", profileId: id }, { message: "The game price changed. Refresh before saving." });
  const result = await api.PATCH(request(), params());
  assert.equal(result.status, 409);
  assert.match(result.body.error, /Refresh/);
});
