import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { androidProductionVersionCode, verifyProductionAndroidRelease } from './verify-production-android-release.mjs';

const read = relative => readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8');
const sha = 'a'.repeat(40), stagingSha = 'b'.repeat(40), tree = 'c'.repeat(40);
const baseEnv = {
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/prod',
  GITHUB_REPOSITORY: 'alituco/field-v2', GITHUB_SHA: sha,
  GITHUB_RUN_NUMBER: '2', GITHUB_RUN_ATTEMPT: '1',
  PRODUCTION_RELEASE_CONFIRMATION: 'BUILD_PRODUCTION_ANDROID',
  PRODUCTION_BACKEND_CONFIRMATION: 'PRODUCTION_BACKEND_READY_FOR_ANDROID',
};
const run = { head_sha: sha, head_branch: 'prod', status: 'completed', conclusion: 'success', event: 'workflow_dispatch' };
const base = 'repos/alituco/field-v2';
const backendQuery = `${base}/actions/workflows/deploy-supabase-production.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`;
const buildsQuery = `${base}/actions/workflows/build-production-android.yml/runs?branch=prod&status=completed&per_page=100`;
function evidence(overrides = {}) {
  const resources = new Map([
    [`${base}/actions/workflows/ci.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`, { workflow_runs: [run] }],
    [backendQuery, { workflow_runs: [run] }], [buildsQuery, { workflow_runs: [] }],
    [`${base}/git/commits/${sha}`, { tree: { sha: tree } }],
    [`${base}/deployments?environment=staging&per_page=100`, [{ id: 123, sha: stagingSha, environment: 'staging', description: 'Field staging Supabase deployment' }]],
    [`${base}/deployments/123/statuses?per_page=1`, [{ state: 'success', description: 'Migrations, smoke, Android, referee, and admin E2E passed' }]],
    [`${base}/git/commits/${stagingSha}`, { tree: { sha: tree } }],
    [`${base}/actions/workflows/ci.yml/runs?branch=staging&head_sha=${stagingSha}&event=push&status=completed&per_page=100`,
      { workflow_runs: [{ ...run, head_sha: stagingSha, head_branch: 'staging', event: 'push' }] }],
    ...Object.entries(overrides),
  ]);
  return resource => {
    assert.ok(resources.has(resource), `Unexpected release evidence read: ${resource}`);
    return structuredClone(resources.get(resource));
  };
}

test('Android signing requires exact prod CI/backend and the same fully qualified staging tree', () => {
  assert.deepEqual(verifyProductionAndroidRelease({ env: baseEnv, readGithub: evidence() }), { sha, stagingSha });
  for (const changes of [
    { GITHUB_REF: 'refs/heads/staging' }, { GITHUB_EVENT_NAME: 'push' },
    { GITHUB_REPOSITORY: 'other/repo' }, { GITHUB_SHA: 'latest' },
    { PRODUCTION_RELEASE_CONFIRMATION: 'yes' }, { PRODUCTION_BACKEND_CONFIRMATION: '' },
  ]) assert.throws(() => verifyProductionAndroidRelease({ env: { ...baseEnv, ...changes }, readGithub: () => assert.fail('must fail before GitHub read') }));
  for (const changes of [
    { [backendQuery]: { workflow_runs: [] } },
    { [backendQuery]: { workflow_runs: [{ ...run, head_sha: stagingSha }] } },
    { [backendQuery]: { workflow_runs: [{ ...run, conclusion: 'skipped' }] } },
    { [`${base}/git/commits/${stagingSha}`]: { tree: { sha: 'd'.repeat(40) } } },
    { [`${base}/deployments/123/statuses?per_page=1`]: [{ state: 'success' }] },
    { [`${base}/actions/workflows/ci.yml/runs?branch=prod&head_sha=${sha}&status=completed&per_page=100`]: { workflow_runs: [{ ...run, conclusion: 'failure' }] } },
    { [buildsQuery]: { workflow_runs: [{ ...run, run_number: 3 }] } },
  ]) assert.throws(() => verifyProductionAndroidRelease({ env: baseEnv, readGithub: evidence(changes) }));
});

test('Android version codes stay unique on retries and within Play bounds', () => {
  assert.equal(androidProductionVersionCode(baseEnv), 201);
  assert.equal(androidProductionVersionCode({ ...baseEnv, GITHUB_RUN_ATTEMPT: '2' }), 202);
  for (const change of [
    { GITHUB_RUN_NUMBER: '0' }, { GITHUB_RUN_NUMBER: '01' }, { GITHUB_RUN_NUMBER: '21000000' },
    { GITHUB_RUN_NUMBER: '9999999999999999999' }, { GITHUB_RUN_ATTEMPT: '0' },
    { GITHUB_RUN_ATTEMPT: '100' }, { GITHUB_RUN_ATTEMPT: '1;bad' },
  ]) assert.throws(() => androidProductionVersionCode({ ...baseEnv, ...change }));
});

