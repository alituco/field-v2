create or replace function public.preview_fixture_sr_scenarios(
  home_clan_id_to_use uuid,
  away_clan_id_to_use uuid,
  perspective_clan_id_to_use uuid
)
returns table (
  scenario_order integer,
  label text,
  my_change integer,
  opponent_change integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  home_rating_value integer;
  away_rating_value integer;
  perspective_is_home boolean;
begin
  if perspective_clan_id_to_use not in (
    home_clan_id_to_use,
    away_clan_id_to_use
  ) then
    raise exception 'The selected clan is not part of this matchup.';
  end if;

  select skill_rating
  into home_rating_value
  from public.clans
  where id = home_clan_id_to_use;

  select skill_rating
  into away_rating_value
  from public.clans
  where id = away_clan_id_to_use;

  if home_rating_value is null or away_rating_value is null then
    raise exception 'Both clans are required to preview SR.';
  end if;

  perspective_is_home := perspective_clan_id_to_use = home_clan_id_to_use;

  return query
  with scenarios(scenario_order, label, my_goals, opponent_goals) as (
    values
      (1, 'Win by 3+'::text, 3, 0),
      (2, 'Win by 2'::text, 2, 0),
      (3, 'Win by 1'::text, 1, 0),
      (4, 'Draw'::text, 0, 0),
      (5, 'Lose by 1'::text, 0, 1),
      (6, 'Lose by 2'::text, 0, 2),
      (7, 'Lose by 3+'::text, 0, 3)
  )
  select
    scenario.scenario_order,
    scenario.label,
    case
      when perspective_is_home then delta.home_change
      else delta.away_change
    end as my_change,
    case
      when perspective_is_home then delta.away_change
      else delta.home_change
    end as opponent_change
  from scenarios scenario
  cross join lateral public.calculate_fixture_sr_delta(
    home_rating_value,
    away_rating_value,
    case
      when perspective_is_home then scenario.my_goals
      else scenario.opponent_goals
    end,
    case
      when perspective_is_home then scenario.opponent_goals
      else scenario.my_goals
    end
  ) delta
  order by scenario.scenario_order;
end;
$$;

revoke execute on function public.preview_fixture_sr_scenarios(uuid, uuid, uuid)
from public, anon;
grant execute on function public.preview_fixture_sr_scenarios(uuid, uuid, uuid)
to authenticated, service_role;
