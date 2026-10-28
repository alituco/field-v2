import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createCipheriv, createHash, hkdfSync, randomBytes } from "node:crypto";
import {
  access,
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { packHandoff, unpackHandoff } from "./staging-e2e-handoff.mjs";

const KEY = "test-only-staging-service-role-key";
const CONTEXT = "123456789";
const PASSWORD = "test-only-password-never-logged-123";
const MAGIC = Buffer.from("field-staging-e2e-handoff\0v1\0", "utf8");
const HEADER_BYTES = MAGIC.length + 12;
const SCRIPT = fileURLToPath(new URL("./staging-e2e-handoff.mjs", import.meta.url));

async function fixture(t, { apk = true } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "field-handoff-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const sourceDir = path.join(root, "source");
  const outputFile = path.join(root, "sealed.bin");
  const outputDir = path.join(root, "restored");
  await mkdir(sourceDir);
  await writeFile(path.join(sourceDir, "manifest.json"), JSON.stringify({ playerId: "fixture-player", runId: CONTEXT }));
  await writeFile(path.join(sourceDir, "password.txt"), PASSWORD);
  if (apk) await writeFile(path.join(sourceDir, "player-journey.apk"), Buffer.from([0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 3]));
  return { root, sourceDir, outputFile, outputDir, key: KEY, context: CONTEXT };
}

async function doesNotExist(filename) {
  await assert.rejects(access(filename), { code: "ENOENT" });
}

async function noTemporaryFiles(root) {
  assert.equal((await readdir(root)).some((name) => name.startsWith(".staging-e2e-handoff-")), false);
}

function sealMetadata(metadata, bytes) {
  const metadataBytes = Buffer.from(JSON.stringify(metadata));
  const length = Buffer.alloc(4);
  length.writeUInt32BE(metadataBytes.length);
  const plaintext = Buffer.concat([length, metadataBytes, bytes]);
  const header = Buffer.concat([MAGIC, randomBytes(12)]);
  const key = Buffer.from(hkdfSync(
    "sha256",
    Buffer.from(KEY),
    Buffer.from(`field-staging-e2e-handoff:v1:run:${CONTEXT}`),
    Buffer.from("aes-256-gcm artifact encryption"),
    32,
  ));
  const cipher = createCipheriv("aes-256-gcm", key, header.subarray(MAGIC.length));
  cipher.setAAD(Buffer.concat([header, Buffer.from(CONTEXT)]));
  return Buffer.concat([header, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
}

test("round-trips exact payload bytes with private output modes", async (t) => {
  const options = await fixture(t);
  await packHandoff(options);
  const sealed = await readFile(options.outputFile);
  assert.equal(sealed.includes(Buffer.from(PASSWORD)), false);
  await unpackHandoff({ ...options, inputFile: options.outputFile });
  for (const name of ["manifest.json", "password.txt", "player-journey.apk"]) {
    assert.deepEqual(await readFile(path.join(options.outputDir, name)), await readFile(path.join(options.sourceDir, name)));
    assert.equal((await stat(path.join(options.outputDir, name))).mode & 0o777, 0o600);
  }
  assert.equal((await stat(options.outputFile)).mode & 0o777, 0o600);
  assert.equal((await stat(options.outputDir)).mode & 0o777, 0o700);
  await noTemporaryFiles(options.root);
});

test("cleanup shell restores a discarded Android password from the encrypted handoff", async (t) => {
  const options = await fixture(t);
  const download = path.join(options.root, "field-e2e-cleanup-download");
  await mkdir(download);
  await packHandoff({ ...options, outputFile: path.join(download, "field-e2e-handoff.bin") });
  const action = await readFile(new URL("../actions/cleanup-staging-e2e/action.yml", import.meta.url), "utf8");
  const restore = action.split("    - name: Restore cleanup manifest\n")[1].split("    - name:")[0];
  const script = restore.split("      run: |\n")[1].replace(/^        /gm, "");
  const envFile = path.join(options.root, "github-env");
  await writeFile(envFile, "");
  const result = spawnSync("/bin/bash", ["-c", script], {
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    env: {
      PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
      RUNNER_TEMP: options.root,
      GITHUB_ENV: envFile,
      GITHUB_RUN_ID: CONTEXT,
      STAGING_E2E_HANDOFF_KEY: KEY,
      E2E_MANIFEST_PATH: path.join(options.sourceDir, "manifest.json"),
      E2E_TEST_PASSWORD: "",
    },
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  const restored = path.join(options.root, "field-e2e-cleanup-restored");
  assert.equal(await readFile(envFile, "utf8"),
    `E2E_MANIFEST_PATH=${restored}/manifest.json\nE2E_TEST_PASSWORD=${PASSWORD}\n`);
  assert.equal(result.stdout.includes(`::add-mask::${PASSWORD}`), true);
  assert.deepEqual(await readFile(path.join(restored, "manifest.json")),
    await readFile(path.join(options.sourceDir, "manifest.json")));
  await doesNotExist(path.join(restored, "password.txt"));
});

test("a partial-fixture handoff can omit the APK for cleanup", async (t) => {
  const options = await fixture(t, { apk: false });
  await packHandoff(options);
  await unpackHandoff({ ...options, inputFile: options.outputFile });
  assert.deepEqual((await readdir(options.outputDir)).sort(), ["manifest.json", "password.txt"]);
});

test("streaming framing keeps a large binary payload close to its original size", async (t) => {
  const options = await fixture(t);
  const apk = await open(path.join(options.sourceDir, "player-journey.apk"), "r+");
  const apkSize = 150 * 1_024 * 1_024;
  try {
    await apk.truncate(apkSize);
    await apk.write(Buffer.from("last-apk-bytes"), 0, 14, apkSize - 14);
  } finally {
    await apk.close();
  }
  await packHandoff(options);
  assert.ok((await stat(options.outputFile)).size < apkSize + 1_024);
  await unpackHandoff({ ...options, inputFile: options.outputFile });
  async function hash(filename) {
    const handle = await open(filename, "r");
    const digest = createHash("sha256");
    try {
      for await (const chunk of handle.createReadStream({ autoClose: false })) digest.update(chunk);
      return digest.digest("hex");
    } finally {
      await handle.close();
    }
  }
  assert.equal(await hash(path.join(options.outputDir, "player-journey.apk")), await hash(path.join(options.sourceDir, "player-journey.apk")));
  await noTemporaryFiles(options.root);
});

for (const location of ["nonce", "ciphertext", "authentication tag"]) {
  test(`tampering with the ${location} is rejected before extraction`, async (t) => {
    const options = await fixture(t);
    await packHandoff(options);
    const artifact = await readFile(options.outputFile);
    const offset = location === "nonce" ? MAGIC.length : location === "ciphertext" ? HEADER_BYTES + 5 : artifact.length - 1;
    artifact[offset] ^= 1;
    await writeFile(options.outputFile, artifact);
    await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /authentication failed/);
    await doesNotExist(options.outputDir);
    await noTemporaryFiles(options.root);
  });
}

for (const override of [{ key: "different-service-role-key" }, { context: "different-workflow-run" }]) {
  test(`rejects a wrong ${"key" in override ? "key" : "run context"} without producing output`, async (t) => {
    const options = await fixture(t);
    await packHandoff(options);
    await assert.rejects(unpackHandoff({ ...options, ...override, inputFile: options.outputFile }), /authentication failed/);
    await doesNotExist(options.outputDir);
    await noTemporaryFiles(options.root);
  });
}

for (const unsafeName of ["../escaped.txt", "/tmp/escaped.txt", "nested/password.txt", "..\\escaped.txt"]) {
  test(`rejects authenticated path traversal entry ${JSON.stringify(unsafeName)}`, async (t) => {
    const options = await fixture(t);
    const manifest = Buffer.from("{}");
    const password = Buffer.from(PASSWORD);
    const extra = Buffer.from("escape");
    const artifact = sealMetadata({ version: 1, files: [
      { name: "manifest.json", size: manifest.length },
      { name: "password.txt", size: password.length },
      { name: unsafeName, size: extra.length },
    ] }, Buffer.concat([manifest, password, extra]));
    await writeFile(options.outputFile, artifact);
    await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /invalid or unsupported file entry/);
    await doesNotExist(options.outputDir);
    await doesNotExist(path.join(options.root, "escaped.txt"));
    await noTemporaryFiles(options.root);
  });
}

for (const invalid of [
  { name: "duplicate entries", files: [{ name: "manifest.json", size: 2 }, { name: "manifest.json", size: 2 }] },
  { name: "negative sizes", files: [{ name: "manifest.json", size: -1 }, { name: "password.txt", size: 17 }] },
  { name: "oversized files", files: [{ name: "manifest.json", size: 2 }, { name: "password.txt", size: 4_097 }] },
  { name: "missing required files", files: [{ name: "manifest.json", size: 2 }, { name: "player-journey.apk", size: 2 }] },
  { name: "trailing bytes", files: [{ name: "manifest.json", size: 2 }, { name: "password.txt", size: 16 }] },
]) {
  test(`rejects authenticated metadata with ${invalid.name}`, async (t) => {
    const options = await fixture(t);
    await writeFile(options.outputFile, sealMetadata({ version: 1, files: invalid.files }, Buffer.from(`{}${PASSWORD}`)));
    await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /invalid|does not match/);
    await doesNotExist(options.outputDir);
    await noTemporaryFiles(options.root);
  });
}

test("rejects truncated and unsupported artifacts", async (t) => {
  const options = await fixture(t);
  await writeFile(options.outputFile, Buffer.alloc(1));
  await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /invalid size/);
  await writeFile(options.outputFile, Buffer.alloc(HEADER_BYTES + 16 + 4));
  await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /unsupported format/);
  await doesNotExist(options.outputDir);
});

