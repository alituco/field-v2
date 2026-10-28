import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
const asset = { method: "GET", mode: "cors", url: "https://ops.example/_next/static/chunks/app.js" };

function worker({ openFails = false, readFails = false, writeFails = false, write, cached, keysFail = false, deleteFail = false } = {}) {
  const handlers = {};
  const calls = { fetch: 0, put: 0, claim: 0, deleted: [] };
  const network = new Response("working asset", { status: 200 });
  vm.runInNewContext(source, {
    URL,
    self: { location: { origin: "https://ops.example" }, addEventListener: (name, fn) => handlers[name] = fn, skipWaiting: () => {}, clients: { claim: async () => calls.claim++ } },
    caches: {
      keys: async () => { if (keysFail) throw Error("storage denied"); return ["field-ops-static-v1", "field-ops-static-v2", "field-ops-static-v3", "unrelated-cache"]; },
      delete: async (key) => { calls.deleted.push(key); if (deleteFail) throw Error("storage denied"); },
      open: async () => {
        if (openFails) throw Error("storage denied");
        return { match: async () => { if (readFails) throw Error("read failed"); return cached; }, put: async () => { calls.put++; if (writeFails) throw Error("quota exceeded"); if (write) await write; } };
      },
    },
    fetch: async () => { calls.fetch++; return network; },
  });
  return {
    calls,
    fetch(request = asset) {
      let response;
      const background = [];
      handlers.fetch({ request, respondWith: (value) => response = value, waitUntil: (value) => background.push(value) });
      return { response, background };
    },
    async activate() { let promise; handlers.activate({ waitUntil: (value) => promise = value }); await promise; },
  };
}

for (const option of ["openFails", "readFails", "writeFails"]) {
  test(`asset remains usable when ${option}`, async () => {
    const app = worker({ [option]: true });
    const event = app.fetch();
    assert.equal(await (await event.response).text(), "working asset");
    await Promise.all(event.background);
    assert.equal(app.calls.fetch, 1);
  });
}

test("asset delivery does not wait for a cache write", async () => {
  let finish;
  const app = worker({ write: new Promise((resolve) => finish = resolve) });
  const event = app.fetch();
  assert.equal(await (await event.response).text(), "working asset");
  assert.equal(app.calls.put, 1);
  finish();
  await Promise.all(event.background);
});

test("cached static assets still work while operational and foreign requests bypass caching", async () => {
  const app = worker({ cached: new Response("cached") });
  assert.equal(await (await app.fetch().response).text(), "cached");
  for (const request of [
    { ...asset, mode: "navigate" }, { ...asset, method: "POST" },
    { ...asset, url: "https://ops.example/api/referee/me" },
    { ...asset, url: "https://ops.example/admin" },
    { ...asset, url: "https://ops.example/broadcast/test" },
    { ...asset, url: "https://elsewhere.example/favicon.ico" },
  ]) assert.equal(app.fetch(request).response, undefined);
  assert.equal(app.calls.fetch, 0);
});

test("activation cleans only obsolete Ops static caches and claims clients", async () => {
  const app = worker();
  await app.activate();
  assert.deepEqual(app.calls.deleted, ["field-ops-static-v1", "field-ops-static-v2"]);
  assert.equal(app.calls.claim, 1);
});
for (const option of ["keysFail", "deleteFail"]) {
  test(`activation still claims clients when ${option}`, async () => {
    const app = worker({ [option]: true });
    await app.activate();
    assert.equal(app.calls.claim, 1);
  });
}
