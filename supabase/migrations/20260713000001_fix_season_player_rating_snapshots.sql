create or replace function public.season_player_rating_rankings(
  region_to_use text,
  season_starts_on date,
  season_ends_on date
)
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
language sql
stable
security definer
set search_path = public
as $$
  with season_stats as (
    select
      appearance.profile_id,
      count(*)::integer as matches_played,
      count(*) filter (
        where
          (
            appearance.side = 'HOME'
            and fixture.home_score > fixture.away_score
          )
          or (
            appearance.side = 'AWAY'
            and fixture.away_score > fixture.home_score
          )
      )::integer as wins,
      count(*) filter (
        where
          (
            appearance.side = 'HOME'
            and fixture.home_score < fixture.away_score
          )
          or (
            appearance.side = 'AWAY'
            and fixture.away_score < fixture.home_score
          )
      )::integer as losses,
      count(*) filter (
        where fixture.home_score = fixture.away_score
      )::integer as draws
    from public.fixture_player_appearances appearance
    join public.fixtures fixture on fixture.id = appearance.fixture_id
    join public.player_ratings region_rating
      on region_rating.profile_id = appearance.profile_id
    where appearance.played = true
      and fixture.status = 'FINAL'
      and fixture.home_score is not null
      and fixture.away_score is not null
      and fixture.match_date between season_starts_on and season_ends_on
      and lower(region_rating.region) = lower(trim(region_to_use))
    group by appearance.profile_id
    having count(*) >= 2
  ),
  qualified_players as (
    select
      profile.id as profile_id,
      profile.display_name,
      profile.username,
      profile.avatar_url,
      coalesce(
        latest_event.rating_after,
        latest_appearance.rating_after
      )::integer as skill_rating,
      stats.matches_played,
      stats.wins,
      stats.losses,
      stats.draws,
      coalesce(
        latest_event.rating_change,
        latest_appearance.rating_change,
        0
      )::integer as last_change,
      rating.region
    from season_stats stats
    join public.player_ratings rating
      on rating.profile_id = stats.profile_id
    join public.profiles profile on profile.id = stats.profile_id
    left join lateral (
      select
        event.rating_after,
        event.rating_change
      from public.player_rating_events event
      join public.fixtures event_fixture
        on event_fixture.id = event.source_id
      join public.fixture_player_appearances event_appearance
        on event_appearance.fixture_id = event_fixture.id
        and event_appearance.profile_id = event.profile_id
        and event_appearance.played = true
      where event.profile_id = stats.profile_id
        and event.source_type = 'CLAN_FIXTURE'
        and event_fixture.status = 'FINAL'
        and event_fixture.match_date
          between season_starts_on and season_ends_on
      order by event.created_at desc, event.id desc
      limit 1
    ) latest_event on true
    left join lateral (
      select
        (
          appearance.rating_at_start
          + coalesce(appearance.rating_change, 0)
        )::integer as rating_after,
        appearance.rating_change
      from public.fixture_player_appearances appearance
      join public.fixtures appearance_fixture
        on appearance_fixture.id = appearance.fixture_id
      where appearance.profile_id = stats.profile_id
        and appearance.played = true
        and appearance_fixture.status = 'FINAL'
        and appearance_fixture.match_date
          between season_starts_on and season_ends_on
      order by
        appearance_fixture.match_date desc,
        appearance.created_at desc,
        appearance.fixture_id desc
      limit 1
    ) latest_appearance on true
  )
  select
    row_number() over (
      order by
        player.skill_rating desc,
        player.matches_played desc,
        player.wins desc,
        lower(player.display_name),
        player.profile_id
    )::bigint as rank,
    player.profile_id,
    player.display_name,
    player.username,
    player.avatar_url,
    player.skill_rating,
    player.matches_played,
    player.wins,
    player.losses,
    player.draws,
    player.last_change,
    player.region
  from qualified_players player;
$$;

