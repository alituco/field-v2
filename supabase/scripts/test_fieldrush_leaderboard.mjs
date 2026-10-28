// Isolated PGlite execution of the real seasonal helper, its relevant real
// reset/timezone patches, and the complete new leaderboard migration.
// This is not a full Supabase replay and never connects to a hosted database.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_fieldrush_leaderboard.mjs
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
let checks = 0;
async function check(sql, expected = true) {
  const { rows } = await db.query(sql);
  assert.deepEqual(Object.values(rows[0])[0], expected, sql);
  checks++;
}
async function rejects(sql, message) {
  await assert.rejects(db.exec(sql), message);
  checks++;
}

await db.exec(`
create role anon; create role authenticated;
create schema auth; create schema fieldrush_rating_private;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.user', true), '')::uuid
$$;
create table public.profiles(id uuid primary key, display_name text, username text,
  avatar_url text, account_deleted_at timestamptz);
create table public.player_ratings(profile_id uuid primary key references public.profiles,
  region text, ratings_reset_at timestamptz, ratings_reset_sequence bigint);
create table public.player_rating_events(profile_id uuid references public.profiles,
  effective_at timestamptz, result text, rating_after integer, rating_change integer,
  applied_sequence bigint generated always as identity);
`);
const sr = '20260713000007_create_open_queue_player_sr_system.sql';
await db.exec(await fn(sr, 'public.season_player_rating_rankings'));
// Execute the checked helper patch from the reset migration without unrelated
// match/payment mutations or hand-written substitutes for ranking behavior.
const reset = await source('20261009010000_add_player_rating_reset_periods.sql');
await db.exec(await fn('20261009010000_add_player_rating_reset_periods.sql', 'fieldrush_rating_private.patch_function'));
const resetStart = reset.indexOf('do $migration$');
const resetEnd = reset.indexOf("  perform fieldrush_rating_private.patch_function(\n    'public.get_my_season_player_rating", resetStart);
assert(resetStart >= 0 && resetEnd > resetStart);
await db.exec(reset.slice(resetStart, resetEnd) + 'end;\n$migration$;');
const market = await source('20261010000000_fieldrush_phoenix_game_format.sql');
const marketStart = market.indexOf('  foreach signature in array array[\'public.season_player_rating_rankings');
const marketEnd = market.indexOf('  end loop;', marketStart) + '  end loop;'.length;
assert(marketStart >= 0 && marketEnd > marketStart);
await db.exec('do $migration$ declare definition text; signature text; begin\n' +
  market.slice(marketStart, marketEnd)
    .replace(", 'public.get_my_season_player_rating(text,date,date)'", '') +
  '\nend; $migration$;');

await db.exec(await source('20261011000000_fieldrush_leaderboard_pages.sql'));
const page = (offset = 0, size = 23, seasonStart = '2026-10-01', seasonEnd = '2026-12-31') =>
  `public.list_fieldrush_player_rating_page('phoenix','${seasonStart}','${seasonEnd}',${offset},${size})`;
