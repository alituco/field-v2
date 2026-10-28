import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
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
  assert.match(close,/retired_secret_names=\(DEV_AUTH_SECRET DEV_OTP_PASSWORD DEV_SWITCH_PASSWORD\)/);
  assert.match(close,/secrets unset "\$\{present_secrets\[@\]\}"/);
  assert.match(close,/secrets list.*--output json/);
  assert.doesNotMatch(close,/secrets unset[^\n]+\|\|\s*true/);
  assert.match(composite,/name: Always close the owned staging E2E authentication window\n\s+if: always\(\)/);
  assert.match(composite,/E2E_TEST_PASSWORD=\$password/);
});

test('only test entrypoints carry the ephemeral capability',()=>{
  assert.match(read('referee/e2e/support/staging-session.ts'),/"x-fieldrush-e2e-secret": requiredEnv\("E2E_TEST_PASSWORD"\)/);
  assert.match(read('mobile/integration_test/helpers/fieldrush_fixture_auth_repository.dart'),/'x-fieldrush-e2e-secret': _runCapability/);
  assert.match(read('mobile/integration_test/staging_player_journey_test.dart'),/'x-fieldrush-e2e-secret': const String\.fromEnvironment\(\s*'E2E_TEST_PASSWORD',?\s*\)/);
  assert.doesNotMatch(read('mobile/lib/src/auth/auth_repository.dart'),/x-fieldrush-e2e-secret/);
});

const retiredSecrets=['DEV_AUTH_SECRET','DEV_OTP_PASSWORD','DEV_SWITCH_PASSWORD'];
const closedControls=['DEV','DEV_OTP_ENABLED','DEV_SWITCH_ALLOW_UNAUTHENTICATED',
  'DEV_AUTH_VALID_UNTIL','DEV_OTP_VALID_UNTIL','DEV_SWITCH_VALID_UNTIL'];

