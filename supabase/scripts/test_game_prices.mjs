// Isolated PostgreSQL/PGlite checks. No hosted connections or real payments.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite node supabase/scripts/test_game_prices.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const admin = '10000000-0000-0000-0000-000000000001';
const referee = '10000000-0000-0000-0000-000000000002';
const inactive = '10000000-0000-0000-0000-000000000003';
const policy = '10000000-0000-0000-0000-000000000004';
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
create table referee_profiles(profile_id uuid primary key,role text,is_active boolean);
insert into referee_profiles values('${admin}','admin',true),('${referee}','referee',true),('${inactive}','admin',false);
create function is_active_moderation_admin(uuid) returns boolean language sql stable as $$
select exists(select 1 from referee_profiles where profile_id=$1 and role='admin' and is_active)$$;
create table fieldrush_private.accounts(user_id uuid primary key);
create table admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
create table game_schedules(id uuid primary key default gen_random_uuid(),price_fils integer default 13000);
create table open_queue_games(id uuid primary key default gen_random_uuid(),status text default 'OPEN',
  starts_at timestamptz default now()+interval '14 days',ends_at timestamptz default now()+interval '14 days 1 hour',
  currency text default 'USD',format_version text default 'FIELDRUSH_7V7',operational_state text default 'NORMAL',
  price_fils integer default 13000,capacity integer default 14,goalkeeper_capacity integer default 2,
  defender_capacity integer default 6,midfielder_capacity integer default 0,attacker_capacity integer default 6,
  replacement_discount_bps integer default 0,replacement_discount_role text,replacement_offer_expires_at timestamptz,
  replacement_source_booking_id uuid);
create table open_queue_clock_states(game_id uuid primary key,status text default 'NOT_STARTED',started_at timestamptz,accumulated_seconds integer default 0);
create table match_reliability_terms(id uuid default gen_random_uuid(),open_queue_game_id uuid,policy_version_id uuid,
  check_in_deadline_at timestamptz,policy_snapshot jsonb);
create function ensure_match_reliability_terms(text,uuid) returns match_reliability_terms language sql stable as $$
select t from match_reliability_terms t where open_queue_game_id=$2$$;
create function profile_has_active_reliability_booking_restriction(uuid) returns boolean language sql stable as $$
select coalesce(current_setting('test.restricted',true),'false')='true'$$;
create function active_reliability_strikes(uuid,timestamptz default now()) returns integer language sql stable as $$
select coalesce(nullif(current_setting('test.strikes',true),''),'0')::integer$$;
create table player_ratings(profile_id uuid primary key,skill_rating integer default 1200);
create table payment_intents(id uuid primary key default gen_random_uuid(),profile_id uuid,provider text default 'STRIPE',
  status text default 'PENDING',purpose text default 'SOLO_BOOKING',provider_status text,provider_intent_id text,
  provider_payment_id text,payment_method text default 'CARD',currency text default 'USD',amount_fils integer,
  amount_minor integer generated always as (amount_fils/10) stored,payload jsonb,quote_snapshot jsonb,transaction_reference text,
  resource_type text,resource_id uuid,finalized_at timestamptz,failure_reason text,captured_at timestamptz,
  created_at timestamptz default now(),expires_at timestamptz default now()+interval '20 minutes');
create table open_queue_bookings(id uuid primary key default gen_random_uuid(),game_id uuid,profile_id uuid,role text,status text default 'CONFIRMED',
  player_rating_at_booking integer,amount_paid_fils integer,base_amount_fils integer,discount_bps integer,reliability_deposit_fils integer,
  reliability_deposit_status text,reliability_policy_version_id uuid,payment_method text,payment_reference text,payment_intent_id uuid,
  provider_payment_id text,refund_status text default 'NOT_DUE');
create table payment_refunds(id uuid primary key default gen_random_uuid(),intent_id uuid,recipient_profile_id uuid,idempotency_key text unique,
  provider_intent_id text,amount_fils integer,amount_minor integer,currency text,reason text,metadata jsonb,status text,provider_status text);
