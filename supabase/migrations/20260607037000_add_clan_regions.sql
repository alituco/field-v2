alter table public.clans
add column if not exists region text not null default 'bahrain';

update public.clans
set region = 'bahrain'
where region is null or trim(region) = '';

alter table public.clans
alter column region set default 'bahrain';

alter table public.clans
alter column region set not null;

alter table public.clans
drop constraint if exists clans_region_check;

alter table public.clans
add constraint clans_region_check
check (region in ('bahrain'));

drop function if exists public.list_clans();

create or replace function public.list_clans()
returns table (
  id uuid,
  name text,
  tag text,
  motto text,
  emblem text,
  theme_id text,
  pattern_id text,
  skill_rating integer,
  wins integer,
  losses integer,
  region text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  member_count bigint
)
language sql
security definer
set search_path = public
as $$
  select
    c.id,
    c.name,
    c.tag,
    c.motto,
    c.emblem,
    c.theme_id,
    c.pattern_id,
    c.skill_rating,
    c.wins,
    c.losses,
    c.region,
    c.created_by,
    c.created_at,
    c.updated_at,
    count(cm.profile_id) as member_count
  from public.clans c
  left join public.clan_members cm on cm.clan_id = c.id
  group by c.id
  order by c.skill_rating desc, c.created_at desc;
$$;

grant execute on function public.list_clans() to authenticated;
