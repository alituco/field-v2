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
// Admin cancellation must still work when an uninitialized clan roster includes
// someone booked into another active game. Replay the real production RPC chain,
// including expected-roster insertion and attendance correction; do not bypass
// the one-game trigger or replace cancellation with a test-only wrapper.
await db.exec(`
alter table fixtures add column home_clan_id uuid, add column away_clan_id uuid,
  add column created_by uuid, add column cancellation_code text, add column cancellation_reason text,
  add column cancelled_at timestamptz, add column cancelled_by uuid, add column cancellation_context jsonb;
alter table match_reliability_terms add column match_kind text default 'SOLO', add column fixture_id uuid,
  add column kickoff_at timestamptz, add column check_in_opens_at timestamptz, add column no_show_cutoff_at timestamptz;
alter table fixture_reliability_roster_history add column clan_id uuid, add column confirmed_by uuid, add column note text;
alter table match_attendance_records add column id uuid default gen_random_uuid(), add column terms_id uuid,
  add column booking_id uuid, add column clan_id uuid, add column side text, add column policy_version_id uuid,
  add column check_in_deadline_at timestamptz, add column no_show_cutoff_at timestamptz,
  add column expected_for_match boolean default true, add column cancelled_at timestamptz,
  add column strike_delta integer default 0, add column refund_bps integer default 0,
  add column refund_amount_fils integer default 0, add column positive_sr_multiplier_bps integer default 10000,
  add column negative_sr_multiplier_bps integer default 10000, add column finalized_at timestamptz,
  add column consequence_snapshot jsonb default '{}'::jsonb;
create unique index clan_attendance_once on match_attendance_records(fixture_id,profile_id) where match_kind='CLAN';
create table referee_profiles(profile_id uuid primary key,role text,is_active boolean);
create table reliability_policy_versions(id uuid primary key default gen_random_uuid(),state text,effective_from timestamptz);
create table clan_members(clan_id uuid,profile_id uuid,role text default 'member',created_at timestamptz default now(),left_at timestamptz);
create table fixture_player_appearances(fixture_id uuid,clan_id uuid,profile_id uuid,played boolean);
create table attendance_events(attendance_id uuid,event_type text,actor_referee_id uuid,event_at timestamptz,
  detail jsonb,idempotency_key text unique);
create table reliability_incidents(id uuid default gen_random_uuid(),subject_type text,profile_id uuid,clan_id uuid,
  attendance_id uuid,booking_id uuid,fixture_id uuid,outcome text,strike_delta integer,occurred_at timestamptz,
  expires_at timestamptz,policy_version_id uuid,reversal_of uuid,active_count_before integer,active_count_after integer,detail jsonb);
create table reliability_sanctions(incident_id uuid,revoked_at timestamptz,revoked_by uuid,revocation_reason text);
create table reliability_appeals(attendance_id uuid,status text,reviewed_by uuid,reviewed_at timestamptz,resolution_note text);
create table fixture_clock_states(fixture_id uuid,status text,started_at timestamptz);
create table fixture_blue_cards(fixture_id uuid,status text);
create table admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,
  before_state jsonb,after_state jsonb);
create function profile_has_active_play_restriction(uuid) returns boolean language sql stable as $$select false$$;
create or replace function ensure_match_reliability_terms(text,uuid) returns match_reliability_terms language sql stable as $$
  select t from match_reliability_terms t
  where (t.match_kind='SOLO' and $1='SOLO' and t.open_queue_game_id=$2)
     or (t.match_kind='CLAN' and $1='CLAN' and t.fixture_id=$2)
$$;
`);
await db.exec(fn(await source('20260715000002_create_moderation_system.sql'),'is_active_moderation_admin'));
await db.exec(fn(await source('20260716000002_enforce_reliability_attendance.sql'),'ensure_match_attendance_records'));
const rosterSource=await source('20260716000005_enforce_reliability_match_effects.sql');
for(const name of ['sync_fixture_reliability_expected_roster','initialize_fixture_reliability_roster','active_clan_reliability_strikes']) await db.exec(fn(rosterSource,name));
const cancellationSource=await source('20260716000006_harden_reliability_privacy_and_field_cancellations.sql');
for(const name of ['reverse_match_reliability_incidents_for_field_cancel','apply_policy_field_cancellation','admin_cancel_match']) {
  await db.exec(fn(cancellationSource,name));
}
// Stripe exposes a refund-summary wrapper; the mutable captain policy body is
// deliberately loaded under its real, renamed function identity.
await db.exec(fn(await source('20260716000008_create_policy_backed_clan_checkout_and_cancellation.sql'),'cancel_clan_fixture_booking')
  .replace('function public.cancel_clan_fixture_booking(', 'function public.cancel_clan_fixture_booking_policy('));
