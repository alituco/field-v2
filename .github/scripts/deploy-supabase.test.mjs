import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyProductionBackendRelease } from './verify-production-backend-release.mjs';

const script = fileURLToPath(new URL('./deploy-supabase.sh', import.meta.url));
const projectRef = 'nfdkdhdevpstfspazbfn';
const productionProjectRef = 'zjsjuuhborxrlmdcpvlj';
const retiredSecrets = ['TAP_SECRET_KEY', 'TAP_PUBLIC_KEY', 'TAP_MERCHANT_ID', 'TAP_APPLE_PAY_ENABLED', 'TAP_WEBHOOK_URL'];
const unrelatedSecrets = ['STRIPE_SECRET_KEY', 'CUSTOM_KEY', 'TAP_SECRET_KEY_BACKUP'];
const fixtureEnv = {
  SUPABASE_ACCESS_TOKEN: 'test-access-token-not-a-real-credential',
  SUPABASE_DB_PASSWORD: 'test-database-password-not-a-real-credential',
  STRIPE_SECRET_KEY: 'sk_test_deployment-fixture-only',
  STRIPE_PUBLISHABLE_KEY: 'pk_test_deployment-fixture-only',
  STRIPE_WEBHOOK_SECRET: 'whsec_deployment-fixture-only',
  STRIPE_RECONCILE_SECRET: 'worker_deployment_fixture_only_32_characters',
  STRIPE_WEBHOOK_ENDPOINT_ID: 'we_fixture',
};
const productionFixtureEnv = {
  STRIPE_SECRET_KEY: 'sk_live_deployment_fixture_only',
  STRIPE_PUBLISHABLE_KEY: 'pk_live_deployment_fixture_only',
  STRIPE_WEBHOOK_SECRET: 'whsec_production_deployment_fixture_only',
  STRIPE_ACCOUNT_ID: 'acct_deploymentfixture',
  PRODUCTION_STRIPE_LIVE_ROLLOUT: 'LIVE_STRIPE_READY',
};

