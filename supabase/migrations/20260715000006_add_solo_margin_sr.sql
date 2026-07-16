-- Give decisive Open Queue wins a conservative, bounded Player SR margin
-- bonus. Existing ledger rows are intentionally left untouched.

alter table public.player_rating_events
add column if not exists score_margin integer,
add column if not exists margin_multiplier numeric(4, 2),
add column if not exists base_rating_change integer,
add column if not exists margin_bonus_before_clamp integer,
add column if not exists margin_bonus_applied integer;

alter table public.player_rating_events
drop constraint if exists player_rating_events_score_margin_check;
alter table public.player_rating_events
add constraint player_rating_events_score_margin_check
check (score_margin is null or score_margin >= 0);

alter table public.player_rating_events
drop constraint if exists player_rating_events_margin_multiplier_check;
alter table public.player_rating_events
add constraint player_rating_events_margin_multiplier_check
check (
  margin_multiplier is null
  or margin_multiplier between 1.00 and 1.20
);

alter table public.player_rating_events
drop constraint if exists player_rating_events_base_rating_change_check;
alter table public.player_rating_events
add constraint player_rating_events_base_rating_change_check
check (
  base_rating_change is null
  or base_rating_change between -32 and 32
);

alter table public.player_rating_events
drop constraint if exists player_rating_events_margin_bonus_before_clamp_check;
alter table public.player_rating_events
add constraint player_rating_events_margin_bonus_before_clamp_check
check (
  margin_bonus_before_clamp is null
  or margin_bonus_before_clamp between -6 and 6
);

alter table public.player_rating_events
drop constraint if exists player_rating_events_margin_bonus_applied_check;
alter table public.player_rating_events
add constraint player_rating_events_margin_bonus_applied_check
check (
  margin_bonus_applied is null
  or margin_bonus_applied between -6 and 6
);

comment on column public.player_rating_events.score_margin is
  'Absolute official goal difference used when this immutable SR event was applied.';
comment on column public.player_rating_events.margin_multiplier is
  'Open Queue margin tier used at application time: 1.00, 1.10, 1.15, or capped at 1.20.';
comment on column public.player_rating_events.base_rating_change is
  'PLAYER_ELO_V1-compatible change before the Open Queue score-margin bonus.';
comment on column public.player_rating_events.margin_bonus_before_clamp is
  'Signed margin bonus requested before the existing +/-32 Player SR clamp.';
comment on column public.player_rating_events.margin_bonus_applied is
  'Signed margin bonus actually realized after the +/-32 clamp and zero-rating floor.';

create or replace function public.calculate_open_queue_margin_multiplier(
  goal_difference_to_use integer
)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
begin
  if goal_difference_to_use is null or goal_difference_to_use < 0 then
    raise exception 'A non-negative goal difference is required.';
  end if;

  return case
    when goal_difference_to_use <= 2 then 1.00::numeric
    when goal_difference_to_use = 3 then 1.10::numeric
    when goal_difference_to_use = 4 then 1.15::numeric
    else 1.20::numeric
  end;
end;
$$;

create or replace function public.calculate_open_queue_margin_bonus(
  team_reference_change_to_use integer,
  margin_multiplier_to_use numeric
)
returns integer
language plpgsql
immutable
set search_path = public
as $$
begin
  if team_reference_change_to_use is null
    or team_reference_change_to_use not between -32 and 32
  then
    raise exception 'A team reference change between -32 and 32 is required.';
  end if;

  if margin_multiplier_to_use is null
    or margin_multiplier_to_use < 1.00
    or margin_multiplier_to_use > 1.20
  then
    raise exception 'A margin multiplier between 1.00 and 1.20 is required.';
  end if;

  if margin_multiplier_to_use = 1.00 then
    return 0;
  end if;

  -- The explicit six-point ceiling is also bounded later by the established
  -- +/-32 total Player SR clamp.
  return least(
    6,
    greatest(
      1,
      round(
        abs(team_reference_change_to_use)
        * (margin_multiplier_to_use - 1)
      )::integer
    )
  );
end;
$$;

