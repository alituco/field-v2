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
  if exists(select 1 from fieldrush_rating_private.season_zero_action_requests where request_id = request_id_to_use) then
    response := public.referee_rebalance_season_zero_match(
      actor_admin_id, game_id_to_use, request_id_to_use, moves, assignment_reason
    );
    return response || jsonb_build_object('action', 'ASSIGN_UNASSIGNED', 'assigned_count', jsonb_array_length(moves));
  end if;
  perform id from public.open_queue_games where id = game_id_to_use for update;
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

  -- The existing operation checks pre-kickoff state, every final team, saved
  -- position quotas and accepted parties, then records audit and notifications.
  response := public.referee_rebalance_season_zero_match(
    actor_admin_id, game_id_to_use, request_id_to_use, moves, assignment_reason
  );
  return response || jsonb_build_object('action', 'ASSIGN_UNASSIGNED', 'assigned_count', jsonb_array_length(moves));
end;
$$;

revoke all on function public.admin_assign_unassigned_open_queue_players(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.admin_assign_unassigned_open_queue_players(uuid, uuid, uuid, jsonb)
  to service_role;
notify pgrst, 'reload schema';
