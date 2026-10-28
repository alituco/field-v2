// Isolated PostgreSQL behavioral checks; never connects to hosted data/Stripe.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_game_division_ranges.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
const admin = '10000000-0000-0000-0000-000000000001';
const nonAdmin = '10000000-0000-0000-0000-000000000002';
const inactiveAdmin = '10000000-0000-0000-0000-000000000003';
let checks = 0;

function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0, `Missing migration function ${name}`);
  const end = sql.indexOf('\n$$;', start);
  assert(end >= start, `Missing function terminator for ${name}`);
  return sql.slice(start, end + 4);
}
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected = true) { assert.deepEqual(await value(sql), expected, sql); checks++; }
async function rejects(sql, pattern) { await assert.rejects(db.exec(sql), pattern); checks++; }
async function rejectedPromise(promise, pattern) { await assert.rejects(promise, pattern); checks++; }

try {
  // Minimal table contracts for the real production functions. Account and
  // reliability source lookups are isolated fixtures, not eligibility replicas.
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
    create table fieldrush_private.accounts(user_id uuid primary key);
    create function is_fieldrush_account_active(uuid) returns boolean language sql stable as $$
      select exists(select 1 from fieldrush_private.accounts where user_id=$1)
    $$;
    create table test_restrictions(profile_id uuid primary key);
    create function profile_has_active_reliability_booking_restriction(uuid) returns boolean language sql stable as $$
      select exists(select 1 from test_restrictions where profile_id=$1)
    $$;
    create function active_reliability_strikes(uuid,timestamptz default now()) returns integer language sql stable as $$select 0$$;
    create function fixture_start_at(date,text) returns timestamptz language sql immutable as $$
      select ($1::text||' '||$2||' UTC')::timestamptz
    $$;
    create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$
      select fixture_start_at($1,$2)+interval '1 hour'
    $$;
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
    create table open_queue_games(id uuid primary key default gen_random_uuid(),status text not null default 'OPEN',
      venue text not null default 'Isolated test pitch',starts_at timestamptz not null,ends_at timestamptz not null,
      timezone text not null default 'America/Phoenix',currency text not null default 'USD',
      format_version text not null default 'FIELDRUSH_7V7',price_fils integer not null default 13000,
      age_label text not null default '18+',created_by uuid,operational_state text default 'NORMAL',
      capacity integer default 14,goalkeeper_capacity integer default 2,defender_capacity integer default 6,
      midfielder_capacity integer default 0,attacker_capacity integer default 6,teams_assigned_at timestamptz,
      replacement_discount_bps integer default 0,replacement_discount_role text,
      replacement_offer_expires_at timestamptz,replacement_source_booking_id uuid,
      constraint open_queue_games_versioned_format_check check (
        (format_version='LEGACY_6V6' and currency='BHD' and timezone='Asia/Bahrain' and capacity=12)
        or (format_version='FIELDRUSH_7V7' and currency='USD' and timezone='America/Phoenix' and capacity=14 and price_fils%10=0)));
    create unique index open_queue_games_one_active_start_idx on open_queue_games(starts_at) where status<>'CANCELLED';
    create unique index open_queue_games_venue_start_unique_idx on open_queue_games(lower(venue),starts_at) where status<>'CANCELLED';
    create table match_reliability_terms(id uuid default gen_random_uuid(),open_queue_game_id uuid,
      policy_version_id uuid,check_in_deadline_at timestamptz,policy_snapshot jsonb);
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
      role text default 'DEF',status text default 'CONFIRMED',player_rating_at_booking integer,
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
    create function assign_open_queue_teams(uuid) returns void language sql as $$
      update open_queue_games set status='FULL' where id=$1
    $$;
  `);
  await db.exec(fn(await source('20260607010000_create_profiles.sql'), 'set_updated_at'));
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
  const provider = await source('20261010001000_replace_payment_provider.sql');
  const providerStart = provider.lastIndexOf('do $migration$', provider.indexOf("  definition:=pg_get_functiondef('public.book_open_queue_game_server"));
  await db.exec(provider.slice(providerStart, provider.indexOf('$migration$;', providerStart) + 13));
  for (const name of ['protect_payment_intent','request_payment_refund','finalize_payment_intent','record_stripe_payment_capture','finalize_free_checkout']) {
    await db.exec(fn(provider, name));
  }
  await db.exec('create trigger protect_payment_intent before update on payment_intents for each row execute function protect_payment_intent()');
  await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'), 'enforce_open_queue_booking_capacity'));
  await db.exec(`create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status
    on open_queue_bookings for each row execute function enforce_open_queue_booking_capacity()`);
  await db.exec(await source('20261010001500_checkout_eligibility_preflight.sql'));
  await db.exec(fn(await source('20261010000000_fieldrush_phoenix_game_format.sql'), 'enforce_open_queue_permanent_schedule'));
  await db.exec(`create trigger enforce_open_queue_permanent_schedule before insert or update of status,starts_at,ends_at,timezone
    on open_queue_games for each row execute function enforce_open_queue_permanent_schedule()`);
  await db.exec(fn(await source('20260713000007_create_open_queue_player_sr_system.sql'), 'referee_start_open_queue_game'));
  await db.exec(await source('20261011000100_saved_fields_and_game_locations.sql'));
  await db.exec(await source('20261011000200_configurable_solo_schedules.sql'));
  await db.exec(await source('20261011000400_enforce_bookable_game_prices.sql'));
  const prices = await source('20261011000300_edit_solo_game_prices.sql');
  const priceStart = prices.indexOf('do $migration$');
  await db.exec(prices.slice(priceStart, prices.indexOf('$migration$;', priceStart) + 13));
  await db.exec(await source('20261012000100_one_active_game_per_player.sql'));

  const savedField = await value(`select admin_save_field('${admin}',null,
    ${json({name:'Division test pitch',address:'123 Regression Road',latitude:33.45,longitude:-112.08})})`);
  const field = savedField.id;
  let gameCounter = 0;
  async function game(extra = {}) {
    const start = await value(`select ('2099-01-01T00:00:00-07:00'::timestamptz+interval '${gameCounter++ * 3} hours')::text`);
    const data = { starts_at: start, ends_at: await value(`select (${q(start)}::timestamptz+interval '1 hour')::text`), ...extra };
    const id = await value(`insert into open_queue_games(${Object.keys(data).join(',')})
      values(${Object.values(data).map(q).join(',')}) returning id`);
    await db.exec(`insert into match_reliability_terms(open_queue_game_id,policy_version_id,check_in_deadline_at,policy_snapshot)
      values(${q(id)},gen_random_uuid(),${q(start)}::timestamptz-interval '1 hour',
      '{"replacement":{"postCheckInDeadlineMarketplaceEnabled":false},"solo":{"reliabilityDeposit":{"activeStrikeThreshold":2,"depositBps":2000}}}')`);
    return id;
  }
  async function player(rating = 1200, played = 2, withRating = true) {
    const id = await value('insert into fieldrush_private.accounts values(gen_random_uuid()) returning user_id');
    if (withRating) await db.exec(`insert into player_ratings values(${q(id)},${q(rating)},${q(played)})`);
    return id;
  }
  async function asPlayer(id) { await db.exec(`select set_config('request.jwt.claim.sub',${q(id)},false)`); }
  async function quote(target, user) {
    await asPlayer(user);
    return value(`select preview_open_queue_booking_cost(${q(target)},'DEF')`);
  }
  async function paymentIntent(target, user) {
    const quoted = await quote(target, user);
    return value(`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot,provider_intent_id,transaction_reference)
      values(${q(user)},${quoted.total_fils},${json({game_id:target,role:'DEF'})},${json(quoted)},
      'pi_'||gen_random_uuid(),'test_'||gen_random_uuid()) returning id`);
  }
  const capture = id => value(`select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD')
    from payment_intents where id=${q(id)}`);
  const direct = (target, user, extra = '') => `insert into open_queue_bookings(game_id,profile_id${extra ? ',payment_intent_id' : ''})
    values(${q(target)},${q(user)}${extra ? `,${q(extra)}` : ''})`;
  const book = target => `select book_open_queue_game_server(${q(target)},'DEF','FREE',null)`;
  const save = (values, id = null, actor = admin) => value(`select admin_save_game_schedule(${q(actor)},${q(id)},${json(values)})`);
  const createGame = (highest, lowest, actor = admin, price = 13000, extraArgs = true) =>
    `select admin_create_open_queue_game(${q(actor)},${q(field)}::uuid,
      '2098-01-01T10:00:00-07:00'::timestamptz,${price},'18+',60${extraArgs ? `,${q(highest)}::integer,${q(lowest)}::integer` : ''})`;

  // Seed pre-migration games, bookings and a schedule to verify the additive
  // defaults and preservation of paid/history rows, not merely new inserts.
  const existingGame = await game();
  const grandfathered = await player(1600, 2);
  const grandfatheredIntent = await paymentIntent(existingGame, grandfathered);
  assert.equal((await capture(grandfatheredIntent)).status, 'FINALIZED'); checks++;
  const existingGameBefore = await value(`select to_jsonb(g) from open_queue_games g where id=${q(existingGame)}`);
  const existingBookings = await value('select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b');
  const existingPayments = await value('select jsonb_agg(to_jsonb(i) order by id) from payment_intents i');
  const tomorrow = await value("select ((now() at time zone 'America/Phoenix')::date+1)::text");
  const scheduleDetails = {name:'Divisions rolling schedule',field_id:field,weekdays:[1,2,3,4,5,6,7],
    kickoff_time:'18:00',starts_on:tomorrow,booking_window_days:7,is_active:false};
  const legacySchedule = await save(scheduleDetails);
  const legacyScheduleBefore = await value(`select to_jsonb(s) from game_schedules s where id=${q(legacySchedule.id)}`);

  // Execute the complete feature migration and all exact patch anchors against
  // the real prior quote/booking/capacity/schedule/generator function bodies.
  await db.exec(await source('20261012000500_game_division_ranges.sql'));
  checks++;
  await check(`select highest_division=1 and lowest_division=5 from open_queue_games where id=${q(existingGame)}`);
  await check(`select to_jsonb(g)-'highest_division'-'lowest_division' from open_queue_games g where id=${q(existingGame)}`, existingGameBefore);
  await check(`select highest_division=1 and lowest_division=5 from game_schedules where id=${q(legacySchedule.id)}`);
  await check(`select to_jsonb(s)-'highest_division'-'lowest_division' from game_schedules s where id=${q(legacySchedule.id)}`, legacyScheduleBefore);
  await check('select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b', existingBookings);
  await check('select jsonb_agg(to_jsonb(i) order by id) from payment_intents i', existingPayments);

  // Threshold boundary values, including the exact two-match reveal cutoff.
  const thresholds = [[-1,5],[0,5],[1099,5],[1100,4],[1299,4],[1300,3],[1499,3],[1500,2],[1649,2],[1650,1],[9999,1]];
  for (const [rating, division] of thresholds) await check(`select fieldrush_division_for_rating(${rating})`, division);
  for (const [rating, division] of thresholds) {
    const target = await game({highest_division:division,lowest_division:division,price_fils:0});
    const user = await player(rating, 2);
    assert.equal((await quote(target, user)).total_fils, 0); checks++;
    await db.exec(book(target)); checks++;
    await check(`select count(*)::integer from open_queue_bookings where game_id=${q(target)} and profile_id=${q(user)}`, 1);
  }
  for (const played of [0, 1, null]) {
    const placement = await player(1700, played);
    const unrestricted = await game({highest_division:1,lowest_division:5,price_fils:0});
    const restricted = await game({highest_division:1,lowest_division:1,price_fils:0});
    await rejectedPromise(quote(restricted, placement), /Placement players can only join/);
    await asPlayer(placement);
    await rejects(book(restricted), /Placement players can only join/);
    await rejects(direct(restricted, placement), /Placement players can only join/);
    assert.equal((await quote(unrestricted, placement)).total_fils, 0); checks++;
    await db.exec(book(unrestricted)); checks++;
  }
  const noRating = await player(1200, 0, false);
  const noRatingRestricted = await game({highest_division:4,lowest_division:5,price_fils:0});
  await rejectedPromise(quote(noRatingRestricted, noRating), /Placement players can only join/);
  await rejects(direct(noRatingRestricted, noRating), /Placement players can only join/);
  const noRatingOpen = await game({price_fils:0});
  await asPlayer(noRating);
  await db.exec(book(noRatingOpen)); checks++;
  const allRangesPlacement = await player(1700, 1);
  for (let highest = 1; highest <= 5; highest++) {
    for (let lowest = highest; lowest <= 5; lowest++) {
      const target = await game({highest_division:highest,lowest_division:lowest,price_fils:0});
      if (highest === 1 && lowest === 5) {
        assert.equal((await quote(target, allRangesPlacement)).total_fils, 0); checks++;
      } else {
        await rejectedPromise(quote(target, allRangesPlacement), /Placement players can only join/);
        await rejects(direct(target, allRangesPlacement), /Placement players can only join/);
      }
    }
  }

  // Inclusive ranges allow either boundary, but cannot be bypassed through the
  // quote, production booking RPC or direct service-owned booking insertion.
  const middleRange = await game({highest_division:2,lowest_division:4,price_fils:0});
  for (const rating of [1100,1300,1500]) {
    const user = await player(rating);
    assert.equal((await quote(middleRange, user)).total_fils, 0); checks++;
    await db.exec(book(middleRange)); checks++;
  }
  for (const rating of [1099,1650]) {
    const user = await player(rating);
    await rejectedPromise(quote(middleRange, user), /This game is for DIV 2–4/);
    await asPlayer(user);
    await rejects(book(middleRange), /This game is for DIV 2–4/);
    await rejects(direct(middleRange, user), /This game is for DIV 2–4/);
    await rejects(direct(middleRange, user, await value('select gen_random_uuid()')), /This game is for DIV 2–4/);
  }

  // A rating change between stale quote and booking is checked at registration.
  const changingPlayer = await player(1300);
  assert.equal((await quote(middleRange, changingPlayer)).total_fils, 0); checks++;
  await db.exec(`update player_ratings set skill_rating=1700 where profile_id=${q(changingPlayer)}`);
  await rejects(book(middleRange), /This game is for DIV 2–4/);
  await rejects(direct(middleRange, changingPlayer), /This game is for DIV 2–4/);
  await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(changingPlayer)}`, 0);

  // Real paid finalization also applies the range. A captured stale checkout
  // cannot bypass a new division mismatch or manufacture a second booking;
  // money is retained in history and the established durable refund path runs.
  const paidRange = await game({highest_division:2,lowest_division:3});
  const paidEligible = await player(1500);
  const successfulIntent = await paymentIntent(paidRange, paidEligible);
  const paidResult = await capture(successfulIntent);
  assert.equal(paidResult.status, 'FINALIZED'); checks++;
  await check(`select status='CONFIRMED' and amount_paid_fils=13000 and payment_method='CARD'
    from open_queue_bookings where payment_intent_id=${q(successfulIntent)}`);
  const stalePaidPlayer = await player(1300);
  const staleIntent = await paymentIntent(paidRange, stalePaidPlayer);
  const staleBefore = await value(`select to_jsonb(i) from payment_intents i where id=${q(staleIntent)}`);
  await db.exec(`update player_ratings set skill_rating=1650 where profile_id=${q(stalePaidPlayer)}`);
  const failedResult = await capture(staleIntent);
  assert.equal(failedResult.status, 'REQUIRES_REFUND'); checks++;
  assert.match(failedResult.failure_reason, /This game is for DIV 2–3/); checks++;
  await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(stalePaidPlayer)}`, 0);
  await check(`select amount_fils=13000 and status='PENDING' from payment_refunds where intent_id=${q(staleIntent)}`);
  await check(`select amount_fils=${staleBefore.amount_fils} and payload=${json(staleBefore.payload)}
    and quote_snapshot=${json(staleBefore.quote_snapshot)} and profile_id=${q(stalePaidPlayer)}
    and provider_intent_id=${q(staleBefore.provider_intent_id)} and captured_at is not null
    from payment_intents where id=${q(staleIntent)}`);
  assert.equal((await capture(staleIntent)).status, 'REQUIRES_REFUND'); checks++;
  await check(`select count(*)::integer from payment_refunds where intent_id=${q(staleIntent)}`, 1);
  // Existing paid rows stay intact when a game range is narrowed prospectively.
  const paidBookingBefore = await value(`select to_jsonb(b) from open_queue_bookings b where payment_intent_id=${q(successfulIntent)}`);
  await db.exec(`update open_queue_games set highest_division=3,lowest_division=3 where id=${q(paidRange)}`);
  await check(`select to_jsonb(b) from open_queue_bookings b where payment_intent_id=${q(successfulIntent)}`, paidBookingBefore);
  assert.equal((await capture(successfulIntent)).status, 'FINALIZED'); checks++;
  await db.exec(`update open_queue_bookings set role='ATT' where payment_intent_id=${q(successfulIntent)}`); checks++;

  // The additive trigger never weakens one-game/capacity/account/reliability
  // gates. Same-player second-game insert still fails even when DIV matches.
  const committed = await player(1300);
  const first = await game({highest_division:3,lowest_division:3,price_fils:0});
  const second = await game({highest_division:3,lowest_division:3,price_fils:0});
  await db.exec(direct(first, committed)); checks++;
  await rejects(direct(second, committed), /one upcoming or active game/);
  await rejectedPromise(quote(second, committed), /one upcoming or active game/);
  await asPlayer(committed);
  await rejects(book(second), /one upcoming or active game/);
  const pendingPlayer = await player(1300);
  await db.exec(`insert into payment_intents(profile_id,payload) values(${q(pendingPlayer)},${json({game_id:first,role:'DEF'})})`);
  await rejects(direct(second, pendingPlayer), /earlier game checkout/);
  const restrictedPlayer = await player(1300);
  await db.exec(`insert into test_restrictions values(${q(restrictedPlayer)})`);
  await rejectedPromise(quote(second, restrictedPlayer), /reliability restriction/);
  await asPlayer(restrictedPlayer);
  await rejects(book(second), /reliability restriction/);
  const notActive = await value('select gen_random_uuid()');
  await rejectedPromise(quote(second, notActive), /Complete your account setup/);
  const capacityGame = await game({highest_division:3,lowest_division:3,price_fils:0,defender_capacity:1});
  await db.exec(direct(capacityGame, await player(1300))); checks++;
  await rejects(direct(capacityGame, await player(1300)), /position just filled/);
  await rejectedPromise(quote(capacityGame, await player(1300)), /no longer available|position|full/);

  for (const [highest, lowest] of [[0,5],[1,6],[6,6],[-1,3],[4,2],[null,5],[1,null]]) {
    await rejects(createGame(highest, lowest), /Choose a division range/);
    await rejectedPromise(save({...scheduleDetails,highest_division:highest,lowest_division:lowest}), /division|whole number|check constraint|not-null/i);
    await rejectedPromise(game({highest_division:highest,lowest_division:lowest}), /check constraint|not-null/i);
  }
  for (const invalid of [{highest_division:'1'},{lowest_division:'5'},{highest_division:1.5},{lowest_division:4.5},
    {highest_division:true},{lowest_division:[]},{highest_division:32768}]) {
    await rejectedPromise(save({...scheduleDetails,...invalid}), /whole number|out of range|check constraint/i);
  }
  for (const actor of [nonAdmin,inactiveAdmin,null]) {
    await rejects(createGame(2,4,actor), /Admin referee/);
    await rejectedPromise(save({...scheduleDetails,highest_division:2,lowest_division:4},null,actor), /Admin referee/);
  }
  for (const signature of ['admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer,integer,integer)',
    'admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer)',
    'admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text)',
    'admin_save_game_schedule(uuid,uuid,jsonb)','assert_open_queue_division_eligibility(uuid,uuid)']) {
    for (const role of ['anon','authenticated']) await check(`select has_function_privilege(${q(role)},${q(`public.${signature}`)},'EXECUTE')`, false);
    await check(`select has_function_privilege('service_role',${q(`public.${signature}`)},'EXECUTE')`);
  }

  const created = await value(createGame(2,4));
  await check(`select highest_division=2 and lowest_division=4 and location_address='123 Regression Road'
    from open_queue_games where id=${q(created)}`);
  await check(`select after_state->>'highest_division'='2' and after_state->>'lowest_division'='4'
    from admin_audit_events where entity_id=${q(created)} and action='SOLO_GAME_CREATED'`);
  await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(created)}`);
  const legacyOneOff = await value(createGame(null,null,admin,13000,false));
  await check(`select highest_division=1 and lowest_division=5 from open_queue_games where id=${q(legacyOneOff)}`);
  await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(legacyOneOff)}`);
  const olderOneOff = await value(`select admin_create_open_queue_game('${admin}',${q(field)}::uuid,
    '2098-01-01T10:00:00-07:00'::timestamptz,13000,'18+')`);
  await check(`select highest_division=1 and lowest_division=5 and ends_at=starts_at+interval '1 hour'
    from open_queue_games where id=${q(olderOneOff)}`);
  await db.exec(`update open_queue_games set status='CANCELLED' where id=${q(olderOneOff)}`);
  await rejects(createGame(1,5,admin,490), /free or between 0.50/);

  // Generation copies the template range; edits apply only to unmaterialized
  // future occurrences. Existing published games and their bookings do not move.
  const schedule = await save({...scheduleDetails,is_active:true,highest_division:2,lowest_division:4});
  await check(`select highest_division=2 and lowest_division=4 from game_schedules where id=${q(schedule.id)}`);
  await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(schedule.id)} and status='CREATED'`, 6);
  await check(`select bool_and(g.highest_division=2 and g.lowest_division=4) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(schedule.id)}`);
  const publishedBefore = await value(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(schedule.id)}`);
  const bookingsBefore = await value('select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b');
  await save({highest_division:1,lowest_division:2,booking_window_days:9},schedule.id);
  await check(`select highest_division=1 and lowest_division=2 from game_schedules where id=${q(schedule.id)}`);
  await check(`select jsonb_agg(to_jsonb(g) order by g.id) from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
    where o.schedule_id=${q(schedule.id)} and o.match_date<${q(tomorrow)}::date+6`, publishedBefore);
  await check(`select count(*)::integer from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
    where o.schedule_id=${q(schedule.id)} and g.highest_division=2 and g.lowest_division=4`, 6);
  await check(`select count(*)::integer from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
    where o.schedule_id=${q(schedule.id)} and g.highest_division=1 and g.lowest_division=2`, 2);
  await check('select jsonb_agg(to_jsonb(b) order by id) from open_queue_bookings b', bookingsBefore);
  await check(`select admin_generate_game_schedule('${admin}',${q(schedule.id)})`, {created:0,conflicts:0,skipped:0});
  const scheduleBeforeInvalid = await value(`select to_jsonb(s) from game_schedules s where id=${q(schedule.id)}`);
  await rejectedPromise(save({highest_division:5,lowest_division:1},schedule.id), /division|check constraint/i);
  await check(`select to_jsonb(s) from game_schedules s where id=${q(schedule.id)}`, scheduleBeforeInvalid);
  await save({is_active:true},legacySchedule.id);
  await check(`select bool_and(g.highest_division=1 and g.lowest_division=5) from game_schedule_occurrences o
    join open_queue_games g on g.id=o.game_id where o.schedule_id=${q(legacySchedule.id)} and o.status='CREATED'`, null);
  // The legacy schedule shares a pitch/time with the restricted one, so its
  // conflicts remain retryable without silently changing any published game.
  await check(`select count(*)::integer from game_schedule_occurrences where schedule_id=${q(legacySchedule.id)} and status='CONFLICT'`, 6);
  const newDefaultSchedule = await save({...scheduleDetails,name:'New default range',kickoff_time:'08:00',is_active:true});
  await check(`select highest_division=1 and lowest_division=5 from game_schedules where id=${q(newDefaultSchedule.id)}`);
  await check(`select count(*)::integer from game_schedule_occurrences o join open_queue_games g on g.id=o.game_id
    where o.schedule_id=${q(newDefaultSchedule.id)} and g.highest_division=1 and g.lowest_division=5`, 6);

  // Historical/terminal setup remains possible after cancellation; eligibility
  // helper return for terminal games must not open an actual booking path.
  const closedRestricted = await game({status:'CANCELLED',highest_division:1,lowest_division:1,price_fils:0});
  const historicalPlacement = await player(1200, 0);
  await db.exec(`select assert_open_queue_division_eligibility(${q(historicalPlacement)},${q(closedRestricted)})`); checks++;
  await rejectedPromise(quote(closedRestricted,historicalPlacement), /no longer available/);
  await rejects(direct(closedRestricted,historicalPlacement), /cannot accept bookings/);
  await asPlayer(historicalPlacement);
  await rejects(book(closedRestricted), /game is full/);

  // PGlite has one serialized session. Lock-contract checks supplement behavior
  // but do not claim a hosted concurrent-connection stress test.
  await check(`select prosrc like '%for share%' and prosecdef from pg_proc
    where oid='public.assert_open_queue_division_eligibility(uuid,uuid)'::regprocedure`);
  await check(`select prosrc like '%assert_player_has_one_game%' and prosrc like '%assert_open_queue_division_eligibility%'
    from pg_proc where oid='public.enforce_open_queue_booking_capacity()'::regprocedure`);
  console.log(`game-division-ranges: ${checks} isolated behavioral checks passed`);
} finally {
  await db.close();
}