// The full deployment runs in a disposable workspace with an explicit env.
// PATH contains only mocked cloud commands and the four required local tools.
// In particular node is mocked: configure-stripe-staging must never run here.
function deployment(t, initialState = {}) {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'field-deploy-test-')));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const workspace = path.join(root, 'test workspace');
  const bin = path.join(root, 'bin');
  const temp = path.join(root, 'temp');
  const statePath = path.join(root, 'state.json');
  const logPath = path.join(root, 'commands.jsonl');
  for (const directory of [workspace, bin, temp]) mkdirSync(directory);
  writeFileSync(statePath, JSON.stringify({
    secrets: [...unrelatedSecrets], functions: [], secretListCalls: 0, ...initialState,
  }));

  for (const command of ['jq', 'mktemp', 'chmod', 'rm']) {
    const found = spawnSync('/bin/sh', ['-c', 'command -v "$1"', 'sh', command], {
      env: { PATH: process.env.PATH }, encoding: 'utf8', timeout: 5000,
    });
    assert.equal(found.status, 0, `${command} is required for deployment contract tests`);
    symlinkSync(found.stdout.trim(), path.join(bin, command));
  }

  const mock = `#!${process.execPath}
const { appendFileSync, readFileSync, statSync, writeFileSync } = require('node:fs');
const { basename } = require('node:path');
const command = basename(process.argv[1]);
const args = process.argv.slice(2);
const state = JSON.parse(readFileSync(process.env.MOCK_STATE, 'utf8'));
const ref = process.env.MOCK_PROJECT_REF;
const target = process.env.MOCK_TARGET;
const retired = ${JSON.stringify(retiredSecrets)};
appendFileSync(process.env.MOCK_LOG, JSON.stringify({ command, args }) + '\\n');
function save() { writeFileSync(process.env.MOCK_STATE, JSON.stringify(state)); }
function reject(message) { console.error(message); process.exit(99); }
function expect(expected) {
  if (JSON.stringify(args) !== JSON.stringify(expected)) reject('Unexpected deployment command');
}
function fail(label) {
  if (state.failure === label) {
    // Even valid-looking stdout must never conceal a nonzero list/auth error.
    if (label.startsWith('secrets-list:')) console.log('[]');
    console.error('Mock remote failure: ' + label);
    process.exit(42);
  }
}
if (command === 'node') {
  if (target === 'production' && args.includes('--preflight')) {
    expect(['.github/scripts/configure-stripe-production.mjs', '--preflight']);
    fail('production-preflight');
  } else {
    expect(['.github/scripts/configure-stripe-' + target + '.mjs']);
    fail('configure');
  }
  if (process.env.SUPABASE_PROJECT_REF !== ref) reject('Wrong configuration project');
} else if (command !== 'supabase') {
  reject('Unexpected executable');
} else if (args[0] === 'link') {
  expect(['link', '--project-ref', ref, '--yes']);
  fail('link');
} else if (args[0] === 'db' && args[1] === 'push') {
  expect(['db', 'push', '--linked', '--include-all', ...(args.includes('--dry-run') ? ['--dry-run'] : []), '--yes']);
  fail(args.includes('--dry-run') ? 'migration-preview' : 'migration-apply');
} else if (args[0] === 'db' && args[1] === 'query') {
  expect(['db', 'query', '--linked', '--file', '.github/scripts/verify-hosted-schema.sql']);
  fail('schema-check');
} else if (args[0] === 'secrets' && args[1] === 'set') {
  expect(['secrets', 'set', '--project-ref', ref, '--env-file', args[5]]);
  if (!args[5] || (statSync(args[5]).mode & 0o777) !== 0o600) reject('Secrets file is not private');
  const expected = ['STRIPE_SECRET_KEY', 'STRIPE_WEBHOOK_SECRET', 'STRIPE_RECONCILE_SECRET'];
  const contents = readFileSync(args[5], 'utf8');
  if (contents !== expected.map(name => name + '=' + process.env[name] + '\\n').join('') + 'FIELD_ENVIRONMENT=' + target + '\\n') {
    reject('Unexpected secret file contents');
  }
  fail('secrets-set');
  state.secrets = [...new Set([...state.secrets, ...expected, 'FIELD_ENVIRONMENT'])];
  save();
} else if (args[0] === 'functions' && args[1] === 'deploy') {
  const name = args[2];
  const names = ['stripe-payment', 'stripe-payment-webhook', 'stripe-payment-reconcile', 'fieldrush-delete-account',
    'fieldrush-push-dispatch', 'cloudflare-stream-webhook', 'profile-goal-clip', 'dev-phone-login', 'dev-switch-user', 'staging-admin-session'];
  if (!names.includes(name)) reject('Unexpected function deployment');
  expect(['functions', 'deploy', name, '--project-ref', ref, '--use-api', ...(name === 'profile-goal-clip' ? [] : ['--no-verify-jwt']), '--yes']);
  fail('deploy:' + name);
  state.functions = [...new Set([...state.functions, name])];
  save();
} else if (args[0] === 'functions' && args[1] === 'list') {
  expect(['functions', 'list', '--project-ref', ref, '--output-format', 'json']);
  fail('functions-list');
  console.log(JSON.stringify(state.functions.map(name => ({ name, slug: name }))));
} else if (args[0] === 'functions' && args[1] === 'delete') {
  expect(['functions', 'delete', args[2], '--project-ref', ref, '--yes']);
  const allowed = ['tap-payment', 'tap-payment-webhook', ...(target === 'production' ? ['dev-phone-login', 'dev-switch-user', 'staging-admin-session'] : [])];
  if (!allowed.includes(args[2]) || !state.functions.includes(args[2])) {
    reject('Function deletion is not restricted to existing retired functions');
  }
  fail('functions-delete');
  state.functions = state.functions.filter(name => name !== args[2]);
  save();
} else if (args[0] === 'secrets' && args[1] === 'list') {
  // Exact CLI 2.105.0 legacy JSON mode: a bare array, with lowercase name.
  // --output-format json is intentionally NOT accepted; it returns an envelope.
  expect(['secrets', 'list', '--project-ref', ref, '--output', 'json']);
  state.secretListCalls++;
  save();
  fail('secrets-list:' + state.secretListCalls);
  if (state.inventoryOverride !== undefined && state.secretListCalls === (state.overrideOnList ?? 1)) {
    console.log(state.inventoryOverride);
  } else {
    console.log(JSON.stringify(state.secrets.map(name => ({ name, value: 'mock-digest-must-not-be-logged' }))));
  }
} else if (args[0] === 'secrets' && args[1] === 'unset') {
  const boundary = args.indexOf('--project-ref');
  const names = args.slice(2, boundary);
  expect(['secrets', 'unset', ...names, '--project-ref', ref, '--yes']);
  if (!names.length || new Set(names).size !== names.length || names.some(name => !retired.includes(name) || !state.secrets.includes(name))) {
    reject('Cannot unset absent or non-allowlisted secrets');
  }
  fail('secrets-unset');
  if (!state.ignoreUnset) state.secrets = state.secrets.filter(name => !names.includes(name));
  save();
} else {
  reject('Unexpected deployment command');
}
`;
  for (const name of ['supabase', 'node']) writeFileSync(path.join(bin, name), mock, { mode: 0o755 });

  function commands() {
    return existsSync(logPath) ? readFileSync(logPath, 'utf8').trim().split('\n').map(JSON.parse) : [];
  }
  return {
    state: () => JSON.parse(readFileSync(statePath, 'utf8')),
    run({ target = 'staging', ref = projectRef, overrides = {} } = {}) {
      const previousCalls = commands().length;
      const env = {
        ...fixtureEnv, PATH: bin, HOME: root, TMPDIR: temp,
        MOCK_STATE: statePath, MOCK_LOG: logPath, MOCK_TARGET: target, MOCK_PROJECT_REF: ref, ...overrides,
      };
      for (const name of Object.keys(env)) if (env[name] === undefined) delete env[name];
      const result = spawnSync('/bin/bash', [script, target, ref], {
        cwd: workspace, env, encoding: 'utf8', timeout: 10_000,
      });
      assert.ifError(result.error);
      const calls = commands().slice(previousCalls);
      const output = result.stdout + result.stderr;
      const privateNames = ['SUPABASE_ACCESS_TOKEN', 'SUPABASE_DB_PASSWORD', 'STRIPE_SECRET_KEY',
        'STRIPE_PUBLISHABLE_KEY', 'STRIPE_WEBHOOK_SECRET', 'STRIPE_RECONCILE_SECRET'];
      for (const value of [...privateNames.map(name => env[name]).filter(Boolean), 'mock-digest-must-not-be-logged']) {
        assert.equal(output.includes(value), false, 'A fixture credential or digest leaked to output');
        assert.equal(JSON.stringify(calls).includes(value), false, 'A fixture credential leaked to command arguments');
      }
      assert.deepEqual(readdirSync(temp), [], 'Temporary secret file must be removed on success and failure');
      assert.equal(JSON.stringify(calls).includes('--include-seed'), false);
      return { ...result, output, calls };
    },
  };
}

