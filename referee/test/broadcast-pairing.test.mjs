import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";
import * as crypto from "node:crypto";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { NextResponse } = require("next/server");
function load(file, overrides = {}) {
  const exports = {};
  const compiled = ts.transpileModule(readFileSync(new URL(file, import.meta.url), "utf8"), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(compiled, {
    exports, Buffer, Date, process: { env: {} }, console,
    require(name) {
      if (name in overrides) return overrides[name];
      if (name === "node:crypto") return crypto;
      if (name === "next/server") return { NextResponse };
      throw new Error(`Unexpected import ${name}`);
    },
  });
  return exports;
}
const token = crypto.randomBytes(32).toString("base64url");
const deviceKey = "paired-8ebbf0be-3612-4e18-8352-72a5b3c41803";
const matchId = "a4116ec2-8946-49b1-ade1-f2fc61b7ca3f";
const session = {
  deviceKey, matchId, matchKind: "SOLO", ownerId: "owner", displayName: "Ref laptop",
  expiresAt: "2026-10-19T00:00:00.000Z", venue: "Pitch 1", startsAt: null,
  matchLabel: "White Team vs Black Team", refereeName: "Ref", status: "READY", matchStatus: "FULL",
};
const request = (value = token) => new Request("https://ops.example/api/broadcast-agent/session", {
  headers: value === null ? {} : { authorization: `Bearer ${value}` },
});

test("pairing codes normalize display separators and never accept ambiguous characters", () => {
  const lib = load("../src/lib/broadcast-pairing.ts", { "./supabase-admin": {} });
  for (let i = 0; i < 30; i++) {
    const code = lib.newPairingCode();
    assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    assert.equal(lib.normalizePairingCode(code.toLowerCase()), code.replaceAll("-", ""));
  }
  for (const code of ["ABCDEFGHIJKL", "0000-OOOO-IIII", "ABCD-EFGH-JKL", {}, null]) {
    assert.throws(() => lib.normalizePairingCode(code));
  }
});

test("only generated device credentials reach auth lookup, and only their digest reaches database", async () => {
  const calls = [];
  const db = { rpc: async (name, args) => { calls.push([name,args]); return { data: session, error: null }; } };
  const lib = load("../src/lib/broadcast-pairing.ts", { "./supabase-admin": { createSupabaseAdmin: () => db } });
  for (const value of [null,"shared-secret","", "x".repeat(44), "!".repeat(43)]) {
    const reply = await lib.getBroadcastAgentContext(request(value));
    assert.equal(reply.status, 401);
  }
  assert.equal(calls.length, 0);
  const context = await lib.getBroadcastAgentContext(request());
  assert.equal(context.deviceKey, deviceKey);
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [["broadcast_device_session", { credential_hash: crypto.createHash("sha256").update(token).digest("hex") }]]);
  assert.ok(!JSON.stringify(calls).includes(token));
});

test("revocation and assignment denial are 401, transient database failure is 503", async () => {
  for (const [code, expected] of [["42501",401],["P0001",401],["57014",503],["ECONNRESET",503]]) {
    const lib = load("../src/lib/broadcast-pairing.ts", {
      "./supabase-admin": { createSupabaseAdmin: () => ({ rpc: async () => ({ data: null, error: { code, message: "private provider details" } }) }) },
    });
    const response = await lib.getBroadcastAgentContext(request());
    assert.equal(response.status, expected);
    assert.ok(!(await response.text()).includes("private provider details"));
  }
});

test("public session response omits capability digest, database and owner identity", () => {
  const lib = load("../src/lib/broadcast-pairing.ts", { "./supabase-admin": {} });
  const response = lib.publicBroadcastSession({ ...session, tokenHash: "secret digest", db: "private db" });
  assert.equal(response.matchId, matchId);
  for (const key of ["ownerId","tokenHash","db"]) assert.equal(key in response, false);
});

