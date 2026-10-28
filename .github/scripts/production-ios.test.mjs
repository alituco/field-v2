import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, mkdirSync, writeFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { verifyProductionIosRelease } from './verify-production-ios-release.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const read = relative => readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8');
const sha = 'a'.repeat(40);
const stagingSha = 'b'.repeat(40);
const tree = 'c'.repeat(40);
const baseEnv = {
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/prod',
  GITHUB_REPOSITORY: 'alituco/field-v2', GITHUB_SHA: sha,
  GITHUB_RUN_NUMBER: '12',
  PRODUCTION_RELEASE_CONFIRMATION: 'BUILD_PRODUCTION_IOS',
  PRODUCTION_BACKEND_CONFIRMATION: 'PRODUCTION_BACKEND_VERIFIED',
};
const run = { head_sha: sha, head_branch: 'prod', status: 'completed', conclusion: 'success', event: 'workflow_dispatch' };

function evidence(overrides = {}) {
  const resources = new Map([
    [`repos/alituco/field-v2/actions/workflows/ci.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`, { workflow_runs: [run] }],
    [`repos/alituco/field-v2/actions/workflows/deploy-supabase-production.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`, { workflow_runs: [run] }],
    ['repos/alituco/field-v2/actions/workflows/upload-production-testflight.yml/runs?branch=prod&status=completed&per_page=100', { workflow_runs: [] }],
    [`repos/alituco/field-v2/git/commits/${sha}`, { tree: { sha: tree } }],
    ['repos/alituco/field-v2/deployments?environment=staging&per_page=100', [{ id: 123, sha: stagingSha, environment: 'staging', description: 'Field staging Supabase deployment' }]],
    ['repos/alituco/field-v2/deployments/123/statuses?per_page=1', [{ state: 'success', description: 'Migrations, smoke, Android, referee, and admin E2E passed' }]],
    [`repos/alituco/field-v2/git/commits/${stagingSha}`, { tree: { sha: tree } }],
    [`repos/alituco/field-v2/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingSha}&event=push&status=completed&per_page=100`,
      { workflow_runs: [{ ...run, head_sha: stagingSha, head_branch: 'staging', event: 'push' }] }],
    ...Object.entries(overrides),
  ]);
  const calls = [];
  return {
    calls,
    readGithub(resource) {
      calls.push(resource);
      assert.ok(resources.has(resource), `Unexpected GitHub read: ${resource}`);
      return structuredClone(resources.get(resource));
    },
  };
}

test('production iOS requires exact successful CI/backend evidence and an identical successful staging tree', () => {
  const mock = evidence();
  assert.deepEqual(verifyProductionIosRelease({ env: baseEnv, readGithub: mock.readGithub }), { sha, stagingSha });
  assert.equal(mock.calls.length, 8);
});

test('wrong branch/event/repository/confirmations fail before reading GitHub', () => {
  for (const changes of [
    { GITHUB_REF: 'refs/heads/staging' }, { GITHUB_EVENT_NAME: 'push' },
    { GITHUB_REPOSITORY: 'other/repo' }, { GITHUB_SHA: 'latest' },
    { GITHUB_RUN_NUMBER: '0' },
    { PRODUCTION_RELEASE_CONFIRMATION: '' }, { PRODUCTION_BACKEND_CONFIRMATION: '' },
  ]) {
    assert.throws(() => verifyProductionIosRelease({ env: { ...baseEnv, ...changes }, readGithub: () => assert.fail('must not read GitHub') }));
  }
});

test('rerunning an older upload cannot submit a lower build after a newer workflow succeeded', () => {
  const resource = 'repos/alituco/field-v2/actions/workflows/upload-production-testflight.yml/runs?branch=prod&status=completed&per_page=100';
  const newer = evidence({ [resource]: { workflow_runs: [{ ...run, run_number: 13 }] } });
  assert.throws(() => verifyProductionIosRelease({ env: baseEnv, readGithub: newer.readGithub }), /newer production iOS workflow/);
  const retry = evidence({ [resource]: { workflow_runs: [{ ...run, run_number: 12 }] } });
  assert.deepEqual(verifyProductionIosRelease({ env: baseEnv, readGithub: retry.readGithub }), { sha, stagingSha });
  const failedNewer = evidence({ [resource]: { workflow_runs: [{ ...run, run_number: 13, conclusion: 'failure' }] } });
  assert.deepEqual(verifyProductionIosRelease({ env: baseEnv, readGithub: failedNewer.readGithub }), { sha, stagingSha });
});

