-- Auditable, consented pre-kickoff transfers for prospectively pinned games.
-- Positions, accepted parties, booked players and the existing formation remain
-- intact. This does not assign new players, activate a policy, or start a clock.
create function public.referee_rebalance_season_zero_match(
  actor_referee_id uuid, game_id_to_use uuid, request_id_to_use uuid,
  moves_input jsonb, reason_to_use text
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare
  g public.open_queue_games%rowtype;
  previous_request fieldrush_rating_private.season_zero_action_requests%rowtype;
  request_input jsonb;
  move jsonb;
  player_id uuid;
  seen_players uuid[] := array[]::uuid[];
  target_team text;
  before_roster jsonb;
  after_roster jsonb;
  final_teams jsonb;
  moved_audit jsonb := '[]'::jsonb;
  booking record;
  actual_count integer;
  total_booked integer;
  quota record;
  team_to_check text;
  recorded timestamptz;
  white_average numeric;
  black_average numeric;
  overall_average numeric;
  present_white_average numeric;
  present_black_average numeric;
  response jsonb;
begin
  if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
    raise exception 'This match is not assigned to you.' using errcode='42501';
  end if;
  if request_id_to_use is null or jsonb_typeof(moves_input) is distinct from 'array'
      or jsonb_array_length(moves_input) not between 1 and 14 then
    raise exception 'Provide one to fourteen player moves with a request ID.' using errcode='22023';
  end if;
  if char_length(trim(coalesce(reason_to_use,''))) not between 10 and 2000 then
    raise exception 'Record a rebalance reason between ten and 2000 characters.' using errcode='22023';
  end if;
  request_input:=jsonb_build_object('action','REBALANCE','moves',moves_input,'reason',trim(reason_to_use));
  perform fieldrush_rating_private.lock_season_zero_sr();
  select * into previous_request from fieldrush_rating_private.season_zero_action_requests
    where request_id=request_id_to_use;
  if found then
    if (previous_request.game_id,previous_request.actor_id,previous_request.input) is distinct from
        (game_id_to_use,actor_referee_id,request_input) then
      raise exception 'This request ID belongs to another action.' using errcode='22023';
    end if;
    return previous_request.response;
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.id is null or g.rating_policy_id is distinct from 'field-sr-season0-v2'
      or g.format_version is distinct from 'FIELDRUSH_7V7' then
    raise exception 'This operation requires a Season 0 seven-a-side game.' using errcode='22023';
  end if;
  if g.status is null or g.status not in ('OPEN','FULL') or g.operational_state is distinct from 'NORMAL'
      or (g.teams_assigned_at is null and not exists(select 1 from public.open_queue_bookings
        where game_id=g.id and status='CONFIRMED' and team in ('WHITE','BLACK')))
      or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=g.id)
      or exists(select 1 from public.open_queue_clock_states where game_id=g.id and
        (status is distinct from 'NOT_STARTED' or started_at is not null or accumulated_seconds is distinct from 0)) then
    raise exception 'Teams can only be moved after assignment and before actual kickoff.' using errcode='22023';
  end if;
  -- Existing party/check-in/booking writers serialize on the same game row.
  -- Lock the concrete evidence too, so consent classification and party checks
  -- describe one coherent pre-kickoff roster.
  perform b.id from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED' order by b.id for update;
  perform p.id from public.open_queue_parties p where p.game_id=g.id and p.status='ACTIVE' order by p.id for update;
  perform m.id from public.open_queue_party_members m where m.game_id=g.id and m.status='ACCEPTED' order by m.id for update;
  perform a.booking_id from public.match_attendance_records a join public.open_queue_bookings b on b.id=a.booking_id
    where b.game_id=g.id and b.status='CONFIRMED' order by a.booking_id for update of a;
  perform r.profile_id from public.fieldrush_player_rating_tracks r join public.open_queue_bookings b
    on b.profile_id=r.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    where b.game_id=g.id and b.status='CONFIRMED' order by r.profile_id,r.rating_track for update of r;
  recorded:=clock_timestamp();
  select count(*) into total_booked from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
  if total_booked not between 10 and 14 or exists(
    select 1 from public.open_queue_bookings b left join public.fieldrush_player_rating_tracks r
      on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)
    where b.game_id=g.id and b.status='CONFIRMED' and
      ((b.team is not null and b.team not in ('WHITE','BLACK')) or r.skill_rating is null or r.matches_played is null)
  ) then
    raise exception 'Ten to fourteen original bookings need valid rating snapshots.' using errcode='22023';
  end if;
  select jsonb_agg(jsonb_build_object('booking_id',b.id,'profile_id',b.profile_id,'team',b.team,'role',b.role,
      'checked_in',exists(select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null),
      'rating_at_team_assignment',b.rating_at_team_assignment) order by b.profile_id),
    jsonb_object_agg(b.profile_id::text,b.team)
  into before_roster,final_teams from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED';

  for move in select value from jsonb_array_elements(moves_input) loop
    if jsonb_typeof(move) is distinct from 'object'
        or exists(select 1 from jsonb_object_keys(move) k where k not in ('profile_id','to_team','consented'))
        or jsonb_typeof(move->'profile_id') is distinct from 'string'
        or jsonb_typeof(move->'consented') is distinct from 'boolean'
        or jsonb_typeof(move->'to_team') is distinct from 'string'
        or move->>'to_team' not in ('WHITE','BLACK') then
      raise exception 'Each move needs a player, a target team, and explicit consent status only.' using errcode='22023';
    end if;
    begin player_id:=(move->>'profile_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Invalid player ID in move.' using errcode='22023';
    end;
    if player_id=any(seen_players) then raise exception 'A player can occur only once in a transfer.' using errcode='22023'; end if;
    seen_players:=array_append(seen_players,player_id);
    target_team:=move->>'to_team';
    select b.id,b.team,b.role,exists(select 1 from public.match_attendance_records a
      where a.booking_id=b.id and a.checked_in_at is not null) checked_in into booking
    from public.open_queue_bookings b where b.game_id=g.id and b.profile_id=player_id and b.status='CONFIRMED';
    if not found then raise exception 'Only an originally confirmed booked player can move.' using errcode='22023'; end if;
    if booking.team=target_team then raise exception 'The player is already assigned to that team.' using errcode='22023'; end if;
    if booking.team is not null and booking.checked_in and not (move->>'consented')::boolean then
      raise exception 'A present player must agree before being moved.' using errcode='22023';
    end if;
    final_teams:=jsonb_set(final_teams,array[player_id::text],to_jsonb(target_team));
    moved_audit:=moved_audit||jsonb_build_array(jsonb_build_object(
      'profile_id',player_id,'booking_id',booking.id,'from_team',booking.team,'to_team',target_team,'role',booking.role,
      'checked_in',booking.checked_in,'consented',(move->>'consented')::boolean,
      'consent_recorded_by',actor_referee_id,'recorded_at',recorded
    ));
  end loop;

  -- Validate the whole final assignment, not sequential intermediate swaps.
  if exists(select 1 from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED'
    and (final_teams->>b.profile_id::text is null or final_teams->>b.profile_id::text not in ('WHITE','BLACK'))) then
    raise exception 'Assign a final team to every original booked player.' using errcode='22023'; end if;
  foreach team_to_check in array array['WHITE','BLACK'] loop
    select count(*) into actual_count from public.open_queue_bookings b
      where b.game_id=g.id and b.status='CONFIRMED' and final_teams->>b.profile_id::text=team_to_check;
    if actual_count>7 then raise exception 'Each final booked team must contain no more than seven players.' using errcode='22023'; end if;
    if actual_count<5 then raise exception 'Each final booked team needs at least five players.' using errcode='22023'; end if;
    for quota in select * from (values ('GK',g.goalkeeper_capacity/2),('DEF',g.defender_capacity/2),
        ('MID',g.midfielder_capacity/2),('ATT',g.attacker_capacity/2)) q(role,capacity) loop
      select count(*) into actual_count from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED'
        and final_teams->>b.profile_id::text=team_to_check and b.role=quota.role;
      if quota.capacity is null or actual_count>quota.capacity or (total_booked=g.capacity and actual_count<>quota.capacity) then
        raise exception 'Transfers must preserve the booked position quotas on both teams.' using errcode='22023';
      end if;
    end loop;
  end loop;
  if exists(select 1 from public.open_queue_parties p join public.open_queue_party_members m on m.party_id=p.id and m.game_id=p.game_id
      join public.open_queue_bookings b on b.game_id=m.game_id and b.profile_id=m.profile_id and b.status='CONFIRMED'
      where p.game_id=g.id and p.status='ACTIVE' and m.status='ACCEPTED'
      group by p.id having count(distinct final_teams->>b.profile_id::text)>1) then
    raise exception 'Accepted parties must stay together after a transfer.' using errcode='22023';
  end if;

  -- One update makes the absent-slot exchange atomic. No role/check-in/played
  -- field changes, and the original assignment is retained in the audit below.
  update public.open_queue_bookings b set team=final_teams->>b.profile_id::text,rating_at_team_assignment=r.skill_rating
    from public.fieldrush_player_rating_tracks r where b.game_id=g.id and b.status='CONFIRMED'
      and r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role);
  select avg(b.rating_at_team_assignment) filter(where b.team='WHITE'),avg(b.rating_at_team_assignment) filter(where b.team='BLACK'),
    avg(b.rating_at_team_assignment),avg(b.rating_at_team_assignment) filter(where b.team='WHITE' and exists(
      select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null)),
    avg(b.rating_at_team_assignment) filter(where b.team='BLACK' and exists(
      select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null))
  into white_average,black_average,overall_average,present_white_average,present_black_average
  from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED';
  update public.open_queue_games set white_average_sr=round(white_average,2),black_average_sr=round(black_average,2),
    match_average_sr=round(overall_average,2),team_sr_spread=round(abs(white_average-black_average),2),
    teams_assigned_at=coalesce(g.teams_assigned_at,recorded) where id=g.id;
  select jsonb_agg(jsonb_build_object('booking_id',b.id,'profile_id',b.profile_id,'team',b.team,'role',b.role,
    'checked_in',exists(select 1 from public.match_attendance_records a where a.booking_id=b.id and a.checked_in_at is not null),
    'rating_at_team_assignment',b.rating_at_team_assignment) order by b.profile_id) into after_roster
  from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED';
  response:=jsonb_build_object('game_id',g.id,'request_id',request_id_to_use,'action','REBALANCE','recorded_at',recorded,
    'actor_id',actor_referee_id,'moves',moved_audit,'roster',after_roster,
    'projected_booked_strengths',jsonb_build_object('WHITE',white_average,'BLACK',black_average),
    'projected_present_strengths',jsonb_build_object('WHITE',present_white_average,'BLACK',present_black_average));
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_referee_id,'SOLO_SR_PREKICKOFF_REBALANCE','SOLO_MATCH',g.id,trim(reason_to_use),
    jsonb_build_object('roster',before_roster),response);
  for move in select value from jsonb_array_elements(moved_audit) loop
    insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
    values((move->>'profile_id')::uuid,'OPEN_QUEUE_TEAM_REASSIGNED','Your team assignment changed',
      'Your booked team is now '||case move->>'to_team' when 'WHITE' then 'White' else 'Black' end||
        '. Your playing position is unchanged. Check your team before entering play.',
      'OPEN_QUEUE_GAME',g.id,jsonb_build_object('game_id',g.id,'request_id',request_id_to_use,
        'from_team',move->'from_team','to_team',move->'to_team','role',move->'role','starts_at',g.starts_at));
  end loop;
  insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
    values(request_id_to_use,g.id,actor_referee_id,request_input,response);
  return response;
end;
$$;
revoke all on function public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.referee_rebalance_season_zero_match(uuid,uuid,uuid,jsonb,text) to service_role;
