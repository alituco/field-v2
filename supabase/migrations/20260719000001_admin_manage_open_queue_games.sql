create or replace function public.admin_create_open_queue_game(
  actor_admin_id uuid,
  venue_to_use text,
  starts_at_to_use timestamptz,
  price_fils_to_use integer,
  age_label_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  created_game public.open_queue_games%rowtype;
  normalized_venue text := trim(coalesce(venue_to_use, ''));
  normalized_age_label text := trim(coalesce(age_label_to_use, ''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin referee access required.';
  end if;

  if char_length(normalized_venue) not between 2 and 80 then
    raise exception 'Venue must be between 2 and 80 characters.';
  end if;
  if char_length(normalized_age_label) not between 2 and 40 then
    raise exception 'Age label must be between 2 and 40 characters.';
  end if;
  if starts_at_to_use is null or starts_at_to_use <= now() then
    raise exception 'The solo game must be scheduled in the future.';
  end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 then
    raise exception 'Price must be between 0 and 100 BHD.';
  end if;

  insert into public.open_queue_games (
    status,
    venue,
    starts_at,
    ends_at,
    timezone,
    price_fils,
    age_label,
    created_by
  ) values (
    'OPEN',
    normalized_venue,
    starts_at_to_use,
    starts_at_to_use + interval '1 hour',
    'Asia/Bahrain',
    price_fils_to_use,
    normalized_age_label,
    actor_admin_id
  )
  returning * into created_game;

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
    'SOLO_GAME_CREATED',
    'SOLO_MATCH',
    created_game.id,
    'Admin created a scheduled solo queue game.',
    '{}'::jsonb,
    to_jsonb(created_game)
  );

  return created_game.id;
end;
$$;

create or replace function public.admin_remove_empty_open_queue_game(
  actor_admin_id uuid,
  game_id_to_remove uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  game_to_remove public.open_queue_games%rowtype;
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  removed_state jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin referee access required.';
  end if;
  if char_length(normalized_reason) not between 8 and 1000 then
    raise exception 'Removal reason must be between 8 and 1000 characters.';
  end if;

  select *
  into game_to_remove
  from public.open_queue_games
  where id = game_id_to_remove
  for update;

  if game_to_remove.id is null then
    raise exception 'Solo game not found.';
  end if;
  if game_to_remove.status is distinct from 'OPEN' then
    raise exception 'Only an open solo game can be removed. Cancel this game instead.';
  end if;
  if game_to_remove.starts_at <= now() then
    raise exception 'A started or past game cannot be removed. Cancel it instead.';
  end if;
  if exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_to_remove.id
  ) then
    raise exception 'This game has booking history. Cancel it instead so refunds and records are preserved.';
  end if;
  if exists (
    select 1
    from public.match_attendance_records attendance
    where attendance.open_queue_game_id = game_to_remove.id
  ) or exists (
    select 1
    from public.match_reliability_terms terms
    where terms.open_queue_game_id = game_to_remove.id
  ) then
    raise exception 'This game has matchday history. Cancel it instead so the audit record is preserved.';
  end if;

  removed_state := to_jsonb(game_to_remove);

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
    'EMPTY_SOLO_GAME_REMOVED',
    'SOLO_MATCH',
    game_to_remove.id,
    normalized_reason,
    removed_state,
    jsonb_build_object('removed', true)
  );

  delete from public.open_queue_games
  where id = game_to_remove.id;

  return removed_state;
end;
$$;

revoke all on function public.admin_create_open_queue_game(
  uuid,text,timestamptz,integer,text
) from public, anon, authenticated;
grant execute on function public.admin_create_open_queue_game(
  uuid,text,timestamptz,integer,text
) to service_role;

revoke all on function public.admin_remove_empty_open_queue_game(
  uuid,uuid,text
) from public, anon, authenticated;
grant execute on function public.admin_remove_empty_open_queue_game(
  uuid,uuid,text
) to service_role;

comment on function public.admin_create_open_queue_game(
  uuid,text,timestamptz,integer,text
) is 'Creates one audited permanent-schedule solo game from the referee admin panel.';

comment on function public.admin_remove_empty_open_queue_game(
  uuid,uuid,text
) is 'Removes only a pristine future solo game and keeps a permanent admin audit event.';
