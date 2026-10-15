-- Explicit, audited assignment for ten to fourteen booked players. The legacy
-- full-roster optimizer and its callers remain unchanged for legacy games.
-- Assignment is not check-in, kickoff, participation, or policy activation.
create or replace function fieldrush_rating_private.pin_solo_rating_policy()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare enabled_to_use boolean;
begin
  if tg_op='UPDATE' then
    if new.rating_policy_id is distinct from old.rating_policy_id then
      raise exception 'The advertised rating policy cannot change. Create a new game.';
    end if;
  else
    -- Serialize only against activation's row update. A new LIVE game's earlier
    -- season trigger may already own the season lock, so never take the SR
    -- global lock here (START takes those locks in the opposite order).
    -- At stronger isolation this row lock rejects an obsolete snapshot.
    select enabled into enabled_to_use from fieldrush_rating_private.season_zero_activation where singleton for share;
    new.rating_policy_id:=case when new.format_version='FIELDRUSH_7V7' and enabled_to_use
      then 'field-sr-season0-v2' else 'LEGACY' end;
  end if;
  return new;
end;
$$;

create function fieldrush_rating_private.season_zero_white_assignment(game_to_use uuid)
returns uuid[] language sql stable security definer set search_path=public,pg_temp as $$
  with game as (select * from public.open_queue_games where id=game_to_use), participants as (
    select b.id,b.role,b.team prior_team,r.skill_rating::numeric sr,
      coalesce('party:'||p.id::text,'booking:'||b.id::text) unit_key
    from public.open_queue_bookings b
    join public.fieldrush_player_rating_tracks r on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    left join public.open_queue_party_members m on m.game_id=b.game_id and m.profile_id=b.profile_id and m.status='ACCEPTED'
    left join public.open_queue_parties p on p.id=m.party_id and p.game_id=b.game_id and p.status='ACTIVE'
    where b.game_id=game_to_use and b.status='CONFIRMED'
  ), grouped as (
    select unit_key,array_agg(id order by id) booking_ids,count(*) n,sum(sr) sr,
      count(*) filter(where role='GK') gk,count(*) filter(where role='DEF') def,
      count(*) filter(where role='MID') mid,count(*) filter(where role='ATT') att,
      count(*) filter(where prior_team='WHITE') pinned_white,count(*) filter(where prior_team='BLACK') pinned_black
    from participants group by unit_key
  ), units as (select g.*,(row_number() over(order by unit_key)-1)::integer idx from grouped g),
  totals as (select count(*)::integer units,sum(n) n,sum(sr) sr,sum(gk) gk,sum(def) def,sum(mid) mid,sum(att) att,sum(pinned_white) pinned_white from units),
  candidates as (
    select mask,side.n,side.sr
    from totals t cross join game g
    -- Pinned teams break complementary-mask symmetry; inspect both labels.
    cross join lateral generate_series(1::bigint,(1::bigint<<t.units)-1) mask
    cross join lateral(select sum(u.n) n,sum(u.sr) sr,sum(u.gk) gk,sum(u.def) def,sum(u.mid) mid,sum(u.att) att,
      sum(u.pinned_white) pinned_white,sum(u.pinned_black) pinned_black
      from units u where (mask & (1::bigint<<u.idx))<>0) side
    where side.n between 5 and 7 and t.n-side.n between 5 and 7
      and side.pinned_black=0 and t.pinned_white-side.pinned_white=0
      and side.gk<=g.goalkeeper_capacity/2 and t.gk-side.gk<=g.goalkeeper_capacity/2
      and side.def<=g.defender_capacity/2 and t.def-side.def<=g.defender_capacity/2
      and side.mid<=g.midfielder_capacity/2 and t.mid-side.mid<=g.midfielder_capacity/2
      and side.att<=g.attacker_capacity/2 and t.att-side.att<=g.attacker_capacity/2
    order by abs(side.n*2-t.n),abs(side.sr/side.n-(t.sr-side.sr)/(t.n-side.n)),mask limit 1
  )
  select array(select bid from units u cross join lateral unnest(u.booking_ids) bid
    where (c.mask & (1::bigint<<u.idx))<>0 order by bid) from candidates c;
