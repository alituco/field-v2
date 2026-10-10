#!/usr/bin/env node
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { constants, createWriteStream } from "node:fs";
import {
  link,
  lstat,
  mkdir,
  mkdtemp,
  open,
  readdir,
  rm,
  appendFile,
} from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

// Only these names may cross the job boundary. No archive path is ever trusted.
const PAYLOAD_FILES = ["manifest.json", "password.txt", "player-journey.apk"];
const MAGIC = Buffer.from("field-staging-e2e-handoff\0v1\0", "utf8");
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = MAGIC.length + NONCE_BYTES;
const MAX_METADATA_BYTES = 4_096;
const MAX_FILE_BYTES = {
  "manifest.json": 2 * 1_024 * 1_024,
  "password.txt": MAX_METADATA_BYTES,
  "player-journey.apk": 300 * 1_024 * 1_024,
};
const MAX_CONTAINER_BYTES =
  HEADER_BYTES + TAG_BYTES + 4 + MAX_METADATA_BYTES +
  Object.values(MAX_FILE_BYTES).reduce((total, size) => total + size, 0);

function credentials(key, context) {
  if (typeof key !== "string" || !key.trim()) {
    throw new Error("STAGING_E2E_HANDOFF_KEY is required.");
  }
  if (typeof context !== "string" || !context.trim() || context.length > 1_024) {
    throw new Error("E2E_HANDOFF_CONTEXT or GITHUB_RUN_ID is required.");
  }
  return { key: key.trim(), context: context.trim() };
}

function encryptionKey(key, context) {
  // Run ID, not run attempt: targeted reruns must decrypt the original artifact.
  return Buffer.from(hkdfSync(
    "sha256",
    Buffer.from(key, "utf8"),
    Buffer.from(`field-staging-e2e-handoff:v1:run:${context}`, "utf8"),
    Buffer.from("aes-256-gcm artifact encryption", "utf8"),
    32,
  ));
}

function associatedData(header, context) {
  return Buffer.concat([header, Buffer.from(context, "utf8")]);
}

async function readExact(handle, length, position) {
  const buffer = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const { bytesRead } = await handle.read(buffer, offset, length - offset, position + offset);
    if (!bytesRead) throw new Error("Handoff payload is truncated.");
    offset += bytesRead;
  }
  return buffer;
}

function validateTextPayloads(manifest, password) {
  try {
    const value = JSON.parse(manifest.toString("utf8"));
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("Invalid manifest.");
    }
  } catch {
    // Never include payload contents or parser excerpts in CI logs.
    throw new Error("manifest.json must contain a JSON object.");
  }
  // A downstream job appends this value to GITHUB_ENV. Reject line breaks and
  // other control/non-ASCII bytes instead of allowing environment-file injection.
  if (password.length < 16 || password.some((byte) => byte < 0x21 || byte > 0x7e)) {
    throw new Error("password.txt must contain at least 16 printable ASCII characters without whitespace.");
  }
}

async function openRegularFile(filename) {
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stats = await handle.stat();
    if (!stats.isFile()) throw new Error("Handoff inputs must be regular files.");
    return { handle, size: stats.size };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function* plaintextChunks(metadata, files) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(metadata.length);
  yield length;
  yield metadata;
  for (const { handle, size } of files) {
    if (!size) continue;
    let bytes = 0;
    for await (const chunk of handle.createReadStream({ start: 0, end: size - 1, autoClose: false })) {
      bytes += chunk.length;
      yield chunk;
    }
    if (bytes !== size) throw new Error("Handoff source changed while packing.");
  }
}

