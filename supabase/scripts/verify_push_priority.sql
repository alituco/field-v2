-- Disposable full-schema transaction. No scheduler/provider calls. Fake device
-- only; exercising the actual SQL claim/outbox does not send a phone push.
create function pg_temp.push_priority_expect(ok boolean,message text)
returns void language plpgsql as $$begin
  if ok is not true then raise exception 'Push priority: %',message; end if;
end$$;

do $$
declare person uuid:=gen_random_uuid(); installation uuid:=gen_random_uuid(); reminder uuid; spot uuid;
  claim uuid; claimed jsonb; routine integer; urgent integer; marketing integer; expiry_id uuid;
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(person,'15558618001',now());
  perform set_config('request.jwt.claim.sub',person::text,true);
  perform public.complete_fieldrush_onboarding(
    '{"first_name":"Push","last_name":"Priority","username":"push_priority_test","date_of_birth":"2000-01-01","email":"pushpriority@example.test","skill_assessment":"not_sure"}',
    'fieldrush-v1','fieldrush-v1');
  perform public.update_my_notification_preferences(
    '{"game_reminders":true,"open_spots":true,"clan_callups":true,"party_invites":true,"ladder_moves":true,"replays_ready":true,"news_and_offers":true}');
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.configure_push_delivery('fieldrush-1cfe5',true);
  perform public.register_my_push_device(installation,1,'push-priority-fixture-not-a-real-token','android','fieldrush-1cfe5');
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    select person,'NEWS_AND_OFFERS','Fixture news','Not a real publication.',jsonb_build_object('expires_at',now()+interval '1 day')
    from generate_series(1,1000);
  update fieldrush_private.push_deliveries set next_attempt_at=now()-interval '1 hour';
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(person,'GAME_REMINDER','Fixture reminder','Not a real game.',jsonb_build_object('expires_at',now()+interval '2 hours')) returning id into reminder;
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(person,'OPEN_QUEUE_REPLACEMENT_AVAILABLE','Fixture open spot','Not a real offer.',jsonb_build_object('expires_at',now()+interval '1 hour')) returning id into spot;
  claim:=gen_random_uuid(); claimed:=public.claim_push_deliveries(10,claim);
  perform pg_temp.push_priority_expect(jsonb_array_length(claimed)=10,'batch remains bounded to ten');
  perform pg_temp.push_priority_expect((select count(*)=2 from fieldrush_private.push_deliveries
    where notification_id in (reminder,spot) and claim_id=claim),'both newly-due urgent alerts pass the thousand-item marketing backlog immediately');
  perform pg_temp.push_priority_expect((select priority=0 and expires_at<=now()+interval '2 hours' from fieldrush_private.push_deliveries
    where notification_id=reminder),'priority and deadline come from authoritative notification');
  claimed:=public.claim_push_deliveries(10,gen_random_uuid());
  perform pg_temp.push_priority_expect(not exists(select 1 from fieldrush_private.push_deliveries
    where notification_id in (reminder,spot) and claim_id<>claim),'another worker cannot reclaim the active lease');
  update fieldrush_private.push_deliveries set status='SENT',locked_until=null;

  -- With all lanes busy, urgent traffic gets eight slots while both lower
  -- lanes still progress. No permanent marketing/routine starvation.
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    select person,event_type,'Lane fixture','No actual delivery.',jsonb_build_object('expires_at',now()+interval '1 day')
    from (values('GAME_REMINDER'),('LADDER_MOVE'),('NEWS_AND_OFFERS')) t(event_type),generate_series(1,30);
  claim:=gen_random_uuid(); claimed:=public.claim_push_deliveries(10,claim);
  select count(*) filter(where priority=0),count(*) filter(where priority=1),count(*) filter(where priority=2)
    into urgent,routine,marketing from fieldrush_private.push_deliveries where claim_id=claim;
  perform pg_temp.push_priority_expect(urgent=8 and routine=1 and marketing=1,'weighted fair capacity is 8 urgent / 1 routine / 1 marketing');
  claimed:=public.claim_push_deliveries(10,gen_random_uuid());
  perform pg_temp.push_priority_expect(jsonb_array_length(claimed)=10,'a subsequent worker claims distinct remaining rows while the first lease is active');
  update fieldrush_private.push_deliveries set status='SENT',locked_until=null;

  insert into public.notifications(recipient_profile_id,type,title,body,data)
    select person,'NEWS_AND_OFFERS','Fill fixture','No actual delivery.','{}' from generate_series(1,20);
  claim:=gen_random_uuid(); claimed:=public.claim_push_deliveries(10,claim);
  perform pg_temp.push_priority_expect((select count(*)=10 from fieldrush_private.push_deliveries where claim_id=claim and priority=2),'unused urgent/routine capacity is not wasted');
  update fieldrush_private.push_deliveries set status='SENT',locked_until=null;

  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(person,'GAME_REMINDER','Expired fixture','No actual delivery.',jsonb_build_object('expires_at',now()-interval '1 second')) returning id into expiry_id;
  claimed:=public.claim_push_deliveries(10,gen_random_uuid());
  perform pg_temp.push_priority_expect(jsonb_array_length(claimed)=0,'expired urgent deliveries consume no slots');
  perform pg_temp.push_priority_expect((select status='SKIPPED' from fieldrush_private.push_deliveries where notification_id=expiry_id),'expired queue entries are retired');
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(person,'GAME_REMINDER','Malformed expiry','No actual delivery.','{"expires_at":"not-a-date"}') returning id into expiry_id;
  claimed:=public.claim_push_deliveries(10,gen_random_uuid());
  perform pg_temp.push_priority_expect(jsonb_array_length(claimed)=0,'invalid expiry fails closed without blocking queue');
  perform pg_temp.push_priority_expect((select status='SKIPPED' from fieldrush_private.push_deliveries where notification_id=expiry_id),'malformed expiry is retired');
  perform public.configure_push_delivery('fieldrush-1cfe5',false);
  perform pg_temp.push_priority_expect(public.claim_push_deliveries(10,gen_random_uuid())='[]'::jsonb,'priority changes never bypass the delivery kill switch');
  perform pg_temp.push_priority_expect(not has_function_privilege('authenticated','public.claim_push_deliveries(integer,uuid)','EXECUTE'),'players cannot claim');
  perform pg_temp.push_priority_expect(not has_table_privilege('service_role','fieldrush_private.push_deliveries','UPDATE'),'service clients cannot assign their own priority');
end$$;
select 'Push priority and fair bounded claims passed with a 1,000-delivery backlog.' as result;