create or replace function public.apply_open_queue_player_ratings(
  game_id_to_apply uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  game_to_apply public.open_queue_games%rowtype;
  participant record;
  team_average numeric;
  opponent_average numeric;
  white_average numeric;
  black_average numeric;
  expected_score_to_use numeric;
  actual_score_to_use numeric;
  base_change integer;
  bounded_change integer;
  applied_change integer;
  base_applied_change integer;
  applied_margin_bonus integer;
  current_rating integer;
  next_rating integer;
  result_to_use text;
  white_result text;
  score_margin_to_use integer;
  margin_multiplier_to_use numeric;
  margin_reference_change integer;
  margin_bonus_magnitude integer := 0;
  margin_bonus_to_use integer;
  inserted_event uuid;
  applied_count integer := 0;
begin
  select * into game_to_apply
  from public.open_queue_games
  where id = game_id_to_apply
  for update;

  if game_to_apply.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_apply.status <> 'FINAL' then
    raise exception 'Player SR can only be applied to a final Open Queue game.';
  end if;

  if game_to_apply.white_score is null or game_to_apply.black_score is null then
    raise exception 'A final score is required before Player SR can be applied.';
  end if;

  if not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_apply
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'WHITE'
      and booking.rating_at_match_start is not null
  ) or not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_apply
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'BLACK'
      and booking.rating_at_match_start is not null
  ) then
    raise exception 'Both teams need a confirmed SR lineup before finalizing.';
  end if;

  insert into public.player_ratings (profile_id)
  select booking.profile_id
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_apply
    and booking.status = 'CONFIRMED'
    and booking.played
  on conflict (profile_id) do nothing;

  perform rating.profile_id
  from public.player_ratings rating
  join public.open_queue_bookings booking
    on booking.profile_id = rating.profile_id
  where booking.game_id = game_id_to_apply
    and booking.status = 'CONFIRMED'
    and booking.played
  order by rating.profile_id
  for update of rating;

  select
    avg(booking.rating_at_match_start) filter (
      where booking.team = 'WHITE'
    ),
    avg(booking.rating_at_match_start) filter (
      where booking.team = 'BLACK'
    )
  into white_average, black_average
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_apply
    and booking.status = 'CONFIRMED'
    and booking.played;

  score_margin_to_use := abs(
    game_to_apply.white_score - game_to_apply.black_score
  );
  margin_multiplier_to_use :=
    public.calculate_open_queue_margin_multiplier(score_margin_to_use);

  -- The margin component is deliberately team-based: every winner receives
  -- the same small addition and every loser receives the corresponding
  -- subtraction. This keeps the margin component zero-sum for the normal
  -- equal-sided lineup, except where the existing +/-32 or zero floor clamps.
  if margin_multiplier_to_use > 1 then
    white_result := case
      when game_to_apply.white_score > game_to_apply.black_score then 'WIN'
      when game_to_apply.white_score < game_to_apply.black_score then 'LOSS'
      else 'DRAW'
    end;

    select calculation.rating_change
    into margin_reference_change
    from public.calculate_player_sr_change(
      round(white_average)::integer,
      black_average,
      white_result
    ) calculation;

    margin_bonus_magnitude := public.calculate_open_queue_margin_bonus(
      margin_reference_change,
      margin_multiplier_to_use
    );
  end if;

  for participant in
    select booking.*
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_apply
      and booking.status = 'CONFIRMED'
      and booking.played
    order by booking.profile_id
  loop
    select skill_rating into current_rating
    from public.player_ratings
    where profile_id = participant.profile_id;

    select avg(teammate.rating_at_match_start)::numeric
    into team_average
    from public.open_queue_bookings teammate
    where teammate.game_id = game_id_to_apply
      and teammate.status = 'CONFIRMED'
      and teammate.played
      and teammate.team = participant.team;

    select avg(opponent.rating_at_match_start)::numeric
    into opponent_average
    from public.open_queue_bookings opponent
    where opponent.game_id = game_id_to_apply
      and opponent.status = 'CONFIRMED'
      and opponent.played
      and opponent.team <> participant.team;

    if game_to_apply.white_score = game_to_apply.black_score then
      result_to_use := 'DRAW';
    elsif
      (participant.team = 'WHITE'
        and game_to_apply.white_score > game_to_apply.black_score)
      or (participant.team = 'BLACK'
        and game_to_apply.black_score > game_to_apply.white_score)
    then
      result_to_use := 'WIN';
    else
      result_to_use := 'LOSS';
    end if;

    select
      calculation.expected_score,
      calculation.actual_score,
      calculation.rating_change
    into
      expected_score_to_use,
      actual_score_to_use,
      base_change
    from public.calculate_player_sr_change(
      participant.rating_at_match_start,
      opponent_average,
      result_to_use
    ) calculation;

    margin_bonus_to_use := case result_to_use
      when 'WIN' then margin_bonus_magnitude
      when 'LOSS' then -margin_bonus_magnitude
      else 0
    end;

    -- Preserve the existing Player SR safety bound after adding the new layer.
    bounded_change := greatest(
      -32,
      least(32, base_change + margin_bonus_to_use)
    );
    next_rating := greatest(0, current_rating + bounded_change);
    applied_change := next_rating - current_rating;
    base_applied_change := greatest(0, current_rating + base_change)
      - current_rating;
    applied_margin_bonus := applied_change - base_applied_change;
    inserted_event := null;

    insert into public.player_rating_events (
      profile_id,
      source_type,
      source_id,
      side,
      result,
      rating_before,
      rating_change,
      rating_after,
      effective_at,
      rating_at_match_start,
      team_average_rating,
      opponent_average_rating,
      expected_score,
      actual_score,
      calculation_version,
      score_margin,
      margin_multiplier,
      base_rating_change,
      margin_bonus_before_clamp,
      margin_bonus_applied
    ) values (
      participant.profile_id,
      'OPEN_QUEUE',
      game_to_apply.id,
      participant.team,
      result_to_use,
      current_rating,
      applied_change,
      next_rating,
      game_to_apply.starts_at,
      participant.rating_at_match_start,
      round(team_average, 2),
      round(opponent_average, 2),
      round(expected_score_to_use, 6),
      actual_score_to_use,
      'PLAYER_ELO_V2_MARGIN',
      score_margin_to_use,
      margin_multiplier_to_use,
      base_change,
      margin_bonus_to_use,
      applied_margin_bonus
    )
    on conflict (source_type, source_id, profile_id) do nothing
    returning id into inserted_event;

    if inserted_event is not null then
      update public.player_ratings
      set
        skill_rating = next_rating,
        matches_played = matches_played + 1,
        wins = wins + case when result_to_use = 'WIN' then 1 else 0 end,
        losses = losses + case when result_to_use = 'LOSS' then 1 else 0 end,
        draws = draws + case when result_to_use = 'DRAW' then 1 else 0 end,
        last_change = applied_change
      where profile_id = participant.profile_id;

      update public.open_queue_bookings
      set rating_change = applied_change
      where id = participant.id;

      applied_count := applied_count + 1;
    end if;
  end loop;

  update public.open_queue_bookings booking
  set rating_change = event.rating_change
  from public.player_rating_events event
  where booking.game_id = game_id_to_apply
    and booking.profile_id = event.profile_id
    and event.source_type = 'OPEN_QUEUE'
    and event.source_id = game_id_to_apply;

  return applied_count;