create table field_wallet_transactions(id uuid default gen_random_uuid(),amount_fils integer);
create table fixtures(id uuid primary key,home_amount_paid_fils integer,away_amount_paid_fils integer,
  home_payment_intent_id uuid,away_payment_intent_id uuid,home_provider_payment_id text,away_provider_payment_id text);
create function assign_open_queue_teams(uuid) returns void language sql as $$update open_queue_games set status='FULL' where id=$1$$;
`);
const oldPayment = await source('20260723010000_finalize_tap_payments_atomically.sql');
let booking = fn(oldPayment, 'book_open_queue_game').replace('function public.book_open_queue_game(', 'function public.book_open_queue_game_server(');
for (const [from, to] of [['tap_payment_intents','payment_intents'],['tap_payment_intent_id','payment_intent_id'],['tap_charge_id','provider_payment_id'],
  ['tap_payment_method','payment_method'],['tap_status','provider_status'],['tap_intent_to_use','payment_intent_to_use']]) booking = booking.replaceAll(from,to);
await db.exec(booking);
await db.exec(fn(await source('20260716000007_preview_open_queue_booking_cost.sql'),'preview_open_queue_booking_cost'));
// Replay the actual existing USD quote/booking transformations, not a test-only
// replacement implementation; omit unrelated wallet/deletion functions.
const usd = await source('20261010000100_fieldrush_usd_wallet_isolation.sql');
const usdStart = usd.indexOf('do $migration$');
const usdEnd = usd.indexOf("  definition := pg_get_functiondef('fieldrush_private.assert_deletion_ready",usdStart);
assert(usdStart>=0 && usdEnd>usdStart);
await db.exec(usd.slice(usdStart,usdEnd)+'end;\n$migration$;');
const provider = await source('20261010001000_replace_payment_provider.sql');
const providerStart = provider.lastIndexOf('do $migration$',provider.indexOf("  definition:=pg_get_functiondef('public.book_open_queue_game_server"));
const providerEnd = provider.indexOf('$migration$;',providerStart)+13;
await db.exec(provider.slice(providerStart,providerEnd));
for (const name of ['protect_payment_intent','request_payment_refund','finalize_payment_intent','record_stripe_payment_capture','finalize_free_checkout']) {
  await db.exec(fn(provider,name));
}
await db.exec(`create trigger protect_payment_intent before update on payment_intents for each row execute function protect_payment_intent();`);
await db.exec(fn(await source('20260713000002_enforce_scheduling_limits.sql'),'enforce_open_queue_booking_capacity'));
await db.exec(`create trigger enforce_capacity before insert or update of game_id,profile_id,role,status on open_queue_bookings
for each row execute function enforce_open_queue_booking_capacity();`);
const migration = await source('20261011000300_edit_solo_game_prices.sql');
await db.exec(migration);
let checks=0;
async function value(sql) { return Object.values((await db.query(sql)).rows[0])[0]; }
async function check(sql, expected=true) { assert.deepEqual(await value(sql),expected,sql); checks++; }
async function rejects(sql,message) { await assert.rejects(db.exec(sql),message); checks++; }
const update = (id,price,expected=13000,actor=admin,reason='Adjust price for future bookings') =>
  `select admin_update_open_queue_game_price(${q(actor)},${q(id)},${price??'null'},${expected??'null'},${q(reason)})`;
async function game(extra={}) {
  const keys=Object.keys(extra);
  const id=await value(keys.length ? `insert into open_queue_games(${keys.join(',')}) values(${keys.map(k=>q(extra[k])).join(',')}) returning id`
    : 'insert into open_queue_games default values returning id');
  await db.exec(`insert into match_reliability_terms(open_queue_game_id,policy_version_id,check_in_deadline_at,policy_snapshot)
    values(${q(id)},'${policy}',now()+interval '13 days',
    '{"replacement":{"postCheckInDeadlineMarketplaceEnabled":false},"solo":{"reliabilityDeposit":{"activeStrikeThreshold":2,"depositBps":2000}}}')`);
  return id;
}
async function player() { return value('insert into fieldrush_private.accounts values(gen_random_uuid()) returning user_id'); }
async function quote(id,user,role='DEF') {
  await db.exec(`select set_config('request.jwt.claim.sub',${q(user)},false)`);
  return value(`select preview_open_queue_booking_cost(${q(id)},${q(role)})`);
}
async function intent(id,user,options={}) {
  const quoted=options.quote??await quote(id,user,options.role??'DEF');
  return value(`insert into payment_intents(profile_id,amount_fils,payload,quote_snapshot,provider_intent_id,provider,transaction_reference)
  values(${q(user)},${options.amount??quoted.total_fils},${json({game_id:id,role:options.role??'DEF'})},${json(quoted)},
  'pi_'||gen_random_uuid(),${q(options.provider??'STRIPE')},'test_'||gen_random_uuid()) returning id`);
}
async function capture(id) {
  return value(`select record_stripe_payment_capture(id,provider_intent_id,'ch_'||id,amount_minor,currency,'CARD') from payment_intents where id=${q(id)}`);
}
// New mutation requires real service-role ACL and an active admin identity.
for(const role of ['anon','authenticated']) {
  await check(`select has_function_privilege('${role}','admin_update_open_queue_game_price(uuid,uuid,integer,integer,text)','EXECUTE')`,false);
  await db.exec(`set role ${role}`);
  await rejects(update(null,14000),/permission denied/);
  await db.exec('reset role');
}
await check(`select has_function_privilege('service_role','admin_update_open_queue_game_price(uuid,uuid,integer,integer,text)','EXECUTE')`);
const primary=await game();
for(const actor of [null,referee,inactive]) await rejects(update(primary,14000,13000,actor),/Admin referee/);
await rejects(update('00000000-0000-0000-0000-000000000000',14000),/not found/);
for(const price of [null,-10,10,490,100010,13001]) await rejects(update(primary,price),/whole cents/);
await rejects(update(primary,14000,null),/Reload/);
for(const reason of [null,'','a'.repeat(7),'x'.repeat(1001)]) await rejects(update(primary,14000,13000,admin,reason),/reason/);
for(const [key,values] of Object.entries({status:['LIVE','FINAL','CANCELLED'],operational_state:['NO_DATA','UNDER_REVIEW','RESOLVED']})) {
  for(const v of values) await rejects(update(await game({[key]:v}),14000),/upcoming games/);
}
await rejects(update(await game({starts_at:'2020-01-01'}),14000),/upcoming games/);
await rejects(update(await game({format_version:'LEGACY_6V6',currency:'BHD'}),14000),/Fieldrush USD/);
for(const state of [{status:'RUNNING'},{status:'PAUSED'},{status:'ENDED'},{started_at:'2020-01-01'},{accumulated_seconds:1}]) {
  const id=await game();
  await db.exec(`insert into open_queue_clock_states(game_id,${Object.keys(state).join(',')}) values(${q(id)},${Object.values(state).map(q).join(',')})`);
  await rejects(update(id,14000),/upcoming games/);
}
const full=await game({status:'FULL'});
await db.exec(update(full,14000));
await check(`select price_fils from open_queue_games where id=${q(full)}`,14000);
// Snapshot all financial rows plus schedule to catch ANY unintended adjustment.
const user=await player(); const paid=await intent(primary,user);
const finalized=await capture(paid); assert.equal(finalized.status,'FINALIZED'); checks++;
await db.exec(`insert into game_schedules default values; insert into field_wallet_transactions(amount_fils) values(3210)`);
async function financialSnapshot() {
  return value(`select jsonb_build_object('bookings',(select jsonb_agg(to_jsonb(b)) from open_queue_bookings b),
  'intents',(select jsonb_agg(to_jsonb(i)) from payment_intents i),'refunds',(select jsonb_agg(to_jsonb(r)) from payment_refunds r),
  'wallet',(select jsonb_agg(to_jsonb(w)) from field_wallet_transactions w),'schedules',(select jsonb_agg(to_jsonb(s)) from game_schedules s))`);
}
const preserved=await financialSnapshot();
let old=13000;
for(const price of [19000,11000,0,500,100000]) {
  const result=await value(update(primary,price,old));
  assert.deepEqual(result,{game_id:primary,price_fils:price,currency:'USD'}); checks++;
  assert.deepEqual(await financialSnapshot(),preserved); checks++;
  await check(`select before_state->>'price_fils'=${q(old)} and after_state->>'price_fils'=${q(price)} and reason='Adjust price for future bookings'
  from admin_audit_events where entity_id=${q(primary)} and before_state->>'price_fils'=${q(old)} and after_state->>'price_fils'=${q(price)}`);
  old=price;
}
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(primary)}`,5);
await db.exec(update(primary,old,old)); // Repeat same value is harmless, not another adjustment.
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(primary)}`,5);
await rejects(update(primary,17000,13000),/price changed/);
await check(`select price_fils from open_queue_games where id=${q(primary)}`,old);
await db.exec(`select request_payment_refund(${q(paid)},13000,${q(`historical:${paid}`)},'Refund the original payment only')`);
await check(`select amount_fils=13000 and amount_minor=1300 from payment_refunds where intent_id=${q(paid)}`);
await check(`select amount_paid_fils from open_queue_bookings where payment_intent_id=${q(paid)}`,13000);
// Serialized concurrent requests with the same stale expected price cannot
// both succeed. PGlite is single-session; the function's real FOR UPDATE lock
// plus compare-and-set is additionally asserted below (not a multi-connection test).
const contenders=await game();
const results=await Promise.allSettled([db.query(update(contenders,15000)),db.query(update(contenders,17000))]);
assert.equal(results.filter(r=>r.status==='fulfilled').length,1); checks++;
assert.match(results.find(r=>r.status==='rejected').reason.message,/price changed/); checks++;
await check(`select count(*)::integer from admin_audit_events where entity_id=${q(contenders)}`,1);
assert.match(migration,/where id=game_id_to_use for update/); checks++;

// Every captured in-flight quote is honored after up/down/free edits, retaining
// the original base/deposit/discount split and refund entitlement.
for(const newPrice of [18000,9000,0]) {
  const id=await game(); const payer=await player();
  await db.exec(`select set_config('test.strikes','2',false);
    update open_queue_games set replacement_discount_bps=2500,replacement_discount_role='DEF',replacement_offer_expires_at=now()+interval '10 minutes' where id=${q(id)}`);
  const original=await quote(id,payer); const pending=await intent(id,payer,{quote:original});
  await db.exec(update(id,newPrice));
  // Current strikes can be different; the immutable checkout amount/split is
  // still the one paid. Current sanctions and availability remain enforced.
  await db.exec(`select set_config('test.strikes','0',false)`);
  const result=await capture(pending); assert.equal(result.status,'FINALIZED'); checks++;
  await check(`select amount_paid_fils=${original.total_fils} and base_amount_fils=${original.match_fee_fils}
    and reliability_deposit_fils=${original.reliability_deposit_fils} and discount_bps=2500 and reliability_policy_version_id='${policy}'
    from open_queue_bookings where id=${q(result.resource_id)}`);
  await check(`select count(*)::integer from payment_refunds where intent_id=${q(pending)}`,0);
  const again=await value(`select finalize_payment_intent(${q(pending)})`); assert.equal(again.resource_id,result.resource_id); checks++;
  await check(`select count(*)::integer from open_queue_bookings where payment_intent_id=${q(pending)}`,1);
  // A subsequent NEW payer sees the edited price, not the earlier quote.
  const next=await quote(id,await player()); assert.equal(next.standard_match_fee_fils,newPrice); checks++;
  await db.exec(`select request_payment_refund(${q(pending)},${original.total_fils},${q(`refund:${pending}`)},'Original paid amount refund')`);
  await check(`select amount_fils=${original.total_fils} and amount_minor=${original.total_fils/10} from payment_refunds where intent_id=${q(pending)}`);
  await rejects(`select request_payment_refund(${q(pending)},10,${q(`extra:${pending}`)},'Must not overrefund')`,/exceed/);
}
// Free bookings are not an escape hatch after a game becomes paid.
const free=await game({price_fils:0}); const freeUser=await player();
const freeBooking=await value(`select finalize_free_checkout(${q(freeUser)},'SOLO_BOOKING',${json({game_id:free,role:'DEF'})})`);
await check(`select amount_paid_fils=0 and base_amount_fils=0 and payment_method='FREE' from open_queue_bookings where id=${q(freeBooking.resource_id)}`);
await db.exec(update(free,16000,0));
await check(`select amount_paid_fils from open_queue_bookings where id=${q(freeBooking.resource_id)}`,0);
await rejects(`select finalize_free_checkout(${q(await player())},'SOLO_BOOKING',${json({game_id:free,role:'DEF'})})`,/requires payment/);
// A payment does not bypass a cancelled/full game, sanctions, exact owner,
// quote identity, amount verification, role or payment-provider validation.
for(const mode of ['CANCELLED','FULL','RESTRICTED','BAD_QUOTE','BAD_TOTAL','BAD_POLICY','BAD_OWNER','BAD_ROLE','BAD_CURRENCY','BAD_INTEGER','BAD_DEPOSIT','BAD_DISCOUNT']) {
  const id=await game(); const payer=await player(); const original=await quote(id,payer);
  let quoted={...original};
  if(mode==='BAD_QUOTE') delete quoted.match_fee_fils;
  if(mode==='BAD_TOTAL') quoted.match_fee_fils+=10;
  if(mode==='BAD_POLICY') quoted.policy_version_id=admin;
  if(mode==='BAD_CURRENCY') quoted.currency='BHD';
  if(mode==='BAD_INTEGER') quoted.match_fee_fils='99999999999999999999999';
  if(mode==='BAD_DEPOSIT') quoted.reliability_deposit_fils=-1;
  if(mode==='BAD_DISCOUNT') quoted.replacement_discount_bps=10001;
  const pending=await intent(id,payer,{quote:quoted,role:mode==='BAD_ROLE'?'MID':'DEF'});
  if(['CANCELLED','FULL'].includes(mode)) await db.exec(`update open_queue_games set status=${q(mode)} where id=${q(id)}`);
  if(mode==='RESTRICTED') await db.exec(`select set_config('test.restricted','true',false)`);
  if(mode==='BAD_OWNER') {
    // A direct caller with another auth identity cannot consume the intent.
    await db.exec(`update payment_intents set status='CAPTURED',provider_status='SUCCEEDED',provider_payment_id='ch_'||id where id=${q(pending)};
      select set_config('request.jwt.claim.sub',${q(await player())},false)`);
    await rejects(`select book_open_queue_game_server(${q(id)},'DEF','CARD',${q(`ch_${pending}`)})`,/could not be verified/);
  } else {
    const result=await capture(pending); assert.equal(result.status,'REQUIRES_REFUND',mode); checks++;
    await check(`select count(*)::integer from open_queue_bookings where payment_intent_id=${q(pending)}`,0);
    await check(`select amount_fils from payment_refunds where intent_id=${q(pending)}`,original.total_fils);
  }
  await db.exec(`select set_config('test.restricted','false',false)`);
}
await check(`select count(*)::integer from field_wallet_transactions`,1);
console.log(`Passed ${checks} isolated solo game price / captured quote / refund checks.`);
await db.close();