test("does not follow source symlinks or pack unsupported files", async (t) => {
  const options = await fixture(t);
  await rm(path.join(options.sourceDir, "password.txt"));
  await symlink(path.join(options.sourceDir, "manifest.json"), path.join(options.sourceDir, "password.txt"));
  await assert.rejects(packHandoff(options));
  await doesNotExist(options.outputFile);
  await rm(path.join(options.sourceDir, "password.txt"));
  await writeFile(path.join(options.sourceDir, "password.txt"), PASSWORD);
  await writeFile(path.join(options.sourceDir, "unexpected-secret.txt"), "must not be packed");
  await assert.rejects(packHandoff(options), /unsupported file/);
  await doesNotExist(options.outputFile);
  await noTemporaryFiles(options.root);
});

test("requires both fixture manifest and password", async (t) => {
  const options = await fixture(t, { apk: false });
  await rm(path.join(options.sourceDir, "manifest.json"));
  await assert.rejects(packHandoff(options), /requires manifest.json and password.txt/);
  await doesNotExist(options.outputFile);
});

test("invalid text payloads are never published or included in errors", async (t) => {
  const options = await fixture(t);
  await writeFile(path.join(options.sourceDir, "manifest.json"), `not JSON ${PASSWORD}`);
  await assert.rejects(packHandoff(options), (error) => {
    assert.equal(error.message.includes(PASSWORD), false);
    return /must contain a JSON object/.test(error.message);
  });
  await doesNotExist(options.outputFile);
  const badManifest = Buffer.from(`not JSON ${PASSWORD}`);
  const password = Buffer.from(PASSWORD);
  await writeFile(options.outputFile, sealMetadata({ version: 1, files: [
    { name: "manifest.json", size: badManifest.length },
    { name: "password.txt", size: password.length },
  ] }, Buffer.concat([badManifest, password])));
  await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /must contain a JSON object/);
  await doesNotExist(options.outputDir);
  await noTemporaryFiles(options.root);
});

