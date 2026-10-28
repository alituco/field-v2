#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { verifyProductionStagingEvidence } from './verify-production-release-evidence.mjs';

const repository = 'alituco/field-v2';
const successfulRun = (run, sha) => run?.head_sha === sha &&
  run?.head_branch === 'prod' && run?.status === 'completed' && run?.conclusion === 'success';

/** Read-only release gate. No signing credentials or hosted writes are needed. */
export function verifyProductionIosRelease({ env = process.env, readGithub } = {}) {
  if (env.PRODUCTION_RELEASE_CONFIRMATION !== 'BUILD_PRODUCTION_IOS' ||
      env.PRODUCTION_BACKEND_CONFIRMATION !== 'PRODUCTION_BACKEND_VERIFIED') {
    throw new Error('Confirm BUILD_PRODUCTION_IOS and PRODUCTION_BACKEND_VERIFIED before uploading.');
  }
  const runNumber = Number(env.GITHUB_RUN_NUMBER);
  if (!/^[1-9][0-9]*$/.test(env.GITHUB_RUN_NUMBER ?? '') || !Number.isSafeInteger(runNumber)) {
    throw new Error('Production iOS requires a positive GitHub workflow run number.');
  }
  const read = readGithub ?? (resource => JSON.parse(execFileSync('gh', ['api', resource], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
  })));
  const base = `repos/${repository}`;
  const evidence = verifyProductionStagingEvidence({ env, readGithub: read });
  const { sha } = evidence;
  const runsQuery = `?branch=prod&head_sha=${sha}&status=completed&per_page=100`;
  const backend = read(`${base}/actions/workflows/deploy-supabase-production.yml/runs${runsQuery}`);
  if (!Array.isArray(backend?.workflow_runs) || !backend.workflow_runs.some(run =>
    successfulRun(run, sha) && run.event === 'workflow_dispatch')) {
    throw new Error('This exact prod commit has not completed the protected production backend deployment.');
  }
  const uploads = read(`${base}/actions/workflows/upload-production-testflight.yml/runs?branch=prod&status=completed&per_page=100`);
  if (!Array.isArray(uploads?.workflow_runs)) throw new Error('Could not verify previous production iOS uploads.');
  if (uploads.workflow_runs.some(run => run?.head_branch === 'prod' && run?.event === 'workflow_dispatch' &&
    run?.status === 'completed' && run?.conclusion === 'success' && Number.isSafeInteger(run.run_number) &&
    run.run_number > runNumber)) {
    throw new Error('A newer production iOS workflow has already uploaded; start a new workflow run instead of rerunning this older one.');
  }
  return evidence;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = verifyProductionIosRelease();
    console.log(`Production iOS gate passed for ${result.sha}; the same tree passed staging and production backend deployment.`);
  } catch (error) {
    const message = error instanceof Error && !('status' in error)
      ? error.message : 'Could not read GitHub release evidence; production upload remains blocked.';
    console.error(`::error::${message}`);
    process.exitCode = 1;
  }
}
