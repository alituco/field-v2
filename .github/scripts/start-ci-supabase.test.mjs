import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { canRetryImagePull, RETRY_DELAYS_MS, runCiSupabase, START_ARGS, START_COMMAND } from "./start-ci-supabase.mjs";

const stream429 = "failed to display json stream: error pulling image configuration: download failed after attempts=1: toomanyrequests: retry-after: 27.06µs, allowed: 44000/minute";
const pull429 = "failed to pull docker image: Error response from daemon: received unexpected HTTP status: 429 Too Many Requests";
const help = "Try rerunning the command with --debug to troubleshoot the error.";
const output = (...lines) => lines.join("\n");
const failed = (text = stream429, status = 1) => ({ status, signal: null, output: text });
const success = { status: 0, signal: null, output: "Started supabase local development setup." };

for (const [label, text] of [
  ["exact streamed-image 429", stream429],
  ["exact direct-image 429", pull429],
  ["exact direct streamed Docker 429", "failed to display json stream: toomanyrequests: retry-after: 157.356µs, allowed: 44000/minute"],
  ["pinned CLI help suffix", output(stream429, help)],
  ["database-start marker before the actual image pull", output("Starting database...", "Stopping containers...", stream429, help)],
  ["ordinary progress and repeated same registry failures", output(pull429, "Retrying after 4s: ghcr.io/supabase/postgres:17.6.1.132", pull429, stream429)],
  ["actual three-pull failure sequence", output(
    "Starting database...",
    "17.6.1.132: Pulling from supabase/postgres",
    "failed to display json stream: error pulling image configuration: download failed after attempts=1: toomanyrequests: retry-after: 78.519µs, allowed: 44000/minute",
    "Retrying after 4s: ghcr.io/supabase/postgres:17.6.1.132",
    "17.6.1.132: Pulling from supabase/postgres",
    "failed to display json stream: toomanyrequests: retry-after: 157.356µs, allowed: 44000/minute",
    "Retrying after 8s: ghcr.io/supabase/postgres:17.6.1.132",
    "17.6.1.132: Pulling from supabase/postgres",
    "Stopping containers...",
    stream429,
    help,
  )],
  ["ANSI-colored failure and help", `\u001b[31m${stream429}\u001b[0m\r\n${help}\r\n`],
  ["OSC controls", `\u001b]0;terminal-title\u0007${stream429}`],
]) {
  test(`retries only a recognized pre-schema pull failure: ${label}`, () => {
    assert.equal(canRetryImagePull(text), true);
  });
}

for (const [label, text] of [
  ["empty output", ""],
  ["unstructured 429", "HTTP 429 Too Many Requests"],
  ["unknown streamed 429", "failed to display json stream: arbitrary service returned HTTP 429"],
  ["ordinary network failure", "failed to pull docker image: network unreachable"],
  ["schema initialization", output("Initialising schema...", stream429)],
  ["alternate schema spelling", output("Initializing schema...", stream429)],
  ["global seeding", output("Seeding globals from roles.sql...", stream429)],
  ["data seeding", output("Seeding data from supabase/seed.sql...", stream429)],
  ["other seeding phase", output("Seeding from custom local fixture...", stream429)],
  ["migration execution", output("Applying migration 20261022000100_example.sql...", stream429)],
  ["later helper image pull", output("Starting containers...", stream429)],
  ["existing database backup", output("Starting database from backup...", stream429)],
  ["already running database", output("Postgres database is already running.", stream429)],
  ["already running stack", output("supabase start is already running.", stream429)],
  ["SQL error after an earlier 429", output(stream429, "ERROR: relation does not exist (SQLSTATE 42P01)", help)],
  ["SQL error before a final pull 429", output("ERROR: relation does not exist", stream429, help)],
  ["SQLSTATE without an ERROR prefix", output("statement failed (SQLSTATE 57014)", stream429)],
  ["colored earlier schema phase", output("\u001b[32mInitialising schema...\u001b[0m", "x".repeat(100_000), stream429)],
  ["authentication failure", output("unauthorized: authentication required", stream429)],
  ["access denial", output("denied: requested access to the resource is denied", stream429)],
  ["permission failure", output("permission denied", stream429)],
  ["invalid configuration", output("invalid configuration in supabase/config.toml", stream429)],
  ["configuration load failure", output("failed to load config: invalid value", stream429)],
  ["invalid CLI flag", output("unknown flag: --typo", stream429)],
  ["health-check failure", output("service health check failed", stream429)],
  ["unhealthy database", output("supabase_db_field_v2 is not ready: unhealthy", stream429)],
  ["unavailable Docker daemon", output("Cannot connect to the Docker daemon", stream429)],
  ["connection failure", output("connection refused", stream429)],
  ["different final failure", output(stream429, "failed to create container: invalid configuration", help)],
  ["different earlier terminal failure", output("failed to inspect docker image: unexpected EOF", stream429)],
  ["unknown trailing message", output(stream429, "An unexpected error occurred.")],
]) {
  test(`fails closed without retry: ${label}`, () => {
    assert.equal(canRetryImagePull(text), false);
  });
}

test("non-string output cannot establish a retryable registry failure", () => {
  for (const value of [null, undefined, {}, []]) assert.equal(canRetryImagePull(value), false);
});

