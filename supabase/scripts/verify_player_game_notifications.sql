-- Rollback-only full-schema contract. No provider calls or real device tokens.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
select set_config('field.admin_score_override','on',true);
create temporary table player_game_notice_checks(label text);
create sequence pg_temp.player_game_notice_person_number;
create function pg_temp.game_notice_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Player game notifications: %',label; end if;
  insert into player_game_notice_checks values(label);
end $$;
create function pg_temp.game_notice_person() returns uuid language plpgsql as $$
declare p uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.player_game_notice_person_number');
  previous text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(p,'1555265'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',p::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Game','last_name','Notices',
    'username','game_notice_'||n,'date_of_birth','2000-01-01','email','game_notice_'||n||'@example.test','skill_assessment','not_sure'),
    'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous,''),true);
  return p;
end $$;
create function pg_temp.flush_game_notices() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function pg_temp.notice_game(label text,kickoff timestamptz) returns uuid language plpgsql as $$
declare g uuid;
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils)
    values(label,kickoff,kickoff+interval '1 hour',0) returning id into g;
  return g;
end $$;
create function pg_temp.notice_booking(g uuid,p uuid,role_to_use text default 'GK',booked timestamptz default now()-interval '2 days')
returns uuid language plpgsql as $$
declare b uuid;
begin
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,booked_at)
    values(g,p,role_to_use,'CONFIRMED',0,0,'FREE',booked) returning id into b;
  return b;
end $$;

