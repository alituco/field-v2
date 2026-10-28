// Isolated PostgreSQL contracts; never connects to Supabase or Firebase.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
const read=(name)=>readFile(new URL(`../${name}`,import.meta.url),'utf8');
const a='10000000-0000-4000-8000-000000000001',b='10000000-0000-4000-8000-000000000002';
const installation='20000000-0000-4000-8000-000000000001';
const emptyInstallation='20000000-0000-4000-8000-000000000002';
const game='30000000-0000-4000-8000-000000000001',party='40000000-0000-4000-8000-000000000001';
const membership='50000000-0000-4000-8000-000000000001',claim='60000000-0000-4000-8000-000000000001';
function extract(source,name){
  const start=source.search(new RegExp(`create(?: or replace)? function ${name.replaceAll('.','\\.')}\\(`));
  assert.ok(start>=0,name);
  return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3);
}
await db.exec(`
create role anon;create role authenticated;create role service_role;
create schema auth;create schema fieldrush_private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
grant usage on schema auth to authenticated,service_role;
create table auth.users(id uuid primary key,email text,phone text,email_confirmed_at timestamptz,phone_confirmed_at timestamptz,deleted_at timestamptz,banned_until timestamptz,raw_user_meta_data jsonb default '{}');
create table public.profiles(id uuid primary key references auth.users,display_name text,username text,bio text,avatar_url text,date_of_birth date);
insert into auth.users(id,phone,phone_confirmed_at) values('${a}','15555550001',now()),('${b}','15555550002',now());
insert into public.profiles(id,display_name,username) values('${a}','Player A','player_a'),('${b}','Player B','player_b');
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now();return new;end$$;
create function public.is_fieldrush_account_active(caller uuid) returns boolean language sql stable security definer as $$select exists(select 1 from auth.users where id=caller and deleted_at is null)$$;
create table public.open_queue_games(id uuid primary key,venue text,starts_at timestamptz,status text);
create table public.open_queue_parties(id uuid primary key,status text);
create table public.open_queue_party_members(id uuid primary key,profile_id uuid,invited_by uuid,party_id uuid,game_id uuid,status text);
insert into public.open_queue_games values('${game}','Fixture venue',now()+interval '2 hours','OPEN');
insert into public.open_queue_parties values('${party}','ACTIVE');
insert into public.open_queue_party_members values('${membership}','${a}','${b}','${party}','${game}','INVITED');
`);
const account=await read('migrations/20261009000000_create_fieldrush_accounts.sql');
await db.exec(extract(account,'fieldrush_private.require_user'));
await db.exec(await read('migrations/20261002000000_create_private_profile_settings.sql'));
const invitations=await read('migrations/20260715000008_allow_open_queue_party_switches.sql');
await db.exec(invitations.slice(invitations.indexOf('create table public.notifications'),invitations.indexOf('-- Foreground clients')));
await db.exec(extract(invitations,'public.create_open_queue_party_invite_notification'));
await db.exec(await read('migrations/20261012000200_home_activity_dismissals.sql'));
await db.exec(await read('migrations/20261015000100_notification_preferences.sql'));
await db.exec(await read('migrations/20261015000200_push_delivery_foundation.sql'));

