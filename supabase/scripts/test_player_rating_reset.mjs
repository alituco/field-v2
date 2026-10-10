// Isolated PostgreSQL/PGlite regression tests; this never connects to Supabase.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_player_rating_reset.mjs
// Executes the real reset migration over the real relevant rating functions,
// with only their necessary schema. This is not a full migration replay.
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';

process.on('uncaughtException', error => {
  console.error(error.message);
  if (error.where) console.error(error.where);
  if (error.query) console.error(error.query.slice(0, 500));
  process.exit(1);
});

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const migrations = new URL('../migrations/', import.meta.url);
const base = '20260607055000_create_open_queue_and_player_ratings.sql';
const sr = '20260713000007_create_open_queue_player_sr_system.sql';
const margin = '20260715000006_add_solo_margin_sr.sql';
const reliability = '20260716000005_enforce_reliability_match_effects.sql';
const resolution = '20260730000000_create_match_resolution_control_plane.sql';
const moderation = '20260715000002_create_moderation_system.sql';
const resetMigration = '20261009010000_add_player_rating_reset_periods.sql';
async function source(file) { return readFile(new URL(file, migrations), 'utf8'); }
async function fn(file, name) {
  const sql = await source(file);
  const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'i'));
  assert(start >= 0, `Missing source function: ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= 0, `Missing function terminator: ${name}`);
  return sql.slice(start, end + 4);
}
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

await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('test.user', true), '')::uuid
$$;
create table public.profiles (
 id uuid primary key, display_name text, username text, avatar_url text,
 account_deleted_at timestamptz
);
create table public.player_ratings (
 profile_id uuid primary key references public.profiles,
 skill_rating integer not null default 1200, matches_played integer not null default 0,
 wins integer not null default 0, losses integer not null default 0,
 draws integer not null default 0, last_change integer not null default 0,
 region text not null default 'bahrain', created_at timestamptz default now(),
 updated_at timestamptz default now()
);
create table public.player_rating_events (
 id uuid primary key default gen_random_uuid(), profile_id uuid references public.profiles,
 source_type text not null, source_id uuid not null, side text not null, result text not null,
 rating_before integer not null, rating_change integer not null, rating_after integer not null,
 created_at timestamptz not null default now(), effective_at timestamptz not null default now(),
 applied_sequence bigint generated always as identity,
 rating_at_match_start integer, team_average_rating numeric, opponent_average_rating numeric,
 expected_score numeric, actual_score numeric, calculation_version text,
 score_margin integer, margin_multiplier numeric, base_rating_change integer,
 margin_bonus_before_clamp integer, margin_bonus_applied integer,
 reliability_policy_version_id uuid, attendance_outcome text,
 unique(source_type, source_id, profile_id)
);
create table public.clans(id uuid primary key, name text, wins integer default 0, losses integer default 0);
create table public.clan_members(profile_id uuid, clan_id uuid, left_at timestamptz);
create table public.fixtures (
 id uuid primary key, status text default 'SCHEDULED', match_date date, time_slot text,
 home_clan_id uuid, away_clan_id uuid, home_score integer, away_score integer,
 venue text, cancellation_context jsonb default '{}', winner_clan_id uuid
);
create table public.fixture_player_appearances (
 fixture_id uuid, profile_id uuid, clan_id uuid, side text, played boolean default false,
 rating_at_start integer default 1200, rating_change integer,
 primary key(fixture_id,profile_id)
);
create table public.fixture_clock_states (
 fixture_id uuid primary key, status text default 'NOT_STARTED', started_at timestamptz,
 accumulated_seconds integer default 0, duration_seconds integer default 3600
);
create table public.open_queue_games (
 id uuid primary key, status text default 'OPEN', starts_at timestamptz, ends_at timestamptz,
 timezone text default 'Asia/Bahrain', white_score integer, black_score integer,
 venue text, teams_assigned_at timestamptz, white_average_sr numeric,
 black_average_sr numeric, match_average_sr numeric, team_sr_spread numeric
);
create table public.open_queue_bookings (
 id uuid primary key default gen_random_uuid(), game_id uuid, profile_id uuid,
 status text default 'CONFIRMED', role text default 'DEF', team text, played boolean default false,
 player_rating_at_booking integer, rating_at_team_assignment integer,
 rating_at_match_start integer, rating_change integer,base_amount_fils integer default 13000,
 amount_paid_fils integer default 13000,refund_amount_fils integer default 0,
 refund_bps integer,refund_percent integer,refund_status text,payment_status text default 'PAID'
);
create table public.open_queue_clock_states (
 game_id uuid primary key, status text default 'NOT_STARTED', started_at timestamptz,
 accumulated_seconds integer default 0, duration_seconds integer default 3600
);
create table public.open_queue_events(game_id uuid,event_type text,occurred_at timestamptz default now(),minute integer,second integer,note text,profile_id uuid,team text);
create table public.fixture_events(fixture_id uuid,event_type text,occurred_at timestamptz default now(),minute integer,second integer,note text);
create table public.referee_profiles(profile_id uuid,role text,is_active boolean);
create table public.match_score_revisions(id uuid primary key default gen_random_uuid(),match_kind text,
 fixture_id uuid,open_queue_game_id uuid,previous_home_score integer,previous_away_score integer,
 revised_home_score integer,revised_away_score integer,reason text,revised_by uuid);
create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,
 reason text,before_state jsonb,after_state jsonb);
create table public.reliability_policy_versions(id uuid primary key,state text,effective_from timestamptz,version integer,config jsonb);
create table public.match_reliability_terms(id uuid primary key default gen_random_uuid(),match_kind text,
 open_queue_game_id uuid,fixture_id uuid,policy_version_id uuid,kickoff_at timestamptz,policy_snapshot jsonb);
create table public.match_verified_injuries(id uuid,terms_id uuid,side text,unable_to_continue boolean,
 replacement_available boolean,match_second integer,profile_id uuid);
create table public.match_shorthanded_periods(terms_id uuid,side text,reason text,started_match_second integer,ended_match_second integer);
create table public.match_attendance_records(id uuid,terms_id uuid,profile_id uuid,match_kind text,open_queue_game_id uuid,fixture_id uuid,
 outcome text,positive_sr_multiplier_bps integer,negative_sr_multiplier_bps integer,booking_id uuid,
 refund_bps integer,refund_amount_fils integer default 0,consequence_snapshot jsonb default '{}');
create table public.reliability_appeals(id uuid,attendance_id uuid,status text,reviewed_by uuid);
create table public.reliability_sr_appeal_adjustments(id uuid,appeal_id uuid);
create table public.field_wallet_accounts(profile_id uuid primary key,balance_fils bigint default 0);
create table public.field_wallet_transactions(id uuid primary key default gen_random_uuid(),profile_id uuid,
 direction text,amount_fils integer,transaction_type text,balance_after_fils bigint,idempotency_key text unique,
 policy_version_id uuid,booking_id uuid,incident_id uuid,description text,metadata jsonb);
`);
for (const [file, name] of [
  ['20260607035000_fixture_capacity_and_cancellations.sql', 'public.fixture_start_at'],
  [base, 'public.ensure_profile_player_rating'],
  [base, 'public.snapshot_fixture_player_appearances'],
  [sr, 'public.calculate_player_sr_change'],
  [sr, 'public.apply_clan_fixture_player_ratings'],
  [sr, 'public.season_player_rating_rankings'],
  [sr, 'public.get_my_season_player_rating'],
  [margin, 'public.calculate_open_queue_margin_multiplier'],
  [margin, 'public.calculate_open_queue_margin_bonus'],
  [margin, 'public.apply_open_queue_player_ratings'],
  [margin, 'public.get_player_rating_history'],
  [reliability, 'public.apply_open_queue_reliability_rating_adjustments'],
  [reliability, 'public.apply_clan_reliability_rating_adjustments'],
  [reliability, 'public.reliability_match_elapsed_seconds'],
  ['20260716000002_enforce_reliability_attendance.sql', 'public.ensure_match_reliability_terms'],
  ['20260716000002_enforce_reliability_attendance.sql', 'public.credit_field_wallet'],
  [resolution, 'public.preserve_player_sr_for_resolution_score'],
  [moderation, 'public.is_active_moderation_admin'],
  [moderation, 'public.admin_override_match_score'],
  ['20260716000013_close_reliability_release_gaps.sql', 'public.apply_late_appeal_sr_correction'],
]) await db.exec(await fn(file, name));

