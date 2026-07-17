-- Preserve the three-hour player-facing team reveal while allowing an active
-- administrator to deliberately start an assigned test match early. The
-- override is transaction-local, game-specific, and permanently audited.

do $migration$
declare
  function_definition text;
  old_guard text := $old$  if clock_timestamp() < public.open_queue_team_assignment_at(game_id_to_assign) then
    return;
  end if;
$old$;
  new_guard text := $new$  if clock_timestamp() < public.open_queue_team_assignment_at(game_id_to_assign)
    and nullif(
      current_setting('field.force_open_queue_team_assignment', true),
      ''
    ) is distinct from game_id_to_assign::text
  then
    return;
  end if;
$new$;
begin
  select pg_get_functiondef(
    'public.assign_open_queue_teams(uuid)'::regprocedure
  ) into function_definition;

  if position(new_guard in function_definition) = 0 then
    if position(old_guard in function_definition) = 0 then
      raise exception 'Could not locate the Open Queue team reveal guard.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;
end;
$migration$;

create or replace function public.admin_force_assign_open_queue_teams(
  actor_admin_id uuid,
  game_id_to_assign uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  game_before public.open_queue_games%rowtype;
  game_after public.open_queue_games%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Record a clear 10 to 1,000 character reason.';
  end if;

  select * into game_before
  from public.open_queue_games game
  where game.id = game_id_to_assign
  for update;

  if game_before.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_before.status <> 'FULL' then
    raise exception 'A solo game must be full before it can start.';
  end if;

  if game_before.teams_assigned_at is not null
    and not exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = game_before.id
        and booking.status = 'CONFIRMED'
        and booking.team is null
    )
  then
    return jsonb_build_object(
      'game_id', game_before.id,
      'teams_assigned_at', game_before.teams_assigned_at,
      'idempotent', true
    );
  end if;

  perform set_config(
    'field.force_open_queue_team_assignment',
    game_before.id::text,
    true
  );
  perform public.assign_open_queue_teams(game_before.id);

  select * into game_after
  from public.open_queue_games game
  where game.id = game_before.id;

  if game_after.teams_assigned_at is null
    or exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = game_before.id
        and booking.status = 'CONFIRMED'
        and booking.team is null
    )
  then
    raise exception 'Could not assign both solo teams for the early start.';
  end if;

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state
  ) values (
    actor_admin_id,
    'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY',
    'SOLO_MATCH',
    game_before.id,
    normalized_reason,
    jsonb_build_object(
      'status', game_before.status,
      'starts_at', game_before.starts_at,
      'teams_assigned_at', game_before.teams_assigned_at,
      'white_average_sr', game_before.white_average_sr,
      'black_average_sr', game_before.black_average_sr
    ),
    jsonb_build_object(
      'status', game_after.status,
      'starts_at', game_after.starts_at,
      'teams_assigned_at', game_after.teams_assigned_at,
      'white_average_sr', game_after.white_average_sr,
      'black_average_sr', game_after.black_average_sr,
      'source', 'REFEREE_CONSOLE_EARLY_START'
    )
  );

  return jsonb_build_object(
    'game_id', game_after.id,
    'teams_assigned_at', game_after.teams_assigned_at,
    'idempotent', false
  );
end;
$$;

revoke all on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) to service_role;

comment on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) is
'Allows an active admin to assign a full solo game early for a deliberate referee-console test start while preserving the ordinary three-hour reveal and an immutable admin audit record.';
