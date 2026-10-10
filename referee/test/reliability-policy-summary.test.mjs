import assert from "node:assert/strict";
import test from "node:test";

import { reliabilityPolicyDefaults } from "../src/lib/reliability-policy.ts";
import {
  buildReliabilityPolicySummary,
  reliabilityPolicySummaryHtml,
} from "../src/lib/reliability-policy-summary.ts";

const metadata = {
  status: "DRAFT",
  version: 4,
  effectiveFrom: "2026-08-01T00:00:00+03:00",
  changeSummary: "Clarify cancellation boundaries.",
  generatedAt: new Date("2026-07-31T12:00:00Z"),
};

test("human summary explains cancellation bands using canonical values", () => {
  const document = buildReliabilityPolicySummary(reliabilityPolicyDefaults, metadata);
  const solo = document.sections.find((section) => section.id === "solo-cancellations");
  const clan = document.sections.find((section) => section.id === "clan-cancellations");

  assert.equal(document.status, "DRAFT");
  assert.equal(document.versionLabel, "Version 4");
  assert.match(solo.rules[0].title, /at least 24 hours/);
  assert.deepEqual(solo.rules[0].facts.slice(0, 2), ["Refund: 100%", "Reliability consequence: 0 strikes"]);
  assert.match(solo.rules[1].title, /between 10 and 24 hours/);
  assert.deepEqual(solo.rules[1].facts.slice(0, 2), ["Refund: 50%", "Reliability consequence: 1 strike"]);
  assert.match(clan.rules.at(-1).explanation, /3–0 forfeit win/);
});

test("human summary includes attendance, deposits, sanctions, SR, and appeals", () => {
  const document = buildReliabilityPolicySummary(reliabilityPolicyDefaults, metadata);
  const text = document.sections.flatMap((section) => [
    section.title,
    section.introduction,
    ...section.rules.flatMap((rule) => [rule.title, rule.explanation, ...(rule.facts ?? [])]),
  ]).join("\n");

  assert.match(text, /six|6v6/i);
  assert.match(text, /Player reliability deposit/);
  assert.match(text, /Player sanction ladder/);
  assert.match(text, /Late-player SR/);
  assert.match(text, /Routine traffic is not automatically excused/);
  assert.match(text, /Field Wallet in BHD/);
});

test("downloadable document is standalone, printable, and escapes admin copy", () => {
  const document = buildReliabilityPolicySummary(reliabilityPolicyDefaults, {
    ...metadata,
    changeSummary: "Refund <script>alert('x')</script>",
  });
  const html = reliabilityPolicySummaryHtml(document);

  assert.match(html, /^<!doctype html>/);
  assert.match(html, /@media print/);
  assert.match(html, /Field Reliability Policy/);
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;/);
});
