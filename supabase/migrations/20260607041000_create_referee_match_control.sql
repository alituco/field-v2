create table if not exists public.fixture_clock_states (
  fixture_id uuid primary key references public.fixtures(id) on delete cascade,
  status text not null default 'NOT_STARTED' check (
    status in ('NOT_STARTED', 'RUNNING', 'PAUSED', 'ENDED')
  ),
  started_at timestamptz,
  accumulated_seconds integer not null default 0 check (
    accumulated_seconds between 0 and 7200
  ),
  duration_seconds integer not null default 3600 check (
    duration_seconds between 600 and 7200
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'RUNNING' and started_at is not null)
    or (status <> 'RUNNING')
  )
);

drop trigger if exists set_fixture_clock_states_updated_at
on public.fixture_clock_states;
create trigger set_fixture_clock_states_updated_at
before update on public.fixture_clock_states
for each row
execute function public.set_updated_at();

create table if not exists public.fixture_events (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  event_type text not null check (
    event_type in (
      'MATCH_STARTED',
      'MATCH_PAUSED',
      'MATCH_RESUMED',
      'MATCH_ENDED',
      'GOAL',
      'BLUE_CARD',
      'BLUE_CARD_EXPIRED'
    )
  ),
  clan_id uuid references public.clans(id) on delete cascade,
  profile_id uuid references public.profiles(id) on delete set null,
  assist_profile_id uuid references public.profiles(id) on delete set null,
  blue_card_id uuid,
  minute integer not null default 0 check (minute between 0 and 130),
  second integer not null default 0 check (second between 0 and 59),
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists fixture_events_fixture_created_idx
on public.fixture_events (fixture_id, created_at desc);

create index if not exists fixture_events_profile_idx
on public.fixture_events (profile_id)
where profile_id is not null;

create table if not exists public.fixture_blue_cards (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  clan_id uuid not null references public.clans(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  duration_seconds integer not null default 120 check (
    duration_seconds between 30 and 600
  ),
  status text not null default 'ACTIVE' check (
    status in ('ACTIVE', 'EXPIRED', 'CLEARED')
  ),
  minute integer not null default 0 check (minute between 0 and 130),
  second integer not null default 0 check (second between 0 and 59),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.fixture_events
drop constraint if exists fixture_events_blue_card_id_fkey;
alter table public.fixture_events
add constraint fixture_events_blue_card_id_fkey
foreign key (blue_card_id)
references public.fixture_blue_cards(id)
on delete set null;

create index if not exists fixture_blue_cards_fixture_status_idx
on public.fixture_blue_cards (fixture_id, status, expires_at);

create index if not exists fixture_blue_cards_profile_idx
on public.fixture_blue_cards (profile_id);

drop trigger if exists set_fixture_blue_cards_updated_at
on public.fixture_blue_cards;
create trigger set_fixture_blue_cards_updated_at
before update on public.fixture_blue_cards
for each row
execute function public.set_updated_at();

alter table public.fixture_clock_states enable row level security;
alter table public.fixture_events enable row level security;
alter table public.fixture_blue_cards enable row level security;

drop policy if exists "Fixture clocks are readable by authenticated users"
on public.fixture_clock_states;
create policy "Fixture clocks are readable by authenticated users"
on public.fixture_clock_states
for select
to authenticated
using (true);

drop policy if exists "Fixture events are readable by authenticated users"
on public.fixture_events;
create policy "Fixture events are readable by authenticated users"
on public.fixture_events
for select
to authenticated
using (true);

drop policy if exists "Fixture blue cards are readable by authenticated users"
on public.fixture_blue_cards;
create policy "Fixture blue cards are readable by authenticated users"
on public.fixture_blue_cards
for select
to authenticated
using (true);

create or replace function public.referee_complete_fixture(
  fixture_id_to_complete uuid
)
returns public.fixtures
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_to_complete public.fixtures%rowtype;
  completed_fixture public.fixtures%rowtype;
  home_rating integer;
  away_rating integer;
  home_score_to_use integer;
  away_score_to_use integer;
  home_delta integer;
  away_delta integer;
  winner_id uuid;
begin
  select *
  into fixture_to_complete
  from public.fixtures
  where id = fixture_id_to_complete
  for update;

  if fixture_to_complete.id is null then
    raise exception 'Match not found.';
  end if;

  if fixture_to_complete.status = 'FINAL' then
    raise exception 'This match is already final.';
  end if;

  if fixture_to_complete.status not in ('SCHEDULED', 'LIVE') then
    raise exception 'Only scheduled or live matches can be finalized.';
  end if;

  if fixture_to_complete.away_clan_id is null then
    raise exception 'Cannot finalize a match without an opponent.';
  end if;

  select count(*)::integer
  into home_score_to_use
  from public.fixture_scorers
  where fixture_id = fixture_to_complete.id
    and clan_id = fixture_to_complete.home_clan_id;

  select count(*)::integer
  into away_score_to_use
  from public.fixture_scorers
  where fixture_id = fixture_to_complete.id
    and clan_id = fixture_to_complete.away_clan_id;

  select skill_rating
  into home_rating
  from public.clans
  where id = fixture_to_complete.home_clan_id
  for update;

  select skill_rating
  into away_rating
  from public.clans
  where id = fixture_to_complete.away_clan_id
  for update;

  select delta.home_change, delta.away_change
  into home_delta, away_delta
  from public.calculate_fixture_sr_delta(
    home_rating,
    away_rating,
    home_score_to_use,
    away_score_to_use
  ) as delta;

  winner_id := case
    when home_score_to_use > away_score_to_use then fixture_to_complete.home_clan_id
    when away_score_to_use > home_score_to_use then fixture_to_complete.away_clan_id
    else null
  end;

  update public.clans
  set
    skill_rating = greatest(0, skill_rating + home_delta),
    wins = wins + case when home_score_to_use > away_score_to_use then 1 else 0 end,
    losses = losses + case when home_score_to_use < away_score_to_use then 1 else 0 end
  where id = fixture_to_complete.home_clan_id;

  update public.clans
  set
    skill_rating = greatest(0, skill_rating + away_delta),
    wins = wins + case when away_score_to_use > home_score_to_use then 1 else 0 end,
    losses = losses + case when away_score_to_use < home_score_to_use then 1 else 0 end
  where id = fixture_to_complete.away_clan_id;

  update public.fixtures
  set
    status = 'FINAL',
    home_score = home_score_to_use,
    away_score = away_score_to_use,
    winner_clan_id = winner_id,
    home_sr_change = home_delta,
    away_sr_change = away_delta
  where id = fixture_to_complete.id
  returning * into completed_fixture;

  update public.fixture_clock_states
  set
    status = 'ENDED',
    started_at = null,
    accumulated_seconds = least(accumulated_seconds, duration_seconds)
  where fixture_id = fixture_to_complete.id;

  update public.fixture_blue_cards
  set status = 'CLEARED'
  where fixture_id = fixture_to_complete.id
    and status = 'ACTIVE';

  return completed_fixture;
end;
$$;

revoke execute on function public.referee_complete_fixture(uuid)
from public, anon, authenticated;
grant execute on function public.referee_complete_fixture(uuid)
to service_role;