// Apply the checked, real effective-time patch installed after the margin
// function. Do not hand-edit the function to make the reset contract fit.
const auditedStart = await source('20260716000020_complete_audited_admin_test_matches.sql');
const effectivePatchStart = auditedStart.indexOf('do $migration$', auditedStart.indexOf('-- Rating changes happen'));
const effectivePatchEnd = auditedStart.indexOf('$migration$;', effectivePatchStart) + '$migration$;'.length;
assert(effectivePatchStart >= 0 && effectivePatchEnd > effectivePatchStart);
await db.exec(auditedStart.slice(effectivePatchStart, effectivePatchEnd));

await db.exec(`
create trigger ensure_profile_player_rating after insert on public.profiles
 for each row execute function public.ensure_profile_player_rating();
create trigger apply_clan_fixture_player_ratings after update of status on public.fixtures
 for each row execute function public.apply_clan_fixture_player_ratings();
insert into profiles(id,display_name,username) values
 ('10000000-0000-0000-0000-000000000001','Player One','one'),
 ('10000000-0000-0000-0000-000000000002','Player Two','two');
insert into open_queue_games(id,status,starts_at,ends_at,white_score,black_score) values
 ('20000000-0000-0000-0000-000000000001','FINAL',now()-interval '4 days',now()-interval '4 days'+interval '1 hour',3,1),
 ('20000000-0000-0000-0000-000000000002','FINAL',now()-interval '3 days',now()-interval '3 days'+interval '1 hour',3,1),
 -- A pre-existing early/test finalization can carry a future effective_at.
 ('20000000-0000-0000-0000-000000000007','FINAL',now()+interval '5 days',now()+interval '5 days 1 hour',1,1);
insert into open_queue_bookings(game_id,profile_id,team,played,player_rating_at_booking,rating_at_team_assignment,rating_at_match_start)
 select g.id,p.id,case when p.username='one' then 'WHITE' else 'BLACK' end,true,1200,1200,1200
 from open_queue_games g cross join profiles p;
select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000001');
select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000002');
select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000007');
select set_config('test.user','10000000-0000-0000-0000-000000000001',false);
`);
// Date windows stay valid across New Year while exercising the real generic
// season RPC contract (maximum 370 days).
const season = `current_date-180,current_date+180`;
const archivedSeason = `current_date-10,current_date-2`;
await check(`select count(*)=2 from season_player_rating_rankings('bahrain',${season})`);
await check(`select matches_played=3 and skill_rating=1224 from player_ratings where profile_id=auth.uid()`);
const originalEvents = (await db.query('select * from player_rating_events order by applied_sequence')).rows;