let checks=0;
async function scalar(sql,expected){const {rows}=await db.query(sql);assert.deepEqual(Object.values(rows[0])[0],expected,sql);checks++;}
async function rejects(sql,pattern){await assert.rejects(db.exec(sql),pattern);checks++;}
async function user(id){await db.exec(`reset role;set request.jwt.claim.sub='${id}';set request.jwt.claim.role='authenticated';set role authenticated;`);}
async function worker(){await db.exec(`reset role;set request.jwt.claim.role='service_role';set role service_role;`);}
async function owner(){await db.exec('reset role;');}
const prefs={game_reminders:true,clan_callups:true,party_invites:true,ladder_moves:true,replays_ready:false,news_and_offers:false};
async function save(patch={}){await db.exec(`select public.update_my_notification_preferences('${JSON.stringify({...prefs,...patch})}'::jsonb)`);}
async function notice(type='OPEN_QUEUE_PARTY_INVITE',recipient=a){
  await owner();
  const {rows}=await db.query(`insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id)
    values('${recipient}','${type}','A private title','A private body','OPEN_QUEUE_PARTY_MEMBERSHIP','${membership}') returning id`);
  return rows[0]?.id;
}
await user(a);
await scalar(`select public.get_my_push_capability()->>'enabled'`,'false');
await rejects(`select public.register_my_push_device('${installation}',1,'fixture_token_long_enough_for_tests','ios','fieldrush-fixture')`,/not configured/);
await save({party_invites:false});
await scalar(`select (public.get_my_profile_settings()->'notifications'->>'party_invites')::boolean`,false);
await owner();
await scalar(`select public.create_open_queue_party_invite_notification('${membership}') is null`,true);
await scalar(`select status from public.open_queue_party_members where id='${membership}'`,'INVITED');
await scalar(`select count(*)::int from public.notifications`,0);
for(const type of ['GAME_REMINDER','CLAN_CALLUP','LADDER_MOVE','REPLAY_READY','NEWS_AND_OFFERS']){
  await user(a);await save(Object.fromEntries(Object.keys(prefs).map(key=>[key,false])));
  await notice(type);await scalar(`select count(*)::int from public.notifications`,0);
}
const mandatory=await notice('RELIABILITY_SANCTION');
await notice('PAYMENT_REFUND');await notice('SUPPORT_TICKET_UPDATE');await notice('OPEN_QUEUE_TEAM_REASSIGNED');
await user(a);await scalar(`select count(*)::int from public.notifications`,4);
await scalar(`select public.my_notification_preference_allows('${b}','OPEN_QUEUE_PARTY_INVITE')`,false);
await rejects(`select * from fieldrush_private.push_devices`,/permission denied/);
await rejects(`select public.claim_push_deliveries(10,'${claim}')`,/permission denied/);
await rejects(`select public.update_my_notification_preferences('{"party_invites":false}')`,/six boolean/);
await save();
await owner();
const invited=(await db.query(`select public.create_open_queue_party_invite_notification('${membership}') as id`)).rows[0].id;
await user(a);
await scalar(`select jsonb_array_length(public.list_my_open_queue_party_invite_notifications())`,1);
await save({party_invites:false});
await scalar(`select count(*)::int from public.notifications where id='${invited}'`,0);
await scalar(`select jsonb_array_length(public.list_my_open_queue_party_invite_notifications())`,0);
await owner();await scalar(`select count(*)::int from public.notifications where id='${invited}'`,1);
await user(a);await save();
await db.exec(`select public.dismiss_my_home_notification('${invited}')`);
await scalar(`select jsonb_array_length(public.list_my_open_queue_party_invite_notifications())`,0);
await owner();await scalar(`select status from public.open_queue_party_members where id='${membership}'`,'INVITED');
await user(b);await scalar(`select count(*)::int from public.notifications`,0);
await rejects(`select public.dismiss_my_home_notification('${mandatory}')`,/Notification not found/);

await worker();await rejects(`select public.configure_push_delivery(null,true)`,/valid Firebase/);
await db.exec(`select public.configure_push_delivery('fieldrush-fixture',true)`);
await user(a);await db.exec(`select public.register_my_push_device('${installation}',10,'fixture_token_long_enough_for_tests','ios','fieldrush-fixture')`);
await owner();await scalar(`select count(*)::int from fieldrush_private.push_deliveries`,0);
const queued=await notice('GAME_REMINDER');
await owner();await scalar(`select count(*)::int from fieldrush_private.push_deliveries`,1);
await db.exec(`select fieldrush_private.enqueue_notification_push('${queued}')`);
await scalar(`select count(*)::int from fieldrush_private.push_deliveries`,1);
await worker();await scalar(`select jsonb_array_length(public.claim_push_deliveries(10,'${claim}'))`,1);
await owner();let delivery=(await db.query(`select id from fieldrush_private.push_deliveries where notification_id='${queued}'`)).rows[0].id;
await worker();await scalar(`select public.get_push_delivery_payload('${delivery}','${claim}')->>'body'`,'You have a new update. Open Fieldrush to view it.');
await user(a);await save({game_reminders:false});
await worker();await scalar(`select public.get_push_delivery_payload('${delivery}','${claim}') is null`,true);
await owner();await scalar(`select status from fieldrush_private.push_deliveries where id='${delivery}'`,'SKIPPED');
await user(a);await save();
const reboundNotice=await notice('GAME_REMINDER');
await worker();await db.exec(`select public.claim_push_deliveries(10,'${claim}')`);
await owner();delivery=(await db.query(`select id from fieldrush_private.push_deliveries where notification_id='${reboundNotice}'`)).rows[0].id;
await user(a);await db.exec(`select public.revoke_my_push_device('${installation}',20)`);
await rejects(`select public.register_my_push_device('${installation}',10,'fixture_token_long_enough_for_tests','ios','fieldrush-fixture')`,/revoked|stale/);
await worker();await scalar(`select public.get_push_delivery_payload('${delivery}','${claim}') is null`,true);
await user(b);await db.exec(`select public.register_my_push_device('${installation}',30,'new_owner_token_long_enough_for_tests','android','fieldrush-fixture')`);
await user(a);await rejects(`select public.register_my_push_device('${installation}',10,'fixture_token_long_enough_for_tests','ios','fieldrush-fixture')`,/revoked|stale/);
await db.exec(`select public.revoke_my_push_device('${installation}',40)`);
await owner();await scalar(`select active and user_id='${b}'::uuid from fieldrush_private.push_devices where installation_id='${installation}'`,true);
// A logout tombstone also wins when registration has not created its row yet.
await user(a);await db.exec(`select public.revoke_my_push_device('${emptyInstallation}',50)`);
await rejects(`select public.register_my_push_device('${emptyInstallation}',49,'never_registered_token_long_enough','ios','fieldrush-fixture')`,/revoked/);

