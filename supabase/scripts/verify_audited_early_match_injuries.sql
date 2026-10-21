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

-- Run inside a rollback-only transaction against the complete application
-- schema. No application function is stubbed and no real match is touched.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);

create function pg_temp.early_injury_expect(ok boolean,message text)
returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Early injury: %',message; end if; end$$;
create function pg_temp.early_injury_reject(statement text,pattern text)
returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if sqlerrm !~* pattern then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.early_injury_expect(rejected,'Expected rejection: '||pattern);
end$$;
create function pg_temp.early_injury_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid();
begin
  insert into auth.users(id,phone,phone_confirmed_at)
    values(player,'1555'||lpad(floor(random()*10000000)::bigint::text,7,'0'),now());
  -- Represent existing legacy accounts, without exercising prospective signup.
  delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=player;
  insert into public.profiles(id,auth_user_id,display_name)
    values(player,player,'Disposable injury regression') on conflict(id) do nothing;
  insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at)
    values(player,'active',now()) on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  return player;
end$$;
create function pg_temp.early_injury_game(actor uuid,kickoff timestamptz,check_in boolean default true)
returns uuid language plpgsql as $$
declare game uuid; player uuid; i integer;
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable early injury regression',kickoff,kickoff+interval '1 hour',0,4,8) returning id into game;
  for i in 1..14 loop
    player:=pg_temp.early_injury_player();
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,player,case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
    if check_in then perform public.referee_check_in_player_with_timing(actor,'SOLO',game,player,'EARLY'); end if;
  end loop;
  return game;
end$$;