test("revoked provider holds remain visible for administrator cleanup without advertising readiness", async () => {
  const calls = [];
  const credential = { device_key: deviceKey, expires_at: new Date(Date.now()+3600000).toISOString(),
    revoked_at: new Date().toISOString(), reservation_active: false, test_input_id: "private-input" };
  const camera = { device_key: deviceKey, display_name: "Ref laptop", status: "READY", obs_connected: true,
    obs_streaming: false, last_seen_at: new Date().toISOString() };
  const db = { from(table) {
    const query = {};
    for (const name of ["select","eq","or","order","limit"]) query[name] = (...args) => { calls.push([table,name,...args]); return query; };
    query.maybeSingle = async () => ({ data: credential, error: null });
    query.single = async () => ({ data: camera, error: null });
    return query;
  } };
  const lib = load("../src/lib/broadcast-pairing.ts", { "./supabase-admin": {} });
  const device = await lib.getPairedBroadcastDevice(db,"SOLO",matchId);
  assert.equal(device.deviceKey,deviceKey);
  assert.equal(device.revokedAt,credential.revoked_at);
  assert.equal(device.status,"OFFLINE");
  assert.equal(device.obsConnected,false);
  assert.equal(device.reservationActive,false);
  assert.equal(device.testCleanupPending,true);
  assert.ok(calls.some(call => call[1] === "or" && call[2] === "revoked_at.is.null,reservation_active.eq.true,test_input_id.not.is.null"));
  assert.equal("test_input_id" in device,false);
});

test("overlay grant works only for its paired device and exact match, and observes revocation", async () => {
  const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
  let revoked = false;
  const db = {
    from() { const query = { select() { return query; }, eq() { return query; }, maybeSingle: async () => ({ data: { token_hash: tokenHash }, error: null }) }; return query; },
    rpc: async () => revoked ? { data: null, error: { code: "42501" } } : { data: session, error: null },
  };
  const lib = load("../src/lib/broadcast-agent-auth.ts", { "./supabase-admin": { createSupabaseAdmin: () => db } });
  const grant = lib.pairedBroadcastOverlayToken({ ...session, db, tokenHash });
  assert.ok(!grant.includes(tokenHash));
  assert.ok(!grant.includes(token));
  assert.equal(await lib.authorizeBroadcastOverlay(grant, "SOLO", matchId), true);
  assert.equal(await lib.authorizeBroadcastOverlay(grant, "CLAN", matchId), false);
  assert.equal(await lib.authorizeBroadcastOverlay(grant, "SOLO", crypto.randomUUID()), false);
  assert.equal(await lib.authorizeBroadcastOverlay(grant.slice(0,-1)+"!", "SOLO", matchId), false);
  revoked = true;
  assert.equal(await lib.authorizeBroadcastOverlay(grant, "SOLO", matchId), false);
});

test("pairing redemption forwards hashes only and returns no raw capability", async () => {
  const lib = load("../src/lib/broadcast-pairing.ts", { "./supabase-admin": {} });
  const calls = [];
  const route = load("../src/app/api/broadcast-agent/pair/route.ts", {
    "@/lib/broadcast-pairing": lib,
    "@/lib/supabase-admin": { createSupabaseAdmin: () => ({ rpc: async (name,args) => { calls.push([name,args]); return { data: session, error: null }; } }) },
  });
  const response = await route.POST(new Request("https://ops.example/api/broadcast-agent/pair", {
    method: "POST", body: JSON.stringify({ code: "ABCD-EFGH-JKLM", displayName: "My Mac", deviceToken: token }),
  }));
  assert.equal(response.status, 200);
  const text = await response.text();
  assert.ok(!text.includes(token));
  assert.ok(!JSON.stringify(calls).includes(token));
  assert.equal(calls[0][1].pair_code_hash, crypto.createHash("sha256").update("ABCDEFGHJKLM").digest("hex"));
});
