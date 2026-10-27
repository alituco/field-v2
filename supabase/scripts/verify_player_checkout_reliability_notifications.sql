-- Full-application-schema, rollback-only payment fixtures. The provider proof
-- is synthetic; real booking, role quotas, free checkout and refund writers run.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create temporary table push_receipt_checks(label text);
create sequence pg_temp.push_receipt_person_number;
create function pg_temp.push_receipt_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Player checkout notifications: %',label; end if;
insert into push_receipt_checks values(label); end $$;
create function pg_temp.push_receipt_reject(statement text,expected text,label text) returns void language plpgsql as $$
declare rejected boolean:=false; begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
perform pg_temp.push_receipt_expect(rejected,label); end $$;
create function pg_temp.push_receipt_person() returns uuid language plpgsql as $$
declare p uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.push_receipt_person_number'); prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
insert into auth.users(id,phone,phone_confirmed_at) values(p,'1555266'||lpad(n::text,4,'0'),now());
perform set_config('request.jwt.claim.sub',p::text,true);
perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Receipt','last_name','Fixture','username','push_receipt_'||n,
  'date_of_birth','2000-01-01','email','push_receipt_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
return p; end $$;
create function pg_temp.push_receipt_attempt(p uuid,g uuid,mode text default 'manual') returns uuid language plpgsql as $$
declare i uuid:=gen_random_uuid(); q jsonb; prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
perform set_config('request.jwt.claim.sub',p::text,true);
q:=public.preview_open_queue_booking_cost(g,'GK');
insert into public.payment_intents(id,profile_id,purpose,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider_intent_id,capture_method,expires_at)
values(i,p,'SOLO_BOOKING','USD',(q->>'total_fils')::integer,jsonb_build_object('game_id',g,'role','GK'),q,'push_receipt_'||i,'pi_push_receipt_'||replace(i::text,'-',''),mode,clock_timestamp()+interval '20 minutes');
perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
return i; end $$;
create function pg_temp.push_receipt_reserve(i uuid) returns jsonb language sql as $$
select public.reserve_stripe_booking_authorization(id,provider_intent_id,amount_minor,currency,'CARD') from public.payment_intents where id=i $$;
create function pg_temp.push_receipt_settle(i uuid) returns jsonb language sql as $$
select public.record_stripe_payment_capture(id,provider_intent_id,'ch_push_receipt_'||replace(id::text,'-',''),amount_minor,currency,'CARD')
from public.payment_intents where id=i $$;

do $$
declare people uuid[]:=array[]::uuid[]; games uuid[]:=array[]::uuid[]; payments uuid[]:=array[]::uuid[];
  n integer; g uuid; p uuid; b uuid; refund uuid; notice uuid; other_notice uuid; attendance uuid; incident uuid; sanction uuid; appeal uuid;
  admin uuid; response jsonb; kickoff timestamptz; blocked boolean;
begin
for n in 1..9 loop people:=array_append(people,pg_temp.push_receipt_person()); end loop;
admin:=people[9];
insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values(admin,'Push verifier','+15552669999','admin',true);
kickoff:=(date_trunc('week',(now() at time zone 'America/Phoenix')+interval '30 years')+interval '1 day 20 hours 30 minutes') at time zone 'America/Phoenix';
for n in 1..3 loop
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values('Push receipt fixture '||n,kickoff+n*interval '7 days',kickoff+n*interval '7 days'+interval '1 hour',13000) returning id into g;
  games:=array_append(games,g);
end loop;

-- Actual paid booking conversion creates exactly one durable result receipt.
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[1],games[1],'automatic'));
response:=pg_temp.push_receipt_settle(payments[1]); b:=(response->>'resource_id')::uuid;
set constraints all immediate; set constraints all deferred;
select id into notice from public.notifications where type='PLAYER_CHECKOUT_CONFIRMED' and data->>'payment_id'=payments[1]::text;
perform pg_temp.push_receipt_expect(notice is not null and fieldrush_private.player_checkout_notification_source_is_current(notice),'verified successful booking receives a current confirmation');
perform pg_temp.push_receipt_expect((select title='You’re in' and related_entity_type='OPEN_QUEUE_GAME' and related_entity_id=games[1] from public.notifications where id=notice),'confirmation routes to the actual game');
perform pg_temp.push_receipt_settle(payments[1]);
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect((select count(*)=1 from public.notifications where type='PLAYER_CHECKOUT_CONFIRMED' and data->>'payment_id'=payments[1]::text),'repeated capture cannot duplicate a confirmation');
perform set_config('request.jwt.claim.sub',people[1]::text,true);
perform public.acknowledge_my_checkout_notification(payments[1],'REFUNDED');
perform pg_temp.push_receipt_expect((select read_at is null from public.notifications where id=notice),'unseen mismatched outcome cannot acknowledge a confirmation');
perform public.acknowledge_my_checkout_notification(payments[1],'CONFIRMED');
perform pg_temp.push_receipt_expect((select read_at is not null from public.notifications where id=notice),'foreground confirmation acknowledges only its exact outcome');
perform set_config('request.jwt.claim.sub',people[2]::text,true);
perform pg_temp.push_receipt_reject(format('select public.acknowledge_my_checkout_notification(%L,''CONFIRMED'')',payments[1]),'Payment receipt is unavailable','another player cannot acknowledge this payment');