test('the release gate also enforces restrictions when executed as a CLI', () => {
  const result = spawnSync(process.execPath, [path.join(directory, 'verify-production-ios-release.mjs')], {
    encoding: 'utf8', env: { ...process.env, ...baseEnv, GITHUB_REF: 'refs/heads/staging' }, timeout: 5000,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /manual dispatch of the prod branch/);
});

test('missing, failed, skipped, stale or wrong-branch CI/backend evidence never permits an upload', () => {
  for (const workflow of ['ci.yml', 'deploy-supabase-production.yml']) {
    for (const runs of [[], [{ ...run, conclusion: 'failure' }], [{ ...run, conclusion: 'skipped' }],
      [{ ...run, status: 'in_progress' }], [{ ...run, head_sha: stagingSha }], [{ ...run, head_branch: 'staging' }]]) {
      const key = `repos/alituco/field-v2/actions/workflows/${workflow}/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`;
      const mock = evidence({ [key]: { workflow_runs: runs } });
      assert.throws(() => verifyProductionIosRelease({ env: baseEnv, readGithub: mock.readGithub }),
        workflow === 'ci.yml' ? /passed CI/ : /production backend deployment/);
    }
  }
});

test('different staging code, failed hosted journey and malformed evidence keep production blocked', () => {
  for (const overrides of [
    { [`repos/alituco/field-v2/git/commits/${stagingSha}`]: { tree: { sha: 'd'.repeat(40) } } },
    { 'repos/alituco/field-v2/deployments/123/statuses?per_page=1': [{ state: 'failure' }] },
    { 'repos/alituco/field-v2/deployments?environment=staging&per_page=100': [] },
    { 'repos/alituco/field-v2/deployments?environment=staging&per_page=100': { message: 'error' } },
    { [`repos/alituco/field-v2/git/commits/${sha}`]: { tree: { sha: 'invalid' } } },
  ]) {
    const mock = evidence(overrides);
    assert.throws(() => verifyProductionIosRelease({ env: baseEnv, readGithub: mock.readGithub }));
  }
});

test('an early successful backend deployment cannot masquerade as the verified full staging release', () => {
  for (const overrides of [
    { 'repos/alituco/field-v2/deployments?environment=staging&per_page=100': [{ id: 123, sha: stagingSha, environment: 'staging' }] },
    { 'repos/alituco/field-v2/deployments/123/statuses?per_page=1': [{ state: 'success' }] },
    { [`repos/alituco/field-v2/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingSha}&event=push&status=completed&per_page=100`]: { workflow_runs: [] } },
    { [`repos/alituco/field-v2/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingSha}&event=push&status=completed&per_page=100`]:
      { workflow_runs: [{ ...run, head_sha: stagingSha, head_branch: 'staging', event: 'push', conclusion: 'failure' }] } },
    { [`repos/alituco/field-v2/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingSha}&event=push&status=completed&per_page=100`]:
      { workflow_runs: [{ ...run, head_sha: stagingSha, head_branch: 'staging', event: 'workflow_dispatch' }] } },
  ]) {
    const mock = evidence(overrides);
    assert.throws(() => verifyProductionIosRelease({ env: baseEnv, readGithub: mock.readGithub }), /explicit verified staging release/);
  }
});

test('production input preflight rejects environment/credential mistakes before signing or upload', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'field-production-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin'); mkdirSync(bin);
  const calls = path.join(root, 'commands');
  for (const command of ['security', 'flutter', 'xcrun', 'xcodebuild']) {
    writeFileSync(path.join(bin, command), '#!/bin/sh\nprintf called >> "$TEST_COMMANDS"\nexit 99\n', { mode: 0o755 });
  }
  const env = {
    ...process.env, ...baseEnv, PATH: `${bin}:${process.env.PATH}`, TEST_COMMANDS: calls,
    APP_STORE_CONNECT_ISSUER_ID: '00000000-0000-0000-0000-000000000000',
    APP_STORE_CONNECT_KEY_ID: 'ABCDEFGHIJ',
    APP_STORE_CONNECT_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----',
    IOS_DISTRIBUTION_CERTIFICATE_BASE64: 'fixture-only', IOS_DISTRIBUTION_CERTIFICATE_PASSWORD: 'fixture-password',
    IOS_PRODUCTION_PROVISIONING_PROFILE_BASE64: 'fixture-only',
    SUPABASE_URL: 'https://zjsjuuhborxrlmdcpvlj.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
    STRIPE_PUBLISHABLE_KEY: 'pk_live_fixture', APPLE_TEAM_ID: '69B646V2WM', IOS_PRODUCTION_BUNDLE_ID: 'com.alialtaraif.field',
    APPLE_MERCHANT_ID: 'merchant.com.alialtaraif.fieldrush', PRODUCTION_EMAIL_DELIVERY_ENABLED: 'true',
    PRODUCTION_PUSH_NOTIFICATIONS_ENABLED: 'false', GITHUB_RUN_NUMBER: '12', GITHUB_RUN_ATTEMPT: '1',
    RUNNER_TEMP: root, GITHUB_WORKSPACE: root,
  };
  const push = { PRODUCTION_PUSH_NOTIFICATIONS_ENABLED: 'true', PUSH_FIREBASE_API_KEY: 'AIzaFixture',
    PUSH_FIREBASE_PROJECT_ID: 'fieldrush-production', PUSH_FIREBASE_SENDER_ID: '1234567890',
    PUSH_FIREBASE_IOS_APP_ID: '1:1234567890:ios:abcdef', PUSH_FIREBASE_IOS_BUNDLE_ID: 'com.alialtaraif.field' };
  const jwt = (role, ref = 'zjsjuuhborxrlmdcpvlj') => `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify({ role, ref })).toString('base64url')}.fixture`;
  const invoke = changes => spawnSync('/bin/bash', [path.join(directory, 'upload-production-testflight.sh'), '--check-inputs'], {
    encoding: 'utf8', env: { ...env, ...changes }, timeout: 5000,
  });
  for (const valid of [{}, push, { SUPABASE_PUBLISHABLE_KEY: jwt('anon') }]) {
    const result = invoke(valid);
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  }
  for (const invalid of [
    { GITHUB_REF: 'refs/heads/staging' }, { GITHUB_EVENT_NAME: 'push' },
    { PRODUCTION_RELEASE_CONFIRMATION: 'yes' }, { PRODUCTION_BACKEND_CONFIRMATION: '' },
    { SUPABASE_URL: 'https://nfdkdhdevpstfspazbfn.supabase.co' }, { SUPABASE_URL: `${env.SUPABASE_URL}/path` },
    { STRIPE_PUBLISHABLE_KEY: 'pk_test_fixture' }, { APPLE_TEAM_ID: 'OTHERTEAM1' },
    { IOS_PRODUCTION_BUNDLE_ID: 'com.alialtaraif.field.staging' }, { APPLE_MERCHANT_ID: 'merchant.other' },
    { SUPABASE_PUBLISHABLE_KEY: 'sb_secret_never_mobile' }, { SUPABASE_PUBLISHABLE_KEY: jwt('service_role') },
    { SUPABASE_PUBLISHABLE_KEY: jwt('anon', 'nfdkdhdevpstfspazbfn') },
    { APP_STORE_CONNECT_PRIVATE_KEY: 'broken' }, { APP_STORE_CONNECT_KEY_ID: '../../bad' },
    { PRODUCTION_EMAIL_DELIVERY_ENABLED: 'yes' }, { PRODUCTION_PUSH_NOTIFICATIONS_ENABLED: '1' },
    { GITHUB_RUN_NUMBER: '1;echo bad' }, { GITHUB_RUN_ATTEMPT: '100' },
    { ...push, PUSH_FIREBASE_PROJECT_ID: '' }, { ...push, PUSH_FIREBASE_IOS_BUNDLE_ID: 'com.alialtaraif.field.staging' },
    { ...push, PUSH_FIREBASE_IOS_APP_ID: '1:999:ios:abcdef' },
    { ...push, PUSH_FIREBASE_SENDER_ID: '756208653017', PUSH_FIREBASE_IOS_APP_ID: '1:756208653017:ios:9a38da8f44901e98f7a4c8' },
  ]) {
    const result = invoke(invalid);
    assert.equal(result.status, 1, `${JSON.stringify(Object.keys(invalid))}: ${result.stdout}${result.stderr}`);
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-password|BEGIN PRIVATE KEY|sb_secret_never_mobile/);
  }
  assert.equal(existsSync(calls), false, 'preflight must not import credentials, build, sign, or upload');
});

