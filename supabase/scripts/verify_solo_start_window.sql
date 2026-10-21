-- Independent synthetic staff Auth; never promote the player login.
create function pg_temp.bind_staff_login_for_verification(staff_id uuid)
returns uuid language plpgsql as $$
declare login uuid:=gen_random_uuid(); address text:=login::text||'@staff-fixture.example';
begin
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,address,now(),'{"fieldrush_account_type":"staff"}'::jsonb);
  update public.referee_profiles set auth_user_id=login,email=address where profile_id=staff_id;
  if not found then raise exception 'The exact synthetic staff fixture was not found.'; end if;
  return login;
end$$;

-- Disposable full-schema regression. The caller owns BEGIN/ROLLBACK; no real
-- players, bookings, streams, payments or persisted match history are touched.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table start_window_checks(label text);
create function pg_temp.window_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Solo start window: %',label; end if;
  insert into start_window_checks values(label);
end;
$$;
create function pg_temp.window_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.window_expect(rejected,'rejected: '||expected);
end;
$$;
create sequence pg_temp.window_person;
create function pg_temp.window_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.window_person');
  previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555666'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Window','last_name','Player',
    'username','window_'||n,'date_of_birth','2000-01-01','email','window_'||n||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  return player;
end;
$$;
create function pg_temp.window_game(kickoff timestamptz,paid boolean default false) returns uuid language plpgsql as $$
declare game uuid; player uuid; i integer;
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable kickoff-window regression',kickoff,kickoff+interval '1 hour',case when paid then 13000 else 0 end,4,8)
    returning id into game;
  for i in 1..14 loop
    player:=pg_temp.window_player();
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
      values(game,player,case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',
        case when paid then 13000 else 0 end,case when paid then 13000 else 0 end,case when paid then 'MOCK' else 'FREE' end,'PAID');
  end loop;
  return game;
end;
$$;

do $$
declare anchor timestamptz:='2026-11-01 20:30:00-07';
begin
  perform pg_temp.window_expect(fieldrush_rating_private.solo_start_window_allows(anchor,anchor-interval '24 hours'),'inclusive earliest kickoff');
  perform pg_temp.window_expect(fieldrush_rating_private.solo_start_window_allows(anchor,anchor+interval '24 hours'),'inclusive latest kickoff');
  perform pg_temp.window_expect(not fieldrush_rating_private.solo_start_window_allows(anchor,anchor-interval '24 hours 1 microsecond'),'before earliest boundary rejected');
  perform pg_temp.window_expect(not fieldrush_rating_private.solo_start_window_allows(anchor,anchor+interval '24 hours 1 microsecond'),'after latest boundary rejected');
  perform pg_temp.window_expect(fieldrush_rating_private.solo_start_window_allows(anchor,anchor),'advertised kickoff allowed');
  perform set_config('TimeZone','America/Phoenix',true);
  perform pg_temp.window_expect(fieldrush_rating_private.solo_start_window_allows('2026-11-01 20:30:00-07','2026-11-03 03:30:00+00'),'Phoenix and UTC denote same inclusive boundary');
  perform set_config('TimeZone','UTC',true);
  perform pg_temp.window_expect(fieldrush_rating_private.solo_start_window_allows('2026-11-01 20:30:00-07','2026-11-03 03:30:00+00'),'server timezone does not change duration');
end;
$$;

