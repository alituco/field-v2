-- Run only in the disposable full-schema migration harness, inside rollback.
-- Actual onboarding, roles, booking triggers, assignment, and START functions.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table assignment_checks(label text);
create function pg_temp.assignment_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Season 0 assignment: %',label; end if;
insert into assignment_checks values(label); end $$;
create function pg_temp.assignment_reject(sql text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute sql; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
  perform pg_temp.assignment_expect(rejected,'rejected: '||expected);
end $$;
create sequence pg_temp.assignment_person;
create sequence pg_temp.assignment_game_number;
create function pg_temp.assignment_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.assignment_person'); previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555777'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Assignment','last_name','Player',
    'username','assign_'||n,'date_of_birth','2000-01-01','email','assign_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  return player;
end $$;
create function pg_temp.assignment_game(n integer,future_game boolean default false,defenders_per_side integer default 2) returns uuid language plpgsql as $$
declare game uuid; player uuid; i integer; kickoff timestamptz:=date_trunc('minute',now())+
  case when future_game then interval '14 days' else interval '0' end-interval '1 minute'*nextval('pg_temp.assignment_game_number');
begin
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('OPEN','Isolated partial assignment',kickoff,kickoff+interval '1 hour',0,defenders_per_side*2,12-defenders_per_side*2) returning id into game;
  for i in 1..n loop
    player:=pg_temp.assignment_player();
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,player,case when i<=2 then 'GK' when i<=2+defenders_per_side*2 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
  end loop;
  return game;
end $$;
do $$
declare admin_id uuid:=pg_temp.assignment_player(); outsider uuid:=pg_temp.assignment_player(); game uuid; n integer;
  request uuid; response jsonb; again jsonb; participants jsonb; player uuid; party uuid; owner uuid; other uuid; swap_player uuid; old_roster jsonb;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Assignment admin','+15557770001','admin',true);
  -- The fresh migration's first reliability policy starts at this instant.
  -- Add rollback-only historical evidence for these already-due fixtures;
  -- retain every immutable-policy trigger and the actual snapshotted config.
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Isolated policy evidence for actual kickoff regression.',now(),admin_id
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Isolated assignment verification only.');
  for n in 10..14 loop
    game:=pg_temp.assignment_game(n); request:=gen_random_uuid();
    perform pg_temp.assignment_expect((select rating_policy_id='field-sr-season0-v2' and teams_assigned_at is null from public.open_queue_games where id=game),'v2 bookings do not silently auto-assign '||n);
    response:=public.referee_assign_season_zero_teams(admin_id,game,request);
    perform pg_temp.assignment_expect(response->>'action'='ASSIGN' and jsonb_array_length(response->'roster')=n,'response roster '||n);
    perform pg_temp.assignment_expect((select min(c)>=5 and max(c)<=7 and max(c)-min(c)<=1 from
      (select count(*) c from public.open_queue_bookings where game_id=game and status='CONFIRMED' group by team) counts),'actual side counts '||n);
    perform pg_temp.assignment_expect(not exists(select 1 from public.open_queue_bookings where game_id=game and (team is null or rating_at_team_assignment<>1000 or played)),'snapshot only, no invented participation '||n);
    perform pg_temp.assignment_expect(not exists(select 1 from public.open_queue_bookings where game_id=game group by team,role
      having count(*)>case role when 'GK' then 1 when 'DEF' then 2 when 'MID' then 0 else 4 end),'saved formation caps '||n);
    again:=public.referee_assign_season_zero_teams(admin_id,game,request);
    perform pg_temp.assignment_expect(again=response,'assignment idempotency '||n);
    perform public.assign_open_queue_teams(game);
    perform pg_temp.assignment_expect((select jsonb_agg(jsonb_build_object('booking_id',id,'profile_id',profile_id,'team',team,'role',role,'rating_at_team_assignment',rating_at_team_assignment) order by profile_id)
      from public.open_queue_bookings where game_id=game)=response->'roster','legacy read callback preserves explicit teams '||n);
    perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'unassigned Season 0');
    perform public.ensure_match_attendance_records('SOLO',game);
    update public.match_attendance_records set checked_in_at=clock_timestamp(),check_in_timing='EARLY' where open_queue_game_id=game;
    select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=game;
    perform public.referee_season_zero_action(admin_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
    perform pg_temp.assignment_expect((select jsonb_array_length(observed_roster)=n from fieldrush_rating_private.season_zero_matches where game_id=game),'actual START with partial roster '||n);
    perform pg_temp.assignment_reject(format('update public.open_queue_bookings set status=''CANCELLED'' where id=(select id from public.open_queue_bookings where game_id=%L limit 1)',game),'After kickoff');
  end loop;
  game:=pg_temp.assignment_game(10);
  perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',outsider,game,gen_random_uuid()),'not assigned to you');
  response:=public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  old_roster:=response->'roster';
  player:=pg_temp.assignment_player();
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
    values(game,player,'ATT','CONFIRMED',0,0,'FREE');
  perform pg_temp.assignment_expect((select teams_assigned_at is null from public.open_queue_games where id=game)
    and not exists(select 1 from jsonb_array_elements(old_roster) p join public.open_queue_bookings b on b.id=(p->>'booking_id')::uuid
      where b.team is distinct from p->>'team'),'late booking invalidates stamp but preserves every revealed team');
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  update public.open_queue_bookings set status='CANCELLED' where game_id=game and profile_id=player;
  perform pg_temp.assignment_expect((select teams_assigned_at is null from public.open_queue_games where id=game)
    and not exists(select 1 from jsonb_array_elements(old_roster) p join public.open_queue_bookings b on b.id=(p->>'booking_id')::uuid
      where b.team is distinct from p->>'team'),'prestart cancellation preserves every remaining revealed team');
  response:=public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.assignment_expect(jsonb_array_length(response->'roster')=10,'reassignment after cancellation uses the current original roster');
  game:=pg_temp.assignment_game(9);
  perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'ten to fourteen');
  game:=pg_temp.assignment_game(10,true);
  perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'team-reveal');
  game:=pg_temp.assignment_game(10);
  select profile_id into owner from public.open_queue_bookings where game_id=game and role='GK' order by id limit 1;
  select profile_id into other from public.open_queue_bookings where game_id=game and role='GK' and profile_id<>owner;
  insert into public.open_queue_parties(game_id,owner_profile_id) values(game,owner) returning id into party;
  insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
    values(party,game,owner,'ACCEPTED',owner,now(),now()),(party,game,other,'ACCEPTED',owner,now(),now());
  perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'roles and accepted parties');
  update public.open_queue_party_members set status='LEFT',ended_at=now() where party_id=party and profile_id=other;
  select profile_id into other from public.open_queue_bookings where game_id=game and role='ATT' order by id limit 1;
  insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
    values(party,game,other,'ACCEPTED',owner,now(),now());
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.assignment_expect((select count(distinct team)=1 from public.open_queue_bookings where game_id=game and profile_id in(owner,other)),'accepted party remains together');
  update public.open_queue_party_members set status='LEFT',ended_at=now() where party_id=party and profile_id=other;
  perform pg_temp.assignment_expect((select teams_assigned_at is null from public.open_queue_games where id=game),'accepted party changes invalidate a prestart assignment');
  -- A new party spanning retained sides cannot silently move present players.
  game:=pg_temp.assignment_game(10);
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  select profile_id into owner from public.open_queue_bookings where game_id=game and role='ATT' and team='WHITE' order by id limit 1;
  select profile_id into swap_player from public.open_queue_bookings where game_id=game and role='ATT' and team='WHITE' and profile_id<>owner;
  select profile_id into other from public.open_queue_bookings where game_id=game and role='ATT' and team='BLACK' order by id limit 1;
  insert into public.open_queue_parties(game_id,owner_profile_id) values(game,owner) returning id into party;
  insert into public.open_queue_party_members(party_id,game_id,profile_id,status,invited_by,responded_at,joined_at)
    values(party,game,owner,'ACCEPTED',owner,now(),now()),(party,game,other,'ACCEPTED',owner,now(),now());
  perform pg_temp.assignment_expect((select teams_assigned_at is null from public.open_queue_games where id=game)
    and (select count(distinct team)=2 from public.open_queue_bookings where game_id=game and profile_id in(owner,other)),
    'party change keeps old teams as consent constraints');
  perform pg_temp.assignment_reject(format('select public.referee_assign_season_zero_teams(%L,%L,%L)',admin_id,game,gen_random_uuid()),'Use consented rebalance');
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=clock_timestamp() where open_queue_game_id=game;
  participants:=jsonb_build_array(jsonb_build_object('profile_id',other,'to_team','WHITE','consented',false),
    jsonb_build_object('profile_id',swap_player,'to_team','BLACK','consented',true));
  perform pg_temp.assignment_reject(format('select public.referee_rebalance_season_zero_match(%L,%L,%L,%L::jsonb,%L)',
    admin_id,game,gen_random_uuid(),participants,'Restore compatible accepted party with consent.'),'present player must agree');
  participants:=jsonb_set(participants,'{0,consented}','true');
  perform public.referee_rebalance_season_zero_match(admin_id,game,gen_random_uuid(),participants,'Restore compatible accepted party with consent.');
  perform pg_temp.assignment_expect((select teams_assigned_at is not null from public.open_queue_games where id=game)
    and (select count(distinct team)=1 from public.open_queue_bookings where game_id=game and profile_id in(owner,other)),
    'consented rebalance repairs and restamps stale assignment');
  select jsonb_object_agg(profile_id::text,team) into old_roster from public.open_queue_bookings where game_id=game;
  perform public.assign_open_queue_teams(game);
  perform pg_temp.assignment_expect((select jsonb_object_agg(profile_id::text,team)=old_roster from public.open_queue_bookings where game_id=game),
    'automatic callback never rewrites consented repaired teams');
  game:=pg_temp.assignment_game(12,false,0);
  response:=public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  perform pg_temp.assignment_expect(not exists(select 1 from public.open_queue_bookings where game_id=game and role='DEF')
    and (select min(c)=6 and max(c)=6 from(select count(*) c from public.open_queue_bookings where game_id=game group by team) t),
    'saved1/0/6 formation assigns partial6v6 without hardcoded defender counts');
  game:=pg_temp.assignment_game(14,false,3);
  update public.fieldrush_player_rating_tracks r set skill_rating=case when rating_track='GOALKEEPER' then -100 else 1000000 end
    where profile_id in(select profile_id from public.open_queue_bookings where game_id=game and role='GK');
  perform public.assign_open_queue_teams(game);
  perform pg_temp.assignment_expect((select teams_assigned_at is not null from public.open_queue_games where id=game),
    'initial full14 uses the unchanged automatic timed optimizer');
  perform pg_temp.assignment_expect((select bool_and(c=3) from(select count(*) c from public.open_queue_bookings where game_id=game and role='DEF' group by team)t),
    'saved1/3/3 formation preserves three defenders per full side');
  perform pg_temp.assignment_expect((select bool_and(rating_at_team_assignment=-100) from public.open_queue_bookings where game_id=game and role='GK')
    and (select match_average_sr=round((12*1000-200)::numeric/14,2) from public.open_queue_games where id=game),
    'automatic assignment retains signed booked-role SR and ignores unused outfield pool');
  game:=pg_temp.assignment_game(14,true);
  perform public.assign_open_queue_teams(game);
  perform pg_temp.assignment_expect((select teams_assigned_at is null from public.open_queue_games where id=game),
    'automatic full14 reveal still obeys existing policy time');
  perform pg_temp.assignment_expect(not has_function_privilege('authenticated','public.referee_assign_season_zero_teams(uuid,uuid,uuid)','EXECUTE')
    and not has_function_privilege('anon','public.referee_assign_season_zero_teams(uuid,uuid,uuid)','EXECUTE')
    and has_function_privilege('service_role','public.referee_assign_season_zero_teams(uuid,uuid,uuid)','EXECUTE'),'assignment RPC service-only');
  perform pg_temp.assignment_expect(position('where singleton for share' in pg_get_functiondef('fieldrush_rating_private.pin_solo_rating_policy()'::regprocedure))>0
    and position('perform fieldrush_rating_private.lock_season_zero_sr()' in pg_get_functiondef('fieldrush_rating_private.pin_solo_rating_policy()'::regprocedure))=0,
    'policy pin shares the activation row without reversing season/SR-global lock order');
  perform pg_temp.assignment_expect((select count(*)>0 from public.admin_audit_events where action='SOLO_SR_TEAMS_ASSIGNED'),'assignment actor and original roster audited');
  perform pg_temp.assignment_expect(not has_function_privilege('service_role','public.assign_open_queue_teams_before_season_zero(uuid)','EXECUTE'),'legacy assignment alias is not a policy bypass');
  perform pg_temp.assignment_expect(position('pg_try_advisory_xact_lock' in pg_get_functiondef('fieldrush_rating_private.invalidate_season_zero_assignment(uuid)'::regprocedure))
    <position('for update' in pg_get_functiondef('fieldrush_rating_private.invalidate_season_zero_assignment(uuid)'::regprocedure)),
    'party-trigger invalidation obtains nonblocking global lock before game row lock');
end $$;
select count(*) as verified_assignment_checks from assignment_checks;
