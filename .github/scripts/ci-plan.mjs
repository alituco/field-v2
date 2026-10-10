#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CI_OUTPUTS = Object.freeze([
  'flutter', 'android', 'ios', 'referee', 'broadcaster', 'database',
  'backend', 'player', 'browser', 'release',
]);
const BASELINE_CHECKS = CI_OUTPUTS.slice(0, 6);
const MODES = new Set(['full', 'backend', 'player', 'journey']);
const COMMIT_SHA = /^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/;
const CONTRACT_ONLY_PR_PATHS = new Set([
  '.github/workflows/ci.yml',
  '.github/actions/cleanup-staging-e2e/action.yml',
  '.github/scripts/check-ci.sh',
  '.github/scripts/ci-plan.mjs',
  '.github/scripts/ci-plan.test.mjs',
  '.github/scripts/ci-results.mjs',
  '.github/scripts/ci-results.test.mjs',
  '.github/scripts/deploy-supabase.sh',
  '.github/scripts/deploy-supabase.test.mjs',
  '.github/scripts/staging-e2e-workflow.test.mjs',
  '.github/scripts/configure-stripe-staging.mjs',
  '.github/scripts/configure-stripe-staging.test.mjs',
  '.github/scripts/smoke-supabase.mjs',
  '.github/scripts/smoke-supabase.test.mjs',
  '.github/scripts/staging-e2e-handoff.mjs',
  '.github/scripts/staging-e2e-handoff.test.mjs',
  '.github/scripts/staging-diagnostics.mjs',
  '.github/scripts/staging-diagnostics.test.mjs',
]);

function emptyPlan() {
  return Object.fromEntries(CI_OUTPUTS.map((name) => [name, 'false']));
}

function enable(plan, names) {
  for (const name of names) plan[name] = 'true';
}

function isDocumentation(filename) {
  return filename.startsWith('docs/') || /\.(?:md|markdown)$/i.test(filename) ||
    /^(?:LICENSE|NOTICE)(?:\.[^/]+)?$/.test(filename);
}

function selectPathChecks(plan, filename) {
  // Markdown and the dedicated documentation tree have no executable CI input.
  // Do not inspect whether the file currently exists: deleted paths count too.
  if (isDocumentation(filename)) return;
  // This exact infrastructure allowlist is exercised by the always-run fast
  // contracts. Native builds test the new wiring once on the full merged push.
  // Unknown workflow inputs and native/TestFlight tooling stay conservative.
  if (CONTRACT_ONLY_PR_PATHS.has(filename)) return;
  if (filename.startsWith('supabase/')) {
    // Backend contracts are consumed by every client, including native builds.
    enable(plan, BASELINE_CHECKS);
  } else if (filename.startsWith('mobile/')) {
    enable(plan, ['flutter']);
    if (filename.startsWith('mobile/android/')) {
      enable(plan, ['android']);
    } else if (filename.startsWith('mobile/ios/')) {
      enable(plan, ['ios']);
    } else if (!/^mobile\/(?:test|integration_test|test_driver)\//.test(filename)) {
      enable(plan, ['android', 'ios']);
    }
  } else if (filename.startsWith('referee/')) {
    enable(plan, ['referee']);
  } else if (filename.startsWith('broadcaster/')) {
    enable(plan, ['broadcaster']);
  } else {
    // Unknown/shared inputs fail conservatively to all local checks. Path
    // selection must never authorize a hosted mutation.
    enable(plan, BASELINE_CHECKS);
  }
}

/**
 * Select CI jobs without reading files, executing commands, or accessing secrets.
 * Values deliberately match GitHub's string-valued job outputs.
 *
 * Manual diagnostics test only reviewed, merged staging code. Candidate refs
 * are not supported: choosing an unmerged source requires a separate trust design.
 */