do $$
declare admin_id uuid:=pg_temp.window_player(); referee_id uuid:=pg_temp.window_player(); outsider uuid:=pg_temp.window_player();
  early_game uuid; late_game uuid; before_game uuid; after_game uuid; locked_game uuid; legacy_game uuid;
  boundary_game uuid; missing_game uuid; player uuid; last_player uuid; participants jsonb; result jsonb;
  schedule_before jsonb; terms_before jsonb; money_before jsonb; tracks_before jsonb; started timestamptz;
  kickoff timestamptz; state_revision integer; injury jsonb; period uuid; checkin_revision integer;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (admin_id,'Window admin','+15556660001','admin',true),
    (referee_id,'Assigned referee','+15556660002','referee',true),
    (outsider,'Unassigned referee','+15556660003','referee',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  perform pg_temp.bind_staff_login_for_verification(referee_id);
  perform pg_temp.bind_staff_login_for_verification(outsider);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  -- Existing unchanged policy supplies actual contracts for delayed fixtures.
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '3 days') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable unchanged policy for kickoff-window regression.',now(),admin_id
    from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable start-window verification only.');

  -- Near the early boundary, beyond the former three-hour team reveal.
  early_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())+interval '23 hours',true);
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(early_game,referee_id,admin_id);
  perform pg_temp.window_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',outsider,early_game,gen_random_uuid()),'not assigned to you');
  perform public.referee_assign_season_zero_teams(referee_id,early_game,gen_random_uuid());
  for player in select profile_id from public.open_queue_bookings where game_id=early_game loop
    perform public.referee_check_in_player_with_timing(referee_id,'SOLO',early_game,player,'EARLY');
  end loop;
  select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=early_game;
  select jsonb_build_object('starts_at',starts_at,'ends_at',ends_at,'season_id',season_id,'price_fils',price_fils) into schedule_before
    from public.open_queue_games where id=early_game;
  select to_jsonb(t) into terms_before from public.match_reliability_terms t where open_queue_game_id=early_game;
  select jsonb_agg(jsonb_build_object('id',id,'amount_paid_fils',amount_paid_fils,'base_amount_fils',base_amount_fils,
    'refund_amount_fils',refund_amount_fils,'payment_status',payment_status,'reliability_deposit_status',reliability_deposit_status) order by id)
    into money_before from public.open_queue_bookings where game_id=early_game;
  select jsonb_agg(to_jsonb(r) order by profile_id,rating_track) into tracks_before from public.fieldrush_player_rating_tracks r
    where profile_id in(select profile_id from public.open_queue_bookings where game_id=early_game);
  perform pg_temp.window_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,%L::jsonb)',outsider,early_game,gen_random_uuid(),
    jsonb_build_object('action','START','participant_ids',participants)::text),'not assigned to you');
  result:=public.referee_season_zero_action(referee_id,early_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
  started:=(result->>'started_at')::timestamptz;
  perform pg_temp.window_expect(started< (schedule_before->>'starts_at')::timestamptz,'assigned referee starts before advertised kickoff');
  perform pg_temp.window_expect((select duration_seconds=3600 and status='RUNNING' and started_at=started from public.open_queue_clock_states where game_id=early_game),'full agreed duration begins at actual kickoff');
  perform pg_temp.window_expect((select jsonb_build_object('starts_at',starts_at,'ends_at',ends_at,'season_id',season_id,'price_fils',price_fils)=schedule_before
    from public.open_queue_games where id=early_game),'scheduled dates, price and season unchanged');
  perform pg_temp.window_expect((select to_jsonb(t)=terms_before from public.match_reliability_terms t where open_queue_game_id=early_game),'saved paid refund, cancellation, attendance and reminder policy unchanged');
  perform pg_temp.window_expect((select jsonb_agg(jsonb_build_object('id',id,'amount_paid_fils',amount_paid_fils,'base_amount_fils',base_amount_fils,
    'refund_amount_fils',refund_amount_fils,'payment_status',payment_status,'reliability_deposit_status',reliability_deposit_status) order by id)=money_before
    from public.open_queue_bookings where game_id=early_game),'paid booking/refund/deposit values unchanged');
  perform pg_temp.window_expect((select jsonb_agg(to_jsonb(r) order by profile_id,rating_track)=tracks_before from public.fieldrush_player_rating_tracks r
    where profile_id in(select profile_id from public.open_queue_bookings where game_id=early_game)),'start does not change SR, counted games or visibility');
  perform pg_temp.window_expect((select count(*)=1 from public.open_queue_events where game_id=early_game and event_type='MATCH_STARTED' and occurred_at=started),'actual kickoff recorded separately');
  perform pg_temp.window_expect(public.finalize_match_attendance_internal('SOLO',early_game,referee_id)=0,'early actual match does not finalize attendance before actual grace');
  perform pg_temp.window_expect(not exists(select 1 from public.current_match_attendance_records where open_queue_game_id=early_game and outcome='NO_SHOW'),'no early no-shows');
  perform pg_temp.window_reject(format('select public.referee_finish_season_zero_match(%L,%L,%L,1)',referee_id,early_game,gen_random_uuid()),'agreed playing duration');
  select profile_id into player from public.open_queue_bookings where game_id=early_game order by id limit 1;
  update public.open_queue_clock_states set status='ENDED',started_at=null where game_id=early_game;
  perform pg_temp.window_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',referee_id,early_game,player),'from kickoff');
  perform pg_temp.window_expect(not exists(select 1 from public.match_verified_injuries where open_queue_game_id=early_game),'invalid early injury transaction rolls back');
  update public.open_queue_clock_states set status='PAUSED',started_at=null,accumulated_seconds=120 where game_id=early_game;
  injury:=public.referee_record_verified_injury(referee_id,'SOLO',early_game,player,true,false,true,'Verified injury during the actual early kickoff test.');
  period:=(injury->>'shorthanded_period_id')::uuid;
  perform pg_temp.window_expect(period is not null and exists(select 1 from public.match_verified_injuries where id=(injury->>'injury_id')::uuid and open_queue_game_id=early_game),'actual early S0 injury and shorthanded evidence persist atomically');
  perform pg_temp.window_expect((select started_match_second=120 from public.match_shorthanded_periods where id=period),'paused early injury uses actual playing time');
  perform pg_temp.window_expect((select to_jsonb(t)=terms_before from public.match_reliability_terms t where open_queue_game_id=early_game),'early S0 injury preserves original paid policy terms');

  -- A delayed game with its scheduled no-show and end cutoffs long past still
  -- accepts genuine check-ins and starts; a later participant uses actual grace.
  late_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())-interval '23 hours');
  perform public.referee_assign_season_zero_teams(admin_id,late_game,gen_random_uuid());
  select profile_id into last_player from public.open_queue_bookings where game_id=late_game and role='ATT' order by id limit 1;
  for player in select profile_id from public.open_queue_bookings where game_id=late_game and profile_id<>last_player loop
    perform public.referee_check_in_player_with_timing(admin_id,'SOLO',late_game,player,'EARLY');
  end loop;
  select profile_id,check_in_revision into player,checkin_revision from public.current_match_attendance_records
    where open_queue_game_id=late_game and profile_id<>last_player order by id limit 1;
  perform public.referee_remove_player_check_in(admin_id,'SOLO',late_game,player,checkin_revision,'OPERATOR_ERROR',null);
  perform pg_temp.window_expect((select checked_in_at is null from public.current_match_attendance_records where open_queue_game_id=late_game and profile_id=player),'delayed pre-kickoff check-in can still be corrected');
  perform public.referee_check_in_player_with_timing(admin_id,'SOLO',late_game,player,'EARLY');
  perform pg_temp.window_expect(public.finalize_match_attendance_internal('SOLO',late_game,admin_id)=0,'scheduled no-show cutoff cannot finalize delayed unstarted match');
  perform public.detect_due_match_resolution_cases();
  perform pg_temp.window_expect((select operational_state='NORMAL' from public.open_queue_games where id=late_game),'scheduled end does not lock valid delayed kickoff');
  select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=late_game and profile_id<>last_player;
  result:=public.referee_season_zero_action(admin_id,late_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
  perform public.referee_check_in_player_with_timing(admin_id,'SOLO',late_game,last_player,'AFTER_KICKOFF');
  perform pg_temp.window_expect((select checked_in_at is not null and outcome is null from public.current_match_attendance_records where open_queue_game_id=late_game and profile_id=last_player),'late actual arrival remains checkable after original scheduled deadline');
  perform pg_temp.window_expect((select played=false from public.open_queue_bookings where game_id=late_game and profile_id=last_player),'check-in does not invent actual participation');
  perform pg_temp.window_expect(fieldrush_rating_private.solo_attendance_cutoff(late_game,null)=(result->>'started_at')::timestamptz+interval '10 minutes','saved grace uses actual kickoff');
  perform public.detect_due_match_resolution_cases();
  perform pg_temp.window_expect((select operational_state='NORMAL' from public.open_queue_games where id=late_game),'fresh delayed live match remains unlocked');
  perform pg_temp.window_expect(not fieldrush_rating_private.solo_resolution_is_due(late_game,clock_timestamp()+interval '89 minutes'),'missing-result timer waits for actual play plus grace');
  perform pg_temp.window_expect(fieldrush_rating_private.solo_resolution_is_due(late_game,clock_timestamp()+interval '91 minutes'),'missing-result timer follows actual play');
  perform public.referee_season_zero_action(admin_id,late_game,gen_random_uuid(),1,'{"action":"PAUSE"}');
  perform pg_temp.window_expect(not fieldrush_rating_private.solo_resolution_is_due(late_game,clock_timestamp()+interval '3 days'),'paused wall time does not consume playing duration');

  -- Exact helper boundaries are deterministic; real RPCs use server wall time.
  before_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())+interval '25 hours');
  perform pg_temp.window_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,before_game,gen_random_uuid()),'within 24 hours');
  select profile_id into player from public.open_queue_bookings where game_id=before_game limit 1;
  perform pg_temp.window_reject(format('select public.referee_check_in_player(%L,''SOLO'',%L,%L)',admin_id,before_game,player),'within 24 hours');
  perform pg_temp.window_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,''{"action":"START","participant_ids":[]}'')',admin_id,before_game,gen_random_uuid()),'within 24 hours');
  after_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())-interval '25 hours');
  perform pg_temp.window_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,''{"action":"START","participant_ids":[]}'')',admin_id,after_game,gen_random_uuid()),'within 24 hours');
  select starts_at into kickoff from public.open_queue_games where id=after_game;
  perform pg_temp.window_expect(not fieldrush_rating_private.solo_resolution_is_due(after_game,kickoff+interval '24 hours'),'no review lock at inclusive latest boundary');
  perform pg_temp.window_expect(fieldrush_rating_private.solo_resolution_is_due(after_game,kickoff+interval '24 hours 1 microsecond'),'review discovery after inclusive latest boundary');
  perform public.detect_due_match_resolution_cases();
  perform pg_temp.window_expect((select operational_state='NO_DATA' from public.open_queue_games where id=after_game),'expired unstarted match enters review');
  perform pg_temp.window_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,''{"action":"START","participant_ids":[]}'')',admin_id,after_game,gen_random_uuid()),'organizer review');

  locked_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())+interval '22 hours');
  update public.open_queue_games set operational_state='UNDER_REVIEW' where id=locked_game;
  perform pg_temp.window_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,''{"action":"START","participant_ids":[]}'')',admin_id,locked_game,gen_random_uuid()),'organizer review');
  perform public.detect_due_match_resolution_cases();
  perform pg_temp.window_expect((select operational_state='UNDER_REVIEW' from public.open_queue_games where id=locked_game),'existing review remains locked');

  -- The actual-clock safety watchdog remains the three-hour boundary.
  update public.open_queue_clock_states set accumulated_seconds=10800,started_at=null,status='PAUSED' where game_id=early_game;
  perform public.auto_stop_overdue_open_queue_clocks();
  perform pg_temp.window_expect((select status='ENDED' and accumulated_seconds=10800 from public.open_queue_clock_states where game_id=early_game),'three-hour actual-clock watchdog preserved');
  perform pg_temp.window_expect((select lifecycle='REVIEW' and rating_status='pending_review' from fieldrush_rating_private.season_zero_matches where game_id=early_game),'watchdog holds unresolved SR for review');

  perform public.admin_set_season_zero_policy(admin_id,false,'Disposable legacy start-window preservation check.');
  legacy_game:=pg_temp.window_game(date_trunc('minute',clock_timestamp())+interval '4 hours');
  perform pg_temp.window_reject(format('select public.referee_start_open_queue_game(%L,(select array_agg(profile_id) from public.open_queue_bookings where game_id=%L),3600)',legacy_game,legacy_game),'before its scheduled kickoff');
  perform pg_temp.window_expect(not has_function_privilege('anon','fieldrush_rating_private.solo_start_window_allows(timestamptz,timestamptz)','EXECUTE')
    and not has_function_privilege('authenticated','fieldrush_rating_private.solo_start_window_allows(timestamptz,timestamptz)','EXECUTE'),'window helper is private');
  perform pg_temp.window_expect(not has_function_privilege('authenticated','public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)','EXECUTE')
    and has_function_privilege('service_role','public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)','EXECUTE'),'start RPC retains service-only authorization');
end;
$$;
select count(*) as checks_passed from start_window_checks;
