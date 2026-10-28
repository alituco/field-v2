// Isolated PostgreSQL behavior checks. No network, hosted data, Auth provisioning,
// payment provider or delivery worker is used by this verifier.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_staging_game_bots.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const source = name => readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
const admin = '10000000-0000-4000-8000-000000000001';
const player = '10000000-0000-4000-8000-000000000002';
const inactive = '10000000-0000-4000-8000-000000000003';
let checks = 0;
function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`));
  assert(start >= 0, `Missing installed function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end > start);
  return sql.slice(start, end + 4);
}
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) { assert.deepEqual(await value(sql), expected, sql); checks++; }
async function rejects(sql, pattern) { await assert.rejects(db.exec(sql), pattern); checks++; }
const uuid = () => value('select gen_random_uuid()');
const fill = (game, request, actor = admin) => `select admin_fill_open_queue_game_with_bots(${q(actor)},${q(game)},${q(request)})`;
async function game(extra = {}) {
  const data = { starts_at: '2090-01-01 UTC', ...extra };
  return value(`insert into open_queue_games(${Object.keys(data).join(',')}) values(${Object.values(data).map(q).join(',')}) returning id`);
}
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private; create schema fieldrush_rating_private;
    create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role',true)$$;
    select set_config('request.jwt.claim.role','service_role',false);
    create table auth.users(id uuid primary key,phone text,phone_confirmed_at timestamptz,deleted_at timestamptz,banned_until timestamptz);
    create table profiles(id uuid primary key,auth_user_id uuid unique references auth.users(id),account_deleted_at timestamptz,
      display_name text not null,username text unique,phone text,updated_at timestamptz default now());
    create table fieldrush_private.accounts(user_id uuid primary key references auth.users(id),status text,onboarding_completed_at timestamptz);
    create table referee_profiles(profile_id uuid primary key references profiles(id),role text,is_active boolean);
    create function is_active_moderation_admin(uuid) returns boolean language sql stable as $$
      select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)$$;
    create table admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'OPEN',
      format_version text default 'FIELDRUSH_7V7',rating_policy_id text default 'LEGACY',operational_state text default 'NORMAL',
      starts_at timestamptz,capacity integer default 14,goalkeeper_capacity integer default 2,defender_capacity integer default 4,
      midfielder_capacity integer default 0,attacker_capacity integer default 8,white_score integer,black_score integer,
      teams_assigned_at timestamptz,white_average_sr numeric,black_average_sr numeric,match_average_sr numeric,team_sr_spread numeric,
      highest_division integer default 1,lowest_division integer default 5,currency text default 'USD',
      check(goalkeeper_capacity+defender_capacity+midfielder_capacity+attacker_capacity=capacity));
    create table open_queue_clock_states(game_id uuid primary key,status text,started_at timestamptz,accumulated_seconds integer);
    create table fieldrush_rating_private.season_zero_matches(game_id uuid primary key);
    create table fieldrush_rating_private.reset_runs(reset_at timestamptz,last_applied_sequence bigint);
    insert into fieldrush_rating_private.reset_runs values(now()-interval '1 day',0);
    create table fieldrush_player_rating_tracks(profile_id uuid references profiles(id),rating_track text,skill_rating integer default 1200,
      matches_played integer default 0,ratings_reset_at timestamptz,ratings_reset_sequence bigint,primary key(profile_id,rating_track));
    create function fieldrush_division_for_rating(integer) returns integer language sql immutable as $$select case when $1>=1600 then 3 else 4 end$$;
    create table payment_intents(id uuid primary key default gen_random_uuid(),purpose text default 'SOLO_BOOKING',status text,
      payload jsonb,provider text default 'STRIPE',provider_intent_id text,provider_payment_id text,expires_at timestamptz default now()-interval '1 day');
    create table payment_refunds(id uuid primary key); create table field_wallet_transactions(id uuid primary key);
    create table notifications(id uuid primary key); create table push_deliveries(id uuid primary key);
    create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid references open_queue_games(id),
      profile_id uuid references profiles(id),role text,status text default 'CONFIRMED',team text,played boolean default false,
      player_rating_at_booking integer not null,booked_at timestamptz default now(),
      rating_at_team_assignment integer,rating_at_match_start integer,rating_change integer,
      amount_paid_fils integer not null,base_amount_fils integer not null,discount_bps integer default 0,
      reliability_deposit_fils integer default 0,reliability_deposit_status text default 'NOT_REQUIRED',payment_method text,
      payment_reference text,payment_intent_id uuid,provider_payment_id text,updated_at timestamptz default now());
    create unique index open_queue_active_booking_unique_idx on open_queue_bookings(game_id,profile_id) where status='CONFIRMED';
    create table assignment_calls(game_id uuid);
    create function assign_open_queue_teams(uuid) returns void language plpgsql as $$begin
      insert into assignment_calls values($1);
      update open_queue_games set teams_assigned_at=now() where id=$1;
      update open_queue_bookings set team='WHITE' where game_id=$1 and status='CONFIRMED';
    end$$;
    create function reassign_open_queue_teams_after_party_change(game_id_to_reassign uuid) returns void language plpgsql as $$begin
      return;
    end$$;
  `);
  const accounts = await source('20261009000000_create_fieldrush_accounts.sql');
  await db.exec(fn(accounts, 'public.is_fieldrush_account_active'));
  await db.exec(fn(accounts, 'fieldrush_private.require_completed_participant'));
  await db.exec(`create trigger fieldrush_booking_account before insert on open_queue_bookings
    for each row execute function fieldrush_private.require_completed_participant('profile_id')`);
  const tracks = await source('20261014000200_fieldrush_independent_rating_tracks.sql');
  await db.exec(fn(tracks, 'public.fieldrush_rating_track'));
  await db.exec(fn(tracks, 'public.ensure_fieldrush_rating_tracks'));
  await db.exec(fn(tracks, 'public.snapshot_fieldrush_booking_rating'));
  await db.exec(`create trigger ensure_fieldrush_rating_tracks after insert on profiles for each row execute function ensure_fieldrush_rating_tracks();
    create trigger a_snapshot_fieldrush_booking_rating before insert on open_queue_bookings for each row execute function snapshot_fieldrush_booking_rating()`);
  await db.exec(fn(await source('20261014001500_lifetime_rating_visibility.sql'), 'public.assert_open_queue_division_eligibility'));
  await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'), 'public.enforce_open_queue_booking_capacity'));
  await db.exec(`create trigger enforce_open_queue_booking_capacity before insert on open_queue_bookings
    for each row execute function enforce_open_queue_booking_capacity();
    create function check_division() returns trigger language plpgsql as $$begin
      perform assert_open_queue_division_eligibility(new.profile_id,new.game_id,new.role); return new; end$$;
    create trigger enforce_division before insert on open_queue_bookings for each row execute function check_division()`);
  await db.exec(fn(await source('20260713000007_create_open_queue_player_sr_system.sql'), 'public.sync_open_queue_game_status'));
  const partial = await source('20261014001800_season_zero_partial_assignment.sql');
  const syncAt = partial.indexOf("d:=pg_get_functiondef('public.sync_open_queue_game_status()'::regprocedure)");
  const blockStart = partial.lastIndexOf('do $migration$', syncAt);
  const blockEnd = partial.indexOf('$migration$;', syncAt);
  await db.exec(partial.slice(blockStart, blockEnd + 13));
  await db.exec(`create trigger sync_open_queue_game_status after insert or update of status or delete on open_queue_bookings
    for each row execute function sync_open_queue_game_status();
    create function touch_booking() returns trigger language plpgsql as $$begin new.updated_at=clock_timestamp(); return new; end$$;
    create trigger touch_booking before update on open_queue_bookings for each row execute function touch_booking()`);
  await db.exec(await source('20261019000300_admin_staging_game_bots.sql'));
  for (const [id, role, active] of [[admin,'admin',true],[player,'referee',true],[inactive,'admin',false]]) {
    await db.exec(`insert into auth.users values(${q(id)},'15550000000',now(),null,null);
      insert into profiles(id,auth_user_id,display_name,username) values(${q(id)},${q(id)},'Real fixture','real_${id.slice(-3)}');
      insert into fieldrush_private.accounts values(${q(id)},'active',now());
      insert into referee_profiles values(${q(id)},${q(role)},${active})`);
  }
  const initial = await game();
  await rejects(fill(initial, await uuid()), /not enabled/);
  await check(`select count(*)::int from profiles`, 3);
  await check(`select has_table_privilege('service_role','fieldrush_private.staging_bot_controls','UPDATE')`, false);
  for (const role of ['anon','authenticated']) await check(`select has_function_privilege(${q(role)},'public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid)','EXECUTE')`, false);
  await check(`select has_function_privilege('service_role','public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid)','EXECUTE')`);
  await db.exec(`update fieldrush_private.staging_bot_controls set enabled=true where singleton`);
  for (const actor of [player,inactive]) await rejects(fill(initial, await uuid(), actor), /administrator/);
  await db.exec(`select set_config('request.jwt.claim.role','authenticated',false)`);
  await rejects(fill(initial, await uuid()), /administrator/);
  await db.exec(`select set_config('request.jwt.claim.role','service_role',false)`);
  for (const policy of ['LEGACY','field-sr-season0-v2']) {
    const target = await game({ rating_policy_id: policy, highest_division: 2, lowest_division: 3 });
    // A real player already occupies a position. Bot fill must preserve every
    // field, including update timestamps, amount paid and provider linkage.
    await db.exec(`update fieldrush_player_rating_tracks set matches_played=2,skill_rating=1800 where profile_id=${q(player)};
      insert into open_queue_bookings(game_id,profile_id,role,player_rating_at_booking,amount_paid_fils,base_amount_fils,payment_method,payment_reference)
      values(${q(target)},${q(player)},'DEF',1200,8000,8000,'CARD','real-provider-reference')`);
    const before = await value(`select to_jsonb(b) from open_queue_bookings b where game_id=${q(target)} and profile_id=${q(player)}`);
    const request = await uuid();
    const result = await value(fill(target, request));
    assert.equal(result.createdBots, 13); checks++;
    assert.equal(result.alreadyFilled, false); checks++;
    await check(`select count(*)::int from open_queue_bookings where game_id=${q(target)} and status='CONFIRMED'`, 14);
    await check(`select jsonb_object_agg(role,n) from(select role,count(*) n from open_queue_bookings where game_id=${q(target)} group by role) x`, {GK:2,DEF:4,ATT:8});
    assert.deepEqual(await value(`select to_jsonb(b) from open_queue_bookings b where game_id=${q(target)} and profile_id=${q(player)}`), before); checks++;
    await check(`select status from open_queue_games where id=${q(target)}`, 'FULL');
    await check(`select teams_assigned_at is null from open_queue_games where id=${q(target)}`);
    await check(`select count(*)::int from assignment_calls where game_id=${q(target)}`, 0);
    await check(`select bool_and(b.team is null and not b.played and b.amount_paid_fils=0 and b.base_amount_fils=0
      and b.discount_bps=0 and b.reliability_deposit_fils=0 and b.reliability_deposit_status='NOT_REQUIRED'
      and b.payment_method='MOCK' and b.payment_intent_id is null and b.provider_payment_id is null
      and p.auth_user_id is null and p.phone is null and not is_fieldrush_account_active(p.id))
      from open_queue_bookings b join fieldrush_private.staging_bot_profiles s on s.booking_id=b.id
      join profiles p on p.id=b.profile_id where b.game_id=${q(target)}`);
    assert.deepEqual(await value(fill(target, request)), result); checks++;
    const again = await value(fill(target, await uuid()));
    assert.equal(again.createdBots, 0); assert.equal(again.alreadyFilled, true); checks+=2;
    await rejects(fill(initial, request), /another bot-fill action/);
    await check(`select count(*)::int from fieldrush_private.staging_bot_profiles where game_id=${q(target)}`, 13);
    // Once the exact fill context is gone, ordinary/manual assignment runs.
    await db.exec(`select assign_open_queue_teams(${q(target)})`);
    await check(`select count(*)::int from assignment_calls where game_id=${q(target)}`, 1);
  }
  const custom = await game({ defender_capacity: 0, attacker_capacity: 12 });
  await value(fill(custom, await uuid()));
  await check(`select count(*)::int from open_queue_bookings where game_id=${q(custom)} and role='DEF'`, 0);
  await check(`select count(*)::int from open_queue_bookings where game_id=${q(custom)} and role='ATT'`, 12);
  for (const patch of [{status:'LIVE'},{status:'FINAL'},{status:'CANCELLED'},{operational_state:'REVIEW_REQUIRED'},{starts_at:'2000-01-01 UTC'},{teams_assigned_at:'2026-01-01 UTC'},{white_score:0}]) {
    const target = await game(patch);
    await rejects(fill(target, await uuid()), /upcoming|locked/);
  }
  for (const status of ['PENDING','PROCESSING','CAPTURED','REQUIRES_REFUND']) {
    const target = await game();
    await db.exec(`insert into payment_intents(status,payload) values(${q(status)},jsonb_build_object('game_id',${q(target)}))`);
    await rejects(fill(target, await uuid()), /pending checkout/);
    await check(`select count(*)::int from fieldrush_private.staging_bot_profiles where game_id=${q(target)}`, 0);
  }
  const paused = await game();
  await db.exec(`insert into open_queue_clock_states values(${q(paused)},'PAUSED',null,0)`);
  await rejects(fill(paused, await uuid()), /unstarted/);
  const frozen = await game();
  await db.exec(`insert into fieldrush_rating_private.season_zero_matches values(${q(frozen)})`);
  await rejects(fill(frozen, await uuid()), /unstarted/);
  // Ordinary authless profiles and registry bots outside this function's exact
  // game context cannot bypass active-account or division validation.
  const outsider = await uuid();
  await db.exec(`insert into profiles(id,display_name,username) values(${q(outsider)},'Authless outsider','outsider')`);
  await rejects(`insert into open_queue_bookings(game_id,profile_id,role,player_rating_at_booking,amount_paid_fils,base_amount_fils)
    values(${q(initial)},${q(outsider)},'GK',1200,0,0)`, /Complete Fieldrush signup/);
  const bot = await value(`select profile_id from fieldrush_private.staging_bot_profiles limit 1`);
  await rejects(`select assert_open_queue_division_eligibility(${q(bot)},(select game_id from fieldrush_private.staging_bot_profiles where profile_id=${q(bot)}),'DEF')`, /Placement/);
  const rollback = await game();
  const botCount = await value('select count(*)::int from fieldrush_private.staging_bot_profiles');
  const profileCount = await value('select count(*)::int from profiles');
  await db.exec(`create function fail_bot_insert() returns trigger language plpgsql as $$begin
    if new.game_id=${q(rollback)}::uuid and new.role='ATT' then raise exception 'forced isolated failure'; end if; return new; end$$;
    create trigger z_fail_bot_insert before insert on open_queue_bookings for each row execute function fail_bot_insert()`);
  const rollbackRequest = await uuid();
  await rejects(fill(rollback, rollbackRequest), /forced isolated failure/);
  await check('select count(*)::int from fieldrush_private.staging_bot_profiles', botCount);
  await check('select count(*)::int from profiles', profileCount);
  await check(`select count(*)::int from fieldrush_private.staging_bot_fill_requests where request_id=${q(rollbackRequest)}`, 0);
  await check(`select count(*)::int from open_queue_bookings where game_id=${q(rollback)}`, 0);
  await check('select count(*)::int from auth.users', 3);
  for (const table of ['payment_refunds','field_wallet_transactions','notifications','push_deliveries']) await check(`select count(*)::int from ${table}`, 0);
  await db.exec(`update fieldrush_private.staging_bot_controls set enabled=false where singleton`);
  await rejects(fill(initial, await uuid()), /not enabled/);
  console.log(`Staging bot fill verified: ${checks} isolated PostgreSQL assertions.`);
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  await db.close();
}