$$;

-- Preserve the established timed automatic reveal for full initial rosters.
-- Never let a legacy read/booking callback overwrite retained/consented teams.
alter function public.assign_open_queue_teams(uuid) rename to assign_open_queue_teams_before_season_zero;
revoke all on function public.assign_open_queue_teams_before_season_zero(uuid) from public,anon,authenticated,service_role;
create function public.assign_open_queue_teams(game_id_to_assign uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.open_queue_games where id=game_id_to_assign and rating_policy_id='field-sr-season0-v2') then
    if not exists(select 1 from public.open_queue_games where id=game_id_to_assign and status='FULL' and teams_assigned_at is null)
      or exists(select 1 from public.open_queue_bookings where game_id=game_id_to_assign and status='CONFIRMED' and team is not null) then return; end if;
  end if;
  perform public.assign_open_queue_teams_before_season_zero(game_id_to_assign);
end;
$$;
revoke all on function public.assign_open_queue_teams(uuid) from public,anon,authenticated;
grant execute on function public.assign_open_queue_teams(uuid) to service_role;

create function fieldrush_rating_private.invalidate_season_zero_assignment(game_to_use uuid)
returns void language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype;
begin
  select * into g from public.open_queue_games where id=game_to_use;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or g.teams_assigned_at is null
    or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=g.id) then return; end if;
  -- Party writers may already own a party row. Never wait against the
  -- assignment/rebalance global->game->party lock order; return a safe retry.
  if not pg_try_advisory_xact_lock(hashtextextended('fieldrush-season-zero-rating',0)) then
    raise exception 'Team evidence changed concurrently. Retry the roster change.' using errcode='40001'; end if;
  select * into g from public.open_queue_games where id=game_to_use for update;
  if g.teams_assigned_at is null or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=g.id) then return; end if;
  update public.open_queue_games set teams_assigned_at=null,white_average_sr=null,black_average_sr=null,match_average_sr=null,team_sr_spread=null where id=g.id;
  update public.open_queue_bookings set rating_at_team_assignment=null,rating_at_match_start=null,rating_change=null
    where game_id=g.id and status='CONFIRMED';
  -- The original assignment remains in its immutable action request and audit.
  -- Membership writers retain their own cancellation/booking actor evidence;
  -- this automatic invalidation must not invent a referee actor.
end;
$$;
create function fieldrush_rating_private.invalidate_season_zero_booking_assignment()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if tg_op='UPDATE' and row(new.game_id,new.profile_id,new.role,new.status) is not distinct from row(old.game_id,old.profile_id,old.role,old.status) then return new; end if;
  if tg_op<>'INSERT' and old.status='CONFIRMED' then perform fieldrush_rating_private.invalidate_season_zero_assignment(old.game_id); end if;
  if tg_op<>'DELETE' and new.status='CONFIRMED' then perform fieldrush_rating_private.invalidate_season_zero_assignment(new.game_id); end if;
  return null;
end;
$$;
create trigger z_invalidate_season_zero_booking_assignment after insert or delete or update of game_id,profile_id,role,status
  on public.open_queue_bookings for each row execute function fieldrush_rating_private.invalidate_season_zero_booking_assignment();

create function fieldrush_rating_private.invalidate_season_zero_party_assignment()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if tg_table_name='open_queue_party_members' then
    if tg_op='UPDATE' and row(new.party_id,new.game_id,new.profile_id,new.status) is not distinct from
      row(old.party_id,old.game_id,old.profile_id,old.status) then return null; end if;
    if tg_op<>'INSERT' and old.status='ACCEPTED' then perform fieldrush_rating_private.invalidate_season_zero_assignment(old.game_id); end if;
    if tg_op<>'DELETE' and new.status='ACCEPTED' then perform fieldrush_rating_private.invalidate_season_zero_assignment(new.game_id); end if;
  elsif new.status is distinct from old.status then
    perform fieldrush_rating_private.invalidate_season_zero_assignment(new.game_id);
  end if;
  return null;
