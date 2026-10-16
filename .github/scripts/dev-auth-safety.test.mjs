import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {mkdtemp, mkdir, writeFile, chmod, rm, readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const read=path=>readFileSync(new URL('../../'+path,import.meta.url),'utf8');
const configure=read('.github/scripts/configure-staging-e2e-auth.sh');
const close=read('.github/scripts/close-staging-e2e-auth.sh');
const setup=read('supabase/scripts/e2e/setup_staging.ts');
const cleanup=read('supabase/scripts/e2e/cleanup_staging.ts');
const composite=read('.github/actions/cleanup-staging-e2e/action.yml');
const workflow=read('.github/workflows/ci.yml');

test('staging E2E capability is generated per run and bounded, never the public OTP',()=>{
  assert.match(workflow,/password="\$\(openssl rand -hex 32\)"/);
  assert.match(configure,/E2E_RUN_ID/);
  assert.match(configure,/DEV_AUTH_SECRET=%s/);
  assert.match(configure,/DEV_AUTH_RUN_ID=%s/);
  assert.match(configure,/DEV_AUTH_VALID_UNTIL=%s/);
  assert.match(configure,/Date\.now\(\)\+90\*60\*1000/);
  assert.match(configure,/--env-file "\$secrets_file"/);
  assert.match(configure,/--header "@\$headers_file"/);
  assert.doesNotMatch(configure,/DEV_OTP_USERS_JSON|DEV_SWITCH_ALLOW_UNAUTHENTICATED=true|--header "x-fieldrush-e2e-secret:/);
});

test('only service-verified synthetic fixture ownership permits setup password refresh',()=>{
  assert.match(setup,/user\.app_metadata\?\.fieldrush_e2e !== true/);
  assert.match(setup,/user\.app_metadata\?\.fieldrush_e2e_role !==/);
  assert.match(setup,/isProtectedBootstrapFixture\(target\)/);
  assert.doesNotMatch(setup,/if \(user\.user_metadata\?\.field_e2e !== true\)/);
  const bootstrap=setup.slice(setup.indexOf('async function ensureBootstrapAccount'));
  assert.ok(bootstrap.indexOf('isProtectedBootstrapFixture(target)')<bootstrap.indexOf('password: config.testPassword'));
});

test('final cleanup retires current-run credentials and staff authority, never ordinary users',()=>{
  assert.match(cleanup,/isCurrentRunFixture\(existing, manifest\.runId, Date\.now\(\)\)/);
  assert.match(cleanup,/admin\.auth\.admin\.signOut\(token, "global"\)/);
  assert.match(cleanup,/fieldrush_e2e_run_id: null/);
  assert.match(cleanup,/fieldrush_e2e_revoked_run_id: manifest\.runId/);
  assert.match(cleanup,/is_active: false/);
  assert.match(cleanup,/crypto\.getRandomValues/);
  assert.doesNotMatch(cleanup,/existing\.user_metadata\?\.field_e2e !== true/);
});

test('always-run cleanup closes both windows and removes capability/password secrets',()=>{
  assert.match(close,/GITHUB_RUN_ID.*GITHUB_RUN_ATTEMPT/);
  assert.match(close,/DEV=false/);
  assert.match(close,/DEV_OTP_ENABLED=false/);
  assert.match(close,/DEV_AUTH_VALID_UNTIL=1970/);
  assert.match(close,/secrets unset DEV_AUTH_SECRET DEV_OTP_PASSWORD DEV_SWITCH_PASSWORD/);
  assert.match(composite,/name: Always close the owned staging E2E authentication window\n\s+if: always\(\)/);
  assert.match(composite,/E2E_TEST_PASSWORD=\$password/);
});

test('only test entrypoints carry the ephemeral capability',()=>{
  assert.match(read('referee/e2e/support/staging-session.ts'),/"x-fieldrush-e2e-secret": requiredEnv\("E2E_TEST_PASSWORD"\)/);
  assert.match(read('mobile/integration_test/helpers/fieldrush_fixture_auth_repository.dart'),/'x-fieldrush-e2e-secret': _runCapability/);
  assert.match(read('mobile/integration_test/staging_player_journey_test.dart'),/'x-fieldrush-e2e-secret': const String\.fromEnvironment\(\s*'E2E_TEST_PASSWORD',?\s*\)/);
  assert.doesNotMatch(read('mobile/lib/src/auth/auth_repository.dart'),/x-fieldrush-e2e-secret/);
});

async function shellFixture(t) {
  const directory=await mkdtemp(path.join(os.tmpdir(),'field-dev-auth-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const bin=path.join(directory,'bin');
  await mkdir(bin);
  const supabase=path.join(bin,'supabase');
  await writeFile(supabase,`#!/usr/bin/env node
const fs=require('node:fs');const args=process.argv.slice(2);const at=args.indexOf('--env-file');
fs.appendFileSync(process.env.TEST_CALLS,JSON.stringify({args,payload:at<0?null:fs.readFileSync(args[at+1],'utf8')})+'\\n');
`);
  const curl=path.join(bin,'curl');
  await writeFile(curl,`#!/usr/bin/env node
const fs=require('node:fs');const args=process.argv.slice(2);const output=args[args.indexOf('--output')+1];
const header=args[args.indexOf('--header')+1];if(!header.startsWith('@'))process.exit(2);
fs.writeFileSync(output,JSON.stringify({access_token:'fixture-access',refresh_token:'fixture-refresh'}));process.stdout.write('200');
`);
  await chmod(supabase,0o700);await chmod(curl,0o700);
  const capability=randomBytes(32).toString('hex');
  const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,TEST_CALLS:path.join(directory,'calls.jsonl'),
    E2E_BOOTSTRAP_PHONE:'+97339009098',E2E_DEV_OTP_CODE:'000000',E2E_TEST_PASSWORD:capability,
    E2E_RUN_ID:'1000-1',GITHUB_RUN_ID:'1000',GITHUB_RUN_ATTEMPT:'1',FIELD_ENVIRONMENT:'staging',
    SUPABASE_ACCESS_TOKEN:randomBytes(32).toString('hex'),SUPABASE_PROJECT_REF:'nfdkdhdevpstfspazbfn',
    SUPABASE_PUBLISHABLE_KEY:'fixture-public-key',SUPABASE_URL:'https://nfdkdhdevpstfspazbfn.supabase.co'};
  const run=(script,overrides={})=>spawnSync('bash',[fileURLToPath(new URL('./'+script,import.meta.url))],{env:{...env,...overrides},encoding:'utf8'});
  const calls=async()=>{
    try{return (await readFile(env.TEST_CALLS,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}
    catch(error){if(error.code==='ENOENT')return[];throw error;}
  };
  return {env,capability,run,calls};
}

test('configure shell writes only a protected finite run window, with no private CLI arguments',async t=>{
  const f=await shellFixture(t);
  const result=f.run('configure-staging-e2e-auth.sh');
  assert.equal(result.status,0,result.stderr);
  const calls=await f.calls();assert.equal(calls.length,1);
  assert.deepEqual(calls[0].args.slice(0,2),['secrets','set']);
  assert.equal(calls[0].args.includes(f.capability),false);
  assert.match(calls[0].payload,/DEV_AUTH_RUN_ID=1000-1/);
  const until=calls[0].payload.match(/DEV_AUTH_VALID_UNTIL=(.+)/)[1];
  assert.ok(Date.parse(until)>Date.now());
  assert.ok(Date.parse(until)-Date.now()<=90*60*1000);
  assert.equal((result.stdout+result.stderr).includes(f.capability),false);
});

test('configure rejects production, malformed run IDs and weak capabilities before any CLI call',async t=>{
  const f=await shellFixture(t);
  for(const overrides of [{FIELD_ENVIRONMENT:'production'},{SUPABASE_PROJECT_REF:'zjsjuuhborxrlmdcpvlj'},
    {E2E_RUN_ID:'bad run'},{E2E_TEST_PASSWORD:'short'}]) {
    assert.equal(f.run('configure-staging-e2e-auth.sh',overrides).status,64);
  }
  assert.deepEqual(await f.calls(),[]);
});

test('close shell disables/expires both entrypoints before discarding their run credentials',async t=>{
  const f=await shellFixture(t);
  const result=f.run('close-staging-e2e-auth.sh');assert.equal(result.status,0,result.stderr);
  const calls=await f.calls();assert.equal(calls.length,2);
  assert.match(calls[0].payload,/DEV=false\nDEV_OTP_ENABLED=false/);
  assert.match(calls[0].payload,/DEV_AUTH_VALID_UNTIL=1970/);
  assert.deepEqual(calls[1].args.slice(0,5),['secrets','unset','DEV_AUTH_SECRET','DEV_OTP_PASSWORD','DEV_SWITCH_PASSWORD']);
  assert.equal((result.stdout+result.stderr).includes(f.capability),false);
});

test('close shell refuses a different workflow run or production without making a CLI call',async t=>{
  const f=await shellFixture(t);
  assert.equal(f.run('close-staging-e2e-auth.sh',{E2E_RUN_ID:'other-run'}).status,64);
  assert.equal(f.run('close-staging-e2e-auth.sh',{FIELD_ENVIRONMENT:'production'}).status,64);
  assert.deepEqual(await f.calls(),[]);
});
