// Isolated PostgreSQL/PGlite operational regression. It runs the actual 010,
// 012 and 013 migrations and actual repository referee/admin authorization
// functions over the smallest necessary schema. It never connects to Supabase.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_match_evidence.mjs
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const {PGlite} = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
process.on('uncaughtException', error => {
  console.error(error.message);
  if (error.where) console.error(error.where);
  if (error.query) console.error(error.query.slice(0, 400));
  process.exit(1);
});
const db = new PGlite();
const migrations = new URL('../migrations/', import.meta.url);
let checks = 0;
async function scalar(sql, args = []) { return Object.values((await db.query(sql, args)).rows[0])[0]; }
async function check(sql, expected = true, args = []) { assert.deepEqual(await scalar(sql, args), expected, sql); checks++; }
async function rejects(fn, expression, label) { await assert.rejects(fn, expression, label); checks++; }
async function source(file) { return readFile(new URL(file, migrations), 'utf8'); }
async function actualFunction(file, name) {
  const sql = await source(file);
  const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'i'));
  assert.ok(start >= 0, `Missing repository function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert.ok(end >= 0);
  return sql.slice(start, end + 4);
}
const admin = randomUUID();
const referee = randomUUID();
const unassigned = randomUUID();
const inactive = randomUUID();
const outsider = randomUUID();
const people = Array.from({length: 14}, (_, i) => ({id: randomUUID(), team: i < 7 ? 'WHITE' : 'BLACK', role: i % 7 === 0 ? 'GK' : 'MID', ordinal: i}));
const sideA = people.filter(p => p.team === 'WHITE');
const sideB = people.filter(p => p.team === 'BLACK');
const firstFive = [...sideA.slice(0, 5), ...sideB.slice(0, 5)].map(p => p.id);
async function game({format = 'FIELDRUSH_7V7', future = false, booked = true} = {}) {
  const id = randomUUID();
  await db.query(`insert into public.open_queue_games(id,format_version,status,operational_state,starts_at,ends_at,teams_assigned_at)
    values($1,$2,'OPEN','NORMAL',clock_timestamp()+$3::interval,clock_timestamp()+$3::interval+interval '1 hour',clock_timestamp())`,
  [id, format, future ? '1 hour' : '-10 minutes']);
  await db.query('insert into public.open_queue_referee_assignments(game_id,referee_id) values($1,$2)', [id, referee]);
  if (booked) for (const p of people) {
    const bookingId = randomUUID();
    await db.query(`insert into public.open_queue_bookings(id,game_id,profile_id,role,team,status)
      values($1,$2,$3,$4,$5,'CONFIRMED')`, [bookingId, id, p.id, p.role, p.team]);
    await db.query('insert into public.match_attendance_records(booking_id,checked_in_at) values($1,clock_timestamp())', [bookingId]);
  }
  return id;
}
async function act(id, revision, action, actor = referee, request = randomUUID()) {
  return scalar('select public.referee_season_zero_action($1,$2,$3,$4,$5::jsonb)', [actor, id, request, revision, JSON.stringify(action)]);
}
async function state(id, actor = referee) { return scalar('select public.get_season_zero_match_state($1,$2)', [actor, id]); }
async function snapshot(id) {
  return scalar(`select jsonb_build_object(
    'state',(select to_jsonb(s) from fieldrush_rating_private.season_zero_matches s where game_id=$1),
    'clock',(select to_jsonb(c) from public.open_queue_clock_states c where game_id=$1),
    'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by request_id),'[]') from fieldrush_rating_private.season_zero_action_requests r where game_id=$1),
    'revisions',(select coalesce(jsonb_agg(to_jsonb(r) order by revision),'[]') from fieldrush_rating_private.season_zero_match_revisions r where game_id=$1),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b where game_id=$1),
    'game',(select to_jsonb(g) from public.open_queue_games g where id=$1))`, [id]);
}
async function failedAtomically(id, fn, expression, label) {
  const before = await snapshot(id);
  await rejects(fn, expression, label);
  assert.deepEqual(await snapshot(id), before, `${label}: complete transaction rollback`); checks++;
}
// Test-only time travel in the disposable runtime: no production override or
// client clock input is introduced. All operational calls still sample SQL time.
async function advanceClock(id, seconds) {
  await db.query(`update public.open_queue_clock_states set accumulated_seconds=$2,
    started_at=case when status='RUNNING' then clock_timestamp() else null end where game_id=$1`, [id, seconds]);
}
async function ageEvidence(id, seconds) {
  await db.query(`update fieldrush_rating_private.season_zero_matches set started_at=started_at-make_interval(secs=>$2),
    events=(select jsonb_agg(e || jsonb_build_object('recorded_at',(e->>'recorded_at')::timestamptz-make_interval(secs=>$2)) order by ord)
      from jsonb_array_elements(events) with ordinality x(e,ord)) where game_id=$1`, [id, seconds]);
}

try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema fieldrush_rating_private;
    create table public.profiles(id uuid primary key);
    create table public.referee_profiles(profile_id uuid primary key references public.profiles,role text,is_active boolean);
    create table public.open_queue_games(id uuid primary key,format_version text,status text,operational_state text,
      starts_at timestamptz,ends_at timestamptz,teams_assigned_at timestamptz);
    create table public.open_queue_referee_assignments(game_id uuid,referee_id uuid);
    create table public.fixture_referee_assignments(fixture_id uuid,referee_id uuid);
    create table public.fieldrush_player_rating_tracks(profile_id uuid references public.profiles,rating_track text,
      skill_rating integer,matches_played integer,primary key(profile_id,rating_track));
    create table public.open_queue_bookings(id uuid primary key,game_id uuid references public.open_queue_games,
      profile_id uuid references public.profiles,role text,team text,status text,played boolean default false,
      rating_at_match_start integer,rating_change integer,unique(game_id,profile_id));
    create table public.open_queue_clock_states(game_id uuid primary key references public.open_queue_games,
      status text,started_at timestamptz,accumulated_seconds integer,duration_seconds integer);
    create table public.match_attendance_records(booking_id uuid primary key,checked_in_at timestamptz);
    create table public.open_queue_events(id uuid default gen_random_uuid(),game_id uuid,event_type text,occurred_at timestamptz);
    create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text check(entity_type='ACTION'),
      entity_id uuid,reason text,before_state jsonb,after_state jsonb);
    create table public.match_reserve_assignments(id uuid default gen_random_uuid(),status text,match_kind text,open_queue_game_id uuid);
    create function public.referee_start_open_queue_game(uuid,uuid[],integer) returns public.open_queue_games
      language sql as $$ select * from public.open_queue_games where id=$1 $$;
  `);
  for (const [file, name] of [
    ['20260715000002_create_moderation_system.sql', 'public.is_active_moderation_admin'],
    ['20260716000002_enforce_reliability_attendance.sql', 'public.referee_can_manage_reliability_match'],
    ['20261014000200_fieldrush_independent_rating_tracks.sql', 'public.fieldrush_rating_track'],
  ]) await db.exec(await actualFunction(file, name));
  for (const id of [admin, referee, unassigned, inactive, outsider, ...people.map(p => p.id)]) await db.query('insert into public.profiles(id) values($1)', [id]);
  for (const [id, role, active] of [[admin, 'admin', true], [referee, 'referee', true], [unassigned, 'referee', true], [inactive, 'referee', false]]) {
    await db.query('insert into public.referee_profiles values($1,$2,$3)', [id, role, active]);
  }
  for (const p of people) for (const track of ['OUTFIELD', 'GOALKEEPER']) {
    await db.query('insert into public.fieldrush_player_rating_tracks values($1,$2,$3,$4)',
      [p.id, track, (track === 'GOALKEEPER' ? 1100 : 900) + p.ordinal, p.ordinal]);
  }
  // A pre-migration row must remain legacy when the column is introduced.
  const historical = await game();
  for (const file of ['20261014001000_season_zero_sr_calculator.sql', '20261014001200_season_zero_sr_timeline.sql', '20261014001300_season_zero_match_evidence.sql']) {
    await db.exec(await source(file));
  }
  await check('select enabled from fieldrush_rating_private.season_zero_activation', false);
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'LEGACY', [historical]);
  const offGame = await game();
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'LEGACY', [offGame]);
  await rejects(() => act(offGame, 0, {action: 'START', participant_ids: firstFive}), /earlier rating policy/);
  await rejects(() => scalar('select public.admin_set_season_zero_policy($1,true,$2)', [referee, 'Enable new prospective matches']), /Admin access required/);
  await rejects(() => scalar('select public.admin_set_season_zero_policy($1,true,$2)', [admin, 'short']), /at least ten/);
  await scalar('select public.admin_set_season_zero_policy($1,true,$2)', [admin, 'Enable isolated test prospective matches']);
  await check('select count(*)::integer from public.admin_audit_events', 1);
  const liveGame = await game();
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'field-sr-season0-v2', [liveGame]);
  const otherFormat = await game({format: 'LEGACY_6V6'});
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'LEGACY', [otherFormat]);
  await rejects(() => db.query("update public.open_queue_games set rating_policy_id='field-sr-season0-v2' where id=$1", [historical]), /cannot change/);
  await rejects(() => db.query("update public.open_queue_games set rating_policy_id='LEGACY' where id=$1", [liveGame]), /cannot change/);
  await scalar('select public.admin_set_season_zero_policy($1,false,$2)', [admin, 'Disable future isolated test creation']);
  const afterDisable = await game();
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'LEGACY', [afterDisable]);
  await check('select rating_policy_id from public.open_queue_games where id=$1', 'field-sr-season0-v2', [liveGame]);
  await scalar('select public.admin_set_season_zero_policy($1,true,$2)', [admin, 'Reenable isolated remaining test fixtures']);

  for (const actor of [unassigned, inactive, outsider]) {
    await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: firstFive}, actor), /not assigned/, 'unauthorized actor');
    await rejects(() => state(liveGame, actor), /not assigned/);
  }
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: [...sideA.slice(0, 4), ...sideB.slice(0, 5)].map(p => p.id)}), /five actual/, 'start below actual minimum');
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: [...firstFive, firstFive[0]]}), /Duplicate starting/, 'duplicate starter');
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: [...firstFive.slice(0, -1), outsider]}), /originally booked/, 'external starter');
  await db.query('update public.match_attendance_records set checked_in_at=null where booking_id=(select id from public.open_queue_bookings where game_id=$1 and profile_id=$2)', [liveGame, sideA[0].id]);
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: firstFive}), /check.in|checked.in/i, 'unchecked-in starter');
  await db.query('update public.match_attendance_records set checked_in_at=clock_timestamp() where checked_in_at is null');
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: firstFive, second: 1000}), /Unsupported match evidence/, 'client clock injection');
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: firstFive, sr_before: 9999}), /Unsupported match evidence/, 'client rating injection');
  const futureGame = await game({future: true});
  await failedAtomically(futureGame, () => act(futureGame, 0, {action: 'START', participant_ids: firstFive}), /scheduled kickoff/, 'future kickoff');
  await db.query('update public.open_queue_games set operational_state=null where id=$1', [liveGame]);
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'START', participant_ids: firstFive}), /locked for organizer review/, 'NULL operational state fails closed');
  await db.query("update public.open_queue_games set operational_state='NORMAL' where id=$1", [liveGame]);
  const startRequest = randomUUID();
  const startPayload = {action: 'START', participant_ids: firstFive};
  const started = await act(liveGame, 0, startPayload, referee, startRequest);
  // The declaration must not freeze wall time before an advisory/row lock wait.
  // Real lock contention still needs a multi-connection PostgreSQL check.
  const actionDefinition = await scalar("select pg_get_functiondef('public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)'::regprocedure)");
  const seasonLockAt = actionDefinition.indexOf("perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));");
  const ratingLockAt = actionDefinition.indexOf('perform fieldrush_rating_private.lock_season_zero_sr();');
  assert.ok(seasonLockAt >= 0 && seasonLockAt < ratingLockAt && ratingLockAt < actionDefinition.indexOf('where id=game_id_to_use for update;'),
    'START uses the existing season → SR → game/track lock order'); checks++;
  assert.match(actionDefinition.slice(0, ratingLockAt), /if action_name='START' then\s+perform pg_advisory_xact_lock/,
    'Only kickoff acquires the season calendar lock'); checks++;
  assert.ok(actionDefinition.indexOf('recorded:=clock_timestamp();') > actionDefinition.indexOf('where game_id=g.id for update;'), 'Timestamp is sampled after both lock acquisitions'); checks++;
  assert.equal(started.revision, 1); checks++;
  assert.equal(started.observed_roster.length, 14); checks++;
  assert.equal(started.observed_roster.find(p => p.id === sideA[0].id).sr_before, 1100); checks++;
  assert.equal(started.observed_roster.find(p => p.id === sideA[1].id).sr_before, 901); checks++;
  await check("select status from public.open_queue_games where id=$1", 'LIVE', [liveGame]);
  await check('select count(*)::integer from public.open_queue_bookings where game_id=$1 and played', 10, [liveGame]);
  assert.deepEqual(await act(liveGame, 99, startPayload, referee, startRequest), started, 'idempotent request returns exact recorded response'); checks++;
  await check('select count(*)::integer from fieldrush_rating_private.season_zero_match_revisions where game_id=$1', 1, [liveGame]);
  await failedAtomically(liveGame, () => act(liveGame, 1, {action: 'PAUSE'}, referee, startRequest), /request ID belongs/, 'idempotency key payload collision');
  await failedAtomically(liveGame, () => act(liveGame, 0, {action: 'PAUSE'}), error => error.code === '40001', 'stale revision');
  await failedAtomically(liveGame, () => act(liveGame, 1, {action: 'RETURN', profile_id: sideA[0].id}), /only ends/, 'malformed return after evidence append');
  await failedAtomically(liveGame, () => act(liveGame, 1, {action: 'QUIT', profile_id: 'not-a-uuid', note: 'Confirmed departure'}), error => error.code === '22P02', 'malformed UUID');
  await failedAtomically(liveGame, () => act(liveGame, 1, {action: 'QUIT', profile_id: sideA[0].id}), /reason for this departure/, 'missing departure reason');

  await advanceClock(liveGame, 600);
  const leave = await act(liveGame, 1, {action: 'EXCUSED_LEAVE', profile_id: sideA[4].id, note: 'Referee-approved injury absence'});
  assert.equal(leave.revision, 2); checks++;
  assert.equal(leave.audit.players[sideA[4].id].final_state, 'EXCUSED'); checks++;
  assert.equal(leave.audit.final_clock_state, 'PAUSED'); checks++;
  assert.deepEqual(leave.events.map(e => e.type), ['EXCUSED_LEAVE', 'PAUSE']); checks++;
  await check('select status from public.open_queue_clock_states where game_id=$1', 'PAUSED', [liveGame]);
  assert.equal((await state(liveGame)).elapsed_seconds, 600); checks++;
  await failedAtomically(liveGame, () => act(liveGame, 2, {action: 'RESUME'}), /five players/, 'cannot resume below five');
  await db.query('update public.match_attendance_records set checked_in_at=null where booking_id=(select id from public.open_queue_bookings where game_id=$1 and profile_id=$2)', [liveGame, sideA[5].id]);
  await failedAtomically(liveGame, () => act(liveGame, 2, {action: 'JOIN', profile_id: sideA[5].id}), /check.in|checked.in/i, 'unchecked-in late arrival');
  await db.query('update public.match_attendance_records set checked_in_at=clock_timestamp() where checked_in_at is null');
  const joined = await act(liveGame, 2, {action: 'JOIN', profile_id: sideA[5].id});
  assert.equal(joined.audit.players[sideA[5].id].final_state, 'ACTIVE'); checks++;
  assert.equal(joined.audit.final_clock_state, 'PAUSED'); checks++;
  await check('select played from public.open_queue_bookings where game_id=$1 and profile_id=$2', true, [liveGame, sideA[5].id]);
  const resumed = await act(liveGame, 3, {action: 'RESUME'});
  assert.equal(resumed.audit.final_clock_state, 'RUNNING'); checks++;

  const blue = await act(liveGame, 4, {action: 'BLUE_CARD', profile_id: sideA[0].id});
  assert.equal(blue.revision, 5); checks++;
  assert.equal(blue.audit.final_clock_state, 'PAUSED'); checks++;
  assert.equal(blue.audit.players[sideA[0].id].final_state, 'BLUE_CARD'); checks++;
  await failedAtomically(liveGame, () => act(liveGame, 5, {action: 'BLUE_RETURN', profile_id: sideA[0].id}), /120 wall seconds/, 'early blue return');
  await failedAtomically(liveGame, () => act(liveGame, 5, {action: 'RETURN', profile_id: sideA[0].id}), /only ends/, 'blue bypass via injury return');
  await failedAtomically(liveGame, () => act(liveGame, 5, {action: 'BLUE_RETURN', profile_id: sideA[0].id, recorded_at: '2099-01-01T00:00:00Z'}), /Unsupported match evidence/, 'blue timer timestamp injection');
  await ageEvidence(liveGame, 121);
  const blueReturn = await act(liveGame, 5, {action: 'BLUE_RETURN', profile_id: sideA[0].id});
  assert.equal(blueReturn.audit.players[sideA[0].id].final_state, 'ACTIVE'); checks++;
  assert.equal(blueReturn.audit.players[sideA[0].id].exit_reason, 'BLUE_CARD'); checks++;
  assert.equal(blueReturn.audit.players[sideA[0].id].retained_seconds, 0); checks++;
  assert.equal(blueReturn.audit.final_clock_state, 'PAUSED'); checks++;
  const afterBlueResume = await act(liveGame, 6, {action: 'RESUME'});
  assert.equal(afterBlueResume.audit.final_clock_state, 'RUNNING'); checks++;

  const fullGame = await game();
  await act(fullGame, 0, {action: 'START', participant_ids: people.map(p => p.id)});
  await advanceClock(fullGame, 600);
  const runningBlue = await act(fullGame, 1, {action: 'BLUE_CARD', profile_id: sideA[0].id});
  assert.equal(runningBlue.audit.final_clock_state, 'RUNNING'); checks++;
  await ageEvidence(fullGame, 121);
  await advanceClock(fullGame, 720);
  const runningReturn = await act(fullGame, 2, {action: 'BLUE_RETURN', profile_id: sideA[0].id});
  assert.equal(runningReturn.audit.players[sideA[0].id].retained_seconds, 120); checks++;
  assert.equal(runningReturn.audit.players[sideA[0].id].actual_seconds, 600); checks++;
  assert.equal(runningReturn.audit.players[sideA[0].id].rating_weight, 720); checks++;
  assert.equal(runningReturn.audit.players[sideA[1].id].protected_seconds, 0); checks++;

  await rejects(() => scalar('select public.referee_start_open_queue_game($1,$2::uuid[],3600)', [liveGame, firstFive]), /Season 0 participation controls/);
  assert.equal((await scalar('select to_jsonb(public.referee_start_open_queue_game($1,$2::uuid[],3600))', [historical, firstFive])).id, historical); checks++;
  await rejects(() => db.query("insert into public.match_reserve_assignments(status,match_kind,open_queue_game_id) values('ACTIVE','SOLO',$1)", [liveGame]), /without external replacements/);
  await db.query("insert into public.match_reserve_assignments(status,match_kind,open_queue_game_id) values('ACTIVE','SOLO',$1)", [historical]);
  await check('select count(*)::integer from public.match_reserve_assignments', 1);

  for (const fn of ['get_season_zero_match_state(uuid,uuid)', 'admin_set_season_zero_policy(uuid,boolean,text)', 'referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)']) {
    for (const role of ['anon', 'authenticated']) await check("select has_function_privilege($1,$2,'EXECUTE')", false, [role, `public.${fn}`]);
    await check("select has_function_privilege('service_role',$1,'EXECUTE')", true, [`public.${fn}`]);
  }
  for (const table of ['season_zero_matches', 'season_zero_match_revisions', 'season_zero_action_requests', 'season_zero_activation']) {
    for (const role of ['anon', 'authenticated', 'service_role']) await check("select has_table_privilege($1,$2,'SELECT,INSERT,UPDATE,DELETE')", false, [role, `fieldrush_rating_private.${table}`]);
  }
  await db.exec('set role authenticated');
  await rejects(() => state(liveGame), error => error.code === '42501', 'direct authenticated RPC denied');
  await db.exec('reset role');
  await db.exec('set role service_role');
  assert.equal((await state(liveGame)).game_id, liveGame); checks++;
  await db.exec('reset role');
  await check('select count(*)::integer from public.fieldrush_player_rating_tracks where skill_rating not between 900 and 1113', 0);
  await check('select count(*)::integer from public.open_queue_bookings where rating_change is not null', 0);
  console.log(`PASS: ${checks} Season 0 operational evidence checks, including actual referee/admin authorization, policy pins, atomic rollback, idempotency, actual-player minimum and blue-card wall-time return.`);
  console.log('NOT TESTED: Edge/API JWT relay, full historical migration replay, final settlement/replay, true multi-connection races, or referee UI. Time travel is test-only SQL in an isolated runtime; no production connection or activation occurred.');
} finally { await db.close(); }
