import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const scriptPath = fileURLToPath(new URL('./run-staging-android-e2e.sh', import.meta.url));
const driverPath = fileURLToPath(new URL('../../mobile/test_driver/integration_test.dart', import.meta.url));
const journeyTarget = 'integration_test/staging_player_journey_test.dart';

// Every Flutter, adb, watchdog, and host-diagnostic command is replaced. These
// tests never build an app, contact a device/backend, or inherit CI credentials.
function runRunner({
  mode = 'run-prebuilt',
  overrides = {},
  apk = 'valid',
  relativeApk = false,
} = {}) {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'field-android-runner-test-')));
  const workspace = path.join(root, 'github workspace');
  const bin = path.join(root, 'bin');
  const logPath = path.join(root, 'commands.jsonl');
  const apkPath = path.join(workspace, 'downloaded apk', 'player-journey.apk');
  mkdirSync(path.join(workspace, 'mobile'), { recursive: true });
  mkdirSync(path.dirname(apkPath), { recursive: true });
  mkdirSync(bin);
  if (apk === 'valid') writeFileSync(apkPath, 'mock APK, not an executable app');
  if (apk === 'empty') writeFileSync(apkPath, '');
  if (apk === 'directory') mkdirSync(apkPath);

  const mockCommand = `#!${process.execPath}
const { appendFileSync } = require('node:fs');
const { spawnSync } = require('node:child_process');
const { basename } = require('node:path');
const command = basename(process.argv[1]);
const args = process.argv.slice(2);
appendFileSync(process.env.MOCK_COMMAND_LOG, JSON.stringify({ command, args, cwd: process.cwd() }) + '\\n');
if (command === 'timeout') {
  while (args[0]?.startsWith('-')) args.shift();
  args.shift(); // duration
  const child = spawnSync(args.shift(), args, { stdio: 'inherit' });
  process.exit(child.status ?? 99);
}
if (command === 'adb') {
  if (args.includes('get-state')) console.log('device');
  process.exit(0);
}
if (command === 'flutter') {
  console.log('Mock Flutter ' + args[0]);
  process.exit(Number(process.env.MOCK_FLUTTER_STATUS ?? 0));
}
process.exit(0);
`;
  for (const command of ['flutter', 'adb', 'timeout', 'free', 'df', 'ps', 'sudo', 'cat', 'tar', 'cp']) {
    writeFileSync(path.join(bin, command), mockCommand, { mode: 0o755 });
  }

  const env = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: root,
    GITHUB_WORKSPACE: workspace,
    ANDROID_SERIAL: 'emulator-5554',
    E2E_APK_PATH: relativeApk ? path.relative(workspace, apkPath) : apkPath,
    MOCK_COMMAND_LOG: logPath,
    ...overrides,
  };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete env[key];
  }
  try {
    const result = spawnSync('/bin/bash', [scriptPath, mode], {
      cwd: workspace,
      env,
      encoding: 'utf8',
      timeout: 10_000,
    });
    assert.ifError(result.error);
    const commands = existsSync(logPath)
      ? readFileSync(logPath, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
      : [];
    const artifactDirectory = path.join(workspace, 'mobile/build/e2e-artifacts');
    return {
      status: result.status,
      output: result.stdout + result.stderr,
      commands,
      workspace,
      apkPath,
      hasLog: existsSync(path.join(artifactDirectory, 'player-journey-flutter-integration.log')),
      hasDiagnostics: existsSync(path.join(artifactDirectory, 'player-journey-adb-devices.txt')),
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function flutterCommands(result) {
  return result.commands.filter(({ command }) => command === 'flutter');
}

function fixtureEnvironment() {
  return Object.fromEntries([
    'E2E_ADMIN_PHONE', 'E2E_BOOTSTRAP_PHONE', 'E2E_CANCELLATION_GAME_ID',
    'E2E_DEV_OTP_CODE', 'E2E_MAIN_PHONE', 'E2E_MAIN_PROFILE_ID',
    'E2E_MATCH_GAME_ID', 'E2E_ONBOARDING_PHONE', 'E2E_ONBOARDING_PROFILE_ID',
    'E2E_PARTY_TARGET_PHONE', 'E2E_PARTY_TARGET_PROFILE_ID', 'E2E_REPORT_DETAILS',
    'E2E_RUN_ID', 'E2E_SUPPORT_DETAILS', 'E2E_TEST_PASSWORD',
    'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_URL',
  ].map((name) => [name, 'non-secret-test-placeholder']));
}

test('run-prebuilt requires only workspace, serial, and the APK, then uses Flutter drive', () => {
  const result = runRunner();
  assert.equal(result.status, 0, result.output);
  const calls = flutterCommands(result);
  assert.equal(calls.length, 1, result.output);
  assert.deepEqual(calls[0], {
    command: 'flutter',
    args: [
      'drive', '--debug', '--target', journeyTarget,
      '--driver', 'test_driver/integration_test.dart', '--flavor', 'staging',
      '-d', 'emulator-5554', '--use-application-binary', result.apkPath,
    ],
    cwd: path.join(result.workspace, 'mobile'),
  });
  assert.ok(result.hasLog);
  assert.ok(result.commands.some(({ command, args }) =>
    command === 'timeout' && args.includes('12m') && args.includes('--signal=INT')));
  assert.equal(result.hasDiagnostics, false);
});

test('run-prebuilt keeps relative APK paths valid after entering mobile', () => {
  const result = runRunner({ relativeApk: true });
  assert.equal(result.status, 0, result.output);
  assert.equal(flutterCommands(result)[0].args.at(-1), result.apkPath);
});

test('run-prebuilt never forwards plaintext compile-time configuration', () => {
  const result = runRunner({ overrides: fixtureEnvironment() });
  assert.equal(result.status, 0, result.output);
  assert.ok(flutterCommands(result).every(({ args }) =>
    args[0] === 'drive' && !args.some((arg) => arg.startsWith('--dart-define'))));
  assert.doesNotMatch(result.output, /non-secret-test-placeholder/);
});

test('run-prebuilt rejects absent required values before Flutter or adb', () => {
  for (const name of ['ANDROID_SERIAL', 'GITHUB_WORKSPACE', 'E2E_APK_PATH']) {
    const result = runRunner({ overrides: { [name]: undefined } });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, new RegExp(`${name} is required`));
    assert.deepEqual(result.commands, []);
  }
});

test('run-prebuilt rejects missing, empty, and non-file APKs before Flutter or adb', () => {
  for (const apk of ['missing', 'empty', 'directory']) {
    const result = runRunner({ apk });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /existing, non-empty APK/);
    assert.deepEqual(result.commands, []);
  }
});

test('run-prebuilt propagates Flutter failure and still captures diagnostics', () => {
  for (const status of [23, 124, 137]) {
    const result = runRunner({ overrides: { MOCK_FLUTTER_STATUS: String(status) } });
    assert.equal(result.status, status, result.output);
    assert.equal(flutterCommands(result).length, 1);
    assert.equal(flutterCommands(result)[0].args[0], 'drive');
    assert.ok(result.hasLog);
    assert.ok(result.hasDiagnostics);
    assert.match(result.output, status === 23
      ? /failed with exit code 23/
      : /exceeded its 12m watchdog/);
  }
});

test('build-only remains a configured APK build and never contacts adb', () => {
  const result = runRunner({
    mode: 'build-only',
    overrides: { ...fixtureEnvironment(), ANDROID_SERIAL: undefined, E2E_APK_PATH: undefined },
  });
  assert.equal(result.status, 0, result.output);
  const calls = flutterCommands(result);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args.slice(0, 5), ['build', 'apk', '--debug', '--target', journeyTarget]);
  assert.ok(calls[0].args.includes('--dart-define=APP_ENV=staging'));
  assert.ok(calls[0].args.includes('--dart-define=EMAIL_DELIVERY_ENABLED=true'));
  assert.ok(calls[0].args.includes('--dart-define=E2E_TEST_PASSWORD=non-secret-test-placeholder'));
  assert.ok(result.commands.every(({ command }) => command !== 'adb'));
});

