-- Disposable full-schema transaction. Fake tokens only; no provider call or
-- scheduler is executed. Phone deliveries are inspected in the private outbox.
create function pg_temp.spot_assert(ok boolean,message text)
returns void language plpgsql as $$begin
  if ok is not true then raise exception 'Replacement alerts: %',message; end if;
end$$;
create function pg_temp.spot_reject(statement text)
returns void language plpgsql as $$declare denied boolean:=false; begin
  begin execute statement; exception when insufficient_privilege then denied:=true; end;
  perform pg_temp.spot_assert(denied,'private publisher must be denied');
end$$;

do $$
declare people uuid[]:='{}'; p uuid; i integer; game uuid; other_game uuid; source uuid;
  preferences jsonb:='{"game_reminders":true,"clan_callups":true,"party_invites":true,"ladder_moves":true,"replays_ready":false,"news_and_offers":false}';
  notification uuid; installation uuid:=gen_random_uuid(); claim uuid:=gen_random_uuid(); payload jsonb; play_action uuid;
begin
  for i in 1..10 loop
    p:=gen_random_uuid(); people:=array_append(people,p);
    insert into auth.users(id,phone,phone_confirmed_at) values(p,'15558617'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',p::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Spot','last_name','Fixture',
      'username','spot_fixture_'||i,'date_of_birth','2000-01-01','email','spot'||i||'@example.test','skill_assessment','not_sure'),
      'fieldrush-v1','fieldrush-v1');
    perform pg_temp.spot_assert((public.get_my_profile_settings()->'notifications'->>'open_spots')::boolean=false,'open spots default off');
    perform public.update_my_notification_preferences(preferences||jsonb_build_object('open_spots',i not in (4,10)));
  end loop;
  insert into public.fieldrush_cities(id,display_name,state,country_code,timezone) values('spot-other','Other fixture','NY','US','America/New_York');
  update fieldrush_private.accounts set preferred_city_id='spot-other' where user_id=people[3];
  update fieldrush_private.accounts set status='deletion_pending' where user_id=people[5];
  update auth.users set banned_until=clock_timestamp()+interval '1 day' where id=people[8];
  update auth.users set deleted_at=clock_timestamp() where id=people[9];
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values
    ('Replacement alert fixture',date_trunc('minute',clock_timestamp())+interval '18 hours',date_trunc('minute',clock_timestamp())+interval '19 hours',0) returning id into game;
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values
    ('Other-day alert fixture',date_trunc('minute',clock_timestamp())+interval '42 hours',date_trunc('minute',clock_timestamp())+interval '43 hours',0) returning id into other_game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
    values(game,people[1],'DEF','CONFIRMED',0,0,'FREE') returning id into source;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method) values
    (game,people[6],'ATT','CONFIRMED',0,0,'FREE'),(other_game,people[7],'ATT','CONFIRMED',0,0,'FREE');
  perform set_config('request.jwt.claim.sub',people[1]::text,true);
  perform public.cancel_open_queue_booking(source);
  perform pg_temp.spot_assert((select count(*)=1 from fieldrush_private.replacement_notification_jobs where source_booking_id=source),'cancellation enqueues one job');
  perform pg_temp.spot_assert(not exists(select 1 from public.notifications where type='OPEN_QUEUE_REPLACEMENT_AVAILABLE'),'no fanout occurs inside cancellation');
  perform pg_temp.spot_assert(fieldrush_private.replacement_recipient_eligible(people[2],game,source),'same-city eligible opt-in qualifies');
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(people[1],'Spot fixture admin','+15558617001','admin',true);
  insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,
    reason_code,user_message,starts_at,ends_at,issued_by)
  values('PLAYER',people[2],'SUSPENSION','PLAY','VERIFICATION','Disposable alert restriction.',
    now()-interval '1 minute',now()+interval '1 day',people[1]) returning id into play_action;
  perform pg_temp.spot_assert(public.profile_has_active_play_restriction(people[2]),'test actually establishes an active play restriction');
  perform pg_temp.spot_assert(not fieldrush_private.replacement_recipient_eligible(people[2],game,source),'play-restricted recipient is excluded');
  update public.moderation_actions set revoked_at=clock_timestamp(),revoked_by=people[1],revocation_reason='Disposable fixture.' where id=play_action;
  perform pg_temp.spot_assert(fieldrush_private.replacement_recipient_eligible(people[2],game,source),'revoked play restriction no longer blocks');
  foreach i in array array[1,3,4,5,6,7,8,9] loop
    perform pg_temp.spot_assert(not fieldrush_private.replacement_recipient_eligible(people[i],game,source),'ineligible recipient excluded: '||i);
  end loop;
  perform pg_temp.spot_assert(not fieldrush_private.replacement_recipient_eligible(people[7],game,source),'non-overlapping upcoming game still blocks a second booking');
  perform set_config('request.jwt.claim.sub',people[10]::text,true);
  perform public.update_my_notification_preferences(preferences||'{"open_spots":true}');
  -- Preference source and role-specific DIV range are checked without leaking
  -- another player's settings or throwing player-facing eligibility exceptions.
  update public.open_queue_games set highest_division=2,lowest_division=4 where id=game;
  perform pg_temp.spot_assert(not fieldrush_private.replacement_recipient_eligible(people[2],game,source),'unplaced role excluded from restricted DIV game');
  update public.fieldrush_player_rating_tracks set matches_played=2,skill_rating=1200 where profile_id=people[2] and rating_track='OUTFIELD';
  perform pg_temp.spot_assert(fieldrush_private.replacement_recipient_eligible(people[2],game,source),'revealed eligible outfield role qualifies');
  update public.fieldrush_player_rating_tracks set skill_rating=2500 where profile_id=people[2] and rating_track='OUTFIELD';
  perform pg_temp.spot_assert(not fieldrush_private.replacement_recipient_eligible(people[2],game,source),'out-of-range division excluded');
  update public.fieldrush_player_rating_tracks set skill_rating=1200 where profile_id=people[2] and rating_track='OUTFIELD';
  update public.open_queue_games set highest_division=1,lowest_division=5 where id=game;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.configure_push_delivery('fieldrush-1cfe5',true);
  perform set_config('request.jwt.claim.sub',people[2]::text,true);
  perform public.register_my_push_device(installation,1,'replacement-fixture-not-a-real-fcm-token','android','fieldrush-1cfe5');
  perform pg_temp.spot_assert(fieldrush_private.process_replacement_notifications()=1,'only eligible pre-existing city opt-in receives alert');
  perform pg_temp.spot_assert(fieldrush_private.process_replacement_notifications()=0,'retry produces no duplicate or late-opt-in backlog');
  select id into notification from public.notifications where type='OPEN_QUEUE_REPLACEMENT_AVAILABLE' and recipient_profile_id=people[2];
  perform pg_temp.spot_assert(notification is not null,'in-app Activity notification exists');
  perform pg_temp.spot_assert((select count(*)=1 from fieldrush_private.push_deliveries where notification_id=notification),'same event queues one phone push');
  perform pg_temp.spot_assert(fieldrush_private.notification_source_is_current(notification),'dispatch validates current offer');
  perform public.claim_push_deliveries(10,claim);
  select public.get_push_delivery_payload(id,claim) into payload from fieldrush_private.push_deliveries where notification_id=notification;
  perform pg_temp.spot_assert(payload is not null,'eligible phone payload available to claimed worker');
  insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,
    reason_code,user_message,starts_at,ends_at,issued_by)
  values('PLAYER',people[2],'SUSPENSION','PLAY','VERIFICATION','Disposable dispatch restriction.',
    now()-interval '1 minute',now()+interval '1 day',people[1]) returning id into play_action;
  perform pg_temp.spot_assert(not fieldrush_private.notification_source_is_current(notification),'new play restriction invalidates queued offer');
  select public.get_push_delivery_payload(id,claim) into payload from fieldrush_private.push_deliveries where notification_id=notification;
  perform pg_temp.spot_assert(payload is null,'new play restriction suppresses phone delivery after claim');
  update public.moderation_actions set revoked_at=clock_timestamp(),revoked_by=people[1],revocation_reason='Disposable fixture.' where id=play_action;
  perform public.update_my_notification_preferences(preferences||'{"open_spots":false}');
  perform pg_temp.spot_assert(not fieldrush_private.notification_source_is_current(notification),'later opt-out invalidates source');
  perform public.update_my_notification_preferences(preferences||'{"open_spots":true}');
  perform pg_temp.spot_assert(not fieldrush_private.notification_source_is_current(notification),'off then on never revives the old queued offer');
  select public.get_push_delivery_payload(id,claim) into payload from fieldrush_private.push_deliveries where notification_id=notification;
  perform pg_temp.spot_assert(payload is null,'opt-out suppresses phone delivery after claim');
  perform fieldrush_private.process_replacement_notifications();
  perform pg_temp.spot_assert((select resolved_at is not null from public.notifications where id=notification),'stale Activity is resolved');
  perform public.update_my_notification_preferences(preferences);
  perform pg_temp.spot_assert((public.get_my_profile_settings()->'notifications'->>'open_spots')::boolean,'old six-key clients preserve open-spots preference');
  update public.open_queue_games set replacement_offer_expires_at=clock_timestamp()-interval '1 second' where id=game;
  perform pg_temp.spot_assert(not fieldrush_private.notification_source_is_current(notification),'expired offer cannot push');
  perform pg_temp.spot_assert((select schedule='* * * * *' from cron.job where jobname='fieldrush-replacement-notifications'),'bounded replacement sweep is minutely');
  perform pg_temp.spot_assert(not has_function_privilege('authenticated','fieldrush_private.process_replacement_notifications()','EXECUTE'),'player cannot publish');
  perform pg_temp.spot_assert(not has_function_privilege('service_role','fieldrush_private.enqueue_replacement_offer(uuid,uuid)','EXECUTE'),'service clients cannot forge events');
end$$;
set local role authenticated;
select pg_temp.spot_reject('select * from fieldrush_private.replacement_notification_jobs');
select pg_temp.spot_reject('select fieldrush_private.process_replacement_notifications()');
reset role;
select 'Replacement alert city, division, account, preferences, cancellation and phone-outbox verification passed.' as result;
