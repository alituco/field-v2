import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { checkResults, plannedJobs } from "./ci-results.mjs";

const flags = [...Object.keys(plannedJobs), "release"];
const all = Object.fromEntries(flags.map(key => [key, "true"]));
function resultsFor(plan) {
  return {
    preflight: { result: "success" },
    ...Object.fromEntries(Object.entries(plannedJobs).flatMap(([key, jobs]) =>
      jobs.map(job => [job, { result: plan[key] === "true" ? "success" : "skipped" }]))),
  };
}

test("full release requires every baseline and journey result", () => {
  assert.match(checkResults(all, resultsFor(all)), /passed/);
  for (const job of ["preflight", ...Object.values(plannedJobs).flat()]) {
    for (const result of ["failure", "cancelled", "skipped", "unknown", undefined]) {
      const results = resultsFor(all);
      results[job] = { result };
      assert.throws(() => checkResults(all, results), undefined, `${job}: ${result}`);
    }
  }
});

test("reduced plans allow skips only for unneeded jobs and never hide failures", () => {
  for (const key of Object.keys(plannedJobs)) {
    const plan = { ...all, release: "false", [key]: "false" };
    assert.doesNotThrow(() => checkResults(plan, resultsFor(plan)));
    for (const job of plannedJobs[key]) {
      for (const result of ["success", "failure", "cancelled", undefined]) {
        const results = resultsFor(plan);
        results[job] = { result };
        assert.throws(() => checkResults(plan, results));
      }
    }
    assert.throws(() => checkResults({ ...plan, release: "true" }, resultsFor(plan)), /complete/);
  }
});

test("missing and malformed plan flags fail closed", () => {
  for (const key of flags) {
    for (const value of [undefined, true, false, "yes", null]) {
      assert.throws(() => checkResults({ ...all, [key]: value }, resultsFor(all)));
    }
  }
  for (const value of [null, [], "false"]) {
    assert.throws(() => checkResults(value, resultsFor(all)));
    assert.throws(() => checkResults(all, value));
  }
});

test("actual gate CLI returns failure rather than masking invalid inputs", () => {
  const script = new URL("./ci-results.mjs", import.meta.url);
  for (const [plan, results, status] of [
    [JSON.stringify(all), JSON.stringify(resultsFor(all)), 0],
    ["{}", "{}", 1],
    ["not json", "{}", 1],
  ]) {
    const result = spawnSync(process.execPath, [script.pathname], {
      env: { CI_PLAN: plan, CI_RESULTS: results }, encoding: "utf8",
    });
    assert.equal(result.status, status, result.stderr);
  }
});