await db.exec(await source(resetMigration));

// Deployment is deliberately inert: only the explicit privileged operation resets.
await check(`select matches_played=3 and skill_rating=1224 and ratings_reset_at is null
 from player_ratings where profile_id=auth.uid()`);
await check(`select not has_function_privilege('anon','public.reset_player_rankings(uuid,text)','EXECUTE')
 and not has_function_privilege('authenticated','public.reset_player_rankings(uuid,text)','EXECUTE')
 and has_function_privilege('service_role','public.reset_player_rankings(uuid,text)','EXECUTE')`);

const resetId = '90000000-0000-0000-0000-000000000001';
const resetSql = `select reset_player_rankings('${resetId}','Restart staging placement') as result`;
await db.exec(`set role authenticated`);
await rejects(resetSql, /permission denied/);
await db.exec(`reset role`);
await db.exec(`
insert into open_queue_games(id,status,starts_at,ends_at,teams_assigned_at,
 white_average_sr,black_average_sr,match_average_sr,team_sr_spread) values
 ('20000000-0000-0000-0000-000000000003','FULL',now()+interval '2 days',now()+interval '2 days 1 hour',now(),1224,1176,1200,48),
 ('20000000-0000-0000-0000-000000000004','FULL',now()-interval '1 day',now()-interval '23 hours',now(),1224,1176,1200,48);
insert into open_queue_bookings(game_id,profile_id,team,player_rating_at_booking,rating_at_team_assignment)
 select g.id,p.id,case when p.username='one' then 'WHITE' else 'BLACK' end,
 r.skill_rating,r.skill_rating
 from open_queue_games g cross join profiles p join player_ratings r on r.profile_id=p.id
 where g.id in ('20000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000004');
insert into clans(id,name) values
 ('30000000-0000-0000-0000-000000000001','Clan One'),
 ('30000000-0000-0000-0000-000000000002','Clan Two');
insert into fixtures(id,match_date,time_slot,home_clan_id,away_clan_id) values
 ('40000000-0000-0000-0000-000000000001',current_date+3,'7:00 PM - 8:00 PM','30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002'),
 ('40000000-0000-0000-0000-000000000002',current_date-3,'7:00 PM - 8:00 PM','30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002');
insert into fixture_player_appearances(fixture_id,profile_id,side,clan_id,rating_at_start)
 select f.id,p.id,case when p.username='one' then 'HOME' else 'AWAY' end,
 case when p.username='one' then f.home_clan_id else f.away_clan_id end,r.skill_rating
 from fixtures f cross join profiles p join player_ratings r on r.profile_id=p.id;
`);

