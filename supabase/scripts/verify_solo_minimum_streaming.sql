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

-- Complete application schema, caller-owned rollback transaction; no provider
-- request is made. Exercise actual booking, assignment and pairing functions.
select set_config('request.jwt.claim.role','service_role',true);
create temporary table stream_minimum_checks(label text);
create function pg_temp.stream_minimum_expect(ok boolean,label text)
returns void language plpgsql as $$begin
  if ok is distinct from true then raise exception 'Minimum stream: %',label; end if;
  insert into stream_minimum_checks values(label);
end$$;
create sequence pg_temp.stream_minimum_person;
create sequence pg_temp.stream_minimum_game_number;
create function pg_temp.stream_minimum_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.stream_minimum_person'); previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555888'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Stream','last_name','Regression',
    'username','stream_min_'||n,'date_of_birth','2000-01-01','email','stream_min_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  return player;
end$$;
create function pg_temp.stream_minimum_game(n integer,minimum integer,version text default 's0-configurable-v1')
returns uuid language plpgsql as $$
declare game uuid:=gen_random_uuid(); player uuid; i integer;
  kickoff timestamptz:=date_trunc('minute',now())+interval '1 hour'+interval '1 minute'*nextval('pg_temp.stream_minimum_game_number');
begin
  insert into public.open_queue_games(id,venue,starts_at,ends_at,price_fils,minimum_players,participation_rules_version)
    values(game,'Disposable stream '||game,kickoff,kickoff+interval '1 hour',0,minimum,version);
  for i in 1..n loop
    player:=pg_temp.stream_minimum_player();
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,player,case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
  end loop;
  return game;
end$$;
do $$
declare admin_id uuid:=pg_temp.stream_minimum_player(); game uuid; code text:=repeat('a',64); token text:=repeat('b',64);
  paired jsonb; players uuid[]; interrupted boolean:=false; expected timestamptz;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Stream regression admin','+15558880001','admin',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  perform public.admin_set_season_zero_policy(admin_id,true,'Rollback-only stream minimum regression.');
  game:=pg_temp.stream_minimum_game(2,2);
  perform pg_temp.stream_minimum_expect(not public.solo_game_stream_ready(game),'unassigned 1v1 cannot prepare stream');
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.stream_minimum_expect(public.solo_game_stream_ready(game),'assigned 1v1 prepares before FULL');
  select starts_at into expected from public.open_queue_games where id=game;
  perform pg_temp.stream_minimum_expect(fieldrush_rating_private.solo_stream_ready(game,expected-interval '24 hours'),'exact early boundary ready');
  perform pg_temp.stream_minimum_expect(not fieldrush_rating_private.solo_stream_ready(game,expected-interval '24 hours 1 microsecond'),'before early boundary rejected');
  perform pg_temp.stream_minimum_expect(fieldrush_rating_private.solo_stream_ready(game,expected+interval '24 hours'),'exact late boundary ready');
  perform pg_temp.stream_minimum_expect(not fieldrush_rating_private.solo_stream_ready(game,expected+interval '24 hours 1 microsecond'),'after late boundary rejected');
  perform public.create_broadcast_pairing(admin_id,'SOLO',game,code);
  paired:=public.redeem_broadcast_pairing(code,token,'Disposable camera');
  update public.broadcast_devices set obs_connected=true,last_seen_at=clock_timestamp(),status='READY' where device_key=paired->>'deviceKey';
  insert into public.open_queue_broadcasts(game_id,status) values(game,'READY');
  perform pg_temp.stream_minimum_expect(public.reserve_broadcast_start(admin_id,'SOLO',game)=paired->>'deviceKey','actual reservation permits 1v1');
  perform pg_temp.stream_minimum_expect((select count(*)=1 from public.broadcast_commands where open_queue_game_id=game and action='START_STREAM'),'one scoped command queued');
  -- Cancel one still-unstarted booking after queueing. The command claimant
  -- rechecks this same RPC before releasing stream credentials.
  update public.open_queue_bookings set status='CANCELLED',cancelled_at=clock_timestamp()
    where id=(select id from public.open_queue_bookings where game_id=game order by id limit 1);
  perform pg_temp.stream_minimum_expect(not public.solo_game_stream_ready(game),'queued start loses readiness after player cancellation');
  begin perform public.reserve_broadcast_start(admin_id,'SOLO',game);
  exception when others then if sqlerrm not like '%minimum%' then raise; end if; interrupted:=true; end;
  perform pg_temp.stream_minimum_expect(interrupted,'repeat reservation cannot bypass lost minimum');

  game:=pg_temp.stream_minimum_game(3,3);
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.stream_minimum_expect(public.solo_game_stream_ready(game),'odd 2v1 is ready');
  game:=pg_temp.stream_minimum_game(10,10,'s0-standard-v1');
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.stream_minimum_expect(public.solo_game_stream_ready(game),'standard S0 partial 5v5 also prepares');
  perform pg_temp.stream_minimum_expect(not public.solo_game_stream_ready(gen_random_uuid()),'unknown game is not ready');
  perform pg_temp.stream_minimum_expect(not has_function_privilege('anon','public.solo_game_stream_ready(uuid)','EXECUTE')
    and not has_function_privilege('authenticated','public.solo_game_stream_ready(uuid)','EXECUTE')
    and has_function_privilege('service_role','public.solo_game_stream_ready(uuid)','EXECUTE'),'readiness remains server-only');
end$$;
select count(*)||' full-schema stream minimum checks passed.' as result from stream_minimum_checks;