end;
$$;
create trigger z_invalidate_season_zero_party_assignment after insert or delete or update of party_id,game_id,profile_id,status
  on public.open_queue_party_members for each row execute function fieldrush_rating_private.invalidate_season_zero_party_assignment();
create trigger z_invalidate_season_zero_party_status after update of status on public.open_queue_parties
  for each row execute function fieldrush_rating_private.invalidate_season_zero_party_assignment();
create function fieldrush_rating_private.invalidate_season_zero_formation_assignment()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  if row(new.goalkeeper_capacity,new.defender_capacity,new.midfielder_capacity,new.attacker_capacity)
    is distinct from row(old.goalkeeper_capacity,old.defender_capacity,old.midfielder_capacity,old.attacker_capacity) then
    perform fieldrush_rating_private.invalidate_season_zero_assignment(new.id);
  end if;
  return null;
end;
$$;
create trigger z_invalidate_season_zero_formation_assignment after update of goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity
  on public.open_queue_games for each row execute function fieldrush_rating_private.invalidate_season_zero_formation_assignment();

-- Existing membership callbacks clear every team when a roster becomes
-- incomplete. For v2 retain those revealed teams as consent constraints.
do $migration$
declare d text;
begin
  d:=pg_get_functiondef('public.sync_open_queue_game_status()'::regprocedure);
  if position(E'begin\n' in d)=0 then raise exception 'Booking status callback contract changed.'; end if;
  d:=replace(d,E'begin\n',$new$begin
  game_id_to_sync:=case when tg_op='DELETE' then old.game_id else new.game_id end;
  if exists(select 1 from public.open_queue_games where id=game_id_to_sync and rating_policy_id='field-sr-season0-v2') then
    select * into game_to_sync from public.open_queue_games where id=game_id_to_sync for update;
    if game_to_sync.status in ('OPEN','FULL') then
      select count(*) into confirmed_count from public.open_queue_bookings where game_id=game_id_to_sync and status='CONFIRMED';
      update public.open_queue_games set status=case when confirmed_count>=game_to_sync.capacity then 'FULL' else 'OPEN' end where id=game_id_to_sync;
    end if;
    return case when tg_op='DELETE' then old else new end;
  end if;
$new$);
  execute d;
  d:=pg_get_functiondef('public.reassign_open_queue_teams_after_party_change(uuid)'::regprocedure);
  if position(E'begin\n' in d)=0 then raise exception 'Party assignment callback contract changed.'; end if;
  d:=replace(d,E'begin\n',$new$begin
  if exists(select 1 from public.open_queue_games where id=game_id_to_reassign and rating_policy_id='field-sr-season0-v2') then
    perform fieldrush_rating_private.invalidate_season_zero_assignment(game_id_to_reassign);
    return;
  end if;
$new$);
  execute d;
end;
$migration$;

