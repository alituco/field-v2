// Isolated PostgreSQL regressions. Never connects to hosted data or Stripe.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_solo_rebooking.mjs
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const migration = '20261012000600_allow_same_game_rebooking_with_attendance_history.sql';
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const admin = '10000000-0000-0000-0000-000000000001';
let checks = 0;

// Read production definitions, including the last CREATE when a migration
// redefines a function twice. This deliberately does not depend on a dumped
// hosted schema. Historical pg_get_functiondef patches are applied below.
function definitions(sql) {
  const result = [];
  const starts = [...sql.matchAll(/^create (?:or replace )?function\s+([\w]+\.[\w]+)\s*\(/gmi)];
  for (const match of starts) {
    const start = match.index;
    const body = /\bas\s+(\$[\w]*\$)/i.exec(sql.slice(start));
    assert(body, `Missing function body ${match[1]}`);
    const end = sql.indexOf(`${body[1]};`, start + body.index + body[0].length);
    assert(end >= 0, `Missing function terminator ${match[1]}`);
    result.push({ name: match[1], sql: sql.slice(start, end + body[1].length + 1) });
  }
  return result;
}
function fn(sql, name) {
  const matches = definitions(sql).filter(item => item.name === `public.${name}`);
  assert(matches.length, `Missing production function ${name}`);
  return matches.at(-1).sql;
}
function table(sql, name) {
  const start = sql.search(new RegExp(`create table (?:if not exists )?public\\.${name}\\s*\\(`, 'i'));
  assert(start >= 0, `Missing production table ${name}`);
  const end = sql.indexOf('\n);', start);
  assert(end >= 0, `Missing table terminator ${name}`);
  return sql.slice(start, end + 3);
}
function doContaining(sql, anchor) {
  const target = sql.indexOf(anchor);
  assert(target >= 0, `Missing patch target ${anchor}`);
  const start = sql.lastIndexOf('do $migration$', target);
  const end = sql.indexOf('$migration$;', target);
  assert(start >= 0 && end >= target, `Missing patch block ${anchor}`);
  return sql.slice(start, end + '$migration$;'.length);
}
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) { assert.deepEqual(await value(sql), expected, sql); checks++; }
async function rejects(sql, pattern) { await assert.rejects(db.exec(sql), pattern); checks++; }
async function row(tableName, id) { return value(`select to_jsonb(r) from ${tableName} r where id=${q(id)}`); }
const history = object => Object.fromEntries(Object.entries(object).filter(([key]) => !['is_current', 'updated_at'].includes(key)));

