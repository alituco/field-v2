// Offline PostgreSQL contracts. No Supabase/Stripe connection or real payment.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create schema fieldrush_private;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
create table public.referee_profiles(profile_id uuid primary key,is_active boolean);
create function public.is_active_moderation_admin(p uuid) returns boolean language sql stable as $$select exists(select 1 from referee_profiles where profile_id=p and is_active)$$;
create table public.payment_intents(id uuid primary key,profile_id uuid not null,provider text not null,purpose text not null,
 status text not null,currency text not null,amount_fils integer not null,amount_minor integer not null,payload jsonb,quote_snapshot jsonb,
 transaction_reference text not null,provider_intent_id text unique,provider_payment_id text,provider_status text,payment_method text,
 resource_type text,resource_id uuid,captured_at timestamptz,finalized_at timestamptz,external_refund_review_required boolean default false,
 created_at timestamptz not null,expires_at timestamptz not null,failure_reason text);
create table public.open_queue_bookings(payment_intent_id uuid);
create table public.payment_refunds(intent_id uuid);
create table public.external_payment_refunds(intent_id uuid);
create table public.fixtures(home_payment_intent_id uuid,away_payment_intent_id uuid);
create table public.admin_audit_events(actor_referee_id uuid,action text,entity_type text,entity_id uuid,reason text,before_state jsonb,after_state jsonb);
`);
const provider=await readFile(new URL('../migrations/20261010001000_replace_payment_provider.sql',import.meta.url),'utf8');
const start=provider.indexOf('create function public.protect_payment_intent()');
await db.exec(provider.slice(start,provider.indexOf('create table public.payment_refunds',start)));
await db.exec(await readFile(new URL('../migrations/20261016000200_stripe_checkout_recovery.sql',import.meta.url),'utf8'));
const admin='10000000-0000-4000-8000-000000000001',other='10000000-0000-4000-8000-000000000002',player='20000000-0000-4000-8000-000000000001';
await db.exec(`insert into referee_profiles values('${admin}',true),('${other}',false)`);
let checks=0,n=0;
const id=()=>`30000000-0000-4000-8000-${String(++n).padStart(12,'0')}`;
const j=(x)=>`'${JSON.stringify(x).replaceAll("'","''")}'::jsonb`;
async function scalar(sql,value){const {rows}=await db.query(sql);assert.deepEqual(Object.values(rows[0])[0],value,sql);checks++;}
async function rejects(sql,re){await assert.rejects(db.exec(sql),re);checks++;}
async function intent(extra=''){const key=id();await db.exec(`insert into payment_intents(id,profile_id,provider,purpose,status,currency,amount_fils,amount_minor,transaction_reference,created_at,expires_at)
 values('${key}','${player}','STRIPE','SOLO_BOOKING','PENDING','USD',13000,1300,'reference-${key}',now()-interval '25 hours',now()-interval '24 hours');${extra.replaceAll('$ID',key)}`);return key;}
const evidence=(key,pi='pi_recoveredA',patch={})=>({id:pi,object:'payment_intent',amount:1300,amount_received:0,currency:'usd',livemode:false,status:'requires_payment_method',capture_method:'automatic',payment_method_types:['card'],metadata:{field_payment_intent_id:key,field_profile_id:player,field_purpose:'SOLO_BOOKING',field_transaction_reference:`reference-${key}`},...patch});
async function claim(key){const lease=id();const {rows}=await db.query(`select claim_stripe_checkout_recovery('${key}','${lease}',false) as value`);return {...rows[0].value,lease};}
async function finish(key,c,outcome,ev=[],complete=true,cursor=null,pages=1){const {rows}=await db.query(`select complete_stripe_checkout_recovery('${key}','${c.lease}','${outcome}',${j(ev)},${complete},${cursor?`'${cursor}'`:'null'},${pages}) as value`);return rows[0].value;}
async function state(key){const {rows}=await db.query(`select * from fieldrush_private.stripe_checkout_recovery_cases where intent_id='${key}'`);return rows[0];}
const resolve=(c,kind='NO_PAYMENT_EXISTS',ev=null,actor=admin,stamp=c.updated_at)=>`select admin_resolve_stripe_checkout_recovery('${actor}','${c.id}','${kind}','Stripe support evidence ref123','Verified provider account and payment history.','${new Date(stamp).toISOString()}',${ev?j(ev):'null'})`;

