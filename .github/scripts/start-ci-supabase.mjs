import { spawn } from "node:child_process";
import { constants } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { stripVTControlCharacters } from "node:util";

export const START_COMMAND = "supabase";
export const START_ARGS = Object.freeze([
  "start",
  "--exclude",
  "studio,imgproxy,mailpit,logflare,vector,realtime,storage-api,edge-runtime,postgres-meta,supavisor",
]);
export const RETRY_DELAYS_MS = Object.freeze([30_000, 60_000, 90_000]);

// These are the pinned CLI's fatal image-pull errors, not any earlier progress
// message mentioning a 429. Unknown error formats deliberately fail closed.
function registryPullFailure(line) {
  return /^failed to (?:pull docker image:|display json stream: (?:error pulling image configuration:|toomanyrequests\b))/i.test(line) &&
    /\btoomanyrequests\b|\b429\b/i.test(line);
}

export function canRetryImagePull(output) {
  if (typeof output !== "string") return false;
  const clean = stripVTControlCharacters(output).replaceAll("\r", "\n");
  // Never replay an initialized stack or a migration, even if a later helper
  // image also encounters throttling. "Starting database..." precedes its pull.
  if (/^\s*(?:initiali[sz]ing schema\b|seeding\b|applying migrations?\b|starting containers\b|starting database from backup\b|postgres database is already running\b|supabase start is already running\b)/im.test(clean)) return false;
  if (/\bSQLSTATE\b|^\s*(?:ERROR|FATAL|PANIC):/im.test(clean)) return false;
  if (/unauthorized|authentication required|access denied|permission denied|denied:|invalid (?:config|configuration)|failed to (?:parse|load) config|unknown (?:flag|command)|not ready: unhealthy|(?:health check|healthcheck)[^\n]*(?:fail|unhealthy)|connection refused|cannot connect to the Docker daemon/i.test(clean)) return false;
  const lines = clean.split("\n").map(line => line.trim()).filter(Boolean);
  // The CLI appends this generic troubleshooting suggestion after its error.
  if (lines.at(-1) === "Try rerunning the command with --debug to troubleshoot the error.") lines.pop();
  if (!registryPullFailure(lines.at(-1) ?? "")) return false;
  // A previous pull warning must not hide another terminal failure in the same
  // invocation. Only the same explicit registry failure is safe to repeat.
  return !lines.some(line => /^failed to /i.test(line) && !registryPullFailure(line));
}

function executeStart(command, args) {
  return new Promise(resolve => {
    const chunks = [];
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let error;
    const stream = (destination, chunk) => {
      chunks.push(chunk.toString());
      destination.write(chunk);
    };
    child.stdout.on("data", chunk => stream(process.stdout, chunk));
    child.stderr.on("data", chunk => stream(process.stderr, chunk));
    child.on("error", failure => {
      error = failure;
      process.stderr.write(`Could not run the local Supabase CLI: ${failure.message}\n`);
    });
    child.on("close", (status, signal) => resolve({ status, signal, error, output: chunks.join("") }));
  });
}

function exitStatus(result) {
  if (result.signal) return 128 + (constants.signals[result.signal] ?? 0) || 1;
  if (result.error?.code === "ENOENT") return 127;
  if (Number.isInteger(result.status) && result.status > 0) return result.status;
  return 1;
}

export async function runCiSupabase({ execute = executeStart, sleep = delay, log = console.error } = {}) {
  for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt++) {
    const result = await execute(START_COMMAND, [...START_ARGS]);
    if (result.status === 0 && !result.signal && !result.error) return 0;
    if (result.signal || result.error || !Number.isInteger(result.status) ||
        attempt === RETRY_DELAYS_MS.length || !canRetryImagePull(result.output)) {
      return exitStatus(result);
    }
    const wait = RETRY_DELAYS_MS[attempt];
    log(`The local Supabase image registry is rate-limited before schema initialization. Retrying start in ${wait / 1000}s (${attempt + 2}/4).`);
    await sleep(wait);
  }
  return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = await runCiSupabase();
  } catch (error) {
    console.error(`Could not start the local CI database: ${error.message}`);
    process.exitCode = 1;
  }
}
