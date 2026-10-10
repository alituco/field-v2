import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { CI_OUTPUTS, createCiPlan } from './ci-plan.mjs';

const script = fileURLToPath(new URL('./ci-plan.mjs', import.meta.url));
const checks = ['flutter', 'android', 'ios', 'referee', 'broadcaster', 'database'];
const staging = 'refs/heads/staging';
const prRef = 'refs/pull/42/merge';

function enabled(plan) {
  assert.deepEqual(Object.keys(plan), CI_OUTPUTS);
  assert.ok(Object.values(plan).every((value) => value === 'true' || value === 'false'));
  return CI_OUTPUTS.filter((name) => plan[name] === 'true');
}

function pullRequest(changedPaths) {
  return createCiPlan({ eventName: 'pull_request', ref: prRef, changedPaths });
}

test('branch pushes always run all baseline checks; only staging pushes release', () => {
  assert.deepEqual(enabled(createCiPlan({ eventName: 'push', ref: staging })), CI_OUTPUTS);
  assert.deepEqual(enabled(createCiPlan({ eventName: 'push', ref: 'refs/heads/prod' })), checks);
});

test('manual full mode runs every check and hosted journey without releasing', () => {
  assert.deepEqual(enabled(createCiPlan({ eventName: 'workflow_dispatch', ref: staging })), CI_OUTPUTS.slice(0, -1));
});

test('manual backend mode runs only protected backend deployment and smoke', () => {
  assert.deepEqual(enabled(createCiPlan({ eventName: 'workflow_dispatch', ref: staging, mode: 'backend' })), ['backend']);
});

test('manual player mode runs player checks, database verification, backend and Android E2E', () => {
  assert.deepEqual(enabled(createCiPlan({ eventName: 'workflow_dispatch', ref: staging, mode: 'player' })), ['flutter', 'database', 'backend', 'player']);
});

test('manual journey mode adds referee checks and the dependent browser journey', () => {
  assert.deepEqual(enabled(createCiPlan({ eventName: 'workflow_dispatch', ref: staging, mode: 'journey' })), ['flutter', 'referee', 'database', 'backend', 'player', 'browser']);
});

test('invalid events, modes, automatic diagnostic modes and refs fail closed', () => {
  for (const options of [
    {},
    { eventName: 'pull_request_target', ref: prRef },
    { eventName: 'push', ref: 'refs/heads/codex/candidate' },
    { eventName: 'push', ref: staging, mode: 'player' },
    { eventName: 'pull_request', ref: staging },
    { eventName: 'pull_request', ref: prRef, mode: 'backend' },
    { eventName: 'workflow_dispatch', ref: 'refs/heads/prod' },
    { eventName: 'workflow_dispatch', ref: 'refs/heads/codex/candidate' },
    { eventName: 'workflow_dispatch', ref: staging, mode: 'unknown' },
    { eventName: 'workflow_dispatch', ref: staging, mode: 'PLAYER' },
  ]) assert.throws(() => createCiPlan(options));
});

test('PR paths select the relevant app checks, including platform-only inputs', () => {
  const matrix = [
    [['mobile/lib/main.dart'], ['flutter', 'android', 'ios']],
    [['mobile/pubspec.lock'], ['flutter', 'android', 'ios']],
    [['mobile/assets/logo.png'], ['flutter', 'android', 'ios']],
    [['mobile/android/app/build.gradle.kts'], ['flutter', 'android']],
    [['mobile/ios/Runner/Info.plist'], ['flutter', 'ios']],
    [['mobile/test/dashboard_test.dart'], ['flutter']],
    [['mobile/integration_test/staging_player_journey_test.dart'], ['flutter']],
    [['mobile/test_driver/integration_test.dart'], ['flutter']],
    [['referee/app/page.tsx'], ['referee']],
    [['broadcaster/src/index.mjs'], ['broadcaster']],
    [['referee/package-lock.json', 'broadcaster/package.json'], ['referee', 'broadcaster']],
    [['supabase/migrations/deleted-migration.sql'], checks],
    [['supabase/functions/new-function/index.ts'], checks],
  ];
  for (const [paths, expected] of matrix) assert.deepEqual(enabled(pullRequest(paths)), expected, paths.join(', '));
});

