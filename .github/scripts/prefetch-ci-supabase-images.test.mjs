import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { isDockerPullRateLimit, parseCiSupabaseImages, PINNED_CLI_VERSION, PINNED_KONG_TAG, prefetchCiSupabaseImages } from "./prefetch-ci-supabase-images.mjs";

const rows = [
  { name: "supabase/postgres", local: "17.6.1.132", remote: "99.99.99" },
  { name: "supabase/gotrue", local: "v2.189.0", remote: "v99.99.99" },
  { name: "postgrest/postgrest", local: "v14.12", remote: "v99.99" },
  { name: "supabase/realtime", local: "v2.103.2", remote: "v99.99.99" },
  { name: "supabase/storage-api", local: "v1.60.4", remote: "v99.99.99" },
  { name: "supabase/studio", local: "2026.06.03-sha-0bca601", remote: "" },
];
const expected = [
  "ghcr.io/supabase/postgres:17.6.1.132",
  "ghcr.io/supabase/gotrue:v2.189.0",
  "ghcr.io/supabase/postgrest:v14.12",
  "ghcr.io/supabase/realtime:v2.103.2",
  "ghcr.io/supabase/storage-api:v1.60.4",
  "ghcr.io/supabase/kong:2.8.1",
];
const success = (stdout = "") => ({ status: 0, signal: null, stdout, stderr: "" });
const limited = { status: 1, signal: null, stderr: "Error response from daemon: toomanyrequests: retry-after: 27.06µs, allowed: 44000/minute" };

function harness(options = {}) {
  const calls = [];
  const waits = [];
  const logs = [];
  const pulls = [...(options.pulls ?? [])];
  const fixture = {
    calls, waits, logs,
    options: {
      registry: "ghcr.io",
      execute: async (command, args) => {
        calls.push({ command, args });
        if (command === "supabase" && args[0] === "--version") return options.version ?? success(PINNED_CLI_VERSION + "\n");
        if (command === "supabase" && args[0] === "services") return options.services ?? success(JSON.stringify(rows));
        if (command === "docker" && args[0] === "pull") return pulls.shift() ?? success();
        if (command === "docker" && args[0] === "tag") return options.tag ?? success();
        throw new Error("Unexpected command: " + command + " " + args.join(" "));
      },
      sleep: async milliseconds => waits.push(milliseconds),
      log: message => logs.push(message),
    },
  };
  return fixture;
}

test("selects the five required local tags plus pinned Kong, never remote versions or excluded runtime-only images", () => {
  assert.deepEqual(parseCiSupabaseImages(JSON.stringify(rows)), expected);
  assert.equal(PINNED_CLI_VERSION, "2.105.0");
  assert.equal(PINNED_KONG_TAG, "2.8.1");
});

for (const [label, value] of [
  ["malformed JSON", "not JSON"],
  ["unsupported top-level shape", JSON.stringify({ services: rows })],
  ["missing realtime schema image", JSON.stringify(rows.filter(row => row.name !== "supabase/realtime"))],
  ["missing storage schema image", JSON.stringify(rows.filter(row => row.name !== "supabase/storage-api"))],
  ["duplicate identical entry", JSON.stringify([...rows, rows[0]])],
  ["conflicting duplicate version", JSON.stringify([...rows, { ...rows[0], local: "17.1.0" }])],
  ["remote-only version", JSON.stringify(rows.map(row => row.name === "supabase/realtime" ? { name: row.name, remote: row.remote } : row))],
  ...[null, "", "latest", "v2.103.2;echo injected", "v2.103.2/other", "v2.103.2@sha256:abc", " v2.103.2"].map(tag => [
    `unsafe/nonconcrete local tag ${JSON.stringify(tag)}`,
    JSON.stringify(rows.map(row => row.name === "supabase/realtime" ? { ...row, local: tag } : row)),
  ]),
]) {
  test(`fails closed on ${label}`, () => assert.throws(() => parseCiSupabaseImages(value)));
}

test("prefetches all six bootstrap images without starting a database", async () => {
  const fixture = harness();
  assert.equal(await prefetchCiSupabaseImages(fixture.options), 0);
  assert.deepEqual(fixture.calls.slice(0, 2), [
    { command: "supabase", args: ["--version"] },
    { command: "supabase", args: ["services", "--output", "json"] },
  ]);
  assert.deepEqual(fixture.calls.slice(2), expected.map(image => ({ command: "docker", args: ["pull", image] })));
  assert.deepEqual(fixture.waits, []);
  assert.ok(!fixture.calls.some(call => call.args[0] === "start"));
});

test("Realtime 429 is resolved before schema initialization using the exact ECR tag cached under the CLI's GHCR name", async () => {
  const fixture = harness({ pulls: [success(), success(), success(), limited, success()] });
  assert.equal(await prefetchCiSupabaseImages(fixture.options), 0);
  assert.deepEqual(fixture.calls.slice(5, 8), [
    { command: "docker", args: ["pull", "ghcr.io/supabase/realtime:v2.103.2"] },
    { command: "docker", args: ["pull", "public.ecr.aws/supabase/realtime:v2.103.2"] },
    { command: "docker", args: ["tag", "public.ecr.aws/supabase/realtime:v2.103.2", "ghcr.io/supabase/realtime:v2.103.2"] },
  ]);
  assert.deepEqual(fixture.waits, [30_000]);
  assert.ok(fixture.logs.at(-1).includes("All six"));
  assert.ok(!fixture.calls.some(call => call.args[0] === "start"));
});

