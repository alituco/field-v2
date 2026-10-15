// Full repository migration replay in isolated PostgreSQL/PGlite, through 020.
// No public application table/function is stubbed. Managed Supabase auth/storage
// surface and unavailable pg_cron/pg_net/Vault extensions are explicit local
// contracts below. Cron records jobs without executing them; HTTP always throws.
// This verifies application DDL/function cloning/view dependencies, NOT the
// managed extensions, network delivery, live production data, or concurrency.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_migration_chain.mjs
import {readFile,readdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url);
const modulePath=process.env.PGLITE_MODULE||'@electric-sql/pglite';
const {PGlite}=require(modulePath);
const db=new PGlite();
const migrationDirectory=new URL('../migrations/',import.meta.url);
const through=process.env.THROUGH_MIGRATION||'20261014002000';
const runSqlVerifiers=process.env.RUN_SQL_VERIFIERS==='1';
const managedExtensionSubstitutions=[];
let applied=0;
let current='managed Supabase contract bootstrap';
let currentSql='';
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create role authenticator; create role supabase_admin; create role supabase_auth_admin;
    create schema auth; create schema storage; create schema extensions; create schema cron; create schema net; create schema vault;
    create table auth.users(id uuid primary key,instance_id uuid,aud text,role text,phone text,email text,encrypted_password text,
      confirmation_token text,recovery_token text,email_change_token_new text,email_change text,raw_user_meta_data jsonb default '{}',
      raw_app_meta_data jsonb default '{}',phone_confirmed_at timestamptz,email_confirmed_at timestamptz,
      deleted_at timestamptz,banned_until timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
    create table auth.identities(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users,
      provider text,provider_id text,identity_data jsonb default '{}');
    create function auth.uid() returns uuid language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
        nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
    create function auth.role() returns text language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
        nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role') $$;
    create function auth.jwt() returns jsonb language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}') $$;
    create table storage.buckets(id text primary key,name text,public boolean default false,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets,
      name text,owner uuid,owner_id text,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now());
    alter table storage.objects enable row level security;
    create function storage.foldername(name text) returns text[] language sql immutable as $$
      select (string_to_array(name,'/'))[1:greatest(cardinality(string_to_array(name,'/'))-1,0)] $$;
    create table cron.job(jobid bigint generated always as identity primary key,jobname text unique,schedule text,command text,active boolean default true);
    create function cron.schedule(job_name text,schedule text,command text) returns bigint language plpgsql as $$
      declare result bigint; begin insert into cron.job(jobname,schedule,command) values(job_name,schedule,command)
      on conflict(jobname) do update set schedule=excluded.schedule,command=excluded.command
      returning jobid into result; return result; end $$;
    create function cron.unschedule(id bigint) returns boolean language plpgsql as $$
      begin delete from cron.job where jobid=id; return found; end $$;
    create table vault.secrets(id uuid primary key default gen_random_uuid(),name text unique,secret text,description text);
    create view vault.decrypted_secrets as select id,name,secret as decrypted_secret,description from vault.secrets;
    create function vault.create_secret(secret_to_use text,name_to_use text,description_to_use text) returns uuid language plpgsql as $$
      declare result uuid; begin insert into vault.secrets(secret,name,description) values(secret_to_use,name_to_use,description_to_use)
      returning id into result; return result; end $$;
    create function vault.update_secret(id_to_use uuid,secret_to_use text) returns void language sql as $$
      update vault.secrets set secret=secret_to_use where id=id_to_use $$;
    create function net.http_post(url text,body jsonb default '{}',params jsonb default '{}',headers jsonb default '{}',timeout_milliseconds integer default 1000)
      returns bigint language plpgsql as $$ begin raise exception 'HTTP is deliberately unavailable in the isolated migration test'; end $$;
    alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
    alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    set check_function_bodies=on;
    -- Supabase PostgreSQL defaults to UTC, unlike PGlite's host-local default.
    set timezone='UTC';
  `);
  const files=(await readdir(migrationDirectory)).filter(file=>/^\d{14}_.*\.sql$/.test(file)&&file.slice(0,14)<=through).sort();
  for(const file of files) {
    current=file;
    currentSql=await readFile(new URL(file,migrationDirectory),'utf8');
    currentSql=currentSql.replace(/create\s+extension\s+if\s+not\s+exists\s+(pg_cron|pg_net|supabase_vault)(?:\s+with\s+schema\s+\w+)?\s*;/gi,(statement,name)=>{
      managedExtensionSubstitutions.push({file,extension:name});
      return `-- ISOLATED TEST: ${name} is the explicit managed-service contract, not an installed extension.`;
    });
    await db.exec('begin');
    try { await db.exec(currentSql); await db.exec('commit'); }
    catch(error) { await db.exec('rollback'); throw error; }
    applied++;
    if(file.slice(0,14)>='20261014001000') console.log(`Applied ${file}`);
  }
  const scalar=async sql=>Object.values((await db.query(sql)).rows[0])[0];
  assert.equal(await scalar('select enabled from fieldrush_rating_private.season_zero_activation'),false);
  assert.equal(await scalar('select count(*)::integer from fieldrush_rating_private.season_zero_matches'),0);
  assert.equal(await scalar("select to_regprocedure('public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text)') is not null"),true);
  assert.equal(await scalar("select has_function_privilege('authenticated','fieldrush_rating_private.calculate_season_zero_sr(jsonb)','EXECUTE')"),false);
  console.log(`PASS: ${applied} application migrations applied in sequence through ${through}; Season 0 remains OFF; private calculator permissions and wrapper existence checked.`);
  console.log(`EXPLICIT LIMITATIONS: managed auth/storage are schema contracts, not services; ${managedExtensionSubstitutions.length} pg_cron/pg_net/Vault CREATE EXTENSION statements replaced by local contracts; cron callbacks, HTTP, realtime publication delivery, existing production data and multi-connection locking are NOT tested.`);
  if(process.env.REPLAY_SQL_FILE) {
    current=process.env.REPLAY_SQL_FILE;
    currentSql=await readFile(current,'utf8');
    await db.exec('begin');
    try {
      if(process.env.BENCHMARK_MATCHES) {
        assert.match(process.env.BENCHMARK_MATCHES,/^[1-9][0-9]{0,2}$/);
        await db.query("select set_config('fieldrush.test_benchmark_matches',$1,true)",[process.env.BENCHMARK_MATCHES]);
      }
      const results=await db.exec(currentSql);
      console.log(`REAL-SCHEMA SMOKE PASS ${current}`);
      const lastRows=results.findLast(result=>result.rows?.length)?.rows;
      if(lastRows) console.log(JSON.stringify(lastRows));
    }
    finally { await db.exec('rollback'); }
  }
  if(process.env.AUDIT_RATING_RPCS==='1') {
    const result=await db.query(`select n.nspname,p.proname,p.oid::regprocedure::text signature,
      has_function_privilege('anon',p.oid,'EXECUTE') as anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated,
      has_function_privilege('service_role',p.oid,'EXECUTE') as service_role,
      p.prosecdef as security_definer,
      substring(p.prosrc from '(skill_rating|rating_change|player_ratings|fieldrush_player_rating_tracks|player_rating_events|rating_at_match_start|before_sr_privacy|before_season_zero)') as matched
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname in ('public','fieldrush_rating_private') and p.prokind='f'
      and p.prosrc ~* '(skill_rating|rating_change|player_ratings|fieldrush_player_rating_tracks|player_rating_events|rating_at_match_start|before_sr_privacy|before_season_zero)'
      and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'))
      order by n.nspname,p.proname`);
    console.log('RATING RPC ACL AUDIT '+JSON.stringify(result.rows));
    const privateLeaks=await db.query(`select p.oid::regprocedure::text signature from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace where n.nspname='fieldrush_rating_private'
      and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'))
      order by signature`);
    console.log('PRIVATE FUNCTION ACL AUDIT '+JSON.stringify(privateLeaks.rows));
    const viewLeaks=await db.query(`select c.oid::regclass::text relation,c.relkind,
      has_table_privilege('anon',c.oid,'SELECT') as anon,has_table_privilege('authenticated',c.oid,'SELECT') as authenticated
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='fieldrush_rating_private' and c.relkind in ('r','v','m')
      and (has_table_privilege('anon',c.oid,'SELECT') or has_table_privilege('authenticated',c.oid,'SELECT'))
      order by relation`);
    console.log('PRIVATE RELATION ACL AUDIT '+JSON.stringify(viewLeaks.rows));
  }
  if(runSqlVerifiers) {
    const ci=await readFile(new URL('../../.github/workflows/ci.yml',import.meta.url),'utf8');
    const verifiers=[...new Set(ci.match(/supabase\/scripts\/verify_[a-z_]+\.sql/g))];
    let passed=0;
    for(const verifier of verifiers) {
      // PGlite always rejects on SQL errors. Remove only psql's equivalent
      // ON_ERROR_STOP directive; unknown metacommands remain hard failures.
      const sql=(await readFile(new URL('../../'+verifier,import.meta.url),'utf8'))
        .replace(/^\\set ON_ERROR_STOP on\s*$/gm,'-- ON_ERROR_STOP is intrinsic to db.exec.');
      await db.exec('begin');
      try {
        await db.exec(sql);
        console.log(`VERIFIER PASS ${verifier}`);
        passed++;
      } catch(error) {
        console.error(`VERIFIER FAIL ${verifier}: ${error.message} [${error.code}]`);
        if(error.detail) console.error(error.detail);
        if(error.where) console.error(error.where);
        process.exitCode=1;
      } finally { await db.exec('rollback'); }
    }
    console.log(`CI SQL VERIFIERS: ${passed}/${verifiers.length} passed against full application schema in rollback-only local execution. Seed-dependent checks require their usual CI seed; managed services remain local contracts.`);
  }
} catch(error) {
  console.error(`FAIL after ${applied} application migrations at ${current}: ${error.message}`);
  if(error.code) console.error(`SQLSTATE ${error.code}`);
  if(error.detail) console.error(error.detail);
  if(error.hint) console.error(error.hint);
  if(error.where) console.error(error.where);
  if(error.position) {
    const at=Number(error.position)-1;
    console.error(currentSql.slice(Math.max(0,at-200),at+400));
  }
  process.exitCode=1;
} finally { await db.close(); }