await db.exec(fn(await source('20261010001100_original_payment_refunds.sql'),'cancel_clan_fixture_booking'));
const cancellationAdmin=await player(); const committedClanPlayer=await player(); const opposingClanPlayer=await player();
const unaffectedSolo=await game(); await db.exec(direct(unaffectedSolo,committedClanPlayer));
const homeClan=await value('select gen_random_uuid()'); const awayClan=await value('select gen_random_uuid()');
const cancellationPolicy=await value("insert into reliability_policy_versions(state,effective_from) values('PUBLISHED',now()-interval '1 day') returning id");
await db.exec(`insert into referee_profiles values(${q(cancellationAdmin)},'admin',true);
  insert into clan_members(clan_id,profile_id) values(${q(homeClan)},${q(committedClanPlayer)}),(${q(awayClan)},${q(opposingClanPlayer)});`);
async function cancellableFixture() {
  const fixture=await value(`insert into fixtures(status,home_clan_id,away_clan_id,created_by)
    values('LIVE',${q(homeClan)},${q(awayClan)},${q(cancellationAdmin)}) returning id`);
  await db.exec(`insert into match_reliability_terms(match_kind,fixture_id,policy_version_id,kickoff_at,
      check_in_opens_at,check_in_deadline_at,no_show_cutoff_at,policy_snapshot)
    values('CLAN',${q(fixture)},${q(cancellationPolicy)},now()+interval '14 days',now(),now(),now(),'{"clan":{"playersPerSide":6}}');
    insert into fixture_clock_states values(${q(fixture)},'RUNNING',now());
    insert into fixture_blue_cards values(${q(fixture)},'ACTIVE');`);
  return fixture;
}
const cancelFixture=await cancellableFixture();
const cancel=(fixture,reason='Unsafe pitch; admin cancellation regression')=>
  `select admin_cancel_match(${q(cancellationAdmin)},'CLAN',${q(fixture)},'SAFETY',${q(reason)})`;
