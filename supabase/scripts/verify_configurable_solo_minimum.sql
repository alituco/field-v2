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

-- Disposable full-schema behavioral verification. Caller owns BEGIN/ROLLBACK.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table minimum_checks(label text);
create function pg_temp.minimum_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Configurable minimum: %',label; end if;
  insert into minimum_checks values(label); end $$;
create function pg_temp.minimum_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
  perform pg_temp.minimum_expect(rejected,'rejected: '||expected);
end $$;
create sequence pg_temp.minimum_person;
create sequence pg_temp.minimum_game_number;
create function pg_temp.minimum_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.minimum_person'); previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555888'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Minimum','last_name','Player',
    'username','minimum_'||n,'date_of_birth','2000-01-01','email','minimum_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  return player;
end $$;
create function pg_temp.minimum_game(n integer,minimum integer,version text default 's0-configurable-v1') returns uuid language plpgsql as $$
declare game uuid; player uuid; i integer; kickoff timestamptz:=date_trunc('minute',now())-interval '1 minute'*nextval('pg_temp.minimum_game_number');
begin
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,minimum_players,participation_rules_version)
    values('OPEN','Isolated minimum verification',kickoff,kickoff+interval '1 hour',0,minimum,version) returning id into game;
  for i in 1..n loop
    player:=pg_temp.minimum_player();
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,player,case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
  end loop;
  return game;
end $$;
create function pg_temp.minimum_input(a integer,b integer,minimum integer default 2,version text default 's0-configurable-v1')
returns jsonb language sql as $$
  select jsonb_build_object('policy_id','field-sr-season0-v2','status','completed','winner','A',
    'scheduled_seconds',3600,'played_seconds',3600,'events','[]'::jsonb,
    'participation_rules_version',version,'minimum_players',minimum,'roster',
    (select jsonb_agg(jsonb_build_object('id',side||i,'team',side,'initial_active',true,'sr_before',1000,'games_before',10))
      from (select 'A' side,generate_series(1,a) i union all select 'B',generate_series(1,b)) p));
$$;
-- Inject the otherwise concurrent activation change between the generator's
-- optimistic preflight and its actual policy-pinning INSERT. This hook exists
-- only in the caller's rollback transaction and cannot reach a hosted service.
create function pg_temp.minimum_change_activation_before_insert() returns trigger language plpgsql as $$
begin
  if current_setting('fieldrush.test_schedule_activation_race',true)='on' then
    update fieldrush_rating_private.season_zero_activation set enabled=false where singleton;
  end if;
  return new;
end $$;
create trigger a_minimum_simulate_activation_change before insert on public.open_queue_games
  for each row execute function pg_temp.minimum_change_activation_before_insert();
