// Isolated behavioral PostgreSQL checks; never connects to hosted data/Stripe.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_single_active_game.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const q = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${q(JSON.stringify(value))}::jsonb`;
const source = file => readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
function fn(sql, name) {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  assert(start >= 0, name);
  return sql.slice(start, sql.indexOf('\n$$;', start) + 4);
}
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth; create schema fieldrush_private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role',true)$$;
select set_config('request.jwt.claim.role','service_role',false);
create table fieldrush_private.accounts(user_id uuid primary key);
create function is_fieldrush_account_active(uuid) returns boolean language sql stable as $$select exists(select 1 from fieldrush_private.accounts where user_id=$1)$$;
create function profile_has_active_reliability_booking_restriction(uuid) returns boolean language sql stable as $$select false$$;
create function active_reliability_strikes(uuid,timestamptz default now()) returns integer language sql stable as $$select 0$$;
create function fixture_start_at(date,text) returns timestamptz language sql immutable as $$select ($1::text||' '||$2||' UTC')::timestamptz$$;
create function fixture_end_at(date,text) returns timestamptz language sql immutable as $$select fixture_start_at($1,$2)+interval '1 hour'$$;
create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'OPEN',
  starts_at timestamptz default now()+interval '14 days',ends_at timestamptz default now()+interval '14 days 1 hour',
  currency text default 'USD',operational_state text default 'NORMAL',price_fils integer default 13000,
  capacity integer default 14,goalkeeper_capacity integer default 2,defender_capacity integer default 6,
  midfielder_capacity integer default 0,attacker_capacity integer default 6,replacement_discount_bps integer default 0,
  replacement_discount_role text,replacement_offer_expires_at timestamptz,replacement_source_booking_id uuid);
create table match_reliability_terms(id uuid default gen_random_uuid(),open_queue_game_id uuid,policy_version_id uuid,
  check_in_deadline_at timestamptz,policy_snapshot jsonb);
create function ensure_match_reliability_terms(text,uuid) returns match_reliability_terms language sql stable as $$select t from match_reliability_terms t where open_queue_game_id=$2$$;
create table player_ratings(profile_id uuid primary key,skill_rating integer default 1200);
create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid,provider text default 'STRIPE',
  status text default 'PENDING',purpose text default 'SOLO_BOOKING',provider_status text,provider_intent_id text unique,
  provider_payment_id text,payment_method text default 'CARD',currency text default 'USD',amount_fils integer,
  amount_minor integer generated always as (amount_fils/10) stored,payload jsonb,quote_snapshot jsonb,transaction_reference text,
  resource_type text,resource_id uuid,finalized_at timestamptz,failure_reason text,captured_at timestamptz,
  created_at timestamptz default now(),expires_at timestamptz default now()+interval '20 minutes');
create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,role text default 'DEF',status text default 'CONFIRMED',
  player_rating_at_booking integer,amount_paid_fils integer,base_amount_fils integer,discount_bps integer,reliability_deposit_fils integer,
  reliability_deposit_status text,reliability_policy_version_id uuid,payment_method text default 'FREE',payment_reference text,payment_intent_id uuid unique,
  provider_payment_id text,refund_status text default 'NOT_DUE');
create unique index one_booking_per_game on open_queue_bookings(game_id,profile_id) where status='CONFIRMED';
create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid,recipient_profile_id uuid,idempotency_key text unique,
  provider_intent_id text,amount_fils integer,amount_minor integer,currency text,reason text,metadata jsonb,status text,provider_status text);
create table fixtures(id uuid primary key default gen_random_uuid(),status text default 'SCHEDULED',match_date date default current_date+14,
  time_slot text default '20:00',operational_state text default 'NORMAL',home_amount_paid_fils integer,away_amount_paid_fils integer,
  home_payment_intent_id uuid,away_payment_intent_id uuid,home_provider_payment_id text,away_provider_payment_id text);
create table fixture_reliability_roster_history(id uuid primary key default gen_random_uuid(),fixture_id uuid,profile_id uuid,status text default 'CONFIRMED');
create table match_reserve_assignments(id uuid primary key default gen_random_uuid(),match_kind text,fixture_id uuid,open_queue_game_id uuid,
  profile_id uuid,status text default 'ACTIVE');
