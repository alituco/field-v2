alter table public.profile_career_entries
add column if not exists clan_id uuid references public.clans(id) on delete set null;

create index if not exists profile_career_entries_clan_idx
on public.profile_career_entries (clan_id);

update public.profile_career_entries career
set clan_id = clan.id
from public.clans clan
where career.clan_id is null
  and lower(clan.tag) = lower(career.tag);

create or replace function public.sync_profile_career_from_clan_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  member_profile_id uuid;
  member_clan_id uuid;
  member_started_at timestamptz;
  member_ended_at timestamptz;
  current_clan_name text;
  current_clan_tag text;
  current_clan_emblem text;
  next_sort_order integer;
  updated_rows integer;
begin
  if tg_op = 'UPDATE' and old.left_at is not distinct from new.left_at then
    return new;
  end if;

  if tg_op = 'DELETE' then
    member_profile_id := old.profile_id;
    member_clan_id := old.clan_id;
    member_started_at := old.created_at;
    member_ended_at := coalesce(old.left_at, now());
  else
    member_profile_id := new.profile_id;
    member_clan_id := new.clan_id;
    member_started_at := new.created_at;
    member_ended_at := new.left_at;
  end if;

  select c.name, c.tag, c.emblem
  into current_clan_name, current_clan_tag, current_clan_emblem
  from public.clans c
  where c.id = member_clan_id;

  if not found then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if member_ended_at is not null then
    update public.profile_career_entries career
    set
      clan_id = member_clan_id,
      is_current = false,
      period = case
        when career.period ~* '\s*-\s*present\s*$' then regexp_replace(
          career.period,
          '\s*-\s*present\s*$',
          ' - ' || extract(year from member_ended_at)::integer::text,
          'i'
        )
        else career.period
      end
    where career.profile_id = member_profile_id
      and (
        career.clan_id = member_clan_id
        or (
          career.clan_id is null
          and upper(career.tag) = upper(current_clan_tag)
        )
      )
      and career.is_current;

    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  update public.profile_career_entries career
  set
    is_current = false,
    period = case
      when career.period ~* '\s*-\s*present\s*$' then regexp_replace(
        career.period,
        '\s*-\s*present\s*$',
        ' - ' || extract(year from member_started_at)::integer::text,
        'i'
      )
      else career.period
    end
  where career.profile_id = member_profile_id
    and career.is_current
    and career.clan_id is distinct from member_clan_id;

  update public.profile_career_entries career
  set
    clan_id = member_clan_id,
    clan_name = current_clan_name,
    tag = current_clan_tag,
    emblem = current_clan_emblem,
    period = case
      when career.period ~* 'present\s*$' then career.period
      else extract(year from member_started_at)::integer::text || ' - Present'
    end
  where career.profile_id = member_profile_id
    and (
      career.clan_id = member_clan_id
      or (
        career.clan_id is null
        and upper(career.tag) = upper(current_clan_tag)
      )
    )
    and career.is_current;

  get diagnostics updated_rows = row_count;

  if updated_rows = 0 then
    select coalesce(min(career.sort_order) - 1, 0)
    into next_sort_order
    from public.profile_career_entries career
    where career.profile_id = member_profile_id;

    insert into public.profile_career_entries (
      profile_id,
      clan_id,
      clan_name,
      tag,
      emblem,
      period,
      is_current,
      sort_order
    )
    values (
      member_profile_id,
      member_clan_id,
      current_clan_name,
      current_clan_tag,
      current_clan_emblem,
      extract(year from member_started_at)::integer::text || ' - Present',
      true,
      next_sort_order
    );
  end if;

  return new;
end;
$$;

drop function if exists public.list_profile_career_entries(uuid);

create function public.list_profile_career_entries(
  profile_id_to_use uuid
)
returns table (
  id uuid,
  clan_id uuid,
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
    coalesce(career.clan_id, matching_clan.id) as clan_id,
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
    where clan.id = career.clan_id
      or (
        career.clan_id is null
        and upper(clan.tag) = upper(career.tag)
      )
    order by
      (clan.id = career.clan_id) desc,
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
          and appearance.clan_id = coalesce(career.clan_id, matching_clan.id)
          and appearance.played
          and fixture.status = 'FINAL'
      ) as apps,
      (
        select count(*)::integer
        from public.fixture_scorers scorer
        join public.fixtures fixture on fixture.id = scorer.fixture_id
        where scorer.profile_id = career.profile_id
          and scorer.clan_id = coalesce(career.clan_id, matching_clan.id)
          and fixture.status = 'FINAL'
      ) as goals
  ) recorded on coalesce(career.clan_id, matching_clan.id) is not null
  where career.profile_id = profile_id_to_use
  order by career.sort_order, career.created_at, career.id;
end;
$$;

revoke all on function public.list_profile_career_entries(uuid)
from public, anon, authenticated;
grant execute on function public.list_profile_career_entries(uuid)
to authenticated;

comment on function public.list_profile_career_entries(uuid) is
  'Returns profile career rows with a stable clan id and recorded final-match apps and goals.';