try {
  const latest = new Map();
  const files = (await readdir(new URL('../migrations/', import.meta.url)))
    .filter(file => file.endsWith('.sql') && file < migration).sort();
  for (const file of files) for (const item of definitions(await source(file))) latest.set(item.name, item.sql);
  const rebooking = await source(migration);
  const signatures = [...new Set([...rebooking.matchAll(/'(public\.[a-z_]+\([a-z_,\[\]]*\))'/g)].map(match => match[1]))];
  const operationalBlock = rebooking.slice(rebooking.indexOf('foreach signature in array array['),
    rebooking.indexOf('] loop', rebooking.indexOf('foreach signature in array array[')));
  const operationalSignatures = [...operationalBlock.matchAll(/'(public\.[a-z_]+\([a-z_,\[\]]*\))'/g)].map(match => match[1]);
  const operationalNames = signatures.map(signature => signature.slice(0, signature.indexOf('(')))
    .filter(name => !['public.book_open_queue_game_server', 'public.cancel_open_queue_booking_policy'].includes(name));

  // Tables are narrow fixtures for real functions, not implementations of the
  // rules under test. External/account/assignment lookups are isolated locally.
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema fieldrush_private;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role',true)$$;
    select set_config('request.jwt.claim.role','service_role',false);
    create table profiles(id uuid primary key,display_name text default 'Regression player');
    create table fieldrush_private.accounts(user_id uuid primary key references profiles(id));
    create table referee_profiles(profile_id uuid primary key references profiles(id),role text,is_active boolean default true);
    insert into profiles(id) values('${admin}');
    insert into referee_profiles values('${admin}','admin',true);
    create function is_fieldrush_account_active(uuid) returns boolean language sql stable as $$
      select exists(select 1 from fieldrush_private.accounts where user_id=$1)
    $$;
    create function is_active_moderation_admin(uuid) returns boolean language sql stable as $$
      select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)
    $$;
    create table test_restrictions(profile_id uuid primary key);
    create function profile_has_active_reliability_booking_restriction(uuid) returns boolean language sql stable as $$
      select exists(select 1 from test_restrictions where profile_id=$1)
    $$;
    create function profile_has_active_play_restriction(uuid) returns boolean language sql stable as $$select false$$;
    create function referee_can_manage_reliability_match(uuid,text,uuid) returns boolean language sql stable as $$select $1='${admin}'::uuid$$;
    create function fixture_start_at(date,text) returns timestamptz language sql immutable as $$
      select ($1::text||' '||$2||' UTC')::timestamptz
    $$;
    create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$select fixture_start_at($1,$2)+interval '1 hour'$$;
    create table clans(id uuid primary key,name text);
    create table clan_members(profile_id uuid,clan_id uuid,left_at timestamptz);
    create table fixtures(id uuid primary key default gen_random_uuid(),status text default 'SCHEDULED',
      match_date date default current_date+14,time_slot text default '20:00',operational_state text default 'NORMAL',
      home_clan_id uuid,away_clan_id uuid,home_paid_by uuid,away_paid_by uuid,
      home_amount_paid_fils integer,away_amount_paid_fils integer,home_payment_intent_id uuid,away_payment_intent_id uuid,
      home_provider_payment_id text,away_provider_payment_id text);
    create table fixture_player_appearances(fixture_id uuid,profile_id uuid,clan_id uuid);
    create table fixture_reliability_roster_history(id uuid primary key default gen_random_uuid(),fixture_id uuid,
      profile_id uuid,status text default 'CONFIRMED');
    create table match_reserve_assignments(id uuid primary key default gen_random_uuid(),match_kind text,
      fixture_id uuid,open_queue_game_id uuid,profile_id uuid,status text default 'ACTIVE');
    create table reliability_policy_versions(id uuid primary key default gen_random_uuid(),effective_from timestamptz default '2000-01-01 UTC');
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'OPEN',venue text default 'Isolated pitch',
      starts_at timestamptz default now()+interval '14 days',ends_at timestamptz default now()+interval '14 days 1 hour',
      currency text default 'USD',operational_state text default 'NORMAL',price_fils integer default 13000,
      capacity integer default 14,goalkeeper_capacity integer default 2,defender_capacity integer default 6,
      midfielder_capacity integer default 0,attacker_capacity integer default 6,teams_assigned_at timestamptz,
      white_score integer,black_score integer,white_average_sr integer,black_average_sr integer,
      replacement_discount_bps integer default 0,replacement_discount_role text,
      replacement_offer_expires_at timestamptz,replacement_source_booking_id uuid,
      highest_division smallint default 1,lowest_division smallint default 5);
    create table match_reliability_terms(id uuid primary key default gen_random_uuid(),match_kind text default 'SOLO',
      open_queue_game_id uuid,fixture_id uuid,policy_version_id uuid references reliability_policy_versions(id),
      kickoff_at timestamptz,check_in_opens_at timestamptz,check_in_deadline_at timestamptz,no_show_cutoff_at timestamptz,policy_snapshot jsonb);
    create function ensure_match_reliability_terms(text,uuid) returns match_reliability_terms language sql stable as $$
      select t from match_reliability_terms t where (t.match_kind='SOLO' and t.open_queue_game_id=$2)
        or (t.match_kind='CLAN' and t.fixture_id=$2)
    $$;
    create table player_ratings(profile_id uuid primary key,skill_rating integer default 1200,matches_played integer default 2,
      wins integer default 0,losses integer default 0,draws integer default 0,last_change integer default 0);
    create table player_rating_events(id uuid primary key default gen_random_uuid(),profile_id uuid,source_type text,source_id uuid,
      side text,result text,rating_before integer default 1200,rating_change integer default 0,rating_after integer default 1200,
      attendance_outcome text,reliability_policy_version_id uuid,reliability_multiplier_bps integer,
      sr_protection_applied boolean default false,sr_protection_reason text,base_rating_change integer,
      margin_bonus_applied integer,rating_at_match_start integer,opponent_average_rating numeric,
      effective_at timestamptz,team_average_rating numeric,expected_score numeric,actual_score numeric,
      calculation_version text,score_margin integer,margin_multiplier numeric,margin_bonus_before_clamp integer,
      unique(source_type,source_id,profile_id));
    create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid,provider text default 'STRIPE',
      status text default 'PENDING',purpose text default 'SOLO_BOOKING',provider_status text,provider_intent_id text unique,
      provider_payment_id text,payment_method text default 'CARD',currency text default 'USD',amount_fils integer,
      amount_minor integer generated always as (amount_fils/10) stored,payload jsonb,quote_snapshot jsonb,
      transaction_reference text,resource_type text,resource_id uuid,finalized_at timestamptz,failure_reason text,
      captured_at timestamptz,created_at timestamptz default now(),expires_at timestamptz default now()+interval '20 minutes',
      external_refund_review_required boolean default false);
    create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,
      role text default 'DEF',status text default 'CONFIRMED',team text,played boolean default false,
      player_rating_at_booking integer,amount_paid_fils integer default 0,base_amount_fils integer default 0,discount_bps integer default 0,
      reliability_deposit_fils integer default 0,reliability_deposit_status text default 'NOT_REQUIRED',reliability_policy_version_id uuid,
      payment_method text default 'FREE',payment_reference text,payment_intent_id uuid unique,provider_payment_id text,
      refund_status text default 'NOT_DUE',payment_status text default 'PAID',refund_destination text default 'FIELD_WALLET',
      cancelled_at timestamptz,refund_bps integer default 0,refund_percent integer default 0,refund_amount_fils integer default 0,
      rating_at_team_assignment integer,rating_at_match_start integer,rating_change integer,
      created_at timestamptz default clock_timestamp(),updated_at timestamptz default clock_timestamp());
    create unique index one_booking_per_game on open_queue_bookings(game_id,profile_id) where status='CONFIRMED';
    create table notifications(recipient_profile_id uuid,type text,title text,body text,related_entity_type text,related_entity_id uuid,data jsonb);
    create table open_queue_clock_states(game_id uuid primary key,status text default 'NOT_STARTED',started_at timestamptz,accumulated_seconds integer default 0);
    create table open_queue_events(game_id uuid,event_type text,occurred_at timestamptz,profile_id uuid);
    create table fixture_clock_states(fixture_id uuid primary key,status text default 'NOT_STARTED',started_at timestamptz,accumulated_seconds integer default 0);
    create table admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
    create table reliability_appeals(id uuid primary key default gen_random_uuid(),attendance_id uuid,status text,reviewed_by uuid);
    create table reliability_sr_appeal_adjustments(id uuid primary key default gen_random_uuid(),appeal_id uuid);
    create table match_resolution_refunds(id uuid primary key default gen_random_uuid(),payment_refund_id uuid,status text,failure_reason text);
    create function initialize_fixture_reliability_roster(uuid) returns integer language sql as $$select 0$$;
    create function assign_open_queue_teams(uuid) returns void language sql as $$update open_queue_games set status='FULL' where id=$1$$;
    create function credit_legacy_field_wallet(uuid,integer,text,text,text,uuid,uuid,uuid,jsonb) returns uuid language sql as $$select gen_random_uuid()$$;
  `);
  const attendanceSource = await source('20260716000002_enforce_reliability_attendance.sql');
  await db.exec(fn(await source('20260607010000_create_profiles.sql'), 'set_updated_at'));
  const attendanceStart = attendanceSource.indexOf('create table public.match_attendance_records (');
  const attendanceEnd = attendanceSource.indexOf('create table public.attendance_events (', attendanceStart);
  await db.exec(attendanceSource.slice(attendanceStart, attendanceEnd));
  await db.exec('alter table match_attendance_records enable row level security; grant all on match_attendance_records to service_role');
  await db.exec(table(attendanceSource, 'attendance_events'));
  await db.exec(table(attendanceSource, 'reliability_incidents'));
  await db.exec(`create unique index reliability_incident_attendance_positive_idx on reliability_incidents(attendance_id)
    where attendance_id is not null and reversal_of is null;
    alter table match_attendance_records add column expected_for_match boolean not null default true,
      add column check_in_revision integer not null default 0,add column check_in_timing text;`);
  const timing = await source('20260722040000_add_referee_selected_check_in_timing.sql');
  await db.exec(timing.slice(0, timing.indexOf('create or replace function public.referee_check_in_player_with_timing')));
  const latestTiming = await source('20260722050000_relax_clan_finish_and_show_cancelled_games.sql');
  await db.exec(latestTiming.slice(latestTiming.indexOf('alter table public.attendance_events'),
    latestTiming.indexOf('create or replace function public.referee_check_in_player_with_timing')));
  const provider = await source('20261010001000_replace_payment_provider.sql');
  await db.exec(table(provider, 'payment_refunds'));
  const effects = await source('20260716000005_enforce_reliability_match_effects.sql');
  await db.exec(table(effects, 'match_shorthanded_periods'));
  await db.exec(table(effects, 'match_verified_injuries'));

  // Uncalled administrative source definitions need their composite types.
  // Placeholder tables do not stand in for operational selectors we execute.
  const selectedNames = [...new Set([...operationalNames,
    'public.ensure_match_attendance_records','public.apply_late_appeal_sr_correction',
    'public.record_reliability_incident','public.settle_reliability_deposit','public.apply_attendance_refund',
    'public.credit_field_wallet','public.reflect_booking_payment_refund','public.finish_payment_refund',
    'public.calculate_player_sr_change','public.calculate_open_queue_margin_multiplier',
    'public.calculate_open_queue_margin_bonus','public.reliability_match_elapsed_seconds',
    'public.apply_clan_reliability_rating_adjustments'])];
  for (const name of selectedNames) {
    assert(latest.has(name), `Missing latest source definition ${name}`);
    for (const match of latest.get(name).matchAll(/public\.([a-z_]+)%rowtype/g)) {
      await db.exec(`create table if not exists public.${match[1]}(id uuid primary key default gen_random_uuid())`);
    }
  }
  for (const name of selectedNames) {
    if (['public.preview_open_queue_booking_cost','public.assert_player_has_one_game',
      'public.enforce_reactivated_player_game_limit'].includes(name)) continue;
    await db.exec(latest.get(name).replace(/^create function/i, 'create or replace function'));
  }
  await db.exec(fn(attendanceSource, 'active_reliability_strikes'));
  await db.exec(fn(attendanceSource, 'open_queue_cancellation_quote'));
  await db.exec(fn(attendanceSource, 'cancel_open_queue_booking')
    .replace('function public.cancel_open_queue_booking(', 'function public.cancel_open_queue_booking_policy('));
  await db.exec(fn(await source('20261010001100_original_payment_refunds.sql'), 'cancel_open_queue_booking'));
  await db.exec(fn(attendanceSource, 'sync_solo_attendance_on_booking_change'));
  await db.exec(fn(await source('20260716000016_make_referee_checkin_authoritative.sql'), 'prevent_same_solo_game_rebooking'));
  await db.exec(`create trigger prevent_same_solo_game_rebooking before insert on open_queue_bookings
      for each row execute function prevent_same_solo_game_rebooking();
    create trigger sync_solo_attendance_on_booking_change after insert or update of status,team,role on open_queue_bookings
      for each row execute function sync_solo_attendance_on_booking_change();
    create trigger require_checked_in_solo_participant before insert or update of played on open_queue_bookings
      for each row execute function require_checked_in_match_participant();
    create trigger reflect_booking_payment_refund before insert or update on open_queue_bookings
      for each row execute function reflect_booking_payment_refund();`);

  // Production payment, USD, immutable-price, preflight, one-game and division
  // transformations in their original chronological order.
  let booking = fn(await source('20260723010000_finalize_tap_payments_atomically.sql'), 'book_open_queue_game')
    .replace('function public.book_open_queue_game(', 'function public.book_open_queue_game_server(');
  for (const [from, to] of [['tap_payment_intents','payment_intents'],['tap_payment_intent_id','payment_intent_id'],
    ['tap_charge_id','provider_payment_id'],['tap_payment_method','payment_method'],['tap_status','provider_status'],
    ['tap_intent_to_use','payment_intent_to_use']]) booking = booking.replaceAll(from, to);
  await db.exec(booking);
  await db.exec(fn(await source('20260716000007_preview_open_queue_booking_cost.sql'), 'preview_open_queue_booking_cost'));
  const usd = await source('20261010000100_fieldrush_usd_wallet_isolation.sql');
  const usdStart = usd.indexOf('do $migration$');
  const usdEnd = usd.indexOf("  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready", usdStart);
  await db.exec(usd.slice(usdStart, usdEnd) + 'end;\n$migration$;');
  await db.exec(doContaining(provider, "  definition:=pg_get_functiondef('public.book_open_queue_game_server"));
  for (const name of ['protect_payment_intent','request_payment_refund','finalize_payment_intent',
    'record_stripe_payment_capture','finalize_free_checkout']) await db.exec(fn(provider, name));
  await db.exec(`create trigger protect_payment_intent before update on payment_intents for each row execute function protect_payment_intent()`);
  await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'), 'enforce_open_queue_booking_capacity'));
  await db.exec(`create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status
    on open_queue_bookings for each row execute function enforce_open_queue_booking_capacity()`);
  await db.exec(await source('20261010001500_checkout_eligibility_preflight.sql'));
  await db.exec(doContaining(await source('20261011000300_edit_solo_game_prices.sql'),
    "definition := pg_get_functiondef('public.book_open_queue_game_server"));
  await db.exec(await source('20261012000100_one_active_game_per_player.sql'));
  const divisions = await source('20261012000500_game_division_ranges.sql');
  await db.exec(fn(divisions, 'fieldrush_division_for_rating'));
  await db.exec(fn(divisions, 'assert_open_queue_division_eligibility'));
  const divisionStart = divisions.indexOf('do $migration$');
  const divisionEnd = divisions.indexOf("  definition := pg_get_functiondef('public.admin_save_game_schedule", divisionStart);
  await db.exec(divisions.slice(divisionStart, divisionEnd) + 'end;\n$migration$;');
  const earlyTests = await source('20260716000020_complete_audited_admin_test_matches.sql');
  await db.exec(doContaining(earlyTests, "'public.referee_start_open_queue_game(uuid,uuid[],integer)'::regprocedure"));
  await db.exec(doContaining(earlyTests, "'public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure"));
  await db.exec(doContaining(earlyTests, "'public.apply_open_queue_player_ratings(uuid)'::regprocedure"));
  await db.exec(doContaining(await source('20260716000013_close_reliability_release_gaps.sql'),
    "old_text text := $old$event_to_adjust.attendance_outcome = 'ON_TIME'"));

  const policy = {
    attendance: { appealWindowHours: 24, strikeLifetimeDays: 90 },
    replacement: { postCheckInDeadlineMarketplaceEnabled: false, reserveActivationMinutesAfterKickoff: 5,
      originalPlayerReclaimUntilMinutesAfterKickoff: 5 },
    solo: { reliabilityDeposit: { activeStrikeThreshold: 2, depositBps: 2000, forfeitOutcomes: ['NO_SHOW'] },
      highestCrossedOnly: true, sanctions: [],
      cancellations: { early: { minimumHoursBeforeKickoff: 24, refundBps: 10000, strikes: 1, advertise: false, notify: false },
        late: { minimumHoursBeforeKickoff: 3, refundBps: 5000, strikes: 1, advertise: false, notify: false },
        veryLate: { refundBps: 0, strikes: 1, advertise: false, notify: false }, afterKickoff: { refundBps: 0, strikes: 2 } },
      outcomes: { onTime: { refundBps: 0, strikes: 0 }, late: { refundBps: 0, strikes: 1 }, noShow: { refundBps: 0, strikes: 2 } } },
    sr: { latePositiveMultiplierBps: 5000, lateNegativeMultiplierBps: 15000 },
  };
  async function player(rating = 1200) {
    const id = await value(`insert into profiles(id) values(gen_random_uuid()) returning id`);
    await db.exec(`insert into fieldrush_private.accounts values(${q(id)}); insert into player_ratings(profile_id,skill_rating) values(${q(id)},${rating})`);
    return id;
  }
  async function game(extra = {}) {
    const columns = Object.keys(extra);
    const id = await value(columns.length ? `insert into open_queue_games(${columns.join(',')}) values(${Object.values(extra).map(q).join(',')}) returning id`
      : 'insert into open_queue_games default values returning id');
    const policyId = await value('insert into reliability_policy_versions default values returning id');
    await db.exec(`insert into match_reliability_terms(open_queue_game_id,policy_version_id,kickoff_at,check_in_opens_at,check_in_deadline_at,no_show_cutoff_at,policy_snapshot)
      select id,${q(policyId)},starts_at,starts_at-interval '1 hour',starts_at-interval '30 minutes',starts_at+interval '15 minutes',${json(policy)}
      from open_queue_games where id=${q(id)}; insert into open_queue_clock_states(game_id) values(${q(id)})`);
    return id;
  }
  async function asPlayer(id) { await db.exec(`select set_config('request.jwt.claim.sub',${q(id)},false)`); }
  async function quote(target, user, role = 'DEF') {
    await asPlayer(user);
    return value(`select preview_open_queue_booking_cost(${q(target)},${q(role)})`);
  }
  async function buy(target, user, role = 'DEF') {
    const quoted = await quote(target, user, role);
    const id = await value(`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot,provider_intent_id,transaction_reference)
      values(${q(user)},${quoted.total_fils},${json({ game_id: target, role })},${json(quoted)},'pi_'||gen_random_uuid(),'test_'||gen_random_uuid()) returning id`);
    const paid = await value(`select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD')
      from payment_intents where id=${q(id)}`);
    assert.equal(paid.status, 'FINALIZED', JSON.stringify(paid)); checks++;
    return { id: paid.resource_id, intent: id, quote: quoted };
  }
  const attendanceFor = bookingId => value(`select to_jsonb(a) from match_attendance_records a where booking_id=${q(bookingId)}`);
  async function cancel(bookingId, user) {
    await asPlayer(user);
    await value(`select to_jsonb(cancel_open_queue_booking(${q(bookingId)}))`);
    await check(`select status='CANCELLED' from open_queue_bookings where id=${q(bookingId)}`);
  }
  async function completeRefunds(bookingId) {
    const refunds = (await db.query(`select r.* from payment_refunds r join open_queue_bookings b
      on b.payment_intent_id=r.intent_id where b.id=${q(bookingId)} order by r.id`)).rows;
    for (const refund of refunds) {
      const call = `select finish_payment_refund(${q(refund.id)},${q(`re_${refund.id}`)},'succeeded',${refund.amount_minor},${q(refund.currency)})`;
      const result = await value(call);
      assert.equal(result.status, 'SUCCEEDED'); checks++;
      assert.deepEqual(await value(call), result); checks++;
    }
  }
  async function snapshots(bookingId) {
    const attendance = await attendanceFor(bookingId);
    const bookingRow = await row('open_queue_bookings', bookingId);
    return { booking: bookingRow, attendance, payment: await row('payment_intents', bookingRow.payment_intent_id),
      events: await value(`select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from attendance_events e where attendance_id=${q(attendance.id)}`),
      incidents: await value(`select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from reliability_incidents i where attendance_id=${q(attendance.id)}`),
      refunds: await value(`select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from payment_refunds r where intent_id=
        (select payment_intent_id from open_queue_bookings where id=${q(bookingId)})`) };
  }
  async function preserved(bookingId, before) {
    const after = await snapshots(bookingId);
    assert.deepEqual(history(after.attendance), history(before.attendance)); checks++;
    for (const key of ['booking','payment','events','incidents','refunds']) { assert.deepEqual(after[key], before[key], key); checks++; }
  }

  // Pre-migration history is additive and never silently changed on migration.
  const user = await player(); const target = await game();
  const first = await buy(target, user, 'GK');
  // A cancelled provisional check-in is immutable old proof, not evidence that
  // the new booking arrived. Exercise an actual removed/re-recorded revision.
  await value(`select referee_check_in_player_with_timing('${admin}','SOLO',${q(target)},${q(user)},'EARLY')`);
  await value(`select referee_remove_player_check_in('${admin}','SOLO',${q(target)},${q(user)},0,'OPERATOR_ERROR','Isolated correction')`);
  await value(`select referee_check_in_player_with_timing('${admin}','SOLO',${q(target)},${q(user)},'EARLY')`);
  await cancel(first.id, user);
  await completeRefunds(first.id);
  const firstBeforeMigration = await snapshots(first.id);
  assert.equal(firstBeforeMigration.attendance.check_in_revision, 1); checks++;
  assert.equal(firstBeforeMigration.attendance.check_in_timing, 'EARLY'); checks++;
  assert(firstBeforeMigration.attendance.checked_in_at); checks++;
  await rejects(`insert into open_queue_bookings(game_id,profile_id,role) values(${q(target)},${q(user)},'DEF')`, /cannot book that same game again/);
  await db.exec(rebooking);
  await preserved(first.id, firstBeforeMigration);
  await check(`select status='REFUNDED' from payment_intents where id=${q(first.intent)}`);
  await check(`select is_current from match_attendance_records where booking_id=${q(first.id)}`);
  await check("select reloptions @> array['security_invoker=true'] from pg_class where oid='current_match_attendance_records'::regclass");
  await check("select has_table_privilege('service_role','current_match_attendance_records','SELECT')");
  for (const role of ['anon','authenticated']) await check(`select has_table_privilege(${q(role)},'current_match_attendance_records','SELECT')`, false);
  await db.exec('set role service_role');
  await check('select count(*)::integer from current_match_attendance_records', 1);
  await db.exec('reset role');
  await db.exec('set role authenticated');
  await rejects('select * from current_match_attendance_records', /permission denied/);
  await db.exec('reset role');
  await check("select has_function_privilege('authenticated','assert_open_queue_rebooking_eligible(uuid,uuid)','EXECUTE')", false);
  for (const signature of signatures) {
    const definition = await value(`select pg_get_functiondef(${q(signature)}::regprocedure)`);
    if (operationalSignatures.includes(signature)) {
      assert.match(definition, /current_match_attendance_records/); checks++;
    }
  }

  // Each attempt gets current pricing, deposit and role; old receipts remain.
  await db.exec(`update open_queue_games set price_fils=9000 where id=${q(target)}`);
  const second = await buy(target, user, 'DEF');
  assert.notEqual(second.id, first.id); checks++;
  const secondAttendance = await attendanceFor(second.id);
  assert.notEqual(secondAttendance.id, firstBeforeMigration.attendance.id); checks++;
  assert.equal(second.quote.total_fils, 9000); checks++;
  await check(`select not is_current from match_attendance_records where booking_id=${q(first.id)}`);
  await check(`select is_current and outcome is null and checked_in_at is null and check_in_revision=0
    and deposit_resolution='NOT_REQUIRED' and role='DEF' from match_attendance_records where booking_id=${q(second.id)}`);
  await rejects(`update open_queue_bookings set played=true where id=${q(second.id)}`, /Check this player in/);
  await rejects(`update open_queue_bookings set status='CONFIRMED' where id=${q(first.id)}`, /superseded booking cannot be restored/);
  await db.exec(`update open_queue_bookings set role='ATT' where id=${q(second.id)}`);
  await check(`select id=${q(secondAttendance.id)} and role='ATT' from match_attendance_records where booking_id=${q(second.id)}`);
  await db.exec(`update open_queue_bookings set role='DEF' where id=${q(second.id)}`);
  await check(`select count(*)::integer from match_attendance_records where booking_id=${q(second.id)}`, 1);
  await preserved(first.id, firstBeforeMigration);
  const firstRetry = await value(`select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD')
    from payment_intents where id=${q(first.intent)}`);
  assert.equal(firstRetry.status, 'REFUNDED'); checks++;
  assert.equal(firstRetry.resource_id, first.id); checks++;
  await rejects(`insert into open_queue_bookings(game_id,profile_id,role) values(${q(target)},${q(user)},'ATT')`, /already booked/);
  const other = await game({ starts_at: '2099-01-01 UTC', ends_at: '2099-01-01 01:00 UTC' });
  await asPlayer(user);
  await rejects(`select preview_open_queue_booking_cost(${q(other)},'DEF')`, /one upcoming or active game/);
  await rejects(`insert into open_queue_bookings(game_id,profile_id) values(${q(other)},${q(user)})`, /one upcoming or active game/);
  await cancel(second.id, user);
  const secondBefore = await snapshots(second.id);
  await db.exec(`update open_queue_games set price_fils=8000 where id=${q(target)}`);
  const third = await buy(target, user, 'ATT');
  assert.equal(third.quote.reliability_deposit_fils, 1600); checks++;
  assert.equal(third.quote.total_fils, 9600); checks++;
  const thirdAttendance = await attendanceFor(third.id);
  await check(`select is_current and role='ATT' and outcome is null and checked_in_at is null
    and reliability_deposit_fils=1600 and deposit_resolution='PENDING' from match_attendance_records where id=${q(thirdAttendance.id)}`);
  await check(`select count(*)::integer from match_attendance_records where open_queue_game_id=${q(target)} and profile_id=${q(user)}`, 3);
  await check(`select count(*)::integer from current_match_attendance_records where open_queue_game_id=${q(target)} and profile_id=${q(user)}`, 1);
  await preserved(first.id, firstBeforeMigration); await preserved(second.id, secondBefore);
  const context = await value(`select get_match_reliability_context('SOLO',${q(target)})`);
  assert.equal(context.players.length, 1); checks++;
  assert.equal(context.players[0].attendance_record_id, thirdAttendance.id); checks++;
  assert.equal(context.players[0].role, 'ATT'); checks++;
  await value(`select referee_check_in_player_with_timing('${admin}','SOLO',${q(target)},${q(user)},'LATE')`);
  await check(`select checked_in_at is not null and check_in_timing='LATE' and outcome is null
    from match_attendance_records where id=${q(thirdAttendance.id)}`);
  await check(`select count(*)::integer from attendance_events where attendance_id=${q(thirdAttendance.id)} and event_type='CHECKED_IN'`, 1);
  await db.exec(`update open_queue_bookings set team='WHITE',played=true,rating_at_match_start=1200 where id=${q(third.id)};
    select set_config('field.allow_early_open_queue_finalization',${q(target)},false)`);
  assert.equal(await value(`select finalize_match_attendance_internal('SOLO',${q(target)},'${admin}')`), 1); checks++;
  assert.equal(await value(`select finalize_match_attendance_internal('SOLO',${q(target)},'${admin}')`), 0); checks++;
  await check(`select outcome='LATE' and deposit_resolution='RETURNED' from match_attendance_records where id=${q(thirdAttendance.id)}`);
  await preserved(first.id, firstBeforeMigration); await preserved(second.id, secondBefore);

  // Failure after supersession must roll it back along with the new booking.
  const rollbackUser = await player(); const rollbackGame = await game();
  const rollbackFirst = await buy(rollbackGame, rollbackUser); await cancel(rollbackFirst.id, rollbackUser);
  const rollbackBefore = await snapshots(rollbackFirst.id);
  await db.exec(`create function test_reject_booking_after_supersession() returns trigger language plpgsql as $$
    begin if new.profile_id=${q(rollbackUser)}::uuid then raise exception 'isolated later insert failure'; end if; return new; end$$;
    create trigger zzzz_test_reject_booking_after_supersession before insert on open_queue_bookings
      for each row execute function test_reject_booking_after_supersession()`);
  await rejects(`insert into open_queue_bookings(game_id,profile_id) values(${q(rollbackGame)},${q(rollbackUser)})`, /isolated later insert failure/);
  await preserved(rollbackFirst.id, rollbackBefore);
  await check(`select is_current from match_attendance_records where booking_id=${q(rollbackFirst.id)}`);
  await check(`select count(*)::integer from open_queue_bookings where game_id=${q(rollbackGame)} and profile_id=${q(rollbackUser)}`, 1);
  await db.exec('drop trigger zzzz_test_reject_booking_after_supersession on open_queue_bookings');
  await db.exec(`create trigger zzzz_test_reject_booking_after_supersession after insert on open_queue_bookings
    for each row execute function test_reject_booking_after_supersession()`);
  await rejects(`insert into open_queue_bookings(game_id,profile_id) values(${q(rollbackGame)},${q(rollbackUser)})`, /isolated later insert failure/);
  await preserved(rollbackFirst.id, rollbackBefore);
  await check(`select is_current from match_attendance_records where booking_id=${q(rollbackFirst.id)}`);
  await check(`select count(*)::integer from match_attendance_records where open_queue_game_id=${q(rollbackGame)}`, 1);
  await db.exec('drop trigger zzzz_test_reject_booking_after_supersession on open_queue_bookings');

  // An orphan does not establish a legitimate cancellation to supersede.
  const orphanUser = await player(); const orphanGame = await game();
  const orphanId = await value(`insert into match_attendance_records(terms_id,match_kind,open_queue_game_id,profile_id,
      policy_version_id,check_in_deadline_at,no_show_cutoff_at)
    select id,'SOLO',open_queue_game_id,${q(orphanUser)},policy_version_id,check_in_deadline_at,no_show_cutoff_at
    from match_reliability_terms where open_queue_game_id=${q(orphanGame)} returning id`);
  const orphanBefore = await row('match_attendance_records', orphanId);
  await asPlayer(orphanUser);
  await rejects(`select preview_open_queue_booking_cost(${q(orphanGame)},'DEF')`, /admin review/);
  await rejects(`select book_open_queue_game_server(${q(orphanGame)},'DEF','FREE',null)`, /admin review/);
  await rejects(`insert into open_queue_bookings(game_id,profile_id) values(${q(orphanGame)},${q(orphanUser)})`, /admin review/);
  assert.deepEqual(await row('match_attendance_records', orphanId), orphanBefore); checks++;
  await check(`select count(*)::integer from open_queue_bookings where game_id=${q(orphanGame)}`, 0);

  // A stale eligible checkout that becomes unsafe is caught again after
  // capture, without recycling orphan proof; its full refund is idempotent.
  const raceUser = await player(); const raceGame = await game();
  const staleQuote = await quote(raceGame, raceUser);
  const raceIntent = await value(`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot,provider_intent_id,transaction_reference)
    values(${q(raceUser)},${staleQuote.total_fils},${json({ game_id: raceGame, role: 'DEF' })},${json(staleQuote)},
    'pi_'||gen_random_uuid(),'test_'||gen_random_uuid()) returning id`);
  const raceOrphan = await value(`insert into match_attendance_records(terms_id,match_kind,open_queue_game_id,profile_id,
    policy_version_id,check_in_deadline_at,no_show_cutoff_at)
    select id,'SOLO',open_queue_game_id,${q(raceUser)},policy_version_id,check_in_deadline_at,no_show_cutoff_at
    from match_reliability_terms where open_queue_game_id=${q(raceGame)} returning id`);
  const raceBefore = await row('match_attendance_records', raceOrphan);
  const raceCapture = `select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD')
    from payment_intents where id=${q(raceIntent)}`;
  assert.equal((await value(raceCapture)).status, 'REQUIRES_REFUND'); checks++;
  assert.equal((await value(raceCapture)).status, 'REQUIRES_REFUND'); checks++;
  await check(`select count(*)::integer from payment_refunds where intent_id=${q(raceIntent)}`, 1);
  await check(`select amount_fils=13000 and amount_minor=1300 from payment_refunds where intent_id=${q(raceIntent)}`);
  assert.deepEqual(await row('match_attendance_records', raceOrphan), raceBefore); checks++;
  await check(`select count(*)::integer from open_queue_bookings where game_id=${q(raceGame)}`, 0);

  // Current filtering is not a waiver of capacity, division or restrictions.
  const capacityGame = await game({ goalkeeper_capacity: 0 }); const capacityUser = await player();
  await asPlayer(capacityUser);
  await rejects(`insert into open_queue_bookings(game_id,profile_id,role) values(${q(capacityGame)},${q(capacityUser)},'GK')`, /goalkeeper|position|spots|full/i);
  const divided = await game({ highest_division: 1, lowest_division: 2 });
  await rejects(`select preview_open_queue_booking_cost(${q(divided)},'DEF')`, /Your current division is 4/);
  await rejects(`insert into open_queue_bookings(game_id,profile_id) values(${q(divided)},${q(capacityUser)})`, /Your current division is 4/);
  await db.exec(`insert into test_restrictions values(${q(capacityUser)})`);
  await rejects(`select preview_open_queue_booking_cost(${q(capacityGame)},'DEF')`, /reliability restriction/);

  // Both real rating pipelines must leave cancelled booking.rating_change
  // untouched, including the game/profile final-update path on idempotent retry.
  const opponent = await player(); const opponentBooking = await buy(target, opponent);
  await value(`select referee_check_in_player_with_timing('${admin}','SOLO',${q(target)},${q(opponent)},'EARLY')`);
  await db.exec(`update open_queue_bookings set team='BLACK',played=true,rating_at_match_start=1200 where id=${q(opponentBooking.id)};
    update open_queue_games set status='FINAL',white_score=2,black_score=0 where id=${q(target)}`);
  await check(`select apply_open_queue_player_ratings(${q(target)})`, 2);
  await check(`select apply_open_queue_player_ratings(${q(target)})`, 0);
  await preserved(first.id, firstBeforeMigration); await preserved(second.id, secondBefore);
  await value(`select apply_open_queue_reliability_rating_adjustments(${q(target)})`);
  await check(`select attendance_outcome='LATE' and reliability_multiplier_bps=5000
    from player_rating_events where profile_id=${q(user)} and source_id=${q(target)}`);
  await check(`select rating_change=(select rating_change from player_rating_events where profile_id=${q(user)} and source_id=${q(target)})
    from open_queue_bookings where id=${q(third.id)}`);
  await preserved(first.id, firstBeforeMigration); await preserved(second.id, secondBefore);

  // An old cancellation appeal cannot mutate the later played rating event.
  const ratingBefore = await value(`select to_jsonb(e) from player_rating_events e where profile_id=${q(user)} and source_id=${q(target)}`);
  const appealId = await value(`insert into reliability_appeals(attendance_id,status,reviewed_by)
    values(${q(firstBeforeMigration.attendance.id)},'OVERTURNED','${admin}') returning id`);
  await check(`select apply_late_appeal_sr_correction('${admin}',${q(appealId)},${q(firstBeforeMigration.attendance.id)})`, null);
  assert.deepEqual(await value(`select to_jsonb(e) from player_rating_events e where profile_id=${q(user)} and source_id=${q(target)}`), ratingBefore); checks++;
  await preserved(first.id, firstBeforeMigration); await preserved(second.id, secondBefore);
  console.log(`${checks} isolated solo rebooking checks passed.`);
} finally {
  await db.close();
}