function unsetCalls(result) {
  return result.calls.filter(({ command, args }) => command === 'supabase' && args[0] === 'secrets' && args[1] === 'unset');
}

function assertNoPostCleanupDeploy(result) {
  assert.equal(result.calls.some(({ args }) => args[0] === 'functions' && args[1] === 'deploy' && args[2] === 'fieldrush-delete-account'), false);
  assert.doesNotMatch(result.output, /deployment completed/);
}

const releaseSha = 'a'.repeat(40);
const stagingReleaseSha = 'b'.repeat(40);
const releaseTree = 'c'.repeat(40);
const releaseEnv = {
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/prod',
  GITHUB_REPOSITORY: 'alituco/field-v2', GITHUB_SHA: releaseSha,
  DEPLOY_CONFIRMATION: 'DEPLOY_PRODUCTION', BACKUP_CONFIRMATION: 'BACKUP_VERIFIED',
  PRODUCTION_STRIPE_LIVE_ROLLOUT: 'LIVE_STRIPE_READY',
};

function releaseEvidence({ earlyDeployment = false, failedStaging = false } = {}) {
  const base = 'repos/alituco/field-v2';
  const resources = new Map([
    [`${base}/actions/workflows/ci.yml/runs?branch=prod&head_sha=${releaseSha}&status=completed&per_page=100`,
      { workflow_runs: [{ head_sha: releaseSha, head_branch: 'prod', status: 'completed', conclusion: 'success' }] }],
    [`${base}/git/commits/${releaseSha}`, { tree: { sha: releaseTree } }],
    [`${base}/git/commits/${stagingReleaseSha}`, { tree: { sha: releaseTree } }],
    [`${base}/deployments?environment=staging&per_page=100`, [{ id: 123, sha: stagingReleaseSha,
      environment: 'staging', description: earlyDeployment ? 'Deploy staging backend' : 'Field staging Supabase deployment' }]],
    [`${base}/deployments/123/statuses?per_page=1`, [{ state: 'success',
      description: 'Migrations, smoke, Android, referee, and admin E2E passed' }]],
    [`${base}/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingReleaseSha}&event=push&status=completed&per_page=100`,
      { workflow_runs: [{ head_sha: stagingReleaseSha, head_branch: 'staging', event: 'push', status: 'completed', conclusion: failedStaging ? 'failure' : 'success' }] }],
  ]);
  return resource => {
    assert.ok(resources.has(resource), `Unexpected release-evidence request: ${resource}`);
    return structuredClone(resources.get(resource));
  };
}