function plist(value) {
  if (value instanceof Date) return `<date>${value.toISOString().replace('.000', '')}</date>`;
  if (Array.isArray(value)) return `<array>${value.map(plist).join('')}</array>`;
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>';
  if (value && typeof value === 'object') return `<dict>${Object.entries(value).map(([key, item]) => `<key>${key}</key>${plist(item)}`).join('')}</dict>`;
  return `<string>${String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</string>`;
}

test('production signing validation rejects wrong profiles, debugging, missing merchant, and invalid APNs before upload', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'field-production-plists-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const entitlements = { 'application-identifier': '69B646V2WM.com.alialtaraif.field',
    'com.apple.developer.team-identifier': '69B646V2WM', 'get-task-allow': false,
    'com.apple.developer.in-app-payments': ['merchant.com.alialtaraif.fieldrush'], 'aps-environment': 'production' };
  const profile = { Name: 'Field Production App Store', UUID: '12345678-1234-1234-1234-123456789ABC',
    TeamIdentifier: ['69B646V2WM'], ExpirationDate: new Date('2099-01-01T00:00:00Z'), Entitlements: entitlements };
  const info = { CFBundleIdentifier: 'com.alialtaraif.field', CFBundleDisplayName: 'Fieldrush',
    CFBundleShortVersionString: '1.0.0', CFBundleVersion: '1201', FirebaseMessagingAutoInitEnabled: false,
    ITSAppUsesNonExemptEncryption: false, CFBundleURLTypes: [{ CFBundleURLSchemes: ['com.alialtaraif.field'] }],
    UIBackgroundModes: ['fetch', 'remote-notification'] };
  const write = (name, value) => {
    const file = path.join(root, name);
    writeFileSync(file, `<?xml version="1.0"?><plist version="1.0">${plist(value)}</plist>`);
    return file;
  };
  const validate = args => spawnSync('python3', [path.join(directory, 'validate-production-ios.py'), ...args], { encoding: 'utf8' });
  const checkProfile = (value, push = 'true') => validate(['profile', write('profile.plist', value), push]);
  const checkApp = (value = entitlements, metadata = info, push = 'true') => validate(['app', write('entitlements.plist', value), write('Info.plist', metadata), push, '1.0.0', '1201']);
  assert.equal(checkProfile(profile).status, 0);
  assert.equal(checkApp().status, 0);
  const withoutPush = { ...entitlements }; delete withoutPush['aps-environment'];
  assert.equal(checkApp(withoutPush, info, 'false').status, 0);
  for (const value of [
    { ...profile, Name: 'Field Staging App Store' }, { ...profile, TeamIdentifier: ['OTHERTEAM1'] },
    { ...profile, UUID: '../../escape' }, { ...profile, ExpirationDate: new Date('2020-01-01T00:00:00Z') },
    { ...profile, ProvisionedDevices: ['device'] }, { ...profile, ProvisionsAllDevices: true },
    { ...profile, Entitlements: { ...entitlements, 'application-identifier': '69B646V2WM.com.alialtaraif.field.staging' } },
    { ...profile, Entitlements: { ...entitlements, 'get-task-allow': true } },
    { ...profile, Entitlements: { ...entitlements, 'com.apple.developer.in-app-payments': [] } },
    { ...profile, Entitlements: { ...entitlements, 'aps-environment': 'development' } },
  ]) assert.equal(checkProfile(value).status, 1);
  for (const [value, metadata, push] of [
    [entitlements, { ...info, CFBundleIdentifier: 'com.alialtaraif.field.staging' }],
    [entitlements, { ...info, CFBundleDisplayName: 'Fieldrush Staging' }],
    [entitlements, { ...info, CFBundleVersion: '1' }],
    [entitlements, { ...info, CFBundleShortVersionString: '2.0.0' }],
    [entitlements, { ...info, FirebaseMessagingAutoInitEnabled: true }],
    [entitlements, { ...info, ITSAppUsesNonExemptEncryption: true }],
    [entitlements, { ...info, CFBundleURLTypes: [] }],
    [entitlements, { ...info, UIBackgroundModes: ['fetch'] }],
    [withoutPush, info], [entitlements, info, 'false'],
  ]) assert.equal(checkApp(value, metadata, push).status, 1);
});

