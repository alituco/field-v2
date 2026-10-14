import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as fields from "../src/lib/admin-fields.ts";
import * as solo from "../src/lib/admin-solo-games.ts";

const fieldId = "f1000000-0000-4000-8000-000000000001";
const actor = { role: "admin", profileId: "10000000-0000-4000-8000-000000000001" };
const body = { fieldId, matchDate: "2099-07-24", kickoffTime: "20:30", ageLabel: "18+", priceUsd: "13.00", timezone: "America/Phoenix", marketCityId: "phoenix" };
function route({ identity = actor, active = true, marketActive = true } = {}) {
  const calls = [];
  const chain = { select: () => chain, eq: () => chain, single: async () => ({ data: { id: fieldId, is_active: active, market_city_id: "new-york", market: { display_name: "New York", timezone: "America/New_York", active: marketActive } }, error: null }) };
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200 }) } },
    "@/lib/admin-fields": fields,
    "@/lib/admin-solo-games": solo,
    "@/lib/referee-session": {
      requireReferee: async () => identity ? { referee: identity, db: { from: (name) => { calls.push(["read", name]); return chain; }, rpc: async (...args) => { calls.push(args); return { data: "new-game", error: null }; } } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (value) => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/solo-games/route.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => modules[name] });
  return { calls, ...exports };
}
test("game route uses the saved field city timezone even when the client forges another", async () => {
  const api = route();
  assert.equal((await api.POST({ json: async () => body })).status, 201);
  const rpc = api.calls.find(([name]) => name === "admin_create_open_queue_game");
  assert.equal(rpc[1].starts_at_to_use, "2099-07-25T00:30:00.000Z");
  assert.equal(rpc[1].field_id_to_use, fieldId);
  assert.equal(rpc[1].market_city_id, undefined);
  assert.equal(rpc[1].timezone, undefined);
  assert.equal(rpc[1].actor_admin_id, actor.profileId);
  assert.equal(rpc[1].goalkeepers_per_side_to_use, 1);
  assert.equal(rpc[1].defenders_per_side_to_use, 2);
  assert.equal(rpc[1].attackers_per_side_to_use, 4);
});
test("closed cities and archived fields cannot create new games", async () => {
  for (const options of [{ active: false }, { marketActive: false }]) {
    const api = route(options);
    assert.equal((await api.POST({ json: async () => body })).status, 400);
    assert.equal(api.calls.filter(([name]) => name === "admin_create_open_queue_game").length, 0);
  }
});
test("game route does not read fields for unauthenticated or non-admin callers", async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: "referee" }, 403]]) {
    const api = route({ identity });
    assert.equal((await api.POST({ json: async () => body })).status, status);
    assert.equal(api.calls.length, 0);
  }
});
