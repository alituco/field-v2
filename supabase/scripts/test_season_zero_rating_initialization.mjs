// Isolated PostgreSQL/PGlite regression; no network or hosted database access.
// Uses the repository's real account RPC bodies, calculator migration, and
// initialization migration with minimal dependencies. It is NOT a substitute
// for replaying the full migration chain against local Supabase.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_rating_initialization.mjs
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const readMigration = name => readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
const accounts = await readMigration('20261009000000_create_fieldrush_accounts.sql');
const tracks = await readMigration('20261014000200_fieldrush_independent_rating_tracks.sql');
const cities = await readMigration('20261014000100_fieldrush_city_catalog.sql');
function definition(source, name) {
  const start = source.indexOf(`create function ${name}(`);
  assert.notEqual(start, -1, `Existing real function ${name}`);
  const end = source.indexOf('\n$$;', start);
  assert.notEqual(end, -1, `Complete real function ${name}`);
  return source.slice(start, end + 4);
}
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private; create schema fieldrush_rating_private;
    revoke all on schema fieldrush_private,fieldrush_rating_private from public,anon,authenticated;
    create table auth.users(id uuid primary key,phone text,phone_confirmed_at timestamptz,email text,
      email_confirmed_at timestamptz,deleted_at timestamptz,banned_until timestamptz,raw_user_meta_data jsonb);
    create table auth.identities(user_id uuid,provider text);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
    $$;
    grant usage on schema auth to authenticated;
    create table public.profiles(id uuid primary key,auth_user_id uuid,display_name text,username text unique,
      phone text,date_of_birth date);
    create table fieldrush_private.accounts(user_id uuid primary key references auth.users(id),first_name text,
      last_name text,username text,date_of_birth date,email text,status text default 'onboarding',
      onboarding_completed_at timestamptz,tour_completed_at timestamptz,created_at timestamptz default now(),
      updated_at timestamptz default now(),preferred_city_id text default 'phoenix');
    create table fieldrush_private.reserved_usernames(normalized_name text primary key);
    create table fieldrush_private.legal_acceptances(user_id uuid,document text,version text,
      accepted_at timestamptz default now(),primary key(user_id,document,version));
    create table public.fieldrush_cities(id text,display_name text,state text,timezone text,active boolean);
    insert into public.fieldrush_cities values('phoenix','Phoenix','AZ','America/Phoenix',true);
    create table fieldrush_rating_private.reset_runs(reset_at timestamptz,last_applied_sequence bigint);
    insert into fieldrush_rating_private.reset_runs values(now(),0);
    create function public.current_player_rankings_reset_at() returns timestamptz language sql stable as $$ select now(); $$;
    create table public.player_ratings(profile_id uuid primary key,skill_rating integer default 1200,matches_played integer default 0,
      wins integer default 0,losses integer default 0,draws integer default 0,last_change integer default 0,
      ratings_reset_at timestamptz,ratings_reset_sequence bigint);
    create table public.player_rating_events(id uuid primary key default gen_random_uuid(),profile_id uuid);
  `);
  const tracksStart = tracks.indexOf('create table public.fieldrush_player_rating_tracks (');
  await db.exec(tracks.slice(tracksStart, tracks.indexOf('\n);', tracksStart) + 3));
  for (const name of ['fieldrush_private.require_user','fieldrush_private.validate_draft','public.get_my_fieldrush_account',
    'public.save_fieldrush_onboarding_draft','fieldrush_private.write_account','public.complete_fieldrush_onboarding',
    'public.update_my_fieldrush_account','public.is_fieldrush_account_active']) {
    await db.exec(definition(accounts, name));
  }
  await db.exec(`alter function public.get_my_fieldrush_account() rename to get_my_fieldrush_account_before_cities;
    revoke all on function public.get_my_fieldrush_account_before_cities() from public,anon,authenticated;`);
  await db.exec(definition(cities, 'public.get_my_fieldrush_account'));
  await db.exec(definition(tracks, 'public.ensure_fieldrush_rating_tracks'));
  await db.exec(definition(tracks, 'public.sync_legacy_outfield_rating'));
  await db.exec(`
    create function public.test_seed_legacy_rating() returns trigger language plpgsql as $$ begin
      insert into public.player_ratings(profile_id) values(new.id); return new; end; $$;
    create trigger a_test_seed_legacy_rating after insert on public.profiles for each row execute function public.test_seed_legacy_rating();
    create trigger ensure_fieldrush_rating_tracks after insert on public.profiles for each row execute function public.ensure_fieldrush_rating_tracks();
    create trigger sync_legacy_outfield_rating after insert or update on public.fieldrush_player_rating_tracks for each row execute function public.sync_legacy_outfield_rating();
    revoke all on all functions in schema fieldrush_private from public,anon,authenticated;
    revoke all on public.fieldrush_player_rating_tracks from public,anon,authenticated;
  `);
  await db.exec(await readMigration('20261014001000_season_zero_sr_calculator.sql'));
  await db.exec(await readMigration('20261014001100_season_zero_rating_initialization.sql'));
  const tests = await readFile(new URL('./verify_season_zero_rating_initialization.sql', import.meta.url), 'utf8');
  const results = await db.exec(tests);
  assert.ok(results.some(r => r.rows?.some(row => row.result === 'Season 0 once-only initialization verification passed.')));
  console.log('PASS: six assessment seeds, both role pools, legacy completed/incomplete preservation, retries, immutable audit, auth/field spoofing, private permissions, unseeded gate, and rollback checks.');
} finally {
  await db.close();
}
