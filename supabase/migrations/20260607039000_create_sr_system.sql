create or replace function public.calculate_fixture_sr_delta(
  home_rating integer,
  away_rating integer,
  home_score integer,
  away_score integer
)
returns table (
  home_change integer,
  away_change integer
)
language plpgsql
immutable
set search_path = public
as $$
declare
  expected_home numeric;
  actual_home numeric;
  goal_diff integer;
  margin_multiplier numeric;
  raw_home_change numeric;
  computed_home_change integer;
begin
  if home_rating is null or away_rating is null then
    raise exception 'Clan ratings are required.';
  end if;

  if home_score is null or away_score is null then
    raise exception 'Scores are required.';
  end if;

  if home_score < 0 or away_score < 0 then
    raise exception 'Scores cannot be negative.';
  end if;

  expected_home := 1 / (
    1 + power(10::numeric, ((away_rating - home_rating)::numeric / 400))
  );

  actual_home := case
    when home_score > away_score then 1
    when home_score < away_score then 0
    else 0.5
  end;

  goal_diff := abs(home_score - away_score);
  margin_multiplier := case
    when goal_diff <= 1 then 1
    else 1 + (ln(goal_diff::numeric) * 0.35)
  end;

  raw_home_change := 32 * margin_multiplier * (actual_home - expected_home);
  computed_home_change := round(raw_home_change)::integer;

  if home_score <> away_score and computed_home_change = 0 then
    computed_home_change := case
      when raw_home_change > 0 then 1
      else -1
    end;
  end if;

  home_change := greatest(-64, least(64, computed_home_change));
  away_change := -home_change;

  return next;
end;
$$;

create or replace function public.complete_fixture(
  fixture_id_to_complete uuid,
  home_score_to_use integer,
  away_score_to_use integer
)
returns public.fixtures
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_to_complete public.fixtures%rowtype;
  completed_fixture public.fixtures%rowtype;
  home_rating integer;
  away_rating integer;
  home_delta integer;
  away_delta integer;
  winner_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  if home_score_to_use is null or away_score_to_use is null then
    raise exception 'Scores are required.';
  end if;

  if home_score_to_use < 0 or away_score_to_use < 0 then
    raise exception 'Scores cannot be negative.';
  end if;

  select *
  into fixture_to_complete
  from public.fixtures
  where id = fixture_id_to_complete
  for update;

  if fixture_to_complete.id is null then
    raise exception 'Match not found.';
  end if;

  if fixture_to_complete.status = 'FINAL' then
    raise exception 'This match is already final.';
  end if;

  if fixture_to_complete.status not in ('SCHEDULED', 'LIVE') then
    raise exception 'Only scheduled or live matches can be finalized.';
  end if;

  if fixture_to_complete.away_clan_id is null then
    raise exception 'Cannot finalize a match without an opponent.';
  end if;

  if not (
    public.is_clan_owner(fixture_to_complete.home_clan_id, auth.uid())
    or public.is_clan_owner(fixture_to_complete.away_clan_id, auth.uid())
  ) then
    raise exception 'Only a participating clan owner can finalize this match.';
  end if;

  select skill_rating
  into home_rating
  from public.clans
  where id = fixture_to_complete.home_clan_id
  for update;

  select skill_rating
  into away_rating
  from public.clans
  where id = fixture_to_complete.away_clan_id
  for update;

  select delta.home_change, delta.away_change
  into home_delta, away_delta
  from public.calculate_fixture_sr_delta(
    home_rating,
    away_rating,
    home_score_to_use,
    away_score_to_use
  ) as delta;

  winner_id := case
    when home_score_to_use > away_score_to_use then fixture_to_complete.home_clan_id
    when away_score_to_use > home_score_to_use then fixture_to_complete.away_clan_id
    else null
  end;

  update public.clans
  set
    skill_rating = greatest(0, skill_rating + home_delta),
    wins = wins + case when home_score_to_use > away_score_to_use then 1 else 0 end,
    losses = losses + case when home_score_to_use < away_score_to_use then 1 else 0 end
  where id = fixture_to_complete.home_clan_id;

  update public.clans
  set
    skill_rating = greatest(0, skill_rating + away_delta),
    wins = wins + case when away_score_to_use > home_score_to_use then 1 else 0 end,
    losses = losses + case when away_score_to_use < home_score_to_use then 1 else 0 end
  where id = fixture_to_complete.away_clan_id;

  update public.fixtures
  set
    status = 'FINAL',
    home_score = home_score_to_use,
    away_score = away_score_to_use,
    winner_clan_id = winner_id,
    home_sr_change = home_delta,
    away_sr_change = away_delta
  where id = fixture_to_complete.id
  returning * into completed_fixture;

  return completed_fixture;
end;
$$;

grant execute on function public.calculate_fixture_sr_delta(integer, integer, integer, integer)
to authenticated;

grant execute on function public.complete_fixture(uuid, integer, integer)
to authenticated;