test('backend promotion requires all three confirmations before release-evidence reads', () => {
  for (const name of ['DEPLOY_CONFIRMATION', 'BACKUP_CONFIRMATION', 'PRODUCTION_STRIPE_LIVE_ROLLOUT']) {
    assert.throws(() => verifyProductionBackendRelease({ env: { ...releaseEnv, [name]: '' },
      readGithub: () => assert.fail('No release reads before explicit confirmations') }));
  }
});

test('backend promotion refuses successful early staging deployments and failed full staging runs', () => {
  for (const scenario of [{ earlyDeployment: true }, { failedStaging: true }]) {
    assert.throws(() => verifyProductionBackendRelease({ env: releaseEnv, readGithub: releaseEvidence(scenario) }),
      /explicit verified staging release/);
  }
  assert.deepEqual(verifyProductionBackendRelease({ env: releaseEnv, readGithub: releaseEvidence() }),
    { sha: releaseSha, stagingSha: stagingReleaseSha });
});

test('backend workflow invokes the shared full-release gate and keeps protected explicit deployment checks', () => {
  const workflow = readFileSync(new URL('../workflows/deploy-supabase-production.yml', import.meta.url), 'utf8');
  assert.match(workflow, /node \.github\/scripts\/verify-production-backend-release\.mjs/);
  assert.match(workflow, /environment:\n      name: production/);
  assert.match(workflow, /\$GITHUB_REF" != "refs\/heads\/prod/);
  assert.match(workflow, /LIVE_STRIPE_READY/);
  assert.doesNotMatch(workflow, /matching_staging_sha|while read -r deployment_id/);
});

test('refuses production payment cutover before invoking deployment tools', (t) => {
  const result = deployment(t).run({ target: 'production', ref: 'zjsjuuhborxrlmdcpvlj' });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /Production live Stripe cutover requires/);
  assert.equal(result.stdout, '');
  assert.deepEqual(result.calls, []);
});

function runProduction(harness, overrides = {}) {
  return harness.run({ target: 'production', ref: productionProjectRef,
    overrides: { ...productionFixtureEnv, ...overrides } });
}

