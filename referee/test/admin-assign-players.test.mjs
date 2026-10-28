import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const id = "10000000-0000-4000-8000-000000000001";
const player = "20000000-0000-4000-8000-000000000001";
const requestId = "30000000-0000-4000-8000-000000000001";
const input = { requestId, assignments: [{ profileId: player, team: "BLACK" }] };

function route({ role = "admin", error = null, data } = {}) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200, headers: init.headers }) } },
    "@/lib/referee-session": {
      requireReferee: async () => role ? { referee: { role, profileId: id }, db: { rpc: async (...args) => {
        calls.push(args);
        return { data: data ?? { game_id: id, request_id: requestId, action: "ASSIGN_UNASSIGNED", assigned_count: 1 }, error };
      } } } : { status: 401 },
      isRefereeContext: value => "referee" in value,
      adminOnly: value => value.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL("../src/app/api/referee/admin/games/[matchKind]/[gameId]/assign-players/route.ts", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports, require: name => modules[name], Set });
  return { calls, post: (body = input, matchKind = "solo", gameId = id) => exports.POST({ json: async () => body }, { params: Promise.resolve({ matchKind, gameId }) }) };
}

test("placing new players requires an authenticated admin", async () => {
  for (const [role, status] of [[null, 401], ["referee", 403]]) {
    const api = route({ role });
    assert.equal((await api.post()).status, status);
    assert.equal(api.calls.length, 0);
  }
});

test("player placement validates the game, unique players, teams and retry identity before writing", async () => {
  const api = route();
  assert.equal((await api.post(input, "clan")).status, 400);
  assert.equal((await api.post(input, "solo", "bad")).status, 400);
  for (const body of [null, [], {}, { ...input, requestId: "bad" }, { ...input, assignments: [] },
    { ...input, assignments: [input.assignments[0], input.assignments[0]] },
    { ...input, assignments: [{ profileId: player, team: "HOME" }] },
    { ...input, assignments: [{ profileId: "bad", team: "BLACK" }] }]) {
    assert.equal((await api.post(body)).status, 400);
  }
  assert.equal(api.calls.length, 0);
});

test("player placement uses the verified admin and strips client-controlled fields", async () => {
  const api = route();
  const result = await api.post({ ...input, actor_admin_id: player, reason: "Ignore existing teams",
    assignments: [{ ...input.assignments[0], consented: true }] });
  assert.equal(result.status, 200);
  assert.equal(result.body.ok, true);
  assert.equal(result.headers["Cache-Control"], "private, no-store");
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls)), [["admin_assign_unassigned_open_queue_players", {
    actor_admin_id: id, game_id_to_use: id, request_id_to_use: requestId,
    assignments_input: [{ profile_id: player, to_team: "BLACK" }],
  }]]);
});

test("a stale assignment, full position or missing migration never claims success", async () => {
  const conflict = await route({ error: { message: "This player has already been assigned. Refresh the roster." } }).post();
  assert.equal(conflict.status, 409);
  assert.match(conflict.body.error, /already been assigned/);
  assert.equal(conflict.body.ok, undefined);
  assert.match((await route({ error: { code: "PGRST202" } }).post()).body.error, /migration/);
});

test("an incomplete or mismatched assignment acknowledgement is rejected", async () => {
  for (const data of [ {}, { game_id: player, request_id: requestId, action: "ASSIGN_UNASSIGNED", assigned_count: 1 },
    { game_id: id, request_id: player, action: "ASSIGN_UNASSIGNED", assigned_count: 1 },
    { game_id: id, request_id: requestId, action: "ASSIGN_UNASSIGNED", assigned_count: 0 }]) {
    const result = await route({ data }).post();
    assert.equal(result.status, 502);
    assert.equal(result.body.ok, undefined);
  }
});