// This is the original CI failure, not a mocked error: the old RPC inserts a
// CONFIRMED expected roster while its target fixture is still LIVE.
await rejects(cancel(cancelFixture),limit);
await check(`select status from fixtures where id=${q(cancelFixture)}`,'LIVE');
await check(`select count(*)::integer from fixture_reliability_roster_history where fixture_id=${q(cancelFixture)}`,0);
await check(`select count(*)::integer from match_attendance_records where fixture_id=${q(cancelFixture)}`,0);
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(cancelFixture)}`,0);
// An existing clan penalty must be reversed by the identified admin before
// status settlement, then counted once by the common cancellation correction.
const originalIncident=await value(`insert into reliability_incidents(subject_type,clan_id,fixture_id,
    outcome,strike_delta,occurred_at,policy_version_id,detail)
  values('CLAN',${q(homeClan)},${q(cancelFixture)},'NO_SHOW',2,now()-interval '1 minute',
    ${q(cancellationPolicy)},jsonb_build_object('fixture_id',${q(cancelFixture)})) returning id`);
await db.exec(`insert into reliability_sanctions(incident_id) values(${q(originalIncident)})`);
await check(`select active_clan_reliability_strikes(${q(homeClan)})`,2);
// Load the forward production fix, then retry the exact same fixture and RPC.
await db.exec(await source('20261012000300_allow_cancellation_with_existing_game.sql'));
await db.exec(cancel(cancelFixture));
await check(`select status='CANCELLED' and cancelled_by=${q(cancellationAdmin)}
  and cancellation_code='SAFETY' and cancellation_context->>'previous_status'='LIVE'
  and cancellation_context#>>'{reliability,policy_applied}'='true'
  and cancellation_context#>>'{reliability,affected_count}'='2'
  and cancellation_context#>>'{reliability,reversed_incident_count}'='1'
  from fixtures where id=${q(cancelFixture)}`);
await check(`select count(*)::integer from reliability_incidents where reversal_of=${q(originalIncident)}`,1);
await check(`select subject_type='CLAN' and clan_id=${q(homeClan)} and fixture_id=${q(cancelFixture)}
  and outcome='FIELD_CANCELLED' and strike_delta=-2 and active_count_before=2 and active_count_after=0
  and detail->>'cancelled_by'=${q(cancellationAdmin)} and detail->>'reason'='Unsafe pitch; admin cancellation regression'
  from reliability_incidents where reversal_of=${q(originalIncident)}`);
await check(`select strike_delta=2 and reversal_of is null from reliability_incidents where id=${q(originalIncident)}`);
await check(`select active_clan_reliability_strikes(${q(homeClan)})`,0);
await check(`select revoked_by=${q(cancellationAdmin)} and revoked_at is not null
  and revocation_reason='Match cancelled by Field: Unsafe pitch; admin cancellation regression'
  from reliability_sanctions where incident_id=${q(originalIncident)}`);
await check(`select count(*)::integer from fixture_reliability_roster_history where fixture_id=${q(cancelFixture)} and status='CONFIRMED'`,2);
await check(`select count(*)::integer from match_attendance_records where fixture_id=${q(cancelFixture)}
  and expected_for_match and outcome='FIELD_CANCELLED' and strike_delta=0 and finalized_at is not null`,2);
await check(`select count(*)::integer from attendance_events event join match_attendance_records attendance
  on attendance.id=event.attendance_id where attendance.fixture_id=${q(cancelFixture)} and event.event_type='ADMIN_CORRECTION'`,2);
await check(`select status='ENDED' and started_at is null from fixture_clock_states where fixture_id=${q(cancelFixture)}`);
await check(`select status from fixture_blue_cards where fixture_id=${q(cancelFixture)}`,'CLEARED');
await check(`select actor_referee_id=${q(cancellationAdmin)} and action='MATCH_CANCELLED'
  and before_state->>'status'='LIVE' and after_state->>'status'='CANCELLED'
  and reason='Unsafe pitch; admin cancellation regression' from admin_audit_events where entity_id=${q(cancelFixture)}`);
await check(`select status from open_queue_bookings where game_id=${q(unaffectedSolo)} and profile_id=${q(committedClanPlayer)}`,'CONFIRMED');
await rejects(cancel(cancelFixture),/already cancelled/);
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(cancelFixture)}`,1);
await check(`select count(*)::integer from reliability_incidents where reversal_of=${q(originalIncident)}`,1);
// The earlier state change must be part of the same atomic cancellation. An
// error after roster/attendance processing must roll back every side effect.
const rollbackFixture=await cancellableFixture();
await db.exec(`create function reject_test_cancellation_audit() returns trigger language plpgsql as $$
  begin if new.reason='Regression: fail final audit' then raise exception 'Injected cancellation audit failure'; end if; return new; end;
  $$;
  create trigger reject_test_cancellation_audit before insert on admin_audit_events for each row execute function reject_test_cancellation_audit();`);
await rejects(cancel(rollbackFixture,'Regression: fail final audit'),/Injected cancellation audit failure/);
await check(`select status='LIVE' and cancelled_at is null and cancellation_context is null from fixtures where id=${q(rollbackFixture)}`);
await check(`select count(*)::integer from fixture_reliability_roster_history where fixture_id=${q(rollbackFixture)}`,0);
await check(`select count(*)::integer from match_attendance_records where fixture_id=${q(rollbackFixture)}`,0);
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(rollbackFixture)}`,0);
await check(`select status='RUNNING' and started_at is not null from fixture_clock_states where fixture_id=${q(rollbackFixture)}`);
await check(`select status from fixture_blue_cards where fixture_id=${q(rollbackFixture)}`,'ACTIVE');
await check(`select status from open_queue_bookings where game_id=${q(unaffectedSolo)} and profile_id=${q(committedClanPlayer)}`,'CONFIRMED');
console.log(`single-active-game: ${checks} isolated behavioral checks passed`);
await db.close();
