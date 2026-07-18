-- Standalone rollback verification for
-- 20260715000006_add_solo_margin_sr.sql. No verification data is retained.

begin;

do $$
declare
  player_ids uuid[];
  game_starts timestamptz[];
  three_goal_game_id uuid;
  two_goal_game_id uuid;
  history_payload jsonb;
  history_event jsonb;
  negative_margin_rejected boolean := false;
begin
  if public.calculate_open_queue_margin_multiplier(0) <> 1.00
    or public.calculate_open_queue_margin_multiplier(2) <> 1.00
    or public.calculate_open_queue_margin_multiplier(3) <> 1.10
    or public.calculate_open_queue_margin_multiplier(4) <> 1.15
    or public.calculate_open_queue_margin_multiplier(5) <> 1.20
    or public.calculate_open_queue_margin_multiplier(99) <> 1.20
  then
    raise exception 'Solo goal-margin multiplier tiers are incorrect.';
  end if;

  if public.calculate_open_queue_margin_bonus(12, 1.00) <> 0
    or public.calculate_open_queue_margin_bonus(12, 1.10) <> 1
    or public.calculate_open_queue_margin_bonus(12, 1.15) <> 2
    or public.calculate_open_queue_margin_bonus(12, 1.20) <> 2
    or public.calculate_open_queue_margin_bonus(32, 1.20) <> 6
  then
    raise exception 'Solo goal-margin whole-point bonus or cap is incorrect.';
  end if;

  begin
    perform public.calculate_open_queue_margin_multiplier(-1);
  exception when others then
    if position('non-negative' in lower(sqlerrm)) > 0 then
      negative_margin_rejected := true;
    else
      raise;
    end if;
  end;
  if not negative_margin_rejected then
    raise exception 'Negative goal margins were not rejected.';
  end if;

  -- Migration safety: historical V1 and clan events must not be backfilled or
  -- recalculated by this change.
  if exists (
    select 1
    from public.player_rating_events event
    where event.calculation_version = 'PLAYER_ELO_V1'
      and (
        event.score_margin is not null
        or event.margin_multiplier is not null
        or event.base_rating_change is not null
        or event.margin_bonus_before_clamp is not null
        or event.margin_bonus_applied is not null
      )
  ) then
    raise exception 'Historical Player SR events were changed retroactively.';
  end if;

  select array_agg(candidate.profile_id order by candidate.profile_id)
  into player_ids
  from (
    select profile.id as profile_id
    from public.profiles profile
    where not public.profile_has_active_play_restriction(profile.id)
      and (
      select count(*)
      from public.open_queue_bookings booking
      join public.open_queue_games game on game.id = booking.game_id
      where booking.profile_id = profile.id
        and booking.status = 'CONFIRMED'
        and game.status in ('OPEN', 'FULL')
        and game.starts_at > now()
    ) < 2
    order by profile.id
    limit 12
  ) candidate;

  if coalesce(cardinality(player_ids), 0) <> 12 then
    raise exception 'Margin SR verification needs 12 bookable profiles.';
  end if;

  select array_agg(candidate.starts_at order by candidate.starts_at)
  into game_starts
  from (
    select
      ((day_to_use::date + time '20:30') at time zone 'Asia/Bahrain')
        as starts_at
    from generate_series(
      current_date + interval '400 days',
      current_date + interval '520 days',
      interval '1 day'
    ) candidate_day(day_to_use)
    where extract(isodow from day_to_use) in (2, 5)
      and not exists (
        select 1
        from public.open_queue_games game
        where game.starts_at =
          ((day_to_use::date + time '20:30') at time zone 'Asia/Bahrain')
          and game.status <> 'CANCELLED'
      )
    order by day_to_use
    limit 2
  ) candidate;

  if coalesce(cardinality(game_starts), 0) <> 2 then
    raise exception 'Margin SR verification needs two unused solo schedule slots.';
  end if;

  -- Equal ratings make the expected base change exactly +12/-12. Resetting
  -- inside this rollback-only transaction also ensures neither safety clamp is
  -- involved in the symmetry assertion below.
  update public.player_ratings
  set skill_rating = 1200, last_change = 0
  where profile_id = any(player_ids);

  insert into public.open_queue_games (
    status,
    venue,
    starts_at,
    ends_at,
    timezone,
    created_by
  ) values (
    'OPEN',
    'Margin SR rollback verification A',
    game_starts[1],
    game_starts[1] + interval '1 hour',
    'Asia/Bahrain',
    player_ids[1]
  ) returning id into three_goal_game_id;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    base_amount_fils,
    payment_method,
    payment_status
  )
  select
    three_goal_game_id,
    player.profile_id,
    case
      when player.position <= 2 then 'GK'
      when player.position <= 6 then 'DEF'
      when player.position <= 10 then 'MID'
      else 'ATT'
    end,
    1200,
    3000,
    3000,
    'MOCK',
    'PAID'
  from unnest(player_ids) with ordinality
    as player(profile_id, position);

  perform public.referee_start_open_queue_game(
    three_goal_game_id,
    player_ids,
    3600
  );

  update public.open_queue_games
  set status = 'FINAL', white_score = 3, black_score = 0
  where id = three_goal_game_id;

  if (
    select count(*)
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = three_goal_game_id
      and event.calculation_version = 'PLAYER_ELO_V2_MARGIN'
      and event.score_margin = 3
      and event.margin_multiplier = 1.10
      and event.base_rating_change in (-12, 12)
      and event.margin_bonus_before_clamp in (-1, 1)
      and event.margin_bonus_applied = event.margin_bonus_before_clamp
      and event.rating_change = event.base_rating_change
        + event.margin_bonus_applied
  ) <> 12 then
    raise exception 'Three-goal Player SR events do not have the expected V2 audit data.';
  end if;

  if (
    select coalesce(sum(event.margin_bonus_before_clamp), 0)
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = three_goal_game_id
  ) <> 0 or (
    select coalesce(sum(event.margin_bonus_applied), 0)
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = three_goal_game_id
  ) <> 0 then
    raise exception 'The unclamped solo margin component is not zero-sum.';
  end if;

  -- A second integration match proves that a two-goal result stays on the V1
  -- base calculation even though its event is versioned and auditable as V2.
  update public.player_ratings
  set skill_rating = 1200, last_change = 0
  where profile_id = any(player_ids);

  insert into public.open_queue_games (
    status,
    venue,
    starts_at,
    ends_at,
    timezone,
    created_by
  ) values (
    'OPEN',
    'Margin SR rollback verification B',
    game_starts[2],
    game_starts[2] + interval '1 hour',
    'Asia/Bahrain',
    player_ids[1]
  ) returning id into two_goal_game_id;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    base_amount_fils,
    payment_method,
    payment_status
  )
  select
    two_goal_game_id,
    player.profile_id,
    case
      when player.position <= 2 then 'GK'
      when player.position <= 6 then 'DEF'
      when player.position <= 10 then 'MID'
      else 'ATT'
    end,
    1200,
    3000,
    3000,
    'MOCK',
    'PAID'
  from unnest(player_ids) with ordinality
    as player(profile_id, position);

  perform public.referee_start_open_queue_game(
    two_goal_game_id,
    player_ids,
    3600
  );

  update public.open_queue_games
  set status = 'FINAL', white_score = 2, black_score = 0
  where id = two_goal_game_id;

  if (
    select count(*)
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = two_goal_game_id
      and event.calculation_version = 'PLAYER_ELO_V2_MARGIN'
      and event.score_margin = 2
      and event.margin_multiplier = 1.00
      and event.margin_bonus_before_clamp = 0
      and event.margin_bonus_applied = 0
      and event.rating_change = event.base_rating_change
  ) <> 12 then
    raise exception 'A two-goal result incorrectly received a Player SR margin bonus.';
  end if;

  perform set_config('request.jwt.claim.sub', player_ids[1]::text, true);
  history_payload := public.get_player_rating_history(player_ids[1], 100);
  select history_item.value
  into history_event
  from jsonb_array_elements(history_payload -> 'events') history_item(value)
  where history_item.value ->> 'source_id' = three_goal_game_id::text
  limit 1;

  if history_event is null
    or history_event ->> 'calculation_version' <> 'PLAYER_ELO_V2_MARGIN'
    or (history_event ->> 'score_margin')::integer <> 3
    or (history_event ->> 'margin_multiplier')::numeric <> 1.10
    or not (history_event ? 'base_rating_change')
    or not (history_event ? 'margin_bonus_before_clamp')
    or not (history_event ? 'margin_bonus_applied')
  then
    raise exception 'Player rating history does not expose the margin audit fields.';
  end if;
end;
$$;

rollback;
