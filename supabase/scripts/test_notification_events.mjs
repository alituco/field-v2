// Real isolated PostgreSQL execution of migrations 001/002/004. Domain fixtures
// expose the authoritative table/function contracts; no hosted DB or provider.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
const read=name=>readFile(new URL(`../${name}`,import.meta.url),'utf8');
const id=n=>`ab150000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const [a,b,c,admin,clan,otherClan,solo,fixture,roster,publication,installation,claim]=Array.from({length:12},(_,i)=>id(i+1));
let checks=0;
const scalar=async(sql,expected)=>{const result=await db.query(sql);assert.deepEqual(Object.values(result.rows[0])[0],expected,sql);checks++;};
const rejects=async(sql,pattern)=>{await assert.rejects(db.exec(sql),pattern);checks++;};
const owner=()=>db.exec('reset role;');
const worker=()=>db.exec(`reset role;set request.jwt.claim.role='service_role';set role service_role;`);
function extract(source,name){const start=source.search(new RegExp(`create(?: or replace)? function ${name.replaceAll('.','\\.')}\\(`));assert.ok(start>=0,name);return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3);}
await db.exec(`
create role anon;create role authenticated;create role service_role;
create schema auth;create schema fieldrush_private;create schema fieldrush_rating_private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
grant usage on schema auth to authenticated,service_role;
create table auth.users(id uuid primary key,email text,phone text,email_confirmed_at timestamptz,phone_confirmed_at timestamptz,deleted_at timestamptz,banned_until timestamptz,raw_user_meta_data jsonb default '{}');
create table public.profiles(id uuid primary key references auth.users,display_name text,username text,bio text,avatar_url text,date_of_birth date);
insert into auth.users(id) values('${a}'),('${b}'),('${c}'),('${admin}');
insert into public.profiles(id,display_name,username) select id,id::text,id::text from auth.users;
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now();return new;end$$;
create function public.is_fieldrush_account_active(caller uuid) returns boolean language sql stable security definer as $$select exists(select 1 from auth.users where id=caller and deleted_at is null)$$;
create table public.referee_profiles(profile_id uuid primary key references public.profiles,is_admin boolean not null default false);
insert into public.referee_profiles values('${admin}',true);
create function public.is_active_moderation_admin(caller uuid) returns boolean language sql stable security definer as $$select exists(select 1 from public.referee_profiles where profile_id=caller and is_admin)$$;
create table public.open_queue_games(id uuid primary key,venue text,starts_at timestamptz,status text);
create table public.open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,status text);
create table public.open_queue_parties(id uuid primary key,status text);
create table public.open_queue_party_members(id uuid primary key,profile_id uuid,invited_by uuid,party_id uuid,game_id uuid,status text);
create table public.fixtures(id uuid primary key,match_date date,time_slot text,status text,home_clan_id uuid,away_clan_id uuid);
create function public.fixture_start_at(day_to_use date,slot_to_use text) returns timestamptz language sql stable as $$select (day_to_use::text||' '||slot_to_use)::timestamptz$$;
create table public.clan_members(clan_id uuid,profile_id uuid,left_at timestamptz,role text);
create table public.fixture_reliability_roster_history(id uuid primary key,fixture_id uuid,clan_id uuid,profile_id uuid,status text,confirmed_by uuid,confirmed_at timestamptz default clock_timestamp());
create function public.set_fixture_reliability_roster(fixture_id_to_manage uuid,clan_id_to_manage uuid,profile_ids_to_confirm uuid[],note_to_use text default null)
returns jsonb language plpgsql security definer as $$begin
 if not exists(select 1 from public.clan_members where clan_id=clan_id_to_manage and profile_id=auth.uid() and left_at is null and role in ('owner','leader')) then
   raise exception 'Captain access required' using errcode='42501'; end if;
 return jsonb_build_object('confirmed_count',cardinality(profile_ids_to_confirm));end$$;