test('production requires explicit live configuration before invoking any deployment tools', (t) => {
  for (const changes of [
    { PRODUCTION_STRIPE_LIVE_ROLLOUT: undefined },
    { PRODUCTION_STRIPE_LIVE_ROLLOUT: 'true' },
    { STRIPE_SECRET_KEY: fixtureEnv.STRIPE_SECRET_KEY },
    { STRIPE_SECRET_KEY: 'rk_test_fixture' },
    { STRIPE_SECRET_KEY: 'rk_live_' },
    { STRIPE_SECRET_KEY: 'rk_live_fixture/other' },
    { STRIPE_SECRET_KEY: 'rk_live_fixture ' },
    { STRIPE_SECRET_KEY: 'sk_live_fixture\n' },
    { STRIPE_SECRET_KEY: 'rk_live_fixture\n' },
    { STRIPE_SECRET_KEY: 'rk_live_fixture\nOTHER=bad' },
    { STRIPE_PUBLISHABLE_KEY: fixtureEnv.STRIPE_PUBLISHABLE_KEY },
    { STRIPE_WEBHOOK_SECRET: undefined },
    { STRIPE_WEBHOOK_ENDPOINT_ID: undefined },
    { STRIPE_ACCOUNT_ID: undefined },
    { STRIPE_ACCOUNT_ID: '../other' },
    { STRIPE_RECONCILE_SECRET: 'short' },
    { STRIPE_RECONCILE_SECRET: 'x'.repeat(513) },
    { STRIPE_RECONCILE_SECRET: 'x'.repeat(32) + '\n' },
    ...['"', "'", '$', '#', '\\'].map(character => ({ STRIPE_RECONCILE_SECRET: character + 'x'.repeat(32) })),
    { SUPABASE_ACCESS_TOKEN: undefined },
    { SUPABASE_DB_PASSWORD: undefined },
  ]) {
    const result = runProduction(deployment(t), changes);
    assert.equal(result.status, 64, result.output);
    assert.deepEqual(result.calls, []);
  }
});

for (const keyPrefix of ['sk', 'rk']) {
  test(`failed production provider preflight with ${keyPrefix} key never invokes Supabase or changes data`, (t) => {
    const result = runProduction(deployment(t, { failure: 'production-preflight' }),
      { STRIPE_SECRET_KEY: `${keyPrefix}_live_deployment_fixture_only` });
    assert.equal(result.status, 42, result.output);
    assert.deepEqual(result.calls.map(call => call.command), ['node']);
    assert.deepEqual(result.calls[0].args, ['.github/scripts/configure-stripe-production.mjs', '--preflight']);
    assert.doesNotMatch(result.output, /Linking|deployment completed/);
  });
}

