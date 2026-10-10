#!/usr/bin/env node
// Provide STAGING_DIAGNOSTICS_KEY through the environment, never an argument.
// Encrypt before uploading an artifact:
//   node .github/scripts/staging-diagnostics.mjs encrypt --input diagnostics.tar.gz --output diagnostics.bin --context RUN_ID:browser
// Recover a downloaded artifact locally using the same key and exact context:
//   node .github/scripts/staging-diagnostics.mjs decrypt --input diagnostics.bin --output recovered.tar.gz --context RUN_ID:browser
// Android artifacts use RUN_ID:android. Output must not already exist; decrypted
// archives contain credentials and must remain private, never publicly uploaded.
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { constants, createWriteStream } from "node:fs";
import { appendFile, link, lstat, mkdtemp, open, realpath, rm } from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

// This envelope is intentionally incompatible with the E2E handoff format.
const MAGIC = Buffer.from("field-staging-diagnostics\0v1\0");
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = MAGIC.length + NONCE_BYTES;
const MAX_PLAINTEXT_BYTES = 8 * 1024 ** 3;

class DiagnosticsError extends Error {}

function credentials(key, context) {
  if (typeof key !== "string" || key.length < 32 || key.trim() !== key) {
    throw new DiagnosticsError("STAGING_DIAGNOSTICS_KEY must contain at least 32 characters without surrounding whitespace.");
  }
  if (typeof context !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(context)) {
    throw new DiagnosticsError("A valid diagnostics context is required.");
  }
  return Buffer.from(hkdfSync(
    "sha256",
    Buffer.from(key),
    Buffer.from(`field-staging-diagnostics:v1:${context}`),
    Buffer.from("aes-256-gcm diagnostic archive encryption"),
    32,
  ));
}

async function destination(input, output) {
  if (typeof input !== "string" || !input || typeof output !== "string" || !output) {
    throw new DiagnosticsError("Input and output files are required.");
  }
  input = path.resolve(input);
  output = path.resolve(output);
  if (input === output) throw new DiagnosticsError("Input and output must be different files.");
  // Reject a symlink as the destination directory, then pin the actual parent.
  // Ancestor aliases such as macOS /tmp -> /private/tmp remain usable.
  const parent = path.dirname(output);
  if (!(await lstat(parent)).isDirectory()) {
    throw new DiagnosticsError("The output parent must be a real directory.");
  }
  output = path.join(await realpath(parent), path.basename(output));
  try {
    await lstat(output);
  } catch (error) {
    if (error.code === "ENOENT") return { input, output };
    throw error;
  }
  throw new DiagnosticsError("The output already exists; it will not be overwritten.");
}

async function readExact(handle, length, position) {
  const buffer = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const { bytesRead } = await handle.read(buffer, offset, length - offset, position + offset);
    if (!bytesRead) throw new DiagnosticsError("The diagnostics envelope is truncated.");
    offset += bytesRead;
  }
  return buffer;
}

async function* fileChunks(handle, start, length) {
  if (length === 0) return;
  let bytes = 0;
  for await (const chunk of handle.createReadStream({ start, end: start + length - 1, autoClose: false })) {
    bytes += chunk.length;
    yield chunk;
  }
  if (bytes !== length) throw new DiagnosticsError("The input changed while being read.");
}

async function transformFile({ input, output, key, context }, decrypt) {
  const encryptionKey = credentials(key, context);
  let source;
  let temporaryDir;
  try {
    ({ input, output } = await destination(input, output));
    source = await open(input, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const before = await source.stat();
    if (!before.isFile()) throw new DiagnosticsError("Input must be a regular file, not a symlink or directory.");
    const maxBytes = MAX_PLAINTEXT_BYTES + (decrypt ? HEADER_BYTES + TAG_BYTES : 0);
    if (!Number.isSafeInteger(before.size) || before.size > maxBytes ||
        (decrypt && before.size < HEADER_BYTES + TAG_BYTES)) {
      throw new DiagnosticsError("The diagnostics input has an invalid size.");
    }
    let header;
    let tag;
    if (decrypt) {
      header = await readExact(source, HEADER_BYTES, 0);
      if (!header.subarray(0, MAGIC.length).equals(MAGIC)) {
        throw new DiagnosticsError("The diagnostics envelope has an unsupported format.");
      }
      tag = await readExact(source, TAG_BYTES, before.size - TAG_BYTES);
    } else {
      header = Buffer.concat([MAGIC, randomBytes(NONCE_BYTES)]);
    }
    const cipher = decrypt
      ? createDecipheriv("aes-256-gcm", encryptionKey, header.subarray(MAGIC.length))
      : createCipheriv("aes-256-gcm", encryptionKey, header.subarray(MAGIC.length));
    cipher.setAAD(Buffer.concat([header, Buffer.from(context)]));
    if (decrypt) cipher.setAuthTag(tag);

    temporaryDir = await mkdtemp(path.join(path.dirname(output), ".staging-diagnostics-"));
    const temporaryFile = path.join(temporaryDir, "payload");
    const sink = createWriteStream(temporaryFile, { flags: "wx", mode: 0o600 });
    if (!decrypt) sink.write(header);
    try {
      await pipeline(
        Readable.from(fileChunks(source, decrypt ? HEADER_BYTES : 0,
          before.size - (decrypt ? HEADER_BYTES + TAG_BYTES : 0))),
        cipher,
        sink,
      );
    } catch (error) {
      if (decrypt) throw new DiagnosticsError("Diagnostics authentication failed; no output was published.");
      throw error;
    }
    const after = await source.stat();
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new DiagnosticsError("The input changed while being read.");
    }
    if (!decrypt) await appendFile(temporaryFile, cipher.getAuthTag());
    const sealed = await open(temporaryFile, "r");
    try {
      await sealed.sync();
    } finally {
      await sealed.close();
    }
    // GCM finalization has authenticated all plaintext before it gains the
    // requested filename. A hard link atomically fails if a destination exists.
    await link(temporaryFile, output);
  } finally {
    encryptionKey.fill(0);
    try {
      await source?.close();
    } finally {
      if (temporaryDir) await rm(temporaryDir, { recursive: true, force: true });
    }
  }
}

export async function encryptDiagnostics(options) {
  await transformFile(options, false);
}

export async function decryptDiagnostics(options) {
  await transformFile(options, true);
}

async function main(args) {
  const [operation, ...options] = args;
  const values = Object.create(null);
  const allowed = new Set(["--input", "--output", "--context"]);
  for (let index = 0; index < options.length; index += 2) {
    const name = options[index];
    const value = options[index + 1];
    if (!allowed.has(name) || !value || value.startsWith("--") || name in values) {
      throw new DiagnosticsError("Invalid diagnostics command arguments.");
    }
    values[name] = value;
  }
  if (!["encrypt", "decrypt"].includes(operation) || Object.keys(values).length !== 3) {
    throw new DiagnosticsError("Usage: staging-diagnostics.mjs encrypt|decrypt --input FILE --output FILE --context RUN_ID:browser (or RUN_ID:android)");
  }
  await transformFile({
    input: values["--input"], output: values["--output"],
    context: values["--context"], key: process.env.STAGING_DIAGNOSTICS_KEY,
  }, operation === "decrypt");
  console.log(operation === "decrypt" ? "Diagnostics authenticated and decrypted." : "Diagnostics encrypted.");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    // Never echo archive paths, provider errors, credentials, or plaintext.
    console.error(`Staging diagnostics failed: ${error instanceof DiagnosticsError ? error.message : "filesystem or cryptographic operation failed."}`);
    process.exitCode = 1;
  });
}
