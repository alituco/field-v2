#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { verifyProductionStagingEvidence } from './verify-production-release-evidence.mjs';

const repository = 'alituco/field-v2';

export function androidProductionVersionCode(env = process.env) {
  const run = Number(env.GITHUB_RUN_NUMBER);
  const attempt = Number(env.GITHUB_RUN_ATTEMPT);
  if (!/^[1-9][0-9]*$/.test(env.GITHUB_RUN_NUMBER ?? '') ||
      !/^[1-9][0-9]*$/.test(env.GITHUB_RUN_ATTEMPT ?? '') ||
      !Number.isSafeInteger(run) || !Number.isSafeInteger(attempt) || attempt > 99 ||
      !Number.isSafeInteger(run * 100 + attempt) || run * 100 + attempt > 2_100_000_000) {
    throw new Error('Android version codes require a positive workflow run number, attempts 1–99, and the Play version-code limit.');
  }
  return run * 100 + attempt;
}

/** Read-only gate: preserve the established staging/production release evidence. */
export function verifyProductionAndroidRelease({ env = process.env, readGithub } = {}) {
  if (env.PRODUCTION_RELEASE_CONFIRMATION !== 'BUILD_PRODUCTION_ANDROID' ||
      env.PRODUCTION_BACKEND_CONFIRMATION !== 'PRODUCTION_BACKEND_READY_FOR_ANDROID') {
    throw new Error('Confirm BUILD_PRODUCTION_ANDROID and PRODUCTION_BACKEND_READY_FOR_ANDROID before signing.');
  }
  androidProductionVersionCode(env);
  const read = readGithub ?? (resource => JSON.parse(execFileSync('gh', ['api', resource], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
  })));
  const evidence = verifyProductionStagingEvidence({ env, readGithub: read });
  const { sha } = evidence;
  const base = `repos/${repository}/actions/workflows`;
  const backend = read(`${base}/deploy-supabase-production.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`);
  if (!Array.isArray(backend?.workflow_runs) || !backend.workflow_runs.some(run =>
    run?.head_sha === sha && run?.head_branch === 'prod' && run?.event === 'workflow_dispatch' &&
    run?.status === 'completed' && run?.conclusion === 'success')) {
    throw new Error('This exact prod commit has not completed the protected production backend deployment.');
  }
  const builds = read(`${base}/build-production-android.yml/runs?branch=prod&status=completed&per_page=100`);
  if (!Array.isArray(builds?.workflow_runs)) throw new Error('Could not verify previous production Android builds.');
  if (builds.workflow_runs.some(run => run?.head_branch === 'prod' && run?.event === 'workflow_dispatch' &&
    run?.status === 'completed' && run?.conclusion === 'success' && Number.isSafeInteger(run.run_number) &&
    run.run_number > Number(env.GITHUB_RUN_NUMBER))) {
    throw new Error('A newer production Android bundle exists; start a new workflow run instead of rerunning this older one.');
  }
  return evidence;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = verifyProductionAndroidRelease();
    console.log(`Production Android gate passed for ${result.sha}; the same tree passed staging and production backend deployment.`);
  } catch (error) {
    const message = error instanceof Error && !('status' in error)
      ? error.message : 'Could not read GitHub release evidence; production signing remains blocked.';
    console.error(`::error::${message}`);
    process.exitCode = 1;
  }
}
