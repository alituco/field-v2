-- Rollback-only complete-schema proof; registered devices are fictitious and
-- no worker/FCM/APNs/network function is invoked.
set local client_min_messages=warning;
create temporary table player_push_checks(label text);
create function pg_temp.player_push_expect(ok boolean,label text) returns void
language plpgsql security definer as $$ begin
  if ok is distinct from true then raise exception 'Player push: %',label; end if;
  insert into player_push_checks values(label);
end $$;
create function pg_temp.player_push_person(number integer) returns uuid language plpgsql as $$
declare person uuid:=gen_random_uuid();
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(person,'1555267'||lpad(number::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',person::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Push','last_name','Fixture',
    'username','push_delivery_'||number,'date_of_birth','2000-01-01','email','push_delivery_'||number||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  return person;
end $$;

do $$
declare person uuid:=pg_temp.player_push_person(1); other uuid:=pg_temp.player_push_person(2);
  installation uuid:=gen_random_uuid(); game uuid; notice uuid; delivery uuid; claim uuid:=gen_random_uuid();
  payload jsonb; receipt jsonb; unsupported uuid; kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '30 days';
begin
  perform set_config('request.jwt.claim.role','service_role',true);
  perform set_config('request.jwt.claim.sub',person::text,true);
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils)
    values('Push fixture original field',kickoff,kickoff+interval '1 hour',0) returning id into game;
  perform public.finalize_free_checkout(person,'SOLO_BOOKING',jsonb_build_object('game_id',game,'role','GK'));
  set constraints all immediate;
  perform public.configure_push_delivery('fieldrush-1cfe5',true);
  perform public.register_my_push_device(installation,1,'player-push-fixture-not-a-real-token','ios','fieldrush-1cfe5');
  update public.open_queue_games set venue='Push fixture updated field' where id=game;
  select id into notice from public.notifications where related_entity_id=game and type='SOLO_GAME_CHANGED';
  perform pg_temp.player_push_expect(notice is not null,'authoritative game edit produces a recipient receipt');
  perform public.claim_push_deliveries(10,claim);
  select id into delivery from fieldrush_private.push_deliveries where notification_id=notice and installation_id=installation;
  payload:=public.get_push_delivery_payload(delivery,claim);
  perform pg_temp.player_push_expect(payload->>'notification_id'=notice::text and payload->>'preview_version'='1',
    'live owned registered binding receives an approved preview');
  perform pg_temp.player_push_expect(payload->>'title'='Your game details changed'
    and payload->>'body' like '%Push fixture updated field%' and payload->>'expires_at' is not null,
    'phone content reflects the changed game and carries a provider deadline');
  perform pg_temp.player_push_expect(not (payload ? 'game_id') and not (payload ? 'payment_id')
    and not (payload ? 'recipient_id'),'phone routing never needs private game/payment/account identifiers');
  perform set_config('request.jwt.claim.role','authenticated',true);
  receipt:=public.get_my_player_notification(notice);
  perform pg_temp.player_push_expect(receipt->>'id'=notice::text and receipt->>'related_entity_id'=game::text,
    'signed-in owner resolves the canonical destination');
  perform set_config('request.jwt.claim.sub',other::text,true);
  perform pg_temp.player_push_expect(public.get_my_player_notification(notice) is null,
    'other account cannot resolve the receipt or its private destination');
  perform set_config('request.jwt.claim.sub',person::text,true);
  perform public.mark_my_home_notification_read(notice);
  perform pg_temp.player_push_expect(public.get_my_player_notification(notice)->>'id'=notice::text,
    'read receipt still opens for its owner');
  perform set_config('request.jwt.claim.role','service_role',true);
  perform pg_temp.player_push_expect(public.get_push_delivery_payload(delivery,claim) is null,
    'already read receipt is suppressed before send');

  update public.open_queue_games set venue='Push fixture second change' where id=game;
  select id into notice from public.notifications where related_entity_id=game and type='SOLO_GAME_CHANGED'
    order by created_at desc,id desc limit 1;
  claim:=gen_random_uuid(); perform public.claim_push_deliveries(10,claim);
  select id into delivery from fieldrush_private.push_deliveries where notification_id=notice and installation_id=installation;
  perform public.revoke_my_push_device(installation,2);
  perform set_config('request.jwt.claim.sub',other::text,true);
  perform public.register_my_push_device(installation,3,'different-owner-push-fixture-token','ios','fieldrush-1cfe5');
  perform pg_temp.player_push_expect(public.get_push_delivery_payload(delivery,claim) is null,
    'account switching invalidates the previous owner pending send');

  update fieldrush_private.push_deliveries set status='SENT',locked_until=null;
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    select other,'GAME_REMINDER','Tomorrow fixture','Arrival details.',
      jsonb_build_object('expires_at',clock_timestamp()+interval '1 hour') from generate_series(1,60);
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(other,'GAME_REMINDER','Last call fixture','Arrival deadline.',
      jsonb_build_object('expires_at',clock_timestamp()+interval '5 minutes')) returning id into unsupported;
  claim:=gen_random_uuid(); perform public.claim_push_deliveries(10,claim);
  perform pg_temp.player_push_expect(exists(select 1 from fieldrush_private.push_deliveries
    where notification_id=unsupported and claim_id=claim),
    'an imminent deadline beats an older sixty-message urgent backlog');
  perform pg_temp.player_push_expect(fieldrush_private.push_priority_for_type('OPEN_QUEUE_PARTY_INVITE')=0,
    'party invitations share the urgent deadline lane');

  -- Arbitrary legacy Activity copy must never become an approved phone preview.
  insert into public.notifications(recipient_profile_id,type,title,body)
    values(person,'SUPPORT_TICKET_UPDATE','Private staff decision','Sensitive fixture-only decision') returning id into unsupported;
  perform pg_temp.player_push_expect(fieldrush_private.player_push_preview(unsupported) is null,
    'unselected events have no new phone preview');
  insert into public.notifications(recipient_profile_id,type,title,body,data)
    values(person,'PLAYER_ACCOUNT_RESTRICTED','Private staff decision','Sensitive fixture-only decision','{"player_push_v1":true}')
    returning id into unsupported;
  payload:=fieldrush_private.player_push_preview(unsupported);
  perform pg_temp.player_push_expect(payload->>'body'='Open Fieldrush to review the decision and your options.'
    and payload::text not like '%Sensitive%','disciplinary details never leak into phone previews');
  update auth.users set banned_until=now()+interval '1 day' where id=person;
  perform pg_temp.player_push_expect(fieldrush_private.player_push_recipient_is_eligible(person,'PLAYER_ACCOUNT_RESTRICTED')
    and not fieldrush_private.player_push_recipient_is_eligible(person,'GAME_REMINDER'),
    'account ban can deliver its decision without reopening optional match alerts');
  update fieldrush_private.accounts set status='deletion_pending' where user_id=person;
  perform pg_temp.player_push_expect(not fieldrush_private.player_push_recipient_is_eligible(person,'PLAYER_ACCOUNT_RESTRICTED'),
    'deleting account never receives a disciplinary exception');
  perform pg_temp.player_push_expect(not has_function_privilege('anon','public.get_my_player_notification(uuid)','EXECUTE')
    and not has_function_privilege('authenticated','public.get_push_delivery_payload(uuid,uuid)','EXECUTE')
    and not has_function_privilege('authenticated','fieldrush_private.player_push_preview(uuid)','EXECUTE'),
    'client grants cannot bypass private payload ownership and binding checks');
end $$;
select count(*)||' player push delivery checks passed.' as result from player_push_checks;
