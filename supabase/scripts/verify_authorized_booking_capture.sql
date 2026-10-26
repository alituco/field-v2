-- Full-application-schema, rollback-only payment fixtures. The provider proof
-- is synthetic; real booking, role quotas, free checkout and refund writers run.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create temporary table capture_checks(label text);
create sequence pg_temp.capture_person_number;
create function pg_temp.capture_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Authorized capture: %',label; end if;
insert into capture_checks values(label); end $$;
create function pg_temp.capture_reject(statement text,expected text,label text) returns void language plpgsql as $$
declare rejected boolean:=false; begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
perform pg_temp.capture_expect(rejected,label); end $$;
create function pg_temp.capture_person() returns uuid language plpgsql as $$
declare p uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.capture_person_number'); prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
insert into auth.users(id,phone,phone_confirmed_at) values(p,'1555261'||lpad(n::text,4,'0'),now());
perform set_config('request.jwt.claim.sub',p::text,true);
perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Capture','last_name','Fixture','username','capture_'||n,
  'date_of_birth','2000-01-01','email','capture_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
return p; end $$;
create function pg_temp.capture_attempt(p uuid,g uuid,mode text default 'manual') returns uuid language plpgsql as $$
declare i uuid:=gen_random_uuid(); q jsonb; prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
perform set_config('request.jwt.claim.sub',p::text,true);
q:=public.preview_open_queue_booking_cost(g,'GK');
insert into public.payment_intents(id,profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider_intent_id,capture_method,expires_at)
values(i,p,'SOLO_BOOKING','USD',(q->>'total_fils')::integer,jsonb_build_object('game_id',g,'role','GK'),q,'capture_'||i,'pi_capture_'||replace(i::text,'-',''),mode,clock_timestamp()+interval '20 minutes');
perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
return i; end $$;
create function pg_temp.capture_reserve(i uuid) returns jsonb language sql as $$
select public.reserve_stripe_booking_authorization(id,provider_intent_id,amount_minor,currency,'CARD') from public.payment_intents where id=i $$;
create function pg_temp.capture_settle(i uuid) returns jsonb language sql as $$
select public.record_stripe_payment_capture(id,provider_intent_id,'ch_capture_'||replace(id::text,'-',''),amount_minor,currency,'CARD')
from public.payment_intents where id=i $$;

do $$
declare people uuid[]:=array[]::uuid[]; games uuid[]:=array[]::uuid[]; checkout_ids uuid[]:=array[]::uuid[];
  n integer; g uuid; first_result jsonb; response jsonb; kickoff timestamptz; cancel_attempt uuid; race_attempt uuid;
begin
for n in 1..10 loop people:=array_append(people,pg_temp.capture_person()); end loop;
kickoff:=(date_trunc('week',(now() at time zone 'America/Phoenix')+interval '30 years')+interval '1 day 20 hours 30 minutes') at time zone 'America/Phoenix';
for n in 1..6 loop
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values('Authorized capture fixture '||n,
    kickoff+n*interval '7 days',kickoff+n*interval '7 days'+interval '1 hour',13000) returning id into g;
  games:=array_append(games,g);
end loop;
-- Legacy automatic capture retains its original verified-payment behavior.
checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[1],games[1],'automatic'));
perform pg_temp.capture_expect((pg_temp.capture_settle(checkout_ids[1])->>'status')='FINALIZED','legacy automatic capture remains valid');
checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[2],games[1]));
checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[3],games[1]));
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[2])->>'status'='RESERVED','first payer holds the last goalkeeper position before capture');
perform pg_temp.capture_expect((select count(*)=1 from public.open_queue_bookings where game_id=games[1] and status='CONFIRMED'),
  'authorization does not create an unpaid confirmed booking');
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[2])->>'status'='RESERVED'
  and (select count(*)=1 from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[2]),'duplicate authorization reuses one reservation');
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[3])->>'status'='CANCEL_AUTHORIZATION','second authorized payer loses the scarce-position race before capture');
perform pg_temp.capture_expect((select captured_at is null and provider_payment_id is null from public.payment_intents where id=checkout_ids[3]),
  'capacity loser has no captured charge');
-- Even repricing the game to free cannot let another payer steal the held slot.
update public.open_queue_games set price_fils=0 where id=games[1];
perform set_config('request.jwt.claim.sub',people[4]::text,true);
perform pg_temp.capture_reject(format('select public.finalize_free_checkout(%L,''SOLO_BOOKING'',%L::jsonb)',people[4],
  jsonb_build_object('game_id',games[1],'role','GK')),'position just filled','free checkout cannot bypass an active paid reservation');
