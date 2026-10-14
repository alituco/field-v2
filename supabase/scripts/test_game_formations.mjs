// Isolated PostgreSQL behavior checks. Never connects to hosted data or Stripe.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_game_formations.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const admin = '10000000-0000-0000-0000-000000000001';
const nonAdmin = '10000000-0000-0000-0000-000000000002';
const inactiveAdmin = '10000000-0000-0000-0000-000000000003';
let checks = 0;

function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0, `Missing real migration function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= start, `Missing function terminator for ${name}`);
  return sql.slice(start, end + 4);
}
function blockContaining(sql, needle) {
  const middle = sql.indexOf(needle);
  assert(middle >= 0, `Missing migration block ${needle}`);
  const start = sql.lastIndexOf('do $migration$', middle);
  const end = sql.indexOf('$migration$;', middle);
  assert(start >= 0 && end >= start);
  return sql.slice(start, end + 13);
}
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) { assert.deepEqual(await value(sql), expected, sql); checks++; }
async function rejects(sql, pattern) { await assert.rejects(db.exec(sql), pattern); checks++; }
async function rejected(promise, pattern) { await assert.rejects(promise, pattern); checks++; }

try {
  // Replay the real prior creation, schedule, booking, feed, party and optimizer
  // function bodies. Only unrelated account/reliability source records are
  // represented by isolated fixtures; no formation checks are replicated here.
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema fieldrush_private; create schema cron;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create function auth.role() returns text language sql stable as $$
      select current_setting('request.jwt.claim.role',true)
    $$;
    select set_config('request.jwt.claim.role','service_role',false);
    create table fieldrush_private.accounts(user_id uuid primary key,status text default 'active');
    create function fieldrush_private.require_user() returns uuid language sql stable as $$select auth.uid()$$;
    create function is_fieldrush_account_active(uuid) returns boolean language sql stable as $$
      select exists(select 1 from fieldrush_private.accounts where user_id=$1)
    $$;
    create function profile_has_active_reliability_booking_restriction(uuid) returns boolean language sql stable as $$select false$$;
    create function active_reliability_strikes(uuid,timestamptz default now()) returns integer language sql stable as $$select 0$$;
    create function fixture_start_at(date,text) returns timestamptz language sql immutable as $$
      select ($1::text||' '||$2||' UTC')::timestamptz
    $$;
    create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$
      select fixture_start_at($1,$2)+interval '1 hour'
    $$;
    create function get_my_fieldrush_account() returns jsonb language sql as $$select '{}'::jsonb$$;
    create table cron.job(jobname text,schedule text,command text);
    create function cron.schedule(text,text,text) returns bigint language plpgsql as $$
      begin insert into cron.job values($1,$2,$3); return 1; end$$;
    create table referee_profiles(profile_id uuid primary key,role text,is_active boolean);
    insert into referee_profiles values('${admin}','admin',true),('${nonAdmin}','referee',true),('${inactiveAdmin}','admin',false);
    create function is_active_moderation_admin(uuid) returns boolean language sql as $$
      select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)
    $$;
    create table admin_audit_events(actor_referee_id uuid not null references referee_profiles(profile_id),action text,
      entity_type text check(entity_type in ('ACTION','SOLO_MATCH')),entity_id uuid not null,
      reason text,before_state jsonb,after_state jsonb);
    create table profiles(id uuid primary key,display_name text default 'Test player',username text,avatar_url text);
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text not null default 'OPEN',
      venue text not null default 'Isolated test pitch',starts_at timestamptz not null,ends_at timestamptz not null,
      timezone text not null default 'America/Phoenix',currency text not null default 'USD',
      format_version text not null default 'FIELDRUSH_7V7',price_fils integer not null default 13000,
      age_label text not null default '18+',created_by uuid,operational_state text not null default 'NORMAL',
      operational_state_updated_at timestamptz,operational_reason_code text,
      capacity integer not null default 14,goalkeeper_capacity integer not null default 2,defender_capacity integer not null default 6,
      midfielder_capacity integer not null default 0,attacker_capacity integer not null default 6,teams_assigned_at timestamptz,
      white_score integer,black_score integer,white_average_sr numeric,black_average_sr numeric,match_average_sr numeric,
      team_sr_spread numeric,video_url text,replacement_discount_bps integer default 0,replacement_discount_role text,
      replacement_offer_expires_at timestamptz,replacement_source_booking_id uuid,
      constraint open_queue_games_versioned_format_check check (
        (format_version='LEGACY_6V6' and capacity=12 and goalkeeper_capacity=2 and defender_capacity=4
          and midfielder_capacity=4 and attacker_capacity=2 and currency='BHD' and timezone='Asia/Bahrain')
        or (format_version='FIELDRUSH_7V7' and capacity=14 and goalkeeper_capacity=2 and defender_capacity=6
          and midfielder_capacity=0 and attacker_capacity=6 and currency='USD' and timezone='America/Phoenix' and price_fils%10=0)));
    create unique index open_queue_games_one_active_start_idx on open_queue_games(starts_at) where status<>'CANCELLED';
    create unique index open_queue_games_venue_start_unique_idx on open_queue_games(lower(venue),starts_at) where status<>'CANCELLED';
    create table match_reliability_terms(id uuid primary key default gen_random_uuid(),match_kind text default 'SOLO',
      open_queue_game_id uuid,policy_version_id uuid,check_in_deadline_at timestamptz,policy_snapshot jsonb,
      team_assignment_at timestamptz,party_lock_at timestamptz);
    create function ensure_match_reliability_terms(text,uuid) returns match_reliability_terms language sql stable as $$
      select t from match_reliability_terms t where open_queue_game_id=$2
    $$;
    create table player_ratings(profile_id uuid primary key,skill_rating integer default 1200,matches_played integer default 0);
    create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid,provider text default 'STRIPE',
      status text default 'PENDING',purpose text default 'SOLO_BOOKING',provider_status text,provider_intent_id text unique,
      provider_payment_id text,payment_method text default 'CARD',currency text default 'USD',amount_fils integer,
      amount_minor integer generated always as (amount_fils/10) stored,payload jsonb,quote_snapshot jsonb,
      transaction_reference text,resource_type text,resource_id uuid,finalized_at timestamptz,failure_reason text,
      captured_at timestamptz,created_at timestamptz default now(),expires_at timestamptz default now()+interval '20 minutes');
    create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,
      role text default 'DEF',status text default 'CONFIRMED',player_rating_at_booking integer,team text,played boolean default false,
      booked_at timestamptz default now(),rating_at_team_assignment integer,rating_at_match_start integer,rating_change integer,
      amount_paid_fils integer,base_amount_fils integer,discount_bps integer,reliability_deposit_fils integer,
      reliability_deposit_status text,reliability_policy_version_id uuid,payment_method text default 'FREE',
      payment_reference text,payment_intent_id uuid unique,provider_payment_id text,refund_status text default 'NOT_DUE');
    create unique index one_booking_per_game on open_queue_bookings(game_id,profile_id) where status='CONFIRMED';
    create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid,recipient_profile_id uuid,
      idempotency_key text unique,provider_intent_id text,amount_fils integer,amount_minor integer,currency text,
      reason text,metadata jsonb,status text,provider_status text);
    create table fixtures(id uuid primary key default gen_random_uuid(),status text default 'SCHEDULED',
      match_date date default current_date+14,time_slot text default '20:00',operational_state text default 'NORMAL',
      home_amount_paid_fils integer,away_amount_paid_fils integer,home_payment_intent_id uuid,
      away_payment_intent_id uuid,home_provider_payment_id text,away_provider_payment_id text);
    create table fixture_reliability_roster_history(id uuid primary key default gen_random_uuid(),fixture_id uuid,
      profile_id uuid,status text default 'CONFIRMED');
    create table match_reserve_assignments(id uuid primary key default gen_random_uuid(),match_kind text,
      fixture_id uuid,open_queue_game_id uuid,profile_id uuid,status text default 'ACTIVE');
    create table match_attendance_records(match_kind text,open_queue_game_id uuid,fixture_id uuid,profile_id uuid,outcome text);
    create table open_queue_clock_states(game_id uuid primary key,status text not null default 'NOT_STARTED'
      check(status in ('NOT_STARTED','RUNNING','PAUSED','ENDED')),started_at timestamptz,
      accumulated_seconds integer not null default 0,duration_seconds integer);
    create table open_queue_broadcasts(game_id uuid primary key,status text,hls_url text,replay_hls_url text,
      stream_started_at timestamptz,stream_stopped_at timestamptz,recording_ready_at timestamptz,error_message text);
    create table open_queue_goals(id uuid primary key,game_id uuid,team text,scorer_profile_id uuid,minute integer,created_at timestamptz);
    create table open_queue_match_events(id uuid primary key,game_id uuid,event_type text,team text,profile_id uuid,minute integer,created_at timestamptz);
    create table open_queue_blue_cards(id uuid primary key,game_id uuid,profile_id uuid,minute integer,created_at timestamptz);
  `);
  await db.exec(fn(await source('20260607010000_create_profiles.sql'), 'set_updated_at'));
  const phoenix = await source('20261010000000_fieldrush_phoenix_game_format.sql');
  await db.exec(fn(phoenix, 'protect_open_queue_format_version'));
  await db.exec(`create trigger protect_open_queue_format_version before update on open_queue_games
    for each row execute function protect_open_queue_format_version()`);
  const parties = await source('20260715000007_create_open_queue_parties.sql');
  await db.exec(parties.slice(0, parties.indexOf('-- Validate parties')));
  for (const name of ['find_open_queue_white_assignment','open_queue_party_assignment_is_possible','assign_open_queue_teams']) {
    await db.exec(fn(phoenix, name));
  }
  await db.exec(fn(parties, 'reassign_open_queue_teams_after_party_change'));
  await db.exec(fn(await source('20260715000008_allow_open_queue_party_switches.sql'), 'respond_open_queue_party_invitation'));
  const cutoffs = await source('20260716000003_apply_reliability_policy_to_solo_cutoffs.sql');
  for (const name of ['open_queue_team_assignment_at','open_queue_party_lock_at','open_queue_max_party_size',
    'list_open_queue_games','list_open_queue_fixture_games']) await db.exec(fn(cutoffs, name));
  await db.exec(fn(await source('20260713000007_create_open_queue_player_sr_system.sql'), 'get_open_queue_match_detail'));
  await db.exec(blockContaining(await source('20260730000000_create_match_resolution_control_plane.sql'),
    "'Could not expose operational state in list_open_queue_games().'"));
  await db.exec(blockContaining(phoenix, "definition := pg_get_functiondef('public.list_open_queue_games()'"));
  let bookingDefinition = fn(await source('20260723010000_finalize_tap_payments_atomically.sql'), 'book_open_queue_game')
    .replace('function public.book_open_queue_game(', 'function public.book_open_queue_game_server(');
  for (const [from,to] of [['tap_payment_intents','payment_intents'],['tap_payment_intent_id','payment_intent_id'],
    ['tap_charge_id','provider_payment_id'],['tap_payment_method','payment_method'],['tap_status','provider_status'],
    ['tap_intent_to_use','payment_intent_to_use']]) bookingDefinition = bookingDefinition.replaceAll(from,to);
  await db.exec(bookingDefinition);
  await db.exec(fn(await source('20260716000007_preview_open_queue_booking_cost.sql'), 'preview_open_queue_booking_cost'));
  const usd = await source('20261010000100_fieldrush_usd_wallet_isolation.sql');
  const usdStart = usd.indexOf('do $migration$');
  const usdEnd = usd.indexOf("  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready",usdStart);
  await db.exec(usd.slice(usdStart,usdEnd)+'end;\n$migration$;');
  const provider = await source('20261010001000_replace_payment_provider.sql');
  await db.exec(blockContaining(provider,"  definition:=pg_get_functiondef('public.book_open_queue_game_server"));
  await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'), 'enforce_open_queue_booking_capacity'));
  await db.exec(`create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status
    on open_queue_bookings for each row execute function enforce_open_queue_booking_capacity()`);
  await db.exec(await source('20261010001500_checkout_eligibility_preflight.sql'));
  await db.exec(fn(phoenix, 'enforce_open_queue_permanent_schedule'));
  await db.exec(`create trigger enforce_open_queue_permanent_schedule before insert or update of status,starts_at,ends_at,timezone
    on open_queue_games for each row execute function enforce_open_queue_permanent_schedule()`);
  await db.exec(fn(await source('20260713000007_create_open_queue_player_sr_system.sql'), 'referee_start_open_queue_game'));
  await db.exec(await source('20261011000100_saved_fields_and_game_locations.sql'));
  await db.exec(await source('20261011000200_configurable_solo_schedules.sql'));
  await db.exec(await source('20261011000400_enforce_bookable_game_prices.sql'));
  await db.exec(blockContaining(await source('20261011000300_edit_solo_game_prices.sql'),
    "definition := pg_get_functiondef('public.book_open_queue_game_server"));
  await db.exec(await source('20261012000100_one_active_game_per_player.sql'));
  await db.exec(await source('20261012000500_game_division_ranges.sql'));
  await db.exec(await source('20261014000100_fieldrush_city_catalog.sql'));

  const field = (await value(`select admin_save_field('${admin}',null,
    ${json({name:'Formation pitch',address:'123 Formation Road',latitude:33.45,longitude:-112.08})})`)).id;
  let sequence = 0;
  async function game(extra={}) {
    const starts = await value(`select ('2099-01-01T08:00:00-07:00'::timestamptz+interval '${sequence++*3} hours')::text`);
    const data = {starts_at:starts,ends_at:await value(`select (${q(starts)}::timestamptz+interval '1 hour')::text`),...extra};
    const id = await value(`insert into open_queue_games(${Object.keys(data).join(',')})
      values(${Object.values(data).map(q).join(',')}) returning id`);
    await db.exec(`insert into match_reliability_terms(open_queue_game_id,policy_version_id,check_in_deadline_at,
      team_assignment_at,party_lock_at,policy_snapshot) values(${q(id)},gen_random_uuid(),${q(starts)}::timestamptz-interval '1 hour',
      ${q(starts)}::timestamptz-interval '1 hour',${q(starts)}::timestamptz-interval '1 hour',
      '{"solo":{"playersPerSide":7,"reliabilityDeposit":{"activeStrikeThreshold":2,"depositBps":2000}},"replacement":{"maxPartySize":4,"postCheckInDeadlineMarketplaceEnabled":false}}')`);
    return id;
  }
  async function player() {
    const id = await value('insert into fieldrush_private.accounts(user_id) values(gen_random_uuid()) returning user_id');
    await db.exec(`insert into profiles(id) values(${q(id)}); insert into player_ratings(profile_id) values(${q(id)})`);
    return id;
  }
  async function booking(target,role,status='CONFIRMED') {
    const user = await player();
    const id = await value(`insert into open_queue_bookings(game_id,profile_id,role,status)
      values(${q(target)},${q(user)},${q(role)},${q(status)}) returning id`);
    return {id,user};
  }
  const save = (values,id=null,actor=admin) => value(`select admin_save_game_schedule(${q(actor)},${q(id)},${json(values)})`);
  const tomorrow = await value("select ((now() at time zone 'America/Phoenix')::date+1)::text");
  const scheduleDetails = {name:'Formation schedule',field_id:field,weekdays:[1,2,3,4,5,6,7],
    kickoff_time:'18:00',starts_on:tomorrow,booking_window_days:7,is_active:false};
  const oldGame = await game();
  const oldBooked = await booking(oldGame,'DEF');
  const oldPayment = await value(`insert into payment_intents(profile_id,status,payload,amount_fils,provider_payment_id)
    values(${q(oldBooked.user)},'FINALIZED',${json({game_id:oldGame,role:'DEF'})},13000,'ch_historical') returning id`);
  await db.exec(`update open_queue_bookings set amount_paid_fils=13000,payment_method='CARD',provider_payment_id='ch_historical'
    ,payment_intent_id=${q(oldPayment)} where id=${q(oldBooked.id)}`);
  const oldGameBefore = await value(`select to_jsonb(g) from open_queue_games g where id=${q(oldGame)}`);
  const oldBookingBefore = await value(`select to_jsonb(b) from open_queue_bookings b where id=${q(oldBooked.id)}`);
  const oldPaymentBefore = await value(`select to_jsonb(i) from payment_intents i where id=${q(oldPayment)}`);
  const oldTermsBefore = await value(`select to_jsonb(t) from match_reliability_terms t where open_queue_game_id=${q(oldGame)}`);
  const legacyGame = await game({format_version:'LEGACY_6V6',currency:'BHD',timezone:'Asia/Bahrain',
    capacity:12,goalkeeper_capacity:2,defender_capacity:4,midfielder_capacity:4,attacker_capacity:2,
    starts_at:'2025-10-03T17:30:00Z',ends_at:'2025-10-03T18:30:00Z'});
  const legacyBefore = await value(`select to_jsonb(g) from open_queue_games g where id=${q(legacyGame)}`);
  const oldSchedule = await save({...scheduleDetails,kickoff_time:'14:00',is_active:true});
  const oldScheduleBefore = await value(`select to_jsonb(s) from game_schedules s where id=${q(oldSchedule.id)}`);
  const oldOccurrencesBefore = await value(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(oldSchedule.id)}`);

  await db.exec(await source('20261014000900_configurable_solo_formations.sql'));
  checks++;
  await check(`select to_jsonb(g) from open_queue_games g where id=${q(oldGame)}`,oldGameBefore);
  await check(`select to_jsonb(b) from open_queue_bookings b where id=${q(oldBooked.id)}`,oldBookingBefore);
  await check(`select to_jsonb(i) from payment_intents i where id=${q(oldPayment)}`,oldPaymentBefore);
  await check(`select to_jsonb(t) from match_reliability_terms t where open_queue_game_id=${q(oldGame)}`,oldTermsBefore);
  await check(`select to_jsonb(g) from open_queue_games g where id=${q(legacyGame)}`,legacyBefore);
  await check(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(oldSchedule.id)}`,oldOccurrencesBefore);
  await check(`select goalkeepers_per_side=1 and defenders_per_side=3 and attackers_per_side=3
    from game_schedules where id=${q(oldSchedule.id)}`);
  await check(`select to_jsonb(s)-'goalkeepers_per_side'-'defenders_per_side'-'attackers_per_side'
    from game_schedules s where id=${q(oldSchedule.id)}`,oldScheduleBefore);

  const fresh = await game();
  await check(`select array[capacity,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity]
    from open_queue_games where id=${q(fresh)}`,[14,2,4,0,8]);
  for (const [gk,def,att] of [[1,0,6],[1,1,5],[1,2,4],[1,3,3],[1,4,2],[1,5,1],[1,6,0]]) {
    await db.exec(`select assert_fieldrush_solo_formation(${gk},${def},${att})`); checks++;
  }
  for (const values of [[0,3,4],[2,2,3],[1,-1,7],[1,7,-1],[1,2,3],[1,2,5],[null,2,4],[1,null,4],[1,2,null]]) {
    await rejects(`select assert_fieldrush_solo_formation(${values.map(q).join(',')})`,/formation|keeper|defender|attacker/i);
  }

  const created = await value(`select admin_create_open_queue_game('${admin}',${q(field)}::uuid,
    '2098-01-01T10:00:00-07:00'::timestamptz,13000,'18+',60,1,5,1,2,4)`);
  await check(`select array[goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity]
    from open_queue_games where id=${q(created)}`,[2,4,0,8]);
  await check(`select count(*)::integer from admin_audit_events where entity_id=${q(created)} and action='SOLO_GAME_CREATED'`,1);
  await rejects(`select admin_create_open_queue_game('${nonAdmin}',${q(field)}::uuid,
    '2098-01-02T10:00:00-07:00'::timestamptz,13000,'18+',60,1,5,1,2,4)`,/Admin referee/);
  const compatible = await value(`select admin_create_open_queue_game('${admin}',${q(field)}::uuid,
    '2098-01-02T10:00:00-07:00'::timestamptz,13000,'18+',60,1,5)`);
  await check(`select defender_capacity=4 and attacker_capacity=8 from open_queue_games where id=${q(compatible)}`);

  const edit = (target,def=3,att=3,actor=admin,reason='Change future formation') =>
    `select admin_update_open_queue_game_formation(${q(actor)},${q(target)},1,${q(def)},${q(att)},${q(reason)})`;
  await db.exec(edit(fresh)); checks++;
  await check(`select defender_capacity=6 and attacker_capacity=6 from open_queue_games where id=${q(fresh)}`);
  await rejects(edit(fresh,2,4,nonAdmin),/Admin referee/);
  await rejects(edit(fresh,2,4,inactiveAdmin),/Admin referee/);
  await rejects(edit(fresh,2,4,admin,''),/reason/i);
  await rejects(edit(fresh,1,1),/formation|keeper|defender|attacker/i);
  await rejects(edit(legacyGame),/Formation is locked/);

  for (const status of ['CONFIRMED','CANCELLED']) {
    const target = await game(); await booking(target,'DEF',status);
    await rejects(edit(target),/formation|booking|payment/i);
  }
  for (const status of ['PENDING','FAILED','EXPIRED','CANCELLED','CAPTURED','FINALIZED']) {
    const target = await game();
    await db.exec(`insert into payment_intents(profile_id,purpose,status,payload,amount_fils)
      values(${q(await player())},'SOLO_BOOKING',${q(status)},${json({game_id:target,role:'DEF'})},13000)`);
    await rejects(edit(target),/formation|booking|payment/i);
  }
  for (const extra of [{status:'FULL'},{status:'LIVE'},{status:'FINAL'},{status:'CANCELLED'},
    {teams_assigned_at:'2099-01-01T00:00:00Z'},{white_score:0},{black_score:0},
    {operational_state:'UNDER_REVIEW'},{operational_state:'NO_DATA'},{operational_state:'RESOLVED'}]) {
    const target = await game(extra);
    await rejects(edit(target),/formation|future|OPEN|bookings|started/i);
    await rejects(`update open_queue_games set defender_capacity=6,attacker_capacity=6 where id=${q(target)}`,
      /Formation is locked/);
  }
  // Merely viewing the referee match creates a pristine NOT_STARTED clock.
  // That default record does not imply match activity or lock an empty game.
  const clocked = await game();
  await db.exec(`insert into open_queue_clock_states(game_id,status) values(${q(clocked)},'NOT_STARTED')`);
  await db.exec(edit(clocked)); checks++;
  await check(`select defender_capacity=6 and attacker_capacity=6 from open_queue_games where id=${q(clocked)}`);
  await db.exec(`update open_queue_games set defender_capacity=4,attacker_capacity=8 where id=${q(clocked)}`); checks++;
  for (const clockState of [{status:'RUNNING'},{status:'PAUSED'},{status:'ENDED'},
    {started_at:'2026-10-14T00:00:00Z'},{accumulated_seconds:1}]) {
    const target = await game();
    const data = {game_id:target,...clockState};
    await db.exec(`insert into open_queue_clock_states(${Object.keys(data).join(',')})
      values(${Object.values(data).map(q).join(',')})`);
    await rejects(edit(target),/Formation is locked/);
    await rejects(`update open_queue_games set defender_capacity=6,attacker_capacity=6 where id=${q(target)}`,
      /Formation is locked/);
  }
  const changingReviewState = await game();
  await rejects(`update open_queue_games set operational_state='UNDER_REVIEW',defender_capacity=6,attacker_capacity=6
    where id=${q(changingReviewState)}`,/Formation is locked/);
  const previous = await game({starts_at:'2020-01-01T10:00:00-07:00',ends_at:'2020-01-01T11:00:00-07:00'});
  await rejects(edit(previous),/formation|future|OPEN/i);
  await rejects(`update open_queue_games set currency='BHD' where id=${q(fresh)}`,/format|currency/i);
  await rejects(`update open_queue_games set capacity=16 where id=${q(fresh)}`,/format|formation/i);
  // Direct writes have the same locks as the admin API; RPC-only enforcement
  // would leave service callers able to rewrite a paid game's agreed slots.
  await rejects(`update open_queue_games set defender_capacity=4,attacker_capacity=8 where id=${q(oldGame)}`,
    /Formation is locked/);
  const directEditable = await game();
  await db.exec(`update open_queue_games set defender_capacity=2,attacker_capacity=10 where id=${q(directEditable)}`); checks++;
  await rejects(`update open_queue_games set defender_capacity=3,attacker_capacity=9 where id=${q(directEditable)}`,
    /whole-number|check constraint/);
  await rejects(`update open_queue_games set goalkeeper_capacity=4,defender_capacity=2,attacker_capacity=8 where id=${q(directEditable)}`,
    /keeper/);
  await rejects(`update open_queue_games set midfielder_capacity=2 where id=${q(directEditable)}`,/check constraint/);

  // The quote is produced by the real booking-cost RPC. The checkout insert
  // snapshots its formation and rejects a quote raced by an admin edit.
  const quotedGame = await game();
  const quotedUser = await player();
  await db.exec(`select set_config('request.jwt.claim.sub',${q(quotedUser)},false)`);
  const quoted = await value(`select preview_open_queue_booking_cost(${q(quotedGame)},'DEF')`);
  assert.deepEqual(quoted.formation,{goalkeeper_capacity:2,defender_capacity:4,midfielder_capacity:0,attacker_capacity:8}); checks++;
  await db.exec(edit(quotedGame));
  await rejects(`insert into payment_intents(profile_id,purpose,payload,quote_snapshot,amount_fils)
    values(${q(quotedUser)},'SOLO_BOOKING',${json({game_id:quotedGame,role:'DEF'})},${json(quoted)},${quoted.total_fils})`,
    /formation changed/);
  await check(`select count(*)::integer from payment_intents where payload->>'game_id'=${q(quotedGame)}`,0);
  const newQuote = await value(`select preview_open_queue_booking_cost(${q(quotedGame)},'DEF')`);
  assert.deepEqual(newQuote.formation,{goalkeeper_capacity:2,defender_capacity:6,midfielder_capacity:0,attacker_capacity:6}); checks++;
  await db.exec(`insert into payment_intents(profile_id,purpose,payload,quote_snapshot,amount_fils)
    values(${q(quotedUser)},'SOLO_BOOKING',${json({game_id:quotedGame,role:'DEF'})},${json(newQuote)},${newQuote.total_fils})`); checks++;
  await rejects(edit(quotedGame,2,4),/Formation is locked/);
  for (const formation of [null,{},[],{goalkeeper_capacity:2,defender_capacity:4,attacker_capacity:8}]) {
    const target = await game();
    await rejects(`insert into payment_intents(profile_id,purpose,payload,quote_snapshot,amount_fils)
      values(${q(await player())},'SOLO_BOOKING',${json({game_id:target,role:'ATT'})},${json({formation})},13000)`,
      /formation changed/);
  }
  const historicalQuote = await game();
  await db.exec(`insert into payment_intents(profile_id,purpose,payload,quote_snapshot,amount_fils)
    values(${q(await player())},'SOLO_BOOKING',${json({game_id:historicalQuote,role:'DEF'})},'{}',13000)`); checks++;

  const newSchedule = await save({...scheduleDetails,name:'New 1-2-4 schedule'});
  await check(`select array[goalkeepers_per_side,defenders_per_side,attackers_per_side]
    from game_schedules where id=${q(newSchedule.id)}`,[1,2,4]);
  for (const values of [{goalkeepers_per_side:2},{defenders_per_side:-1,attackers_per_side:7},
    {defenders_per_side:2,attackers_per_side:3},{defenders_per_side:'2'},
    {attackers_per_side:4.5},{goalkeepers_per_side:null},{attackers_per_side:null}]) {
    await rejected(save({...scheduleDetails,name:'Invalid formation',...values}),/formation|number|keeper|defender|attacker/i);
  }
  await save({is_active:true},newSchedule.id);
  const materialized = await value(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(newSchedule.id)}`);
  assert(materialized.length > 0); checks++;
  assert(materialized.every(g=>g.goalkeeper_capacity===2 && g.defender_capacity===4 && g.attacker_capacity===8)); checks++;
  await save({defenders_per_side:1,attackers_per_side:5},newSchedule.id);
  await check(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(newSchedule.id)}`,materialized);
  await check(`select defenders_per_side=1 and attackers_per_side=5 from game_schedules where id=${q(newSchedule.id)}`);
  await save({booking_window_days:14},oldSchedule.id);
  await check(`select bool_and(g.defender_capacity=6 and g.attacker_capacity=6) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(oldSchedule.id)}`);
  // Expanding the rolling window generates new occurrences with the new rule.
  await save({booking_window_days:14},newSchedule.id);
  await check(`select count(*)::integer from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
    where o.schedule_id=${q(newSchedule.id)} and g.defender_capacity=2 and g.attacker_capacity=10`,7);

  // Actual capacity trigger uses each game's saved role totals.
  const capGame = await game();
  for (let i=0;i<4;i++) await booking(capGame,'DEF');
  await rejected(booking(capGame,'DEF'),/position|full|spot|capacity/i);
  for (let i=0;i<2;i++) await booking(capGame,'GK');
  await rejected(booking(capGame,'GK'),/position|full|spot|capacity/i);
  await rejected(booking(capGame,'MID'),/position|full|spot|capacity/i);
  for (let i=0;i<8;i++) await booking(capGame,'ATT');
  await check(`select count(*)::integer from open_queue_bookings where game_id=${q(capGame)} and status='CONFIRMED'`,14);
  const chosen = await value(`select find_open_queue_white_assignment(${q(capGame)},false)`);
  assert.equal(chosen.length,7); checks++;
  await check(`select jsonb_object_agg(role,n) from (select role,count(*)::integer n from open_queue_bookings
    where id=any(${q(`{${chosen.join(',')}}`)}::uuid[]) group by role) x`,{GK:1,DEF:2,ATT:4});
  await db.exec(`update open_queue_games set status='FULL' where id=${q(capGame)};
    select set_config('field.force_open_queue_team_assignment',${q(capGame)},false);
    select assign_open_queue_teams(${q(capGame)})`); checks++;
  for (const side of ['WHITE','BLACK']) await check(`select jsonb_object_agg(role,n) from (
    select role,count(*)::integer n from open_queue_bookings where game_id=${q(capGame)} and team=${q(side)} group by role
  ) x`,{GK:1,DEF:2,ATT:4});
  await check(`select teams_assigned_at is not null and match_average_sr=1200 from open_queue_games where id=${q(capGame)}`);
  for (const [defenders,attackers,emptyRole] of [[0,12,'DEF'],[12,0,'ATT']]) {
    const target = await game({defender_capacity:defenders,attacker_capacity:attackers});
    await rejected(booking(target,emptyRole),/position|full|spot|capacity/i);
    for (const role of ['GK','GK',...Array(defenders).fill('DEF'),...Array(attackers).fill('ATT')]) await booking(target,role);
    const white = await value(`select find_open_queue_white_assignment(${q(target)},false)`);
    assert.equal(white.length,7); checks++;
    await check(`select count(*)::integer from open_queue_bookings
      where id=any(${q(`{${white.join(',')}}`)}::uuid[]) and role='GK'`,1);
    await check(`select count(*)::integer from open_queue_bookings
      where id=any(${q(`{${white.join(',')}}`)}::uuid[]) and role=${q(emptyRole)}`,0);
  }

  async function partyScenario(roles) {
    const target = await game();
    const players = [];
    for (const role of roles) players.push(await booking(target,role));
    const party = await value(`insert into open_queue_parties(game_id,owner_profile_id)
      values(${q(target)},${q(players[0].user)}) returning id`);
    for (const [index,p] of players.entries()) {
      await db.exec(`insert into open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
        values(${q(party)},${q(target)},${q(p.user)},${index===players.length-1?"'INVITED'":"'ACCEPTED'"},${q(players[0].user)},
          ${index===players.length-1?'null':'now()'},${index===players.length-1?'null':'now()'})`);
    }
    const membership = await value(`select id from open_queue_party_members where party_id=${q(party)} and status='INVITED'`);
    await db.exec(`select set_config('request.jwt.claim.sub',${q(players.at(-1).user)},false)`);
    return {target,party,membership};
  }
  for (const roles of [['GK','GK'],['DEF','DEF','DEF']]) {
    const p = await partyScenario(roles);
    await rejects(`select respond_open_queue_party_invitation(${q(p.membership)},true)`,/impossible|formation/i);
    await check(`select status from open_queue_party_members where id=${q(p.membership)}`,'INVITED');
  }
  const attackers = await partyScenario(['ATT','ATT','ATT','ATT']);
  assert.equal((await value(`select respond_open_queue_party_invitation(${q(attackers.membership)},true)`)).status,'ACCEPTED'); checks++;
  await check(`select open_queue_party_assignment_is_possible(${q(attackers.target)})`);
  await check(`select count(*)::integer from open_queue_party_members where party_id=${q(attackers.party)} and status='ACCEPTED'`,4);
  for (const role of ['GK','GK','DEF','DEF','DEF','DEF','ATT','ATT','ATT','ATT']) await booking(attackers.target,role);
  await db.exec(`update open_queue_games set status='FULL' where id=${q(attackers.target)};
    select set_config('field.force_open_queue_team_assignment',${q(attackers.target)},false);
    select assign_open_queue_teams(${q(attackers.target)})`); checks++;
  await check(`select count(distinct b.team)::integer from open_queue_party_members m
    join open_queue_bookings b on b.game_id=m.game_id and b.profile_id=m.profile_id
    where m.party_id=${q(attackers.party)} and m.status='ACCEPTED'`,1);

  // Functions that rewrite creation/schedules must retain narrow service ACLs.
  for (const signature of [
    'admin_create_open_queue_game(uuid,uuid,timestamp with time zone,integer,text,integer,integer,integer,integer,integer,integer)',
    'admin_update_open_queue_game_formation(uuid,uuid,integer,integer,integer,text)',
    'admin_save_game_schedule(uuid,uuid,jsonb)',
  ]) {
    for (const role of ['anon','authenticated']) await check(`select has_function_privilege('${role}',${q(signature)},'EXECUTE')`,false);
    await check(`select has_function_privilege('service_role',${q(signature)},'EXECUTE')`);
  }
  await check(`select has_function_privilege('authenticated','assert_fieldrush_solo_formation(integer,integer,integer)','EXECUTE')`,false);
  for (const capacity of ['goalkeeper_capacity','defender_capacity','midfielder_capacity','attacker_capacity']) {
    await check(`select has_column_privilege('authenticated','open_queue_games',${q(capacity)},'SELECT')`);
  }
  await check(`select has_table_privilege('authenticated','open_queue_games','SELECT')`,false);
  console.log(`${checks} isolated formation behavior checks passed.`);
} finally {
  await db.close();
}
