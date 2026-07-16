create or replace function public.list_profile_career_entries(
  profile_id_to_use uuid
)
returns table (
  id uuid,
  clan_name text,
  tag text,
  emblem text,
  period text,
  apps integer,
  goals integer,
  is_current boolean,
  sort_order integer,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    career.id,
    career.clan_name,
    career.tag,
    career.emblem,
    career.period,
    case
      when career.is_current then coalesce(recorded.apps, 0)
      else career.apps
    end as apps,
    case
      when career.is_current then coalesce(recorded.goals, 0)
      else career.goals
    end as goals,
    career.is_current,
    career.sort_order,
    career.created_at
  from public.profile_career_entries career
  left join lateral (
    select clan.id
    from public.clans clan
    where upper(clan.tag) = upper(career.tag)
    order by
      (clan.archived_at is null) desc,
      clan.created_at desc,
      clan.id
    limit 1
  ) matching_clan on true
  left join lateral (
    select
      (
        select count(distinct appearance.fixture_id)::integer
        from public.fixture_player_appearances appearance
        join public.fixtures fixture on fixture.id = appearance.fixture_id
        where appearance.profile_id = career.profile_id
          and appearance.clan_id = matching_clan.id
          and appearance.played
          and fixture.status = 'FINAL'
      ) as apps,
      (
        select count(*)::integer
        from public.fixture_scorers scorer
        join public.fixtures fixture on fixture.id = scorer.fixture_id
        where scorer.profile_id = career.profile_id
          and scorer.clan_id = matching_clan.id
          and fixture.status = 'FINAL'
      ) as goals
  ) recorded on matching_clan.id is not null
  where career.profile_id = profile_id_to_use
  order by career.sort_order, career.created_at, career.id;
end;
$$;

-- Repair existing current rows so direct database readers agree with the
-- computed profile response. Historical rows retain their imported totals.
with current_stats as (
  select
    career.id as career_id,
    (
      select count(distinct appearance.fixture_id)::integer
      from public.fixture_player_appearances appearance
      join public.fixtures fixture on fixture.id = appearance.fixture_id
      where appearance.profile_id = career.profile_id
        and appearance.clan_id = clan.id
        and appearance.played
        and fixture.status = 'FINAL'
    ) as apps,
    (
      select count(*)::integer
      from public.fixture_scorers scorer
      join public.fixtures fixture on fixture.id = scorer.fixture_id
      where scorer.profile_id = career.profile_id
        and scorer.clan_id = clan.id
        and fixture.status = 'FINAL'
    ) as goals
  from public.profile_career_entries career
  join public.clans clan on upper(clan.tag) = upper(career.tag)
  where career.is_current
)
update public.profile_career_entries career
set
  apps = stats.apps,
  goals = stats.goals
from current_stats stats
where career.id = stats.career_id
  and (
    career.apps is distinct from stats.apps
    or career.goals is distinct from stats.goals
  );

revoke all on function public.list_profile_career_entries(uuid)
from public, anon, authenticated;
grant execute on function public.list_profile_career_entries(uuid)
to authenticated;

comment on function public.list_profile_career_entries(uuid) is
  'Returns career rows with the current clan apps and goals derived from recorded final played fixtures, keeping Career consistent with Previous Games.';