first_result:=pg_temp.capture_settle(checkout_ids[2]);
perform pg_temp.capture_expect(first_result->>'status'='FINALIZED','reserved payer converts at the original quoted price after repricing');
perform pg_temp.capture_expect((select b.amount_paid_fils=13000 and b.base_amount_fils=13000
  and g.currency='USD' and i.amount_fils=13000 and i.currency='USD'
  from public.open_queue_bookings b join public.open_queue_games g on g.id=b.game_id
  join public.payment_intents i on i.id=b.payment_intent_id where b.id=(first_result->>'resource_id')::uuid),
  'captured booking retains the original USD 13 paid amount and fee after the game becomes free');
perform set_config('request.jwt.claim.sub',people[2]::text,true);
perform pg_temp.capture_expect((select refund_amount_fils=13000 and refund_bps=10000 and refund_destination='ORIGINAL_PAYMENT_METHOD'
  from public.preview_open_queue_cancellation((first_result->>'resource_id')::uuid)),
  'cancellation refund retains the original paid basis after repricing');
perform pg_temp.capture_expect(pg_temp.capture_settle(checkout_ids[2])->>'resource_id'=first_result->>'resource_id','capture replay returns the same booking');
perform pg_temp.capture_expect((select count(*)=2 from public.open_queue_bookings where game_id=games[1] and status='CONFIRMED' and role='GK'),
  'last-slot conversion creates exactly two goalkeeper bookings');
perform pg_temp.capture_expect((select status='CONSUMED' from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[2]),'successful captured booking consumes its reservation');
update public.payment_intents set status='CANCELLED',provider_status='canceled' where id=checkout_ids[3];
perform pg_temp.capture_expect((select status='RELEASED' from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[3])
  and not exists(select 1 from public.payment_refunds where intent_id=checkout_ids[3]),'uncaptured capacity loser is voided without a refund or booking');

checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[4],games[2]));
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[4])->>'status'='RESERVED','second game reservation acquired');
perform pg_temp.capture_reject(format('update public.open_queue_games set defender_capacity=6,attacker_capacity=6 where id=%L',games[2]),
  'Formation is locked','an administrator cannot change a held game formation or role capacities');
perform public.request_stripe_booking_void(checkout_ids[4]);
perform pg_temp.capture_expect((select status='ACTIVE' and cancel_requested from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[4]),
  'an unacknowledged cancellation keeps its reserved capacity');
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[4])->>'status'='CANCEL_AUTHORIZATION','a cancelled attempt cannot be recaptured by a later webhook');
perform pg_temp.capture_reject(format('update public.open_queue_games set status=''LIVE'' where id=%L',games[2]),
  'booking payment is being confirmed','kickoff cannot freeze a roster while capture or cancellation is unresolved');
update public.payment_intents set status='EXPIRED',provider_status='canceled' where id=checkout_ids[4];
perform pg_temp.capture_expect((select status='RELEASED' from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[4]),
  'provider-confirmed canceled expiry releases capacity and cannot orphan an active hold');

checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[5],games[2]));
perform public.request_stripe_booking_void(checkout_ids[5]);
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[5])->>'status'='CANCEL_AUTHORIZATION'
  and not exists(select 1 from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[5] and status='ACTIVE'),
  'abandonment before authorization prevents a subsequent reservation');
update public.payment_intents set status='CANCELLED',provider_status='canceled' where id=checkout_ids[5];

checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[6],games[3]));
response:=pg_temp.capture_settle(checkout_ids[6]);
perform pg_temp.capture_expect(response->>'status'='REQUIRES_REFUND' and not exists(select 1 from public.open_queue_bookings where profile_id=people[6]),
  'unexpected external capture without a reservation never bypasses booking validation');
perform pg_temp.capture_settle(checkout_ids[6]);
perform pg_temp.capture_expect((select count(*)=1 and max(amount_fils)=13000 from public.payment_refunds where intent_id=checkout_ids[6]),
  'unexpected capture has exactly one durable full refund across replays');
checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[7],games[3],'automatic'));
perform pg_temp.capture_expect(pg_temp.capture_settle(checkout_ids[7])->>'status'='FINALIZED','automatic checkout_ids still finalize after a manual rollout');
perform pg_temp.capture_reject(format('update public.payment_intents set capture_method=''manual'' where id=%L',checkout_ids[7]),
  'capture method cannot change','existing automatic attempt capture mode is immutable');
