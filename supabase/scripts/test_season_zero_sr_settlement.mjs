// Isolated real PostgreSQL/PGlite settlement tests; no network/hosted writes.
// Runs actual 010/012/013/014, actor permissions, snapshot and financial bodies.
// The small existing evidence harness schema is reused; legacy award/refund
// dependencies are deliberately stubbed. Full Supabase/finance integration and
// multiple-connection lock contention still require a disposable full schema.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_sr_settlement.mjs
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const {PGlite} = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
let checks = 0;
const source = name => readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
async function actual(file, name) {
  const sql = await source(file);
  const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'i'));
  const end = sql.indexOf('\n$$;', start);
  assert.ok(start >= 0 && end > start, name);
  return sql.slice(start, end + 4);
}
async function scalar(sql, args = []) { return Object.values((await db.query(sql, args)).rows[0])[0]; }
async function check(sql, expected = true, args = []) { assert.deepEqual(await scalar(sql, args), expected, sql); checks++; }
async function reject(fn, expression) { await assert.rejects(fn, expression); checks++; }
const admin = randomUUID(), referee = randomUUID(), outsider = randomUUID();
const people = Array.from({length: 14}, (_, i) => ({id: randomUUID(), team: i < 7 ? 'WHITE' : 'BLACK', role: i % 7 === 0 ? 'GK' : 'MID'}));
const pool = p => p.role === 'GK' ? 'GOALKEEPER' : 'OUTFIELD';
async function activate(enabled) {
  return scalar('select public.admin_set_season_zero_policy($1,$2,$3)', [admin, enabled, 'Disposable settlement verification activation']);
}
async function game(roster = people) {
  const id = randomUUID();
  await db.query(`insert into public.open_queue_games(id,format_version,status,operational_state,starts_at,ends_at,teams_assigned_at)
    values($1,'FIELDRUSH_7V7','OPEN','NORMAL',clock_timestamp()-interval '1 minute',clock_timestamp()+interval '59 minutes',clock_timestamp())`, [id]);
  await db.query('insert into public.open_queue_referee_assignments values($1,$2)', [id, referee]);
  for (const p of roster) {
    const booking = randomUUID();
    await db.query(`insert into public.open_queue_bookings(id,game_id,profile_id,role,team,status)
      values($1,$2,$3,$4,$5,'CONFIRMED')`, [booking,id,p.id,p.role,p.team]);
    await db.query('insert into public.match_attendance_records(booking_id,checked_in_at,open_queue_game_id,profile_id,match_kind) values($1,clock_timestamp(),$2,$3,\'SOLO\')', [booking,id,p.id]);
  }
  return id;
}
async function action(id, rev, action) { return scalar('select public.referee_season_zero_action($1,$2,$3,$4,$5::jsonb)', [referee,id,randomUUID(),rev,JSON.stringify(action)]); }
async function start(id, participants = people.map(p => p.id)) { return action(id,0,{action:'START',participant_ids:participants}); }
async function advance(id, seconds) { await db.query("update public.open_queue_clock_states set accumulated_seconds=$2,started_at=clock_timestamp() where game_id=$1", [id,seconds]); }
async function finish(id, rev = 1, request = randomUUID(), actor = referee) { return scalar('select public.referee_finish_season_zero_match($1,$2,$3,$4)', [actor,id,request,rev]); }
async function resolve(id, rev, resolution, request = randomUUID(), actor = admin) {
  return scalar('select public.admin_resolve_season_zero_match($1,$2,$3,$4,$5::jsonb)', [actor,id,request,rev,JSON.stringify(resolution)]);
}
async function track(p) { return scalar('select to_jsonb(r) from public.fieldrush_player_rating_tracks r where profile_id=$1 and rating_track=$2', [p.id,pool(p)]); }
async function fullSnapshot() {
  return scalar(`select jsonb_build_object(
    'tracks',(select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) from public.fieldrush_player_rating_tracks t),
    'events',(select jsonb_agg(to_jsonb(e) order by id) from public.player_rating_events e),
    'states',(select jsonb_agg(to_jsonb(s) order by game_id) from fieldrush_rating_private.season_zero_matches s),
    'revisions',(select jsonb_agg(to_jsonb(r) order by id) from fieldrush_rating_private.season_zero_settlement_revisions r),
    'requests',(select jsonb_agg(to_jsonb(r) order by request_id) from fieldrush_rating_private.season_zero_action_requests r),
    'clock',(select jsonb_agg(to_jsonb(c) order by game_id) from public.open_queue_clock_states c),
    'games',(select jsonb_agg(to_jsonb(g) order by id) from public.open_queue_games g))`);
}
async function rejectsAtomically(fn, error) {
  const before = await fullSnapshot(); await reject(fn,error); assert.deepEqual(await fullSnapshot(),before); checks++;
}
try {
  const evidenceHarness = await readFile(new URL('./test_season_zero_match_evidence.mjs', import.meta.url), 'utf8');
  const scaffold = evidenceHarness.match(/await db\.exec\(`([\s\S]*?)`\);/);
  assert.ok(scaffold, 'Reuse the explicit evidence-schema scaffold, never evaluate another test program');
  await db.exec(scaffold[1]);
  await db.exec(`
    alter table public.open_queue_games add column white_score integer default 0,add column black_score integer default 0,
      add column market_city_id text default 'phoenix',add column timezone text default 'America/Phoenix',
      add column season_id uuid,add column operational_state_updated_at timestamptz,add column operational_reason_code text,
      add column white_average_sr numeric,add column black_average_sr numeric,add column match_average_sr numeric,add column team_sr_spread numeric;
    create table public.fieldrush_seasons(id uuid primary key,ends_on date);
    alter table public.open_queue_bookings add column rating_at_team_assignment integer;
    alter table public.fieldrush_player_rating_tracks add column wins integer default 0,add column losses integer default 0,
      add column draws integer default 0,add column last_change integer default 0,add column rating_initialized_at timestamptz;
    alter table public.open_queue_events add column minute integer,add column second integer,add column note text;
    alter table public.open_queue_events alter column occurred_at set default clock_timestamp();
    alter table public.admin_audit_events drop constraint admin_audit_events_entity_type_check;
    alter table public.match_attendance_records add column id uuid default gen_random_uuid(),add column open_queue_game_id uuid,
      add column profile_id uuid,add column match_kind text,add column outcome text;
    create table public.open_queue_goals(id uuid default gen_random_uuid(),game_id uuid,team text);
    create table public.player_rating_events(id uuid primary key default gen_random_uuid(),profile_id uuid,source_type text,source_id uuid,
      side text,result text,rating_before integer,rating_change integer,rating_after integer,effective_at timestamptz,
      rating_at_match_start integer,team_average_rating numeric,opponent_average_rating numeric,expected_score numeric,actual_score numeric,
      calculation_version text,rating_track text,played_at timestamptz,counted_as_played boolean default false,
      market_city_id text,played_timezone text,reliability_policy_version_id uuid,unique(source_type,source_id,profile_id));
    create table public.match_reliability_terms(id uuid,policy_version_id uuid,policy_snapshot jsonb,no_show_cutoff_at timestamptz);
    create table public.match_verified_injuries(id uuid,terms_id uuid,profile_id uuid,side text,unable_to_continue boolean,
      replacement_available boolean,match_second integer);
    create table public.reliability_policy_versions(id uuid,effective_from timestamptz);
    create function public.current_player_rankings_reset_at() returns timestamptz language sql stable as $$ select '2000-01-01'::timestamptz $$;
    create function public.resolve_reliability_policy_id(timestamptz) returns uuid language sql as $$ select null::uuid $$;
    create function public.ensure_match_reliability_terms(text,uuid) returns public.match_reliability_terms language sql as $$ select row(null,null,null,null)::public.match_reliability_terms $$;
    create function public.ensure_match_attendance_records(text,uuid) returns integer language sql as $$ select 0 $$;
    create function public.finalize_match_attendance_internal(text,uuid,uuid) returns integer language sql as $$ select 0 $$;
    create function public.apply_open_queue_player_ratings(game_id_to_apply uuid) returns integer language plpgsql as $$
    declare b record; r public.fieldrush_player_rating_tracks; written uuid; begin
      for b in select * from public.open_queue_bookings where game_id=game_id_to_apply and played loop
        select * into r from public.fieldrush_player_rating_tracks where profile_id=b.profile_id and rating_track=public.fieldrush_rating_track(b.role);
        insert into public.player_rating_events(profile_id,source_type,source_id,side,result,rating_before,rating_change,rating_after,calculation_version)
          values(b.profile_id,'OPEN_QUEUE',game_id_to_apply,b.team,'WIN',r.skill_rating,12,r.skill_rating+12,'LEGACY_TEST_FIXED')
          on conflict(source_type,source_id,profile_id) do nothing returning id into written;
        if written is not null then update public.fieldrush_player_rating_tracks set skill_rating=skill_rating+12,matches_played=matches_played+1,
          wins=wins+1,last_change=12 where profile_id=b.profile_id and rating_track=r.rating_track; end if;
      end loop; return 1; end; $$;
    create function public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer) returns integer language sql as $$ select 0 $$;
    create function public.admin_override_match_score(uuid,text,uuid,integer,integer,text) returns uuid language sql as $$ select gen_random_uuid() $$;
    create function public.apply_late_appeal_sr_correction(uuid,uuid,uuid) returns uuid language sql as $$ select null::uuid $$;
    create function public.reset_player_rankings(uuid,text) returns jsonb language sql as $$ select '{}'::jsonb $$;
    -- Isolated cancellation stand-in only; the full-schema smoke exercises
    -- the actual established wallet/refund policy and its idempotency.
    create function public.admin_cancel_match(uuid,text,uuid,text,text) returns void language plpgsql as $$ begin
      update public.open_queue_bookings set status='CANCELLED' where game_id=$3;
      update public.open_queue_games set status='CANCELLED' where id=$3; end; $$;
  `);
  for (const [file,name] of [
    ['20260715000002_create_moderation_system.sql','public.is_active_moderation_admin'],
    ['20260715000002_create_moderation_system.sql','public.protect_rated_open_queue_game_inputs'],
    ['20260713000007_create_open_queue_player_sr_system.sql','public.calculate_player_sr_change'],
    ['20260716000002_enforce_reliability_attendance.sql','public.referee_can_manage_reliability_match'],
    ['20261014000200_fieldrush_independent_rating_tracks.sql','public.fieldrush_rating_track'],
    ['20261014000200_fieldrush_independent_rating_tracks.sql','public.snapshot_fieldrush_rating_event'],
    ['20260716000005_enforce_reliability_match_effects.sql','public.apply_open_queue_reliability_rating_adjustments'],
    ['20260716000020_complete_audited_admin_test_matches.sql','public.apply_open_queue_player_ratings_on_final'],
  ]) await db.exec(await actual(file,name));
  const oldDomain = await db.query(`select p,o,r,c.* from unnest(array[0,300,800,1000,1200,1700,3000]) p
    cross join unnest(array[0,300,800,1000,1200,1700,3000]) o cross join unnest(array['WIN','LOSS','DRAW']) r
    cross join lateral public.calculate_player_sr_change(p,o,r) c order by p,o,r`);
  await db.exec(`create trigger a_snapshot_fieldrush_rating_event before insert or update on public.player_rating_events for each row execute function public.snapshot_fieldrush_rating_event();
    create trigger protect_rated_open_queue_game_inputs before update or delete on public.open_queue_games for each row execute function public.protect_rated_open_queue_game_inputs();
    create trigger apply_open_queue_player_ratings_on_final after update of status on public.open_queue_games for each row execute function public.apply_open_queue_player_ratings_on_final();`);
  for (const file of ['20261014001000_season_zero_sr_calculator.sql','20261014001200_season_zero_sr_timeline.sql',
    '20261014001300_season_zero_match_evidence.sql','20261014001400_season_zero_sr_settlement.sql']) await db.exec(await source(file));
  assert.deepEqual((await db.query(`select p,o,r,c.* from unnest(array[0,300,800,1000,1200,1700,3000]) p
    cross join unnest(array[0,300,800,1000,1200,1700,3000]) o cross join unnest(array['WIN','LOSS','DRAW']) r
    cross join lateral public.calculate_player_sr_change(p,o,r) c order by p,o,r`)).rows,oldDomain.rows); checks++;
  await check("select rating_change from public.calculate_player_sr_change(-100,-100,'WIN')",12);
  await check("select rating_change from public.calculate_player_sr_change(-2147483648,2147483647,'WIN')",24);
  await check("select rating_change from public.calculate_player_sr_change(2147483647,-2147483648,'LOSS')",-24);
  for (const id of [admin,referee,outsider,...people.map(p=>p.id)]) await db.query('insert into public.profiles values($1)',[id]);
  await db.query("insert into public.referee_profiles values($1,'admin',true),($2,'referee',true)",[admin,referee]);
  for (const p of people) for (const ratingTrack of ['OUTFIELD','GOALKEEPER']) await db.query(
    'insert into public.fieldrush_player_rating_tracks(profile_id,rating_track,skill_rating,matches_played,wins) values($1,$2,1000,1,1)',[p.id,ratingTrack]);
  await activate(true);
  const first = await game(); await start(first);
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_rating_baselines',14);
  await rejectsAtomically(()=>finish(first),/agreed playing duration/);
  await rejectsAtomically(()=>finish(first,1,randomUUID(),outsider),/not assigned/);
  await advance(first,3600);
  await db.query("insert into public.open_queue_goals(game_id,team) values($1,'WHITE')",[first]);
  const request = randomUUID(); const settled = await finish(first,1,request);
  assert.equal(settled.settlement_status,'RATED'); checks++;
  assert.equal((await track(people[0])).skill_rating,1040); checks++;
  assert.equal((await track(people[7])).skill_rating,960); checks++;
  assert.equal((await track(people[0])).matches_played,2); checks++;
  await check("select skill_rating from public.fieldrush_player_rating_tracks where profile_id=$1 and rating_track='OUTFIELD'",1000,[people[0].id]);
  await check('select count(*)::integer from public.player_rating_events where source_id=$1',14,[first]);
  assert.deepEqual(await finish(first,999,request),settled); checks++;
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_settlement_revisions where game_id=$1',1,[first]);

  const second = await game(); await start(second); await advance(second,3600);
  await db.exec(`create function public.test_unchanged_projection_write() returns trigger language plpgsql as $$ begin
    if old.source_id='${first}'::uuid then raise exception 'Unchanged historical projection was rewritten'; end if; return new; end $$;
    create trigger test_unchanged_projection_write before update on public.player_rating_events for each row execute function public.test_unchanged_projection_write();`);
  await finish(second); checks++;
  await db.exec('drop trigger test_unchanged_projection_write on public.player_rating_events');
  assert.equal((await track(people[0])).skill_rating,1031); checks++;
  const observedFirst = await scalar('select observed_roster from fieldrush_rating_private.season_zero_matches where game_id=$1',[first]);
  const observedSecond = await scalar('select observed_roster from fieldrush_rating_private.season_zero_matches where game_id=$1',[second]);
  const correction = {status:'completed',winner:'B',white_score:0,black_score:1,reason:'Organizer verified the original result was reversed.'};
  await rejectsAtomically(()=>resolve(first,2,correction,randomUUID(),referee),/organizer access/);
  const corrected = await resolve(first,2,correction);
  assert.equal(corrected.settlement_status,'RATED'); checks++;
  assert.equal((await track(people[0])).skill_rating,969); checks++;
  assert.equal((await track(people[0])).matches_played,3); checks++;
  await check("select operational_state from public.open_queue_games where id=$1",'RESOLVED',[first]);
  assert.deepEqual(await scalar('select observed_roster from fieldrush_rating_private.season_zero_matches where game_id=$1',[first]),observedFirst); checks++;
  assert.deepEqual(await scalar('select observed_roster from fieldrush_rating_private.season_zero_matches where game_id=$1',[second]),observedSecond); checks++;
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_settlement_revisions where game_id=$1',2,[second]);
  await resolve(first,3,{status:'no_contest',winner:null,reason:'Verified external interruption makes the first result no contest.'});
  assert.equal((await track(people[0])).skill_rating,1000); checks++;
  assert.equal((await track(people[0])).matches_played,2); checks++;
  await check('select count(*)::integer from public.player_rating_events where source_id=$1',0,[first]);
  await resolve(first,4,{status:'pending_review',winner:null,reason:'Participation timing is disputed and requires review.'});
  await check("select operational_state from public.open_queue_games where id=$1",'UNDER_REVIEW',[first]);
  await check('select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=$1','HELD',[second]);
  await check('select count(*)::integer from public.player_rating_events',0);
  assert.equal((await track(people[0])).matches_played,1); checks++;
  await resolve(first,5,{status:'forfeit_confirmed',winner:'B',played_seconds:599,reason:'Organizer confirms intentional refusal after recorded play.'});
  await check('select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=$1','NOT_RATED',[first]);
  assert.equal((await track(people[0])).matches_played,2); checks++;
  await resolve(first,6,{status:'forfeit_confirmed',winner:'B',played_seconds:600,reason:'Organizer corrected verified conduct-forfeit clock to ten minutes.'});
  assert.equal((await track(people[0])).matches_played,3); checks++;
  assert.equal((await track(people[0])).skill_rating,969); checks++;
  await check(`select (r.calculation->>'protection_denominator')::integer from fieldrush_rating_private.season_zero_active_settlements a
    join fieldrush_rating_private.season_zero_settlement_revisions r on r.id=a.settlement_id where a.game_id=$1`,3600,[first]);

  const late = await game(); await start(late,people.slice(0,6).concat(people.slice(7)).map(p=>p.id));
  await advance(late,3001); await action(late,1,{action:'JOIN',profile_id:people[6].id});
  await advance(late,3600); await finish(late,2);
  await check('select counted_as_played from public.player_rating_events where source_id=$1 and profile_id=$2',false,[late,people[6].id]);
  await check('select rating_change from public.player_rating_events where source_id=$1 and profile_id=$2',0,[late,people[6].id]);
  const lateBefore = (await track(people[6])).matches_played;
  const lateEvents = await scalar('select events from fieldrush_rating_private.season_zero_matches where game_id=$1',[late]);
  lateEvents[0].second=3000;
  await resolve(late,3,{status:'completed',winner:null,white_score:0,black_score:0,events:lateEvents,reason:'Corrected the verified entry timestamp from 599 to 600 participation seconds.'});
  assert.equal((await track(people[6])).matches_played,lateBefore+1); checks++;
  await check('select counted_as_played from public.player_rating_events where source_id=$1 and profile_id=$2',true,[late,people[6].id]);

  // New awards/markers/ledger rows must all roll back after a mid-write failure.
  const failure = await game(); await start(failure); await advance(failure,3600);
  await db.exec(`create function public.test_fail_rating_write() returns trigger language plpgsql as $$ begin
    if new.profile_id='${people[5].id}'::uuid and new.matches_played>old.matches_played then raise exception 'Injected rating persistence failure'; end if;
    return new; end; $$;
    create trigger z_test_fail_rating_write before update on public.fieldrush_player_rating_tracks for each row execute function public.test_fail_rating_write();`);
  await rejectsAtomically(()=>finish(failure),/Injected rating persistence failure/);
  await db.exec('drop trigger z_test_fail_rating_write on public.fieldrush_player_rating_tracks');
  await finish(failure);
  await check('select count(*)::integer from public.player_rating_events where source_id=$1',14,[failure]);

  // Existing/future legacy policy stays pinned. Its actual +12 movement and
  // appearance are journaled once, never recalculated by a v2 correction.
  await activate(false); const legacy = await game();
  await db.query('update public.open_queue_bookings set played=true where game_id=$1 and profile_id=$2',[legacy,people[0].id]);
  const runsBeforeLegacy = await scalar('select count(*)::integer from fieldrush_rating_private.season_zero_settlement_runs');
  // This actual FINAL trigger has no reliability policy/overlay in the isolated
  // schema; its fixed base award must still replay all chronologically later v2.
  await db.query("update public.open_queue_games set status='FINAL' where id=$1",[legacy]);
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_settlement_runs',runsBeforeLegacy+1);
  await check(`select (p->>'sr_before')::integer from fieldrush_rating_private.season_zero_active_settlements a
    join fieldrush_rating_private.season_zero_settlement_revisions s on s.id=a.settlement_id
    cross join lateral jsonb_array_elements(s.input_snapshot->'roster') p where a.game_id=$1 and p->>'id'=$2`,1012,[first,people[0].id]);
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_legacy_movements',1);
  // Replayed old projections may have newer IDs than later matches. Historical
  // SR must use chronological active deltas + fixed legacy movements instead.
  const seasonOne = randomUUID(), seasonTwo = randomUUID();
  await db.query("insert into public.fieldrush_seasons values($1,'2026-10-31'),($2,'2026-11-30')",[seasonOne,seasonTwo]);
  await db.query('update public.open_queue_games set season_id=$1 where id=$2',[seasonOne,first]);
  await db.query('update public.open_queue_games set season_id=$1 where id<>$2',[seasonTwo,first]);
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_track_rating_at($1,$2,$3)',0,[people[0].id,pool(people[0]),'2026-09-30']);
  await check('select skill_rating from fieldrush_rating_private.season_zero_track_rating_at($1,$2,$3)',960,[people[0].id,pool(people[0]),'2026-10-31']);
  await check('select skill_rating from fieldrush_rating_private.season_zero_track_rating_at($1,$2,$3)',(await track(people[0])).skill_rating,[people[0].id,pool(people[0]),'2026-11-30']);
  const legacyAward = await scalar('select to_jsonb(e) from public.player_rating_events e where source_id=$1',[legacy]);
  await resolve(first,7,{status:'no_contest',winner:null,reason:'Final organizer review resolves the first contest as externally interrupted.'});
  await check('select skill_rating from fieldrush_rating_private.season_zero_track_rating_at($1,$2,$3)',1000,[people[0].id,pool(people[0]),'2026-10-31']);
  await check('select skill_rating from fieldrush_rating_private.season_zero_track_rating_at($1,$2,$3)',(await track(people[0])).skill_rating,[people[0].id,pool(people[0]),'2026-11-30']);
  assert.deepEqual(await scalar('select to_jsonb(e) from public.player_rating_events e where source_id=$1',[legacy]),legacyAward); checks++;
  await check('select rating_change from public.player_rating_events where source_id=$1',12,[legacy]);
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_legacy_movements',1);
  await reject(()=>db.query('update public.fieldrush_player_rating_tracks set skill_rating=0 where profile_id=$1 and rating_track=$2',[people[0].id,pool(people[0])]),/replay baseline/);
  await reject(()=>scalar('select public.reset_player_rankings($1,$2)',[randomUUID(),'Unapproved reset test']),/cannot be reset/);
  await reject(()=>db.query('update fieldrush_rating_private.season_zero_settlement_revisions set status=\'HELD\''),/append-only/);
  for (const fn of ['referee_finish_season_zero_match(uuid,uuid,uuid,integer)','admin_resolve_season_zero_match(uuid,uuid,uuid,integer,jsonb)']) {
    for (const role of ['anon','authenticated']) await check("select has_function_privilege($1,$2,'EXECUTE')",false,[role,`public.${fn}`]);
    await check("select has_function_privilege('service_role',$1,'EXECUTE')",true,[`public.${fn}`]);
  }
  await check("select has_function_privilege('service_role','fieldrush_rating_private.replay_season_zero_ratings(uuid,uuid,text)','EXECUTE')",false);
  // Real safety recorder/watchdog with explicitly minimal moderation tables.
  await db.exec(`alter table public.open_queue_goals add column profile_id uuid,add column assist_profile_id uuid;
    create table public.match_stoppages(id uuid primary key default gen_random_uuid(),match_kind text,fixture_id uuid,open_queue_game_id uuid,
      stopped_by uuid,mode text,reason_code text,note text,elapsed_seconds integer);
    create table public.moderation_reports(id uuid primary key default gen_random_uuid(),reporter_referee_id uuid,source text,subject_type text,
      fixture_id uuid,open_queue_game_id uuid,category text,details text,replay_offset_seconds integer,priority text);
    create function public.referee_complete_open_queue_game(uuid) returns integer language plpgsql as $$ begin
      update public.open_queue_games set status='FINAL' where id=$1; return 1; end; $$;`);
  await db.exec(await actual('20260715000002_create_moderation_system.sql','public.referee_record_match_stoppage'));
  await db.exec(await actual('20260713000006_create_open_queue_match_control.sql','public.auto_stop_overdue_open_queue_clocks'));
  await db.exec(await actual('20260716000002_enforce_reliability_attendance.sql','public.require_checked_in_match_participant'));
  await db.exec(await source('20261014001700_season_zero_safety_review.sql'));
  await db.exec('create trigger require_checked_in_solo_participant before insert or update of played on public.open_queue_bookings for each row execute function public.require_checked_in_match_participant()');
  await activate(true);
  await check("select public.admin_get_season_zero_policy($1)->>'enabled'",'true',[admin]);
  await reject(()=>scalar('select public.admin_get_season_zero_policy($1)',[referee]),/organizer access/);
  const safety = await game(); await start(safety); await advance(safety,100);
  await rejectsAtomically(()=>db.query("update public.open_queue_bookings set team='BLACK' where game_id=$1 and profile_id=$2",[safety,people[0].id]),/do not replace/);
  await rejectsAtomically(()=>db.query("update public.open_queue_bookings set status='CANCELLED' where game_id=$1 and profile_id=$2",[safety,people[0].id]),/do not replace/);
  await rejectsAtomically(()=>db.query("update public.open_queue_bookings set role='ATT' where game_id=$1 and profile_id=$2",[safety,people[0].id]),/do not replace/);
  await rejectsAtomically(()=>db.query('delete from public.open_queue_bookings where game_id=$1',[safety]),/frozen after kickoff/);
  await rejectsAtomically(()=>db.query("insert into public.open_queue_bookings(id,game_id,profile_id,role,team,status) values($1,$2,$3,'ATT','WHITE','CONFIRMED')",[randomUUID(),safety,outsider]),/frozen after kickoff/);
  await rejectsAtomically(()=>db.query("update public.open_queue_games set status='CANCELLED' where id=$1",[safety]),/organizer review/);
  await rejectsAtomically(()=>db.query("update fieldrush_rating_private.season_zero_matches set observed_roster='[]' where game_id=$1",[safety]),/kickoff snapshot is immutable/);
  await rejectsAtomically(()=>db.query('delete from fieldrush_rating_private.season_zero_action_requests where game_id=$1',[safety]),/append-only/);
  await rejectsAtomically(()=>db.query('delete from fieldrush_rating_private.season_zero_match_revisions where game_id=$1',[safety]),/append-only/);
  async function goal(id, player = people[0], assist = null) {
    return db.query('insert into public.open_queue_goals(game_id,team,profile_id,assist_profile_id) values($1,$2,$3,$4)',[id,player.team,player.id,assist]);
  }
  async function stop(id, rev, mode = 'TEMPORARY', request = randomUUID(), actor = referee) {
    return scalar('select public.referee_stop_season_zero_match($1,$2,$3,$4,$5,$6,$7)',[actor,id,request,rev,mode,'UNSAFE_VENUE_OR_WEATHER','Verified unsafe condition']);
  }
  await goal(safety); checks++;
  await rejectsAtomically(()=>stop(safety,1,'TEMPORARY',randomUUID(),outsider),/not assigned/);
  const safetyRequest=randomUUID(); const paused=await stop(safety,1,'TEMPORARY',safetyRequest);
  assert.equal(paused.lifecycle,'LIVE'); checks++;
  assert.equal(paused.settlement_status,'HELD'); checks++;
  assert.deepEqual(await stop(safety,999,'TEMPORARY',safetyRequest),paused); checks++;
  await check("select status from public.open_queue_clock_states where game_id=$1",'PAUSED',[safety]);
  await check('select count(*)::integer from public.match_stoppages where open_queue_game_id=$1',1,[safety]);
  await check('select count(*)::integer from public.moderation_reports where open_queue_game_id=$1',1,[safety]);
  await reject(()=>goal(safety),/running Season 0/);
  await action(safety,2,{action:'RESUME'});
  await action(safety,3,{action:'EXCUSED_LEAVE',profile_id:people[0].id,note:'Verified injury'});
  await reject(()=>goal(safety),/actually be active/);
  await reject(()=>goal(safety,people[1],people[0].id),/actually be active/);
  await goal(safety,people[1]); checks++;
  await reject(()=>scalar('select public.referee_record_match_stoppage($1,\'SOLO\',$2,\'ABANDON\',\'TEAM_WALKOUT\',null)',[referee,safety]),/revisioned Season 0/);
  const abandoned=await stop(safety,4,'ABANDON');
  assert.equal(abandoned.lifecycle,'REVIEW'); checks++;
  await check("select operational_state from public.open_queue_games where id=$1",'UNDER_REVIEW',[safety]);
  await check("select status from public.open_queue_games where id=$1",'LIVE',[safety]);
  await check('select count(*)::integer from public.player_rating_events where source_id=$1',0,[safety]);
  await rejectsAtomically(()=>finish(safety,5),/unlocked live/);
  await resolve(safety,5,{status:'no_contest',winner:null,reason:'Organizer confirms venue interruption was external.'});
  await check("select operational_state from public.open_queue_games where id=$1",'RESOLVED',[safety]);
  const overdue=await game(); await start(overdue); await advance(overdue,10800);
  await check('select public.auto_stop_overdue_open_queue_clocks()',1);
  await check("select lifecycle from fieldrush_rating_private.season_zero_matches where game_id=$1",'REVIEW',[overdue]);
  await check("select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=$1",'HELD',[overdue]);
  await check("select status from public.open_queue_games where id=$1",'LIVE',[overdue]);
  await check('select count(*)::integer from public.player_rating_events where source_id=$1',0,[overdue]);
  await check('select public.auto_stop_overdue_open_queue_clocks()',0);
  await check("select count(*)::integer from fieldrush_rating_private.season_zero_match_revisions where game_id=$1 and actor_id is null and action='SYSTEM_CLOCK_REVIEW'",1,[overdue]);
  const independent = people.map(p=>({...p,id:randomUUID()}));
  for (const p of independent) {
    await db.query('insert into public.profiles values($1)',[p.id]);
    for(const t of ['OUTFIELD','GOALKEEPER']) await db.query('insert into public.fieldrush_player_rating_tracks(profile_id,rating_track,skill_rating,matches_played) values($1,$2,1000,1)',[p.id,t]);
  }
  // An unresolved A must not hold C through a final independently unrated
  // A/C match. Test each independent no-rating reason, including 599s forfeit.
  for(const status of ['no_contest','unranked','cancelled','forfeit_confirmed']) {
    const bridgeRoster=[people[0],...independent.slice(1)];
    const bridge=await game(bridgeRoster); await start(bridge,bridgeRoster.map(p=>p.id));
    await resolve(bridge,1,{status,winner:status==='forfeit_confirmed'?'A':null,played_seconds:599,reason:'Independent final no-rating decision must not propagate another participant hold.'});
    await check('select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=$1','NOT_RATED',[bridge]);
    const later=await game(independent); await start(later,independent.map(p=>p.id)); await advance(later,3600); await finish(later);
    await check('select settlement_status from fieldrush_rating_private.season_zero_matches where game_id=$1','RATED',[later]);
  }
  for (const fn of ['referee_stop_season_zero_match(uuid,uuid,uuid,integer,text,text,text)','admin_get_season_zero_policy(uuid)']) {
    for (const role of ['anon','authenticated']) await check("select has_function_privilege($1,$2,'EXECUTE')",false,[role,`public.${fn}`]);
    await check("select has_function_privilege('service_role',$1,'EXECUTE')",true,[`public.${fn}`]);
  }
  console.log(`PASS: ${checks} settlement checks: exact awards, separate pools, finish idempotency, chronological dependent correction, lifetime count/reveal rollback, transitive holds, forfeit 599/600, late-entry correction, atomic persistence rollback, fixed legacy awards, no reset, immutable audit and authorization.`);
} catch (error) {
  console.error(error.message);
  if (error.where) console.error(error.where);
  if (error.query) console.error(error.position ? error.query.slice(Math.max(0,Number(error.position)-250),Number(error.position)+250) : error.query.slice(0,500));
  process.exitCode=1;
} finally { await db.close(); }
