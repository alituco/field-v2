// Isolated PostgreSQL/PGlite fixture tests, never connected to a Supabase project.
// npm install --prefix /tmp/fieldrush-market-sql-tools --no-package-lock --no-save @electric-sql/pglite@0.5.8
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_fieldrush_market.mjs
// This tests the new migrations against the real relevant function definitions,
// with a minimal fixture schema; it is not a full Supabase migration replay.
// Its pre-October fixture intentionally uses the historical payment table names
// that the tested market migrations expect. The later provider rename and full
// Stripe checkout/refund behavior are tested in verify_stripe_payment_system.sql.
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const migrations = new URL('../migrations/', import.meta.url);
async function source(file) { return readFile(new URL(file, migrations), 'utf8'); }
async function fn(file, name) {
  const sql = await source(file);
  const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'i'));
  assert(start >= 0, name);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= 0, name);
  return sql.slice(start, end + 4);
}
const core = '20260716000002_enforce_reliability_attendance.sql';
const account = '20261009000000_create_fieldrush_accounts.sql';
const sr = '20260713000007_create_open_queue_player_sr_system.sql';
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth; create schema fieldrush_private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.user', true), '')::uuid$$;
create function fieldrush_private.require_user() returns uuid language sql as $$select auth.uid()$$;
create function public.set_updated_at() returns trigger language plpgsql as $$begin new.updated_at = now(); return new; end$$;
create table auth.users (id uuid primary key, email text, phone text, email_confirmed_at timestamptz, phone_confirmed_at timestamptz);
create table auth.identities (user_id uuid, provider text);
create table fieldrush_private.accounts (user_id uuid primary key, first_name text, last_name text, username text, date_of_birth date,
 email text, status text default 'active', onboarding_completed_at timestamptz, tour_completed_at timestamptz);
create table public.profiles (id uuid primary key, display_name text, username text, avatar_url text, account_deleted_at timestamptz);
create table public.notifications (id uuid primary key, recipient_profile_id uuid, read_at timestamptz);
create table public.player_ratings (profile_id uuid primary key, skill_rating integer default 1200, matches_played integer default 0,
 wins integer default 0, losses integer default 0, draws integer default 0, last_change integer default 0, region text default 'bahrain');
create table public.player_rating_events (profile_id uuid, effective_at timestamptz, result text, rating_after integer,
 rating_change integer, applied_sequence bigint);
create table public.open_queue_games (
 id uuid primary key default gen_random_uuid(), status text default 'OPEN', venue text, starts_at timestamptz, ends_at timestamptz,
 operational_state text default 'NORMAL', operational_state_updated_at timestamptz default now(), operational_reason_code text,
 timezone text default 'Asia/Bahrain', price_fils integer default 3000, age_label text, created_by uuid,
 capacity integer default 12 constraint open_queue_games_capacity_check check(capacity = 12),
 goalkeeper_capacity integer default 2 constraint open_queue_games_goalkeeper_capacity_check check(goalkeeper_capacity = 2),
 defender_capacity integer default 4 constraint open_queue_games_defender_capacity_check check(defender_capacity = 4),
 midfielder_capacity integer default 4 constraint open_queue_games_midfielder_capacity_check check(midfielder_capacity = 4),
 attacker_capacity integer default 2 constraint open_queue_games_attacker_capacity_check check(attacker_capacity = 2),
 constraint open_queue_games_permanent_timezone_check check(timezone = 'Asia/Bahrain'),
 constraint open_queue_games_permanent_schedule_check check(ends_at = starts_at + interval '1 hour'),
 white_average_sr numeric, black_average_sr numeric, match_average_sr numeric, team_sr_spread numeric, teams_assigned_at timestamptz,
 replacement_offer_expires_at timestamptz, replacement_discount_role text, replacement_discount_bps integer default 0);