const readNotice=await notice('PAYMENT_REFUND',b);
await worker();await db.exec(`select public.claim_push_deliveries(10,'${claim}')`);
await owner();let readDelivery=(await db.query(`select id from fieldrush_private.push_deliveries where notification_id='${readNotice}'`)).rows[0].id;
await db.exec(`update public.notifications set read_at=now() where id='${readNotice}'`);
await worker();await scalar(`select public.get_push_delivery_payload('${readDelivery}','${claim}') is null`,true);

// An UNREGISTERED response for old token T1 must not revoke refreshed token T2.
const staleTokenNotice=await notice('PAYMENT_REFUND',b);
await worker();await db.exec(`select public.claim_push_deliveries(10,'${claim}')`);
await owner();let staleDelivery=(await db.query(`select id from fieldrush_private.push_deliveries where notification_id='${staleTokenNotice}'`)).rows[0].id;
await user(b);await db.exec(`select public.register_my_push_device('${installation}',30,'refreshed_owner_token_long_enough_for_tests','android','fieldrush-fixture')`);
await worker();await db.exec(`select public.complete_push_delivery('${staleDelivery}','${claim}','INVALID_TOKEN',null,'UNREGISTERED',null,'new_owner_token_long_enough_for_tests')`);
await owner();await scalar(`select active and registration_token='refreshed_owner_token_long_enough_for_tests' from fieldrush_private.push_devices where installation_id='${installation}'`,true);

const sentNotice=await notice('PAYMENT_REFUND',b);
await worker();await db.exec(`select public.claim_push_deliveries(10,'${claim}')`);
await owner();delivery=(await db.query(`select id from fieldrush_private.push_deliveries where notification_id='${sentNotice}'`)).rows[0].id;
await worker();await db.exec(`select public.complete_push_delivery('${delivery}','${claim}','RETRY',null,'QUOTA_EXCEEDED',120)`);
await owner();await scalar(`select status='PENDING' and next_attempt_at>=now()+interval '119 seconds' from fieldrush_private.push_deliveries where id='${delivery}'`,true);
await db.exec(`update fieldrush_private.push_deliveries set next_attempt_at=now()-interval '1 second' where id='${delivery}'`);
await worker();await db.exec(`select public.claim_push_deliveries(10,'${claim}')`);
await db.exec(`select public.complete_push_delivery('${delivery}','${claim}','INVALID_TOKEN',null,'UNREGISTERED',null,'refreshed_owner_token_long_enough_for_tests')`);
await owner();await scalar(`select not active from fieldrush_private.push_devices where installation_id='${installation}'`,true);
await scalar(`select status from fieldrush_private.push_deliveries where id='${delivery}'`,'FAILED');
await db.exec(`set request.jwt.claim.sub='';set role anon;`);
await rejects(`select public.get_my_push_capability()`,/permission denied/);
await rejects(`select public.my_notification_preference_allows('${a}','OPEN_QUEUE_PARTY_INVITE')`,/permission denied/);
await owner();
await scalar(`select not has_function_privilege('authenticated','public.complete_push_delivery(uuid,uuid,text,text,text,integer,text)','EXECUTE')`,true);
console.log(`${checks} isolated notification preference and push delivery checks passed.`);
await db.close();
