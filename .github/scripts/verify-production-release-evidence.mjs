const repository = 'alituco/field-v2';
const shaPattern = /^[a-f0-9]{40}$/;
const deploymentDescription = 'Field staging Supabase deployment';
const statusDescription = 'Migrations, smoke, Android, referee, and admin E2E passed';

/** Shared read-only evidence gate for protected production backend/iOS releases. */
export function verifyProductionStagingEvidence({ env = process.env, readGithub } = {}) {
  if (env.GITHUB_EVENT_NAME !== 'workflow_dispatch' || env.GITHUB_REF !== 'refs/heads/prod' ||
      env.GITHUB_REPOSITORY !== repository || !shaPattern.test(env.GITHUB_SHA ?? '')) {
    throw new Error('Production releases require a manual dispatch of the prod branch in alituco/field-v2.');
  }
  if (typeof readGithub !== 'function') throw new Error('A read-only GitHub API client is required.');
  const base = `repos/${repository}`;
  const sha = env.GITHUB_SHA;
  const ci = readGithub(`${base}/actions/workflows/ci.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`);
  if (!Array.isArray(ci?.workflow_runs) || !ci.workflow_runs.some(run => run?.head_sha === sha &&
    run?.head_branch === 'prod' && run?.status === 'completed' && run?.conclusion === 'success')) {
    throw new Error('This exact prod commit has not passed CI.');
  }
  const currentTree = readGithub(`${base}/git/commits/${sha}`)?.tree?.sha;
  if (!shaPattern.test(currentTree ?? '')) throw new Error('Could not verify the production Git tree.');
  const deployments = readGithub(`${base}/deployments?environment=staging&per_page=100`);
  if (!Array.isArray(deployments)) throw new Error('Could not read verified staging deployments.');
  const treeCache = new Map([[sha, currentTree]]);
  for (const deployment of deployments) {
    // GitHub also creates ordinary successful environment deployments for early
    // backend/player jobs. Only record-staging writes these release markers.
    if (deployment?.environment !== 'staging' || deployment.description !== deploymentDescription ||
        !Number.isSafeInteger(deployment.id) || deployment.id < 1 || !shaPattern.test(deployment.sha ?? '')) continue;
    const statuses = readGithub(`${base}/deployments/${deployment.id}/statuses?per_page=1`);
    if (!Array.isArray(statuses) || statuses[0]?.state !== 'success' ||
        statuses[0]?.description !== statusDescription) continue;
    if (!treeCache.has(deployment.sha)) {
      treeCache.set(deployment.sha, readGithub(`${base}/git/commits/${deployment.sha}`)?.tree?.sha);
    }
    if (treeCache.get(deployment.sha) !== currentTree) continue;
    const staging = readGithub(`${base}/actions/workflows/ci.yml/runs?branch=staging&head_sha=${deployment.sha}&event=push&status=completed&per_page=100`);
    if (Array.isArray(staging?.workflow_runs) && staging.workflow_runs.some(run =>
      run?.head_sha === deployment.sha && run?.head_branch === 'staging' && run?.event === 'push' &&
      run?.status === 'completed' && run?.conclusion === 'success')) {
      return { sha, stagingSha: deployment.sha };
    }
  }
  throw new Error('This production Git tree has no explicit verified staging release with successful full push CI and hosted journeys.');
}