test('production workflow is manual/protected and validates archive and exported IPA without submitting review', () => {
  const workflow = read('.github/workflows/upload-production-testflight.yml');
  assert.match(workflow, /on:\n  workflow_dispatch:/);
  assert.doesNotMatch(workflow, /^  (?:push|pull_request|schedule|workflow_run):/m);
  assert.match(workflow, /environment:\n      name: production/);
  assert.match(workflow, /needs: release-evidence/);
  assert.match(workflow, /if: github.ref == 'refs\/heads\/prod'/);
  assert.equal((workflow.match(/node \.github\/scripts\/verify-production-ios-release.mjs/g) ?? []).length, 2);
  assert.match(workflow, /concurrency:\n  group: production-ios-upload\n  cancel-in-progress: false/);
  assert.doesNotMatch(workflow, /submit-for-review|auto-release|appStoreVersionSubmissions/);
  const upload = read('.github/scripts/upload-production-testflight.sh');
  assert.ok(upload.indexOf('verify_app "$archive_path/') < upload.indexOf('-exportArchive'));
  assert.ok(upload.indexOf('verify_app "$signing_root/exported-ipa/') < upload.indexOf('--upload-app'));
  assert.match(upload, /--dart-define=DEV=false --dart-define=PROFILE_SWITCHER_ENABLED=false/);
  assert.doesNotMatch(upload, /(?:^|\s)(?:INFOPLIST_FILE|CODE_SIGN_ENTITLEMENTS)=/);
  const base = read('mobile/ios/Runner/Info.plist');
  const push = read('mobile/ios/Runner/Info-production-push.plist');
  assert.equal(push.replace(/\t<key>UIBackgroundModes<\/key>\n\t<array>\n\t\t<string>fetch<\/string>\n\t\t<string>remote-notification<\/string>\n\t<\/array>\n/, ''), base);
  assert.match(read('mobile/ios/Runner/Runner-production.entitlements'), /merchant.com.alialtaraif.fieldrush/);
  assert.doesNotMatch(read('mobile/ios/Runner/Runner-production.entitlements'), /aps-environment/);
  assert.match(read('mobile/ios/Runner/Runner-production-push.entitlements'), /<key>aps-environment<\/key>\s*<string>production<\/string>/);
});

