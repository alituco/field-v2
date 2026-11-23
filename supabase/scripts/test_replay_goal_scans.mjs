import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const match = '10000000-0000-4000-8000-000000000001';
const event = '10000000-0000-4000-8000-000000000002';
const field = 'replay_goal_positions';
const migration = new URL('../migrations/20261123000100_replay_goal_scans.sql', import.meta.url);

async function value(sql, params = []) {
  return Object.values((await db.query(sql, params)).rows[0])[0];
}
async function as(role, op) {
  await db.exec('begin');
  try {
    await db.exec('set local role ' + role);
    return await op();
  } finally {
    await db.exec('rollback');
  }
}
const enable = (enabled) => db.query('select fieldrush_private.set_replay_scanning_enabled($1)', [enabled]);
const soloDetail = () => value('select get_open_queue_match_detail($1)', [match]);
const clanPositions = () => value('select b.replay_goal_positions from fixture_broadcasts b where fixture_id=$1', [match]);
const updateMap = (source, position) => db.query(
  "update replay_goal_scans set status='scanned', goal_positions=$1::jsonb where source_type=$2 and match_id=$3 and video_id='a'",
  [JSON.stringify({ [event]: position }), source, match]);

try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema fieldrush_private;
    alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
    create table open_queue_broadcasts(game_id uuid primary key, active_video_id text, status text, replay_hls_url text);
    create table open_queue_events(game_id uuid, event_type text);
    create table fixture_events(fixture_id uuid, event_type text);
    create table fixture_broadcasts(fixture_id uuid primary key, active_video_id text, status text, replay_hls_url text);
    grant select on fixture_broadcasts to authenticated, service_role;
    create function public.get_open_queue_match_detail(game_id_to_use uuid)
    returns jsonb language plpgsql stable security definer set search_path = public as $$
    begin
      if current_setting('test.viewer_allowed',true) = 'no' then raise exception 'viewer denied'; end if;
      return (select jsonb_build_object('private_rating',null,'broadcast',jsonb_build_object(
        'status',status,'replay_hls_url',replay_hls_url)) from open_queue_broadcasts where game_id=game_id_to_use);
    end $$;
    insert into open_queue_broadcasts values('${match}', 'a', 'REPLAY_READY', 'replay-a');
    insert into fixture_broadcasts values('${match}', 'a', 'REPLAY_READY', 'replay-a');
  `);
  const before = await soloDetail();
  await db.exec(await readFile(migration, 'utf8'));
  assert.deepEqual(await soloDetail(), before);
  assert.equal(await clanPositions(), null);
  assert.equal(await value('select count(*)::int from replay_goal_scans'), 0);

  // A project with the optional recording worker disabled keeps legacy playback.
  await db.exec("update fixture_broadcasts set status='PROCESSING'; update fixture_broadcasts set status='REPLAY_READY'");
  await db.query("insert into open_queue_events values ($1, 'GOAL')", [match]);
  assert.equal(await value('select count(*)::int from replay_goal_scans'), 0);
  await enable(true);
  await db.query("insert into open_queue_events values ($1, 'CORRECTION')", [match]);
  assert.equal(await value('select count(*)::int from replay_goal_scans'), 0);
  await db.exec("update open_queue_broadcasts set status='PROCESSING'; update fixture_broadcasts set status='PROCESSING'");
  assert.equal(await value('select count(*)::int from replay_goal_scans'), 0);
  await db.exec("update open_queue_broadcasts set status='REPLAY_READY'; update fixture_broadcasts set status='REPLAY_READY'");
  assert.equal(await value("select count(*)::int from replay_goal_scans where status='pending'"), 2);
  assert.deepEqual((await as('authenticated', soloDetail)).broadcast[field], {});
  assert.deepEqual(await as('authenticated', clanPositions), {});
  await as('service_role', async () => {
    await updateMap('SOLO', 23.5);
    assert.equal((await soloDetail()).broadcast[field][event], 23.5);
  });
  await updateMap('SOLO', 23.5);
  await updateMap('CLAN', 0);
  assert.deepEqual(await as('authenticated', soloDetail),
    { ...before, broadcast: { ...before.broadcast, [field]: { [event]: 23.5 } } });
  assert.deepEqual(await as('authenticated', clanPositions), { [event]: 0 });

  // A repeated webhook leaves any finished result in place.
  await db.exec("update open_queue_broadcasts set status='REPLAY_READY'");
  assert.equal((await soloDetail()).broadcast[field][event], 23.5);
  // Replacement uploads are queued transactionally with no inherited offsets.
  await db.exec(`update open_queue_broadcasts set active_video_id='b', replay_hls_url='replay-b';
    update fixture_broadcasts set active_video_id='b', replay_hls_url='replay-b';`);
  assert.deepEqual((await soloDetail()).broadcast[field], {});
  assert.deepEqual(await clanPositions(), {});
  // A late result for the old video cannot change the current replay's offsets.
  await updateMap('CLAN', 42);
  assert.deepEqual(await clanPositions(), {});
  assert.equal(await as('authenticated', () => value(
    "select replay_goal_positions(row($1,'a','REPLAY_READY','replay-a')::fixture_broadcasts)", [match])), null);
  assert.equal(await value("select count(*)::int from replay_goal_scans where status='scanned'"), 2);

  await db.exec("update replay_goal_scans set status='unmatched' where video_id='b'");
  assert.deepEqual((await soloDetail()).broadcast[field], {});
  // CHECK constraints reject arrays, non-event keys, negative time, and strings.
  for (const invalid of [[], { foo: 2 }, { [event]: -1 }, { [event]: '3' }, { [event]: null }]) {
    await assert.rejects(db.query("update replay_goal_scans set goal_positions=$1::jsonb where status='scanned'",
      [JSON.stringify(invalid)]), /check constraint/);
  }
  await assert.rejects(db.query("update replay_goal_scans set status='pending' where status='scanned'"), /check constraint/);
  for (const role of ['anon', 'authenticated']) {
    await assert.rejects(as(role, () => db.query('select * from replay_goal_scans')), /permission denied/);
    await assert.rejects(as(role, () => updateMap('SOLO', 999)), /permission denied/);
    await assert.rejects(as(role, () => value('select get_open_queue_match_detail_before_replay_scan($1)', [match])), /permission denied/);
  }
  await assert.rejects(as('anon', soloDetail), /permission denied/);
  const other = '10000000-0000-4000-8000-000000000002';
  await db.query("insert into fixture_broadcasts values ($1,'new','REPLAY_READY','replay-new')", [other]);
  assert.equal(await value("select status from replay_goal_scans where match_id=$1", [other]), 'pending');
  // Correcting a final score clears the old offsets. A second edit while
  // scanning invalidates the worker's compare-and-set lease on that recording.
  await db.query("insert into fixture_events values ($1, 'GOAL')", [match]);
  assert.equal(await value("select status from replay_goal_scans where source_type='CLAN' and video_id='b'"), 'pending');
  await db.query("update replay_goal_scans set next_attempt_at='2099-01-01' where source_type='CLAN' and video_id='b'");
  await db.query("insert into fixture_events values ($1, 'CORRECTION')", [match]);
  const staleWrite = await db.query("update replay_goal_scans set status='scanned' where source_type='CLAN' and video_id='b' and next_attempt_at='2099-01-01' returning video_id");
  assert.equal(staleWrite.rows.length, 0);
  assert.equal(await value("select count(*)::int from replay_goal_scans where video_id='a' and status='scanned'"), 2);

  await db.query("update replay_goal_scans set status='scanned',goal_positions=$1::jsonb where source_type='SOLO' and video_id='b'",
    [JSON.stringify({ [event]: 3 })]);
  await db.query("insert into open_queue_events values ($1, 'MATCH_ENDED')", [match]);
  assert.equal((await soloDetail()).broadcast[field][event], 3);
  await enable(false);
  assert.equal(await value("select count(*)::int from replay_goal_scans where status='pending'"), 0);
  assert.equal(await clanPositions(), null);
  assert.equal((await soloDetail()).broadcast[field][event], 3);
  // Once an analyzed score actually changes, a disabled project drops that
  // stale result without creating unserviceable pending work.
  await db.query("insert into open_queue_events values ($1, 'CORRECTION')", [match]);
  assert.equal((await soloDetail()).broadcast[field], undefined);
  assert.equal(await value("select count(*)::int from replay_goal_scans where video_id='a'"), 2);
  for (const role of ['anon', 'authenticated', 'service_role']) {
    assert.equal(await value("select has_function_privilege($1,'fieldrush_private.set_replay_scanning_enabled(boolean)','execute')", [role]), false);
  }
  await db.exec("set test.viewer_allowed = 'no'");
  await assert.rejects(as('authenticated', soloDetail), /viewer denied/);
  console.log('Passed replay goal scan publication, validation and authorization checks.');
} finally {
  await db.close();
}