-- Last-position loser has an authorization release, never a fictitious refund.
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[2],games[1]));
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[3],games[1]));
perform pg_temp.push_receipt_reserve(payments[2]);
perform pg_temp.push_receipt_expect(pg_temp.push_receipt_reserve(payments[3])->>'status'='CANCEL_AUTHORIZATION','scarce role race refuses the losing authorization');
update public.payment_intents set status='CANCELLED',provider_status='canceled' where id=payments[3];
set constraints all immediate; set constraints all deferred;
select id into other_notice from public.notifications where type='PLAYER_CHECKOUT_AUTH_RELEASED' and data->>'payment_id'=payments[3]::text;
perform pg_temp.push_receipt_expect(other_notice is not null and fieldrush_private.player_checkout_notification_source_is_current(other_notice),'verified uncaptured loser receives an authorization-release receipt');
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type like 'PLAYER_CHECKOUT_REFUND%' and data->>'payment_id'=payments[3]::text),'uncaptured authorization is never described as a refund');

-- Simulate a confirmed payment that predates notification rollout. A harmless
-- later reconciliation edit must not replay the old booking confirmation.
perform pg_temp.push_receipt_settle(payments[2]);
set constraints all immediate; set constraints all deferred;
delete from public.notifications where type='PLAYER_CHECKOUT_CONFIRMED' and data->>'payment_id'=payments[2]::text;
delete from fieldrush_private.notification_event_receipts where event_key='checkout:'||payments[2]||':CONFIRMED';
update public.payment_intents set failure_reason='Internal reconciliation completed.' where id=payments[2];
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_CONFIRMED' and data->>'payment_id'=payments[2]::text),'later metadata edits do not replay pre-rollout checkout confirmations');

-- External capture without a reserved spot is durable and eventually refunded.
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[4],games[2]));
perform pg_temp.push_receipt_settle(payments[4]);
set constraints all immediate; set constraints all deferred;
select id into other_notice from public.notifications where type='PLAYER_CHECKOUT_REFUND_PENDING' and data->>'payment_id'=payments[4]::text;
perform pg_temp.push_receipt_expect(other_notice is not null and fieldrush_private.player_checkout_notification_source_is_current(other_notice),'failed captured checkout says refund is pending');
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=payments[4]::text),'requested full refund is not reported as completed');
perform set_config('request.jwt.claim.sub',people[4]::text,true);
perform public.acknowledge_my_checkout_notification(payments[4],'REFUND_PENDING');
select id into refund from public.payment_refunds where intent_id=payments[4];
perform public.finish_payment_refund(refund,'re_push_full','succeeded',1300,'USD');
set constraints all immediate; set constraints all deferred;
select id into p from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=payments[4]::text;
perform pg_temp.push_receipt_expect(p is not null and fieldrush_private.player_checkout_notification_source_is_current(p),'only provider-confirmed full refund creates the completed receipt');
perform pg_temp.push_receipt_expect((select read_at is null from public.notifications where id=p),'seeing pending does not suppress a later completed refund');
perform pg_temp.push_receipt_expect(not fieldrush_private.player_checkout_notification_source_is_current(other_notice) and (select resolved_at is not null from public.notifications where id=other_notice),'pending notification becomes obsolete after completed refund');
perform public.finish_payment_refund(refund,'re_push_full','succeeded',1300,'USD');
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect((select count(*)=1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=payments[4]::text),'provider retry creates no duplicate refund push');
delete from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=payments[4]::text;
delete from fieldrush_private.notification_event_receipts where event_key='checkout:'||payments[4]||':REFUNDED';
update public.payment_intents set failure_reason='Historical refund audit annotation.' where id=payments[4];
update public.payment_refunds set metadata='{"audit":"Historical refund reconciled."}',last_error=null where id=refund;
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=payments[4]::text),'metadata edits to a pre-rollout refunded payment and completed refund cannot replay its result');