// A reset cannot straddle a live match or discard the frozen starting ratings.
await db.exec(`update open_queue_games set status='LIVE' where id='20000000-0000-0000-0000-000000000003'`);
await rejects(resetSql, /live|started|in.progress/i);
await db.exec(`update open_queue_games set status='FULL' where id='20000000-0000-0000-0000-000000000003';
 insert into open_queue_clock_states(game_id,status,started_at) values('20000000-0000-0000-0000-000000000003','PAUSED',now())`);
await rejects(resetSql, /live|started|in.progress/i);
await db.exec(`delete from open_queue_clock_states;
 insert into fixture_clock_states(fixture_id,status,started_at) values('40000000-0000-0000-0000-000000000001','RUNNING',now())`);
await rejects(resetSql, /live|started|in.progress/i);
await db.exec(`delete from fixture_clock_states`);
await db.exec(`insert into open_queue_events(game_id,event_type)
 values('20000000-0000-0000-0000-000000000003','MATCH_STARTED')`);
await rejects(resetSql, /live|started|in.progress/i);
await db.exec(`delete from open_queue_events where event_type='MATCH_STARTED'`);
await check(`select count(*)=0 from fieldrush_rating_private.reset_runs`);
await check(`select matches_played=3 and skill_rating=1224 from player_ratings where profile_id=auth.uid()`);

await db.exec(`set role service_role`);
const resetResult = (await db.query(resetSql)).rows[0].result;
await db.exec(`reset role`);
assert.equal(resetResult.reset_id, resetId);
assert.equal(resetResult.players_reset, 2);
checks += 2;
await check(`select bool_and(skill_rating=1200 and matches_played=0 and wins=0 and losses=0
 and draws=0 and last_change=0 and ratings_reset_at is not null) from player_ratings`);
assert.deepEqual((await db.query('select * from player_rating_events order by applied_sequence')).rows, originalEvents,
  'Reset must preserve every historical event field');
checks++;
await check(`select count(*)=2 from fieldrush_rating_private.rating_snapshots where reset_id='${resetId}'`);
await check(`select snapshot->>'skill_rating'='1224' and snapshot->>'matches_played'='3'
 from fieldrush_rating_private.rating_snapshots where reset_id='${resetId}' and profile_id=auth.uid()`);
await check(`select count(*)=5 from fieldrush_rating_private.lineup_snapshots where reset_id='${resetId}'`);
await check(`select count(*)=0 from season_player_rating_rankings('bahrain',${season})`);
await check(`select rank=0 and matches_played=0 and wins=0 and losses=0 and draws=0
 and skill_rating=1200 and last_change=0 from get_my_season_player_rating('bahrain',${season})`);
await check(`select get_player_rating_history(auth.uid())->>'ratings_reset_at' is not null
 and (get_player_rating_history(auth.uid())->>'matches_played')::integer=0
 and jsonb_array_length(get_player_rating_history(auth.uid())->'events')=3`);
await check(`select (get_player_rating_history(auth.uid())->>'ratings_reset_sequence')::bigint=6`);
await check(`select count(*)=2 from season_player_rating_rankings('bahrain',${archivedSeason})`);
await check(`select matches_played=2 and wins=2 and skill_rating=1224
 from get_my_season_player_rating('bahrain',${archivedSeason})`);