export async function packHandoff({ sourceDir, outputFile, key, context }) {
  ({ key, context } = credentials(key, context));
  sourceDir = path.resolve(sourceDir);
  outputFile = path.resolve(outputFile);
  const sourceStats = await lstat(sourceDir);
  if (!sourceStats.isDirectory() || sourceStats.isSymbolicLink()) {
    throw new Error("Handoff source must be a directory, not a symbolic link.");
  }
  const names = await readdir(sourceDir);
  if (names.some((name) => !PAYLOAD_FILES.includes(name))) {
    throw new Error("Handoff source contains an unsupported file.");
  }
  if (!names.includes("manifest.json") || !names.includes("password.txt")) {
    throw new Error("Handoff source requires manifest.json and password.txt.");
  }
  const files = [];
  let temporaryDir;
  try {
    for (const name of PAYLOAD_FILES.filter((name) => names.includes(name))) {
      const file = await openRegularFile(path.join(sourceDir, name));
      files.push({ name, ...file });
      if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > MAX_FILE_BYTES[name]) {
        throw new Error("Handoff source file has an invalid size.");
      }
    }
    validateTextPayloads(
      await readExact(files[0].handle, files[0].size, 0),
      await readExact(files[1].handle, files[1].size, 0),
    );
    const metadata = Buffer.from(JSON.stringify({
      version: 1,
      files: files.map(({ name, size }) => ({ name, size })),
    }), "utf8");
    if (metadata.length > MAX_METADATA_BYTES) throw new Error("Handoff metadata is too large.");
    temporaryDir = await mkdtemp(path.join(path.dirname(outputFile), ".staging-e2e-handoff-"));
    const temporaryFile = path.join(temporaryDir, "sealed.bin");
    const header = Buffer.concat([MAGIC, randomBytes(NONCE_BYTES)]);
    const cipher = createCipheriv("aes-256-gcm", encryptionKey(key, context), header.subarray(MAGIC.length));
    cipher.setAAD(associatedData(header, context));
    const output = createWriteStream(temporaryFile, { flags: "wx", mode: 0o600 });
    output.write(header);
    await pipeline(Readable.from(plaintextChunks(metadata, files)), cipher, output);
    await appendFile(temporaryFile, cipher.getAuthTag());
    // Atomic publication without replacing a previous artifact or a symlink.
    await link(temporaryFile, outputFile);
  } finally {
    await Promise.all(files.map(({ handle }) => handle.close()));
    if (temporaryDir) await rm(temporaryDir, { recursive: true, force: true });
  }
}

function validateMetadata(metadata, plaintextSize, dataOffset) {
  if (
    metadata === null || typeof metadata !== "object" || Array.isArray(metadata) ||
    metadata.version !== 1 || !Array.isArray(metadata.files) ||
    Object.keys(metadata).some((key) => !["version", "files"].includes(key)) ||
    metadata.files.length < 2 || metadata.files.length > PAYLOAD_FILES.length
  ) {
    throw new Error("Handoff metadata is invalid.");
  }
  const names = new Set();
  let position = dataOffset;
  const files = metadata.files.map((entry) => {
    if (
      entry === null || typeof entry !== "object" || Array.isArray(entry) ||
      Object.keys(entry).some((key) => !["name", "size"].includes(key)) ||
      !PAYLOAD_FILES.includes(entry.name) || names.has(entry.name) ||
      !Number.isSafeInteger(entry.size) || entry.size < 1 || entry.size > MAX_FILE_BYTES[entry.name]
    ) {
      throw new Error("Handoff contains an invalid or unsupported file entry.");
    }
    names.add(entry.name);
    const file = { ...entry, position };
    position += entry.size;
    return file;
  });
  if (!names.has("manifest.json") || !names.has("password.txt") || position !== plaintextSize) {
    throw new Error("Handoff payload does not match its metadata.");
  }
  return files;
}