-- Simply abandoning a checkout or declining payment does not nag the player.
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[5],games[2]));
perform public.request_stripe_booking_void(payments[5]);
update public.payment_intents set status='CANCELLED',provider_status='canceled' where id=payments[5];
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[6],games[2]));
update public.payment_intents set status='FAILED',provider_status='requires_payment_method' where id=payments[6];
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type like 'PLAYER_CHECKOUT_%' and data->>'payment_id'=any(array[payments[5]::text,payments[6]::text])),'abandoned and declined checkout attempts are silent');

-- A partial external refund requires review, not a false fully-refunded claim.
p:=pg_temp.push_receipt_attempt(people[5],games[2]);
perform pg_temp.push_receipt_settle(p);
set constraints all immediate; set constraints all deferred;
delete from public.notifications where type='PLAYER_CHECKOUT_REFUND_PENDING' and data->>'payment_id'=p::text;
delete from fieldrush_private.notification_event_receipts where event_key='checkout:'||p||':REFUND_PENDING';
update public.payment_intents set failure_reason='Historical refund waiting for reconciliation.' where id=p;
update public.payment_refunds set attempts=attempts+1,next_attempt_at=clock_timestamp()+interval '1 minute',metadata='{"audit":"Retry bookkeeping."}' where intent_id=p;
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUND_PENDING' and data->>'payment_id'=p::text),'metadata and retry bookkeeping cannot create a historical pending-refund receipt');
perform public.record_external_stripe_refund(p,'re_push_external_half',650,'USD','succeeded');
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=p::text),'a partial confirmed refund never claims the full charge was refunded');
perform pg_temp.push_receipt_expect((select body like '%refund needs review%' and data->>'refund_needs_review'='true'
  from public.notifications where type='PLAYER_CHECKOUT_REFUND_PENDING' and data->>'payment_id'=p::text),'existing pending receipt reflects an external-refund review without retry spam');
perform public.record_external_stripe_refund(p,'re_push_external_rest',650,'USD','succeeded');
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=p::text),'full settled external refunds also complete the checkout receipt');
delete from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=p::text;
delete from fieldrush_private.notification_event_receipts where event_key='checkout:'||p||':REFUNDED';
update public.external_payment_refunds set updated_at=clock_timestamp() where intent_id=p;
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type='PLAYER_CHECKOUT_REFUNDED' and data->>'payment_id'=p::text),'timestamp refreshes of settled external refunds do not replay old outcomes');

-- A later player cancellation is not a failed checkout, and invalidates queued success.
perform set_config('request.jwt.claim.sub',people[1]::text,true);
perform public.cancel_open_queue_booking(b);
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect(not fieldrush_private.player_checkout_notification_source_is_current(notice),'a cancelled booking cannot deliver a stale you-are-in push');
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where type like 'PLAYER_CHECKOUT_REFUND%' and data->>'payment_id'=payments[1]::text),'ordinary booking refund does not masquerade as checkout failure');

-- Actual incident + generated sanction are reduced to one outcome receipt.
payments:=array_append(payments,pg_temp.push_receipt_attempt(people[7],games[3],'automatic'));
response:=pg_temp.push_receipt_settle(payments[7]); b:=(response->>'resource_id')::uuid;
select id into attendance from public.match_attendance_records where booking_id=b;
update public.match_attendance_records set outcome='LATE',strike_delta=3,finalized_at=clock_timestamp(),appeal_due_at=clock_timestamp()+interval '7 days' where id=attendance;
incident:=public.record_reliability_incident(attendance,'LATE',3,clock_timestamp());
insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
  values(people[7],'RELIABILITY_OUTCOME','Attendance finalized as late','Recorded decision.','MATCH_ATTENDANCE',attendance,'{}') returning id into notice;
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect((select count(*)=1 from public.notifications where recipient_profile_id=people[7] and type in ('RELIABILITY_OUTCOME','RELIABILITY_SANCTION') and resolved_at is null),'incident and its sanction produce one surviving notification');
perform pg_temp.push_receipt_expect((select data->>'incident_id'=incident::text and body like '%New bookings are temporarily restricted.%' from public.notifications where id=notice),'one notice includes strike and actual resulting restriction');
perform pg_temp.push_receipt_expect(fieldrush_private.player_discipline_notification_source_is_current(notice),'unreversed incident is a current discipline source');
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where recipient_profile_id=people[7] and type='PLAYER_ACCOUNT_RESTRICTED'),'reliability sanction does not also create a generic restriction push');

