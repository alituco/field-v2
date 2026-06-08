create table if not exists public.fixtures (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'SCHEDULED', 'LIVE', 'FINAL')
  ),
  home_clan_id uuid not null
    constraint fixtures_home_clan_id_fkey
    references public.clans(id) on delete cascade,
  away_clan_id uuid
    constraint fixtures_away_clan_id_fkey
    references public.clans(id) on delete set null,
  venue text not null check (char_length(trim(venue)) between 2 and 60),
  day text not null check (day in ('TUESDAY', 'THURSDAY')),
  time_slot text not null check (
    time_slot in ('7:00 PM - 8:00 PM', '8:30 PM - 9:30 PM')
  ),
  match_date date not null,
  home_score integer check (home_score >= 0),
  away_score integer check (away_score >= 0),
  winner_clan_id uuid references public.clans(id) on delete set null,
  home_sr_change integer,
  away_sr_change integer,
  video_url text,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (away_clan_id is null or away_clan_id <> home_clan_id)
);

create index if not exists fixtures_status_idx
on public.fixtures (status);

create index if not exists fixtures_match_date_idx
on public.fixtures (match_date);

create index if not exists fixtures_home_clan_idx
on public.fixtures (home_clan_id);

create index if not exists fixtures_away_clan_idx
on public.fixtures (away_clan_id);

drop trigger if exists set_fixtures_updated_at on public.fixtures;
create trigger set_fixtures_updated_at
before update on public.fixtures
for each row
execute function public.set_updated_at();

create or replace function public.clan_has_fixture_conflict(
  clan_id_to_check uuid,
  fixture_date_to_check date,
  fixture_time_slot_to_check text,
  fixture_id_to_ignore uuid default null
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.fixtures f
    where f.match_date = fixture_date_to_check
      and f.time_slot = fixture_time_slot_to_check
      and f.status in ('OPEN', 'SCHEDULED', 'LIVE')
      and (
        fixture_id_to_ignore is null
        or f.id <> fixture_id_to_ignore
      )
      and (
        f.home_clan_id = clan_id_to_check
        or f.away_clan_id = clan_id_to_check
      )
  );
$$;

create or replace function public.create_fixture(
  home_clan_id_to_use uuid,
  fixture_venue text,
  fixture_date date,
  fixture_time_slot text
)
returns public.fixtures
language plpgsql
security definer
set search_path = public
as $$
declare
  created_fixture public.fixtures%rowtype;
  fixture_day text;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  if not public.is_clan_owner(home_clan_id_to_use, auth.uid()) then
    raise exception 'Only the clan owner can host a match.';
  end if;

  if fixture_date < current_date then
    raise exception 'Match date cannot be in the past.';
  end if;

  if fixture_time_slot not in ('7:00 PM - 8:00 PM', '8:30 PM - 9:30 PM') then
    raise exception 'Invalid time slot.';
  end if;

  fixture_day := case extract(isodow from fixture_date)
    when 2 then 'TUESDAY'
    when 4 then 'THURSDAY'
    else null
  end;

  if fixture_day is null then
    raise exception 'Matches can only be hosted on Tuesday or Thursday.';
  end if;

  if public.clan_has_fixture_conflict(
    home_clan_id_to_use,
    fixture_date,
    fixture_time_slot,
    null
  ) then
    raise exception 'Your clan already has a match in that slot.';
  end if;

  insert into public.fixtures (
    home_clan_id,
    venue,
    day,
    time_slot,
    match_date,
    created_by
  )
  values (
    home_clan_id_to_use,
    trim(fixture_venue),
    fixture_day,
    fixture_time_slot,
    fixture_date,
    auth.uid()
  )
  returning * into created_fixture;

  return created_fixture;
end;
$$;

create or replace function public.join_fixture(
  fixture_id_to_join uuid,
  away_clan_id_to_use uuid
)
returns public.fixtures
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_to_join public.fixtures%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  if not public.is_clan_owner(away_clan_id_to_use, auth.uid()) then
    raise exception 'Only the clan owner can join a match.';
  end if;

  select *
  into fixture_to_join
  from public.fixtures
  where id = fixture_id_to_join
  for update;

  if fixture_to_join.id is null then
    raise exception 'Match not found.';
  end if;

  if fixture_to_join.status <> 'OPEN' or fixture_to_join.away_clan_id is not null then
    raise exception 'This match is no longer open.';
  end if;

  if fixture_to_join.home_clan_id = away_clan_id_to_use then
    raise exception 'Your clan cannot join its own match.';
  end if;

  if public.clan_has_fixture_conflict(
    away_clan_id_to_use,
    fixture_to_join.match_date,
    fixture_to_join.time_slot,
    fixture_to_join.id
  ) then
    raise exception 'Your clan already has a match in that slot.';
  end if;

  update public.fixtures
  set
    away_clan_id = away_clan_id_to_use,
    status = 'SCHEDULED'
  where id = fixture_to_join.id
  returning * into fixture_to_join;

  return fixture_to_join;
end;
$$;

grant execute on function public.clan_has_fixture_conflict(uuid, date, text, uuid)
to authenticated;
grant execute on function public.create_fixture(uuid, text, date, text)
to authenticated;
grant execute on function public.join_fixture(uuid, uuid)
to authenticated;

alter table public.fixtures enable row level security;

drop policy if exists "Fixtures are readable by authenticated users" on public.fixtures;
create policy "Fixtures are readable by authenticated users"
on public.fixtures
for select
to authenticated
using (true);

drop policy if exists "Clan owners can update fixture records" on public.fixtures;
create policy "Clan owners can update fixture records"
on public.fixtures
for update
to authenticated
using (
  public.is_clan_owner(fixtures.home_clan_id, auth.uid())
  or (
    fixtures.away_clan_id is not null
    and public.is_clan_owner(fixtures.away_clan_id, auth.uid())
  )
)
with check (
  public.is_clan_owner(fixtures.home_clan_id, auth.uid())
  or (
    fixtures.away_clan_id is not null
    and public.is_clan_owner(fixtures.away_clan_id, auth.uid())
  )
);
