create table if not exists public.referee_profiles (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 2 and 80),
  phone text not null unique check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  role text not null default 'referee' check (role in ('admin', 'referee')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_referee_profiles_updated_at
on public.referee_profiles;
create trigger set_referee_profiles_updated_at
before update on public.referee_profiles
for each row
execute function public.set_updated_at();

create table if not exists public.fixture_referee_assignments (
  fixture_id uuid primary key references public.fixtures(id) on delete cascade,
  referee_id uuid not null references public.referee_profiles(profile_id) on delete restrict,
  assigned_by uuid references public.referee_profiles(profile_id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists fixture_referee_assignments_referee_idx
on public.fixture_referee_assignments (referee_id, created_at desc);

drop trigger if exists set_fixture_referee_assignments_updated_at
on public.fixture_referee_assignments;
create trigger set_fixture_referee_assignments_updated_at
before update on public.fixture_referee_assignments
for each row
execute function public.set_updated_at();

alter table public.referee_profiles enable row level security;
alter table public.fixture_referee_assignments enable row level security;

drop policy if exists "Referees can read active referee profiles"
on public.referee_profiles;
create policy "Referees can read active referee profiles"
on public.referee_profiles
for select
to authenticated
using (
  is_active
  and exists (
    select 1
    from public.referee_profiles rp
    where rp.profile_id = auth.uid()
      and rp.is_active
  )
);

drop policy if exists "Referees can read their own assignments"
on public.fixture_referee_assignments;
create policy "Referees can read their own assignments"
on public.fixture_referee_assignments
for select
to authenticated
using (
  referee_id = auth.uid()
  or exists (
    select 1
    from public.referee_profiles rp
    where rp.profile_id = auth.uid()
      and rp.role = 'admin'
      and rp.is_active
  )
);
