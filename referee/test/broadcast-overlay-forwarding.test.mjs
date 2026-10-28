import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL(
  "../src/app/broadcast/overlay/[fixtureId]/overlay-client.tsx",
  import.meta.url,
), "utf8");

function render({ fixtureId = "match-id", search = "", hash = "" } = {}) {
  const effects = [];
  const replacements = [];
  const document = {
    documentElement: { style: { background: "initial-html" } },
    body: { style: { background: "initial-body" } },
  };
  const exports = {};
  const compiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      jsx: ts.JsxEmit.ReactJSX,
    },
  }).outputText;
  vm.runInNewContext(compiled, {
    exports, URL, URLSearchParams, encodeURIComponent, document,
    window: { location: {
      origin: "https://ops-staging.example",
      search,
      hash,
      replace: value => replacements.push(value),
    } },
    require(name) {
      if (name === "react") return { useEffect: effect => effects.push(effect) };
      if (name === "react/jsx-runtime") return { jsx: (type, props) => ({ type, props }) };
      throw new Error(`Unexpected import ${name}`);
    },
  });
  const view = exports.default({ fixtureId });
  const cleanup = effects[0]();
  return { view, replacements, document, cleanup };
}

test("legacy overlay replaces its address while keeping capabilities in the fragment", () => {
  const fragment = "#token=paired.device.capability%2Bvalue";
  const result = render({ hash: fragment });
  assert.equal(result.replacements.length, 1);
  const target = new URL(result.replacements[0]);
  assert.equal(target.origin, "https://ops-staging.example");
  assert.equal(target.pathname, "/broadcast/obs/match-id");
  assert.equal(target.search, "");
  assert.equal(target.hash, fragment);
  assert.equal(result.view.type, "div");
  assert.equal(result.view.props.className, "broadcast-overlay-root");
  assert.equal("children" in result.view.props, false);
});

test("solo kind is forwarded without copying token or arbitrary query parameters", () => {
  const result = render({
    search: "?kind=solo&token=must-not-forward&redirect=https://elsewhere.example",
    hash: "#token=fragment-only-token",
  });
  const target = new URL(result.replacements[0]);
  assert.equal(target.search, "?kind=solo");
  assert.equal(target.hash, "#token=fragment-only-token");
  assert.equal(target.searchParams.has("token"), false);
  assert.equal(result.replacements[0].includes("must-not-forward"), false);
});

test("fixture paths remain one encoded component and unknown kinds are omitted", () => {
  const result = render({ fixtureId: "match/other?kind=solo", search: "?kind=unknown" });
  const target = new URL(result.replacements[0]);
  assert.equal(target.pathname, "/broadcast/obs/match%2Fother%3Fkind%3Dsolo");
  assert.equal(target.search, "");
  assert.equal(target.hash, "");
});

test("forwarding stays transparent and restores previous inline background styles", () => {
  const result = render();
  assert.equal(result.document.documentElement.style.background, "transparent");
  assert.equal(result.document.body.style.background, "transparent");
  result.cleanup();
  assert.equal(result.document.documentElement.style.background, "initial-html");
  assert.equal(result.document.body.style.background, "initial-body");
});