async function shellFixture(t,options={}) {
  const directory=await mkdtemp(path.join(os.tmpdir(),'field-dev-auth-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const bin=path.join(directory,'bin');
  await mkdir(bin);
  const temporary=path.join(directory,'temporary');await mkdir(temporary);
  const statePath=path.join(directory,'state.json');
  await writeFile(statePath,JSON.stringify({
    secrets:Object.fromEntries([...retiredSecrets,'UNRELATED_SECRET'].map(name=>[name,'fixture-private-digest'])),
    listCalls:0,...options,
  }));
  const supabase=path.join(bin,'supabase');
  await writeFile(supabase,`#!/usr/bin/env node
const fs=require('node:fs');const args=process.argv.slice(2);const at=args.indexOf('--env-file');
fs.appendFileSync(process.env.TEST_CALLS,JSON.stringify({args,payload:at<0?null:fs.readFileSync(args[at+1],'utf8')})+'\\n');
const state=JSON.parse(fs.readFileSync(process.env.TEST_STATE,'utf8'));
const save=()=>fs.writeFileSync(process.env.TEST_STATE,JSON.stringify(state));
const fail=stage=>{if(state.failure===stage){process.stderr.write('Fixture remote failure');process.exit(42);}};
const retired=['DEV_AUTH_SECRET','DEV_OTP_PASSWORD','DEV_SWITCH_PASSWORD'];
const ref='nfdkdhdevpstfspazbfn';
if(args[0]!=='secrets')process.exit(90);
if(args[1]==='set'){
  if(JSON.stringify(args)!==JSON.stringify(['secrets','set','--project-ref',ref,'--env-file',args[at+1]]))process.exit(90);
  fail('set');
  if(!state.ignoreSet)for(const line of fs.readFileSync(args[at+1],'utf8').trim().split('\\n')){
    const boundary=line.indexOf('=');state.secrets[line.slice(0,boundary)]='fixture-digest:'+line.slice(boundary+1);
  }
  save();
}else if(args[1]==='list'){
  if(JSON.stringify(args)!==JSON.stringify(['secrets','list','--project-ref',ref,'--output','json']))process.exit(90);
  state.listCalls++;save();fail('list:'+state.listCalls);
  if(state.inventoryOverride!==undefined&&state.listCalls===(state.overrideOnList??1)){
    process.stdout.write(state.inventoryOverride);
  }else process.stdout.write(JSON.stringify(Object.entries(state.secrets).map(([name,value])=>({name,value}))));
}else if(args[1]==='unset'){
  const boundary=args.indexOf('--project-ref');const names=args.slice(2,boundary);
  if(JSON.stringify(args)!==JSON.stringify(['secrets','unset',...names,'--project-ref',ref,'--yes']))process.exit(90);
  if(!names.length||names.some(name=>!retired.includes(name)||!(name in state.secrets))){
    process.stderr.write('Secret not found with given name');process.exit(41);
  }
  fail('unset');
  if(!state.ignoreUnset)for(const name of names)delete state.secrets[name];
  save();
}else process.exit(90);
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
    TEST_STATE:statePath,TMPDIR:temporary,
    E2E_BOOTSTRAP_PHONE:'+97339009098',E2E_DEV_OTP_CODE:'000000',E2E_TEST_PASSWORD:capability,
    E2E_RUN_ID:'1000-1',GITHUB_RUN_ID:'1000',GITHUB_RUN_ATTEMPT:'1',FIELD_ENVIRONMENT:'staging',
    SUPABASE_ACCESS_TOKEN:randomBytes(32).toString('hex'),SUPABASE_PROJECT_REF:'nfdkdhdevpstfspazbfn',
    SUPABASE_PUBLISHABLE_KEY:'fixture-public-key',SUPABASE_URL:'https://nfdkdhdevpstfspazbfn.supabase.co'};
  const run=(script,overrides={})=>{
    const result=spawnSync('bash',[fileURLToPath(new URL('./'+script,import.meta.url))],{env:{...env,...overrides},encoding:'utf8',timeout:10_000});
    assert.ifError(result.error);
    assert.equal((result.stdout+result.stderr).includes(capability),false);
    assert.equal((result.stdout+result.stderr).includes('fixture-private-digest'),false);
    assert.deepEqual(readdirSync(temporary),[],'Temporary secret files must be removed on every exit');
    return result;
  };
  const calls=async()=>{
    try{return (await readFile(env.TEST_CALLS,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}
    catch(error){if(error.code==='ENOENT')return[];throw error;}
  };
  return {env,capability,run,calls,temporary,state:async()=>JSON.parse(await readFile(statePath,'utf8'))};
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
  const calls=await f.calls();assert.equal(calls.length,4);
  assert.match(calls[0].payload,/DEV=false\nDEV_OTP_ENABLED=false/);
  assert.match(calls[0].payload,/DEV_AUTH_VALID_UNTIL=1970/);
  assert.deepEqual(calls[1].args,['secrets','list','--project-ref','nfdkdhdevpstfspazbfn','--output','json']);
  assert.deepEqual(calls[2].args.slice(0,5),['secrets','unset','DEV_AUTH_SECRET','DEV_OTP_PASSWORD','DEV_SWITCH_PASSWORD']);
  assert.equal(calls[3].args[1],'list');
  assert.equal((result.stdout+result.stderr).includes(f.capability),false);
});

test('close shell refuses a different workflow run or production without making a CLI call',async t=>{
  const f=await shellFixture(t);
  for(const overrides of [{E2E_RUN_ID:'other-run'},{FIELD_ENVIRONMENT:'production'},
    {SUPABASE_PROJECT_REF:'zjsjuuhborxrlmdcpvlj'},{SUPABASE_URL:'https://nfdkdhdevpstfspazbfn.supabase.co.evil.test'},
    {SUPABASE_ACCESS_TOKEN:''},{GITHUB_RUN_ATTEMPT:'2'}]){
    assert.equal(f.run('close-staging-e2e-auth.sh',overrides).status,64);
  }
  assert.deepEqual(await f.calls(),[]);
});

for(let mask=0;mask<8;mask++){
  test(`close shell is idempotent with retired-secret presence mask ${mask}`,async t=>{
    const present=retiredSecrets.filter((_,index)=>mask&(1<<index));
    const f=await shellFixture(t,{secrets:Object.fromEntries(
      [...present,'STRIPE_SECRET_KEY','FIREBASE_SERVICE_ACCOUNT_JSON','UNRELATED_SECRET']
        .map(name=>[name,'fixture-private-digest']))});
    const first=f.run('close-staging-e2e-auth.sh');
    assert.equal(first.status,0,first.stderr);
    const firstCalls=await f.calls();
    const unsets=firstCalls.filter(call=>call.args[1]==='unset');
    assert.equal(unsets.length,present.length?1:0);
    if(present.length)assert.deepEqual(unsets[0].args.slice(2,-3),present);
    assert.equal(firstCalls[0].args[1],'set');
    assert.equal(firstCalls[1].args[1],'list');
    const second=f.run('close-staging-e2e-auth.sh');
    assert.equal(second.status,0,second.stderr);
    assert.equal((await f.calls()).slice(firstCalls.length).some(call=>call.args[1]==='unset'),false);
    const state=await f.state();
    assert.deepEqual(Object.keys(state.secrets).sort(),
      [...closedControls,'STRIPE_SECRET_KEY','FIREBASE_SERVICE_ACCOUNT_JSON','UNRELATED_SECRET'].sort());
    for(const name of ['STRIPE_SECRET_KEY','FIREBASE_SERVICE_ACCOUNT_JSON','UNRELATED_SECRET']){
      assert.equal(state.secrets[name],'fixture-private-digest');
    }
    for(const name of closedControls){
      assert.equal(state.secrets[name],`fixture-digest:${name.endsWith('VALID_UNTIL')?'1970-01-01T00:00:00.000Z':'false'}`);
    }
  });
}

for(const failure of ['set','list:1','unset','list:2']){
  test(`close shell preserves ${failure} failure instead of announcing success`,async t=>{
    const f=await shellFixture(t,{failure});
    const result=f.run('close-staging-e2e-auth.sh');
    assert.equal(result.status,42,result.stderr);
    assert.doesNotMatch(result.stdout,/authentication window is closed/);
    const calls=await f.calls();
    assert.equal(calls.length,{'set':1,'list:1':2,'unset':3,'list:2':4}[failure]);
  });
}

const invalidInventories=[
  '{}','null','<html>Private provider failure</html>','[]\n[]',
  JSON.stringify({success:true,data:[]}),
  JSON.stringify([{name:'DEV_AUTH_SECRET'}]),
  JSON.stringify([{name:'',value:'fixture-private-digest'}]),
  JSON.stringify([{name:'DEV_AUTH_SECRET',value:'fixture-private-digest'},
    {name:'DEV_AUTH_SECRET',value:'fixture-private-digest'}]),
];
for(const overrideOnList of [1,2]){
  for(const [index,inventoryOverride] of invalidInventories.entries()){
    test(`close shell rejects malformed inventory ${index} on read ${overrideOnList}`,async t=>{
      const f=await shellFixture(t,{inventoryOverride,overrideOnList});
      const result=f.run('close-staging-e2e-auth.sh');
      assert.equal(result.status,1,result.stderr);
      assert.match(result.stderr,/Invalid staging secret inventory/);
      assert.doesNotMatch(result.stdout,/authentication window is closed/);
      assert.equal((result.stdout+result.stderr).includes('Private provider failure'),false);
      assert.equal((await f.calls()).length,overrideOnList===1?2:4);
    });
  }
}

test('close shell rejects an acknowledged deletion that leaves credentials behind',async t=>{
  const f=await shellFixture(t,{ignoreUnset:true});
  const result=f.run('close-staging-e2e-auth.sh');
  assert.equal(result.status,1,result.stderr);
  assert.match(result.stderr,/credentials remain after cleanup/);
  assert.doesNotMatch(result.stdout,/authentication window is closed/);
});

test('close shell rejects an acknowledged close whose controls are absent from readback',async t=>{
  const f=await shellFixture(t,{ignoreSet:true});
  const result=f.run('close-staging-e2e-auth.sh');
  assert.equal(result.status,1,result.stderr);
  assert.match(result.stderr,/authentication control is missing/);
  assert.doesNotMatch(result.stdout,/authentication window is closed/);
});
