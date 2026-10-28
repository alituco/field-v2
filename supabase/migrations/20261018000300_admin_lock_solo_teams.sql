-- Release a full roster without starting the clock or manufacturing attendance.
create function public.admin_lock_open_queue_teams(actor_admin_id uuid, game_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare g public.open_queue_games%rowtype; assigned_at timestamptz;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.id is null then raise exception 'Game not found.'; end if;
  if g.status <> 'FULL' or g.operational_state <> 'NORMAL' then
    raise exception 'Only a full game with no active review can lock teams.';
  end if;
  if (select count(*) from public.open_queue_bookings where game_id=g.id and status='CONFIRMED') <> g.capacity then
    raise exception 'Every place must be booked before locking teams.';
  end if;
  if g.teams_assigned_at is not null and not exists(
    select 1 from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and team is null
  ) then return jsonb_build_object('teamsAssignedAt',g.teams_assigned_at,'alreadyLocked',true); end if;
  perform set_config('field.force_open_queue_team_assignment',g.id::text,true);
  perform public.assign_open_queue_teams(g.id);
  select teams_assigned_at into assigned_at from public.open_queue_games where id=g.id;
  if assigned_at is null or exists(select 1 from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and team is null) then
    raise exception 'Could not assign both teams.';
  end if;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'OPEN_QUEUE_TEAMS_LOCKED','SOLO_MATCH',g.id,
    'Administrator locked the full roster from the game detail page.',
    jsonb_build_object('teams_assigned_at',g.teams_assigned_at),
    jsonb_build_object('teams_assigned_at',assigned_at));
  return jsonb_build_object('teamsAssignedAt',assigned_at,'alreadyLocked',false);
end;
$$;
revoke all on function public.admin_lock_open_queue_teams(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_lock_open_queue_teams(uuid,uuid) to service_role;