do $$
declare
  actor uuid:=pg_temp.early_injury_player(); stranger uuid:=pg_temp.early_injury_player();
  game uuid; second_game uuid; season_zero_game uuid; normal_game uuid;
  injured uuid; second_player uuid; teammate uuid; player_ids uuid[]; selected_side text;
  terms_before jsonb; game_before jsonb; result jsonb; period uuid;
  saved_clock public.open_queue_clock_states%rowtype;
  saved_start public.open_queue_events%rowtype;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(actor,'Early injury admin','+15551110001','admin',true),
      (stranger,'Unassigned referee','+15551110002','referee',true);
  perform pg_temp.bind_staff_login_for_verification(actor);
  perform pg_temp.bind_staff_login_for_verification(stranger);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  -- Fresh replay publishes its first policy at migration time. Add unchanged
  -- rollback-only historical coverage for the ordinary already-started case.
  if public.resolve_reliability_policy_id(date_trunc('minute',now())-interval '5 minutes') is null then
    insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_by,published_at)
      select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
        (date_trunc('day',clock_timestamp() at time zone 'Asia/Bahrain')-interval '1 day') at time zone 'Asia/Bahrain',
        config,'Disposable unchanged policy for injury fixtures',actor,clock_timestamp()
      from public.reliability_policy_versions where state='PUBLISHED' order by effective_from desc limit 1;
  end if;
  -- Explicitly exercise legacy policy even if this verifier is used on a
  -- disposable snapshot where prospective Season 0 activation was already on.
  perform public.admin_set_season_zero_policy(actor,false,'Rollback-only legacy injury regression setup.');
  game:=pg_temp.early_injury_game(actor,date_trunc('minute',now())+interval '1 hour');
  select array_agg(profile_id order by id) into player_ids from public.open_queue_bookings where game_id=game and status='CONFIRMED';
  injured:=player_ids[1];
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',actor,game,injured),'during a live match');
  perform pg_temp.early_injury_reject(format('select public.referee_start_open_queue_game(%L,%L::uuid[],3600)',game,player_ids),'before its scheduled kickoff');
  perform public.admin_force_assign_open_queue_teams(actor,game,'Rollback-only authorized early injury regression.');
  perform pg_temp.early_injury_expect(exists(select 1 from public.admin_audit_events where entity_id=game and action='OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'),'real admin RPC creates early approval');
  -- Approval and locked teams alone do not mean kickoff has happened.
  perform pg_temp.early_injury_reject(format('select public.referee_start_shorthanded_period(%L,''SOLO'',%L,''WHITE'',''INJURY'',%L)',actor,game,injured),'during a live match');
  perform public.referee_start_open_queue_game(game,player_ids,3600);
  perform pg_temp.early_injury_expect((select status='LIVE' and starts_at>clock_timestamp() and rating_policy_id='LEGACY' from public.open_queue_games where id=game),'actual early start succeeds');
  select to_jsonb(t) into terms_before from public.match_reliability_terms t where open_queue_game_id=game;
  select to_jsonb(g) into game_before from public.open_queue_games g where id=game;
  select team into selected_side from public.open_queue_bookings where game_id=game and profile_id=injured and status='CONFIRMED';
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',stranger,game,injured),'not assigned to you');
  perform pg_temp.early_injury_reject(format('select public.referee_start_shorthanded_period(%L,''SOLO'',%L,%L,''INJURY'',%L)',actor,game,selected_side,stranger),'not on this team');

  -- A live label with an unstarted/ended clock is insufficient even with audit.
  select * into saved_clock from public.open_queue_clock_states where game_id=game;
  update public.open_queue_clock_states set status='NOT_STARTED',started_at=null where game_id=game;
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',actor,game,injured),'from kickoff');
  perform pg_temp.early_injury_expect(not exists(select 1 from public.match_verified_injuries where open_queue_game_id=game),'failed injury rolls back');
  update public.open_queue_clock_states set status='ENDED' where game_id=game;
  perform pg_temp.early_injury_reject(format('select public.referee_start_shorthanded_period(%L,''SOLO'',%L,%L,''INJURY'',%L)',actor,game,selected_side,injured),'from kickoff');
  update public.open_queue_clock_states set status=saved_clock.status,started_at=saved_clock.started_at,accumulated_seconds=saved_clock.accumulated_seconds where game_id=game;

  select * into saved_start from public.open_queue_events where game_id=game and event_type='MATCH_STARTED';
  delete from public.open_queue_events where id=saved_start.id;
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',actor,game,injured),'from kickoff');
  insert into public.open_queue_events select saved_start.*;
  -- The exception still requires the complete confirmed, checked-in lineup.
  update public.open_queue_bookings set played=false where game_id=game and profile_id=injured and status='CONFIRMED';
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',actor,game,injured),'from kickoff');
  update public.open_queue_bookings set played=true where game_id=game and profile_id=injured and status='CONFIRMED';

  result:=public.referee_record_verified_injury(actor,'SOLO',game,injured,true,false,true,'Unable to continue during an authorized early test.');
  period:=(result->>'shorthanded_period_id')::uuid;
  perform pg_temp.early_injury_expect(period is not null and result->>'idempotent'='false','injury and shorthanded period acknowledged together');
  perform pg_temp.early_injury_expect(exists(select 1 from public.match_verified_injuries where id=(result->>'injury_id')::uuid and profile_id=injured and open_queue_game_id=game),'injury persisted');
  perform pg_temp.early_injury_expect(exists(select 1 from public.match_shorthanded_periods p where id=period and open_queue_game_id=game and caused_by_profile_id=injured and reason='INJURY' and p.side=selected_side),'shorthanded period persisted');
  perform pg_temp.early_injury_expect((select count(*)=1 from public.attendance_events where event_type='INJURY_RECORDED' and detail->>'injury_id'=result->>'injury_id'),'one audit event persisted');
  result:=public.referee_record_verified_injury(actor,'SOLO',game,injured,true,false,true);
  perform pg_temp.early_injury_expect(result->>'idempotent'='true' and (select count(*)=1 from public.match_verified_injuries where open_queue_game_id=game),'injury retry stays idempotent');
  perform public.referee_end_shorthanded_period(actor,period,null,'End rollback-only period.');
  -- Injuries are commonly entered while paused; the recorded start event is
  -- the evidence even when pause correctly clears the running timestamp.
  update public.open_queue_clock_states set status='PAUSED',started_at=null,accumulated_seconds=120 where game_id=game;
  select profile_id into second_player from public.open_queue_bookings where game_id=game and status='CONFIRMED' and profile_id<>injured order by id limit 1;
  result:=public.referee_record_verified_injury(actor,'SOLO',game,second_player,true,false,true);
  perform pg_temp.early_injury_expect(result->>'match_second'='120' and result->>'shorthanded_period_id' is not null,'paused early match uses actual elapsed clock');
  perform pg_temp.early_injury_expect((select to_jsonb(t)=terms_before from public.match_reliability_terms t where open_queue_game_id=game),'scheduled reliability/refund/attendance terms unchanged');
  perform pg_temp.early_injury_expect((select to_jsonb(g)=game_before from public.open_queue_games g where id=game),'scheduled game data unchanged');

  -- A different live test fixture cannot borrow another game's approval or
  -- start event, and failed writes remain atomic. Owner-only fixture setup
  -- deliberately simulates incomplete evidence instead of bypassing a guard.
  second_game:=pg_temp.early_injury_game(actor,date_trunc('minute',now())+interval '2 hours');
  perform public.admin_lock_open_queue_teams(actor,second_game);
  select profile_id,team into teammate,selected_side from public.open_queue_bookings where game_id=second_game and status='CONFIRMED' order by id limit 1;
  update public.open_queue_bookings set played=true where game_id=second_game and status='CONFIRMED';
  insert into public.open_queue_clock_states(game_id,status,started_at) values(second_game,'RUNNING',clock_timestamp())
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.open_queue_games set status='LIVE' where id=second_game;
  insert into public.open_queue_events(game_id,event_type,occurred_at) values(second_game,'MATCH_STARTED',clock_timestamp());
  perform pg_temp.early_injury_reject(format('select public.referee_record_verified_injury(%L,''SOLO'',%L,%L,true,false,true)',actor,second_game,teammate),'from kickoff');
  perform pg_temp.early_injury_expect(not exists(select 1 from public.match_verified_injuries where open_queue_game_id=second_game),'no-audit failure is atomic');

  -- Prospective policy keeps its own bounded start window.
  perform public.admin_set_season_zero_policy(actor,true,'Rollback-only new-policy early injury isolation.');
  season_zero_game:=pg_temp.early_injury_game(actor,date_trunc('minute',now())+interval '25 hours',false);
  select array_agg(profile_id order by id) into player_ids from public.open_queue_bookings where game_id=season_zero_game and status='CONFIRMED';
  perform pg_temp.early_injury_reject(format('select public.referee_season_zero_action(%L,%L,%L,0,%L::jsonb)',actor,season_zero_game,gen_random_uuid(),jsonb_build_object('action','START','participant_ids',to_jsonb(player_ids))),'24 hours');
  perform pg_temp.early_injury_expect(not exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=season_zero_game),'new-policy early start creates no state');

  -- The ordinary after-kickoff path must continue without an admin override.
  perform public.admin_set_season_zero_policy(actor,false,'Rollback-only ordinary injury regression setup.');
  normal_game:=pg_temp.early_injury_game(actor,date_trunc('minute',now())-interval '5 minutes');
  select array_agg(profile_id order by id) into player_ids from public.open_queue_bookings where game_id=normal_game and status='CONFIRMED';
  perform public.referee_start_open_queue_game(normal_game,player_ids,3600);
  result:=public.referee_record_verified_injury(actor,'SOLO',normal_game,player_ids[1],true,false,true);
  perform pg_temp.early_injury_expect(result->>'shorthanded_period_id' is not null and not exists(
    select 1 from public.admin_audit_events where entity_id=normal_game and action='OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'),
    'ordinary live injuries still work without an early-start audit');
  perform pg_temp.early_injury_expect(not has_function_privilege('anon','public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)','EXECUTE') and
    not has_function_privilege('authenticated','public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)','EXECUTE') and
    has_function_privilege('service_role','public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)','EXECUTE'),'existing RPC permissions unchanged');
end$$;
select 'Audited early match injury full-schema verification passed.' as result;