test('exact contract-covered CI infrastructure paths need only the always-run PR preflight', () => {
  const paths = [
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
  ];
  for (const filename of paths) assert.deepEqual(enabled(pullRequest([filename])), [], filename);
  // The CI-refactor PR is contract-only; the merged staging push still executes
  // every baseline build and journey before it may publish a release.
  assert.deepEqual(enabled(pullRequest([...paths, 'docs/development/ci.md'])), []);
  assert.deepEqual(enabled(createCiPlan({ eventName: 'push', ref: staging })), CI_OUTPUTS);
  assert.deepEqual(enabled(pullRequest([...paths, 'mobile/pubspec.yaml'])), ['flutter', 'android', 'ios']);
});

test('unknown infrastructure, native tooling and shared paths still select every baseline check', () => {
  for (const filename of [
    '.github/workflows/new-ci.yml', '.github/workflows/deploy-supabase-production.yml',
    '.github/scripts/ci-plan.test.mjs.bak', '.github/scripts/unknown.mjs',
    '.github/actions/staging-android-emulator/action.yml', '.gitignore',
    '.github/scripts/run-staging-android-e2e.sh', '.github/scripts/prepare-android-runner.sh',
    '.github/scripts/upload-staging-testflight.sh', '.github/scripts/stripe-android-config.test.mjs',
    'package.json', 'new-client/index.js', 'field.bh',
  ]) assert.deepEqual(enabled(pullRequest([filename])), checks, filename);
});

test('documentation-only and empty PRs do not select app checks or hosted mutations', () => {
  for (const paths of [
    [], ['README.md'], ['mobile/README.md', 'referee/notes.MD'],
    ['docs/architecture.svg', 'docs/release.txt'], ['LICENSE', 'NOTICE.txt'],
  ]) assert.deepEqual(enabled(pullRequest(paths)), [], paths.join(', '));
  assert.deepEqual(enabled(pullRequest(['README.md', 'mobile/lib/main.dart'])), ['flutter', 'android', 'ios']);
});

test('invalid changed paths fail closed rather than silently skip checks', () => {
  for (const changedPaths of [null, 'mobile/lib/main.dart', [''], [42]]) {
    assert.throws(() => createCiPlan({ eventName: 'pull_request', ref: prRef, changedPaths }));
  }
});

function withWorkspace(callback) {
  const root = mkdtempSync(path.join(tmpdir(), 'field-ci-plan-'));
  try { return callback(root); } finally { rmSync(root, { recursive: true, force: true }); }
}

function git(root, args) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: root } });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function commit(root, message) {
  git(root, ['add', '--all']);
  git(root, ['-c', 'user.name=CI Plan Test', '-c', 'user.email=ci-plan@example.test', 'commit', '--quiet', '-m', message]);
  return git(root, ['rev-parse', 'HEAD']);
}

function runCli(root, overrides = {}) {
  const output = path.join(root, 'github-output');
  const result = spawnSync(process.execPath, [script], {
    cwd: root,
    encoding: 'utf8',
    timeout: 10_000,
    env: { PATH: process.env.PATH, HOME: root, GITHUB_EVENT_NAME: 'push', GITHUB_REF: staging, GITHUB_OUTPUT: output, ...overrides },
  });
  assert.ifError(result.error);
  return { ...result, outputExists: existsSync(output), output: existsSync(output) ? readFileSync(output, 'utf8') : '' };
}

