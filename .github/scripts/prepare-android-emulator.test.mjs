import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const scriptPath = fileURLToPath(new URL('./prepare-android-emulator.sh', import.meta.url));
const minimumKiB = 10 * 1024 * 1024;

// No sudo, deletion, AVD, or filesystem capacity query is used by these tests.
// Test overrides work only with the guard's non-destructive --dry-run mode.
function runGuard(overrides = {}, args = ['--dry-run']) {
  const env = {
    PATH: process.env.PATH,
    HOME: '/nonexistent-disk-guard-test-home',
    GITHUB_ACTIONS: 'true',
    RUNNER_ENVIRONMENT: 'github-hosted',
    RUNNER_OS: 'Linux',
    ANDROID_AVD_HOME: '/nonexistent-disk-guard-test-avd',
    ANDROID_EMULATOR_GUARD_TEST_OS: 'Linux',
    ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB: String(minimumKiB),
    ...overrides,
  };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete env[key];
  }
  const result = spawnSync('bash', [scriptPath, ...args], {
    env,
    encoding: 'utf8',
  });
  assert.ifError(result.error);
  return { status: result.status, output: result.stdout + result.stderr };
}

test('passes with exactly 10 GiB and never performs cleanup', () => {
  const result = runGuard();
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /Dry run: no files will be removed/);
  assert.match(result.output, /disk guard passed: 10485760 KiB available/);
  assert.doesNotMatch(result.output, /Removing unused hosted language bundles/);
});

test('fails before launch when the AVD filesystem has insufficient space', () => {
  for (const freeKiB of [0, 4319 * 1024, minimumKiB - 1]) {
    const result = runGuard({ ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB: String(freeKiB) });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /requires at least 10 GiB free on the AVD filesystem/);
    assert.match(result.output, new RegExp(`only ${freeKiB} KiB remain`));
    assert.doesNotMatch(result.output, /disk guard passed/);
  }
});

test('rejects malformed disk capacity without treating it as sufficient', () => {
  for (const value of ['', 'unknown', '-1', '10000000 KiB', '999999999999999999']) {
    const result = runGuard({ ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB: value });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /Unable to determine free space/);
  }
});

test('refuses non-hosted, non-Linux, and non-Actions environments before cleanup', () => {
  for (const overrides of [
    { RUNNER_ENVIRONMENT: 'self-hosted' },
    { RUNNER_ENVIRONMENT: undefined },
    { RUNNER_OS: 'macOS' },
    { GITHUB_ACTIONS: 'false' },
    { ANDROID_EMULATOR_GUARD_TEST_OS: 'Darwin' },
  ]) {
    const result = runGuard(overrides);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /requires a GitHub-hosted Linux runner; no cleanup was performed/);
    assert.doesNotMatch(result.output, /cleanup candidates|Removing unused/);
  }
});

test('real mode refuses test overrides even when hosted flags are present', () => {
  const result = runGuard({}, []);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /test overrides require --dry-run; no cleanup was performed/);
  assert.doesNotMatch(result.output, /Removing unused/);
});

test('real mode refuses an ordinary local environment before filesystem work', () => {
  const result = runGuard({
    GITHUB_ACTIONS: undefined,
    RUNNER_ENVIRONMENT: undefined,
    RUNNER_OS: undefined,
    ANDROID_EMULATOR_GUARD_TEST_OS: undefined,
    ANDROID_EMULATOR_GUARD_TEST_AVAILABLE_KIB: undefined,
  }, []);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /requires a GitHub-hosted Linux runner; no cleanup was performed/);
  assert.doesNotMatch(result.output, /Removing unused/);
});

test('cleanup allowlist contains no Android, Java, Flutter, APK, or workspace paths', () => {
  const result = runGuard();
  const candidates = result.output.split('\n').filter((line) => line.startsWith('  /'));
  assert.deepEqual(candidates, [
    '  /usr/share/dotnet',
    '  /usr/share/swift',
    '  /opt/ghc',
    '  /usr/local/.ghcup',
    '  /opt/hostedtoolcache/CodeQL',
    '  /usr/local/share/powershell',
  ]);
  const script = readFileSync(scriptPath, 'utf8');
  assert.match(script, /sudo -n rm -rf -- "\$\{unused_hosted_tools\[@\]\}"/);
  assert.match(script, /df --output=avail -k -- "\$avd_directory"/);
  assert.match(script, /host_os="\$\(\/usr\/bin\/uname -s\)"/);
});

test('unsupported options fail before any cleanup', () => {
  for (const args of [['--cleanup-all'], ['--dry-run', 'extra']]) {
    const result = runGuard({}, args);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /Usage:/);
    assert.doesNotMatch(result.output, /Removing unused/);
  }
});