create table public.open_queue_broadcasts(game_id uuid primary key,provider text default 'cloudflare',status text,recording_ready_at timestamptz,active_video_id text,replay_hls_url text);
create table public.fixture_broadcasts(fixture_id uuid primary key,provider text default 'cloudflare',status text,recording_ready_at timestamptz,active_video_id text,replay_hls_url text);
create table public.current_match_attendance_records(match_kind text,open_queue_game_id uuid,fixture_id uuid,profile_id uuid,checked_in_at timestamptz,cancelled_at timestamptz,outcome text);
create table public.fieldrush_cities(id text primary key);
insert into public.fieldrush_cities values('phoenix'),('new-york');
create table public.fieldrush_seasons(id text primary key,lifecycle text,visible_to_players boolean,starts_on date,ends_on date,minimum_rated_games integer);
insert into public.fieldrush_seasons values('s1','ACTIVE',true,current_date-1,current_date+90,2);
create table public.fieldrush_player_rating_tracks(profile_id uuid,rating_track text,matches_played integer);
create table fieldrush_rating_private.ranking_fixture(profile_id uuid,rating_track text,city_id text,sr integer,played integer,committed boolean default true);
create function fieldrush_rating_private.track_rankings(text,text,text,date,date)
returns table(rank bigint,profile_id uuid,primary_city_id text,matches_played integer) language sql stable as $$
 select row_number() over(order by sr desc,profile_id),profile_id,city_id,played
 from fieldrush_rating_private.ranking_fixture where rating_track=$3 and committed order by sr desc,profile_id$$;
`);
const accounts=await read('migrations/20261009000000_create_fieldrush_accounts.sql');
await db.exec(extract(accounts,'fieldrush_private.require_user'));
await db.exec(await read('migrations/20261002000000_create_private_profile_settings.sql'));
const invites=await read('migrations/20260715000008_allow_open_queue_party_switches.sql');
await db.exec(invites.slice(invites.indexOf('create table public.notifications'),invites.indexOf('-- Foreground clients')));
await db.exec(await read('migrations/20261012000200_home_activity_dismissals.sql'));
await db.exec(await read('migrations/20261015000100_notification_preferences.sql'));
await db.exec(await read('migrations/20261015000200_push_delivery_foundation.sql'));
await db.exec(await read('migrations/20261015000400_notification_events.sql'));

await db.exec(`insert into public.profile_settings(profile_id,game_reminders,clan_callups,party_invites,ladder_moves,replays_ready,news_and_offers)
 values('${a}',true,true,true,true,true,true),('${b}',false,false,true,false,false,false),('${c}',true,true,true,true,true,false);
 insert into public.open_queue_games values('${solo}','Private fixture venue',clock_timestamp()+interval '23 hours 59 minutes','OPEN');
 insert into public.open_queue_bookings(game_id,profile_id,status) values('${solo}','${a}','CONFIRMED'),('${solo}','${b}','CONFIRMED'),('${solo}','${c}','CANCELLED');`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,1);
await scalar(`select count(*)::int from public.notifications where type='GAME_REMINDER'`,1);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,0);
await db.exec(`set timezone='America/Phoenix'`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,0);
await db.exec(`set timezone='UTC'`);
await db.exec(`update public.profile_settings set game_reminders=true where profile_id='${b}'`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,0);
await scalar(`select count(*)::int from public.notifications where recipient_profile_id='${b}'`,0);
await scalar(`select count(*)::int from fieldrush_private.notification_event_receipts where notification_type='GAME_REMINDER'`,2);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='GAME_REMINDER' limit 1))`,true);
await db.exec(`update public.open_queue_games set status='CANCELLED' where id='${solo}'`);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='GAME_REMINDER' limit 1))`,false);
await db.exec(`select fieldrush_private.process_notification_events()`);
await scalar(`select resolved_at is not null from public.notifications where type='GAME_REMINDER' limit 1`,true);
await db.exec(`update public.open_queue_games set status='OPEN',starts_at=clock_timestamp()+interval '119 minutes' where id='${solo}'`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,2);
await db.exec(`update public.open_queue_games set starts_at=clock_timestamp()+interval '1 hour' where id='${solo}'`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,0);
// A threshold missed by one slightly late cron run is still delivered once.
await db.exec(`insert into public.open_queue_games values('${id(90)}','Jitter fixture',clock_timestamp()+interval '23 hours 54 minutes','OPEN');
 insert into public.open_queue_bookings(game_id,profile_id,status) values('${id(90)}','${a}','CONFIRMED')`);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,1);
await scalar(`select (fieldrush_private.process_notification_events()->>'reminders')::int`,0);

await db.exec(`insert into public.fixtures values('${fixture}',current_date+1,'12:00:00+00','SCHEDULED','${clan}','${otherClan}');
 insert into public.clan_members values('${clan}','${a}',null,'member'),('${clan}','${b}',null,'member'),('${clan}','${admin}',null,'owner');
 insert into public.fixture_reliability_roster_history values('${roster}','${fixture}','${clan}','${a}','CONFIRMED','${admin}',clock_timestamp());`);
await scalar(`select count(*)::int from public.notifications where type='CLAN_CALLUP'`,0);
await db.exec(`set request.jwt.claim.sub='${admin}';select public.set_fixture_reliability_roster('${fixture}','${clan}',array['${a}']::uuid[])`);
await scalar(`select count(*)::int from public.notifications where type='CLAN_CALLUP'`,1);
await db.exec(`select public.set_fixture_reliability_roster('${fixture}','${clan}',array['${a}']::uuid[])`);
await scalar(`select count(*)::int from public.notifications where type='CLAN_CALLUP'`,1);
await db.exec(`insert into public.fixture_reliability_roster_history values('${id(30)}','${fixture}','${clan}','${b}','CONFIRMED','${admin}',clock_timestamp());
 insert into public.fixture_reliability_roster_history values('${id(31)}','${fixture}','${clan}','${c}','CONFIRMED',null,clock_timestamp());`);
await db.exec(`select public.set_fixture_reliability_roster('${fixture}','${clan}',array['${a}','${b}']::uuid[])`);
await scalar(`select count(*)::int from public.notifications where type='CLAN_CALLUP'`,1);
await db.exec(`set request.jwt.claim.sub='${c}'`);
await rejects(`select public.set_fixture_reliability_roster('${fixture}','${clan}',array['${a}']::uuid[])`,/Captain access/);
await db.exec(`update public.fixture_reliability_roster_history set status='REMOVED' where id='${roster}'`);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='CLAN_CALLUP'))`,false);