do $$
declare admin_id uuid:=pg_temp.minimum_player(); outsider uuid:=pg_temp.minimum_player(); game uuid; n integer; response jsonb;
  participants jsonb; player uuid; second_player uuid; first_player uuid; normalized jsonb; calculation jsonb; input jsonb;
  events jsonb; snapshot jsonb; party uuid; field uuid; created uuid; schedule uuid; schedule_data jsonb;
  schedule_day date:=(now() at time zone 'America/Phoenix')::date+1; generated uuid;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Minimum admin','+15558880001','admin',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Isolated policy evidence for configurable minimum verification.',now(),admin_id
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Isolated configurable minimum verification only.');
  response:=public.admin_save_field(admin_id,null,jsonb_build_object('name','Minimum verification field','address','1 Disposable Test Street',
    'city','Phoenix','state','AZ','country_code','US','latitude',33.4,'longitude',-111.9,'market_city_id','phoenix','is_active',true));
  field:=(response->>'id')::uuid;
  created:=public.admin_create_open_queue_game_with_minimum(admin_id,field,date_trunc('minute',now())+interval '7 days',0,'18+',60,1,5,1,2,4,2);
  perform pg_temp.minimum_expect((select minimum_players=2 and capacity=14 and participation_rules_version='s0-configurable-v1' from public.open_queue_games where id=created),'real create RPC saves minimum and keeps capacity');
  perform pg_temp.minimum_reject(format('select public.admin_create_open_queue_game_with_minimum(%L,%L,now()+interval ''8 days'',0,''18+'',60,1,5,1,2,4,1)',admin_id,field),'from 2 to 14');
  perform pg_temp.minimum_reject(format('select public.admin_create_open_queue_game_with_minimum(%L,%L,now()+interval ''8 days'',0,''18+'',60,1,5,1,2,4,15)',admin_id,field),'from 2 to 14');
  created:=public.admin_create_open_queue_game(admin_id,field,date_trunc('minute',now())+interval '8 days',0,'18+',60,1,5,1,2,4);
  perform pg_temp.minimum_expect((select minimum_players=10 and participation_rules_version='s0-configurable-v1' from public.open_queue_games where id=created),'old create RPC remains compatible with new default');
  response:=public.admin_save_game_schedule(admin_id,null,jsonb_build_object('name','Minimum recurring verification','field_id',field,
    'weekdays',jsonb_build_array(1,2,3,4,5,6,7),'kickoff_time','20:30','starts_on',schedule_day,'ends_on',schedule_day,
    'duration_minutes',60,'booking_window_days',28,'price_fils',0,'age_label','18+','is_active',true,'minimum_players',3));
  schedule:=(response->>'id')::uuid;
  select game_id into generated from public.game_schedule_occurrences where schedule_id=schedule and match_date=schedule_day;
  perform pg_temp.minimum_expect((select minimum_players=3 and participation_rules_version='s0-configurable-v1' from public.open_queue_games where id=generated),'schedule generation saves minimum and rules');
  perform public.admin_save_game_schedule(admin_id,schedule,jsonb_build_object('minimum_players',2,'ends_on',schedule_day+1));
  perform pg_temp.minimum_expect((select minimum_players=3 from public.open_queue_games where id=generated),'schedule change preserves materialized game');
  perform pg_temp.minimum_expect(exists(select 1 from public.game_schedule_occurrences o join public.open_queue_games g on g.id=o.game_id
    where o.schedule_id=schedule and o.match_date=schedule_day+1 and g.minimum_players=2 and g.participation_rules_version='s0-configurable-v1'),'future occurrence gets edited minimum');
  insert into public.game_schedules(name,field_id,weekdays,kickoff_time,duration_minutes,starts_on,ends_on,booking_window_days,price_fils,age_label,is_active,created_by,participation_rules_version)
    values('Existing standard schedule',field,array[1,2,3,4,5,6,7],'18:00',60,schedule_day,schedule_day,28,0,'18+',false,admin_id,'s0-standard-v1') returning id into schedule;
  perform public.admin_save_game_schedule(admin_id,schedule,jsonb_build_object('is_active',true));
  perform pg_temp.minimum_expect(exists(select 1 from public.game_schedule_occurrences o join public.open_queue_games g on g.id=o.game_id
    where o.schedule_id=schedule and g.participation_rules_version='s0-standard-v1' and g.minimum_players=10),'existing schedule generated games keep standard rules');
  perform pg_temp.minimum_reject(format('select public.admin_save_game_schedule(%L,%L,''{"minimum_players":2}''::jsonb)',admin_id,schedule),'Create a new schedule');
  foreach n in array array[2,3,10,14] loop
    game:=pg_temp.minimum_game(n,n);
    perform pg_temp.minimum_expect((select minimum_players=n and participation_rules_version='s0-configurable-v1' from public.open_queue_games where id=game),'advertised minimum '||n);
    response:=public.admin_lock_open_queue_teams(admin_id,game);
    perform pg_temp.minimum_expect(response->>'teamsAssignedAt' is not null,'admin lock partial/full '||n);
    perform pg_temp.minimum_expect((select min(c)>=1 and max(c)<=7 and max(c)-min(c)<=1 from
      (select count(*) c from public.open_queue_bookings where game_id=game and status='CONFIRMED' group by team) counts),'balanced odd/even assignment '||n);
    perform pg_temp.minimum_expect(not exists(select 1 from public.open_queue_bookings where game_id=game group by team,role
      having count(*)>case role when 'GK' then 1 when 'DEF' then 2 when 'MID' then 0 else 4 end),'saved role caps '||n);
    perform public.ensure_match_attendance_records('SOLO',game);
    update public.match_attendance_records set checked_in_at=clock_timestamp(),check_in_timing='EARLY' where open_queue_game_id=game;
    if n in (2,3) then
      select profile_id into first_player from public.open_queue_bookings where game_id=game and role='GK' and team='WHITE';
      select profile_id into second_player from public.open_queue_bookings where game_id=game and role='GK' and team='BLACK';
      events:=jsonb_build_array(jsonb_build_object('profile_id',first_player,'to_team','BLACK','consented',false),
        jsonb_build_object('profile_id',second_player,'to_team','WHITE','consented',true));
      perform pg_temp.minimum_reject(format('select public.referee_rebalance_season_zero_match(%L,%L,%L,%L::jsonb,''Isolated consent regression.'')',
        admin_id,game,gen_random_uuid(),events),'must agree');
      events:=jsonb_build_array(jsonb_build_object('profile_id',first_player,'to_team','BLACK','consented',true),
        jsonb_build_object('profile_id',second_player,'to_team','WHITE','consented',true));
      response:=public.referee_rebalance_season_zero_match(admin_id,game,gen_random_uuid(),events,'Isolated consented small-team keeper swap.');
      perform pg_temp.minimum_expect(response->>'action'='REBALANCE' and
        (select team='BLACK' from public.open_queue_bookings where game_id=game and profile_id=first_player) and
        (select team='WHITE' from public.open_queue_bookings where game_id=game and profile_id=second_player),'actual consented rebalance size '||n);
    end if;
    select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=game;
    response:=public.referee_season_zero_action(admin_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
    perform pg_temp.minimum_expect(response->>'minimum_players'=n::text and response->>'participation_rules_version'='s0-configurable-v1','frozen kickoff rules '||n);
    perform pg_temp.minimum_reject(format('update public.open_queue_games set minimum_players=%s where id=%L',case when n=2 then 3 else 2 end,game),'minimum is locked');
    perform pg_temp.minimum_reject(format('update fieldrush_rating_private.season_zero_matches set minimum_players=%s where game_id=%L',case when n=2 then 3 else 2 end,game),'kickoff snapshot is immutable');
    if n=2 then
      select profile_id into player from public.open_queue_bookings where game_id=game and team='WHITE';
      response:=public.referee_season_zero_action(admin_id,game,gen_random_uuid(),(response->>'revision')::integer,
        jsonb_build_object('action','EXCUSED_LEAVE','profile_id',player,'note','Verified injury for minimum pause test.'));
      perform pg_temp.minimum_expect((select status='PAUSED' from public.open_queue_clock_states where game_id=game),'one active player pauses 1v1');
      perform pg_temp.minimum_expect(response->>'rating_status'='pending_review','pause does not unrank game');
      perform pg_temp.minimum_reject(format('select public.referee_season_zero_action(%L,%L,%L,%s,%L::jsonb)',admin_id,game,gen_random_uuid(),
        (response->>'revision')::integer,jsonb_build_object('action','RESUME')),'saved minimum');
      response:=public.referee_season_zero_action(admin_id,game,gen_random_uuid(),(response->>'revision')::integer,jsonb_build_object('action','RETURN','profile_id',player));
      response:=public.referee_season_zero_action(admin_id,game,gen_random_uuid(),(response->>'revision')::integer,jsonb_build_object('action','RESUME'));
      perform pg_temp.minimum_expect((select status='RUNNING' from public.open_queue_clock_states where game_id=game),'return allows minimum resume');
      -- A real completed 1v1 settles and replay retains the frozen rule snapshot.
      update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=game;
      response:=public.referee_finish_season_zero_match(admin_id,game,gen_random_uuid(),(response->>'revision')::integer);
      perform pg_temp.minimum_expect(response->>'settlement_status'='RATED','completed 1v1 is rated');
      select input_snapshot into snapshot from fieldrush_rating_private.season_zero_settlement_revisions where game_id=game order by id desc limit 1;
      perform pg_temp.minimum_expect(snapshot->>'minimum_players'='2' and snapshot->>'participation_rules_version'='s0-configurable-v1','settlement replay input pins rules');
      perform pg_temp.minimum_expect((select count(*)=2 from public.player_rating_events where source_id=game and calculation_version='field-sr-season0-v2'),'both 1v1 appearance events settle');
    elsif n=14 then
      select profile_id into player from public.open_queue_bookings where game_id=game and team='WHITE' limit 1;
      response:=public.referee_season_zero_action(admin_id,game,gen_random_uuid(),(response->>'revision')::integer,
        jsonb_build_object('action','EXCUSED_LEAVE','profile_id',player,'note','Verified injury below advertised fourteen.'));
      perform pg_temp.minimum_expect((select status='PAUSED' from public.open_queue_clock_states where game_id=game),'minimum14 pauses at13');
    end if;
  end loop;
  game:=pg_temp.minimum_game(2,3);
  perform pg_temp.minimum_reject(format('select public.admin_lock_open_queue_teams(%L,%L)',admin_id,game),'saved minimum');
  perform pg_temp.minimum_reject(format('select public.admin_lock_open_queue_teams(%L,%L)',outsider,game),'administrator access');
  game:=pg_temp.minimum_game(2,2,'s0-standard-v1');
  perform pg_temp.minimum_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'ten to fourteen');
  game:=pg_temp.minimum_game(10,10,'s0-standard-v1');
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=clock_timestamp(),check_in_timing='EARLY' where open_queue_game_id=game;
  select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=game;
  perform public.referee_season_zero_action(admin_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
  input:=fieldrush_rating_private.season_zero_input(game);
  perform pg_temp.minimum_expect(not input ? 'participation_rules_version' and not input ? 'minimum_players','standard replay input shape stays unchanged');
  -- Two keepers in one accepted party cannot be silently split or assigned to
  -- one side beyond its keeper cap, even though the total minimum is satisfied.
  game:=pg_temp.minimum_game(2,2);
  select min(profile_id::text)::uuid,max(profile_id::text)::uuid into first_player,second_player from public.open_queue_bookings where game_id=game;
  insert into public.open_queue_parties(game_id,owner_profile_id) values(game,first_player) returning id into party;
  insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
    values(party,game,first_player,'ACCEPTED',first_player,now(),now()),(party,game,second_player,'ACCEPTED',first_player,now(),now());
  perform pg_temp.minimum_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'roles and accepted parties');

  foreach n in array array[2,3,10,14] loop
    input:=pg_temp.minimum_input(n/2,n-n/2,n);
    normalized:=fieldrush_rating_private.normalize_season_zero_sr(input);
    calculation:=fieldrush_rating_private.calculate_season_zero_sr(normalized->'core');
    perform pg_temp.minimum_expect(calculation->>'settlement'='RATED' and (select count(*)=n from jsonb_object_keys(calculation->'players')),'rated calculator size '||n);
  end loop;
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',pg_temp.minimum_input(1,1,3)),'saved total minimum');
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',pg_temp.minimum_input(2,0,2)),'saved total minimum');
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',pg_temp.minimum_input(1,1,2,'s0-standard-v1')),'five to seven');
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',pg_temp.minimum_input(1,1,2,'unknown')),'Unknown participation');
  input:=pg_temp.minimum_input(7,1,2);
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(input);
  calculation:=fieldrush_rating_private.calculate_season_zero_sr(normalized->'core');
  perform pg_temp.minimum_expect((calculation->>'effective_difference_a')::numeric=600,'new version accepts +6 advantage');
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.calculate_season_zero_sr(%L::jsonb)',(normalized->'core')-'participation_rules_version'-'minimum_players'),'5-to-7');

  -- Seven versus five after halftime: equal established SR, no margin bonus.
  input:=pg_temp.minimum_input(7,7,10);
  events:=jsonb_build_array(
    jsonb_build_object('id','leave1','type','EXCUSED_LEAVE','second',1800,'recorded_at','2026-10-20T02:30:00Z','player_id','B6'),
    jsonb_build_object('id','leave2','type','EXCUSED_LEAVE','second',1800,'recorded_at','2026-10-20T02:30:00Z','player_id','B7'));
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(input||jsonb_build_object('events',events));
  calculation:=fieldrush_rating_private.calculate_season_zero_sr(normalized->'core');
  perform pg_temp.minimum_expect(calculation#>>'{players,A1,delta}'='14','7v5 excused winners +14');
  perform pg_temp.minimum_expect(calculation#>>'{players,B1,delta}'='-8','7v5 remaining losers -8');
  perform pg_temp.minimum_expect(calculation#>>'{players,B6,delta}'='-14','7v5 excused departing player -14');
  perform pg_temp.minimum_expect((calculation#>>'{players,B1,q}')::numeric=0.5,'half-match loss protection');
  events:=replace(events::text,'EXCUSED_LEAVE','QUIT')::jsonb;
  normalized:=fieldrush_rating_private.normalize_season_zero_sr(input||jsonb_build_object('events',events));
  calculation:=fieldrush_rating_private.calculate_season_zero_sr(normalized->'core');
  perform pg_temp.minimum_expect(calculation#>>'{players,A1,delta}'='20' and calculation#>>'{players,B1,delta}'='-20' and calculation#>>'{players,B6,delta}'='-20','quit retains contribution, no numerical forgiveness');
  input:=pg_temp.minimum_input(7,7,14)||jsonb_build_object('events',replace(events::text,'QUIT','EXCUSED_LEAVE')::jsonb);
  perform pg_temp.minimum_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',input),'saved total minimum');
  input:=pg_temp.minimum_input(5,5,10,'s0-standard-v1');
  perform pg_temp.minimum_expect(fieldrush_rating_private.normalize_season_zero_sr(input)=fieldrush_rating_private.normalize_season_zero_sr_standard(input),'standard replay normalizer byte-for-byte unchanged');
  perform pg_temp.minimum_expect(not has_function_privilege('authenticated','public.admin_create_open_queue_game_with_minimum(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer,integer)','EXECUTE')
    and has_function_privilege('service_role','public.admin_create_open_queue_game_with_minimum(uuid,uuid,timestamptz,integer,text,integer,integer,integer,integer,integer,integer,integer)','EXECUTE'),'creation RPC restricted to service role');
  perform set_config('fieldrush.test_schedule_activation_race','on',true);
  response:=public.admin_save_game_schedule(admin_id,null,jsonb_build_object('name','Activation changed during generation','field_id',field,
    'weekdays',jsonb_build_array(1,2,3,4,5,6,7),'kickoff_time','13:00','starts_on',schedule_day,'ends_on',schedule_day,
    'duration_minutes',60,'booking_window_days',28,'price_fils',0,'age_label','18+','is_active',true,'minimum_players',2));
  perform set_config('fieldrush.test_schedule_activation_race','off',true);
  schedule:=(response->>'id')::uuid;
  perform pg_temp.minimum_expect(exists(select 1 from public.game_schedule_occurrences where schedule_id=schedule and status='CONFLICT'
    and error_message like 'Enable Season 0%') and not exists(select 1 from public.game_schedule_occurrences where schedule_id=schedule and game_id is not null),
    'activation change between preflight and policy pinning cannot create a legacy configurable game');
  perform pg_temp.minimum_expect(not exists(select 1 from public.open_queue_games where field_id=field and starts_at=(schedule_day+time '13:00') at time zone 'America/Phoenix'),
    'failed activation-race insert rolls back game and audit atomically');
  perform public.admin_set_season_zero_policy(admin_id,false,'Isolated minimum activation rollback verification.');
  perform pg_temp.minimum_reject(format('select public.admin_create_open_queue_game_with_minimum(%L,%L,date_trunc(''minute'',now())+interval ''9 days'',0,''18+'',60,1,5,1,2,4,2)',admin_id,field),'Enable the Season 0');
  response:=public.admin_save_game_schedule(admin_id,null,jsonb_build_object('name','Policy off configurable schedule','field_id',field,
    'weekdays',jsonb_build_array(1,2,3,4,5,6,7),'kickoff_time','15:00','starts_on',schedule_day,'ends_on',schedule_day,
    'duration_minutes',60,'booking_window_days',28,'price_fils',0,'age_label','18+','is_active',true,'minimum_players',2));
  schedule:=(response->>'id')::uuid;
  perform pg_temp.minimum_expect(exists(select 1 from public.game_schedule_occurrences where schedule_id=schedule and status='CONFLICT'
    and error_message like 'Enable Season 0%') and not exists(select 1 from public.game_schedule_occurrences where schedule_id=schedule and game_id is not null),'policy-off generation exposes conflict instead of ignoring advertised minimum');
end $$;
select count(*) as configurable_minimum_checks from minimum_checks;