await rejects(`select ${page()}`, /sign in again/);
await db.exec(`select set_config('test.user','10000000-0000-0000-0000-000000000138',false);`);
await check(`select ${page()}->>'total_count'`, '0');
await check(`select ${page()}->'players'`, []);
await rejects(`select public.list_fieldrush_player_rating_page('bahrain','2026-10-01','2026-12-31')`, /Only the Phoenix/);
await rejects(`select ${page(0, 23, '2026-12-31', '2026-10-01')}`, /valid leaderboard season/);
await rejects(`select ${page(0, 23, '2020-01-01', '2026-12-31')}`, /valid leaderboard season/);
await db.exec(`
insert into profiles(id,display_name,username)
  select ('10000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
    'Player '||n, 'player_'||n from generate_series(1,155) n;
insert into player_ratings(profile_id,region)
  select id,case when username='player_154' then 'bahrain' else 'phoenix' end from profiles;
-- 150 placed players, two one-game placements, one deleted account, one legacy
-- market player and one current-period placement with an older rated event.
insert into player_rating_events(profile_id,effective_at,result,rating_after,rating_change)
  select p.id,'2026-10-10T03:30:00Z','WIN',2000-substring(p.username from 8)::integer,7
  from profiles p;
insert into player_rating_events(profile_id,effective_at,result,rating_after,rating_change)
  select p.id,'2026-10-11T03:30:00Z','LOSS',1993-substring(p.username from 8)::integer,-7
  from profiles p where username not in ('player_151','player_152');
update profiles set account_deleted_at=now() where username='player_153';
update player_ratings set ratings_reset_at='2026-10-11T00:00:00Z',ratings_reset_sequence=155
  where profile_id=(select id from profiles where username='player_155');
`);
await check(`select (${page()}->>'total_count')::integer`, 150);
await check(`select jsonb_array_length(${page()}->'players')`, 23);
await check(`select (${page()}->>'next_offset')::integer`, 23);
await check(`select ${page()}#>>'{players,0,rank}'`, '1');
await check(`select ${page()}#>>'{players,0,skill_rating}'`, '1992');
await check(`select ${page()}#>>'{players,0,last_change}'`, '-7');
await check(`select jsonb_array_length(${page()}->'around_me')`, 5);
await check(`select ${page()}#>>'{around_me,0,rank}'`, '136');
await check(`select ${page()}#>>'{around_me,2,profile_id}'`, '10000000-0000-0000-0000-000000000138');
await check(`select ${page()}#>>'{around_me,4,rank}'`, '140');
await check(`select jsonb_array_length(${page(103, 20)}->'players')`, 20);
await check(`select ${page(103, 20)}#>>'{players,0,rank}'`, '104');
await check(`select (${page(103, 20)}->>'next_offset')::integer`, 123);
await check(`select jsonb_array_length(${page(143, 20)}->'players')`, 7);
await check(`select ${page(143, 20)}->'next_offset'`, null);
await check(`select jsonb_array_length(${page(0, 1000)}->'players')`, 100);
await check(`select jsonb_array_length(${page(-8, -3)}->'players')`, 1);
await check(`select ${page(-8, -3)}#>>'{players,0,rank}'`, '1');
await check(`select jsonb_array_length(${page(9999, 23)}->'players')`, 0);
await check(`select ${page(9999, 23)}->'next_offset'`, null);
await check(`select jsonb_array_length(${page(0, 23, '2026-06-01', '2026-09-30')}->'players')`, 0);
await check(`select count(*) from season_player_rating_rankings('phoenix','2026-10-01','2026-12-31')
  where profile_id in (select id from profiles where username in ('player_151','player_152','player_153','player_154','player_155'))`, 0);
// A Phoenix Sep 30 event is not an Oct 1 event despite its UTC date.
await db.exec(`insert into player_rating_events(profile_id,effective_at,result,rating_after,rating_change)
  select id,'2026-10-01T03:30:00Z','WIN',2500,7 from profiles where username='player_151';`);
await check(`select (${page()}->>'total_count')::integer`, 150);
await db.exec(`select set_config('test.user','10000000-0000-0000-0000-000000000151',false);`);
await check(`select jsonb_array_length(${page()}->'around_me')`, 0);
// Permissions, including inherited PUBLIC execute, are checked by PostgreSQL.
await check(`select has_function_privilege('authenticated',
  'public.list_fieldrush_player_rating_page(text,date,date,integer,integer)','execute')`);
await check(`select not has_function_privilege('anon',
  'public.list_fieldrush_player_rating_page(text,date,date,integer,integer)','execute')`);
await db.exec(`select set_config('test.user','',false);`);
await rejects(`select ${page()}`, /sign in again/);
await db.close();
console.log(`Fieldrush leaderboard: ${checks} isolated SQL checks passed.`);