create table public.open_queue_bookings (id uuid primary key default gen_random_uuid(), game_id uuid, profile_id uuid,
 role text check(role in ('GK','DEF','MID','ATT')), status text default 'CONFIRMED', team text,
 rating_at_team_assignment integer, rating_at_match_start integer, rating_change integer);
create table public.open_queue_parties (id uuid primary key default gen_random_uuid(), game_id uuid, status text default 'ACTIVE');
create table public.open_queue_party_members (party_id uuid, game_id uuid, profile_id uuid, status text,
 responded_at timestamptz, ended_at timestamptz);
create table public.admin_audit_events (actor_referee_id uuid, action text, entity_type text, entity_id uuid,
 reason text, before_state jsonb, after_state jsonb);
create function public.is_active_moderation_admin(uuid) returns boolean language sql as $$select true$$;
create table public.reliability_policy_versions (id uuid primary key default gen_random_uuid(), state text, config jsonb,
 version integer, effective_from timestamptz);
create table public.match_reliability_terms (id uuid primary key default gen_random_uuid(), match_kind text, open_queue_game_id uuid,
 fixture_id uuid, policy_version_id uuid, policy_snapshot jsonb, check_in_deadline_at timestamptz);
create function public.open_queue_team_assignment_at(uuid) returns timestamptz language sql as $$select starts_at - interval '3 hours' from public.open_queue_games where id=$1$$;
create function public.active_reliability_strikes(uuid,timestamptz) returns integer language sql as $$select 0$$;
create function public.ensure_match_reliability_terms(text,uuid) returns public.match_reliability_terms language sql as $$select t from public.match_reliability_terms t where open_queue_game_id=$2$$;
create table public.tap_payment_intents (id uuid primary key default gen_random_uuid(), profile_id uuid,
 currency text default 'BHD' constraint tap_payment_intents_currency_check check(currency='BHD'), amount_fils integer,
 status text, purpose text, tap_status text, tap_charge_id text, tap_payment_method text, payload jsonb);
create table public.field_wallet_accounts (profile_id uuid primary key, balance_fils bigint default 0, currency text default 'BHD', updated_at timestamptz);
create table public.field_wallet_transactions (id uuid primary key default gen_random_uuid(), profile_id uuid, direction text,
 amount_fils integer, transaction_type text, balance_after_fils bigint, idempotency_key text unique, policy_version_id uuid,
 booking_id uuid, incident_id uuid, description text, metadata jsonb);
-- Dependencies used only by the existing deletion readiness guard.
create table public.referee_profiles (profile_id uuid);
create table public.clans (id uuid, archived_at timestamptz);
create table public.clan_members (profile_id uuid, clan_id uuid, role text, left_at timestamptz);
create table public.fixtures (id uuid, home_clan_id uuid, away_clan_id uuid, status text, home_paid_by uuid, away_paid_by uuid);
create table public.fixture_player_appearances (profile_id uuid);
create table public.match_resolution_refunds (recipient_profile_id uuid, status text);
create table public.reliability_sanctions (id uuid);
`);
for (const [file, name] of [
  ['20260719000001_admin_manage_open_queue_games.sql', 'public.admin_create_open_queue_game'],
  [sr, 'public.season_player_rating_rankings'], [sr, 'public.get_my_season_player_rating'],
  [sr, 'public.list_open_queue_games'],
  ['20260713000002_enforce_scheduling_limits.sql', 'public.enforce_open_queue_booking_capacity'],
  ['20260721000000_make_reliability_formats_six_a_side.sql', 'public.normalize_reliability_draft_format'],
  ['20260716000007_preview_open_queue_booking_cost.sql', 'public.preview_open_queue_booking_cost'],
  [core, 'public.get_my_reliability_status'],
  [account, 'fieldrush_private.serialize_wallet_with_deletion'],
  [account, 'fieldrush_private.assert_deletion_ready'],
]) await db.exec(await fn(file, name));
// Apply the real latest discovery return-contract patch, not a hand-written
// imitation. Other RPC patches in that DO block are outside this fixture schema.
const controlPlane = await source('20260730000000_create_match_resolution_control_plane.sql');
const discoveryPatchStart = controlPlane.indexOf('do $migration$', controlPlane.indexOf('-- Mobile consumes these three RPCs'));
const discoveryPatchEnd = controlPlane.indexOf("  select pg_get_functiondef(\n    'public.list_open_queue_fixture_games()'", discoveryPatchStart);
assert(discoveryPatchStart >= 0 && discoveryPatchEnd > discoveryPatchStart);
await db.exec(controlPlane.slice(discoveryPatchStart, discoveryPatchEnd) + 'end;\n$migration$;');
await db.exec((await fn('20260723010000_finalize_tap_payments_atomically.sql', 'public.book_open_queue_game'))
  .replace('function public.book_open_queue_game(', 'function public.book_open_queue_game_server('));
await db.exec(`
create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status
 on public.open_queue_bookings for each row execute function public.enforce_open_queue_booking_capacity();