create function public.referee_assign_season_zero_teams(actor_referee_id uuid,game_id_to_use uuid,request_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; previous_request fieldrush_rating_private.season_zero_action_requests%rowtype;
  white_ids uuid[]; booked integer; recorded timestamptz; response jsonb; roster jsonb;
  white_average numeric; black_average numeric; overall_average numeric;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501'; end if;
  if request_id_to_use is null then raise exception 'Provide an assignment request ID.' using errcode='22023'; end if;
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into previous_request from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
  if found then
    if row(previous_request.game_id,previous_request.actor_id,previous_request.input) is distinct from
      row(game_id_to_use,actor_referee_id,'{"action":"ASSIGN"}'::jsonb) then raise exception 'This request ID belongs to another action.' using errcode='22023'; end if;
    return previous_request.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.rating_policy_id is distinct from 'field-sr-season0-v2' or g.format_version is distinct from 'FIELDRUSH_7V7'
    or g.status is null or g.status not in ('OPEN','FULL') or g.operational_state is distinct from 'NORMAL'
    or g.teams_assigned_at is not null or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=g.id)
    or exists(select 1 from public.open_queue_clock_states where game_id=g.id and
      (status is distinct from 'NOT_STARTED' or started_at is not null or accumulated_seconds is distinct from 0)) then
    raise exception 'Assign only an unassigned Season 0 game before kickoff.' using errcode='22023';
  end if;
  if clock_timestamp()<least(g.starts_at,public.open_queue_team_assignment_at(g.id)) then
    raise exception 'Wait until the scheduled team-reveal time.' using errcode='22023'; end if;
  perform b.id from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED' order by b.id for update;
  perform p.id from public.open_queue_parties p where p.game_id=g.id and p.status='ACTIVE' order by p.id for update;
  perform m.id from public.open_queue_party_members m where m.game_id=g.id and m.status='ACCEPTED' order by m.id for update;
  perform r.profile_id from public.fieldrush_player_rating_tracks r join public.open_queue_bookings b
    on b.profile_id=r.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    where b.game_id=g.id and b.status='CONFIRMED' order by r.profile_id,r.rating_track for update of r;
  recorded:=clock_timestamp();
  select count(*) into booked from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
  if booked not between 10 and 14 or exists(select 1 from public.open_queue_bookings b
    left join public.fieldrush_player_rating_tracks r on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    where b.game_id=g.id and b.status='CONFIRMED' and (r.profile_id is null or b.role not in ('GK','DEF','MID','ATT'))) then
    raise exception 'Assignment needs ten to fourteen booked players with valid rating tracks.' using errcode='22023'; end if;
  white_ids:=fieldrush_rating_private.season_zero_white_assignment(g.id);
  if white_ids is null then raise exception 'The booked roles and accepted parties cannot form two sides of five to seven without moving an assigned player. Use consented rebalance.' using errcode='22023'; end if;
  update public.open_queue_party_members m set status='CANCELLED',responded_at=recorded,ended_at=recorded
    from public.open_queue_parties p where m.party_id=p.id and m.game_id=g.id and m.status='INVITED' and p.status='ACTIVE';
  update public.open_queue_bookings b set team=case when b.id=any(white_ids) then 'WHITE' else 'BLACK' end,
    rating_at_team_assignment=r.skill_rating,rating_at_match_start=null,rating_change=null
    from public.fieldrush_player_rating_tracks r where b.game_id=g.id and b.status='CONFIRMED'
      and r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role);
  select avg(rating_at_team_assignment) filter(where team='WHITE'),avg(rating_at_team_assignment) filter(where team='BLACK'),avg(rating_at_team_assignment),
    jsonb_agg(jsonb_build_object('booking_id',id,'profile_id',profile_id,'team',team,'role',role,'rating_at_team_assignment',rating_at_team_assignment) order by profile_id)
    into white_average,black_average,overall_average,roster from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
  update public.open_queue_games set teams_assigned_at=recorded,white_average_sr=round(white_average,2),black_average_sr=round(black_average,2),
    match_average_sr=round(overall_average,2),team_sr_spread=round(abs(white_average-black_average),2) where id=g.id;
  response:=jsonb_build_object('game_id',g.id,'action','ASSIGN','request_id',request_id_to_use,'actor_id',actor_referee_id,'recorded_at',recorded,
    'roster',roster,'projected_booked_strengths',jsonb_build_object('WHITE',white_average,'BLACK',black_average));
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,after_state)
    values(actor_referee_id,'SOLO_SR_TEAMS_ASSIGNED','SOLO_MATCH',g.id,'Assign the original booked roster while preserving accepted parties and saved roles.',response);
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,g.id,actor_referee_id,'{"action":"ASSIGN"}',response);
  return response;
end;
$$;
revoke all on function fieldrush_rating_private.season_zero_white_assignment(uuid),
  fieldrush_rating_private.invalidate_season_zero_assignment(uuid),fieldrush_rating_private.invalidate_season_zero_booking_assignment(),
  fieldrush_rating_private.invalidate_season_zero_party_assignment(),fieldrush_rating_private.invalidate_season_zero_formation_assignment()
  from public,anon,authenticated,service_role;
revoke all on function public.referee_assign_season_zero_teams(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.referee_assign_season_zero_teams(uuid,uuid,uuid) to service_role;
notify pgrst,'reload schema';
