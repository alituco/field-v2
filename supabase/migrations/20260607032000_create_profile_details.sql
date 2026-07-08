alter table public.profiles
add column if not exists username text;

alter table public.profiles
add column if not exists bio text not null default '';

alter table public.profiles
add column if not exists avatar_url text;

alter table public.profiles
add column if not exists following_count integer not null default 0
check (following_count >= 0);

alter table public.profiles
add column if not exists fans_count integer not null default 0
check (fans_count >= 0);

create unique index if not exists profiles_username_unique_lower_idx
on public.profiles (lower(username))
where username is not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_username_format_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
    add constraint profiles_username_format_check
    check (username is null or username ~ '^[a-z0-9_]{2,24}$');
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_bio_length_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
    add constraint profiles_bio_length_check
    check (char_length(bio) <= 160);
  end if;
end $$;

create table if not exists public.profile_highlights (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 2 and 80),
  thumbnail_url text not null,
  video_url text,
  duration text not null default '0:00' check (
    duration ~ '^[0-9]{1,2}:[0-9]{2}$'
  ),
  views integer not null default 0 check (views >= 0),
  clan_tag text check (clan_tag is null or clan_tag ~ '^[A-Z0-9]{2,5}$'),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profile_highlights_profile_idx
on public.profile_highlights (profile_id, sort_order);

drop trigger if exists set_profile_highlights_updated_at
on public.profile_highlights;
create trigger set_profile_highlights_updated_at
before update on public.profile_highlights
for each row
execute function public.set_updated_at();

create table if not exists public.profile_career_entries (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  clan_name text not null check (char_length(trim(clan_name)) between 2 and 40),
  tag text not null check (tag ~ '^[A-Z0-9]{2,5}$'),
  emblem text not null default '⚽',
  period text not null check (char_length(trim(period)) between 2 and 32),
  apps integer not null default 0 check (apps >= 0),
  goals integer not null default 0 check (goals >= 0),
  is_current boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profile_career_entries_profile_idx
on public.profile_career_entries (profile_id, sort_order);

drop trigger if exists set_profile_career_entries_updated_at
on public.profile_career_entries;
create trigger set_profile_career_entries_updated_at
before update on public.profile_career_entries
for each row
execute function public.set_updated_at();

create table if not exists public.fixture_scorers (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  clan_id uuid not null references public.clans(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  assist_profile_id uuid references public.profiles(id) on delete set null,
  minute integer not null check (minute between 1 and 130),
  created_at timestamptz not null default now()
);

create index if not exists fixture_scorers_fixture_idx
on public.fixture_scorers (fixture_id, minute);

create index if not exists fixture_scorers_profile_idx
on public.fixture_scorers (profile_id);

create index if not exists fixture_scorers_assist_profile_idx
on public.fixture_scorers (assist_profile_id)
where assist_profile_id is not null;

alter table public.profile_highlights enable row level security;
alter table public.profile_career_entries enable row level security;
alter table public.fixture_scorers enable row level security;

drop policy if exists "Profile highlights are readable by authenticated users"
on public.profile_highlights;
create policy "Profile highlights are readable by authenticated users"
on public.profile_highlights
for select
to authenticated
using (true);

drop policy if exists "Users can insert their own highlights"
on public.profile_highlights;
create policy "Users can insert their own highlights"
on public.profile_highlights
for insert
to authenticated
with check (auth.uid() = profile_id);

drop policy if exists "Users can update their own highlights"
on public.profile_highlights;
create policy "Users can update their own highlights"
on public.profile_highlights
for update
to authenticated
using (auth.uid() = profile_id)
with check (auth.uid() = profile_id);

drop policy if exists "Users can delete their own highlights"
on public.profile_highlights;
create policy "Users can delete their own highlights"
on public.profile_highlights
for delete
to authenticated
using (auth.uid() = profile_id);

drop policy if exists "Career entries are readable by authenticated users"
on public.profile_career_entries;
create policy "Career entries are readable by authenticated users"
on public.profile_career_entries
for select
to authenticated
using (true);

drop policy if exists "Users can insert their own career entries"
on public.profile_career_entries;
create policy "Users can insert their own career entries"
on public.profile_career_entries
for insert
to authenticated
with check (auth.uid() = profile_id);

drop policy if exists "Users can update their own career entries"
on public.profile_career_entries;
create policy "Users can update their own career entries"
on public.profile_career_entries
for update
to authenticated
using (auth.uid() = profile_id)
with check (auth.uid() = profile_id);

drop policy if exists "Users can delete their own career entries"
on public.profile_career_entries;
create policy "Users can delete their own career entries"
on public.profile_career_entries
for delete
to authenticated
using (auth.uid() = profile_id);

drop policy if exists "Fixture scorers are readable by authenticated users"
on public.fixture_scorers;
create policy "Fixture scorers are readable by authenticated users"
on public.fixture_scorers
for select
to authenticated
using (true);

drop policy if exists "Clan owners can insert fixture scorers"
on public.fixture_scorers;
create policy "Clan owners can insert fixture scorers"
on public.fixture_scorers
for insert
to authenticated
with check (
  public.is_clan_owner(clan_id, auth.uid())
  and exists (
    select 1
    from public.fixtures f
    where f.id = fixture_id
      and (f.home_clan_id = clan_id or f.away_clan_id = clan_id)
  )
);

drop policy if exists "Clan owners can update fixture scorers"
on public.fixture_scorers;
create policy "Clan owners can update fixture scorers"
on public.fixture_scorers
for update
to authenticated
using (public.is_clan_owner(clan_id, auth.uid()))
with check (
  public.is_clan_owner(clan_id, auth.uid())
  and exists (
    select 1
    from public.fixtures f
    where f.id = fixture_id
      and (f.home_clan_id = clan_id or f.away_clan_id = clan_id)
  )
);

drop policy if exists "Clan owners can delete fixture scorers"
on public.fixture_scorers;
create policy "Clan owners can delete fixture scorers"
on public.fixture_scorers
for delete
to authenticated
using (public.is_clan_owner(clan_id, auth.uid()));