perform pg_temp.capture_expect(not has_function_privilege('authenticated','public.reserve_stripe_booking_authorization(uuid,text,integer,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.request_stripe_booking_void(uuid)','EXECUTE')
  and not has_table_privilege('authenticated','fieldrush_private.stripe_booking_reservations','SELECT'),
  'players cannot forge authorizations, inspect reservations or release capacity directly');

cancel_attempt:=pg_temp.capture_attempt(people[9],games[5]);
perform pg_temp.capture_reserve(cancel_attempt);
update public.open_queue_games set status='CANCELLED',cancellation_code='OTHER',
  cancellation_reason='Disposable organizer-cancellation verification.',cancelled_at=clock_timestamp() where id=games[5];
perform pg_temp.capture_expect((select status='CANCELLED' from public.open_queue_games where id=games[5]),
  'organizer cancellation stays available with an unresolved provider authorization');
perform pg_temp.capture_expect(pg_temp.capture_reserve(cancel_attempt)->>'status'='CANCEL_AUTHORIZATION',
  'organizer cancellation prevents a later capture claim');
update public.payment_intents set status='CANCELLED',provider_status='canceled' where id=cancel_attempt;
perform pg_temp.capture_expect((select status='RELEASED' from fieldrush_private.stripe_booking_reservations where intent_id=cancel_attempt)
  and not exists(select 1 from public.payment_refunds where intent_id=cancel_attempt),'known uncaptured organizer cancellation releases without a refund');
race_attempt:=pg_temp.capture_attempt(people[10],games[6]);
perform pg_temp.capture_reserve(race_attempt);
update public.open_queue_games set status='CANCELLED',cancellation_code='OTHER',
  cancellation_reason='Disposable in-flight cancellation verification.',cancelled_at=clock_timestamp() where id=games[6];
response:=pg_temp.capture_settle(race_attempt);
perform pg_temp.capture_expect(response->>'status'='REQUIRES_REFUND' and not exists(select 1 from public.open_queue_bookings where game_id=games[6]),
  'an in-flight capture racing organizer cancellation is durably refunded instead of losing money');
perform pg_temp.capture_settle(race_attempt);
perform pg_temp.capture_expect((select count(*)=1 and max(amount_fils)=13000 from public.payment_refunds where intent_id=race_attempt),
  'organizer cancellation racing capture queues only one full refund');

-- Reserve before kickoff, finish that same captured reservation after kickoff.
-- Only this local clock is replaced, inside the rollback-only fixture.
create temporary table capture_clock(t timestamptz);
insert into capture_clock values((select check_in_deadline_at-interval '1 second'
  from public.ensure_match_reliability_terms('SOLO',games[4])));
alter function pg_catalog.clock_timestamp() rename to capture_original_clock_timestamp;
create function pg_catalog.clock_timestamp() returns timestamptz language sql volatile as 'select t from pg_temp.capture_clock';
alter function pg_catalog.now() rename to capture_original_now;
create function pg_catalog.now() returns timestamptz language sql stable as 'select t from pg_temp.capture_clock';
execute 'discard plans';
checkout_ids:=array_append(checkout_ids,pg_temp.capture_attempt(people[8],games[4]));
perform pg_temp.capture_expect(pg_temp.capture_reserve(checkout_ids[8])->>'status'='RESERVED','late-capture probe secures its spot before kickoff');
perform pg_temp.capture_expect((select authorized_at=(select t from capture_clock) from fieldrush_private.stripe_booking_reservations where intent_id=checkout_ids[8]),
  'the controlled reservation is exactly one second before the registration cutoff');
update capture_clock set t=(select starts_at+interval '1 second' from public.open_queue_games where id=games[4]);
execute 'discard plans';
response:=pg_temp.capture_settle(checkout_ids[8]);
perform pg_temp.capture_expect((select captured_at=(select t from capture_clock) from public.payment_intents where id=checkout_ids[8]),
  'captured proof uses the controlled post-kickoff clock');
perform pg_temp.capture_expect(response->>'status'='FINALIZED','a valid pre-kickoff hold converts after kickoff without charging-and-refunding');
perform pg_temp.capture_expect(not exists(select 1 from public.payment_refunds where intent_id=checkout_ids[8]),'after-kickoff conversion needs no refund');
perform set_config('request.jwt.claim.sub',people[9]::text,true);
perform pg_temp.capture_reject(format('select public.preview_open_queue_booking_cost(%L,''GK'')',games[4]),
  'no longer available','new post-kickoff checkouts remain unavailable');
end $$;
select count(*) as authorized_capture_checks from capture_checks;
rollback;