function harness(results) {
  const calls = [];
  const waits = [];
  const messages = [];
  return {
    calls, waits, messages,
    options: {
      execute: async (command, args) => {
        calls.push({ command, args });
        assert.ok(calls.length <= results.length, "Unexpected extra CLI invocation");
        return results[calls.length - 1];
      },
      sleep: async milliseconds => waits.push(milliseconds),
      log: message => messages.push(message),
    },
  };
}

test("successful start executes the exact original CLI command once", async () => {
  const fixture = harness([success]);
  assert.equal(await runCiSupabase(fixture.options), 0);
  assert.deepEqual(fixture.calls, [{
    command: "supabase",
    args: ["start", "--exclude", "studio,imgproxy,mailpit,logflare,vector,realtime,storage-api,edge-runtime,postgres-meta,supavisor"],
  }]);
  assert.equal(START_COMMAND, "supabase");
  assert.deepEqual(fixture.calls[0].args, START_ARGS);
  assert.deepEqual(fixture.waits, []);
  assert.deepEqual(fixture.messages, []);
});

test("registry throttling uses at most four identical starts with 30/60/90-second waits", async () => {
  const fixture = harness([failed(), failed(), failed(), success]);
  assert.equal(await runCiSupabase(fixture.options), 0);
  assert.equal(fixture.calls.length, 4);
  assert.ok(fixture.calls.every(call => call.command === START_COMMAND && JSON.stringify(call.args) === JSON.stringify(START_ARGS)));
  assert.deepEqual(fixture.waits, [30_000, 60_000, 90_000]);
  assert.deepEqual(fixture.waits, RETRY_DELAYS_MS);
  assert.equal(fixture.messages.length, 3);
  assert.match(fixture.messages[2], /90s \(4\/4\)/);
});

test("exhausted registry failures preserve the final nonzero exit status", async () => {
  const fixture = harness([failed(), failed(), failed(), failed(stream429, 23)]);
  assert.equal(await runCiSupabase(fixture.options), 23);
  assert.equal(fixture.calls.length, 4);
  assert.deepEqual(fixture.waits, RETRY_DELAYS_MS);
});

for (const [label, result, expected] of [
  ["SQL failure", failed(output("Applying migration example.sql...", "ERROR: bad schema (SQLSTATE 42P01)"), 17), 17],
  ["configuration failure", failed("failed to load config", 2), 2],
  ["authentication failure", failed("unauthorized: authentication required", 4), 4],
  ["health failure", failed("database is not ready: unhealthy", 5), 5],
  ["termination signal", { status: null, signal: "SIGTERM", output: stream429 }, 143],
  ["interrupt signal", { status: null, signal: "SIGINT", output: stream429 }, 130],
  ["signal despite nonzero status", { status: 1, signal: "SIGTERM", output: stream429 }, 143],
  ["missing process exit", { status: null, signal: null, output: stream429 }, 1],
  ["undefined process exit", { output: stream429 }, 1],
  ["CLI executable missing", { status: null, signal: null, output: stream429, error: { code: "ENOENT" } }, 127],
  ["spawn error", { status: 1, signal: null, output: stream429, error: { code: "EACCES" } }, 1],
]) {
  test(`runner never retries ${label} and preserves its failure`, async () => {
    const fixture = harness([result]);
    assert.equal(await runCiSupabase(fixture.options), expected);
    assert.equal(fixture.calls.length, 1);
    assert.deepEqual(fixture.waits, []);
  });
}

test("a registry retry followed by a migration error stops immediately", async () => {
  const fixture = harness([failed(), failed(output(stream429, "Applying migration example.sql...", "ERROR: duplicate relation (SQLSTATE 42P07)", help), 19)]);
  assert.equal(await runCiSupabase(fixture.options), 19);
  assert.equal(fixture.calls.length, 2);
  assert.deepEqual(fixture.waits, [30_000]);
});

test("a rejected executor or interrupted sleep never causes another attempt", async () => {
  const failure = new Error("execution interrupted");
  const first = harness([failed()]);
  first.options.execute = async () => { throw failure; };
  await assert.rejects(runCiSupabase(first.options), failure);
  assert.deepEqual(first.waits, []);
  const second = harness([failed()]);
  second.options.sleep = async () => { throw failure; };
  await assert.rejects(runCiSupabase(second.options), failure);
  assert.equal(second.calls.length, 1);
});

test("real entrypoint streams a hermetic CLI child and preserves success/failure exit codes", async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "field-ci-supabase-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const executable = path.join(directory, "supabase");
  const script = fileURLToPath(new URL("./start-ci-supabase.mjs", import.meta.url));
  for (const status of [0, 17]) {
    await writeFile(executable, `#!${process.execPath}\n` +
      `process.stdout.write(JSON.stringify(process.argv.slice(2)) + "\\n");\n` +
      `process.stderr.write(${JSON.stringify(status === 0 ? "Local CLI fixture started.\n" : "failed to load config: fixture failure\n")});\n` +
      `process.exitCode = ${status};\n`, { mode: 0o755 });
    // Only this fake executable is on PATH. No real Docker/Supabase command,
    // account configuration or inherited application credentials are available.
    const result = spawnSync(process.execPath, [script], {
      env: { PATH: directory }, encoding: "utf8", timeout: 10_000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status, status);
    assert.deepEqual(JSON.parse(result.stdout.trim()), START_ARGS);
    assert.match(result.stderr, status === 0 ? /Local CLI fixture started/ : /failed to load config: fixture failure/);
    assert.doesNotMatch(result.stderr, /Retrying start/);
  }
});
