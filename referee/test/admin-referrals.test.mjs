import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as referrals from "../src/lib/admin-referrals.ts";

const ids = ["10000000-0000-4000-8000-000000000001", "10000000-0000-4000-8000-000000000002"];
const actor = { role: "admin", profileId: "10000000-0000-4000-8000-000000000003" };
const token = "abc123".repeat(8);
const input = { evidenceToken: token, orderedProfileIds: ids, note: "Reviewed the matching attendance records." };
const entries = ids.map((id, i) => ({ id, name: `Player ${i + 1}`, username: `player${i + 1}`, rank: 5, referral_count: 3, games_played: 7, referred_games_played: 11, needs_review: true, prize_eligible: false }));
const catalog = { season: { id: "s0", label: "Season 0", ended: false, starts_on: "2026-10-01", ends_on: "2026-12-31" }, qualified_total: 6, entries,
  tie_groups: [{ evidence_token: token, rank: 5, referral_count: 3, games_played: 7, referred_games_played: 11, entries, resolved: false, review_note: null, ordered_profile_ids: [] }] };

test("review requires complete-shaped unique UUID order, evidence, and reason; rejects actor injection", () => {
  assert.deepEqual(referrals.parseReferralTieReview(input), input);
  assert.equal(referrals.parseReferralTieReview({ ...input, note: `  ${input.note}  ` }).note, input.note);
  for (const changes of [
    { actor_admin_id: ids[0] }, { seasonId: "s1" }, { evidenceToken: "" }, { evidenceToken: "a".repeat(129) },
    { evidenceToken: "not a fingerprint!!!" }, { orderedProfileIds: [] }, { orderedProfileIds: [ids[0]] },
    { orderedProfileIds: [ids[0], ids[0].toUpperCase()] }, { orderedProfileIds: [ids[0], "bad-id"] },
    { orderedProfileIds: [ids[0], 7] }, { orderedProfileIds: null }, { note: "short" }, { note: "a".repeat(2001) },
  ]) assert.throws(() => referrals.parseReferralTieReview({ ...input, ...changes }));
  for (const value of [null, [], "input"]) assert.throws(() => referrals.parseReferralTieReview(value));
});

test("catalog preserves unresolved prize tie and does not convert source order into a winner", () => {
  const result = referrals.serializeAdminReferrals(catalog);
  assert.equal(result.qualifiedTotal, 6);
  assert.deepEqual(result.entries.map((row) => row.rank), [5, 5]);
  assert.deepEqual(result.entries.map((row) => row.prizeEligible), [false, false]);
  assert.ok(result.entries.every((row) => row.needsReview));
  assert.equal(result.tieGroups[0].evidenceToken, token);
  assert.deepEqual(result.tieGroups[0].orderedProfileIds, []);
  assert.equal(result.tieGroups[0].referredGamesPlayed, 11);
  assert.throws(() => referrals.serializeAdminReferrals({ ...catalog, entries: [{ ...entries[0], referral_count: -1 }] }));
  assert.throws(() => referrals.serializeAdminReferrals({ ...catalog, entries: null }));
});

function route(file, { identity = actor, error = null, data = catalog } = {}) {
  const calls = [];
  const modules = {
    "next/server": { NextResponse: { json: (body, init = {}) => ({ body, status: init.status ?? 200, headers: init.headers }) } },
    "@/lib/admin-referrals": referrals,
    "@/lib/referee-session": {
      requireReferee: async () => identity ? { referee: identity, db: { rpc: async (name, params) => { calls.push([name, params]); return { data, error }; } } } : { status: 401 },
      isRefereeContext: (value) => "referee" in value,
      adminOnly: (identity) => identity.role === "admin" ? null : { status: 403 },
    },
  };
  const ts = createRequire(import.meta.url)("typescript");
  const source = readFileSync(new URL(`../src/app/api/referee/admin/referrals/${file}`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, require: (name) => { if (!(name in modules)) throw new Error(`Unknown dependency ${name}`); return modules[name]; } });
  return { calls, ...exports };
}

test("anonymous and referee identities cannot read or review referral ties", async () => {
  for (const [identity, status] of [[null, 401], [{ ...actor, role: "referee" }, 403]]) {
    const read = route("route.ts", { identity });
    assert.equal((await read.GET({})).status, status); assert.equal(read.calls.length, 0);
    const write = route("review/route.ts", { identity });
    assert.equal((await write.POST({ json: async () => input })).status, status); assert.equal(write.calls.length, 0);
  }
});

test("admin reads are uncached and use the bound staff actor", async () => {
  const api = route("route.ts"); const result = await api.GET({});
  assert.equal(result.status, 200);
  assert.equal(result.headers["Cache-Control"], "private, no-store");
  assert.equal(api.calls[0][0], "admin_get_fieldrush_referrals");
  assert.equal(api.calls[0][1].actor_admin_id, actor.profileId);
  assert.equal(result.body.tieGroups[0].resolved, false);
});

test("review passes explicit order, exact evidence and bound actor without accepting forged fields", async () => {
  const api = route("review/route.ts");
  const result = await api.POST({ json: async () => ({ ...input, orderedProfileIds: [...ids].reverse() }) });
  assert.equal(result.status, 200); assert.equal(result.body.ok, true);
  assert.equal(result.headers["Cache-Control"], "private, no-store");
  assert.equal(api.calls[0][0], "admin_review_fieldrush_referral_tie");
  assert.deepEqual(JSON.parse(JSON.stringify(api.calls[0][1])), { actor_admin_id: actor.profileId, evidence_token_to_use: token, ordered_profile_ids: [...ids].reverse(), review_note: input.note });
  for (const body of [{ ...input, actor_admin_id: ids[0] }, { ...input, orderedProfileIds: [ids[0], ids[0]] }, { ...input, note: "bad" }]) {
    assert.equal((await api.POST({ json: async () => body })).status, 400);
  }
  assert.equal(api.calls.length, 1);
});

test("stale reviews, missing migration and invalid whole-group input are explicit failures", async () => {
  for (const [error, status, pattern] of [
    [{ code: "40001", message: "Counts changed" }, 409, /standings changed/],
    [{ code: "PGRST202", message: "Missing function" }, 503, /not installed/],
    [{ code: "42501", message: "Forbidden" }, 403, /active admin/],
    [{ code: "22023", message: "Choose every member of the current tied group." }, 400, /every member/],
  ]) {
    const api = route("review/route.ts", { error });
    const result = await api.POST({ json: async () => input });
    assert.equal(result.status, status); assert.match(result.body.error, pattern); assert.equal(result.body.ok, undefined);
  }
});

test("successful write with unreadable refreshed data reports saved outcome rather than asking for duplicate submission", async () => {
  const result = await route("review/route.ts", { data: null }).POST({ json: async () => input });
  assert.equal(result.status, 200); assert.equal(result.body.ok, true); assert.match(result.body.warning, /review was saved/);
  assert.equal((await route("route.ts", { data: null }).GET({})).status, 500);
});
