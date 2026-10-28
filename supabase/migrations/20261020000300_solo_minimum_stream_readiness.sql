-- A partly booked solo match may prepare its camera once its saved playing
-- minimum and real team assignment are ready. Capacity still means FULL.
-- The same server predicate protects preparation, reservation and command claim.
create function fieldrush_rating_private.solo_stream_ready(
  game_id_to_use uuid, at_time_to_use timestamptz
) returns boolean language plpgsql stable security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
declare
  game public.open_queue_games%rowtype;
  booked integer; white_count integer; black_count integer; minimum_to_use integer;
begin
  select * into game from public.open_queue_games where id=game_id_to_use;
  if game.id is null or game.operational_state is distinct from 'NORMAL' then return false; end if;
  if game.rating_policy_id='LEGACY' then return game.status in ('FULL','LIVE'); end if;
  if game.rating_policy_id is distinct from 'field-sr-season0-v2' then return false; end if;
  if game.status='LIVE' then
    -- Keep the camera usable during a player-count pause; the referee's match
    -- clock, rather than the stream, enforces the participation threshold.
    return exists(select 1 from fieldrush_rating_private.season_zero_matches
      where game_id=game.id and lifecycle='LIVE');
  end if;
  if game.status not in ('OPEN','FULL') or game.teams_assigned_at is null
    or not fieldrush_rating_private.solo_start_window_allows(game.starts_at,at_time_to_use)
  then return false; end if;
  select count(*)::integer,count(*) filter(where team='WHITE')::integer,
    count(*) filter(where team='BLACK')::integer
    into booked,white_count,black_count
    from public.open_queue_bookings where game_id=game.id and status='CONFIRMED';
  if white_count+black_count<>booked or booked>game.capacity then return false; end if;
  if game.participation_rules_version='s0-configurable-v1' then
    minimum_to_use:=game.minimum_players;
    return minimum_to_use between 2 and game.capacity and booked>=minimum_to_use
      and white_count between 1 and 7 and black_count between 1 and 7;
  elsif game.participation_rules_version='s0-standard-v1' then
    return white_count between 5 and 7 and black_count between 5 and 7;
  end if;
  return false;
end;
$$;
revoke all on function fieldrush_rating_private.solo_stream_ready(uuid,timestamptz)
  from public,anon,authenticated,service_role;

create function public.solo_game_stream_ready(game_id_to_use uuid)
returns boolean language sql volatile security definer
set search_path=public,fieldrush_rating_private,pg_temp as $$
  select fieldrush_rating_private.solo_stream_ready(game_id_to_use,clock_timestamp());
$$;
revoke all on function public.solo_game_stream_ready(uuid) from public,anon,authenticated;
grant execute on function public.solo_game_stream_ready(uuid) to service_role;

do $migration$
declare definition text;
  old_guard text := $old$  if (kind='SOLO' and context->>'matchStatus' not in ('FULL','LIVE')) or
     (kind='CLAN' and context->>'matchStatus' not in ('SCHEDULED','LIVE')) then raise exception 'This match is not ready to stream.'; end if;$old$;
  new_guard text := $new$  if kind='SOLO' then
    -- Booking writers lock this row too. A cancellation cannot invalidate the
    -- minimum between this check and the atomic stream reservation.
    perform 1 from public.open_queue_games where id=target_id for share;
    if not public.solo_game_stream_ready(target_id) then
      raise exception 'Assign teams and reach this game''s minimum within its start window before streaming.';
    end if;
  elsif context->>'matchStatus' not in ('SCHEDULED','LIVE') then
    raise exception 'This match is not ready to stream.';
  end if;$new$;
begin
  definition:=pg_get_functiondef('public.reserve_broadcast_start(uuid,text,uuid)'::regprocedure);
  if position(old_guard in definition)=0 then raise exception 'Broadcast reservation readiness contract changed.'; end if;
  execute replace(definition,old_guard,new_guard);
end;
$migration$;
notify pgrst,'reload schema';