create or replace function public.get_my_season_player_rating(
  region_to_use text,
  season_starts_on date,
  season_ends_on date
)
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

  if char_length(trim(coalesce(region_to_use, ''))) < 2 then
    raise exception 'Choose a valid leaderboard region.';
  end if;

  if season_starts_on is null
    or season_ends_on is null
    or season_ends_on < season_starts_on
    or season_ends_on - season_starts_on > 370
  then
    raise exception 'Choose a valid leaderboard season.';
  end if;

  return query
  with my_season_stats as (
    select
      count(*)::integer as matches_played,
      count(*) filter (
        where
          (
            appearance.side = 'HOME'
            and fixture.home_score > fixture.away_score
          )
          or (
            appearance.side = 'AWAY'
            and fixture.away_score > fixture.home_score
          )
      )::integer as wins,
      count(*) filter (
        where
          (
            appearance.side = 'HOME'
            and fixture.home_score < fixture.away_score
          )
          or (
            appearance.side = 'AWAY'
            and fixture.away_score < fixture.home_score
          )
      )::integer as losses,
      count(*) filter (
        where fixture.home_score = fixture.away_score
      )::integer as draws
    from public.fixture_player_appearances appearance
    join public.fixtures fixture on fixture.id = appearance.fixture_id
    where appearance.profile_id = user_id
      and appearance.played = true
      and fixture.status = 'FINAL'
      and fixture.home_score is not null
      and fixture.away_score is not null
      and fixture.match_date between season_starts_on and season_ends_on
  )
  select
    coalesce(ranking.rank, 0::bigint) as rank,
    profile.id,
    profile.display_name,
    profile.username,
    profile.avatar_url,
    case
      when stats.matches_played = 0 then rating.skill_rating
      else coalesce(
        latest_event.rating_after,
        latest_appearance.rating_after,
        rating.skill_rating
      )
    end::integer as skill_rating,
    stats.matches_played,
    stats.wins,
    stats.losses,
    stats.draws,
    coalesce(
      latest_event.rating_change,
      latest_appearance.rating_change,
      0
    )::integer as last_change,
    rating.region
  from public.player_ratings rating
  join public.profiles profile on profile.id = rating.profile_id
  cross join my_season_stats stats
  left join public.season_player_rating_rankings(
    region_to_use,
    season_starts_on,
    season_ends_on
  ) ranking on ranking.profile_id = rating.profile_id
  left join lateral (
    select
      event.rating_after,
      event.rating_change
    from public.player_rating_events event
    join public.fixtures event_fixture on event_fixture.id = event.source_id
    join public.fixture_player_appearances event_appearance
      on event_appearance.fixture_id = event_fixture.id
      and event_appearance.profile_id = event.profile_id
      and event_appearance.played = true
    where event.profile_id = rating.profile_id
      and event.source_type = 'CLAN_FIXTURE'
      and event_fixture.status = 'FINAL'
      and event_fixture.match_date between season_starts_on and season_ends_on
    order by event.created_at desc, event.id desc
    limit 1
  ) latest_event on true
  left join lateral (
    select
      (
        appearance.rating_at_start
        + coalesce(appearance.rating_change, 0)
      )::integer as rating_after,
      appearance.rating_change
    from public.fixture_player_appearances appearance
    join public.fixtures appearance_fixture
      on appearance_fixture.id = appearance.fixture_id
    where appearance.profile_id = rating.profile_id
      and appearance.played = true
      and appearance_fixture.status = 'FINAL'
      and appearance_fixture.match_date
        between season_starts_on and season_ends_on
    order by
      appearance_fixture.match_date desc,
      appearance.created_at desc,
      appearance.fixture_id desc
    limit 1
  ) latest_appearance on true
  where rating.profile_id = user_id
    and lower(rating.region) = lower(trim(region_to_use));
end;
$$;

revoke all on function public.season_player_rating_rankings(text, date, date)
from public, anon, authenticated;

revoke execute on function public.get_my_season_player_rating(
  text,
  date,
  date
) from public, anon;

grant execute on function public.get_my_season_player_rating(
  text,
  date,
  date
) to authenticated;
