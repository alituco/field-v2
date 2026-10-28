-- Disposable full-schema regression; the harness rolls back every row.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table goal_credit_checks(label text);
create function pg_temp.goal_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Replay goal credit: %',label; end if;
  insert into goal_credit_checks values(label);
end;
$$;
do $$
declare players uuid[]:=array[]::uuid[]; person uuid; admin_id uuid; login uuid;
  game uuid; scorer uuid; i integer; first_goal jsonb; replacement jsonb; payload jsonb;
  removed_event uuid; valid_event uuid; legacy_event uuid; saved uuid; custom_clip uuid; rejected boolean:=false;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())-interval '1 minute';
begin
  for i in 1..15 loop
    person:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(person,'15558828'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',person::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Replay','last_name','Player',
      'username','replay_goal_'||i,'date_of_birth','2000-01-01','email','replay_goal_'||i||'@example.test',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
    if i=15 then admin_id:=person; else players:=array_append(players,person); end if;
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Replay admin','+15558828015','admin',true);
  login:=gen_random_uuid();
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,login||'@replay-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
  update public.referee_profiles set auth_user_id=login,email=login||'@replay-staff.example.test' where profile_id=admin_id;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable replay goal policy.',now(),admin_id
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable replay goal verification only.');
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable replay goals',kickoff,kickoff+interval '1 hour',0,4,8) returning id into game;
  for i in 1..14 loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,players[i],case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=admin_id,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=game;
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform public.referee_season_zero_action(admin_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  select profile_id into scorer from public.open_queue_bookings where game_id=game and team='BLACK' limit 1;
  first_goal:=public.referee_mutate_solo_goal(admin_id,game,gen_random_uuid(),jsonb_build_object('action','ADD','team','BLACK','profile_id',scorer));
  removed_event:=(first_goal->>'event_id')::uuid;
  insert into public.profile_highlights(profile_id,title,duration,source_type,source_match_id,source_event_id,
    video_url,download_url,download_status,processing_status,is_public)
    values(scorer,'Earlier saved goal','0:30','SOLO',game,removed_event,
      'https://example.test/goal.m3u8','https://example.test/goal.mp4','READY','READY',true) returning id into saved;
  insert into public.profile_highlights(profile_id,title,duration,source_type,source_match_id,source_event_id,
    video_url,download_status,processing_status,is_public)
    values(scorer,'Custom match moment','0:20','SOLO',game,null,
      'https://example.test/custom.m3u8','READY','READY',true) returning id into custom_clip;
  perform public.referee_mutate_solo_goal(admin_id,game,gen_random_uuid(),jsonb_build_object(
    'action','REMOVE','goal_id',first_goal->>'goal_id','note','Misclick corrected'));
  replacement:=public.referee_mutate_solo_goal(admin_id,game,gen_random_uuid(),jsonb_build_object('action','ADD','team','BLACK','profile_id',scorer));
  valid_event:=(replacement->>'event_id')::uuid;
  perform pg_temp.goal_expect((select processing_status='FAILED' and not is_public and video_url is null
    and download_url is null from public.profile_highlights where id=saved),'saved removed goal media is revoked');
  perform pg_temp.goal_expect((select processing_status='READY' and is_public and video_url is not null
    from public.profile_highlights where id=custom_clip),'custom arbitrary clip is unchanged');
  begin
    update public.profile_highlights set processing_status='READY',video_url='https://example.test/late-worker.m3u8',
      download_url='https://example.test/late-worker.mp4' where id=saved;
  exception when check_violation then rejected:=true;
  end;
  perform pg_temp.goal_expect(rejected,'late provider response cannot restore removed goal media');
  rejected:=false;
  begin update public.profile_highlights set is_public=true where id=saved;
  exception when check_violation then rejected:=true;
  end;
  perform pg_temp.goal_expect(rejected,'visibility retry cannot republish a removed goal');
  rejected:=false;
  perform pg_temp.goal_expect((select count(*)=2 from public.open_queue_events where game_id=game and event_type='GOAL'),
    'immutable original and replacement goal audit rows are retained');
  perform pg_temp.goal_expect((select count(*)=1 from public.open_queue_goals where game_id=game),'official scorer has one goal');
  update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=game;
  perform public.referee_finish_season_zero_match(admin_id,game,gen_random_uuid(),1);
  insert into public.open_queue_broadcasts(game_id,status,active_video_id,stream_started_at,stream_stopped_at)
    values(game,'REPLAY_READY','test-video',kickoff,clock_timestamp())
    on conflict(game_id) do update set status='REPLAY_READY',active_video_id='test-video',stream_started_at=kickoff,stream_stopped_at=clock_timestamp();
  perform set_config('request.jwt.claim.sub',scorer::text,true);
  payload:=public.get_open_queue_match_detail(game);
  perform pg_temp.goal_expect((select value->>'event_type'='DISALLOWED_GOAL' and value->>'is_goal_valid'='false'
    and value->>'goal_id'=first_goal->>'goal_id' from jsonb_array_elements(payload->'events') where value->>'id'=removed_event::text),
    'removed goal is disallowed even for old clients; correction identity is preserved');
  perform pg_temp.goal_expect((select value->>'event_type'='GOAL' and value->>'is_goal_valid'='true'
    from jsonb_array_elements(payload->'events') where value->>'id'=valid_event::text),'replacement remains credited');
  perform pg_temp.goal_expect(jsonb_array_length(public.get_credited_replay_goals('SOLO',game))=1,
    'edge download source contains only official goal');
  begin
    perform public.request_profile_goal_clip('SOLO',game,removed_event,'Invalid saved goal retry');
  exception when others then
    if position('Only the scorer' in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.goal_expect(rejected,'direct save and cached saved-goal retry reject removed goal');
  payload:=public.request_profile_goal_clip('SOLO',game,valid_event,'Valid replacement goal');
  perform pg_temp.goal_expect(jsonb_array_length(payload->'goal_timestamps')=1 and
    payload->'highlight'->>'source_event_id'=valid_event::text,'valid save uses only credited alignment timestamps');
  perform pg_temp.goal_expect(not fieldrush_private.is_credited_replay_goal('SOLO',gen_random_uuid(),valid_event),
    'a valid goal cannot be credited to a different match');
  insert into public.open_queue_events(game_id,event_type,team,profile_id,minute,note)
    values(game,'GOAL','BLACK',scorer,0,'Legacy unlinked goal') returning id into legacy_event;
  perform pg_temp.goal_expect(fieldrush_private.is_credited_replay_goal('SOLO',game,legacy_event),
    'legacy goals without correction linkage retain existing credit');
  perform pg_temp.goal_expect(not has_function_privilege('authenticated','public.get_credited_replay_goals(text,uuid)','execute')
    and has_function_privilege('service_role','public.get_credited_replay_goals(text,uuid)','execute'),
    'raw credit lookup remains service only');
  perform pg_temp.goal_expect(not has_function_privilege('authenticated','public.get_open_queue_match_detail_before_goal_credit(uuid)','execute'),
    'original detail alias is not an authorization bypass');
  perform set_config('request.jwt.claim.sub','',true);
  rejected:=false;
  begin perform public.get_open_queue_match_detail(game);
  exception when others then rejected:=true;
  end;
  perform pg_temp.goal_expect(rejected,'public detail retains sign-in requirement');
end;
$$;
select count(*) as replay_goal_checks from goal_credit_checks;