test('mocked production archive/export verifies signatures before upload and cleans signing files on success or failure', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'field-production-upload-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const scenario of ['push-disabled', 'push-enabled', 'bad-exported-signature', 'archive-failure', 'profile-backup-failure']) {
    const folder = path.join(root, scenario); mkdirSync(folder);
    const bin = path.join(folder, 'bin'); mkdirSync(bin);
    const profiles = path.join(folder, 'profiles'); mkdirSync(profiles);
    const workspace = path.join(folder, 'workspace'); mkdirSync(workspace);
    const temp = path.join(folder, 'temp'); mkdirSync(temp);
    mkdirSync(path.join(workspace, 'mobile', 'ios'), { recursive: true });
    writeFileSync(path.join(workspace, 'mobile', 'pubspec.yaml'), 'version: 1.0.0+1\n');
    const push = scenario === 'push-enabled';
    const entitlements = { 'application-identifier': '69B646V2WM.com.alialtaraif.field',
      'com.apple.developer.team-identifier': '69B646V2WM', 'get-task-allow': false,
      'com.apple.developer.in-app-payments': ['merchant.com.alialtaraif.fieldrush'],
      ...(push ? { 'aps-environment': 'production' } : {}) };
    const profile = { Name: 'Field Production App Store', UUID: '12345678-1234-1234-1234-123456789ABC',
      TeamIdentifier: ['69B646V2WM'], ExpirationDate: new Date('2099-01-01T00:00:00Z'), Entitlements: entitlements };
    const info = { CFBundleIdentifier: 'com.alialtaraif.field', CFBundleDisplayName: 'Fieldrush',
      CFBundleShortVersionString: '1.0.0', CFBundleVersion: '1201', FirebaseMessagingAutoInitEnabled: false,
      ITSAppUsesNonExemptEncryption: false, CFBundleURLTypes: [{ CFBundleURLSchemes: ['com.alialtaraif.field'] }],
      ...(push ? { UIBackgroundModes: ['fetch', 'remote-notification'] } : {}) };
    const encode = value => `<?xml version="1.0"?><plist version="1.0">${plist(value)}</plist>`;
    writeFileSync(path.join(folder, 'info.plist'), encode(info));
    writeFileSync(path.join(folder, 'entitlements.plist'), encode(entitlements));
    writeFileSync(path.join(folder, 'wrong-entitlements.plist'), encode({ ...entitlements, 'application-identifier': '69B646V2WM.com.alialtaraif.field.staging' }));
    const existingProfile = path.join(profiles, `${profile.UUID}.mobileprovision`);
    writeFileSync(existingProfile, 'previous-profile');
    const script = path.join(folder, 'upload-production-testflight.sh');
    writeFileSync(script, read('.github/scripts/upload-production-testflight.sh')
      .replaceAll('/usr/libexec/PlistBuddy', '"$TEST_PLIST_BUDDY"')
      .replace('profiles_path="$HOME/Library/MobileDevice/Provisioning Profiles"', 'profiles_path="$TEST_PROFILE_DIR"'));
    writeFileSync(path.join(folder, 'validate-production-ios.py'), read('.github/scripts/validate-production-ios.py'));
    const plistBuddy = path.join(bin, 'PlistBuddy');
    writeFileSync(plistBuddy, '#!/usr/bin/env python3\nimport plistlib,sys\nwith open(sys.argv[3],"rb") as source: value=plistlib.load(source)\nprint(value[sys.argv[2].removeprefix("Print :")])\n', { mode: 0o755 });
    const commands = path.join(folder, 'commands.jsonl');
    const mock = `#!${process.execPath}
const fs=require('node:fs'), path=require('node:path'), cp=require('node:child_process');
const command=path.basename(process.argv[1]), args=process.argv.slice(2), folder=process.env.TEST_STATE_DIR;
fs.appendFileSync(process.env.TEST_COMMANDS,JSON.stringify({command,operation:args[0],...(command==='security'&&args[0]==='list-keychains'?{args}:{} )})+'\\n');
const argument=(name)=>args[args.indexOf(name)+1];
if(command==='security'){
  if(args[0]==='cms') process.stdout.write(fs.readFileSync(argument('-i')));
  else if(args[0]==='list-keychains'&&!args.includes('-s')) console.log('    "'+path.join(folder,'original login.keychain-db')+'"');
  else if(args[0]==='find-identity') console.log('1) FIXTURE Apple Distribution: Ali Altaraif (69B646V2WM)');
}else if(command==='xcodebuild'){
  if(args.includes('archive')){
    if(process.env.TEST_SCENARIO==='archive-failure') process.exit(42);
    const app=path.join(argument('-archivePath'),'Products/Applications/Runner.app');
    fs.mkdirSync(app,{recursive:true}); fs.copyFileSync(path.join(folder,'info.plist'),path.join(app,'Info.plist'));
  }else if(args.includes('-exportArchive')){
    const payload=path.join(folder,'zip/Payload/Runner.app');fs.mkdirSync(payload,{recursive:true});
    fs.copyFileSync(path.join(folder,'info.plist'),path.join(payload,'Info.plist'));
    cp.execFileSync('zip',['-qr',path.join(argument('-exportPath'),'Field.ipa'),'Payload'],{cwd:path.join(folder,'zip')});
  }else process.exit(99);
}else if(command==='codesign'){
  if(args[0]==='--display'){
    const bad=process.env.TEST_SCENARIO==='bad-exported-signature'&&args.at(-1).includes('exported-ipa');
    process.stdout.write(fs.readFileSync(path.join(folder,bad?'wrong-entitlements.plist':'entitlements.plist')));
  }
}else if(command==='xcrun'){
  if(args[0]!=='altool'||!args.includes('--upload-app'))process.exit(99);
  console.log('Mock production upload accepted');
}else if(command==='cp'){
  if(process.env.TEST_SCENARIO==='profile-backup-failure'&&args.at(-1).endsWith('previous.mobileprovision.pending')){
    fs.writeFileSync(args.at(-1),'partial-backup');process.exit(42);
  }
  cp.execFileSync('/bin/cp',args);
}else if(!['flutter','pod'].includes(command))process.exit(99);
`;
    for (const command of ['security', 'flutter', 'pod', 'xcodebuild', 'codesign', 'xcrun', 'cp']) writeFileSync(path.join(bin, command), mock, { mode: 0o755 });
    const env = { ...process.env, ...baseEnv, PATH: `${bin}:${process.env.PATH}`, TEST_COMMANDS: commands,
      TEST_STATE_DIR: folder, TEST_SCENARIO: scenario, TEST_PLIST_BUDDY: plistBuddy, TEST_PROFILE_DIR: profiles,
      APP_STORE_CONNECT_ISSUER_ID: '00000000-0000-0000-0000-000000000000', APP_STORE_CONNECT_KEY_ID: 'ABCDEFGHIJ',
      APP_STORE_CONNECT_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----',
      IOS_DISTRIBUTION_CERTIFICATE_BASE64: Buffer.from('fixture-only').toString('base64'), IOS_DISTRIBUTION_CERTIFICATE_PASSWORD: 'fixture-password',
      IOS_PRODUCTION_PROVISIONING_PROFILE_BASE64: Buffer.from(encode(profile)).toString('base64'),
      SUPABASE_URL: 'https://zjsjuuhborxrlmdcpvlj.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
      STRIPE_PUBLISHABLE_KEY: 'pk_live_fixture', APPLE_TEAM_ID: '69B646V2WM', IOS_PRODUCTION_BUNDLE_ID: 'com.alialtaraif.field',
      APPLE_MERCHANT_ID: 'merchant.com.alialtaraif.fieldrush', PRODUCTION_EMAIL_DELIVERY_ENABLED: 'true',
      PRODUCTION_PUSH_NOTIFICATIONS_ENABLED: String(push), GITHUB_RUN_NUMBER: '12', GITHUB_RUN_ATTEMPT: '1',
      RUNNER_TEMP: temp, GITHUB_WORKSPACE: workspace,
      PUSH_FIREBASE_API_KEY: 'AIzaFixture', PUSH_FIREBASE_PROJECT_ID: 'fieldrush-production', PUSH_FIREBASE_SENDER_ID: '1234567890',
      PUSH_FIREBASE_IOS_APP_ID: '1:1234567890:ios:abcdef', PUSH_FIREBASE_IOS_BUNDLE_ID: 'com.alialtaraif.field',
    };
    const result = spawnSync('/bin/bash', [script], { encoding: 'utf8', env, timeout: 20_000 });
    const success = scenario === 'push-disabled' || scenario === 'push-enabled';
    assert.equal(result.status === 0, success, `${scenario}: ${result.stdout}${result.stderr}`);
    const log = readFileSync(commands, 'utf8').trim().split('\n').map(JSON.parse);
    const uploads = log.filter(item => item.command === 'xcrun');
    assert.equal(uploads.length, success ? 1 : 0, `${scenario}: invalid archive/export must never upload`);
    assert.ok(log.some(item => item.command === 'security' && item.operation === 'delete-keychain'), scenario);
    assert.equal(readFileSync(existingProfile, 'utf8'), 'previous-profile', 'existing installed profile must be restored');
    assert.equal(readdirSync(temp).some(name => name.startsWith('field-production-signing.')), false,
      'all temporary private signing material must be removed');
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-password|BEGIN PRIVATE KEY/);
    const listChanges = log.filter(item => item.command === 'security' && item.operation === 'list-keychains' && item.args.includes('-s'));
    assert.deepEqual(listChanges.at(-1).args, ['list-keychains', '-d', 'user', '-s', path.join(folder, 'original login.keychain-db')]);
  }
});