export async function unpackHandoff({ inputFile, outputDir, key, context }) {
  ({ key, context } = credentials(key, context));
  inputFile = path.resolve(inputFile);
  outputDir = path.resolve(outputDir);
  let input;
  let plaintext;
  let temporaryDir;
  let createdOutput = false;
  try {
    const source = await openRegularFile(inputFile);
    input = source.handle;
    if (source.size < HEADER_BYTES + TAG_BYTES + 4 || source.size > MAX_CONTAINER_BYTES) {
      throw new Error("Handoff artifact has an invalid size.");
    }
    const header = await readExact(input, HEADER_BYTES, 0);
    if (!header.subarray(0, MAGIC.length).equals(MAGIC)) {
      throw new Error("Handoff artifact has an unsupported format.");
    }
    const tag = await readExact(input, TAG_BYTES, source.size - TAG_BYTES);
    temporaryDir = await mkdtemp(path.join(path.dirname(outputDir), ".staging-e2e-handoff-"));
    const temporaryFile = path.join(temporaryDir, "authenticated-payload.bin");
    const decipher = createDecipheriv("aes-256-gcm", encryptionKey(key, context), header.subarray(MAGIC.length));
    decipher.setAAD(associatedData(header, context));
    decipher.setAuthTag(tag);
    try {
      await pipeline(
        input.createReadStream({ start: HEADER_BYTES, end: source.size - TAG_BYTES - 1, autoClose: false }),
        decipher,
        createWriteStream(temporaryFile, { flags: "wx", mode: 0o600 }),
      );
    } catch {
      throw new Error("Handoff authentication failed; no payload files were extracted.");
    }

    // Do not parse metadata, create an output directory, or use any payload
    // contents until GCM finalization above has authenticated every byte.
    plaintext = await open(temporaryFile, "r");
    const { size: plaintextSize } = await plaintext.stat();
    const metadataSize = (await readExact(plaintext, 4, 0)).readUInt32BE();
    if (metadataSize < 1 || metadataSize > MAX_METADATA_BYTES || 4 + metadataSize > plaintextSize) {
      throw new Error("Handoff metadata has an invalid size.");
    }
    let metadata;
    try {
      metadata = JSON.parse((await readExact(plaintext, metadataSize, 4)).toString("utf8"));
    } catch {
      throw new Error("Handoff metadata is not valid JSON.");
    }
    const files = validateMetadata(metadata, plaintextSize, 4 + metadataSize);
    const manifest = files.find(({ name }) => name === "manifest.json");
    const password = files.find(({ name }) => name === "password.txt");
    validateTextPayloads(
      await readExact(plaintext, manifest.size, manifest.position),
      await readExact(plaintext, password.size, password.position),
    );
    // mkdir is exclusive: an existing directory or symlink is never reused.
    await mkdir(outputDir, { mode: 0o700 });
    createdOutput = true;
    for (const { name, size, position } of files) {
      await pipeline(
        plaintext.createReadStream({ start: position, end: position + size - 1, autoClose: false }),
        createWriteStream(path.join(outputDir, name), { flags: "wx", mode: 0o600 }),
      );
    }
    createdOutput = false;
  } finally {
    await plaintext?.close();
    await input?.close();
    if (createdOutput) await rm(outputDir, { recursive: true, force: true });
    if (temporaryDir) await rm(temporaryDir, { recursive: true, force: true });
  }
}

async function main(args) {
  const [operation, ...options] = args;
  const values = {};
  for (let index = 0; index < options.length; index += 2) {
    const name = options[index];
    const value = options[index + 1];
    if (!name?.startsWith("--") || !value || value.startsWith("--") || name in values) {
      throw new Error("Invalid handoff command arguments.");
    }
    values[name] = value;
  }
  const key = process.env.STAGING_E2E_HANDOFF_KEY;
  const context = process.env.E2E_HANDOFF_CONTEXT || process.env.GITHUB_RUN_ID;
  if (operation === "pack" && Object.keys(values).length === 2 && values["--source-dir"] && values["--output"]) {
    await packHandoff({ sourceDir: values["--source-dir"], outputFile: values["--output"], key, context });
    console.log("Staging E2E handoff packed.");
  } else if (operation === "unpack" && Object.keys(values).length === 2 && values["--file"] && values["--output-dir"]) {
    await unpackHandoff({ inputFile: values["--file"], outputDir: values["--output-dir"], key, context });
    console.log("Staging E2E handoff authenticated and unpacked.");
  } else {
    throw new Error("Usage: staging-e2e-handoff.mjs pack --source-dir DIR --output FILE | unpack --file FILE --output-dir DIR");
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    // File paths and secret payloads are deliberately excluded from diagnostics.
    console.error(`Staging E2E handoff failed: ${error.code ? "filesystem operation failed." : error.message}`);
    process.exitCode = 1;
  });
}
