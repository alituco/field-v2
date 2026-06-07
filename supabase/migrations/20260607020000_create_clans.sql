create table if not exists public.clans (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 24),
  tag text not null check (tag ~ '^[A-Z0-9]{2,5}$'),
  motto text not null default '' check (char_length(motto) <= 60),
  emblem text not null default '⚽',
  theme_id text not null default 'pitch' check (
    theme_id in (
      'pitch',
      'electric',
      'royal',
      'sunset',
      'crimson',
      'gold',
      'shadow',
      'mint'
    )
  ),
  pattern_id text not null default 'solid' check (
    pattern_id in ('solid', 'stripes', 'sash', 'chevron', 'pitch')
  ),
  skill_rating integer not null default 1500 check (skill_rating >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists clans_tag_unique_lower_idx
on public.clans (lower(tag));

create table if not exists public.clan_members (
  clan_id uuid not null references public.clans(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (clan_id, profile_id),
  unique (profile_id)
);

drop trigger if exists set_clans_updated_at on public.clans;
create trigger set_clans_updated_at
before update on public.clans
for each row
execute function public.set_updated_at();

create or replace function public.add_clan_owner_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.clan_members (clan_id, profile_id, role)
  values (new.id, new.created_by, 'owner');

  return new;
end;
$$;

drop trigger if exists add_clan_owner_member on public.clans;
create trigger add_clan_owner_member
after insert on public.clans
for each row
execute function public.add_clan_owner_member();

create or replace function public.profile_has_clan(profile_id_to_check uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.clan_members
    where profile_id = profile_id_to_check
  );
$$;

create or replace function public.is_clan_owner(
  clan_id_to_check uuid,
  profile_id_to_check uuid
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.clan_members
    where clan_id = clan_id_to_check
      and profile_id = profile_id_to_check
      and role = 'owner'
  );
$$;

grant execute on function public.profile_has_clan(uuid) to authenticated;
grant execute on function public.is_clan_owner(uuid, uuid) to authenticated;

alter table public.clans enable row level security;
alter table public.clan_members enable row level security;

drop policy if exists "Clans are readable by authenticated users" on public.clans;
create policy "Clans are readable by authenticated users"
on public.clans
for select
to authenticated
using (true);

drop policy if exists "Users can create one clan for themselves" on public.clans;
create policy "Users can create one clan for themselves"
on public.clans
for insert
to authenticated
with check (
  auth.uid() = created_by
  and not public.profile_has_clan(auth.uid())
);

drop policy if exists "Clan owners can update their clan" on public.clans;
create policy "Clan owners can update their clan"
on public.clans
for update
to authenticated
using (
  public.is_clan_owner(clans.id, auth.uid())
)
with check (
  public.is_clan_owner(clans.id, auth.uid())
);

drop policy if exists "Clan owners can delete their clan" on public.clans;
create policy "Clan owners can delete their clan"
on public.clans
for delete
to authenticated
using (
  public.is_clan_owner(clans.id, auth.uid())
);

drop policy if exists "Clan members are readable by authenticated users" on public.clan_members;
create policy "Clan members are readable by authenticated users"
on public.clan_members
for select
to authenticated
using (true);

drop policy if exists "Users can join a clan as a member" on public.clan_members;
create policy "Users can join a clan as a member"
on public.clan_members
for insert
to authenticated
with check (
  auth.uid() = profile_id
  and role = 'member'
);

drop policy if exists "Clan owners can manage members" on public.clan_members;
create policy "Clan owners can manage members"
on public.clan_members
for update
to authenticated
using (
  public.is_clan_owner(clan_members.clan_id, auth.uid())
)
with check (
  public.is_clan_owner(clan_members.clan_id, auth.uid())
);

drop policy if exists "Clan owners and members can remove members" on public.clan_members;
create policy "Clan owners and members can remove members"
on public.clan_members
for delete
to authenticated
using (
  auth.uid() = profile_id
  or public.is_clan_owner(clan_members.clan_id, auth.uid())
);

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