await check(`select not player_rating_source_is_current('OPEN_QUEUE','20000000-0000-0000-0000-000000000007')`);
await check(`select bool_and(player_rating_at_booking=1200 and rating_at_team_assignment=1200)
 from open_queue_bookings where game_id='20000000-0000-0000-0000-000000000003'`);
await check(`select white_average_sr=1200 and black_average_sr=1200 and match_average_sr=1200
 and team_sr_spread=0 from open_queue_games where id='20000000-0000-0000-0000-000000000003'`);
await check(`select bool_and(rating_at_start=1200) from fixture_player_appearances
 where fixture_id='40000000-0000-0000-0000-000000000001'`);
await check(`select bool_and(rating_at_team_assignment<>1200) from open_queue_bookings
 where game_id='20000000-0000-0000-0000-000000000004'`);
await check(`select bool_and(rating_at_start<>1200) from fixture_player_appearances
 where fixture_id='40000000-0000-0000-0000-000000000002'`);
const repeatedResult = (await db.query(resetSql)).rows[0].result;
assert.deepEqual(repeatedResult, { ...resetResult, already_applied: true }, 'A retry must return its original reset result');
checks++;
await check(`select count(*)=1 from fieldrush_rating_private.reset_runs`);

// Existing matches can be corrected for audit/history without becoming new placements.
await check(`select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000001')=0`);
await check(`select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000007')=0`);
// Existing committed terms and a late verified injury exercise the real refund
// path too: the reset must isolate SR without suppressing money owed to players.
await db.exec(`
insert into reliability_policy_versions(id,state,effective_from,version,config) values
 ('50000000-0000-0000-0000-000000000001','PUBLISHED',now()-interval '1 year',1,
 '{"sr":{"shorthandedQualifyingActualMinutes":10},"injury":{"halfMatchThresholdBps":5000,"incompleteRefundBps":10000,"incompleteLosingMultiplierBps":0,"incompleteWinningMultiplierBps":0}}');
insert into match_reliability_terms(id,match_kind,open_queue_game_id,policy_version_id,kickoff_at,policy_snapshot)
 select '60000000-0000-0000-0000-000000000001','SOLO',g.id,p.id,g.starts_at,p.config
 from open_queue_games g cross join reliability_policy_versions p
 where g.id='20000000-0000-0000-0000-000000000001';
insert into match_verified_injuries(id,terms_id,side,unable_to_continue,replacement_available,match_second,profile_id)
 values('70000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001','BLACK',true,false,300,'10000000-0000-0000-0000-000000000002');
`);
await check(`select apply_open_queue_reliability_rating_adjustments('20000000-0000-0000-0000-000000000001')=0`);
await check(`select count(*)=2 and sum(amount_fils)=26000 from field_wallet_transactions`);
await check(`select bool_and(balance_fils=13000) from field_wallet_accounts`);
await check(`select bool_and(refund_status='PROCESSED' and payment_status='REFUNDED')
 from open_queue_bookings where game_id='20000000-0000-0000-0000-000000000001'`);
await check(`select apply_open_queue_reliability_rating_adjustments('20000000-0000-0000-0000-000000000001')=0`);
await check(`select count(*)=2 from field_wallet_transactions`);
await db.exec(`select preserve_player_sr_for_resolution_score('SOLO','20000000-0000-0000-0000-000000000001',0,3)`);
await check(`select bool_and(skill_rating=1200 and matches_played=0 and wins=0 and losses=0 and draws=0)
 from player_ratings`);
await check(`select result='LOSS' from player_rating_events
 where source_id='20000000-0000-0000-0000-000000000001' and profile_id=auth.uid()`);
await db.exec(`insert into referee_profiles(profile_id,role,is_active) values(auth.uid(),'admin',true);
 select admin_override_match_score(auth.uid(),'SOLO','20000000-0000-0000-0000-000000000007',0,3,'Correct the recorded test match score');`);
await check(`select bool_and(matches_played=0 and wins=0 and losses=0 and draws=0 and skill_rating=1200)
 from player_ratings`);
await check(`select result='LOSS' from player_rating_events
 where source_id='20000000-0000-0000-0000-000000000007' and profile_id=auth.uid()`);