-- The legacy appeal decision and its restriction lift stay one notification.
select id into sanction from public.reliability_sanctions where incident_id=incident and sanction_kind='BOOKING_RESTRICTION';
insert into public.reliability_appeals(attendance_id,incident_id,appellant_profile_id,category,message,status,appeal_due_at,reviewed_at,reviewed_by,resolution_note)
  values(attendance,incident,people[7],'APP_OR_OPERATOR_ERROR','The referee corrected this attendance.','OVERTURNED',clock_timestamp()+interval '7 days',clock_timestamp(),admin,'Attendance correction approved.') returning id into appeal;
update public.reliability_sanctions set revoked_at=(select reviewed_at from public.reliability_appeals where id=appeal),revoked_by=admin,revocation_reason='Attendance appeal approved.' where id=sanction;
insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
  values(people[7],'RELIABILITY_APPEAL_DECIDED','Reliability appeal approved','Attendance corrected.','RELIABILITY_APPEAL',appeal,'{}') returning id into notice;
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect((select body like '%You can book games again.%' and data->>'can_book'='true' from public.notifications where id=notice),'appeal receipt includes restored booking access');
perform pg_temp.push_receipt_expect(not exists(select 1 from public.notifications where recipient_profile_id=people[7] and type='PLAYER_RESTRICTION_LIFTED'),'same appeal does not create a separate restriction-lift push');

-- Moderator message is user-visible, while private staff notes stay private.
insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,reason_code,user_message,private_note,starts_at,ends_at,issued_by)
  values('PLAYER',people[8],'SUSPENSION','PLAY','CONDUCT','Your playing access is temporarily suspended.','PRIVATE STAFF NOTE NEVER COPY',clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 hour',admin) returning id into p;
set constraints all immediate; set constraints all deferred;
select id into notice from public.notifications where recipient_profile_id=people[8] and type='PLAYER_ACCOUNT_RESTRICTED';
perform pg_temp.push_receipt_expect(notice is not null and fieldrush_private.player_discipline_notification_source_is_current(notice),'actual moderation restriction receives one current account notice');
perform pg_temp.push_receipt_expect((select body='Your playing access is temporarily suspended.' and data::text not like '%PRIVATE STAFF%' from public.notifications where id=notice),'only the player-visible moderator explanation is copied');
perform fieldrush_private.observe_player_restriction_notification(people[8],clock_timestamp()+interval '2 hours');
perform pg_temp.push_receipt_expect((select count(*)=1 from public.notifications where recipient_profile_id=people[8] and type='PLAYER_RESTRICTION_LIFTED'),'time-only expiry is observed and creates a single restored-access notice');
perform pg_temp.push_receipt_expect((select data->>'route_hint'='account' from public.notifications where recipient_profile_id=people[8] and type='PLAYER_RESTRICTION_LIFTED'),'moderation expiry retains its account destination instead of opening strike history');
perform fieldrush_private.observe_player_restriction_notification(people[8],clock_timestamp()+interval '2 hours');
perform pg_temp.push_receipt_expect((select count(*)=1 from public.notifications where recipient_profile_id=people[8] and type='PLAYER_RESTRICTION_LIFTED'),'repeating expiry sweep does not repeat restored access');
insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,reason_code,user_message,starts_at,ends_at,issued_by)
  values('PLAYER',people[6],'SUSPENSION','PLAY','CONDUCT',repeat('A player-visible explanation. ',16),clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 hour',admin);
set constraints all immediate; set constraints all deferred;
perform pg_temp.push_receipt_expect((select char_length(body)=300 from public.notifications where recipient_profile_id=people[6] and type='PLAYER_ACCOUNT_RESTRICTED'),'long permitted moderation message is bounded without aborting the administrative decision');

perform pg_temp.push_receipt_expect(not has_function_privilege('authenticated','fieldrush_private.emit_player_checkout_notification(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','fieldrush_private.observe_player_restriction_notification(uuid,timestamptz)','EXECUTE')
  and not has_table_privilege('authenticated','fieldrush_private.checkout_notification_acknowledgements','SELECT'),
  'players cannot publish outcomes, manipulate restrictions or read other payment acknowledgements');
end $$;

select count(*) as player_checkout_reliability_notification_checks from push_receipt_checks;
rollback;