test('confirmed production deploys payment/deletion/inert push without developer authentication or automatic activation', (t) => {
  const forbidden = ['dev-phone-login', 'dev-switch-user', 'staging-admin-session'];
  const harness = deployment(t, { functions: [...forbidden, 'tap-payment', 'keep-function'], secrets: [...retiredSecrets, ...unrelatedSecrets] });
  for (let run = 0; run < 2; run++) {
    const result = runProduction(harness, {
      STRIPE_SECRET_KEY: `${run === 0 ? 'sk' : 'rk'}_live_deployment_fixture_only`,
    });
    assert.equal(result.status, 0, result.output);
    assert.match(result.output, /Supabase production deployment completed/);
    assert.equal(result.calls[0].command, 'node');
    assert.deepEqual(result.calls[0].args, ['.github/scripts/configure-stripe-production.mjs', '--preflight']);
    const deployments = result.calls.filter(({ args }) => args[0] === 'functions' && args[1] === 'deploy');
    assert.deepEqual(deployments.map(({ args }) => args[2]), ['stripe-payment', 'stripe-payment-webhook',
      'stripe-payment-reconcile', 'fieldrush-delete-account', 'fieldrush-push-dispatch']);
    const state = harness.state();
    assert.ok(forbidden.every(name => !state.functions.includes(name)));
    assert.ok(state.functions.includes('keep-function'));
    assert.ok(!state.functions.includes('tap-payment'));
    assert.ok(retiredSecrets.every(name => !state.secrets.includes(name)));
    for (const flag of ['PUSH_DELIVERY_ENABLED', 'FIREBASE_SERVICE_ACCOUNT_JSON', 'PUSH_WORKER_SECRET', 'FIELDRUSH_ACCOUNT_DELETION_ENABLED']) {
      assert.ok(!state.secrets.includes(flag), `${flag} must not be activated by deployment`);
    }
    const firstMigration = result.calls.findIndex(({ args }) => args[0] === 'db' && args[1] === 'push');
    const forbiddenDeletes = result.calls.filter(({ args }) => args[0] === 'functions' && args[1] === 'delete' && forbidden.includes(args[2]));
    assert.equal(forbiddenDeletes.length, run === 0 ? forbidden.length : 0);
    for (const call of forbiddenDeletes) assert.ok(result.calls.indexOf(call) < firstMigration);
    const reconcileDeploy = result.calls.findIndex(({ args }) => args[0] === 'functions' && args[1] === 'deploy' && args[2] === 'stripe-payment-reconcile');
    const configuration = result.calls.findIndex(({ command, args }) => command === 'node' && args.length === 1);
    const retiredDelete = result.calls.findIndex(({ args }) => args[0] === 'functions' && args[1] === 'delete' && args[2] === 'tap-payment');
    assert.ok(configuration > reconcileDeploy);
    if (retiredDelete >= 0) assert.ok(retiredDelete > configuration);
  }
});

test('production recording remains a separate explicit deployment opt-in', (t) => {
  const result = runProduction(deployment(t), { DEPLOY_RECORDING_FUNCTIONS: 'true' });
  assert.equal(result.status, 0, result.output);
  assert.ok(result.calls.some(({ args }) => args[0] === 'functions' && args[1] === 'deploy' && args[2] === 'cloudflare-stream-webhook'));
  assert.ok(result.calls.some(({ args }) => args[0] === 'functions' && args[1] === 'deploy' && args[2] === 'profile-goal-clip'));
});

test('rejects the wrong project before performing any deployment', (t) => {
  const result = deployment(t).run({ ref: 'zjsjuuhborxrlmdcpvlj' });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /not Field's exact staging project/);
  assert.equal(result.stdout, '');
  assert.deepEqual(result.calls, []);
});

test('requires sandbox keys and recovery credentials before staging migrations', (t) => {
  for (const overrides of [
    { STRIPE_SECRET_KEY: undefined },
    { STRIPE_SECRET_KEY: 'sk_live_placeholder' },
    { STRIPE_SECRET_KEY: 'rk_live_placeholder' },
    { STRIPE_RECONCILE_SECRET: 'short' },
    { STRIPE_WEBHOOK_ENDPOINT_ID: undefined },
    { SUPABASE_ACCESS_TOKEN: undefined },
    { SUPABASE_DB_PASSWORD: undefined },
  ]) {
    const result = deployment(t).run({ overrides });
    assert.equal(result.status, 64);
    assert.equal(result.stdout, '');
    assert.deepEqual(result.calls, []);
  }
});