test('existing run mode remains a configured Flutter test invocation', () => {
  const result = runRunner({
    mode: 'run',
    overrides: { ...fixtureEnvironment(), E2E_APK_PATH: undefined },
  });
  assert.equal(result.status, 0, result.output);
  const calls = flutterCommands(result);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args.slice(0, 2), ['test', journeyTarget]);
  assert.ok(calls[0].args.includes('--reporter'));
  assert.ok(calls[0].args.includes('--dart-define=APP_ENV=staging'));
  assert.ok(calls[0].args.includes('--dart-define=EMAIL_DELIVERY_ENABLED=true'));
});

test('unsupported modes fail before any external command', () => {
  const result = runRunner({ mode: 'install-only' });
  assert.equal(result.status, 2, result.output);
  assert.match(result.output, /build-only\|run\|run-prebuilt/);
  assert.deepEqual(result.commands, []);
});

test('host driver bounds its wait and writes response data on failure into E2E artifacts', () => {
  const driver = readFileSync(driverPath, 'utf8');
  assert.match(driver, /package:integration_test\/integration_test_driver\.dart/);
  assert.match(driver, /timeout: const Duration\(minutes: 10\)/);
  assert.match(driver, /writeResponseOnFailure: true/);
  assert.match(driver, /destinationDirectory: 'build\/e2e-artifacts'/);
});