create trigger normalize_reliability_draft_format before insert or update of state,config
 on public.reliability_policy_versions for each row execute function public.normalize_reliability_draft_format();
insert into public.open_queue_games (id,venue,starts_at,ends_at)
 values ('00000000-0000-0000-0000-000000000001','Legacy', '2099-10-09T17:30:00Z','2099-10-09T18:30:00Z');
`);
for (const file of ['20261010000000_fieldrush_phoenix_game_format.sql', '20261010000100_fieldrush_usd_wallet_isolation.sql', '20261010000500_fieldrush_home_activity.sql']) {
  try { await db.exec(await source(file)); }
  catch (error) { console.error(`Migration failed: ${file}: ${error.message}`, error.where || ''); process.exit(1); }
}
await db.exec(`create trigger enforce_open_queue_permanent_schedule before insert or update of status,starts_at,ends_at,timezone
 on open_queue_games for each row execute function enforce_open_queue_permanent_schedule();`);
let checks = 0;
async function check(sql, expected = true) {
  const { rows } = await db.query(sql);
  assert.equal(Object.values(rows[0])[0], expected, sql);
  checks++;
}
async function rejects(sql, message) {
  await assert.rejects(db.exec(sql), message);
  checks++;
}
await check(`select format_version='LEGACY_6V6' and capacity=12 and midfielder_capacity=4 and currency='BHD' from open_queue_games limit 1`);
await db.exec(`insert into open_queue_games(id,venue,starts_at,ends_at)
 values('00000000-0000-0000-0000-000000000002','Phoenix','2099-10-10T03:30:00Z','2099-10-10T04:30:00Z');`);
await check(`select capacity=14 and defender_capacity=6 and midfielder_capacity=0 and attacker_capacity=6
 and currency='USD' and price_fils=13000 and timezone='America/Phoenix' from open_queue_games where id='00000000-0000-0000-0000-000000000002'`);
await rejects(`update open_queue_games set currency='BHD' where id='00000000-0000-0000-0000-000000000002'`, /format, market and currency cannot change/);
await rejects(`update open_queue_games set price_fils=13001 where id='00000000-0000-0000-0000-000000000002'`, /versioned_format_check/);
await rejects(`select admin_create_open_queue_game(null,'Test venue','2099-10-24T03:30:00Z',13001,'18+')`, /whole cents/);
await db.exec(`select admin_create_open_queue_game(null,'Admin Phoenix venue','2099-10-24T03:30:00Z',15000,'18+')`);
await check(`select capacity=14 and currency='USD' and price_fils=15000 and timezone='America/Phoenix'
 from open_queue_games where venue='Admin Phoenix venue'`);
await rejects(`insert into open_queue_games(venue,starts_at,ends_at)
 values('Wrong local time','2099-10-31T02:30:00Z','2099-10-31T03:30:00Z')`, /game timezone/);
// Complete both formats using different players so the existing booking limit
// remains authoritative. Include varied SR so the optimizer has real work.
await db.exec(`
insert into profiles(id,display_name,username) select ('10000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,'Player','player'||n from generate_series(1,30)n;
insert into player_ratings(profile_id,skill_rating) select id,1000+row_number() over(order by id)*37 from profiles;
insert into open_queue_bookings(game_id,profile_id,role) select '00000000-0000-0000-0000-000000000002',id,
 case when n<=2 then 'GK' when n<=8 then 'DEF' else 'ATT' end
 from (select id,row_number() over(order by id)n from profiles) p where n<=14;
insert into open_queue_bookings(game_id,profile_id,role) select '00000000-0000-0000-0000-000000000001',id,
 case when n<=16 then 'GK' when n<=20 then 'DEF' when n<=24 then 'MID' else 'ATT' end
 from (select id,row_number() over(order by id)n from profiles) p where n between 15 and 26;
insert into open_queue_parties(id,game_id) values('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002');
insert into open_queue_party_members(party_id,game_id,profile_id,status)
 select '20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',id,'ACCEPTED'
 from profiles where id in ('10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000009');
update open_queue_games set status='FULL';
select set_config('field.force_open_queue_team_assignment','00000000-0000-0000-0000-000000000002',false);
select assign_open_queue_teams('00000000-0000-0000-0000-000000000002');
select set_config('field.force_open_queue_team_assignment','00000000-0000-0000-0000-000000000001',false);
select assign_open_queue_teams('00000000-0000-0000-0000-000000000001');
`);
await check(`select count(*)=7 and count(*) filter(where role='GK')=1 and count(*) filter(where role='DEF')=3 and count(*) filter(where role='ATT')=3
 from open_queue_bookings where game_id='00000000-0000-0000-0000-000000000002' and team='WHITE'`);
await check(`select count(*)=6 and count(*) filter(where role='MID')=2 from open_queue_bookings
 where game_id='00000000-0000-0000-0000-000000000001' and team='WHITE'`);
await check(`select count(distinct team)=1 from open_queue_bookings where profile_id in
 ('10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000009')`);
await check(`select public.open_queue_party_assignment_is_possible('00000000-0000-0000-0000-000000000002')`);
await db.exec(`
insert into open_queue_games(id,venue,starts_at,ends_at) values('00000000-0000-0000-0000-000000000003','Phoenix','2099-10-17T03:30:00Z','2099-10-17T04:30:00Z');
do $$begin
 begin insert into open_queue_bookings(game_id,profile_id,role) values('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000030','MID');
 raise exception 'TEST: MID unexpectedly accepted';
 exception when others then if sqlerrm='TEST: MID unexpectedly accepted' then raise; end if; end;
end$$;
`);
await check(`select count(*)=0 from open_queue_bookings where game_id='00000000-0000-0000-0000-000000000003'`);
await check(`select public.open_queue_party_assignment_is_possible('00000000-0000-0000-0000-000000000003')`);
await db.exec(`
select set_config('test.user','10000000-0000-0000-0000-000000000030',false);
update open_queue_games set price_fils=13010, replacement_discount_role='ATT', replacement_discount_bps=5000,
 replacement_offer_expires_at='2099-10-17T03:30:00Z' where id='00000000-0000-0000-0000-000000000003';
insert into match_reliability_terms(match_kind,open_queue_game_id,check_in_deadline_at,policy_snapshot)
 values('SOLO','00000000-0000-0000-0000-000000000003','2099-10-17T03:00:00Z',
 '{"solo":{"playersPerSide":6,"reliabilityDeposit":{"activeStrikeThreshold":2,"depositBps":5000}},"wallet":{"currency":"BHD"}}');
`);
await check(`select policy_snapshot #>> '{solo,playersPerSide}'='7' and policy_snapshot #>> '{wallet,currency}'='USD'
 and policy_snapshot->>'timezone'='America/Phoenix'
 from match_reliability_terms where open_queue_game_id='00000000-0000-0000-0000-000000000003'`);
await check(`select preview_open_queue_booking_cost('00000000-0000-0000-0000-000000000003','ATT')->>'currency'='USD'
 and (preview_open_queue_booking_cost('00000000-0000-0000-0000-000000000003','ATT')->>'total_fils')::integer=6510`);
await db.exec(`do $$begin
 begin perform preview_open_queue_booking_cost('00000000-0000-0000-0000-000000000003','MID');
 raise exception 'TEST: MID quote unexpectedly accepted';
 exception when others then if sqlerrm='TEST: MID quote unexpectedly accepted' then raise; end if; end;
end$$;`);
await db.exec(`
insert into open_queue_bookings(game_id,profile_id,role)
 values('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000029','GK'),
 ('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000030','GK');
insert into open_queue_parties(id,game_id) values('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
insert into open_queue_party_members(party_id,game_id,profile_id,status)
 select '20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',id,'ACCEPTED'
 from profiles where id in ('10000000-0000-0000-0000-000000000029','10000000-0000-0000-0000-000000000030');
`);
await check(`select not public.open_queue_party_assignment_is_possible('00000000-0000-0000-0000-000000000003')`);
// Same person can hold both denominations; neither balance consumes the other.
await db.exec(`
insert into field_wallet_accounts(profile_id,balance_fils) values('10000000-0000-0000-0000-000000000001',3000);
select credit_field_wallet('10000000-0000-0000-0000-000000000001',13000,'BOOKING_REFUND','usd-test-refund','USD refund',null,
 (select id from open_queue_bookings where profile_id='10000000-0000-0000-0000-000000000001'),null,'{}');
select credit_field_wallet('10000000-0000-0000-0000-000000000001',13000,'BOOKING_REFUND','usd-test-refund','USD refund',null,
 (select id from open_queue_bookings where profile_id='10000000-0000-0000-0000-000000000001'),null,'{}');
select set_config('test.user','10000000-0000-0000-0000-000000000001',false);
`);
await check(`select balance_fils=3000 from field_wallet_accounts where profile_id=auth.uid()`);
await check(`select balance_fils=13000 from field_wallet_usd_accounts where profile_id=auth.uid()`);
await check(`select count(*)=1 and min(currency)='USD' from field_wallet_transactions where idempotency_key='usd-test-refund'`);
await rejects(`select credit_field_wallet('10000000-0000-0000-0000-000000000001',12000,'BOOKING_REFUND','usd-test-refund','USD refund',null,
 (select id from open_queue_bookings where profile_id='10000000-0000-0000-0000-000000000001'),null,'{}')`, /idempotency conflict/);
await rejects(`select credit_field_wallet('10000000-0000-0000-0000-000000000002',13000,'BOOKING_REFUND','wrong-recipient','USD refund',null,
 (select id from open_queue_bookings where profile_id='10000000-0000-0000-0000-000000000001'),null,'{}')`, /booking and recipient do not match/);
await check(`select get_my_fieldrush_wallet()->>'currency'='USD' and (get_my_fieldrush_wallet()->>'balance_fils')::integer=13000`);
await check(`select not has_function_privilege('authenticated','public.credit_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb)','EXECUTE')`);
await db.exec(`insert into auth.users(id,phone,phone_confirmed_at) values(auth.uid(),'16025550148',now());
insert into fieldrush_private.accounts(user_id,first_name,last_name,onboarding_completed_at) values(auth.uid(),'Test','Player',now());`);
await check(`select get_my_fieldrush_account()->>'home_city'='Phoenix, AZ' and get_my_fieldrush_account()->>'ranking_region'='phoenix'`);
await check(`select position('field_wallet_usd_accounts' in pg_get_functiondef('fieldrush_private.assert_deletion_ready(uuid)'::regprocedure))>0`);
await check(`select position('intent.currency = game_to_book.currency' in pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure))>0`);
await db.exec(`
insert into fieldrush_private.accounts(user_id,first_name,last_name,onboarding_completed_at)
 select id,'Fresh','Player',now() from profiles where id in
 ('10000000-0000-0000-0000-000000000027','10000000-0000-0000-0000-000000000028');
update player_ratings set region='bahrain' where profile_id in
 ('10000000-0000-0000-0000-000000000027','10000000-0000-0000-0000-000000000028');
insert into player_rating_events(profile_id,effective_at,result,rating_after,rating_change,applied_sequence)
 values('10000000-0000-0000-0000-000000000028',now(),'WIN',1210,10,1);
`);
await db.exec(await source('20261010000200_move_fresh_fieldrush_accounts_to_phoenix.sql'));
await check(`select region='phoenix' from player_ratings where profile_id='10000000-0000-0000-0000-000000000027'`);
await check(`select region='bahrain' from player_ratings where profile_id='10000000-0000-0000-0000-000000000028'`);
// SECURITY DEFINER activity reads must remain bound to the authenticated recipient.
await db.exec(`
insert into notifications(id,recipient_profile_id) values
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002');
select set_config('test.user','10000000-0000-0000-0000-000000000001',false);
set role authenticated;
select mark_my_home_notification_read('30000000-0000-0000-0000-000000000001');
select mark_my_home_notification_read('30000000-0000-0000-0000-000000000002');
reset role;
`);
await check(`select read_at is not null from notifications where id='30000000-0000-0000-0000-000000000001'`);
await check(`select read_at is null from notifications where id='30000000-0000-0000-0000-000000000002'`);
await check(`select not has_function_privilege('anon','public.mark_my_home_notification_read(uuid)','EXECUTE')`);
await db.exec(`select set_config('test.user','',false); set role authenticated;
do $$begin
 begin perform public.mark_my_home_notification_read('30000000-0000-0000-0000-000000000001');
 raise exception 'TEST: unauthenticated read unexpectedly accepted';
 exception when insufficient_privilege then null; end;
end$$; reset role;`);
// Older-market inventory must not consume the new market's LIMIT 40 window.
await db.exec(`
insert into open_queue_games(format_version,currency,timezone,capacity,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity,
 venue,starts_at,ends_at,price_fils)
 select 'LEGACY_6V6','BHD','Asia/Bahrain',12,2,4,4,2,'Legacy discovery fixture',
 (day::date+time '20:30') at time zone 'Asia/Bahrain',
 ((day::date+time '20:30') at time zone 'Asia/Bahrain')+interval '1 hour',3000
 from generate_series(date '2098-01-01',date '2099-01-01',interval '1 day') day
 where extract(isodow from day)=2 order by day limit 41;
select set_config('test.user','10000000-0000-0000-0000-000000000001',false);
set role authenticated;
`);
await check(`select count(*)=40 and bool_and(timezone='Asia/Bahrain') from list_open_queue_games()`);
await check(`select count(*)>0 and bool_and(timezone='America/Phoenix') from list_open_queue_games_for_market('America/Phoenix')`);
await check(`select count(*)=40 and bool_and(timezone='Asia/Bahrain') from list_open_queue_games_for_market('Asia/Bahrain')`);
await check(`select bool_and(operational_state='NORMAL') and bool_and(operational_state_updated_at is not null)
 from list_open_queue_games_for_market('America/Phoenix')`);
await rejects(`select * from list_open_queue_games_for_market('Europe/London')`, /supported game market/);
await rejects(`select * from list_open_queue_games_for_market(null)`, /supported game market/);
await db.exec(`select set_config('test.user','',false)`);
await rejects(`select * from list_open_queue_games_for_market('America/Phoenix')`, /sign in again/);
await db.exec('reset role');
await check(`select not has_function_privilege('anon','public.list_open_queue_games_for_market(text)','EXECUTE')`);
await db.close();
console.log(`Fieldrush market migrations: ${checks} PostgreSQL fixture checks passed (not a full Supabase replay).`);
