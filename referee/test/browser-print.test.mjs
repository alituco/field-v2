import assert from "node:assert/strict";
import test from "node:test";

import { printStandaloneHtml } from "../src/lib/browser-print.ts";

test("printable policy HTML is written before opening the print dialog", () => {
  const calls = [];
  const printableWindow = {
    opener: { unsafe: true },
    document: {
      readyState: "complete",
      open: () => calls.push("document.open"),
      write: (html) => calls.push(["document.write", html]),
      close: () => calls.push("document.close"),
    },
    focus: () => calls.push("focus"),
    print: () => calls.push("print"),
    setTimeout: (callback) => {
      calls.push("timeout");
      callback();
      return 1;
    },
    addEventListener: () => calls.push("load-listener"),
  };
  const openedWith = [];

  const didOpen = printStandaloneHtml("<main>Field policy</main>", (url, target) => {
    openedWith.push(url, target);
    return printableWindow;
  });

  assert.equal(didOpen, true);
  assert.deepEqual(openedWith, ["about:blank", "_blank"]);
  assert.equal(printableWindow.opener, null);
  assert.deepEqual(calls, [
    "document.open",
    ["document.write", "<main>Field policy</main>"],
    "document.close",
    "timeout",
    "focus",
    "print",
  ]);
});

test("blocked popups fail cleanly without attempting to print", () => {
  assert.equal(printStandaloneHtml("<main>Field policy</main>", () => null), false);
});
