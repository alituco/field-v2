import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
let checks=0;
const equal=(actual,expected)=>{assert.deepEqual(actual,expected);checks++;};
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
const rejects=async(sql,args,code)=>{await assert.rejects(db.query(sql,args),error=>error.code===code);checks++;};
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private; create schema vault; create schema net; create schema cron;
    create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claim.role',true),'') $$;
    create table fieldrush_private.push_configuration(singleton boolean primary key default true,enabled boolean not null default false,firebase_project_id text);
    insert into fieldrush_private.push_configuration(singleton,enabled) values(true,false);
    create table vault.secrets(id uuid primary key default gen_random_uuid(),name text unique,secret text,description text);
    create view vault.decrypted_secrets as select id,name,secret as decrypted_secret from vault.secrets;
    create function vault.create_secret(secret_to_use text,name_to_use text,description_to_use text) returns uuid language plpgsql as $$
      declare result uuid; begin insert into vault.secrets(secret,name,description) values(secret_to_use,name_to_use,description_to_use)
      returning id into result; return result; end $$;
    create function vault.update_secret(id_to_use uuid,secret_to_use text) returns void language sql as $$ update vault.secrets set secret=secret_to_use where id=id_to_use $$;
    create table cron.job(jobid bigint generated always as identity primary key,jobname text unique,schedule text,command text);
    create function cron.schedule(job_name text,schedule text,command text) returns bigint language plpgsql as $$
      declare result bigint; begin insert into cron.job(jobname,schedule,command) values(job_name,schedule,command)
      returning jobid into result; return result; end $$;
    create table net.requests(id bigint generated always as identity,url text,body jsonb,headers jsonb,timeout_ms integer);
    create function net.http_post(url text,body jsonb default '{}',params jsonb default '{}',headers jsonb default '{}',timeout_milliseconds integer default 1000)
      returns bigint language plpgsql as $$ declare result bigint; begin
      insert into net.requests(url,body,headers,timeout_ms) values(url,body,headers,timeout_milliseconds)
      returning id into result; return result; end $$;
  `);
  await db.exec(await readFile(new URL('../migrations/20261015000500_schedule_push_dispatch.sql',import.meta.url),'utf8'));
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),false);
  equal(await scalar('select fieldrush_private.dispatch_pending_push()'),null);
  equal(await scalar('select count(*)::integer from net.requests'),0);
  equal(await scalar("select schedule from cron.job where jobname='fieldrush-push-dispatch'"),'* * * * *');
  equal(await scalar("select command from cron.job where jobname='fieldrush-push-dispatch'"),'select fieldrush_private.dispatch_pending_push();');
  for(const role of ['anon','authenticated']) {
    equal(await scalar(`select has_function_privilege($1,'public.configure_push_dispatch(text,text,boolean)','EXECUTE')`,[role]),false);
    equal(await scalar(`select has_function_privilege($1,'fieldrush_private.dispatch_pending_push()','EXECUTE')`,[role]),false);
    equal(await scalar(`select has_table_privilege($1,'fieldrush_private.push_dispatch_configuration','SELECT')`,[role]),false);
  }
  equal(await scalar("select has_table_privilege('service_role','fieldrush_private.push_dispatch_configuration','SELECT')"),false);
  equal(await scalar("select has_function_privilege('service_role','public.configure_push_dispatch(text,text,boolean)','EXECUTE')"),true);
  await db.query("select set_config('request.jwt.claim.role','authenticated',false)");
  await rejects('select public.configure_push_dispatch(null,null,false)',[],'42501');
  await db.query("select set_config('request.jwt.claim.role','service_role',false)");
  const endpoint='https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch';
  const secret=randomUUID().replaceAll('-','')+randomUUID().replaceAll('-','');
  await rejects('select public.configure_push_dispatch($1,$2,true)',[endpoint,secret],'22023');
  equal(await scalar('select count(*)::integer from vault.secrets'),0);
  await db.exec('update fieldrush_private.push_configuration set enabled=true');
  for(const wrong of [endpoint+'/',endpoint.replace('nfdkdhdevpstfspazbfn','zjsjuuhborxrlmdcpvlj'),'https://example.com/worker']) {
    await rejects('select public.configure_push_dispatch($1,$2,true)',[wrong,secret],'22023');
  }
  for(const invalid of [null,'short','a'.repeat(31),'a'.repeat(513),'a'.repeat(32)+'\n']) {
    await rejects('select public.configure_push_dispatch($1,$2,true)',[endpoint,invalid],'22023');
  }
  await db.query('select public.configure_push_dispatch($1,$2,true)',[endpoint,secret]);
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),true);
  equal(await scalar("select decrypted_secret from vault.decrypted_secrets where name='fieldrush_push_worker_secret'"),secret);
  const id=await scalar("select id from vault.secrets where name='fieldrush_push_worker_secret'");
  await db.query('select fieldrush_private.dispatch_pending_push()');
  const sent=(await db.query('select url,body,headers,timeout_ms from net.requests')).rows[0];
  equal(sent,{url:endpoint,body:{},headers:{'Content-Type':'application/json',Authorization:`Bearer ${secret}`},timeout_ms:90000});
  await db.exec('update fieldrush_private.push_configuration set enabled=false');
  equal(await scalar('select fieldrush_private.dispatch_pending_push()'),null);
  equal(await scalar('select count(*)::integer from net.requests'),1);
  await db.query('select public.configure_push_dispatch(null,null,false)');
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),false);
  await db.exec('update fieldrush_private.push_configuration set enabled=true');
  const rotated=randomUUID().replaceAll('-','')+randomUUID().replaceAll('-','');
  await db.query('select public.configure_push_dispatch($1,$2,true)',[endpoint,rotated]);
  equal(await scalar("select id from vault.secrets where name='fieldrush_push_worker_secret'"),id);
  equal(await scalar('select count(*)::integer from vault.secrets'),1);
  equal(await scalar("select decrypted_secret from vault.decrypted_secrets where name='fieldrush_push_worker_secret'"),rotated);
  await db.exec('delete from vault.secrets');
  equal(await scalar('select fieldrush_private.dispatch_pending_push()'),null);
  equal(await scalar('select count(*)::integer from net.requests'),1);
  // Replay the additive production rollout over an active staging setup. It
  // preserves all existing switches and the one existing inert cron schedule.
  await db.exec(await readFile(new URL('../migrations/20261027000800_production_push_dispatch.sql',import.meta.url),'utf8'));
  equal(await scalar('select environment from fieldrush_private.push_dispatch_configuration'),'staging');
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),true);
  equal(await scalar('select endpoint_url from fieldrush_private.push_dispatch_configuration'),endpoint);
  equal(await scalar('select count(*)::integer from cron.job'),1);
  equal(await scalar('select count(*)::integer from net.requests'),1);
  for(const role of ['anon','authenticated']) {
    equal(await scalar("select has_function_privilege($1,'public.configure_push_dispatch_environment(text)','EXECUTE')",[role]),false);
    equal(await scalar("select has_function_privilege($1,'public.configure_push_delivery(text,boolean)','EXECUTE')",[role]),false);
  }
  equal(await scalar("select has_function_privilege('service_role','public.configure_push_dispatch_environment(text)','EXECUTE')"),true);
  await db.query("select set_config('request.jwt.claim.role','authenticated',false)");
  await rejects("select public.configure_push_dispatch_environment('production')",[],'42501');
  await rejects("select public.configure_push_delivery('production-fixture',false)",[],'42501');
  await db.query("select set_config('request.jwt.claim.role','service_role',false)");
  await db.query("select public.configure_push_dispatch_environment('staging')");
  await rejects("select public.configure_push_dispatch_environment('production')",[],'55000');
  await db.query('select public.configure_push_dispatch(null,null,false)');
  await rejects("select public.configure_push_dispatch_environment('production')",[],'55000');
  await db.query("select public.configure_push_delivery('staging-fixture',false)");
  for(const invalid of [null,'local','prod','PRODUCTION','production ']) {
    await rejects('select public.configure_push_dispatch_environment($1)',[invalid],'22023');
  }
  await db.query("select public.configure_push_dispatch_environment('production')");
  equal(await scalar('select environment from fieldrush_private.push_dispatch_configuration'),'production');
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),false);
  equal(await scalar('select endpoint_url from fieldrush_private.push_dispatch_configuration'),null);
  equal(await scalar('select firebase_project_id from fieldrush_private.push_configuration'),null);
  equal(await scalar('select fieldrush_private.dispatch_pending_push()'),null);
  equal(await scalar('select count(*)::integer from vault.secrets'),0);
  const productionEndpoint='https://zjsjuuhborxrlmdcpvlj.supabase.co/functions/v1/fieldrush-push-dispatch';
  await rejects('select public.configure_push_dispatch($1,$2,true)',[productionEndpoint,secret],'22023');
  await rejects("select public.configure_push_delivery('production-fixture',null)",[],'22023');
  await rejects("select public.configure_push_delivery('',true)",[],'22023');
  await db.query("select public.configure_push_delivery('production-fixture',true)");
  for(const wrong of [endpoint,productionEndpoint+'/',productionEndpoint+'?test=true','https://example.com/worker']) {
    await rejects('select public.configure_push_dispatch($1,$2,true)',[wrong,secret],'22023');
    await rejects('update fieldrush_private.push_dispatch_configuration set endpoint_url=$1',[wrong],'23514');
  }
  await db.query('select public.configure_push_dispatch($1,$2,true)',[productionEndpoint,secret]);
  equal(await scalar('select enabled from fieldrush_private.push_dispatch_configuration'),true);
  await db.query('select fieldrush_private.dispatch_pending_push()');
  equal((await db.query('select url,body,headers from net.requests order by id desc limit 1')).rows[0],{
    url:productionEndpoint,body:{},headers:{'Content-Type':'application/json',Authorization:`Bearer ${secret}`}
  });
  await rejects("select public.configure_push_dispatch_environment('staging')",[],'55000');
  // A rollback of delivery is possible without retaining provider credentials.
  await db.exec('delete from vault.secrets');
  await db.query('select public.configure_push_dispatch(null,null,false)');
  equal(await scalar('select fieldrush_private.dispatch_pending_push()'),null);
  equal(await scalar('select count(*)::integer from net.requests'),2);
  console.log(`PASS ${checks} protected dispatcher checks; Vault/cron/net are local contracts, no network requests made.`);
} finally {await db.close();}