export function createCiPlan({ eventName, ref, mode = 'full', changedPaths = [] } = {}) {
  if (!MODES.has(mode)) throw new Error('CI_MODE must be full, backend, player, or journey.');
  if (!['pull_request', 'push', 'workflow_dispatch'].includes(eventName)) {
    throw new Error('Unsupported CI event.');
  }
  if (eventName !== 'workflow_dispatch' && mode !== 'full') {
    throw new Error('Diagnostic CI modes require workflow_dispatch.');
  }
  const plan = emptyPlan();

  if (eventName === 'push') {
    if (!['refs/heads/staging', 'refs/heads/prod'].includes(ref)) {
      throw new Error('Automatic CI pushes must target staging or prod.');
    }
    enable(plan, BASELINE_CHECKS);
    if (ref === 'refs/heads/staging') enable(plan, ['backend', 'player', 'browser', 'release']);
    return plan;
  }

  if (eventName === 'workflow_dispatch') {
    if (ref !== 'refs/heads/staging') {
      throw new Error('Manual CI diagnostics must be dispatched from staging.');
    }
    enable(plan, ['backend']);
    if (mode === 'full') enable(plan, [...BASELINE_CHECKS, 'player', 'browser']);
    if (mode === 'player' || mode === 'journey') enable(plan, ['flutter', 'database', 'player']);
    if (mode === 'journey') enable(plan, ['referee', 'browser']);
    // A diagnostic run is never a release, even after every check passes.
    return plan;
  }

  if (typeof ref !== 'string' || !/^refs\/pull\/\d+\/(?:merge|head)$/.test(ref)) {
    throw new Error('Pull-request CI requires a pull-request ref.');
  }
  if (!Array.isArray(changedPaths) || changedPaths.some((filename) => typeof filename !== 'string' || !filename)) {
    throw new Error('Pull-request changed paths must be non-empty strings.');
  }
  for (const filename of changedPaths) selectPathChecks(plan, filename);
  return plan;
}

export function readPullRequestPaths(env = process.env, cwd = process.cwd()) {
  const base = env.PR_BASE_SHA;
  const head = env.PR_HEAD_SHA;
  if (!COMMIT_SHA.test(base ?? '') || !COMMIT_SHA.test(head ?? '')) {
    throw new Error('PR_BASE_SHA and PR_HEAD_SHA must be full commit hashes.');
  }
  // Disable rename detection so both the deleted old path and added new path
  // select checks. NUL separators preserve spaces/newlines in Git filenames.
  const result = spawnSync('git', ['diff', '--name-only', '--no-renames', '-z', `${base}...${head}`, '--'], {
    cwd,
    encoding: 'utf8',
    maxBuffer: 10 * 1_024 * 1_024,
    timeout: 30_000,
  });
  if (result.error || result.status !== 0) {
    throw new Error('Cannot enumerate PR paths; fetch the pinned base and head commits first.');
  }
  if (result.stdout && !result.stdout.endsWith('\0')) {
    throw new Error('Git returned an incomplete changed-path list.');
  }
  return result.stdout ? result.stdout.slice(0, -1).split('\0') : [];
}

export function runCiPlan(env = process.env, cwd = process.cwd()) {
  const eventName = env.GITHUB_EVENT_NAME;
  const ref = env.GITHUB_REF;
  const mode = env.CI_MODE || 'full';
  // Validate event/ref/mode before invoking Git or writing any outputs.
  const options = { eventName, ref, mode };
  createCiPlan(options);
  if (eventName === 'pull_request') options.changedPaths = readPullRequestPaths(env, cwd);
  const plan = createCiPlan(options);
  const output = CI_OUTPUTS.map((name) => `${name}=${plan[name]}\n`).join('');
  if (!env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required.');
  appendFileSync(env.GITHUB_OUTPUT, output, { encoding: 'utf8' });
  return plan;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runCiPlan();
  } catch (error) {
    console.error(`::error::CI plan failed: ${error.message}`);
    process.exitCode = 1;
  }
}
