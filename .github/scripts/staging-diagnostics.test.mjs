import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { access, link, mkdir, mkdtemp, open, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { decryptDiagnostics, encryptDiagnostics } from "./staging-diagnostics.mjs";

const KEY = "test-only-diagnostics-service-key-123456789";
const CONTEXT = "123456789:browser";
const PLAINTEXT = "private-admin-bearer-and-refresh-token-never-published";
const MAGIC_BYTES = Buffer.byteLength("field-staging-diagnostics\0v1\0");
const HEADER_BYTES = MAGIC_BYTES + 12;
const SCRIPT = fileURLToPath(new URL("./staging-diagnostics.mjs", import.meta.url));

async function fixture(t, data = Buffer.from(PLAINTEXT)) {
  const root = await mkdtemp(path.join(os.tmpdir(), "field-diagnostics-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const input = path.join(root, "diagnostics.tar.gz");
  const output = path.join(root, "diagnostics.bin");
  const restored = path.join(root, "restored.tar.gz");
  await writeFile(input, data);
  return { root, input, output, restored, key: KEY, context: CONTEXT };
}

async function absent(filename) {
  await assert.rejects(access(filename), { code: "ENOENT" });
}

async function noTemporaryFiles(root) {
  assert.equal((await readdir(root)).some((name) => name.startsWith(".staging-diagnostics-")), false);
}

async function decrypt(options, changes = {}) {
  await decryptDiagnostics({ ...options, input: options.output, output: options.restored, ...changes });
}

function cli(args, key = KEY) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    env: { PATH: process.env.PATH, ...(key === null ? {} : { STAGING_DIAGNOSTICS_KEY: key }) },
    encoding: "utf8", timeout: 10_000,
  });
}

function argumentsFor(operation, options) {
  return [operation, "--input", options.input, "--output", options.output, "--context", options.context];
}

test("round-trips binary diagnostics with private files and no plaintext in envelope", async (t) => {
  const bytes = Buffer.concat([Buffer.from(PLAINTEXT), Buffer.from([0, 255, 128, 1, 0])]);
  const options = await fixture(t, bytes);
  await encryptDiagnostics(options);
  const sealed = await readFile(options.output);
  assert.equal(sealed.length, bytes.length + HEADER_BYTES + 16);
  assert.equal(sealed.includes(Buffer.from(PLAINTEXT)), false);
  assert.equal(sealed.includes(Buffer.from(KEY)), false);
  assert.equal((await stat(options.output)).mode & 0o777, 0o600);
  await decrypt(options);
  assert.deepEqual(await readFile(options.restored), bytes);
  assert.equal((await stat(options.restored)).mode & 0o777, 0o600);
  await noTemporaryFiles(options.root);
});

test("empty files round-trip and each encryption uses a fresh nonce", async (t) => {
  const options = await fixture(t, Buffer.alloc(0));
  await encryptDiagnostics(options);
  const second = path.join(options.root, "second.bin");
  await encryptDiagnostics({ ...options, output: second });
  assert.notDeepEqual(await readFile(options.output), await readFile(second));
  await decrypt(options);
  assert.equal((await stat(options.restored)).size, 0);
});

test("streams a large archive with constant envelope overhead", async (t) => {
  const options = await fixture(t);
  const source = await open(options.input, "r+");
  const size = 64 * 1024 ** 2;
  try {
    await source.truncate(size);
    await source.write(Buffer.from("end-of-large-archive"), 0, 20, size - 20);
  } finally {
    await source.close();
  }
  await encryptDiagnostics(options);
  assert.equal((await stat(options.output)).size, size + HEADER_BYTES + 16);
  await decrypt(options);
  async function digest(filename) {
    const source = await open(filename, "r");
    const hash = createHash("sha256");
    try {
      for await (const bytes of source.createReadStream({ autoClose: false })) hash.update(bytes);
      return hash.digest("hex");
    } finally {
      await source.close();
    }
  }
  assert.equal(await digest(options.restored), await digest(options.input));
  await noTemporaryFiles(options.root);
});

for (const [label, changes] of [
  ["wrong key", { key: "different-test-only-key-123456789012345" }],
  ["wrong run", { context: "987654321:browser" }],
  ["wrong purpose", { context: "123456789:android" }],
]) {
  test(`${label} never publishes unauthenticated plaintext`, async (t) => {
    const options = await fixture(t);
    await encryptDiagnostics(options);
    await assert.rejects(decrypt(options, changes), /authentication failed/);
    await absent(options.restored);
    await noTemporaryFiles(options.root);
  });
}

for (const [label, offset] of [
  ["magic", 0], ["nonce", MAGIC_BYTES], ["ciphertext", HEADER_BYTES + 1], ["tag", -1],
]) {
  test(`rejects tampered ${label} without publishing any output`, async (t) => {
    const options = await fixture(t);
    await encryptDiagnostics(options);
    const bytes = await readFile(options.output);
    bytes[offset < 0 ? bytes.length + offset : offset] ^= 1;
    await writeFile(options.output, bytes);
    await assert.rejects(decrypt(options), /unsupported format|authentication failed/);
    await absent(options.restored);
    await noTemporaryFiles(options.root);
  });
}

test("rejects truncated and appended envelopes and the handoff format", async (t) => {
  const options = await fixture(t);
  await encryptDiagnostics(options);
  const sealed = await readFile(options.output);
  for (const bytes of [
    Buffer.alloc(0), sealed.subarray(0, 4), sealed.subarray(0, HEADER_BYTES + 15),
    sealed.subarray(0, sealed.length - 1), Buffer.concat([sealed, Buffer.from("extra")]),
    Buffer.concat([Buffer.from("field-staging-e2e-handoff\0v1\0"), sealed]),
  ]) {
    await writeFile(options.output, bytes);
    await assert.rejects(decrypt(options));
    await absent(options.restored);
    await noTemporaryFiles(options.root);
  }
});

