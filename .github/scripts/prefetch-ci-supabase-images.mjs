import { spawn } from "node:child_process";
import { constants } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { stripVTControlCharacters } from "node:util";

export const PINNED_CLI_VERSION = "2.105.0";
// This helper is absent from `supabase services`. Its version comes from the
// pinned CLI's apps/cli-go/pkg/config/templates/Dockerfile, not a moving tag.
export const PINNED_KONG_TAG = "2.8.1";
export const RETRY_DELAYS_MS = Object.freeze([30_000, 60_000, 90_000]);
const primaryRegistry = "ghcr.io";
const mirrorRegistry = "public.ecr.aws";
const requiredSources = new Map([
  ["supabase/postgres", "postgres"],
  ["supabase/gotrue", "gotrue"],
  ["postgrest/postgrest", "postgrest"],
  ["supabase/realtime", "realtime"],
  ["supabase/storage-api", "storage-api"],
]);

export function parseCiSupabaseImages(stdout) {
  let rows;
  try { rows = JSON.parse(stdout); } catch { throw new Error("Supabase services did not return valid JSON."); }
  if (!Array.isArray(rows)) throw new Error("Unsupported Supabase services JSON shape.");
  const versions = new Map();
  for (const row of rows) {
    if (!row || typeof row !== "object" || !requiredSources.has(row.name)) continue;
    if (versions.has(row.name)) throw new Error(`Supabase services repeated ${row.name}.`);
    // Use only local versions from this CLI/config. Remote hosted versions may
    // differ and must never change the fresh-schema test's image selection.
    if (typeof row.local !== "string" || !/^v?\d[0-9A-Za-z_.-]{0,126}$/.test(row.local)) {
      throw new Error(`Supabase services has no concrete local version for ${row.name}.`);
    }
    versions.set(row.name, row.local);
  }
  const images = [];
  for (const [source, name] of requiredSources) {
    if (!versions.has(source)) throw new Error(`Supabase services omitted required image ${source}.`);
    images.push(`${primaryRegistry}/supabase/${name}:${versions.get(source)}`);
  }
  images.push(`${primaryRegistry}/supabase/kong:${PINNED_KONG_TAG}`);
  return images;
}

function exitStatus(result) {
  if (result.signal) return 128 + (constants.signals[result.signal] ?? 0) || 1;
  if (result.error?.code === "ENOENT") return 127;
  if (Number.isInteger(result.status) && result.status > 0) return result.status;
  return 1;
}

function succeeded(result) {
  return result.status === 0 && !result.signal && !result.error;
}

export function isDockerPullRateLimit(result) {
  if (succeeded(result) || result.signal || result.error || !Number.isInteger(result.status)) return false;
  const output = result.output ?? `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const clean = stripVTControlCharacters(output).replaceAll("\r", "\n");
  if (/unauthorized|authentication required|access denied|permission denied|denied:/i.test(clean)) return false;
  const last = clean.split("\n").map(line => line.trim()).filter(Boolean).at(-1) ?? "";
  return /^(?:Error response from daemon:|error pulling image configuration:|error from registry:|failed to (?:resolve|fetch|pull)\b|toomanyrequests:)/i.test(last) &&
    /\btoomanyrequests\b|\b429(?:\b|(?=TooManyRequests))|\btoo many requests\b/i.test(last);
}

function executeCommand(command, args) {
  return new Promise(resolve => {
    const stdout = [];
    const stderr = [];
    const output = [];
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let error;
    const stream = (chunks, destination, chunk) => {
      chunks.push(chunk.toString());
      output.push(chunk.toString());
      destination.write(chunk);
    };
    child.stdout.on("data", chunk => stream(stdout, process.stdout, chunk));
    child.stderr.on("data", chunk => stream(stderr, process.stderr, chunk));
    child.on("error", failure => { error = failure; });
    child.on("close", (status, signal) => resolve({
      status, signal, error, stdout: stdout.join(""), stderr: stderr.join(""), output: output.join(""),
    }));
  });
}

export async function prefetchCiSupabaseImages({
  execute = executeCommand, sleep = delay, log = console.error,
  registry = process.env.SUPABASE_INTERNAL_IMAGE_REGISTRY ?? primaryRegistry,
} = {}) {
  if (registry !== primaryRegistry) {
    log("CI image prefetch requires the pinned CLI's ghcr.io registry; no database was started.");
    return 1;
  }
  const version = await execute("supabase", ["--version"]);
  if (!succeeded(version)) return exitStatus(version);
  if (version.stdout?.trim() !== PINNED_CLI_VERSION) {
    log(`Review the CI image prefetch manifest before changing Supabase CLI ${PINNED_CLI_VERSION}.`);
    return 1;
  }
  const services = await execute("supabase", ["services", "--output", "json"]);
  if (!succeeded(services)) return exitStatus(services);
  let images;
  try { images = parseCiSupabaseImages(services.stdout); } catch (error) {
    log(error.message);
    return 1;
  }
  // Realtime and Storage are required by initSchema15 even though their
  // long-running services are excluded. Download every bootstrap image BEFORE
  // start can initialize a schema or apply any application migration.
  for (const canonical of images) {
    for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt++) {
      const mirror = attempt % 2 === 1;
      const image = mirror ? canonical.replace(primaryRegistry, mirrorRegistry) : canonical;
      log(`Prefetching local Supabase image ${image} (${attempt + 1}/4).`);
      const pull = await execute("docker", ["pull", image]);
      if (succeeded(pull)) {
        if (mirror) {
          // The CLI checks its canonical image name in Docker's local cache.
          // Alias the same official image/tag; do not change the CLI registry.
          const tagged = await execute("docker", ["tag", image, canonical]);
          if (!succeeded(tagged)) return exitStatus(tagged);
        }
        break;
      }
      if (attempt === RETRY_DELAYS_MS.length || !isDockerPullRateLimit(pull)) return exitStatus(pull);
      const wait = RETRY_DELAYS_MS[attempt];
      log(`Image download was rate-limited. Trying the alternate official registry in ${wait / 1000}s.`);
      await sleep(wait);
    }
  }
  log("All six local Supabase bootstrap images are cached. Schema replay may now start.");
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = await prefetchCiSupabaseImages();
  } catch (error) {
    console.error(`Could not prefetch local Supabase images: ${error.message}`);
    process.exitCode = 1;
  }
}
