alter table public.fixture_player_appearances
alter column played set default false;

create or replace function public.apply_clan_fixture_player_ratings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  participant record;
  opponent_average numeric;
  actual_score numeric;
  expected_score numeric;
  raw_change numeric;
  computed_change integer;
  current_rating integer;
  next_rating integer;
  result_to_use text;
  inserted_event uuid;
begin
  if new.status <> 'FINAL' or old.status = 'FINAL' then
    return new;
  end if;

  if new.home_score is null or new.away_score is null then
    return new;
  end if;

  perform public.snapshot_fixture_player_appearances(new.id);

  for participant in
    select appearance.*
    from public.fixture_player_appearances appearance
    where appearance.fixture_id = new.id
      and appearance.played = true
    order by appearance.profile_id
  loop
    select skill_rating into current_rating
    from public.player_ratings
    where profile_id = participant.profile_id
    for update;

    select avg(opponent.rating_at_start)::numeric
    into opponent_average
    from public.fixture_player_appearances opponent
    where opponent.fixture_id = new.id
      and opponent.played = true
      and opponent.side <> participant.side;

    if opponent_average is null then
      continue;
    end if;

    if new.home_score = new.away_score then
      actual_score := 0.5;
      result_to_use := 'DRAW';
    elsif
      (participant.side = 'HOME' and new.home_score > new.away_score)
      or (participant.side = 'AWAY' and new.away_score > new.home_score)
    then
      actual_score := 1;
      result_to_use := 'WIN';
    else
      actual_score := 0;
      result_to_use := 'LOSS';
    end if;

    expected_score := 1 / (
      1 + power(
        10::numeric,
        ((opponent_average - participant.rating_at_start)::numeric / 400)
      )
    );
    raw_change := 24 * (actual_score - expected_score);
    computed_change := round(raw_change)::integer;

    if result_to_use = 'WIN' and computed_change < 3 then
      computed_change := 3;
    elsif result_to_use = 'LOSS' and computed_change > -3 then
      computed_change := -3;
    end if;

    computed_change := greatest(-32, least(32, computed_change));
    next_rating := greatest(0, current_rating + computed_change);
    inserted_event := null;

    insert into public.player_rating_events (
      profile_id,
      source_type,
      source_id,
      side,
      result,
      rating_before,
      rating_change,
      rating_after
    )
    values (
      participant.profile_id,
      'CLAN_FIXTURE',
      new.id,
      participant.side,
      result_to_use,
      current_rating,
      computed_change,
      next_rating
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
        last_change = computed_change
      where profile_id = participant.profile_id;

      update public.fixture_player_appearances
      set rating_change = computed_change
      where fixture_id = new.id
        and profile_id = participant.profile_id;
    end if;
  end loop;

  return new;
end;
$$;

create or replace function public.sync_open_queue_game_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_id_to_sync uuid;
  confirmed_count integer;
  game_capacity integer;
begin
  if tg_op = 'DELETE' then
    game_id_to_sync := old.game_id;
  else
    game_id_to_sync := new.game_id;
  end if;

  select capacity into game_capacity
  from public.open_queue_games
  where id = game_id_to_sync;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings
  where game_id = game_id_to_sync
    and status = 'CONFIRMED';

  update public.open_queue_games
  set status = case
    when confirmed_count >= game_capacity then 'FULL'
    else 'OPEN'
  end
  where id = game_id_to_sync
    and status in ('OPEN', 'FULL');

  if confirmed_count >= game_capacity then
    perform public.assign_open_queue_teams(game_id_to_sync);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

do $$
declare
  full_game record;
begin
  for full_game in
    select id from public.open_queue_games where status = 'FULL'
  loop
    perform public.assign_open_queue_teams(full_game.id);
  end loop;
end;
$$;

create or replace function public.get_my_player_rating()
returns table (
  rank bigint,
  profile_id uuid,
  display_name text,
  username text,
  avatar_url text,
  skill_rating integer,
  matches_played integer,
  wins integer,
  losses integer,
  draws integer,
  last_change integer,
  region text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    1 + (
      select count(*)
      from public.player_ratings ahead
      where lower(ahead.region) = lower(rating.region)
        and (
          ahead.skill_rating > rating.skill_rating
          or (
            ahead.skill_rating = rating.skill_rating
            and ahead.matches_played > rating.matches_played
          )
        )
    ),
    profile.id,
    profile.display_name,
    profile.username,
    profile.avatar_url,
    rating.skill_rating,
    rating.matches_played,
    rating.wins,
    rating.losses,
    rating.draws,
    rating.last_change,
    rating.region
  from public.player_ratings rating
  join public.profiles profile on profile.id = rating.profile_id
  where rating.profile_id = user_id;
end;
$$;