end;
$$;

create or replace function public.get_player_rating_history(
  profile_id_to_use uuid,
  limit_to_use integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  safe_limit integer := greatest(1, least(100, coalesce(limit_to_use, 50)));
  summary jsonb;
  history jsonb;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  select jsonb_build_object(
    'profile_id', profile.id,
    'display_name', profile.display_name,
    'username', profile.username,
    'avatar_url', profile.avatar_url,
    'skill_rating', coalesce(rating.skill_rating, 1200),
    'matches_played', coalesce(rating.matches_played, 0),
    'wins', coalesce(rating.wins, 0),
    'losses', coalesce(rating.losses, 0),
    'draws', coalesce(rating.draws, 0),
    'last_change', coalesce(rating.last_change, 0),
    'region', coalesce(rating.region, 'bahrain')
  )
  into summary
  from public.profiles profile
  left join public.player_ratings rating on rating.profile_id = profile.id
  where profile.id = profile_id_to_use;

  if summary is null then
    raise exception 'Player profile not found.';
  end if;

  select coalesce(
    jsonb_agg(event_row.payload order by event_row.applied_sequence desc),
    '[]'::jsonb
  )
  into history
  from (
    select
      event.applied_sequence,
      jsonb_build_object(
        'id', event.id,
        'event_id', event.id,
        'source_type', event.source_type,
        'source_id', event.source_id,
        'played_at', coalesce(
          public.fixture_start_at(fixture.match_date, fixture.time_slot),
          game.starts_at,
          event.effective_at
        ),
        'venue', coalesce(fixture.venue, game.venue),
        'side', event.side,
        'result', event.result,
        'team_name', case
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'HOME'
            then home_clan.name
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'AWAY'
            then away_clan.name
          when event.side = 'WHITE' then 'White Team'
          else 'Black Team'
        end,
        'opponent_name', case
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'HOME'
            then away_clan.name
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'AWAY'
            then home_clan.name
          when event.side = 'WHITE' then 'Black Team'
          else 'White Team'
        end,
        'opponent_label', case
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'HOME'
            then away_clan.name
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'AWAY'
            then home_clan.name
          when event.side = 'WHITE' then 'Black Team'
          else 'White Team'
        end,
        'score_for', case
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'HOME'
            then fixture.home_score
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'AWAY'
            then fixture.away_score
          when event.side = 'WHITE' then game.white_score
          else game.black_score
        end,
        'score_against', case
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'HOME'
            then fixture.away_score
          when event.source_type = 'CLAN_FIXTURE' and event.side = 'AWAY'
            then fixture.home_score
          when event.side = 'WHITE' then game.black_score
          else game.white_score
        end,
        'rating_before', event.rating_before,
        'rating_change', event.rating_change,
        'rating_after', event.rating_after,
        'rating_at_match_start', event.rating_at_match_start,
        'team_average_rating', event.team_average_rating,
        'opponent_average_rating', event.opponent_average_rating,
        'expected_score', event.expected_score,
        'actual_score', event.actual_score,
        'calculation_version', event.calculation_version,
        'score_margin', event.score_margin,
        'margin_multiplier', event.margin_multiplier,
        'base_rating_change', event.base_rating_change,
        'margin_bonus_before_clamp', event.margin_bonus_before_clamp,
        'margin_bonus_applied', event.margin_bonus_applied,
        'applied_sequence', event.applied_sequence,
        'applied_at', event.created_at
      ) as payload
    from public.player_rating_events event
    left join public.fixtures fixture
      on event.source_type = 'CLAN_FIXTURE'
      and fixture.id = event.source_id
    left join public.clans home_clan on home_clan.id = fixture.home_clan_id
    left join public.clans away_clan on away_clan.id = fixture.away_clan_id
    left join public.open_queue_games game
      on event.source_type = 'OPEN_QUEUE'
      and game.id = event.source_id
    where event.profile_id = profile_id_to_use
    order by event.applied_sequence desc
    limit safe_limit
  ) event_row;

  return summary || jsonb_build_object('events', history);
end;
$$;

revoke all on function public.calculate_open_queue_margin_multiplier(integer)
from public, anon, authenticated;
grant execute on function public.calculate_open_queue_margin_multiplier(integer)
to service_role;

revoke all on function public.calculate_open_queue_margin_bonus(integer, numeric)
from public, anon, authenticated;
grant execute on function public.calculate_open_queue_margin_bonus(integer, numeric)
to service_role;

revoke all on function public.apply_open_queue_player_ratings(uuid)
from public, anon, authenticated;
grant execute on function public.apply_open_queue_player_ratings(uuid)
to service_role;

revoke all on function public.get_player_rating_history(uuid, integer)
from public, anon, authenticated;
grant execute on function public.get_player_rating_history(uuid, integer)
to authenticated;

comment on function public.calculate_open_queue_margin_multiplier(integer) is
  'Returns the capped solo score-margin tier: no bonus through two goals, 1.10 at three, 1.15 at four, and 1.20 at five or more.';

comment on function public.calculate_open_queue_margin_bonus(integer, numeric) is
  'Turns the capped solo margin tier into a symmetric whole-point team bonus, with a six-point ceiling before the established total Player SR clamp.';

comment on function public.apply_open_queue_player_ratings(uuid) is
  'Applies append-only PLAYER_ELO_V2_MARGIN events. The existing individual ELO remains the base; a symmetric team margin bonus is added and then bounded by the original +/-32 and zero-rating clamps.';

comment on function public.get_player_rating_history(uuid, integer) is
  'Returns a public, payment-free Player SR summary and append-only calculation audit trail, including score-margin inputs and applied bonuses, to authenticated callers.';