const old=await intent();
await db.exec("set request.jwt.claim.role='authenticated';set role authenticated");
await rejects(`select claim_stripe_checkout_recovery('${old}','${id()}',false)`,/permission denied/);
await rejects(`select admin_list_stripe_checkout_recovery('${admin}')`,/permission denied/);
await rejects('select * from fieldrush_private.stripe_checkout_recovery_cases',/permission denied/);
await db.exec("reset role;set request.jwt.claim.role='service_role'");
await rejects(`select admin_list_stripe_checkout_recovery('${other}')`,/active administrator/);
const young=await intent("update payment_intents set created_at=now()-interval '22 hours' where id='$ID';");
await rejects(`select claim_stripe_checkout_recovery('${young}','${id()}',false)`,/original idempotent create/);
const c=await claim(old);assert.equal(c.claimed,true);checks++;
assert.equal((await claim(old)).claimed,false);checks++;
const invalid=evidence(old,'pi_wrong',{amount:1400});
await rejects(`select complete_stripe_checkout_recovery('${old}','${c.lease}','RECOVERED',${j([invalid])},true,null,1)`,/does not match/);
await rejects(`select complete_stripe_checkout_recovery('${old}','${c.lease}','NO_MATCH','[]',false,null,1)`,/completed empty listing/);
await finish(old,c,'INCOMPLETE',[evidence(old)],false,'pi_pageA');
await scalar(`select scan_cursor from fieldrush_private.stripe_checkout_recovery_cases where intent_id='${old}'`,'pi_pageA');
await scalar(`select status from payment_intents where id='${old}'`,'PENDING');
const incomplete=await state(old);
await rejects(resolve(incomplete),/prevents releasing/);
await db.exec(`update fieldrush_private.stripe_checkout_recovery_cases set next_check_at=now()-interval '1 second' where intent_id='${old}'`);
const resumed=await claim(old);assert.equal(resumed.scan_cursor,'pi_pageA');assert.equal(resumed.provider_evidence.length,1);checks+=2;
await finish(old,resumed,'RECOVERED',[evidence(old)],true,null,2);
await scalar(`select provider_intent_id from payment_intents where id='${old}'`,'pi_recoveredA');
await scalar(`select state from fieldrush_private.stripe_checkout_recovery_cases where intent_id='${old}'`,'LINKED');
const lostAck=await claim(old);assert.equal(lostAck.provider_intent_id,'pi_recoveredA');assert.equal(lostAck.claimed,false);checks+=2;
await rejects(resolve(await state(old)),/changed or is still running/);

const noMatch=await intent();const none=await claim(noMatch);await finish(noMatch,none,'NO_MATCH');
await scalar(`select status from payment_intents where id='${noMatch}'`,'PENDING');
const review=await state(noMatch);
await rejects(`select complete_stripe_checkout_recovery('${noMatch}',null,'NO_MATCH','[]',true,null,1)`,/recovery claim expired/);
await rejects(resolve(review,'NO_PAYMENT_EXISTS',null,other),/active administrator/);
await rejects(resolve(review,'NO_PAYMENT_EXISTS',null,admin,'2000-01-01'),/Refresh before reviewing/);
await db.exec(resolve(review));
await scalar(`select status from payment_intents where id='${noMatch}'`,'CANCELLED');
await scalar(`select count(*)::integer from admin_audit_events where entity_id='${noMatch}'`,1);
await scalar(`select count(*)::integer from fieldrush_private.stripe_checkout_recovery_events where case_id='${review.id}'`,2);
const noLease=await intent();const noLeaseClaim=await claim(noLease);
await db.exec(`update fieldrush_private.stripe_checkout_recovery_cases set locked_until=null where intent_id='${noLease}'`);
await rejects(`select complete_stripe_checkout_recovery('${noLease}','${noLeaseClaim.lease}','NO_MATCH','[]',true,null,1)`,/recovery claim expired/);

