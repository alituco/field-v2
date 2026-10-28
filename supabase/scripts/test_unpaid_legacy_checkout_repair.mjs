// Isolated PostgreSQL checks for the one-record operational repair. No hosted
// data, gateway calls or real account identifiers are used.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_unpaid_legacy_checkout_repair.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const migration = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
let checks = 0;

function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0, `Missing production function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= start, `Missing function terminator for ${name}`);
  return sql.slice(start, end + 4);
}
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) {
  assert.deepEqual(await value(sql), expected, sql); checks++;
}
async function row(table, id) {
  return value(`select to_jsonb(r) from ${table} r where id=${q(id)}`);
}

try {
  const repairSql = await readFile(new URL('./expire_unpaid_legacy_checkout.sql', import.meta.url), 'utf8');
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create table profiles(id uuid primary key default gen_random_uuid(),username text);
    create table referee_profiles(profile_id uuid primary key references profiles(id),role text,is_active boolean default true);
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'CANCELLED',
      venue text default 'Isolated legacy repair fixture',created_by uuid,
      ends_at timestamptz default now()+interval '14 days',operational_state text default 'NORMAL');
    create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid not null references profiles(id),
      purpose text default 'SOLO_BOOKING',status text default 'PENDING',provider text default 'LEGACY',
      currency text default 'BHD',amount_fils integer default 8000,
      amount_minor integer generated always as (case when currency='USD' then amount_fils/10 else amount_fils end) stored,
      payload jsonb not null,quote_snapshot jsonb not null,transaction_reference text not null unique,
      provider_intent_id text unique,provider_payment_id text,provider_status text,payment_method text,
      resource_type text,resource_id uuid,failure_reason text,captured_at timestamptz,finalized_at timestamptz,
      expires_at timestamptz default now()-interval '1 day',
      created_at timestamptz default '2025-01-01 UTC',updated_at timestamptz default '2025-01-01 UTC');
    create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,
      status text default 'CONFIRMED',payment_intent_id uuid references payment_intents(id));
    create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid references payment_intents(id),
      status text default 'PENDING',amount_fils integer default 8000);
    create table fixtures(id uuid primary key default gen_random_uuid(),status text default 'SCHEDULED',
      match_date date default current_date+14,time_slot text default '20:00',operational_state text default 'NORMAL',
      home_payment_intent_id uuid references payment_intents(id),away_payment_intent_id uuid references payment_intents(id));
    create table fixture_reliability_roster_history(id uuid primary key default gen_random_uuid(),
      fixture_id uuid,profile_id uuid,status text default 'CONFIRMED');
    create table match_reserve_assignments(id uuid primary key default gen_random_uuid(),match_kind text,
      fixture_id uuid,open_queue_game_id uuid,profile_id uuid,status text default 'ACTIVE');
    create table match_attendance_records(match_kind text,open_queue_game_id uuid,fixture_id uuid,profile_id uuid,outcome text);
    create table admin_audit_events(id bigint generated always as identity primary key,
      actor_referee_id uuid not null references referee_profiles(profile_id),
      action text not null check(char_length(trim(action)) between 2 and 100),
      entity_type text not null check(entity_type='ACTION'),entity_id uuid not null,
      reason text not null check(char_length(reason)<=2000),before_state jsonb not null,after_state jsonb not null,
      created_at timestamptz not null default now());
    create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$
      select ($1::text||' '||$2||' UTC')::timestamptz+interval '1 hour'
    $$;
  `);
  await db.exec(fn(await migration('20260607010000_create_profiles.sql'), 'set_updated_at'));
  await db.exec(fn(await migration('20261010001000_replace_payment_provider.sql'), 'protect_payment_intent'));
  await db.exec(`
    create trigger set_payment_intents_updated_at before update on payment_intents
      for each row execute function set_updated_at();
    create trigger protect_payment_intent before update on payment_intents
      for each row execute function protect_payment_intent();
  `);
  const oneGame = await migration('20261012000100_one_active_game_per_player.sql');
  for (const name of ['player_game_blocks_registration', 'assert_player_has_one_game']) {
    await db.exec(fn(oneGame, name));
  }

  async function account(role = null, active = true) {
    const id = await value("insert into profiles(username) values('isolated_repair_user') returning id");
    if (role) await db.exec(`insert into referee_profiles values(${q(id)},${q(role)},${active})`);
    return id;
  }
  async function game(status = 'CANCELLED') {
    return value(`insert into open_queue_games(status) values(${q(status)}) returning id`);
  }
  async function intent(player, target, extra = {}) {
    const data = {
      profile_id: player,
      payload: { game_id: target, role: 'DEF', historical_marker: 'preserve' },
      quote_snapshot: { base_amount_fils: 7000, reliability_deposit_fils: 1000, total_fils: 8000, currency: 'BHD' },
      transaction_reference: `isolated_repair_${await value('select gen_random_uuid()')}`,
      failure_reason: 'Historical failure note',
      ...extra,
    };
    return value(`insert into payment_intents(${Object.keys(data).join(',')})
      values(${Object.entries(data).map(([key, val]) => ['payload', 'quote_snapshot'].includes(key) ? json(val) : q(val)).join(',')}) returning id`);
  }
  const admin = await account('admin');
  const player = await account();
  const cancelled = await game();
  const target = await intent(player, cancelled);
  const reason = 'Close an expired, uncaptured retired-provider checkout for its cancelled game after verified support review.';
  const defaults = { intent_id: target, profile_id: player, game_id: cancelled, admin_id: admin, reason };

  async function repair(overrides = {}) {
    const settings = { ...defaults, ...overrides };
    await db.exec('begin');
    try {
      for (const [key, val] of Object.entries(settings)) {
        await db.query('select set_config($1,$2,true)', [`field.repair_${key}`, val ?? '']);
      }
      await db.exec(repairSql);
      await db.exec('commit');
    } catch (error) {
      await db.exec('rollback');
      throw error;
    }
  }
  async function rejectRepair(overrides = {}, pattern = /./s) {
    const before = await value('select jsonb_agg(to_jsonb(i) order by id) from payment_intents i');
    const audits = await value('select count(*)::integer from admin_audit_events');
    await assert.rejects(repair(overrides), pattern); checks++;
    await check('select jsonb_agg(to_jsonb(i) order by id) from payment_intents i', before);
    await check('select count(*)::integer from admin_audit_events', audits);
  }
  const nextGame = await game('OPEN');
  const available = (person = player) => `select assert_player_has_one_game(${q(person)},'SOLO',${q(nextGame)},true)`;
  await assert.rejects(db.exec(available()), /earlier game checkout/); checks++;

  // Wrong selectors, absent evidence and non-admin actors cannot authorize a repair.
  for (const key of ['intent_id', 'profile_id', 'game_id', 'admin_id']) {
    await rejectRepair({ [key]: null });
    await rejectRepair({ [key]: 'not-a-uuid' });
    await rejectRepair({ [key]: await value('select gen_random_uuid()') });
  }
  for (const invalidAdmin of [await account('referee'), await account('admin', false), player]) {
    await rejectRepair({ admin_id: invalidAdmin });
  }
  for (const invalidReason of ['', '   ', 'Too short', 'x'.repeat(1001)]) await rejectRepair({ reason: invalidReason });
  await rejectRepair({ profile_id: await account() });
  await rejectRepair({ game_id: await game() });

  const exclusions = [
    ['missing expiry evidence', { expires_at: null }],
    ['unexpired', { expires_at: '2100-01-01 UTC' }],
    ['captured timestamp', { captured_at: '2025-02-01 UTC' }],
    ['finalized timestamp', { finalized_at: '2025-02-01 UTC' }],
    ['provider intent', { provider_intent_id: 'pi_isolated_evidence' }],
    ['provider charge', { provider_payment_id: 'ch_isolated_evidence' }],
    ['provider status', { provider_status: 'INITIATED' }],
    ['empty provider status is still evidence', { provider_status: '' }],
    ['resource id', { resource_id: await value('select gen_random_uuid()') }],
    ['resource type', { resource_type: 'OPEN_QUEUE_BOOKING' }],
    ['payment method', { payment_method: 'CARD' }],
    ['non-solo', { purpose: 'CLAN_JOIN' }],
    ['Stripe', { provider: 'STRIPE' }],
    ['synthetic', { provider: 'STAGING_E2E' }],
    ['malformed payload game', { payload: { game_id: 'not-a-uuid' } }],
    ['missing payload game', { payload: { role: 'DEF' } }],
    ...['CAPTURED', 'FINALIZED', 'FAILED', 'CANCELLED', 'EXPIRED', 'REQUIRES_REFUND', 'REFUNDED']
      .map(status => [status, { status }]),
  ];
  for (const [label, extra] of exclusions) {
    const id = await intent(player, cancelled, extra);
    const before = await row('payment_intents', id);
    await rejectRepair({ intent_id: id });
    assert.deepEqual(await row('payment_intents', id), before, `${label} must remain unchanged`); checks++;
  }
  const live = await game('LIVE');
  const liveAttempt = await intent(player, live);
  await rejectRepair({ intent_id: liveAttempt, game_id: live });
  const active = await game('OPEN');
  const activeAttempt = await intent(player, active);
  await rejectRepair({ intent_id: activeAttempt, game_id: active });
  for (const kind of ['cancelled booking', 'completed refund', 'home fixture', 'away fixture']) {
    const id = await intent(player, cancelled);
    if (kind === 'cancelled booking') {
      await db.exec(`insert into open_queue_bookings(game_id,profile_id,status,payment_intent_id)
        values(${q(cancelled)},${q(player)},'CANCELLED',${q(id)})`);
    } else if (kind === 'completed refund') {
      await db.exec(`insert into payment_refunds(intent_id,status) values(${q(id)},'SUCCEEDED')`);
    } else {
      await db.exec(`insert into fixtures(${kind === 'home fixture' ? 'home' : 'away'}_payment_intent_id) values(${q(id)})`);
    }
    await rejectRepair({ intent_id: id });
  }

  // Ordinary database roles receive no new privileges from this operational script.
  for (const role of ['anon', 'authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(repair(), /permission denied/); checks++;
    await db.exec('reset role');
  }

  // One legitimate repair is atomic with its full audit history. Other player
  // rows intentionally retain pending states, so use a fresh owner for this case.
  const cleanPlayer = await account();
  const clean = await intent(cleanPlayer, cancelled);
  const repairClean = { intent_id: clean, profile_id: cleanPlayer };
  const before = await row('payment_intents', clean);
  const historyBefore = await value(`select jsonb_build_object(
    'games',(select jsonb_agg(to_jsonb(g) order by id) from open_queue_games g),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b),
    'refunds',(select jsonb_agg(to_jsonb(r) order by id) from payment_refunds r),
    'fixtures',(select jsonb_agg(to_jsonb(f) order by id) from fixtures f))`);
  const otherIntents = await value(`select jsonb_agg(to_jsonb(i) order by id) from payment_intents i where id<>${q(clean)}`);
  await assert.rejects(db.exec(available(cleanPlayer)), /earlier game checkout/); checks++;
  await db.exec(`create function reject_repair_audit() returns trigger language plpgsql as $$
    begin raise exception 'Injected repair audit failure'; end; $$;
    create trigger reject_repair_audit before insert on admin_audit_events
      for each row execute function reject_repair_audit()`);
  await rejectRepair(repairClean, /Injected repair audit failure/);
  assert.deepEqual(await row('payment_intents', clean), before); checks++;
  await db.exec('drop trigger reject_repair_audit on admin_audit_events');
  await repair(repairClean);
  const after = await row('payment_intents', clean);
  assert.equal(after.status, 'EXPIRED'); checks++;
  assert.notEqual(after.failure_reason, before.failure_reason); checks++;
  const { status: oldStatus, failure_reason: oldReason, updated_at: oldUpdated, ...beforeImmutable } = before;
  const { status: newStatus, failure_reason: newReason, updated_at: newUpdated, ...afterImmutable } = after;
  assert.deepEqual(afterImmutable, beforeImmutable); checks++;
  assert(new Date(newUpdated) > new Date(oldUpdated)); checks++;
  await check(`select actor_referee_id=${q(admin)} and action='UNPAID_LEGACY_CHECKOUT_EXPIRED'
    and entity_type='ACTION' and reason=${q(reason)} and before_state=${json(before)} and after_state=${json(after)}
    from admin_audit_events where entity_id=${q(clean)}`);
  await check(`select jsonb_agg(to_jsonb(i) order by id) from payment_intents i where id<>${q(clean)}`, otherIntents);
  await check(`select jsonb_build_object(
    'games',(select jsonb_agg(to_jsonb(g) order by id) from open_queue_games g),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b),
    'refunds',(select jsonb_agg(to_jsonb(r) order by id) from payment_refunds r),
    'fixtures',(select jsonb_agg(to_jsonb(f) order by id) from fixtures f))`, historyBefore);
  await db.exec(available(cleanPlayer)); checks++;
  await repair(repairClean);
  assert.deepEqual(await row('payment_intents', clean), after); checks++;
  await check('select count(*)::integer from admin_audit_events', 1);
  await rejectRepair({ ...repairClean, admin_id: await account('admin') });
  await rejectRepair({ ...repairClean, reason: 'A different operation must not reuse the earlier audit acknowledgement.' });
  await assert.rejects(db.exec(`update payment_intents set amount_fils=9000 where id=${q(clean)}`), /checkout quote and its owner cannot change/); checks++;
  await assert.rejects(db.exec(`update payment_intents set status='PENDING' where id=${q(clean)}`), /completed payment state cannot regress/); checks++;

  // Even an expired local deadline cannot release another provider-backed
  // checkout. A real booking still enforces the original single-game rule.
  const pendingOther = await intent(cleanPlayer, active, { provider: 'STRIPE', provider_intent_id: 'pi_keep_lease' });
  await assert.rejects(db.exec(available(cleanPlayer)), /earlier game checkout/); checks++;
  await repair(repairClean);
  await check(`select status from payment_intents where id=${q(pendingOther)}`, 'PENDING');
  await assert.rejects(db.exec(available(cleanPlayer)), /earlier game checkout/); checks++;
  await db.exec(`insert into open_queue_bookings(game_id,profile_id) values(${q(active)},${q(cleanPlayer)})`);
  await assert.rejects(db.exec(available(cleanPlayer)), /one upcoming or active game/); checks++;

  // PGlite serializes statements: this suite verifies behavior and the actual
  // production guard, not a multi-session PostgreSQL lock-contention scenario.
  console.log(`unpaid-legacy-checkout-repair: ${checks} isolated behavioral checks passed`);
} finally {
  await db.close();
}
