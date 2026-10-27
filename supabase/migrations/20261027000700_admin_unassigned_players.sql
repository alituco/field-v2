-- Place new bookings into retained teams without allowing a stale admin form
-- to transfer anyone who has since received an assignment.
create function public.admin_assign_unassigned_open_queue_players(
  actor_admin_id uuid,
  game_id_to_use uuid,
  request_id_to_use uuid,
  assignments_input jsonb
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_rating_private, pg_temp as $$
declare
  assignment jsonb;
  moves jsonb := '[]'::jsonb;
  player_id uuid;
  seen_players uuid[] := array[]::uuid[];
  booking record;
  g public.open_queue_games%rowtype;
  previous_request fieldrush_rating_private.season_zero_action_requests%rowtype;
  request_input jsonb;
  final_teams jsonb;
  before_roster jsonb;
  after_roster jsonb;
  total_booked integer;
  team_to_check text;
  actual_count integer;
  quota record;
  recorded timestamptz;
  white_average numeric;
  black_average numeric;
  overall_average numeric;
  response jsonb;
  assignment_reason constant text := 'Assign newly booked players without moving existing teams.';
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Only an active admin can place unassigned players.' using errcode = '42501';
  end if;
  if request_id_to_use is null or jsonb_typeof(assignments_input) is distinct from 'array'
    or jsonb_array_length(assignments_input) not between 1 and 14 then
    raise exception 'Choose one to fourteen unassigned players and provide a request ID.' using errcode = '22023';
  end if;
  for assignment in select value from jsonb_array_elements(assignments_input) loop
    if jsonb_typeof(assignment) is distinct from 'object'
      or exists(select 1 from jsonb_object_keys(assignment) k where k not in ('profile_id', 'to_team'))
      or jsonb_typeof(assignment->'profile_id') is distinct from 'string'
      or jsonb_typeof(assignment->'to_team') is distinct from 'string'
      or assignment->>'to_team' not in ('WHITE', 'BLACK') then
      raise exception 'Choose a player and either White or Black.' using errcode = '22023';
    end if;
    begin
      player_id := (assignment->>'profile_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Choose a valid player.' using errcode = '22023';
    end;
    if player_id = any(seen_players) then
      raise exception 'Choose each player only once.' using errcode = '22023';
    end if;
    seen_players := array_append(seen_players, player_id);
    moves := moves || jsonb_build_array(jsonb_build_object(
      'profile_id', player_id, 'to_team', assignment->>'to_team', 'consented', false
    ));
  end loop;

  -- Same lock order and request ledger as the audited team-edit operation.
  perform fieldrush_rating_private.lock_season_zero_sr();
  request_input := jsonb_build_object('action', 'ASSIGN_UNASSIGNED', 'moves', moves);
  select * into previous_request from fieldrush_rating_private.season_zero_action_requests where request_id = request_id_to_use;
  if found and previous_request.input->>'action' = 'ASSIGN_UNASSIGNED' then
    if row(previous_request.game_id, previous_request.actor_id, previous_request.input)
      is distinct from row(game_id_to_use, actor_admin_id, request_input) then
      raise exception 'This request ID belongs to another action.' using errcode = '22023';
    end if;
    return previous_request.response;
  elsif found then
    response := public.referee_rebalance_season_zero_match(
      actor_admin_id, game_id_to_use, request_id_to_use, moves, assignment_reason
    );
    return response || jsonb_build_object('action', 'ASSIGN_UNASSIGNED', 'assigned_count', jsonb_array_length(moves));
  end if;
  select * into g from public.open_queue_games where id = game_id_to_use for update;
  perform b.id from public.open_queue_bookings b
    where b.game_id = game_id_to_use and b.status = 'CONFIRMED' order by b.id for update;
  foreach player_id in array seen_players loop
    select b.id, b.team into booking from public.open_queue_bookings b
      where b.game_id = game_id_to_use and b.profile_id = player_id and b.status = 'CONFIRMED';
    if not found then
      raise exception 'This player no longer has a confirmed booking. Refresh the roster.' using errcode = '22023';
    end if;
    if booking.team is not null then
      raise exception 'This player has already been assigned. Refresh the roster before placing players.' using errcode = '22023';
    end if;
  end loop;

  if g.rating_policy_id = 'field-sr-season0-v2' then
    -- Keep the existing Season 0 participation and minimum-roster policy.
    response := public.referee_rebalance_season_zero_match(
      actor_admin_id, game_id_to_use, request_id_to_use, moves, assignment_reason
    );
    return response || jsonb_build_object('action', 'ASSIGN_UNASSIGNED', 'assigned_count', jsonb_array_length(moves));
  end if;

  -- Legacy Phoenix 7v7 and Bahrain 6v6 games retain their advertised format,
  -- roles, rating policy and kickoff requirements. Placement alone need not
  -- wait until a cancelled place has been rebooked or the kickoff minimum met.
  if g.id is null or g.rating_policy_id is distinct from 'LEGACY'
    or g.format_version not in ('LEGACY_6V6', 'FIELDRUSH_7V7')
    or g.status not in ('OPEN', 'FULL') or g.operational_state is distinct from 'NORMAL'
    or g.actual_started_at is not null
    or (g.teams_assigned_at is null and not exists(select 1 from public.open_queue_bookings
      where game_id = g.id and status = 'CONFIRMED' and team in ('WHITE', 'BLACK')))
    or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id = g.id)
    or exists(select 1 from public.open_queue_clock_states where game_id = g.id and
      (status is distinct from 'NOT_STARTED' or started_at is not null or accumulated_seconds is distinct from 0))
    or exists(select 1 from public.open_queue_events where game_id = g.id and event_type = 'MATCH_STARTED') then
    raise exception 'Place players only into already-created teams before actual kickoff, with no active review.' using errcode = '22023';
  end if;
  perform p.id from public.open_queue_parties p where p.game_id = g.id and p.status = 'ACTIVE' order by p.id for update;
  perform m.id from public.open_queue_party_members m where m.game_id = g.id and m.status = 'ACCEPTED' order by m.id for update;
  perform r.profile_id from public.fieldrush_player_rating_tracks r join public.open_queue_bookings b
    on b.profile_id = r.profile_id and r.rating_track = public.fieldrush_rating_track(b.role)
    where b.game_id = g.id and b.status = 'CONFIRMED' order by r.profile_id, r.rating_track for update of r;
  select count(*) into total_booked from public.open_queue_bookings where game_id = g.id and status = 'CONFIRMED';
  if total_booked > g.capacity or exists(select 1 from public.open_queue_bookings b
    left join public.fieldrush_player_rating_tracks r on r.profile_id = b.profile_id and r.rating_track = public.fieldrush_rating_track(b.role)
    where b.game_id = g.id and b.status = 'CONFIRMED' and
      (b.role not in ('GK', 'DEF', 'MID', 'ATT') or (b.team is not null and b.team not in ('WHITE', 'BLACK')) or r.skill_rating is null)) then
    raise exception 'The booked roster must fit the saved game format and have valid rating snapshots.' using errcode = '22023';
  end if;
  select jsonb_object_agg(b.profile_id::text, b.team),
    jsonb_agg(jsonb_build_object('booking_id', b.id, 'profile_id', b.profile_id, 'team', b.team,
      'role', b.role, 'rating_at_team_assignment', b.rating_at_team_assignment) order by b.profile_id)
    into final_teams, before_roster from public.open_queue_bookings b where b.game_id = g.id and b.status = 'CONFIRMED';
  for assignment in select value from jsonb_array_elements(moves) loop
    final_teams := jsonb_set(final_teams, array[assignment->>'profile_id'], assignment->'to_team');
  end loop;
  if exists(select 1 from public.open_queue_bookings b where b.game_id = g.id and b.status = 'CONFIRMED'
    and (final_teams->>b.profile_id::text is null or final_teams->>b.profile_id::text not in ('WHITE', 'BLACK'))) then
    raise exception 'Choose a team for every unassigned player before saving.' using errcode = '22023';
  end if;
  foreach team_to_check in array array['WHITE', 'BLACK'] loop
    select count(*) into actual_count from public.open_queue_bookings b where b.game_id = g.id
      and b.status = 'CONFIRMED' and final_teams->>b.profile_id::text = team_to_check;
    if actual_count > g.capacity / 2 then
      raise exception 'Each team must fit the saved game capacity.' using errcode = '22023';
    end if;
    for quota in select * from (values ('GK', g.goalkeeper_capacity / 2), ('DEF', g.defender_capacity / 2),
      ('MID', g.midfielder_capacity / 2), ('ATT', g.attacker_capacity / 2)) q(role, capacity) loop
      select count(*) into actual_count from public.open_queue_bookings b where b.game_id = g.id and b.status = 'CONFIRMED'
        and final_teams->>b.profile_id::text = team_to_check and b.role = quota.role;
      if quota.capacity is null or actual_count > quota.capacity or (total_booked = g.capacity and actual_count <> quota.capacity) then
        raise exception 'Placement must preserve the saved position quotas on both teams.' using errcode = '22023';
      end if;
    end loop;
  end loop;
  if exists(select 1 from public.open_queue_parties p join public.open_queue_party_members m
    on m.party_id = p.id and m.game_id = p.game_id and m.status = 'ACCEPTED'
    join public.open_queue_bookings b on b.game_id = m.game_id and b.profile_id = m.profile_id and b.status = 'CONFIRMED'
    where p.game_id = g.id and p.status = 'ACTIVE'
    group by p.id having count(distinct final_teams->>b.profile_id::text) > 1) then
    raise exception 'Accepted parties must stay together after placement.' using errcode = '22023';
  end if;
  recorded := clock_timestamp();
  -- Update only the selected unassigned bookings, preserving all other players'
  -- existing team, role, original SR snapshot, check-in and playing-time fields.
  update public.open_queue_bookings b set team = final_teams->>b.profile_id::text, rating_at_team_assignment = r.skill_rating
    from public.fieldrush_player_rating_tracks r where b.game_id = g.id and b.status = 'CONFIRMED'
      and b.profile_id = any(seen_players) and b.team is null
      and r.profile_id = b.profile_id and r.rating_track = public.fieldrush_rating_track(b.role);
  select avg(coalesce(b.rating_at_team_assignment, r.skill_rating)) filter(where b.team = 'WHITE'),
    avg(coalesce(b.rating_at_team_assignment, r.skill_rating)) filter(where b.team = 'BLACK'),
    avg(coalesce(b.rating_at_team_assignment, r.skill_rating)),
    jsonb_agg(jsonb_build_object('booking_id', b.id, 'profile_id', b.profile_id, 'team', b.team,
      'role', b.role, 'rating_at_team_assignment', b.rating_at_team_assignment) order by b.profile_id)
    into white_average, black_average, overall_average, after_roster
    from public.open_queue_bookings b join public.fieldrush_player_rating_tracks r
      on r.profile_id = b.profile_id and r.rating_track = public.fieldrush_rating_track(b.role)
    where b.game_id = g.id and b.status = 'CONFIRMED';
  update public.open_queue_games set teams_assigned_at = coalesce(g.teams_assigned_at, recorded),
    white_average_sr = round(white_average, 2), black_average_sr = round(black_average, 2),
    match_average_sr = round(overall_average, 2), team_sr_spread = round(abs(white_average - black_average), 2)
    where id = g.id;
  response := jsonb_build_object('game_id', g.id, 'request_id', request_id_to_use, 'action', 'ASSIGN_UNASSIGNED',
    'assigned_count', jsonb_array_length(moves), 'recorded_at', recorded, 'actor_id', actor_admin_id, 'roster', after_roster);
  insert into public.admin_audit_events(actor_referee_id, action, entity_type, entity_id, reason, before_state, after_state)
    values(actor_admin_id, 'OPEN_QUEUE_UNASSIGNED_PLAYERS_PLACED', 'SOLO_MATCH', g.id, assignment_reason,
      jsonb_build_object('roster', before_roster), response);
  insert into fieldrush_rating_private.season_zero_action_requests(request_id, game_id, actor_id, input, response)
    values(request_id_to_use, g.id, actor_admin_id, request_input, response);
  -- Normal deferred game-notice triggers publish the final committed teams.
  return response;
end;
$$;

revoke all on function public.admin_assign_unassigned_open_queue_players(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.admin_assign_unassigned_open_queue_players(uuid, uuid, uuid, jsonb)
  to service_role;
notify pgrst, 'reload schema';