create table match_attendance_records(match_kind text,open_queue_game_id uuid,fixture_id uuid,profile_id uuid,outcome text);
create function assign_open_queue_teams(uuid) returns void language sql as $$update open_queue_games set status='FULL' where id=$1$$;
`);
let booking = fn(await source('20260723010000_finalize_tap_payments_atomically.sql'),'book_open_queue_game')
  .replace('function public.book_open_queue_game(', 'function public.book_open_queue_game_server(');
for (const [from,to] of [['tap_payment_intents','payment_intents'],['tap_payment_intent_id','payment_intent_id'],['tap_charge_id','provider_payment_id'],
  ['tap_payment_method','payment_method'],['tap_status','provider_status'],['tap_intent_to_use','payment_intent_to_use']]) booking=booking.replaceAll(from,to);
await db.exec(booking);
await db.exec(fn(await source('20260716000007_preview_open_queue_booking_cost.sql'),'preview_open_queue_booking_cost'));
const usd=await source('20261010000100_fieldrush_usd_wallet_isolation.sql');
const usdStart=usd.indexOf('do $migration$');
const usdEnd=usd.indexOf("  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready",usdStart);
await db.exec(usd.slice(usdStart,usdEnd)+'end;\n$migration$;');
const provider=await source('20261010001000_replace_payment_provider.sql');
const providerStart=provider.lastIndexOf('do $migration$',provider.indexOf("  definition:=pg_get_functiondef('public.book_open_queue_game_server"));
await db.exec(provider.slice(providerStart,provider.indexOf('$migration$;',providerStart)+13));
for(const name of ['protect_payment_intent','request_payment_refund','finalize_payment_intent','record_stripe_payment_capture','finalize_free_checkout']) await db.exec(fn(provider,name));
await db.exec('create trigger protect_payment_intent before update on payment_intents for each row execute function protect_payment_intent();');
await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'),'enforce_open_queue_booking_capacity'));
await db.exec('create trigger enforce_open_queue_booking_capacity before insert or update of game_id,profile_id,role,status on open_queue_bookings for each row execute function enforce_open_queue_booking_capacity();');
await db.exec(await source('20261010001500_checkout_eligibility_preflight.sql'));
// Latest immutable price snapshot transformation, without unrelated admin RPC.
const prices=await source('20261011000300_edit_solo_game_prices.sql');
const priceStart=prices.indexOf('do $migration$');
await db.exec(prices.slice(priceStart,prices.indexOf('$migration$;',priceStart)+13));
let checks=0;
const limit=/one upcoming or active game/;
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql,expected=true) { assert.deepEqual(await value(sql),expected,sql); checks++; }
async function rejects(sql,pattern) { await assert.rejects(db.exec(sql),pattern); checks++; }
async function game(extra={}) {
  const keys=Object.keys(extra);
  const id=await value(keys.length ? `insert into open_queue_games(${keys.join(',')}) values(${keys.map(k=>q(extra[k])).join(',')}) returning id`
    : 'insert into open_queue_games default values returning id');
  await db.exec(`insert into match_reliability_terms(open_queue_game_id,policy_version_id,check_in_deadline_at,policy_snapshot)
    values(${q(id)},gen_random_uuid(),now()+interval '13 days',
    '{"replacement":{"postCheckInDeadlineMarketplaceEnabled":false},"solo":{"reliabilityDeposit":{"activeStrikeThreshold":2,"depositBps":2000}}}')`);
  return id;
}
async function player() { return value('insert into fieldrush_private.accounts values(gen_random_uuid()) returning user_id'); }
async function quote(id,user) {
  await db.exec(`select set_config('request.jwt.claim.sub',${q(user)},false)`);
  return value(`select preview_open_queue_booking_cost(${q(id)},'DEF')`);
}
async function intent(id,user) {
  const quoted=await quote(id,user);
  return value(`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot,provider_intent_id,transaction_reference)
    values(${q(user)},${quoted.total_fils},${json({game_id:id,role:'DEF'})},${json(quoted)},'pi_'||gen_random_uuid(),'test_'||gen_random_uuid()) returning id`);
}
async function capture(id) { return value(`select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD') from payment_intents where id=${q(id)}`); }
const direct=(id,user,status='CONFIRMED')=>`insert into open_queue_bookings(game_id,profile_id,status) values(${q(id)},${q(user)},${q(status)})`;
// Pre-existing raced attempts are NOT deleted or rewritten by migration.
const legacyPlayer=await player();
const legacyA=await game(); const legacyB=await game();
const racedA=await intent(legacyA,legacyPlayer); const racedB=await intent(legacyB,legacyPlayer);
const grandfathered=await player(); const grandfatheredA=await game();
const grandfatheredB=await game({starts_at:'2034-01-01',ends_at:'2034-01-01 01:00'});
const grandfatheredIntentA=await intent(grandfatheredA,grandfathered);
const grandfatheredIntentB=await intent(grandfatheredB,grandfathered);
const grandfatheredPaidA=await capture(grandfatheredIntentA);
const grandfatheredPaidB=await capture(grandfatheredIntentB);
assert.equal(grandfatheredPaidA.status,'FINALIZED'); assert.equal(grandfatheredPaidB.status,'FINALIZED');
await db.exec(await source('20261012000100_one_active_game_per_player.sql'));
await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(grandfathered)} and status='CONFIRMED'`,2);
assert.equal((await capture(grandfatheredIntentA)).resource_id,grandfatheredPaidA.resource_id); checks++;
assert.equal((await capture(grandfatheredIntentB)).resource_id,grandfatheredPaidB.resource_id); checks++;
await db.exec(`update open_queue_bookings set role='ATT' where game_id=${q(grandfatheredA)} and profile_id=${q(grandfathered)}`);
await rejects(direct(await game(),grandfathered),limit);
await db.exec(`update open_queue_bookings set status='CANCELLED' where profile_id=${q(grandfathered)}`);
await db.exec(direct(await game(),grandfathered)); checks++;
assert.equal((await capture(racedA)).status,'FINALIZED'); checks++;
assert.equal((await capture(racedB)).status,'REQUIRES_REFUND'); checks++;
await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(legacyPlayer)}`,1);
await check(`select amount_fils=13000 and status='PENDING' from payment_refunds where intent_id=${q(racedB)}`);
await capture(racedB); await capture(racedA);
await check(`select count(*)::integer from payment_refunds where intent_id=${q(racedB)}`,1);
await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(legacyPlayer)}`,1);
// Non-overlapping days still block, including quote and direct service insert.
const next=await game({starts_at:'2035-01-01',ends_at:'2035-01-01 01:00'});
await rejects(`select preview_open_queue_booking_cost(${q(next)},'DEF')`,limit);
await rejects(direct(next,legacyPlayer),limit);
await db.exec(`update open_queue_games set status='FINAL' where id=${q(legacyA)}`);
assert.equal((await quote(next,legacyPlayer)).total_fils,13000); checks++;
await db.exec(direct(next,legacyPlayer));
// A completed payment retry is an audit/idempotency read, not a new booking.
const retryWhileNewGame=await capture(racedA);
assert.equal(retryWhileNewGame.status,'FINALIZED'); checks++;
assert.equal(retryWhileNewGame.resource_id,(await value(`select resource_id from payment_intents where id=${q(racedA)}`))); checks++;
await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(legacyPlayer)}`,2);
// Scheduled window continues to block after kickoff; LIVE persists past end.
for(const status of ['OPEN','FULL','LIVE']) {
  const user=await player(); const current=await game(); const other=await game();
  await db.exec(direct(current,user));
  await db.exec(`update open_queue_games set status=${q(status)},starts_at=now()-interval '10 minutes',ends_at=now()+interval '50 minutes' where id=${q(current)}`);
  await rejects(direct(other,user),limit);
  if(status==='LIVE') {
    await db.exec(`update open_queue_games set ends_at=now()-interval '1 day',operational_state='NO_DATA' where id=${q(current)}`);
    await rejects(direct(other,user),limit);
  }
}
// Completed/cancelled/no-show/expired schedule/no-data free the commitment.
for(const condition of ['FINAL','CANCELLED','NO_SHOW','PAST','NO_DATA','BOOKING_CANCELLED']) {
  const user=await player(); const current=await game(); const other=await game();
  await db.exec(direct(current,user));
  if(['FINAL','CANCELLED'].includes(condition)) await db.exec(`update open_queue_games set status=${q(condition)} where id=${q(current)}`);
  else if(condition==='NO_SHOW') await db.exec(`insert into match_attendance_records values('SOLO',${q(current)},null,${q(user)},'NO_SHOW')`);
  else if(condition==='PAST') await db.exec(`update open_queue_games set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour' where id=${q(current)}`);
  else if(condition==='NO_DATA') await db.exec(`update open_queue_games set operational_state='NO_DATA' where id=${q(current)}`);
  else await db.exec(`update open_queue_bookings set status='CANCELLED' where game_id=${q(current)} and profile_id=${q(user)}`);
  await db.exec(direct(other,user)); checks++;
  if(condition==='PAST') await rejects(`update open_queue_games set ends_at=now()+interval '3 days' where id=${q(current)}`,limit);
}
// Pending checkout lease: same-target retry, no second payment, no free bypass.
// Old overlap guards must agree with the canonical exclusion rule through the
// actual quote AND free/paid booking paths, not only direct fixture inserts.
for(const condition of ['NO_SHOW','EXCUSED','NO_DATA']) {
  for(const method of ['FREE','CARD']) {
    const user=await player(); const current=await game(); const overlapping=await game({price_fils:method==='FREE'?0:13000});
    await db.exec(direct(current,user));
    if(['NO_SHOW','EXCUSED'].includes(condition)) {
      await db.exec(`update open_queue_games set status='LIVE' where id=${q(current)}`);
      await db.exec(`insert into match_attendance_records values('SOLO',${q(current)},null,${q(user)},${q(condition)})`);
    } else await db.exec(`update open_queue_games set operational_state='NO_DATA' where id=${q(current)}`);
    assert.equal((await quote(overlapping,user)).total_fils,method==='FREE'?0:13000); checks++;
    const result=method==='FREE'
      ? await value(`select finalize_free_checkout(${q(user)},'SOLO_BOOKING',${json({game_id:overlapping,role:'DEF'})})`)
      : await capture(await intent(overlapping,user));
    assert.equal(result.status,'FINALIZED'); checks++;
    await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(user)}`,2);
    if(condition==='NO_SHOW') {
      // Appeal correction to EXCUSED remains terminal absence; it must not
      // restore the old game as a competing commitment after a second booking.
      await db.exec(`update match_attendance_records set outcome='EXCUSED' where profile_id=${q(user)} and open_queue_game_id=${q(current)}`);
      await db.exec(`select assert_player_has_one_game(${q(user)},'SOLO',${q(overlapping)},false)`); checks++;
    }
  }
}
const pendingUser=await player(); const pendingGame=await game(); const pendingNext=await game({price_fils:0});
const pending=await intent(pendingGame,pendingUser);
await rejects(`insert into payment_intents(profile_id,payload) values(${q(pendingUser)},${json({game_id:pendingGame,role:'DEF'})})`,/already being prepared/);
await rejects(`insert into payment_intents(profile_id,payload) values(${q(pendingUser)},${json({game_id:pendingNext,role:'DEF'})})`,/earlier game checkout/);
await rejects(direct(pendingNext,pendingUser),/earlier game checkout/);
await rejects(`select finalize_free_checkout(${q(pendingUser)},'SOLO_BOOKING',${json({game_id:pendingNext,role:'DEF'})})`,/earlier game checkout/);
await db.exec(`update payment_intents set expires_at=now()-interval '1 hour' where id=${q(pending)}`);
await rejects(direct(pendingNext,pendingUser),/earlier game checkout/);
await db.exec(`update payment_intents set status='CANCELLED',provider_status='canceled' where id=${q(pending)}`);
assert.equal((await value(`select finalize_free_checkout(${q(pendingUser)},'SOLO_BOOKING',${json({game_id:pendingNext,role:'DEF'})})`)).status,'FINALIZED'); checks++;
// Free retry is idempotent and cannot create a second row.
await value(`select finalize_free_checkout(${q(pendingUser)},'SOLO_BOOKING',${json({game_id:pendingNext,role:'DEF'})})`);
await check(`select count(*)::integer from open_queue_bookings where profile_id=${q(pendingUser)}`,1);
// Two stale preflights can both succeed; only one subsequent lease insert does.
// PGlite serializes statements, exercising the database transition guard after
// a stale quote. Hosted multi-session lock stress is intentionally not run.
const raceUser=await player(); const raceGameA=await game(); const raceGameB=await game();
const staleQuoteA=await quote(raceGameA,raceUser); const staleQuoteB=await quote(raceGameB,raceUser);
const lease=(id,snapshot)=>`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot)
  values(${q(raceUser)},13000,${json({game_id:id,role:'DEF'})},${json(snapshot)})`;
const leaseRace=await Promise.allSettled([db.exec(lease(raceGameA,staleQuoteA)),db.exec(lease(raceGameB,staleQuoteB))]);
assert.equal(leaseRace.filter(result=>result.status==='fulfilled').length,1); checks++;
assert.equal(leaseRace.filter(result=>result.status==='rejected').length,1); checks++;
await check(`select count(*)::integer from payment_intents where profile_id=${q(raceUser)} and status='PENDING'`,1);
// Legacy roster/reserve paths use the identical player lock and mutual guard.
for(const path of ['CLAN','SOLO_RESERVE','CLAN_RESERVE']) {
  const user=await player(); const solo=await game();
  const fixture=await value('insert into fixtures default values returning id');
  const insert=path==='CLAN'
    ? `insert into fixture_reliability_roster_history(fixture_id,profile_id) values(${q(fixture)},${q(user)})`
    : `insert into match_reserve_assignments(match_kind,open_queue_game_id,fixture_id,profile_id) values(${q(path==='SOLO_RESERVE'?'SOLO':'CLAN')},${q(path==='SOLO_RESERVE'?solo:null)},${q(path==='CLAN_RESERVE'?fixture:null)},${q(user)})`;
  const other=await game();
  await db.exec(direct(other,user));
  await rejects(insert,limit);
  await db.exec(`update open_queue_games set status='FINAL' where id=${q(other)}`);
  await db.exec(insert);
  await rejects(direct(await game(),user),limit);
  await db.exec(path==='SOLO_RESERVE' ? `update open_queue_games set status='FINAL' where id=${q(solo)}` : `update fixtures set status='FINAL' where id=${q(fixture)}`);
  await db.exec(`update open_queue_games set status='OPEN' where id=${q(other)}`);
  // Existing participant becomes active again only when no other game blocks.
  checks++;
}
// Positional capacity and private helper ACLs remain enforced.
// Historical direct roster/reserve writes are legal audit rows, but restoring
// their target to active must detect all committed participants and conflicts.
for(const path of ['CLAN','SOLO_RESERVE','CLAN_RESERVE']) {
  const user=await player(); const current=await game(); await db.exec(direct(current,user));
  const target=path==='SOLO_RESERVE'
    ? await game({status:'FINAL'}) : await value("insert into fixtures(status) values('FINAL') returning id");
  await db.exec(path==='CLAN'
    ? `insert into fixture_reliability_roster_history(fixture_id,profile_id) values(${q(target)},${q(user)})`
    : `insert into match_reserve_assignments(match_kind,open_queue_game_id,fixture_id,profile_id) values(${q(path==='SOLO_RESERVE'?'SOLO':'CLAN')},${q(path==='SOLO_RESERVE'?target:null)},${q(path==='CLAN_RESERVE'?target:null)},${q(user)})`);
  const table=path==='SOLO_RESERVE'?'open_queue_games':'fixtures';
  const status=path==='SOLO_RESERVE'?'OPEN':'SCHEDULED';
  await rejects(`update ${table} set status=${q(status)} where id=${q(target)}`,limit);
  await check(`select status from ${table} where id=${q(target)}`,'FINAL');
  await db.exec(`update open_queue_games set status='FINAL' where id=${q(current)}`);
  await db.exec(`update ${table} set status=${q(status)} where id=${q(target)}`); checks++;
}
// PGlite does not run concurrent PostgreSQL sessions. Assert both target reads
// actually use status-update-conflicting SHARE locks, in addition to transitions.
await check(`select (length(prosrc)-length(replace(prosrc,'for share','')))/length('for share')=2
  from pg_proc where oid='public.enforce_one_player_registered_game()'::regprocedure`);
// Replay the actual rollback-verifier candidate helpers, not a test facsimile.
for(const file of ['verify_open_queue_parties.sql','verify_open_queue_margin_sr.sql','verify_moderation_system.sql','verify_match_resolution_control_plane.sql']) {
  const sql=await readFile(new URL(file,import.meta.url),'utf8');
  const start=sql.indexOf('create or replace function pg_temp.verification_player_has_free_game_slot');
  assert(start>=0,file);
  const end=sql.indexOf('$availability$;',start)+'$availability$;'.length;
  await db.exec(sql.slice(start,end));
  await check(`select pg_temp.verification_player_has_free_game_slot(${q(await player())})`);
  await check(`select pg_temp.verification_player_has_free_game_slot(${q(legacyPlayer)})`,false);
  await check(`select pg_temp.verification_player_has_free_game_slot(${q(raceUser)})`,false);
}
const crowded=await game({defender_capacity:1});
await db.exec(direct(crowded,await player()));
await rejects(direct(crowded,await player()),/position just filled/);
for(const role of ['anon','authenticated']) await check(`select has_function_privilege(${q(role)},'assert_player_has_one_game(uuid,text,uuid,boolean)','EXECUTE')`,false);
await rejects(`select assert_player_has_one_game(null,'SOLO',${q(crowded)},true)`,/player and game/);
console.log(`single-active-game: ${checks} isolated behavioral checks passed`);
await db.close();