for (const [name, lineBreak] of [["LF", "\n"], ["CR", "\r"], ["CRLF", "\r\n"]]) {
  test(`rejects ${name} in passwords during packing and authenticated unpacking`, async (t) => {
    const options = await fixture(t);
    const manifest = Buffer.from("{}");
    const password = Buffer.from(`${PASSWORD}${lineBreak}INJECTED_ENV=value`);
    await writeFile(path.join(options.sourceDir, "password.txt"), password);
    await assert.rejects(packHandoff(options), /printable ASCII characters without whitespace/);
    await doesNotExist(options.outputFile);
    await writeFile(options.outputFile, sealMetadata({ version: 1, files: [
      { name: "manifest.json", size: manifest.length },
      { name: "password.txt", size: password.length },
    ] }, Buffer.concat([manifest, password])));
    await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), /printable ASCII characters without whitespace/);
    await doesNotExist(options.outputDir);
    await noTemporaryFiles(options.root);
  });
}

test("never overwrites an existing artifact or output directory", async (t) => {
  const options = await fixture(t);
  await writeFile(options.outputFile, "existing artifact");
  await assert.rejects(packHandoff(options), { code: "EEXIST" });
  assert.equal(await readFile(options.outputFile, "utf8"), "existing artifact");
  await rm(options.outputFile);
  await packHandoff(options);
  await mkdir(options.outputDir);
  await writeFile(path.join(options.outputDir, "keep.txt"), "existing output");
  await assert.rejects(unpackHandoff({ ...options, inputFile: options.outputFile }), { code: "EEXIST" });
  assert.equal(await readFile(path.join(options.outputDir, "keep.txt"), "utf8"), "existing output");
  await noTemporaryFiles(options.root);
});