await check(`select count(*)=1 from match_score_revisions where open_queue_game_id='20000000-0000-0000-0000-000000000007'`);
// Approved appeals keep their attendance/refund decision, but an old SR event
// cannot add its former late-arrival penalty back into a fresh rating period.
await db.exec(`
insert into match_attendance_records(id,terms_id,profile_id,match_kind,open_queue_game_id)
 values('80000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001',auth.uid(),'SOLO','20000000-0000-0000-0000-000000000001');
insert into reliability_appeals(id,attendance_id,status,reviewed_by)
 values('81000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000001','OVERTURNED',auth.uid());
update player_rating_events set attendance_outcome='LATE',reliability_policy_version_id='50000000-0000-0000-0000-000000000001'
 where source_id='20000000-0000-0000-0000-000000000001' and profile_id=auth.uid();
`);
await check(`select apply_late_appeal_sr_correction(auth.uid(),'81000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000001') is null`);
await check(`select count(*)=0 from reliability_sr_appeal_adjustments`);

// Delayed finalization of an old unreported match is also outside this period.
await db.exec(`update open_queue_games set status='FINAL',white_score=2,black_score=1
 where id='20000000-0000-0000-0000-000000000004'`);
await check(`select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000004')=0`);
await db.exec(`update fixture_player_appearances set played=true where fixture_id='40000000-0000-0000-0000-000000000002';
 update fixtures set status='FINAL',home_score=2,away_score=1 where id='40000000-0000-0000-0000-000000000002'`);
await check(`select apply_clan_reliability_rating_adjustments('40000000-0000-0000-0000-000000000002')=0`);
await check(`select count(*)=6 from player_rating_events`);

// New accounts inherit the period boundary, and remain in placement themselves.
await db.exec(`insert into profiles(id,display_name,username)
 values('10000000-0000-0000-0000-000000000003','Player Three','three')`);
await check(`select skill_rating=1200 and matches_played=0 and ratings_reset_at=(
 select reset_at from fieldrush_rating_private.reset_runs where id='${resetId}')
 from player_ratings where profile_id='10000000-0000-0000-0000-000000000003'`);

// Real new solo and clan ratings take a player from 0 -> 1 -> 2 placements.
await db.exec(`update open_queue_bookings set played=true,rating_at_match_start=1200
 where game_id='20000000-0000-0000-0000-000000000003';
 update open_queue_games set status='FINAL',white_score=3,black_score=1
 where id='20000000-0000-0000-0000-000000000003';
 select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000003')`);
await check(`select matches_played=1 and wins=1 and skill_rating=1212 from player_ratings where profile_id=auth.uid()`);
await check(`select rank=0 and matches_played=1 from get_my_season_player_rating('bahrain',${season})`);
await check(`select count(*)=0 from season_player_rating_rankings('bahrain',${season})`);
await db.exec(`update fixture_player_appearances set played=true where fixture_id='40000000-0000-0000-0000-000000000001';
 update fixtures set status='FINAL',home_score=2,away_score=1 where id='40000000-0000-0000-0000-000000000001'`);
await check(`select matches_played=2 and wins=2 and skill_rating=1224 from player_ratings where profile_id=auth.uid()`);
await check(`select rank=1 and matches_played=2 and wins=2 and skill_rating=1224
 from get_my_season_player_rating('bahrain',${season})`);
await check(`select count(*)=2 from season_player_rating_rankings('bahrain',${season})`);
await check(`select apply_open_queue_player_ratings('20000000-0000-0000-0000-000000000003')=0`);
await check(`select matches_played=2 from player_ratings where profile_id=auth.uid()`);

// Retrying the previous reset after new matches must never wipe their progress.
assert.deepEqual((await db.query(resetSql)).rows[0].result, { ...resetResult, already_applied: true });
checks++;
await check(`select matches_played=2 and skill_rating=1224 from player_ratings where profile_id=auth.uid()`);
await db.exec(`set role authenticated`);
await rejects(`select * from fieldrush_rating_private.rating_snapshots`, /permission denied/);
await rejects(`select * from fieldrush_rating_private.reset_runs`, /permission denied/);
await db.exec(`reset role`);

console.log(`Player rating reset: ${checks} isolated PostgreSQL checks passed.`);
await db.close();