await db.exec(`update public.open_queue_games set status='FINAL' where id='${solo}';
 insert into public.current_match_attendance_records values('SOLO','${solo}',null,'${a}',clock_timestamp(),null,'ON_TIME'),
 ('SOLO','${solo}',null,'${b}',null,null,'NO_SHOW'),('SOLO','${solo}',null,'${c}',clock_timestamp(),clock_timestamp(),'CANCELLED_LATE');
 insert into public.open_queue_broadcasts values('${solo}','cloudflare','REPLAY_READY',clock_timestamp(),'video-a','https://fixture.invalid/replay.m3u8');`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY'`,1);

// Processing can become ready before FINAL. The sweep must wait, then emit
// once for checked-in participants, without depending on another webhook.
await db.exec(`insert into public.open_queue_games values('${id(50)}','Pending final',clock_timestamp()-interval '1 hour','LIVE');
 insert into public.current_match_attendance_records values('SOLO','${id(50)}',null,'${c}',clock_timestamp(),null,'ON_TIME');
 insert into public.open_queue_broadcasts values('${id(50)}','cloudflare','REPLAY_READY',clock_timestamp(),'pending-video','https://fixture.invalid/pending.m3u8');`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY' and recipient_profile_id='${c}'`,0);
await db.exec(`update public.open_queue_games set status='FINAL' where id='${id(50)}';select fieldrush_private.process_notification_events()`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY' and recipient_profile_id='${c}'`,1);
await db.exec(`select fieldrush_private.process_notification_events()`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY' and recipient_profile_id='${c}'`,1);
await db.exec(`update public.fixtures set status='FINAL' where id='${fixture}';
 insert into public.current_match_attendance_records values('CLAN',null,'${fixture}','${a}',clock_timestamp(),null,'ON_TIME'),
 ('CLAN',null,'${fixture}','${b}',null,null,'NO_SHOW');
 insert into public.fixture_broadcasts values('${fixture}','cloudflare','REPLAY_READY',clock_timestamp(),'clan-video','https://fixture.invalid/clan.m3u8');`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY' and related_entity_type='FIXTURE'`,1);
await scalar(`select fieldrush_private.emit_ready_replay('SOLO','${solo}')`,0);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY' and related_entity_id='${solo}' and recipient_profile_id<>'${a}'`,0);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='REPLAY_READY' and related_entity_id='${solo}'))`,true);
await db.exec(`update public.open_queue_broadcasts set status='ERROR' where game_id='${solo}'`);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='REPLAY_READY' and related_entity_id='${solo}'))`,false);
await db.exec(`update public.open_queue_broadcasts set status='REPLAY_READY' where game_id='${solo}'`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY'`,3);
await db.exec(`insert into public.open_queue_games values('${id(32)}','Old fixture',clock_timestamp()-interval '2 days','FINAL');
 insert into public.current_match_attendance_records values('SOLO','${id(32)}',null,'${a}',clock_timestamp(),null,'ON_TIME');
 insert into public.open_queue_broadcasts values('${id(32)}','cloudflare','REPLAY_READY',clock_timestamp()-interval '2 days','old-video','https://fixture.invalid/old.m3u8');`);
await scalar(`select count(*)::int from public.notifications where type='REPLAY_READY'`,3);

await db.exec(`insert into public.fieldrush_player_rating_tracks values('${a}','OUTFIELD',2),('${b}','OUTFIELD',2),('${c}','OUTFIELD',1);
 insert into fieldrush_rating_private.ranking_fixture values('${a}','OUTFIELD','phoenix',1000,2,true),('${b}','OUTFIELD','phoenix',900,2,true),('${c}','OUTFIELD','phoenix',1100,1,true);`);
await scalar(`select fieldrush_private.observe_notification_ladder()`,0);
await scalar(`select count(*)::int from fieldrush_private.notification_ladder_snapshots`,2);
await db.exec(`update fieldrush_rating_private.ranking_fixture set sr=1200 where profile_id='${b}'`);
await scalar(`select fieldrush_private.observe_notification_ladder()`,1);
await scalar(`select data->>'previous_rank'||':'||(data->>'rank') from public.notifications where type='LADDER_MOVE'`,'1:2');
await scalar(`select fieldrush_private.observe_notification_ladder()`,0);
await db.exec(`update fieldrush_rating_private.ranking_fixture set city_id='new-york' where profile_id='${a}'`);
await scalar(`select fieldrush_private.observe_notification_ladder()`,0);
await db.exec(`update fieldrush_rating_private.ranking_fixture set committed=false where profile_id='${a}'`);
await scalar(`select fieldrush_private.observe_notification_ladder()`,0);

await worker();
const expiry=(await db.query(`select (clock_timestamp()+interval '1 day')::text expiry`)).rows[0].expiry;
const publish=`select public.admin_publish_fieldrush_news('${admin}','${publication}','Fixture news','An explicitly approved update.','Reviewed opt-in publication.','${expiry}',true)`;
await scalar(`select (${publish.slice(7)}->>'recipients')::int`,1);
await owner();
await scalar(`select count(*)::int from public.notifications where type='NEWS_AND_OFFERS'`,1);
await worker();
await scalar(`select (${publish.slice(7)}->>'already_published')::boolean`,true);
await rejects(`select public.admin_publish_fieldrush_news('${admin}','${publication}','Different title','An explicitly approved update.','Reviewed opt-in publication.','${expiry}',true)`,/different content/);
await rejects(`select public.admin_publish_fieldrush_news('${a}','${id(40)}','Fixture news','An explicitly approved update.','Reviewed opt-in publication.','${expiry}',true)`,/Active admin/);
await rejects(`select public.admin_publish_fieldrush_news('${admin}','${id(40)}','Fixture news','An explicitly approved update.','Reviewed opt-in publication.','${expiry}',false)`,/Confirm/);
await owner();
await scalar(`select recipient_count=1 and reason='Reviewed opt-in publication.' from fieldrush_private.notification_news_publications where id='${publication}'`,true);
await db.exec(`update fieldrush_private.notification_news_publications set expires_at=clock_timestamp()-interval '1 minute' where id='${publication}'`);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='NEWS_AND_OFFERS'))`,false);
await db.exec(`set request.jwt.claim.sub='${a}';set request.jwt.claim.role='authenticated';set role authenticated;`);
await rejects(publish,/permission denied/);
await rejects(`select public.process_fieldrush_notification_events()`,/permission denied/);
await rejects(`select * from fieldrush_private.notification_news_publications`,/permission denied/);
await rejects(`select fieldrush_private.emit_notification_event('${a}','GAME_REMINDER','forged','Forged','Forged',null,null,'{}')`,/permission denied/);
await owner();
await scalar(`select not has_function_privilege('authenticated','public.admin_publish_fieldrush_news(uuid,uuid,text,text,text,timestamptz,boolean)','EXECUTE')`,true);
await scalar(`select not has_table_privilege('service_role','fieldrush_private.notification_event_receipts','SELECT')`,true);

// Event creation uses the real outbox hook. Eligibility is checked again at
// dispatch so an already queued reminder cannot outlive a canceled booking.
await worker();
await db.exec(`select public.configure_push_delivery('fieldrush-fixture',true)`);
await db.exec(`reset role;set request.jwt.claim.sub='${a}';set request.jwt.claim.role='authenticated';set role authenticated;
 select public.register_my_push_device('${installation}',1,'fixture_notification_token_long_enough','ios','fieldrush-fixture')`);
await owner();
await db.exec(`insert into public.open_queue_games values('${id(60)}','Future fixture',clock_timestamp()+interval '119 minutes','OPEN');
 insert into public.open_queue_bookings(game_id,profile_id,status) values('${id(60)}','${a}','CONFIRMED');
 select fieldrush_private.process_notification_events()`);
const queued=(await db.query(`select d.id,n.id notification from fieldrush_private.push_deliveries d join public.notifications n on n.id=d.notification_id
 where n.type='GAME_REMINDER' and n.related_entity_id='${id(60)}'`)).rows;
assert.equal(queued.length,1);checks++;
await worker();
await db.exec(`select public.claim_push_deliveries(50,'${claim}')`);
await scalar(`select public.get_push_delivery_payload('${queued[0].id}','${claim}') is not null`,true);
await owner();
await db.exec(`update public.open_queue_bookings set status='CANCELLED' where game_id='${id(60)}'`);
await worker();
await scalar(`select public.get_push_delivery_payload('${queued[0].id}','${claim}') is null`,true);
await owner();
await scalar(`select status from fieldrush_private.push_deliveries where id='${queued[0].id}'`,'SKIPPED');
await db.exec(`insert into public.fixtures values('${id(70)}',(clock_timestamp()+interval '119 minutes')::date,
 to_char(clock_timestamp()+interval '119 minutes','HH24:MI:SSOF'),'SCHEDULED','${clan}','${otherClan}');
 insert into public.fixture_reliability_roster_history values('${id(71)}','${id(70)}','${clan}','${a}','CONFIRMED','${admin}',clock_timestamp());
 select fieldrush_private.process_notification_events()`);
await scalar(`select count(*)::int from public.notifications where type='GAME_REMINDER' and related_entity_type='FIXTURE' and related_entity_id='${id(70)}'`,1);
await scalar(`select fieldrush_private.notification_source_is_current((select id from public.notifications where type='GAME_REMINDER' and related_entity_id='${id(70)}'))`,true);
await scalar(`select count(*)::int from public.notifications where type='CLAN_CALLUP' and related_entity_id='${id(70)}'`,0);
await db.exec(`insert into public.open_queue_games values('${id(80)}','Party fixture',clock_timestamp()+interval '2 days','OPEN');
 insert into public.open_queue_parties values('${id(81)}','ACTIVE');
 insert into public.open_queue_party_members values('${id(82)}','${a}','${admin}','${id(81)}','${id(80)}','INVITED');
 insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id)
 values('${a}','OPEN_QUEUE_PARTY_INVITE','Party invitation','A real pending invitation','OPEN_QUEUE_PARTY_MEMBERSHIP','${id(82)}');`);
const partyNotice=(await db.query(`select id from public.notifications where type='OPEN_QUEUE_PARTY_INVITE'`)).rows[0].id;
await scalar(`select fieldrush_private.notification_source_is_current('${partyNotice}')`,true);
await db.exec(`update public.open_queue_parties set status='EXPIRED' where id='${id(81)}'`);
await scalar(`select fieldrush_private.notification_source_is_current('${partyNotice}')`,false);
await db.exec(`update public.open_queue_parties set status='ACTIVE' where id='${id(81)}';update public.open_queue_games set status='CANCELLED' where id='${id(80)}'`);
await scalar(`select fieldrush_private.notification_source_is_current('${partyNotice}')`,false);
await db.exec(`update public.open_queue_games set status='OPEN' where id='${id(80)}';update public.open_queue_party_members set status='ACCEPTED' where id='${id(82)}'`);
await scalar(`select fieldrush_private.notification_source_is_current('${partyNotice}')`,false);
console.log(`${checks} isolated notification event-source checks passed.`);
await db.close();