do $$
declare p uuid:=pg_temp.game_notice_person(); teammate uuid:=pg_temp.game_notice_person();
  admin uuid:=pg_temp.game_notice_person(); login uuid:=gen_random_uuid(); game uuid; b uuid; second_b uuid;
  reminder_game uuid; reminder_b uuid; late_booker uuid; checked_player uuid; checked_b uuid;
  count_before integer; notification uuid; details jsonb; kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '4 days';
  at_clock timestamptz:=date_trunc('minute',clock_timestamp())+interval '30 seconds'; party uuid; invite uuid; result jsonb;
  case_id uuid; old_notice uuid; removed_game uuid; removed_b uuid; before_cancel uuid; cancelled_game uuid; saved_field uuid;
  payment uuid; refund uuid;
  rebook_game uuid; old_rebook uuid; new_rebook uuid; opponent_book uuid; rebook_player uuid; rebook_opponent uuid;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin,'Game notices admin','+15552659999','admin',true);
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,login||'@notice-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
  update public.referee_profiles set auth_user_id=login,email=login||'@notice-staff.example.test' where profile_id=admin;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '2 days') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable game notification policy.',now(),admin
    from public.reliability_policy_versions order by version limit 1;
  update fieldrush_private.player_game_notice_activation set activated_at=at_clock-interval '1 day';

  game:=pg_temp.notice_game('Game notices team fixture',kickoff);
  b:=pg_temp.notice_booking(game,p); second_b:=pg_temp.notice_booking(game,teammate,'DEF');
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=game),
    'ordinary unassigned booking does not fabricate a team or a result notice');
  update public.open_queue_bookings set team=case when id=b then 'WHITE' else 'BLACK' end where game_id=game;
  -- Assignment publication happens after the individual booking updates.
  update public.open_queue_games set teams_assigned_at=clock_timestamp() where id=game;
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=game),
    'transactional team work does not emit notices before the final state');
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=2 from public.notifications where related_entity_id=game and type='SOLO_TEAM_READY'),
    'actual team publication announces each booked player once');
  select id,data into notification,details from public.notifications where related_entity_id=game and recipient_profile_id=p and type='SOLO_TEAM_READY';
  perform pg_temp.game_notice_expect(details->>'team'='WHITE' and details->>'check_in_label' is not null
    and details->>'deadline_label' is not null,'team notice includes the actual side and arrival contract');
  perform pg_temp.game_notice_expect(fieldrush_private.player_game_notification_source_is_current(notification),
    'current assigned team is dispatchable');
  select count(*) into count_before from public.notifications where related_entity_id=game;
  update public.open_queue_bookings set team='BLACK' where id=b;
  update public.open_queue_bookings set team='WHITE' where id=b;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=count_before from public.notifications where related_entity_id=game),
    'temporary team changes restored within one transaction are silent');
  update public.open_queue_bookings set team='BLACK' where id=b;
  -- Legacy writer must not create a second notice alongside the observer.
  insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id)
    values(p,'OPEN_QUEUE_TEAM_REASSIGNED','Old writer','Old writer','OPEN_QUEUE_GAME',game);
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=1 from public.notifications where related_entity_id=game and type='SOLO_TEAM_CHANGED')
    and not exists(select 1 from public.notifications where related_entity_id=game and type='OPEN_QUEUE_TEAM_REASSIGNED'),
    'only the moved recipient gets one reassignment, without the old duplicate');
  perform pg_temp.game_notice_expect(not fieldrush_private.player_game_notification_source_is_current(notification),
    'old team push is invalidated when the player moves');

  insert into public.fields(name,address,latitude,longitude)
    values('Game notices new field','200 New Field Avenue',33.4,-112.1) returning id into saved_field;
  -- Existing production games retain immutable location/time snapshots. This
  -- supported legacy-to-saved-field binding exercises a real changed snapshot.
  update public.open_queue_games set field_id=saved_field where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=2 from public.notifications where related_entity_id=game and type='SOLO_GAME_CHANGED'),
    'one committed venue/address change reaches both currently booked players');
  select id,data into notification,details from public.notifications where related_entity_id=game and recipient_profile_id=p and type='SOLO_GAME_CHANGED';
  perform pg_temp.game_notice_expect(details->>'venue_label'='Game notices new field'
    and (details->>'check_in_at')::timestamptz=(select starts_at-interval '30 minutes' from public.open_queue_games where id=game),
    'changed-field notice retains the saved arrival time instead of displaying kickoff');
  perform pg_temp.game_notice_expect((select body like '%200 New Field Avenue%' from public.notifications where id=notification),
    'a changed address is included in the notice');
  select count(*) into count_before from public.notifications where related_entity_id=game;
  update public.open_queue_games set white_average_sr=1234 where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=count_before from public.notifications where related_entity_id=game),
    'an unrelated average SR refresh does not notify the lobby');

  -- Existing party invitation creation is enriched and expires at the saved lock.
  insert into public.open_queue_parties(game_id,owner_profile_id) values(game,p) returning id into party;
  insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by)
    values(party,game,teammate,'INVITED',p) returning id into invite;
  notification:=public.create_open_queue_party_invite_notification(invite);
  select data into details from public.notifications where id=notification;
  perform pg_temp.game_notice_expect((details->>'expires_at')::timestamptz=(select party_lock_at from public.match_reliability_terms where open_queue_game_id=game),
    'party invite expiry uses the actual saved party lock');
  perform pg_temp.game_notice_expect(fieldrush_private.player_game_notification_source_is_current(notification),
    'pending booked party invite remains dispatchable before lock');
  update public.open_queue_party_members set status='ACCEPTED',responded_at=now(),joined_at=now() where id=invite;
  perform pg_temp.game_notice_expect(not fieldrush_private.player_game_notification_source_is_current(notification),
    'an already accepted invitation cannot notify later');

  -- 24h and2h boundaries are relative to arrival, not kickoff, with no catch-up
  -- blast for a player who booked after that boundary.
  reminder_game:=pg_temp.notice_game('Tomorrow notice fixture',at_clock+interval '24 hours 30 minutes'-interval '30 seconds');
  reminder_b:=pg_temp.notice_booking(reminder_game,pg_temp.game_notice_person());
  late_booker:=pg_temp.game_notice_person(); perform pg_temp.notice_booking(reminder_game,late_booker,'DEF',at_clock);
  checked_player:=pg_temp.game_notice_person(); checked_b:=pg_temp.notice_booking(reminder_game,checked_player,'ATT');
  update public.match_attendance_records set checked_in_at=at_clock,checked_in_by=admin where booking_id=checked_b;
  perform pg_temp.flush_game_notices();
  perform fieldrush_private.process_player_game_reminders(at_clock);
  perform pg_temp.game_notice_expect((select count(*)=1 from public.notifications where related_entity_id=reminder_game and type='GAME_REMINDER'
    and data->>'reminder_kind'='24h'),'only the early-booked, unchecked-in participant gets the arrival-based24h reminder');
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=reminder_game
    and recipient_profile_id in (late_booker,checked_player)),'late booking and checked-in players do not receive a stale tomorrow reminder');
  perform fieldrush_private.process_player_game_reminders(at_clock+interval '30 seconds');
  perform pg_temp.game_notice_expect((select count(*)=1 from public.notifications where related_entity_id=reminder_game and type='GAME_REMINDER'),
    'overlapping reminder sweeps remain idempotent');

  reminder_game:=pg_temp.notice_game('Two hour notice fixture',at_clock+interval '2 hours 30 minutes'-interval '30 seconds');
  reminder_b:=pg_temp.notice_booking(reminder_game,pg_temp.game_notice_person());
  second_b:=pg_temp.notice_booking(reminder_game,pg_temp.game_notice_person(),'DEF');
  perform pg_temp.flush_game_notices();
  update public.open_queue_bookings set team='WHITE' where id=reminder_b;
  update public.open_queue_games set teams_assigned_at=at_clock where id=reminder_game;
  perform pg_temp.flush_game_notices();
  perform fieldrush_private.process_player_game_reminders(at_clock);
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=reminder_game
    and type='GAME_REMINDER' and data->>'booking_id'=reminder_b::text),
    'nearby team publication already includes arrival/deadline and replaces the2h reminder');
  perform pg_temp.game_notice_expect(exists(select 1 from public.notifications where related_entity_id=reminder_game
    and type='GAME_REMINDER' and data->>'booking_id'=second_b::text and data->>'reminder_kind'='2h'),
    'a player without a team notice still gets their2h reminder');

  reminder_game:=pg_temp.notice_game('Last call notice fixture',at_clock+interval '15 minutes'-interval '30 seconds');
  reminder_b:=pg_temp.notice_booking(reminder_game,pg_temp.game_notice_person());
  perform pg_temp.flush_game_notices();
  perform fieldrush_private.process_player_game_reminders(at_clock);
  select id,data into notification,details from public.notifications where related_entity_id=reminder_game and type='GAME_REMINDER';
  perform pg_temp.game_notice_expect(notification is not null and details->>'reminder_kind'='check_in_deadline'
    and (details->>'expires_at')::timestamptz=(select arrival_check_in_deadline_at from public.match_reliability_terms where open_queue_game_id=reminder_game),
    'last call is five minutes before the strict deadline and expires at that deadline');
  perform pg_temp.game_notice_expect(fieldrush_private.player_game_notification_source_is_current(notification),
    'a still-unchecked-in last call is current');
  update public.match_attendance_records set checked_in_at=at_clock,checked_in_by=admin where booking_id=reminder_b;
  perform pg_temp.game_notice_expect(not fieldrush_private.player_game_notification_source_is_current(notification),
    'referee check-in invalidates an already queued last call');
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null where booking_id=reminder_b;
  insert into public.open_queue_clock_states(game_id,status,started_at) values(reminder_game,'RUNNING',clock_timestamp())
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.open_queue_games set status='LIVE' where id=reminder_game;
  perform pg_temp.game_notice_expect(not fieldrush_private.player_game_notification_source_is_current(notification),
    'a started game invalidates the last call even when attendance is absent');

  -- Review and correction notices are distinct from an ordinary first result.
  -- Accepting the party above correctly invalidates its Season0 assignment.
  -- Republish the fixture's teams before testing a later live reassignment.
  update public.open_queue_games set teams_assigned_at=clock_timestamp() where id=game;
  perform pg_temp.flush_game_notices();
  insert into public.open_queue_clock_states(game_id,status,started_at) values(game,'RUNNING',clock_timestamp())
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.open_queue_games set status='LIVE',white_score=1,black_score=0 where id=game;
  perform pg_temp.flush_game_notices();
  -- Fixture-only game-scoped finalization context used by the real audited
  -- writers. This suite tests notifications, not the independent SR calculator.
  perform set_config('field.allow_early_open_queue_finalization',game::text,true);
  perform set_config('fieldrush.season_zero_finalizing',game::text,true);
  update public.match_attendance_records set checked_in_at=clock_timestamp(),checked_in_by=admin where open_queue_game_id=game;
  update public.open_queue_bookings set team='WHITE' where id=b;
  update public.open_queue_bookings set played=true,rating_at_match_start=1000,rating_at_team_assignment=1000 where game_id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect(exists(select 1 from public.notifications where related_entity_id=game
    and type='SOLO_TEAM_CHANGED' and data->>'team'='WHITE' and fieldrush_private.player_game_notification_source_is_current(id)),
    'a live referee reassignment reaches the moved player');
  update public.open_queue_games set status='FINAL' where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED'),
    'this scoped change does not add unrequested first-result pushes');
  update public.open_queue_games set white_score=2 where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=2 from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED'),
    'a meaningful published score correction reaches both participants');
  select id into old_notice from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED' and recipient_profile_id=p;
  update public.open_queue_clock_states set status='RUNNING',started_at=clock_timestamp() where game_id=game;
  update public.open_queue_games set status='LIVE' where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=2 from public.notifications where related_entity_id=game and type='SOLO_MATCH_REVIEW')
    and not fieldrush_private.player_game_notification_source_is_current(old_notice),
    'reopening a published result informs players and invalidates the former correction');
  update public.notifications set resolved_at=clock_timestamp() where related_entity_id=game and type='SOLO_MATCH_REVIEW';
  update public.open_queue_games set status='FINAL' where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=4 from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED'),
    'closing the reopened game publishes one follow-up even if its review receipt expired and the score is unchanged');
  perform pg_temp.game_notice_expect(not fieldrush_private.player_game_notification_source_is_current(old_notice),
    'an old correction does not revive after a later reopen finishes with the same score');
  perform pg_temp.game_notice_expect(not exists(select 1 from public.notifications where related_entity_id=game
    and type='SOLO_MATCH_CORRECTED' and (data?'rating_change' or data?'rating_before' or data?'rating_after')),
    'correction receipts never expose numeric placement SR through notification data');
  select count(*) into count_before from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED';
  update public.open_queue_games set white_average_sr=1432 where id=game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=count_before from public.notifications where related_entity_id=game and type='SOLO_MATCH_CORRECTED'),
    'metadata updates after closing a review do not repeat the review decision');

  -- Prior personal cancellations may retain a referee check-in. Rebooking must
  -- not make that historical generation a second review/correction recipient.
  rebook_game:=pg_temp.notice_game('Rebooked review notice fixture',kickoff+interval '1 day');
  rebook_player:=pg_temp.game_notice_person(); rebook_opponent:=pg_temp.game_notice_person();
  old_rebook:=pg_temp.notice_booking(rebook_game,rebook_player);
  update public.match_attendance_records set checked_in_at=clock_timestamp(),checked_in_by=admin where booking_id=old_rebook;
  perform pg_temp.flush_game_notices();
  perform set_config('request.jwt.claim.sub',rebook_player::text,true);
  perform public.cancel_open_queue_booking(old_rebook);
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect(exists(select 1 from public.match_attendance_records where booking_id=old_rebook
    and checked_in_at is not null and outcome='CANCELLED_EARLY'),
    'personal cancellation fixture actually retains the historical referee check-in');
  new_rebook:=pg_temp.notice_booking(rebook_game,rebook_player);
  opponent_book:=pg_temp.notice_booking(rebook_game,rebook_opponent,'ATT');
  perform pg_temp.flush_game_notices();
  update public.open_queue_games set operational_state='UNDER_REVIEW' where id=rebook_game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=1 and bool_and(data->>'booking_id'=new_rebook::text)
    from public.notifications where related_entity_id=rebook_game and recipient_profile_id=rebook_player and type='SOLO_MATCH_REVIEW'),
    'only the current rebooking receives the review notice despite the historical check-in');
  insert into public.open_queue_clock_states(game_id,status,started_at) values(rebook_game,'RUNNING',clock_timestamp())
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.match_attendance_records set checked_in_at=clock_timestamp(),checked_in_by=admin where booking_id in (new_rebook,opponent_book);
  update public.open_queue_bookings set team=case when id=new_rebook then 'WHITE' else 'BLACK' end,
    played=true,rating_at_match_start=1000,rating_at_team_assignment=1000 where id in (new_rebook,opponent_book);
  update public.open_queue_games set operational_state='NORMAL',status='LIVE',teams_assigned_at=clock_timestamp(),white_score=1,black_score=0 where id=rebook_game;
  perform pg_temp.flush_game_notices();
  perform set_config('field.allow_early_open_queue_finalization',rebook_game::text,true);
  perform set_config('fieldrush.season_zero_finalizing',rebook_game::text,true);
  update public.open_queue_games set status='FINAL' where id=rebook_game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=1 and bool_and(data->>'booking_id'=new_rebook::text)
    from public.notifications where related_entity_id=rebook_game and recipient_profile_id=rebook_player and type='SOLO_MATCH_CORRECTED'),
    'review closure reaches only the current booking generation');
  update public.open_queue_games set white_score=2 where id=rebook_game;
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=1 and bool_and(data->>'booking_id'=new_rebook::text)
    from public.notifications where related_entity_id=rebook_game and recipient_profile_id=rebook_player
      and type='SOLO_MATCH_CORRECTED' and data->>'white_score'='2'),
    'a later score correction also excludes the checked-in but personally cancelled generation');

  -- Ordinary organizer cancellation excludes prior personal cancellations.
  cancelled_game:=pg_temp.notice_game('Cancelled notification fixture',kickoff+interval '2 days');
  p:=pg_temp.game_notice_person(); teammate:=pg_temp.game_notice_person();
  b:=pg_temp.notice_booking(cancelled_game,p); before_cancel:=pg_temp.notice_booking(cancelled_game,teammate,'DEF');
  perform pg_temp.flush_game_notices();
  perform set_config('request.jwt.claim.sub',teammate::text,true);
  perform public.cancel_open_queue_booking(before_cancel);
  perform pg_temp.flush_game_notices();
  perform public.admin_cancel_match(admin,'SOLO',cancelled_game,'WEATHER_OR_VENUE','Lightning closed the field.');
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect((select count(*)=1 from public.notifications where related_entity_id=cancelled_game and type='SOLO_GAME_CANCELLED')
    and not exists(select 1 from public.notifications where related_entity_id=cancelled_game and recipient_profile_id=teammate),
    'Fieldrush cancellation reaches the actual current booking, not a former personal cancellation');
  select id,data into notification,details from public.notifications where related_entity_id=cancelled_game and type='SOLO_GAME_CANCELLED';
  perform pg_temp.game_notice_expect(details->>'refund_message'='No payment was taken for this booking.'
    and fieldrush_private.player_game_notification_source_is_current(notification),
    'free cancellation has an honest no-payment receipt and valid source');

  -- Legacy projected refund_status alone is not proof that a card was refunded.
  payment:=gen_random_uuid();
  insert into public.payment_intents(id,profile_id,purpose,status,currency,amount_fils,payload,quote_snapshot,
    transaction_reference,provider,provider_intent_id,provider_payment_id,payment_method,provider_status,captured_at)
  values(payment,p,'SOLO_BOOKING','FINALIZED','USD',13000,jsonb_build_object('game_id',cancelled_game,'role','GK'),'{}',
    'notice_'||payment,'STRIPE','pi_notice_'||payment,'ch_notice_'||payment,'CARD','SUCCEEDED',clock_timestamp());
  update public.open_queue_bookings set payment_intent_id=payment,amount_paid_fils=13000,base_amount_fils=13000,
    payment_method='CARD',payment_status='REFUNDED',refund_status='PROCESSED' where id=b;
  details:=fieldrush_private.player_booking_refund_notice(b);
  perform pg_temp.game_notice_expect(details->>'refunded_minor'='0' and details->>'refund_message' not like '%full refund%',
    'optimistic booking refund flags never become a confirmed card-refund claim');
  perform public.request_payment_refund(payment,13000,'notice-refund-'||payment,'Cancelled game refund.');
  details:=fieldrush_private.player_booking_refund_notice(b);
  perform pg_temp.game_notice_expect(details->>'pending_refund_minor'='1300' and details->>'refund_message' like '%is processing%',
    'requested card refund is described as processing rather than paid back');
  select id into refund from public.payment_refunds where intent_id=payment;
  perform public.finish_payment_refund(refund,'re_notice_'||payment,'succeeded',1300,'USD');
  details:=fieldrush_private.player_booking_refund_notice(b);
  perform pg_temp.game_notice_expect(details->>'refunded_minor'='1300' and details->>'refund_message' like '%full refund has been processed%',
    'full-refund wording requires provider-confirmed full repayment');

  -- A moderation-enforced removal is distinguishable from player cancellation.
  removed_game:=pg_temp.notice_game('Removed booking notice fixture',kickoff+interval '3 days');
  p:=pg_temp.game_notice_person(); removed_b:=pg_temp.notice_booking(removed_game,p);
  perform pg_temp.flush_game_notices();
  insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,
    reason_code,user_message,starts_at,ends_at,issued_by)
  values('PLAYER',p,'SUSPENSION','PLAY','VERIFICATION','Disposable account restriction.',
    now()-interval '1 minute',now()+interval '1 day',admin);
  perform pg_temp.flush_game_notices();
  perform pg_temp.game_notice_expect(exists(select 1 from public.notifications where related_entity_id=removed_game
    and type='SOLO_BOOKING_REMOVED' and recipient_profile_id=p),'forced booking release produces its own game receipt');

  perform pg_temp.game_notice_expect(not has_function_privilege('authenticated',
    'fieldrush_private.observe_player_game_notice(uuid)','EXECUTE') and not has_function_privilege('service_role',
    'fieldrush_private.emit_player_game_notice(uuid,text,text,text,text,uuid,jsonb)','EXECUTE'),
    'clients and service roles cannot forge player notification receipts');
  perform pg_temp.game_notice_expect(not has_table_privilege('authenticated','fieldrush_private.player_game_notice_state','SELECT'),
    'private player snapshots cannot be enumerated');
  perform pg_temp.game_notice_expect((select schedule='* * * * *' and command='select fieldrush_private.process_notification_events();'
    from cron.job where jobname='fieldrush-notification-events'),'one-minute sweep runs the private worker without a missing JWT');
end $$;
select count(*) as player_game_notification_assertions from player_game_notice_checks;