test("never overwrites a destination, the source, or a hard-linked source", async (t) => {
  const options = await fixture(t);
  await assert.rejects(encryptDiagnostics({ ...options, output: options.input }), /different files/);
  await link(options.input, options.output);
  await assert.rejects(encryptDiagnostics(options), /already exists/);
  assert.equal(await readFile(options.input, "utf8"), PLAINTEXT);
  await rm(options.output);
  await encryptDiagnostics(options);
  const sealed = await readFile(options.output);
  await assert.rejects(encryptDiagnostics(options), /already exists/);
  assert.deepEqual(await readFile(options.output), sealed);
  await writeFile(options.restored, "preserve-existing-output");
  await assert.rejects(decrypt(options), /already exists/);
  assert.equal(await readFile(options.restored, "utf8"), "preserve-existing-output");
  await noTemporaryFiles(options.root);
});

test("concurrent writers publish exactly one authenticated output without overwriting", async (t) => {
  const options = await fixture(t, Buffer.alloc(1024 * 1024, 0xab));
  const results = await Promise.allSettled([
    encryptDiagnostics(options), encryptDiagnostics(options),
  ]);
  assert.equal(results.filter(({ status }) => status === "fulfilled").length, 1);
  assert.equal(results.filter(({ status }) => status === "rejected").length, 1);
  await decrypt(options);
  assert.deepEqual(await readFile(options.restored), await readFile(options.input));
  await noTemporaryFiles(options.root);
});

test("rejects symlink sources, destinations, and destination parent", async (t) => {
  const options = await fixture(t);
  const sourceLink = path.join(options.root, "source-link");
  await symlink(options.input, sourceLink);
  await assert.rejects(encryptDiagnostics({ ...options, input: sourceLink }));
  await absent(options.output);
  await symlink(path.join(options.root, "never-created"), options.output);
  await assert.rejects(encryptDiagnostics(options), /already exists/);
  await absent(path.join(options.root, "never-created"));
  await rm(options.output);
  const realDirectory = path.join(options.root, "real-directory");
  const linkedDirectory = path.join(options.root, "linked-directory");
  await mkdir(realDirectory);
  await symlink(realDirectory, linkedDirectory);
  await assert.rejects(encryptDiagnostics({ ...options, output: path.join(linkedDirectory, "payload") }), /real directory/);
  await encryptDiagnostics(options);
  const sealedLink = path.join(options.root, "sealed-link");
  await symlink(options.output, sealedLink);
  await assert.rejects(decrypt(options, { input: sealedLink }));
  await absent(options.restored);
  await noTemporaryFiles(options.root);
});

test("rejects non-regular sources and oversized sparse files before streaming", async (t) => {
  const options = await fixture(t);
  await assert.rejects(encryptDiagnostics({ ...options, input: options.root }), /regular file/);
  const source = await open(options.input, "r+");
  try {
    await source.truncate(8 * 1024 ** 3 + 1);
  } finally {
    await source.close();
  }
  await assert.rejects(encryptDiagnostics(options), /invalid size/);
  await absent(options.output);
  await noTemporaryFiles(options.root);
});

test("CLI round-trips with only fixed success messages and no secret arguments", async (t) => {
  const options = await fixture(t);
  const encrypted = cli(argumentsFor("encrypt", options));
  assert.equal(encrypted.status, 0, encrypted.stderr);
  assert.equal(encrypted.stdout, "Diagnostics encrypted.\n");
  const decrypted = cli(argumentsFor("decrypt", { ...options, input: options.output, output: options.restored }));
  assert.equal(decrypted.status, 0, decrypted.stderr);
  assert.equal(decrypted.stdout, "Diagnostics authenticated and decrypted.\n");
  assert.equal(await readFile(options.restored, "utf8"), PLAINTEXT);
  for (const result of [encrypted, decrypted]) {
    for (const sensitive of [KEY, PLAINTEXT, options.input, CONTEXT]) {
      assert.equal(`${result.stdout}${result.stderr}`.includes(sensitive), false);
    }
  }
});

test("CLI rejects missing credentials, malformed arguments and invalid context without echoing inputs", async (t) => {
  const options = await fixture(t);
  const valid = argumentsFor("encrypt", options);
  for (const [args, key] of [
    [valid, null], [valid, ""], [valid, "short"], [valid, ` ${KEY}`],
    [[], KEY], [[...valid, "--secret", PLAINTEXT], KEY],
    [[...valid, "--input", PLAINTEXT], KEY], [["encrypt", "--input"], KEY],
    [argumentsFor("encrypt", { ...options, context: `${PLAINTEXT}\n` }), KEY],
    [argumentsFor("encrypt", { ...options, input: path.join(options.root, PLAINTEXT) }), KEY],
  ]) {
    const result = cli(args, key);
    assert.notEqual(result.status, 0);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr.includes(KEY), false);
    assert.equal(result.stderr.includes(PLAINTEXT), false);
    assert.equal(result.stderr.includes(options.root), false);
    await absent(options.output);
  }
});

test("CLI authentication failures reveal no plaintext and leave no temporary output", async (t) => {
  const options = await fixture(t);
  await encryptDiagnostics(options);
  const result = cli(argumentsFor("decrypt", { ...options, input: options.output, output: options.restored }), "different-test-only-key-123456789012345");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /authentication failed; no output was published/);
  assert.equal(result.stderr.includes(PLAINTEXT), false);
  assert.equal(result.stderr.includes(KEY), false);
  await absent(options.restored);
  await noTemporaryFiles(options.root);
});