test("CLI uses run ID across attempts and never logs the password or key", async (t) => {
  const options = await fixture(t, { apk: false });
  const env = { ...process.env, STAGING_E2E_HANDOFF_KEY: KEY, GITHUB_RUN_ID: CONTEXT, GITHUB_RUN_ATTEMPT: "1" };
  delete env.E2E_HANDOFF_CONTEXT;
  const packed = spawnSync(process.execPath, [SCRIPT, "pack", "--source-dir", options.sourceDir, "--output", options.outputFile], { env, encoding: "utf8" });
  assert.equal(packed.status, 0, packed.stderr);
  const unpacked = spawnSync(process.execPath, [SCRIPT, "unpack", "--file", options.outputFile, "--output-dir", options.outputDir], { env: { ...env, GITHUB_RUN_ATTEMPT: "2" }, encoding: "utf8" });
  assert.equal(unpacked.status, 0, unpacked.stderr);
  assert.equal((packed.stdout + packed.stderr + unpacked.stdout + unpacked.stderr).includes(PASSWORD), false);
  assert.equal((packed.stdout + packed.stderr + unpacked.stdout + unpacked.stderr).includes(KEY), false);
  assert.equal(await readFile(path.join(options.outputDir, "password.txt"), "utf8"), PASSWORD);
});

test("CLI rejects missing credentials and duplicate or unrecognized arguments", async (t) => {
  const options = await fixture(t);
  const env = { ...process.env, STAGING_E2E_HANDOFF_KEY: "", E2E_HANDOFF_CONTEXT: CONTEXT };
  const missing = spawnSync(process.execPath, [SCRIPT, "pack", "--source-dir", options.sourceDir, "--output", options.outputFile], { env, encoding: "utf8" });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /STAGING_E2E_HANDOFF_KEY is required/);
  const duplicate = spawnSync(process.execPath, [SCRIPT, "pack", "--source-dir", options.sourceDir, "--source-dir", options.sourceDir], { env, encoding: "utf8" });
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr, /Invalid handoff command arguments/);
  const unknown = spawnSync(process.execPath, [SCRIPT, "pack", "--source-dir", options.sourceDir, "--unknown", options.outputFile], { env, encoding: "utf8" });
  assert.notEqual(unknown.status, 0);
  assert.match(unknown.stderr, /Usage:/);
});
