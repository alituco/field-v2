import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import vm from "node:vm";
const require = createRequire(import.meta.url);
const ts = require("typescript");
const { NextResponse } = require("next/server");

function harness(initial = "CLAIMED") {
  const command = { id: "command-1", fixture_id: null, open_queue_game_id: "game-1", device_key: "device-1", action: "START_STREAM", status: initial };
  const writes = [];
  const db = { from(table) {
    const filters = [];
    let values;
    const query = {
      select() { return query; },
      eq(key,value) { filters.push([key,value]); return query; },
      is() { return query; },
      update(value) { values = value; return query; },
      async single() {
        if (filters.some(([key,value]) => command[key] !== value)) return { data: null,error: { message: "Not found" } };
        return { data: { ...command }, error: null };
      },
      then(resolve,reject) {
        if (values) {
          writes.push({ table, values });
          if (table === "broadcast_commands") Object.assign(command,values);
        }
        return Promise.resolve({ data: null,error: null }).then(resolve,reject);
      },
    };
    return query;
  } };
  const modules = {
    "next/server": { NextResponse },
    "@/lib/broadcast-agent-auth": {},
    "@/lib/broadcast-pairing": { getBroadcastAgentContext: async () => ({ db,deviceKey: "device-1",matchKind: "SOLO",matchId: "game-1" }) },
    "@/lib/broadcasts": { syncOpenQueueBroadcastFromCloudflare: async () => null },
  };
  const exports = {};
  const compiled = ts.transpileModule(readFileSync(new URL("../src/app/api/broadcast-agent/commands/route.ts",import.meta.url),"utf8"),{
    compilerOptions: { module: ts.ModuleKind.CommonJS,target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(compiled,{ exports,Date,require: name => { assert.ok(name in modules, name); return modules[name]; } });
  const ack = (ok,commandId = "command-1") => exports.POST(new Request("https://ops.example/api/broadcast-agent/commands",{
    method:"POST",body:JSON.stringify({ commandId,ok,errorMessage: ok ? null : "Camera unavailable",obsStreaming: ok }),
  }));
  return { ack, command, writes };
}

test("lost failed acknowledgement retries without rewriting or wedging the command queue",async () => {
  const h = harness();
  assert.equal((await h.ack(false)).status,200);
  assert.equal(h.command.status,"FAILED");
  const before = h.writes.length;
  const retried = await h.ack(false);
  assert.equal(retried.status,200);
  assert.equal((await retried.json()).ignored,true);
  assert.equal(h.writes.length,before);
});
test("a superseded command accepts receipt without resurrecting a successful stale start",async () => {
  const h = harness("FAILED");
  assert.equal((await h.ack(true)).status,200);
  assert.equal(h.command.status,"FAILED");
  assert.equal(h.writes.length,0);
});
test("a contradictory receipt cannot downgrade an acknowledged command",async () => {
  const h = harness("ACKNOWLEDGED");
  assert.equal((await h.ack(false)).status,200);
  assert.equal(h.command.status,"ACKNOWLEDGED");
  assert.equal(h.writes.length,0);
});
test("unclaimed and unknown commands still reject receipt without mutations",async () => {
  const h = harness("PENDING");
  assert.equal((await h.ack(true)).status,400);
  assert.equal((await h.ack(true,"another-command")).status,400);
  assert.equal(h.writes.length,0);
});
