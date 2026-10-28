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

-- Disposable full-schema verification. All accounts, controls and games roll back.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create function pg_temp.bot_expect(ok boolean,message text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Staging bots: %',message; end if; end$$;
create function pg_temp.bot_reject(statement text,pattern text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if sqlerrm !~* pattern then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.bot_expect(rejected,'Expected rejection: '||pattern);
end$$;
do $$
declare actor uuid:=gen_random_uuid(); player uuid:=gen_random_uuid(); game uuid; restricted_game uuid;
  request uuid:=gen_random_uuid(); bot uuid; response jsonb; real_before jsonb; accounts_before bigint;
  phone_suffix text:=lpad(floor(random()*1000000)::bigint::text,6,'0');
begin
  perform pg_temp.bot_expect((select not enabled from fieldrush_private.staging_bot_controls where singleton),'off after fresh migration');
  insert into auth.users(id,phone,phone_confirmed_at) values(actor,'155571'||phone_suffix,now()),(player,'155572'||phone_suffix,now());
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Bottool','last_name','Admin',
    'username','botadm_'||phone_suffix,'date_of_birth','2000-01-01','email','botadmin@example.test','skill_assessment','intermediate'),
    'fieldrush-v1','fieldrush-v1');
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values(actor,'Bot Tool Admin','+155571'||phone_suffix,'admin',true);
  perform pg_temp.bind_staff_login_for_verification(actor);
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Real','last_name','Player',
    'username','botreal_'||phone_suffix,'date_of_birth','2000-01-01','email','realplayer@example.test','skill_assessment','intermediate'),
    'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  select count(*) into accounts_before from auth.users;
  perform set_config('field.match_resolution_control_plane','on',true);
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable bot-fill verification',date_trunc('minute',now())+interval '15 minutes',date_trunc('minute',now())+interval '75 minutes',0,4,8) returning id into game;
  perform set_config('field.match_resolution_control_plane','off',true);
  perform pg_temp.bot_reject(format('select public.admin_fill_open_queue_game_with_bots(%L,%L,%L)',actor,game,request),'not enabled');
  update fieldrush_private.staging_bot_controls set enabled=true where singleton;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,payment_method,amount_paid_fils,base_amount_fils)
    values(game,player,'DEF','CONFIRMED','FREE',0,0);
  select to_jsonb(b) into real_before from public.open_queue_bookings b where game_id=game and profile_id=player;
  response:=public.admin_fill_open_queue_game_with_bots(actor,game,request);
  perform pg_temp.bot_expect(response->>'createdBots'='13' and response->>'confirmedCount'='14','only empty seats filled');
  perform pg_temp.bot_expect((select to_jsonb(b)=real_before from public.open_queue_bookings b where game_id=game and profile_id=player),'real booking unchanged, including timestamps');
  perform pg_temp.bot_expect(public.admin_fill_open_queue_game_with_bots(actor,game,request)=response,'same request returns original receipt');
  perform pg_temp.bot_expect((select count(*)=accounts_before from auth.users),'no login accounts created');
  perform pg_temp.bot_expect((select status='FULL' and teams_assigned_at is null from public.open_queue_games where id=game),'filled but not team locked');
  perform pg_temp.bot_expect(not exists(select 1 from public.open_queue_bookings where game_id=game and (team is not null or played)),'no teams or attendance manufactured');
  perform pg_temp.bot_expect((select count(*)=2 from public.open_queue_bookings where game_id=game and role='GK') and
    (select count(*)=4 from public.open_queue_bookings where game_id=game and role='DEF') and
    (select count(*)=8 from public.open_queue_bookings where game_id=game and role='ATT'),'saved 1/2/4 formation respected');
  perform pg_temp.bot_expect(not exists(select 1 from fieldrush_private.staging_bot_profiles r join public.profiles p on p.id=r.profile_id
    join public.open_queue_bookings b on b.id=r.booking_id where r.game_id=game and
      (p.auth_user_id is not null or p.phone is not null or b.amount_paid_fils<>0 or b.base_amount_fils<>0 or b.reliability_deposit_fils<>0 or
        b.payment_intent_id is not null or b.provider_payment_id is not null or public.is_fieldrush_account_active(p.id))),
    'bots have no login or financial liability');
  select profile_id into bot from fieldrush_private.staging_bot_profiles where game_id=game limit 1;
  perform pg_temp.bot_expect(not fieldrush_private.is_staging_bot_fill_participant(bot,game),'scoped exception cleared after fill');
  perform public.admin_lock_open_queue_teams(actor,game);
  perform pg_temp.bot_expect((select teams_assigned_at is not null from public.open_queue_games where id=game) and
    (select count(*)=7 from public.open_queue_bookings where game_id=game and team='WHITE') and
    (select count(*)=7 from public.open_queue_bookings where game_id=game and team='BLACK'),'normal manual Lock teams still works with bots');
  perform public.referee_check_in_player_with_timing(actor,'SOLO',game,bot,'EARLY');
  perform pg_temp.bot_expect(exists(select 1 from public.match_attendance_records where open_queue_game_id=game and profile_id=bot and checked_in_at is not null),
    'normal referee check-in works with a bot');
  -- Restricted games must work without fabricating any counted appearances.
  perform public.admin_set_season_zero_policy(actor,true,'Disposable bot-fill Season 0 integration verification.');
  perform set_config('field.match_resolution_control_plane','on',true);
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,highest_division,lowest_division,defender_capacity,attacker_capacity)
    values('Disposable restricted bot game',date_trunc('minute',now())+interval '16 minutes',date_trunc('minute',now())+interval '76 minutes',0,1,1,2,10) returning id into restricted_game;
  perform set_config('field.match_resolution_control_plane','off',true);
  response:=public.admin_fill_open_queue_game_with_bots(actor,restricted_game,gen_random_uuid());
  perform pg_temp.bot_expect(response->>'createdBots'='14','restricted placement bots supported');
  perform pg_temp.bot_expect((select rating_policy_id='field-sr-season0-v2' and teams_assigned_at is null from public.open_queue_games where id=restricted_game),
    'new-policy fill does not start or assign the match');
  perform pg_temp.bot_expect(not exists(select 1 from public.fieldrush_player_rating_tracks t join fieldrush_private.staging_bot_profiles r on r.profile_id=t.profile_id
    where r.game_id=restricted_game and (t.matches_played<>0 or t.rating_initialized_at is not null)), 'no fake game history or initialization audit');
  perform public.referee_assign_season_zero_teams(actor,restricted_game,gen_random_uuid());
  perform pg_temp.bot_expect((select count(*)=14 from public.open_queue_bookings where game_id=restricted_game and team is not null),'new-policy manual assignment works');
  perform pg_temp.bot_expect(not has_function_privilege('anon','public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid)','EXECUTE') and
    not has_function_privilege('authenticated','public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid)','EXECUTE') and
    not has_table_privilege('service_role','fieldrush_private.staging_bot_controls','UPDATE'),'clients and service API cannot enable test controls');
end$$;
select 'Staging bot-fill full-schema verification passed.' as result;
rollback;