test('CLI appends string-valued GitHub outputs without inheriting CI secrets', () => withWorkspace((root) => {
  writeFileSync(path.join(root, 'github-output'), 'existing=value\n');
  const result = runCli(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, `existing=value\n${CI_OUTPUTS.map((name) => `${name}=true\n`).join('')}`);
  assert.equal(result.stdout, '');
}));

test('CLI honors manual modes and rejects invalid refs/modes before writing outputs', () => withWorkspace((root) => {
  const result = runCli(root, { GITHUB_EVENT_NAME: 'workflow_dispatch', CI_MODE: 'backend' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.output, /^backend=true$/m);
  assert.match(result.output, /^release=false$/m);
  rmSync(path.join(root, 'github-output'));
  for (const overrides of [
    { GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/prod' },
    { CI_MODE: 'unknown' },
    { GITHUB_EVENT_NAME: 'unknown' },
    { GITHUB_OUTPUT: '' },
  ]) {
    const failed = runCli(root, overrides);
    assert.notEqual(failed.status, 0);
    assert.equal(failed.outputExists, false);
  }
}));

test('CLI counts deleted and renamed paths using the pinned PR merge-base diff', () => withWorkspace((root) => {
  git(root, ['init', '--quiet']);
  mkdirSync(path.join(root, 'mobile', 'android'), { recursive: true });
  mkdirSync(path.join(root, 'referee', 'app'), { recursive: true });
  mkdirSync(path.join(root, 'docs'), { recursive: true });
  writeFileSync(path.join(root, 'mobile', 'android', 'old.gradle'), 'old native input\n');
  writeFileSync(path.join(root, 'referee', 'app', 'deleted.ts'), 'referee input\n');
  const base = commit(root, 'base');
  renameSync(path.join(root, 'mobile', 'android', 'old.gradle'), path.join(root, 'docs', 'old.md'));
  rmSync(path.join(root, 'referee', 'app', 'deleted.ts'));
  const head = commit(root, 'rename native input into docs and delete referee input');
  const result = runCli(root, { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: prRef, PR_BASE_SHA: base, PR_HEAD_SHA: head });
  assert.equal(result.status, 0, result.stderr);
  for (const name of ['flutter', 'android', 'referee']) assert.match(result.output, new RegExp(`^${name}=true$`, 'm'));
  for (const name of ['ios', 'broadcaster', 'database', 'backend', 'player', 'browser', 'release']) assert.match(result.output, new RegExp(`^${name}=false$`, 'm'));
}));

test('CLI preserves unusual filenames and treats SHA inputs as data, never shell commands', () => withWorkspace((root) => {
  git(root, ['init', '--quiet']);
  writeFileSync(path.join(root, 'README.md'), 'base\n');
  const base = commit(root, 'base');
  mkdirSync(path.join(root, 'mobile', 'lib'), { recursive: true });
  writeFileSync(path.join(root, 'mobile', 'lib', 'space $(touch injected)\nname.dart'), 'fixture\n');
  const head = commit(root, 'unusual filename');
  const result = runCli(root, { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: prRef, PR_BASE_SHA: base, PR_HEAD_SHA: head });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.output, /^android=true$/m);
  assert.equal(existsSync(path.join(root, 'injected')), false);
  rmSync(path.join(root, 'github-output'));
  const failed = runCli(root, { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: prRef, PR_BASE_SHA: `${base};touch injected`, PR_HEAD_SHA: head });
  assert.notEqual(failed.status, 0);
  assert.equal(failed.outputExists, false);
  assert.equal(existsSync(path.join(root, 'injected')), false);
}));

test('CLI fails closed when pinned PR commits are missing', () => withWorkspace((root) => {
  git(root, ['init', '--quiet']);
  const result = runCli(root, { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: prRef, PR_BASE_SHA: 'a'.repeat(40), PR_HEAD_SHA: 'b'.repeat(40) });
  assert.notEqual(result.status, 0);
  assert.equal(result.outputExists, false);
  assert.match(result.stderr, /fetch the pinned base and head commits/);
}));