const many=await intent();const m=await claim(many);const matches=[evidence(many,'pi_manyA'),evidence(many,'pi_manyB')];
await finish(many,m,'MULTIPLE_MATCHES',matches);const mr=await state(many);
await rejects(resolve(mr),/completed no-match/);
await rejects(resolve(mr,'ALL_PROVIDER_PAYMENTS_CANCELLED',[{...matches[0],status:'canceled',amount_received:0}]),/cover every/);
await rejects(resolve(mr,'ALL_PROVIDER_PAYMENTS_CANCELLED',matches.map((e,index)=>({...e,status:index?'succeeded':'canceled',amount_received:index?1300:0}))),/confirmed cancelled/);
await rejects(resolve(mr,'ALL_PROVIDER_PAYMENTS_CANCELLED',matches.map((e)=>({...e,status:undefined}))),/confirmed cancelled/);
await rejects(resolve(mr,'ALL_PROVIDER_PAYMENTS_CANCELLED',matches.map((e)=>({...e,status:'canceled',livemode:true}))),/confirmed cancelled/);
await db.exec(resolve(mr,'ALL_PROVIDER_PAYMENTS_CANCELLED',matches.map((e)=>({...e,status:'canceled',amount_received:0}))));
await scalar(`select status from payment_intents where id='${many}'`,'CANCELLED');

for(const fixture of ['booking','refund','external-refund','fixture','charge','captured-at','finalized-at','external-review']){
  const key=await intent();const cl=await claim(key);await finish(key,cl,'NO_MATCH');
  if(fixture==='booking')await db.exec(`insert into open_queue_bookings values('${key}')`);
  if(fixture==='refund')await db.exec(`insert into payment_refunds values('${key}')`);
  if(fixture==='external-refund')await db.exec(`insert into external_payment_refunds values('${key}')`);
  if(fixture==='fixture')await db.exec(`insert into fixtures values('${key}',null)`);
  if(fixture==='charge')await db.exec(`update payment_intents set provider_payment_id='ch_protected' where id='${key}'`);
  if(fixture==='captured-at')await db.exec(`update payment_intents set captured_at=now() where id='${key}'`);
  if(fixture==='finalized-at')await db.exec(`update payment_intents set finalized_at=now() where id='${key}'`);
  if(fixture==='external-review')await db.exec(`update payment_intents set external_refund_review_required=true where id='${key}'`);
  await rejects(resolve(await state(key)),/prevents releasing/);
  await scalar(`select status from payment_intents where id='${key}'`,'PENDING');
}
for(const patch of [{currency:'bhd'},{livemode:true},{metadata:{}},{amount:999},{payment_method_types:['card','link']}]){
  const key=await intent();const cl=await claim(key);
  await rejects(`select complete_stripe_checkout_recovery('${key}','${cl.lease}','RECOVERED',${j([evidence(key,'pi_invalid',patch)])},true,null,1)`,/does not match/);
}
await scalar("select has_function_privilege('authenticated','public.admin_resolve_stripe_checkout_recovery(uuid,uuid,text,text,text,timestamptz,jsonb)','execute')",false);
await scalar("select has_function_privilege('service_role','public.admin_resolve_stripe_checkout_recovery(uuid,uuid,text,text,text,timestamptz,jsonb)','execute')",true);
await db.close();console.log(`${checks} isolated Stripe checkout recovery SQL checks passed.`);
