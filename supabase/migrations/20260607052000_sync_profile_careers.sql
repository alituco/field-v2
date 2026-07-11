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
      and upper(career.tag) = upper(current_clan_tag)
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
    and upper(career.tag) <> upper(current_clan_tag);

  update public.profile_career_entries career
  set
    clan_name = current_clan_name,
    tag = current_clan_tag,
    emblem = current_clan_emblem,
    period = case
      when career.period ~* 'present\s*$' then career.period
      else extract(year from member_started_at)::integer::text || ' - Present'
    end
  where career.profile_id = member_profile_id
    and upper(career.tag) = upper(current_clan_tag)
    and career.is_current;

  get diagnostics updated_rows = row_count;

  if updated_rows = 0 then
    select coalesce(min(career.sort_order) - 1, 0)
    into next_sort_order
    from public.profile_career_entries career
    where career.profile_id = member_profile_id;

    insert into public.profile_career_entries (
      profile_id,
      clan_name,
      tag,
      emblem,
      period,
      is_current,
      sort_order
    )
    values (
      member_profile_id,
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

-- Repair current career rows that no longer have a matching active membership.
with stale_careers as (
  select
    career.id,
    coalesce(
      (
        select max(member.left_at)
        from public.clan_members member
        join public.clans clan on clan.id = member.clan_id
        where member.profile_id = career.profile_id
          and upper(clan.tag) = upper(career.tag)
          and member.left_at is not null
      ),
      now()
    ) as ended_at
  from public.profile_career_entries career
  where career.is_current
    and not exists (
      select 1
      from public.clan_members member
      join public.clans clan on clan.id = member.clan_id
      where member.profile_id = career.profile_id
        and member.left_at is null
        and clan.archived_at is null
        and upper(clan.tag) = upper(career.tag)
    )
)
update public.profile_career_entries career
set
  is_current = false,
  period = case
    when career.period ~* '\s*-\s*present\s*$' then regexp_replace(
      career.period,
      '\s*-\s*present\s*$',
      ' - ' || extract(year from stale.ended_at)::integer::text,
      'i'
    )
    else career.period
  end
from stale_careers stale
where career.id = stale.id;

-- Keep the earliest display row if legacy data has duplicate current entries.
with duplicate_careers as (
  select id
  from (
    select
      career.id,
      row_number() over (
        partition by career.profile_id
        order by career.sort_order, career.created_at, career.id
      ) as row_number
    from public.profile_career_entries career
    where career.is_current
  ) ranked
  where ranked.row_number > 1
)
update public.profile_career_entries career
set
  is_current = false,
  period = case
    when career.period ~* '\s*-\s*present\s*$' then regexp_replace(
      career.period,
      '\s*-\s*present\s*$',
      ' - ' || extract(year from now())::integer::text,
      'i'
    )
    else career.period
  end
where career.id in (select id from duplicate_careers);

-- Every active clan member should have one current career entry.
insert into public.profile_career_entries (
  profile_id,
  clan_name,
  tag,
  emblem,
  period,
  is_current,
  sort_order
)
select
  member.profile_id,
  clan.name,
  clan.tag,
  clan.emblem,
  extract(year from member.created_at)::integer::text || ' - Present',
  true,
  coalesce(
    (
      select min(existing.sort_order) - 1
      from public.profile_career_entries existing
      where existing.profile_id = member.profile_id
    ),
    0
  )
from public.clan_members member
join public.clans clan on clan.id = member.clan_id
where member.left_at is null
  and clan.archived_at is null
  and not exists (
    select 1
    from public.profile_career_entries career
    where career.profile_id = member.profile_id
      and career.is_current
  );

create unique index if not exists profile_career_entries_one_current_idx
on public.profile_career_entries (profile_id)
where is_current;

drop trigger if exists sync_profile_career_on_member_insert_delete
on public.clan_members;
create trigger sync_profile_career_on_member_insert_delete
after insert or delete on public.clan_members
for each row
execute function public.sync_profile_career_from_clan_membership();

drop trigger if exists sync_profile_career_on_member_left_at
on public.clan_members;
create trigger sync_profile_career_on_member_left_at
after update of left_at on public.clan_members
for each row
execute function public.sync_profile_career_from_clan_membership();