const fixtureCertificate = Buffer.from('fixture-certificate-not-a-private-key');
const digest = value => createHash('sha256').update(value).digest('hex');
function signingEnv(root) {
  return {
    ...process.env, ...baseEnv, RUNNER_TEMP: root, GITHUB_WORKSPACE: root,
    RUNNER_OS: 'Linux', RUNNER_ENVIRONMENT: 'github-hosted', ANDROID_HOME: root,
    ANDROID_PRODUCTION_PACKAGE_ID: 'gg.fieldrush.app',
    ANDROID_UPLOAD_KEYSTORE_BASE64: Buffer.from('fixture-only').toString('base64'),
    ANDROID_UPLOAD_STORE_PASSWORD: 'fixture-store-password', ANDROID_UPLOAD_KEY_PASSWORD: 'fixture-key-password',
    ANDROID_UPLOAD_KEY_ALIAS: 'fixture-upload', ANDROID_UPLOAD_CERTIFICATE_SHA256: digest(fixtureCertificate),
    SUPABASE_URL: 'https://zjsjuuhborxrlmdcpvlj.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
    STRIPE_PUBLISHABLE_KEY: 'pk_live_fixture', PRODUCTION_EMAIL_DELIVERY_ENABLED: 'true',
    PRODUCTION_ANDROID_PUSH_NOTIFICATIONS_ENABLED: 'false',
  };
}

test('preflight rejects wrong targets, server keys and unsafe credentials before invoking native tools', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'field-android-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const env = signingEnv(root);
  const invoke = changes => spawnSync('/bin/bash', [new URL('./build-production-android.sh', import.meta.url).pathname, '--check-inputs'], {
    encoding: 'utf8', env: { ...env, ...changes }, timeout: 5000,
  });
  const jwt = (role, ref = 'zjsjuuhborxrlmdcpvlj') => `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify({ role, ref })).toString('base64url')}.fixture`;
  for (const valid of [{}, { ANDROID_UPLOAD_CERTIFICATE_SHA256: digest(fixtureCertificate).match(/../g).join(':').toUpperCase() },
    { SUPABASE_PUBLISHABLE_KEY: jwt('anon') }]) assert.equal(invoke(valid).status, 0);
  for (const invalid of [
    { GITHUB_REF: 'refs/heads/staging' }, { GITHUB_EVENT_NAME: 'push' }, { GITHUB_REPOSITORY: 'other/repo' },
    { ANDROID_PRODUCTION_PACKAGE_ID: 'com.field.field.staging' }, { SUPABASE_URL: 'https://nfdkdhdevpstfspazbfn.supabase.co' },
    { ANDROID_PRODUCTION_PACKAGE_ID: 'com.field.field' },
    { SUPABASE_PUBLISHABLE_KEY: 'sb_secret_never_mobile' }, { SUPABASE_PUBLISHABLE_KEY: jwt('service_role') },
    { SUPABASE_PUBLISHABLE_KEY: jwt('service_role'), PYTHONOPTIMIZE: '1' },
    { SUPABASE_PUBLISHABLE_KEY: jwt('anon', 'nfdkdhdevpstfspazbfn') }, { STRIPE_PUBLISHABLE_KEY: 'pk_test_fixture' },
    { ANDROID_UPLOAD_KEYSTORE_BASE64: '' }, { ANDROID_UPLOAD_KEYSTORE_BASE64: '!not-base64' },
    { ANDROID_UPLOAD_KEY_PASSWORD: '' }, { ANDROID_UPLOAD_STORE_PASSWORD: 'fixture-store-password\nsecond-line' },
    { ANDROID_UPLOAD_CERTIFICATE_SHA256: 'bad' }, { ANDROID_UPLOAD_KEY_ALIAS: '../bad' },
    { PRODUCTION_EMAIL_DELIVERY_ENABLED: 'yes' }, { PRODUCTION_ANDROID_PUSH_NOTIFICATIONS_ENABLED: 'true' },
    { GITHUB_RUN_NUMBER: '21000000' }, { GITHUB_RUN_ATTEMPT: '100' }, { RUNNER_ENVIRONMENT: 'self-hosted' },
  ]) {
    const result = invoke(invalid);
    assert.equal(result.status, 1, JSON.stringify(Object.keys(invalid)));
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-store-password|fixture-key-password|sb_secret_never_mobile/);
  }
  assert.deepEqual(readdirSync(root), [], 'preflight must not write signing files or build outputs');
});