test("one image has four total alternating downloads and at most 30/60/90 seconds of backoff", async () => {
  const fixture = harness({ pulls: [limited, limited, limited, success()] });
  assert.equal(await prefetchCiSupabaseImages(fixture.options), 0);
  assert.deepEqual(fixture.calls.slice(2, 6).map(call => call.args[1]), [
    expected[0], "public.ecr.aws/supabase/postgres:17.6.1.132", expected[0], "public.ecr.aws/supabase/postgres:17.6.1.132",
  ]);
  assert.deepEqual(fixture.waits, [30_000, 60_000, 90_000]);
  assert.equal(fixture.calls.filter(call => call.args[0] === "tag").length, 1);
});

test("exhausted download throttling preserves the last exit and never continues to other images or start", async () => {
  const fixture = harness({ pulls: [limited, limited, limited, { ...limited, status: 29 }] });
  assert.equal(await prefetchCiSupabaseImages(fixture.options), 29);
  assert.equal(fixture.calls.length, 6);
  assert.deepEqual(fixture.waits, [30_000, 60_000, 90_000]);
});

for (const [label, result, expectedStatus] of [
  ["authorization", { status: 1, stderr: "Error response from daemon: unauthorized: authentication required" }, 1],
  ["missing image", { status: 1, stderr: "Error response from daemon: manifest unknown" }, 1],
  ["network failure", { status: 7, stderr: "Error response from daemon: connection refused" }, 7],
  ["HTTP 500", { status: 9, stderr: "Error response from daemon: unexpected HTTP status: 500" }, 9],
  ["old 429 followed by auth failure", { status: 1, stderr: limited.stderr + "\nError response from daemon: unauthorized" }, 1],
  ["progress byte count 429 followed by other failure", { status: 1, stderr: "429 B downloaded\nError response from daemon: manifest unknown" }, 1],
  ["signal", { status: null, signal: "SIGTERM", stderr: limited.stderr }, 143],
  ["missing exit", { status: null, stderr: limited.stderr }, 1],
  ["spawn failure", { status: null, error: { code: "ENOENT" }, stderr: limited.stderr }, 127],
]) {
  test(`never retries or switches registries for ${label}`, async () => {
    const fixture = harness({ pulls: [result] });
    assert.equal(await prefetchCiSupabaseImages(fixture.options), expectedStatus);
    assert.equal(fixture.calls.length, 3);
    assert.deepEqual(fixture.waits, []);
  });
}

test("mirror non-rate failure and canonical tagging failure stop immediately", async () => {
  const mirror = harness({ pulls: [limited, { status: 18, stderr: "Error response from daemon: manifest unknown" }] });
  assert.equal(await prefetchCiSupabaseImages(mirror.options), 18);
  assert.equal(mirror.calls.length, 4);
  const tag = harness({ pulls: [limited, success()], tag: { status: 23, stderr: "tag failed" } });
  assert.equal(await prefetchCiSupabaseImages(tag.options), 23);
  assert.equal(tag.calls.length, 5);
  assert.deepEqual(tag.waits, [30_000]);
});

for (const [label, overrides, expectedStatus] of [
  ["different CLI version", { version: success("2.106.0\n") }, 1],
  ["missing CLI", { version: { status: null, error: { code: "ENOENT" } } }, 127],
  ["services command failure", { services: { status: 12, stderr: "config failed" } }, 12],
  ["bad services shape", { services: success("{}") }, 1],
]) {
  test(`stops before Docker for ${label}`, async () => {
    const fixture = harness(overrides);
    assert.equal(await prefetchCiSupabaseImages(fixture.options), expectedStatus);
    assert.ok(fixture.calls.every(call => call.command === "supabase"));
  });
}

test("unexpected registry stops before any command", async () => {
  const fixture = harness();
  assert.equal(await prefetchCiSupabaseImages({ ...fixture.options, registry: "untrusted.example" }), 1);
  assert.deepEqual(fixture.calls, []);
});

for (const stderr of [
  limited.stderr,
  "Error response from daemon: received unexpected HTTP status: 429 Too Many Requests",
  "error pulling image configuration: download failed: toomanyrequests: rate exceeded",
  "\u001b[31mtoomanyrequests: rate exceeded\u001b[0m\r\n",
]) {
  test(`recognizes an explicit Docker download throttle: ${stderr.slice(0, 65)}`, () => {
    assert.equal(isDockerPullRateLimit({ status: 1, stderr }), true);
  });
}

test("real entrypoint resolves version/services and executes six hermetic Docker pulls", async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "field-ci-image-prefetch-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const script = fileURLToPath(new URL("./prefetch-ci-supabase-images.mjs", import.meta.url));
  await writeFile(path.join(directory, "supabase"), `#!${process.execPath}\n` +
    `if (process.argv[2] === "--version") console.log(${JSON.stringify(PINNED_CLI_VERSION)});\n` +
    `else if (process.argv[2] === "services") console.log(${JSON.stringify(JSON.stringify(rows))});\n` +
    `else process.exitCode = 33;\n`, { mode: 0o755 });
  await writeFile(path.join(directory, "docker"), `#!${process.execPath}\n` +
    `console.log("FIXTURE_DOCKER " + JSON.stringify(process.argv.slice(2)));\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [script], {
    env: { PATH: directory }, encoding: "utf8", timeout: 10_000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0);
  const pulls = result.stdout.split("\n").filter(line => line.startsWith("FIXTURE_DOCKER ")).map(line => JSON.parse(line.slice(15)));
  assert.deepEqual(pulls, expected.map(image => ["pull", image]));
  assert.match(result.stderr, /All six local Supabase bootstrap images are cached/);
});
