// Isolated behavioral PostgreSQL checks; never connects to hosted data/Stripe.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_e2e_checkout_cleanup.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
const array = values => values == null ? 'null::uuid[]' : `array[${values.map(q).join(',')}]::uuid[]`;
let checks = 0;

function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0, `Missing migration function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= start, `Missing function terminator for ${name}`);
  return sql.slice(start, end + 4);
}
async function value(sql) {
  return Object.values((await db.query(sql)).rows[0])[0];
}
async function check(sql, expected = true) {
  assert.deepEqual(await value(sql), expected, sql);
  checks++;
}
async function rejects(sql, pattern) {
  await assert.rejects(db.exec(sql), pattern);
  checks++;
}
async function row(table, id) {
  return value(`select to_jsonb(r) from ${table} r where id=${q(id)}`);
}

try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.role() returns text language sql stable as $$
      select current_setting('request.jwt.claim.role',true)
    $$;
    select set_config('request.jwt.claim.role','service_role',false);
    create table auth.users(id uuid primary key default gen_random_uuid(),
      raw_app_meta_data jsonb not null default '{}'::jsonb,
      raw_user_meta_data jsonb not null default '{}'::jsonb);
    create table profiles(id uuid primary key,username text);
    create table referee_profiles(profile_id uuid primary key,role text,is_active boolean default true);
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'CANCELLED',
      venue text default '[FIELD E2E cleanup] regression',created_by uuid,
      starts_at timestamptz default now()+interval '14 days',
      ends_at timestamptz default now()+interval '14 days 1 hour',operational_state text default 'NORMAL',
      capacity integer default 14,goalkeeper_capacity integer default 2,defender_capacity integer default 6,
      midfielder_capacity integer default 0,attacker_capacity integer default 6);
    create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid,
      purpose text default 'SOLO_BOOKING',status text default 'PENDING',provider text default 'LEGACY',
      currency text default 'USD',amount_fils integer default 13000,
      amount_minor integer generated always as (case when currency='USD' then amount_fils/10 else amount_fils end) stored,
      payload jsonb not null,quote_snapshot jsonb not null,transaction_reference text not null unique,
      provider_intent_id text unique,provider_payment_id text,provider_status text,payment_method text,
      resource_type text,resource_id uuid,failure_reason text,captured_at timestamptz,finalized_at timestamptz,
      expires_at timestamptz default now()-interval '1 day',
      created_at timestamptz default '2025-01-01 UTC',updated_at timestamptz default '2025-01-01 UTC');
    create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,
      role text default 'DEF',status text default 'CONFIRMED',payment_intent_id uuid unique,
      provider_payment_id text,payment_method text default 'FREE',refund_status text default 'NOT_DUE');
    create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid,
      recipient_profile_id uuid,status text default 'PENDING',amount_fils integer default 13000);
    create table fixtures(id uuid primary key default gen_random_uuid(),status text default 'SCHEDULED',
      match_date date default current_date+14,time_slot text default '20:00',operational_state text default 'NORMAL',
      home_payment_intent_id uuid,away_payment_intent_id uuid);
    create table fixture_reliability_roster_history(id uuid primary key default gen_random_uuid(),
      fixture_id uuid,profile_id uuid,status text default 'CONFIRMED');
    create table match_reserve_assignments(id uuid primary key default gen_random_uuid(),match_kind text,
      fixture_id uuid,open_queue_game_id uuid,profile_id uuid,status text default 'ACTIVE');
    create table match_attendance_records(match_kind text,open_queue_game_id uuid,fixture_id uuid,
      profile_id uuid,outcome text);
    create table admin_audit_events(id uuid primary key default gen_random_uuid(),actor_referee_id uuid,
      action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
    create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$
      select ($1::text||' '||$2||' UTC')::timestamptz+interval '1 hour'
    $$;
  `);

  // Run the production immutable-quote trigger, not a permissive test substitute.
  const provider = await source('20261010001000_replace_payment_provider.sql');
  await db.exec(fn(await source('20260607010000_create_profiles.sql'), 'set_updated_at'));
  await db.exec(`create trigger set_payment_intents_updated_at before update on payment_intents
    for each row execute function set_updated_at()`);
  await db.exec(fn(provider, 'protect_payment_intent'));
  await db.exec(`create trigger protect_payment_intent before update on payment_intents
    for each row execute function protect_payment_intent()`);
  await db.exec(await source('20261012000400_cleanup_unpaid_legacy_e2e_checkouts.sql'));

  async function account(role, username, options = {}) {
    const metadata = options.metadata ?? { fieldrush_e2e: true, fieldrush_e2e_role: role };
    const id = await value(`insert into auth.users(raw_app_meta_data,raw_user_meta_data)
      values(${json(metadata)},${json(options.userMetadata ?? {})}) returning id`);
    if (username !== undefined) await db.exec(`insert into profiles values(${q(id)},${q(username)})`);
    if (options.referee) await db.exec(`insert into referee_profiles values(${q(id)},
      ${q(options.referee.role)},${options.referee.active ? 'true' : 'false'})`);
    return id;
  }
  async function game(owner, extra = {}) {
    const data = { created_by: owner, ...extra };
    return value(`insert into open_queue_games(${Object.keys(data).join(',')})
      values(${Object.values(data).map(q).join(',')}) returning id`);
  }
  async function intent(player, target, extra = {}) {
    const data = {
      profile_id: player,
      payload: { game_id: target, role: 'DEF', legacy_test_marker: 'retained' },
      quote_snapshot: { base_amount_fils: 10000, reliability_deposit_fils: 3000,
        total_fils: 13000, currency: 'USD', policy: { version: 'historical' } },
      transaction_reference: `regression_${await value('select gen_random_uuid()')}`,
      failure_reason: 'Historical failure note',
      ...extra,
    };
    const literal = ([key, val]) => ['payload', 'quote_snapshot'].includes(key) ? json(val) : q(val);
    return value(`insert into payment_intents(${Object.keys(data).join(',')})
      values(${Object.entries(data).map(literal).join(',')}) returning id`);
  }
  const actor = await account('admin', 'field_e2e_admin', { referee: { role: 'admin', active: true } });
  const eligiblePlayer = await account('player', 'field_e2e_01');
  const excludedPlayer = await account('player', 'field_e2e_02');
  const outsidePlayer = await account('player', 'field_e2e_03');
  const onboarding = await account('onboarding');
  const cancelled = await game(actor);
  const eligible = await intent(eligiblePlayer, cancelled);
  const onboardingIntent = await intent(onboarding, cancelled);
  const untouched = [];
  const exclude = async (label, extra = {}, target = cancelled, player = excludedPlayer) => {
    const id = await intent(player, target, extra);
    untouched.push({ label, id, before: await row('payment_intents', id) });
    return id;
  };

  // Historical raced attempts are seeded before the current checkout-insert
  // guard. All data lives in this fresh PGlite database, never staging.
  await exclude('unexpired', { expires_at: '2100-01-01 UTC' });
  await exclude('captured timestamp', { captured_at: '2025-02-01 UTC' });
  await exclude('finalized timestamp', { finalized_at: '2025-02-01 UTC' });
  await exclude('provider intent', { provider_intent_id: 'pi_keep_legacy' });
  await exclude('provider payment', { provider_payment_id: 'ch_keep_legacy' });
  await exclude('provider status', { provider_status: 'INITIATED' });
  await exclude('empty provider status is still evidence', { provider_status: '' });
  await exclude('resource id', { resource_id: await value('select gen_random_uuid()') });
  await exclude('resource type', { resource_type: 'OPEN_QUEUE_BOOKING' });
  await exclude('payment method', { payment_method: 'CARD' });
  await exclude('non-solo purpose', { purpose: 'CLAN_JOIN' });
  await exclude('STRIPE provider', { provider: 'STRIPE' });
  await exclude('STAGING_E2E provider', { provider: 'STAGING_E2E' });
  for (const status of ['CAPTURED', 'FINALIZED', 'FAILED', 'CANCELLED', 'EXPIRED', 'REQUIRES_REFUND', 'REFUNDED']) {
    await exclude(`terminal/non-pending status ${status}`, { status });
  }
  await exclude('active target game', {}, await game(actor, { status: 'OPEN' }));
  await exclude('foreign venue', {}, await game(actor, { venue: 'Real public venue' }));
  await exclude('non-prefix E2E marker', {}, await game(actor, { venue: 'Other [FIELD E2E cleanup]' }));
  await exclude('incomplete E2E marker', {}, await game(actor, { venue: '[FIELD E2E]' }));
  await exclude('foreign creator', {}, await game(outsidePlayer));
  await exclude('missing target game', {}, await value('select gen_random_uuid()'));
  await exclude('malformed game id', { payload: { game_id: 'not-a-uuid', role: 'DEF' } });
  await exclude('missing game id', { payload: { role: 'DEF' } });
  await exclude('outside requested pool', {}, cancelled, outsidePlayer);
  const ordinaryPlayer = await account('player', 'ordinary_player', { metadata: {} });
  await exclude('ordinary player outside requested pool', {}, cancelled, ordinaryPlayer);
  const bookedIntent = await exclude('linked cancelled booking');
  await db.exec(`insert into open_queue_bookings(game_id,profile_id,status,payment_intent_id)
    values(${q(cancelled)},${q(excludedPlayer)},'CANCELLED',${q(bookedIntent)})`);
  const refundIntent = await exclude('linked completed refund');
  await db.exec(`insert into payment_refunds(intent_id,recipient_profile_id,status)
    values(${q(refundIntent)},${q(excludedPlayer)},'SUCCEEDED')`);
  const homeIntent = await exclude('linked fixture home payment');
  const awayIntent = await exclude('linked fixture away payment');
  await db.exec(`insert into fixtures(home_payment_intent_id,away_payment_intent_id)
    values(${q(homeIntent)},${q(awayIntent)})`);

  const cleanup = (players = [eligiblePlayer, excludedPlayer, onboarding], admin = actor) =>
    `select expire_staging_e2e_legacy_checkouts(${q(admin)},${array(players)})`;
  const beforeEligible = await row('payment_intents', eligible);
  const beforeOnboarding = await row('payment_intents', onboardingIntent);
  const historyBefore = await value(`select jsonb_build_object(
    'games',(select jsonb_agg(to_jsonb(g) order by id) from open_queue_games g),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b),
    'refunds',(select jsonb_agg(to_jsonb(r) order by id) from payment_refunds r),
    'fixtures',(select jsonb_agg(to_jsonb(f) order by id) from fixtures f))`);
  const intentCount = await value('select count(*)::integer from payment_intents');

  // JWT enforcement is checked even as the database owner; ACLs are checked
  // separately so an authenticated caller cannot spoof a service-role claim.
  for (const role of ['anon', 'authenticated', '', 'admin']) {
    await db.exec(`select set_config('request.jwt.claim.role',${q(role)},false)`);
    await rejects(cleanup(), /Only the staging test service/);
  }
  await db.exec("select set_config('request.jwt.claim.role','service_role',false)");
  await check("select has_function_privilege('service_role','public.expire_staging_e2e_legacy_checkouts(uuid,uuid[])','EXECUTE')");
  for (const role of ['anon', 'authenticated']) {
    await check(`select has_function_privilege(${q(role)},'public.expire_staging_e2e_legacy_checkouts(uuid,uuid[])','EXECUTE')`, false);
    await db.exec(`set role ${role}`);
    await rejects(cleanup(), /permission denied for function/);
    await db.exec('reset role');
  }
  const invalidActors = [
    await account('admin', 'field_e2e_admin', { metadata: {}, referee: { role: 'admin', active: true } }),
    await account('admin', 'field_e2e_admin', { metadata: { fieldrush_e2e: 'true', fieldrush_e2e_role: 'admin' }, referee: { role: 'admin', active: true } }),
    await account('player', 'field_e2e_admin', { referee: { role: 'admin', active: true } }),
    await account('admin', 'ordinary_admin', { referee: { role: 'admin', active: true } }),
    await account('admin', undefined, { referee: { role: 'admin', active: true } }),
    await account('admin', 'field_e2e_admin'),
    await account('admin', 'field_e2e_admin', { referee: { role: 'referee', active: true } }),
    await account('admin', 'field_e2e_admin', { referee: { role: 'admin', active: false } }),
    null,
    await value('select gen_random_uuid()'),
  ];
  for (const invalidActor of invalidActors) await rejects(cleanup([eligiblePlayer], invalidActor), /protected active E2E administrator/);
  for (const players of [null, [], [null], [eligiblePlayer, null], [eligiblePlayer, eligiblePlayer], Array(16).fill(eligiblePlayer)]) {
    await rejects(cleanup(players), /nonempty, distinct isolated E2E account pool/);
  }
  const invalidPlayers = [
    ordinaryPlayer,
    await account('player', 'field_e2e_04', { metadata: {}, userMetadata: { fieldrush_e2e: true, fieldrush_e2e_role: 'player' } }),
    await account('player', 'field_e2e_05', { metadata: { fieldrush_e2e: 'true', fieldrush_e2e_role: 'player' } }),
    await account('player', 'field_e2e_09', { metadata: { fieldrush_e2e: false, fieldrush_e2e_role: 'player' } }),
    await account('admin', 'field_e2e_06'),
    await account('player', 'field_e2e_7'),
    await account('player', 'field_e2e_123'),
    await account('player', 'field_e2e_00'),
    await account('player', 'field_e2e_15'),
    await account('player', 'field_e2e_99'),
    await account('player', 'field_e2e_08_suffix'),
    await account('player'),
    await account('player', 'field_e2e_onboarding'),
    await account('onboarding', 'ordinary_onboarding'),
    await account('onboarding', null),
    await value('select gen_random_uuid()'),
  ];
  for (const invalidPlayer of invalidPlayers) {
    // Mixing an eligible row with an invalid account must roll back the whole
    // request rather than clean the valid subset before discovering the error.
    await rejects(cleanup([eligiblePlayer, invalidPlayer]), /unprotected E2E account/);
    await check(`select status from payment_intents where id=${q(eligible)}`, 'PENDING');
  }
  const boundaryPlayers = [];
  for (let index = 1; index <= 14; index++) boundaryPlayers.push(await account('player', `field_e2e_${String(index).padStart(2, '0')}`));
  const boundaryOnboarding = await account('onboarding');
  const extraOnboarding = await account('onboarding');
  await rejects(cleanup([...boundaryPlayers, boundaryOnboarding, extraOnboarding]), /nonempty, distinct isolated E2E account pool/);
  await check(cleanup([...boundaryPlayers, boundaryOnboarding]), []);
  await check(`select status from payment_intents where id=${q(eligible)}`, 'PENDING');
  await check('select count(*)::integer from admin_audit_events', 0);

  // Preserve the production one-game rule. Load its actual canonical functions
  // and transform the real positional-capacity trigger with the same exact
  // $old$ and $guard$ fragments that the production migration applies. The
  // unrelated quote/paid-booking RPCs are unnecessary in this small fixture.
  const oneGame = await source('20261012000100_one_active_game_per_player.sql');
  for (const name of ['player_game_blocks_registration', 'assert_player_has_one_game', 'enforce_one_player_game_checkout']) {
    await db.exec(fn(oneGame, name));
  }
  const oldGuard = oneGame.match(/anchor:=\$old\$([\s\S]*?)\$old\$;/)?.[1];
  const newGuard = oneGame.match(/execute replace\(definition,anchor,\$guard\$([\s\S]*?)\$guard\$\);/)?.[1];
  assert(oldGuard && newGuard, 'Missing exact one-game capacity transformation');
  let capacity = fn(await source('20260713000002_enforce_scheduling_limits.sql'), 'enforce_open_queue_booking_capacity');
  assert(capacity.includes(oldGuard), 'Capacity contract changed');
  capacity = capacity.replace(oldGuard, newGuard);
  await db.exec(capacity);
  await db.exec(`
    create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status
      on open_queue_bookings for each row execute function enforce_open_queue_booking_capacity();
    create trigger enforce_one_player_game_checkout before insert on payment_intents
      for each row execute function enforce_one_player_game_checkout();
  `);
  const nextGame = await game(actor, { status: 'OPEN' });
  const directBooking = (target, player = eligiblePlayer) =>
    `insert into open_queue_bookings(game_id,profile_id) values(${q(target)},${q(player)})`;
  const assertAvailable = `select assert_player_has_one_game(${q(eligiblePlayer)},'SOLO',${q(nextGame)},true)`;
  await rejects(assertAvailable, /earlier game checkout/);
  await rejects(directBooking(nextGame), /earlier game checkout/);
  await check(`select status='PENDING' and expires_at<clock_timestamp() from payment_intents where id=${q(eligible)}`);

  const expired = await value(cleanup());
  assert.deepEqual([...expired].sort(), [eligible, onboardingIntent].sort()); checks++;
  for (const [id, before] of [[eligible, beforeEligible], [onboardingIntent, beforeOnboarding]]) {
    const after = await row('payment_intents', id);
    assert.equal(after.status, 'EXPIRED'); checks++;
    assert.match(after.failure_reason, new RegExp(`^Expired unpaid retired-provider E2E checkout.*${actor}\\.$`)); checks++;
    // Quote, owner, provider, payload, amount, created/captured/finalized times
    // and historical payment evidence are retained. The only explicit changes
    // are status/failure_reason; the production timestamp trigger additionally
    // advances updated_at as expected for an operational state transition.
    const { status: oldStatus, failure_reason: oldReason, updated_at: oldUpdatedAt, ...beforeInvariant } = before;
    const { status: newStatus, failure_reason: newReason, updated_at: newUpdatedAt, ...afterInvariant } = after;
    assert.deepEqual(afterInvariant, beforeInvariant, `Immutable checkout history ${id}`); checks++;
    assert(new Date(newUpdatedAt) > new Date(oldUpdatedAt), 'Operational updated_at must advance'); checks++;
    await check(`select before_state=${json(before)} and after_state=${json(after)}
      and actor_referee_id=${q(actor)} and action='E2E_LEGACY_CHECKOUT_EXPIRED' and entity_type='ACTION'
      from admin_audit_events where entity_id=${q(id)}`);
  }
  for (const { label, id, before } of untouched) {
    assert.deepEqual(await row('payment_intents', id), before, `${label} must remain untouched`); checks++;
  }
  await check('select count(*)::integer from payment_intents', intentCount);
  await check(`select jsonb_build_object(
    'games',(select jsonb_agg(to_jsonb(g) order by id) from open_queue_games g where id<>${q(nextGame)}),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b),
    'refunds',(select jsonb_agg(to_jsonb(r) order by id) from payment_refunds r),
    'fixtures',(select jsonb_agg(to_jsonb(f) order by id) from fixtures f))`, historyBefore);
  await check('select count(*)::integer from admin_audit_events', 2);
  await check(cleanup(), []);
  await check('select count(*)::integer from admin_audit_events', 2);
  await db.exec(assertAvailable); checks++;
  await db.exec(directBooking(nextGame)); checks++;
  await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(eligiblePlayer)}`, 1);
  // Cleanup unblocks only the stale lease; it does not allow a second real game.
  const competingGame = await game(actor, { status: 'OPEN' });
  await rejects(directBooking(competingGame), /one upcoming or active game/);
  await rejects(`select assert_player_has_one_game(${q(eligiblePlayer)},'SOLO',${q(competingGame)},true)`, /one upcoming or active game/);
  await rejects(`update payment_intents set amount_fils=14000 where id=${q(eligible)}`, /checkout quote and its owner cannot change/);
  await rejects(`update payment_intents set status='PENDING' where id=${q(eligible)}`, /completed payment state cannot regress/);
  await check(`select status from payment_intents where id=${q(eligible)}`, 'EXPIRED');

  // Every documented onboarding profile state is accepted. A fresh actor with
  // no profile was exercised above; a completed and an Auth fallback profile
  // are covered here with the same protected app metadata.
  const namedOnboarding = await account('onboarding', 'field_e2e_onboarding');
  const fallbackOnboarding = await account('onboarding');
  await db.exec(`insert into profiles values(${q(fallbackOnboarding)},
    ${q(`e2e_${fallbackOnboarding.replaceAll('-', '').slice(0, 12)}`)})`);
  const onboardingVariants = [
    await intent(namedOnboarding, cancelled),
    await intent(fallbackOnboarding, cancelled),
  ];
  const variantBefore = await Promise.all(onboardingVariants.map(id => row('payment_intents', id)));
  assert.deepEqual([...(await value(cleanup([namedOnboarding, fallbackOnboarding])))].sort(), onboardingVariants.sort()); checks++;
  for (let index = 0; index < onboardingVariants.length; index++) {
    const after = await row('payment_intents', variantBefore[index].id);
    const { status, failure_reason, updated_at: updatedAt, ...invariant } = after;
    const { status: beforeStatus, failure_reason: beforeReason, updated_at: beforeUpdatedAt, ...beforeInvariant } = variantBefore[index];
    assert.equal(status, 'EXPIRED'); checks++;
    assert.deepEqual(invariant, beforeInvariant); checks++;
    assert(new Date(updatedAt) > new Date(beforeUpdatedAt), 'Operational updated_at must advance'); checks++;
  }
  await check('select count(*)::integer from admin_audit_events', 4);

  // An expired provider-backed lease remains a lease. Neither cleanup nor the
  // one-game rule may treat the old local expires_at as provider cancellation.
  for (const providerName of ['STRIPE', 'STAGING_E2E']) {
    const player = boundaryPlayers[providerName === 'STRIPE' ? 10 : 11];
    const id = await intent(player, cancelled, { provider: providerName });
    const before = await row('payment_intents', id);
    await check(cleanup([player]), []);
    assert.deepEqual(await row('payment_intents', id), before); checks++;
    await rejects(`select assert_player_has_one_game(${q(player)},'SOLO',${q(nextGame)},true)`, /earlier game checkout/);
    await rejects(directBooking(nextGame, player), /earlier game checkout/);
  }

  // Payment mutation and its audit record form one transaction, including a
  // batch where the first attempt has already been updated before audit of the
  // second attempt fails. No half-cleaned pool or missing history may remain.
  const rollbackPlayers = boundaryPlayers.slice(12, 14);
  const rollbackIds = [await intent(rollbackPlayers[0], cancelled), await intent(rollbackPlayers[1], cancelled)];
  const rollbackBefore = await Promise.all(rollbackIds.map(id => row('payment_intents', id)));
  const secondAttempt = [...rollbackIds].sort()[1];
  await db.exec(`create function reject_test_cleanup_audit() returns trigger language plpgsql as $$
    begin if new.entity_id=${q(secondAttempt)} then raise exception 'Injected E2E audit failure'; end if;
    return new; end;
    $$;
    create trigger reject_test_cleanup_audit before insert on admin_audit_events
      for each row execute function reject_test_cleanup_audit()`);
  await rejects(cleanup(rollbackPlayers), /Injected E2E audit failure/);
  for (const before of rollbackBefore) {
    assert.deepEqual(await row('payment_intents', before.id), before, 'Audit failure must roll back every payment update'); checks++;
  }
  await check('select count(*)::integer from admin_audit_events', 4);
  await db.exec('drop trigger reject_test_cleanup_audit on admin_audit_events');
  assert.deepEqual([...(await value(cleanup(rollbackPlayers)))].sort(), [...rollbackIds].sort()); checks++;
  await check('select count(*)::integer from admin_audit_events', 6);
  await check(cleanup(rollbackPlayers), []);
  await check('select count(*)::integer from admin_audit_events', 6);

  // PGlite serializes statements, so hosted multi-session lock stress is not
  // performed. Verify the real function keeps conflicting game/intent locks
  // and the player advisory lock used by production registration guards.
  await check(`select regexp_replace(lower(prosrc),'\\s+',' ','g')
    like '%order by i.id for update of i for share of g%'
    from pg_proc where oid='public.expire_staging_e2e_legacy_checkouts(uuid,uuid[])'::regprocedure`);
  await check(`select prosrc like '%pg_advisory_xact_lock(hashtext(player_id::text)::bigint)%'
    and prosecdef and proconfig=array['search_path=public, pg_temp']
    from pg_proc where oid='public.expire_staging_e2e_legacy_checkouts(uuid,uuid[])'::regprocedure`);

  console.log(`e2e-checkout-cleanup: ${checks} isolated behavioral checks passed`);
} finally {
  await db.close();
}
