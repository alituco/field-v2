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
  capped_goal_diff integer;
  margin_multiplier numeric;
  raw_home_change numeric;
  computed_home_change integer;
  minimum_change constant integer := 5;
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
  capped_goal_diff := least(goal_diff, 3);
  margin_multiplier := case
    when capped_goal_diff <= 1 then 1
    else 1 + (ln(capped_goal_diff::numeric) * 0.35)
  end;

  raw_home_change := 32 * margin_multiplier * (actual_home - expected_home);
  computed_home_change := round(raw_home_change)::integer;

  if home_score <> away_score and abs(computed_home_change) < minimum_change then
    computed_home_change := case
      when home_score > away_score then minimum_change
      else -minimum_change
    end;
  elsif computed_home_change <> 0
      and abs(computed_home_change) < minimum_change then
    computed_home_change := case
      when computed_home_change > 0 then minimum_change
      else -minimum_change
    end;
  end if;

  home_change := greatest(-64, least(64, computed_home_change));
  away_change := -home_change;

  return next;
end;
$$;

grant execute on function public.calculate_fixture_sr_delta(integer, integer, integer, integer)
to authenticated, service_role;