for (const [label, present] of [
  ['already absent', []],
  ['all present', retiredSecrets],
  ['partly present', [retiredSecrets[0], retiredSecrets[4]]],
]) {
  test(`full staging deployment is repeatable with retired secrets ${label}`, (t) => {
    const harness = deployment(t, { secrets: [...unrelatedSecrets, ...present], functions: ['tap-payment', 'tap-payment-webhook', 'keep-function'] });
    for (let run = 0; run < 2; run++) {
      const result = harness.run();
      assert.equal(result.status, 0, result.output);
      assert.match(result.output, /Supabase staging deployment completed/);
      const functionDeployments = result.calls.filter(({ command, args }) =>
        command === 'supabase' && args[0] === 'functions' && args[1] === 'deploy');
      assert.equal(functionDeployments.length, 10);
      for (const { args } of functionDeployments) {
        assert.ok(args.includes('--use-api'), `${args[2]} must deploy without a local Docker bundler`);
        assert.equal(args.includes('--no-verify-jwt'), args[2] !== 'profile-goal-clip');
      }
      const deletions = unsetCalls(result);
      assert.equal(deletions.length, run === 0 && present.length ? 1 : 0);
      if (deletions.length) assert.deepEqual(deletions[0].args.slice(2, -3), present);
      assert.equal(result.calls.filter(({ args }) => args[0] === 'secrets' && args[1] === 'list').length, 2);
      const state = harness.state();
      assert.ok(unrelatedSecrets.every(name => state.secrets.includes(name)));
      assert.ok(retiredSecrets.every(name => !state.secrets.includes(name)));
      assert.ok(state.functions.includes('keep-function'));
      assert.ok(state.functions.includes('fieldrush-push-dispatch'));
      assert.ok(!state.secrets.includes('PUSH_DELIVERY_ENABLED'));
      assert.ok(!state.secrets.includes('FIREBASE_SERVICE_ACCOUNT_JSON'));
      assert.ok(!state.secrets.includes('PUSH_WORKER_SECRET'));
      assert.ok(!state.functions.includes('tap-payment') && !state.functions.includes('tap-payment-webhook'));
      const stripeDeployed = result.calls.findIndex(({ args }) => args[0] === 'functions' && args[1] === 'deploy' && args[2] === 'stripe-payment-reconcile');
      const configured = result.calls.findIndex(({ command }) => command === 'node');
      const listed = result.calls.findIndex(({ args }) => args[0] === 'secrets' && args[1] === 'list');
      assert.ok(stripeDeployed >= 0 && configured > stripeDeployed && listed > configured);
    }
  });
}

test('a push worker deployment failure is not hidden or reported as success', (t) => {
  const result = deployment(t, { failure: 'deploy:fieldrush-push-dispatch' }).run();
  assert.equal(result.status, 42, result.output);
  assert.match(result.stderr, /Mock remote failure: deploy:fieldrush-push-dispatch/);
  assert.doesNotMatch(result.output, /deployment completed/);
  assert.equal(result.calls.some(({ args }) => args.includes('configure_push_dispatch')), false);
});

for (const inventoryOverride of ['not-json', '', 'null', '{}', '[{}]', '[{"name":null}]', '[{"name":42}]', '[{"name":""}]', '{"type":"success","data":{"secrets":[]}}', '[]\n[]']) {
  test(`rejects malformed secret inventory ${JSON.stringify(inventoryOverride)}`, (t) => {
    const result = deployment(t, { inventoryOverride }).run();
    assert.equal(result.status, 1, result.output);
    assert.match(result.stderr, /invalid secret inventory/);
    assert.deepEqual(unsetCalls(result), []);
    assertNoPostCleanupDeploy(result);
  });
}

test('revalidates inventory after cleanup and rejects secrets that remain', (t) => {
  for (const scenario of [
    { ignoreUnset: true },
    { inventoryOverride: '{}', overrideOnList: 2 },
  ]) {
    const result = deployment(t, { secrets: [...unrelatedSecrets, ...retiredSecrets], ...scenario }).run();
    assert.equal(result.status, 1, result.output);
    assert.equal(unsetCalls(result).length, 1);
    assertNoPostCleanupDeploy(result);
  }
});

for (const failure of [
  'link', 'migration-preview', 'migration-apply', 'schema-check', 'secrets-set',
  'deploy:stripe-payment', 'configure', 'functions-list', 'functions-delete',
  'secrets-list:1', 'secrets-list:2', 'secrets-unset',
]) {
  test(`preserves failure from ${failure} instead of completing deployment`, (t) => {
    const result = deployment(t, { failure, secrets: retiredSecrets, functions: ['tap-payment'] }).run();
    assert.equal(result.status, 42, result.output);
    assert.match(result.stderr, /Mock remote failure/);
    assertNoPostCleanupDeploy(result);
  });
}
