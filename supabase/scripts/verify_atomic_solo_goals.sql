-- Bind a synthetic staff login separately from the historical operational key.
-- This temporary fixture helper never converts the existing player Auth user.
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

-- Disposable full-schema regression. No production timing bypass or data survives.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create function pg_temp.goal_expect(ok boolean,message text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Atomic solo goals: %',message; end if; end;
$$;
create function pg_temp.goal_reject(statement text,pattern text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement; exception when others then
    if sqlerrm !~* pattern then raise; end if; rejected:=true;
  end;
  perform pg_temp.goal_expect(rejected,'Expected rejected operation: '||pattern);
end;
$$;
create function pg_temp.fail_goal_event() returns trigger language plpgsql as $$
begin if current_setting('fieldrush.test_goal_failure',true)='event' and new.event_type='GOAL' then raise exception 'Injected goal event failure'; end if; return new; end;
$$;
create trigger test_goal_event_failure before insert on public.open_queue_events for each row execute function pg_temp.fail_goal_event();
create function pg_temp.fail_goal_score() returns trigger language plpgsql as $$
begin if current_setting('fieldrush.test_goal_failure',true)='score' then raise exception 'Injected goal score failure'; end if; return new; end;
$$;
create trigger test_goal_score_failure before update of white_score,black_score on public.open_queue_games for each row execute function pg_temp.fail_goal_score();
create function pg_temp.fail_goal_audit() returns trigger language plpgsql as $$
begin if current_setting('fieldrush.test_goal_failure',true)='audit' and new.action in ('SOLO_GOAL_RECORDED','SOLO_GOAL_REMOVED') then raise exception 'Injected goal audit failure'; end if; return new; end;
$$;
create trigger test_goal_audit_failure before insert on public.admin_audit_events for each row execute function pg_temp.fail_goal_audit();

do $$
declare players uuid[]:='{}'; person uuid; admin_id uuid; other_ref uuid; game uuid; legacy uuid; policy boolean;
  i integer; scorer uuid; assist uuid; opposite uuid; role_to_use text; request uuid; removal uuid; saved_goal_id uuid; foreign_goal uuid;
  input jsonb; response jsonb; removed jsonb; original_tracks jsonb; failure text; operations_before integer; events_before integer;
  fixture_start timestamptz;
begin
  for i in 1..16 loop
    person:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(person,'15558616'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',person::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Goal','last_name','Fixture',
      'username','goal_fixture_'||i,'date_of_birth','2000-01-01','email','goal'||i||'@example.test','skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
    if i=15 then admin_id:=person; elsif i=16 then other_ref:=person; else players:=array_append(players,person); end if;
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (admin_id,'Goal Admin','+15558616015','admin',true),(other_ref,'Other Ref','+15558616016','referee',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  perform pg_temp.bind_staff_login_for_verification(other_ref);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_by,published_at)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      (date_trunc('day',clock_timestamp() at time zone 'Asia/Bahrain')-interval '1 day') at time zone 'Asia/Bahrain',
      config,'Disposable unchanged policy for goal fixtures',admin_id,clock_timestamp()
    from public.reliability_policy_versions where state='PUBLISHED' order by effective_from desc limit 1;
  perform pg_temp.goal_expect(not has_function_privilege('authenticated','public.referee_mutate_solo_goal(uuid,uuid,uuid,jsonb)','EXECUTE'),'players cannot impersonate a referee');
  perform pg_temp.goal_expect(not has_table_privilege('service_role','fieldrush_rating_private.solo_goal_operations','SELECT'),'goal receipts remain private');

  foreach policy in array array[false,true] loop
    perform public.admin_set_season_zero_policy(admin_id,policy,'Disposable atomic goal regression activation.');
    perform set_config('field.match_resolution_control_plane','on',true);
    fixture_start:=date_trunc('minute',clock_timestamp())+case when policy then interval '-29 minutes' else interval '10 minutes' end;
    insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
      values('OPEN','Atomic goal fixture',fixture_start,fixture_start+interval '1 hour',0) returning id into game;
    for i in 1..14 loop
      role_to_use:=case when i in (1,8) then 'GK' when i in (2,3,9,10) then 'DEF' else 'ATT' end;
      insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
        values(game,players[i],role_to_use,'CONFIRMED',0,0,'FREE');
    end loop;
    perform public.ensure_match_attendance_records('SOLO',game);
    update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=admin_id,
      check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=game;
    perform set_config('field.match_resolution_control_plane','off',true);
    if policy then
      perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
      perform public.referee_season_zero_action(admin_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
    else
      legacy:=game;
      perform public.admin_force_assign_open_queue_teams(admin_id,game,'Disposable complete roster early-test fixture.');
      perform public.referee_start_open_queue_game(game,players,3600);
    end if;
    select profile_id into scorer from public.open_queue_bookings where game_id=game and team='WHITE' and role='GK';
    select profile_id into assist from public.open_queue_bookings where game_id=game and team='WHITE' and role<>'GK' limit 1;
    select profile_id into opposite from public.open_queue_bookings where game_id=game and team='BLACK' limit 1;
    input:=jsonb_build_object('action','ADD','team','WHITE','profile_id',scorer,'assist_profile_id',assist);
    request:=gen_random_uuid();
    response:=public.referee_mutate_solo_goal(admin_id,game,request,input); saved_goal_id:=(response->>'goal_id')::uuid;
    perform pg_temp.goal_expect(response->>'white_score'='1' and response->>'black_score'='0','add returns canonical score');
    perform pg_temp.goal_expect(public.referee_mutate_solo_goal(admin_id,game,request,input)=response,'identical retry returns original receipt');
    perform pg_temp.goal_expect((select count(*)=1 from public.open_queue_goals where game_id=game),'retry adds no duplicate goal');
    perform pg_temp.goal_expect((select count(*)=1 from public.open_queue_events where game_id=game and event_type='GOAL' and goal_id=saved_goal_id),'goal/event linked once');
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),
      jsonb_build_object('action',null,'goal_id',saved_goal_id,'note','A null action must not remove a goal.')),'valid goal operation');
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,request,input||'{"team":"BLACK"}'),'another goal operation');
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',other_ref,game,request,input),'not assigned');
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input||jsonb_build_object('assist_profile_id',opposite)),'assist|team|active');
    if policy then
      perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),
        jsonb_build_object('action','REMOVE','goal_id',foreign_goal,'note','Cannot remove another match goal.')),'no longer recorded');
    end if;
    update public.open_queue_games set operational_state='UNDER_REVIEW' where id=game;
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input),'unlocked live');
    update public.open_queue_games set operational_state='NORMAL' where id=game;
    update public.open_queue_clock_states set status='PAUSED',started_at=null where game_id=game;
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input),'clock is running');
    update public.open_queue_clock_states set status='RUNNING',started_at=clock_timestamp() where game_id=game;
    removal:=gen_random_uuid();
    removed:=public.referee_mutate_solo_goal(admin_id,game,removal,jsonb_build_object('action','REMOVE','goal_id',saved_goal_id,'note','Recorded twice by mistake.'));
    perform pg_temp.goal_expect(removed->>'white_score'='0' and (select count(*)=0 from public.open_queue_goals where game_id=game),'undo changes score and scorer totals together');
    perform pg_temp.goal_expect(public.referee_mutate_solo_goal(admin_id,game,removal,jsonb_build_object('action','REMOVE','goal_id',saved_goal_id,'note','Recorded twice by mistake.'))=removed,'undo retry returns original receipt');
    perform pg_temp.goal_expect(public.referee_mutate_solo_goal(admin_id,game,request,input)=response,'original add retry never resurrects an undone goal');
    perform pg_temp.goal_expect((select count(*)=2 from public.open_queue_events e where e.game_id=game and e.goal_id=saved_goal_id),'original event retained with linked correction');
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),jsonb_build_object('action','REMOVE','goal_id',saved_goal_id,'note','Recorded twice by mistake.')),'no longer recorded');
    select count(*) into operations_before from fieldrush_rating_private.solo_goal_operations where game_id=game;
    select count(*) into events_before from public.open_queue_events where game_id=game;
    foreach failure in array array['event','score','audit'] loop
      perform set_config('fieldrush.test_goal_failure',failure,true);
      perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input),'Injected goal');
      perform set_config('fieldrush.test_goal_failure','',true);
      perform pg_temp.goal_expect((select count(*)=0 from public.open_queue_goals where game_id=game),'late failure rolls back goal');
      perform pg_temp.goal_expect((select count(*)=events_before from public.open_queue_events where game_id=game),'late failure rolls back timeline');
      perform pg_temp.goal_expect((select count(*)=operations_before from fieldrush_rating_private.solo_goal_operations where game_id=game),'late failure rolls back receipt');
      perform pg_temp.goal_expect((select white_score=0 and black_score=0 from public.open_queue_games where id=game),'late failure rolls back projected score');
    end loop;
    response:=public.referee_mutate_solo_goal(admin_id,game,gen_random_uuid(),input);
    if not policy then foreign_goal:=(response->>'goal_id')::uuid; end if;
    update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=game;
    if policy then
      perform public.referee_season_zero_action(admin_id,game,gen_random_uuid(),1,jsonb_build_object('action','BLUE_CARD','profile_id',scorer,'note','Actual temporary suspension at the final whistle.'));
      perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input),'actually be active');
      perform public.referee_finish_season_zero_match(admin_id,game,gen_random_uuid(),2);
      perform public.admin_resolve_season_zero_match(admin_id,game,gen_random_uuid(),3,
        '{"status":"completed","winner":"B","white_score":0,"black_score":1,"reason":"Verified corrected winner against the original match recording."}');
      perform pg_temp.goal_expect((select result='LOSS' and rating_change<0 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=game and profile_id=scorer),'v2 organizer correction still recalculates SR');
    else
      perform public.referee_complete_open_queue_game(game);
      select jsonb_agg(to_jsonb(r) order by profile_id,rating_track) into original_tracks from public.fieldrush_player_rating_tracks r where profile_id=any(players);
      perform pg_temp.goal_reject(format('select public.admin_override_match_score(%L,%L,%L,0,1,%L)',admin_id,'SOLO',game,'Verified winning side needs correction.'),'reviewed rating migration');
      perform pg_temp.goal_reject(format('select public.preserve_player_sr_for_resolution_score(%L,%L,0,1)','SOLO',game),'reviewed rating migration');
      perform pg_temp.goal_reject(format('select public.admin_override_match_score(%L,%L,%L,3,0,%L)',admin_id,'SOLO',game,'Same winner but a different rating margin factor.'),'reviewed rating migration');
      perform pg_temp.goal_expect((select white_score=1 and black_score=0 from public.open_queue_games where id=game),'blocked legacy winner flip leaves score unchanged');
      perform pg_temp.goal_expect((select jsonb_agg(to_jsonb(r) order by profile_id,rating_track)=original_tracks from public.fieldrush_player_rating_tracks r where profile_id=any(players)),'blocked flip preserves all rating state');
      perform public.admin_override_match_score(admin_id,'SOLO',game,2,0,'Verified additional goal without a changed result.');
      perform pg_temp.goal_expect((select white_score=2 and black_score=0 from public.open_queue_games where id=game),'same-result legacy correction remains supported');
    end if;
    perform pg_temp.goal_reject(format('select public.referee_mutate_solo_goal(%L,%L,%L,%L)',admin_id,game,gen_random_uuid(),input),'unlocked live');
  end loop;
  -- Any historic awarded legacy result is also protected after v2 enrollment.
  perform pg_temp.goal_reject(format('select public.admin_override_match_score(%L,%L,%L,0,2,%L)',admin_id,'SOLO',legacy,'Do not silently rewrite frozen historical awards.'),'reviewed rating migration');
end;
$$;
select 'PASS: full-schema atomic legacy/v2 goal, undo, receipt retry, rollback, authorization and correction-containment regressions' result;
rollback;
