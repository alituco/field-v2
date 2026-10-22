-- Disposable full-schema regression; every synthetic record rolls back.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create function pg_temp.clan_goal_expect(ok boolean,message text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Atomic clan goals: %',message; end if; end;
$$;
create function pg_temp.clan_goal_reject(statement text,pattern text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement; exception when others then
    if sqlerrm !~* pattern then raise; end if; rejected:=true;
  end;
  perform pg_temp.clan_goal_expect(rejected,'Expected rejected operation: '||pattern);
end;
$$;
create function pg_temp.fail_clan_goal_write() returns trigger language plpgsql as $$
begin
  if current_setting('fieldrush.test_clan_goal_failure',true)=tg_table_name then
    raise exception 'Injected clan goal failure at %',tg_table_name;
  end if;
  return new;
end;
$$;
create trigger test_clan_goal_scorer_failure before insert on public.fixture_scorers
  for each row execute function pg_temp.fail_clan_goal_write();
create trigger test_clan_goal_event_failure before insert on public.fixture_events
  for each row execute function pg_temp.fail_clan_goal_write();
create trigger test_clan_goal_score_failure before update of home_score,away_score on public.fixtures
  for each row execute function pg_temp.fail_clan_goal_write();
create trigger test_clan_goal_receipt_failure before insert on fieldrush_rating_private.clan_goal_operations
  for each row execute function pg_temp.fail_clan_goal_write();
create trigger test_clan_goal_audit_failure before insert on public.admin_audit_events
  for each row execute function pg_temp.fail_clan_goal_write();

do $$
declare
  people uuid[]:='{}'; player uuid; i integer; home_clan uuid; away_clan uuid; game uuid;
  staff uuid:=gen_random_uuid(); staff_auth uuid:=gen_random_uuid(); other_staff uuid:=gen_random_uuid(); other_auth uuid:=gen_random_uuid();
  match_day date; chosen uuid; request uuid:=gen_random_uuid(); other_request uuid:=gen_random_uuid();
  goal_input jsonb; response jsonb; again jsonb; failure text; score_before jsonb;
begin
  for i in 1..14 loop
    player:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555761'||lpad(i::text,4,'0'),now());
    perform set_config('request.jwt.claim.sub',player::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Atomic','last_name','Clan',
      'username','atomic_clan_'||i,'date_of_birth','2000-01-01','email','atomic_clan_'||i||'@example.invalid',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
    people:=array_append(people,player);
  end loop;
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values
    (staff_auth,'atomic-clan-staff@example.invalid',now(),'{"fieldrush_account_type":"staff"}'),
    (other_auth,'atomic-clan-other@example.invalid',now(),'{"fieldrush_account_type":"staff"}');
  insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,role,is_active) values
    (staff,staff_auth,'atomic-clan-staff@example.invalid','Atomic clan referee','admin',true),
    (other_staff,other_auth,'atomic-clan-other@example.invalid','Unassigned referee','referee',true);
  insert into public.clans(name,tag,created_by) values('Atomic clan home','ACH',people[1]) returning id into home_clan;
  insert into public.clans(name,tag,created_by) values('Atomic clan away','ACA',people[8]) returning id into away_clan;
  for i in 2..7 loop insert into public.clan_members(clan_id,profile_id) values(home_clan,people[i]); end loop;
  for i in 9..14 loop insert into public.clan_members(clan_id,profile_id) values(away_clan,people[i]); end loop;
  select d::date into match_day from generate_series(current_date+7,current_date+14,interval '1 day') d
    where extract(isodow from d) in (2,5) order by d limit 1;
  update public.game_payment_settings set clan_enabled=true where singleton;
  insert into public.fixtures(status,home_clan_id,away_clan_id,venue,day,time_slot,match_date,created_by)
    values('SCHEDULED',home_clan,away_clan,'Atomic clan local test',case when extract(isodow from match_day)=2 then 'TUESDAY' else 'FRIDAY' end,
      '7:00 PM - 8:00 PM',match_day,people[1]) returning id into game;
  insert into public.fixture_referee_assignments(fixture_id,referee_id,assigned_by) values(game,staff,staff);
  perform public.ensure_match_attendance_records('CLAN',game);
  perform public.initialize_fixture_reliability_roster(game);
  foreach chosen in array people loop perform public.referee_check_in_player_with_timing(staff,'CLAN',game,chosen,'EARLY'); end loop;
  perform public.referee_start_fixture_atomic(game,people,3600);
  goal_input:=jsonb_build_object('action','ADD','clan_id',home_clan,'profile_id',people[2],'assist_profile_id',people[3]);

  -- Existing pre-migration goals remain part of the official score projection.
  insert into public.fixture_scorers(fixture_id,clan_id,profile_id,minute) values(game,away_clan,people[8],1);
  update public.fixtures set away_score=1 where id=game;
  select jsonb_build_object('home',home_score,'away',away_score) into score_before from public.fixtures where id=game;
  foreach failure in array array['fixture_scorers','fixture_events','fixtures','clan_goal_operations','admin_audit_events'] loop
    perform set_config('fieldrush.test_clan_goal_failure',failure,true);
    perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,request,goal_input),'Injected clan goal failure');
    perform pg_temp.clan_goal_expect((select count(*)=1 from public.fixture_scorers where fixture_id=game),'partial scorer write after '||failure);
    perform pg_temp.clan_goal_expect(not exists(select 1 from public.fixture_events where fixture_id=game and event_type='GOAL'),'partial event after '||failure);
    perform pg_temp.clan_goal_expect(not exists(select 1 from fieldrush_rating_private.clan_goal_operations where request_id=request),'partial receipt after '||failure);
    perform pg_temp.clan_goal_expect((select jsonb_build_object('home',home_score,'away',away_score)=score_before from public.fixtures where id=game),'partial score after '||failure);
  end loop;
  perform set_config('fieldrush.test_clan_goal_failure','',true);
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',other_staff,game,request,goal_input),'not assigned');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,request,
    goal_input||jsonb_build_object('profile_id',people[8])),'not in the selected clan');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,request,
    goal_input||'{"home_score":999}'::jsonb),'Unexpected goal input');

  response:=public.referee_record_fixture_goal_atomic(staff,game,request,goal_input);
  again:=public.referee_record_fixture_goal_atomic(staff,game,request,goal_input);
  perform pg_temp.clan_goal_expect(response=again,'retry must return the identical receipt');
  perform pg_temp.clan_goal_expect(response->>'home_score'='1' and response->>'away_score'='1','include historical scorer when projecting score');
  perform pg_temp.clan_goal_expect((select count(*)=2 from public.fixture_scorers where fixture_id=game),'retry duplicated scorer');
  perform pg_temp.clan_goal_expect((select count(*)=1 from public.fixture_events where fixture_id=game and goal_id=(response->>'goal_id')::uuid),'one linked timeline event');
  perform pg_temp.clan_goal_expect((select count(*)=1 from public.admin_audit_events where action='CLAN_GOAL_RECORDED' and entity_id=game),'one audited operation');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,request,
    goal_input||jsonb_build_object('profile_id',people[4])),'another goal operation');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,gen_random_uuid(),request,goal_input),'another goal operation');
  response:=public.referee_record_fixture_goal_atomic(staff,game,other_request,goal_input);
  perform pg_temp.clan_goal_expect(response->>'home_score'='2' and response->>'away_score'='1','different request records the next actual goal');
  update public.fixtures set operational_state='UNDER_REVIEW' where id=game;
  perform pg_temp.clan_goal_expect(public.referee_record_fixture_goal_atomic(staff,game,other_request,goal_input)=response,'acknowledge existing goal during review');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,gen_random_uuid(),goal_input),'unlocked live match');
  update public.fixtures set operational_state='NORMAL' where id=game;
  perform public.referee_finish_fixture_atomic(game);
  perform pg_temp.clan_goal_expect(public.referee_record_fixture_goal_atomic(staff,game,other_request,goal_input)=response,'acknowledge existing goal after finalization');
  perform pg_temp.clan_goal_reject(format('select public.referee_record_fixture_goal_atomic(%L,%L,%L,%L)',staff,game,gen_random_uuid(),goal_input),'unlocked live match');
  perform pg_temp.clan_goal_expect((select count(*)=3 from public.fixture_scorers where fixture_id=game),'post-final retry must not add scorer');

  perform pg_temp.clan_goal_expect(not has_function_privilege('authenticated','public.referee_record_fixture_goal_atomic(uuid,uuid,uuid,jsonb)','EXECUTE'),'client cannot call service RPC');
  perform pg_temp.clan_goal_expect(not has_function_privilege('anon','public.referee_record_fixture_goal_atomic(uuid,uuid,uuid,jsonb)','EXECUTE'),'anonymous cannot call service RPC');
  perform pg_temp.clan_goal_expect(not has_table_privilege('service_role','fieldrush_rating_private.clan_goal_operations','UPDATE'),'receipts cannot be directly changed');
end;
$$;
select 'PASS: atomic clan goal rollback, exact retry receipt, historical score, final/review retries, permissions and participant validation' as result;
rollback;