test('protected Android workflow cannot publish and exposes signing keys only to its final build step', () => {
  const workflow = read('.github/workflows/build-production-android.yml');
  assert.match(workflow, /on:\n  workflow_dispatch:/);
  assert.doesNotMatch(workflow, /^  (?:push|pull_request|schedule|workflow_run):/m);
  assert.match(workflow, /if: github.ref == 'refs\/heads\/prod'/);
  assert.match(workflow, /environment:\n      name: production/);
  assert.match(workflow, /concurrency:\n  group: production-android-build\n  cancel-in-progress: false/);
  assert.equal(workflow.match(/run: node \.github\/scripts\/verify-production-android-release\.mjs/g)?.length, 2);
  assert.ok(workflow.lastIndexOf('verify-production-android-release.mjs') < workflow.indexOf('smoke-supabase.mjs'));
  assert.ok(workflow.indexOf('smoke-supabase.mjs') < workflow.indexOf('secrets.ANDROID_UPLOAD_KEYSTORE_BASE64'));
  assert.match(workflow, /retention-days: 7\n          path: mobile\/build\/production-android-artifacts\//);
  assert.doesNotMatch(workflow, /SUPABASE_SERVICE_ROLE_KEY|GOOGLE_PLAY_SERVICE_ACCOUNT|r0adkll|fastlane|supply|upload-google-play/);
  const gradle = read('mobile/android/app/build.gradle.kts');
  assert.match(gradle, /storeType = "PKCS12"/);
  assert.match(gradle, /signingConfig = signingConfigs.findByName\("productionUpload"\)/);
  assert.match(gradle, /release \{[\s\S]*?signingConfig = null/);
  const build = read('.github/scripts/build-production-android.sh');
  assert.match(build, /bundletool_version=1\.18\.3/);
  assert.match(build, /bundletool_sha256=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29/);
  assert.match(build, /--dart-define=FIELD_E2E_PAYMENT_BYPASS=false/);
  assert.match(build, /--dart-define=DEV=false --dart-define=PROFILE_SWITCHER_ENABLED=false/);
  assert.match(build, /--dart-define=PUSH_NOTIFICATIONS_ENABLED=false/);
  assert.doesNotMatch(build, /GOOGLE_AUTH_ENABLED|GOOGLE_PAY_ENABLED|--dart-define=.*(?:SERVICE_ROLE|SECRET_KEY)/);
});

test('mocked signed bundle validates before artifact publication and cleans credentials on failures', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'field-android-build-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const scenario of ['success', 'bad-upload-certificate', 'bad-bundle-signature', 'bad-bundle-signer', 'bad-apk-signer', 'bad-zip-alignment', 'bad-artifact']) {
    const folder = path.join(root, scenario); mkdirSync(folder);
    const workspace = path.join(folder, 'workspace with spaces'), temp = path.join(folder, 'temp'), bin = path.join(folder, 'bin');
    for (const directory of [workspace, temp, bin, path.join(workspace, 'mobile'), path.join(folder, 'sdk/cmdline-tools/latest/bin'), path.join(folder, 'sdk/build-tools/36.0.0')]) mkdirSync(directory, { recursive: true });
    writeFileSync(path.join(workspace, 'mobile/pubspec.yaml'), 'version: 1.0.0+1\n');
    const script = path.join(folder, 'build-production-android.sh');
    writeFileSync(script, read('.github/scripts/build-production-android.sh').replace('bundletool_sha256=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29', `bundletool_sha256=${digest('fixture-tool')}`));
    writeFileSync(path.join(folder, 'validate-production-android.py'), 'import os,sys\nif os.environ["TEST_SCENARIO"] == "bad-artifact": sys.exit(1)\nassert all(os.path.isfile(sys.argv[i]) for i in (1,2,6,8))\nprint("{}")\n');
    const commands = path.join(folder, 'commands.jsonl');
    const mock = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const command=path.basename(process.argv[1]),args=process.argv.slice(2),scenario=process.env.TEST_SCENARIO;
fs.appendFileSync(process.env.TEST_COMMANDS,JSON.stringify({command,operation:args[0]})+'\\n');
const option=name=>args[args.indexOf(name)+1],flag=name=>args.find(a=>a.startsWith(name+'='))?.slice(name.length+1);
const hash=data=>crypto.createHash('sha256').update(data).digest('hex'),cert=Buffer.from('fixture-certificate-not-a-private-key');
if(command==='keytool'){
 if(args[0]==='-exportcert')fs.writeFileSync(option('-file'),scenario==='bad-upload-certificate'?'wrong':cert);
 else if(args[0]==='-printcert')console.log('-----BEGIN CERTIFICATE-----\\n'+Buffer.from(scenario==='bad-bundle-signer'?'wrong':cert).toString('base64')+'\\n-----END CERTIFICATE-----');
 else process.exit(99);
}else if(command==='sha256sum'){
 if(args.includes('--check')){const [expected,file]=fs.readFileSync(0,'utf8').trimEnd().split(/  (.*)/s);if(hash(fs.readFileSync(file))!==expected)process.exit(1);}
 else console.log(hash(fs.readFileSync(args[0]))+'  '+args[0]);
}else if(command==='curl')fs.writeFileSync(option('--output'),'fixture-tool');
else if(command==='flutter'){
 if(args[0]==='build'){const file=path.join(process.cwd(),'build/app/outputs/bundle/productionRelease/app-production-release.aab');fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,'fixture-bundle');}
}else if(command==='jarsigner'){if(scenario==='bad-bundle-signature'){console.error('fixture failure '+process.env.ANDROID_UPLOAD_STORE_PASSWORD+' '+process.env.ANDROID_UPLOAD_KEY_PASSWORD+' ::warning::fixture');process.exit(1);}}
else if(command==='java'){
 if(args[2]==='dump')console.log(args[3]==='manifest'?'<manifest/>':'{}');
 else if(args[2]==='build-apks')cp.execFileSync('python3',['-c','import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("universal.apk",b"fixture-apk"); z.close()',flag('--output')]);
}else if(command==='apksigner')console.log('Signer #1 certificate SHA-256 digest: '+(scenario==='bad-apk-signer'?'0'.repeat(64):hash(cert)));
else if(command==='zipalign'){if(scenario==='bad-zip-alignment')process.exit(1);}
else if(command==='aapt2')console.log('fixture badging');
else if(command!=='sdkmanager')process.exit(99);
`;
    for (const command of ['keytool', 'sha256sum', 'curl', 'flutter', 'jarsigner', 'java']) writeFileSync(path.join(bin, command), mock, { mode: 0o755 });
    for (const command of ['apksigner', 'zipalign', 'aapt2']) writeFileSync(path.join(folder, 'sdk/build-tools/36.0.0', command), mock, { mode: 0o755 });
    writeFileSync(path.join(folder, 'sdk/cmdline-tools/latest/bin/sdkmanager'), mock, { mode: 0o755 });
    const result = spawnSync('/bin/bash', [script], {
      encoding: 'utf8', timeout: 20000,
      env: { ...signingEnv(temp), GITHUB_WORKSPACE: workspace, ANDROID_HOME: path.join(folder, 'sdk'),
        PATH: `${bin}:${process.env.PATH}`, TEST_SCENARIO: scenario, TEST_COMMANDS: commands },
    });
    assert.equal(result.status === 0, scenario === 'success', `${scenario}: ${result.stdout}${result.stderr}`);
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-store-password|fixture-key-password/);
    if (scenario === 'bad-bundle-signature') {
      assert.match(result.stdout, /fixture failure \[REDACTED\] \[REDACTED\]/);
      assert.doesNotMatch(result.stdout, /::warning::/);
    }
    assert.deepEqual(readdirSync(temp), [], `${scenario}: temporary credentials must be deleted`);
    const artifacts = path.join(workspace, 'mobile/build/production-android-artifacts');
    if (scenario === 'success') {
      assert.deepEqual(readdirSync(artifacts).sort(), ['SHA256SUMS', 'fieldrush-1.0.0-201.aab', 'release.json']);
      const record = JSON.parse(readFileSync(path.join(artifacts, 'release.json'), 'utf8'));
      assert.equal(record.deviceQualificationCompleted, false);
      assert.equal(record.googlePlayUploadCompleted, false);
      assert.equal(record.uploadCertificateSha256, digest(fixtureCertificate));
    } else assert.equal(existsSync(artifacts), false, `${scenario}: invalid artifact must not publish`);
    const log = readFileSync(commands, 'utf8').trim().split('\n').map(JSON.parse);
    if (scenario === 'bad-upload-certificate') assert.equal(log.some(item => item.command === 'flutter'), false);
    if (scenario === 'bad-bundle-signature' || scenario === 'bad-bundle-signer') assert.equal(log.some(item => item.command === 'java'), false);
  }
});
