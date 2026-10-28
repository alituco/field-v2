#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { verifyProductionStagingEvidence } from './verify-production-release-evidence.mjs';

/** Read-only promotion gate, before any production credentials are used. */
export function verifyProductionBackendRelease({ env = process.env, readGithub } = {}) {
  if (env.DEPLOY_CONFIRMATION !== 'DEPLOY_PRODUCTION' ||
      env.BACKUP_CONFIRMATION !== 'BACKUP_VERIFIED' ||
      env.PRODUCTION_STRIPE_LIVE_ROLLOUT !== 'LIVE_STRIPE_READY') {
    throw new Error('Production deployment requires DEPLOY_PRODUCTION, BACKUP_VERIFIED and LIVE_STRIPE_READY.');
  }
  const read = readGithub ?? (resource => JSON.parse(execFileSync('gh', ['api', resource], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
  })));
  return verifyProductionStagingEvidence({ env, readGithub: read });
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = verifyProductionBackendRelease();
    console.log(`Production backend release gate passed for ${result.sha}; its exact tree passed the full staging push release.`);
  } catch (error) {
    const message = error instanceof Error && !('status' in error)
      ? error.message : 'Could not verify production release evidence; deployment remains blocked.';
    console.error(`::error::${message}`);
    process.exitCode = 1;
  }
}
