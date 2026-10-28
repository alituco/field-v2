import { pathToFileURL } from "node:url";

export const plannedJobs = Object.freeze({
  flutter: ["flutter"],
  android: ["android-builds"],
  ios: ["flutter-ios"],
  referee: ["referee"],
  broadcaster: ["broadcaster"],
  database: ["database"],
  backend: ["backend-staging"],
  player: ["prepare-staging-e2e", "android-staging-e2e"],
  browser: ["browser-staging-e2e"],
});

export function checkResults(plan, results) {
  if (!plan || typeof plan !== "object" || Array.isArray(plan) ||
      !results || typeof results !== "object" || Array.isArray(results)) {
    throw new Error("Missing or malformed CI plan/results.");
  }
  const failures = [];
  if (results.preflight?.result !== "success") {
    failures.push("preflight did not succeed");
  }
  for (const key of [...Object.keys(plannedJobs), "release"]) {
    if (!["true", "false"].includes(plan[key])) {
      throw new Error(`Invalid CI plan flag: ${key}`);
    }
  }
  // Release can never be granted by a reduced diagnostic or path-scoped plan.
  if (plan.release === "true" && Object.keys(plannedJobs).some(key => plan[key] !== "true")) {
    throw new Error("A staging release requires the complete check plan.");
  }
  for (const [key, jobs] of Object.entries(plannedJobs)) {
    for (const job of jobs) {
      const expected = plan[key] === "true" ? "success" : "skipped";
      const actual = results[job]?.result;
      if (actual !== expected) failures.push(`${job}: expected ${expected}, got ${actual ?? "missing"}`);
    }
  }
  if (failures.length) throw new Error(failures.join("; "));
  return "Every planned check passed; only explicitly unneeded jobs were skipped.";
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    console.log(checkResults(JSON.parse(process.env.CI_PLAN ?? "null"), JSON.parse(process.env.CI_RESULTS ?? "null")));
  } catch (error) {
    console.error(`CI gate failed: ${error.message}`);
    process.exitCode = 1;
  }
}
