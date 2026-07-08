alter table public.fixtures
drop constraint if exists fixtures_status_check;

alter table public.fixtures
add constraint fixtures_status_check
check (status in ('OPEN', 'SCHEDULED', 'LIVE', 'FINAL', 'CANCELLED'));

alter table public.fixtures
add column if not exists cancelled_at timestamptz;

alter table public.fixtures
add column if not exists cancellation_reason text;

drop index if exists public.fixtures_one_active_match_per_slot_idx;

create index if not exists fixtures_active_slot_idx
on public.fixtures (match_date, time_slot)
where status in ('OPEN', 'SCHEDULED', 'LIVE');

create or replace function public.fixture_start_at(
  fixture_date date,
  fixture_time_slot text
)
returns timestamptz
language sql
immutable
set search_path = public
as $$
  select make_timestamptz(
    extract(year from fixture_date)::int,
    extract(month from fixture_date)::int,
    extract(day from fixture_date)::int,
    case fixture_time_slot
      when '7:00 PM - 8:00 PM' then 19
      when '8:30 PM - 9:30 PM' then 20
      else 0
    end,
    case fixture_time_slot
      when '8:30 PM - 9:30 PM' then 30
      else 0
    end,
    0,
    'Asia/Bahrain'
  );
$$;

create or replace function public.fixture_active_slot_count(
  fixture_date_to_check date,
  fixture_time_slot_to_check text,
  fixture_id_to_ignore uuid default null
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.fixtures f
  where f.match_date = fixture_date_to_check
    and f.time_slot = fixture_time_slot_to_check
    and f.status in ('OPEN', 'SCHEDULED', 'LIVE')
    and (
      fixture_id_to_ignore is null
      or f.id <> fixture_id_to_ignore
    );
$$;

create or replace function public.fixture_slot_is_booked(
  fixture_date_to_check date,
  fixture_time_slot_to_check text,
  fixture_id_to_ignore uuid default null
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.fixture_active_slot_count(
    fixture_date_to_check,
    fixture_time_slot_to_check,
    fixture_id_to_ignore
  ) >= 2;
$$;

create or replace function public.cancel_underfilled_fixtures()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cancelled_count integer;
begin
  update public.fixtures
  set
    status = 'CANCELLED',
    cancelled_at = coalesce(cancelled_at, now()),
    cancellation_reason = coalesce(
      cancellation_reason,
      'No opponent joined before the 24 hour cutoff.'
    ),
    updated_at = now()
  where status = 'OPEN'
    and away_clan_id is null
    and public.fixture_start_at(match_date, time_slot) <= now() + interval '24 hours';

  get diagnostics cancelled_count = row_count;
  return cancelled_count;
end;
$$;

create or replace function public.enforce_fixture_slot_capacity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  fixture_id_to_ignore uuid;
begin
  if tg_op = 'UPDATE' then
    fixture_id_to_ignore := old.id;
  end if;

  if new.status in ('OPEN', 'SCHEDULED', 'LIVE') then
    perform pg_advisory_xact_lock(
      hashtext(new.match_date::text || '|' || new.time_slot)::bigint
    );

    if public.fixture_active_slot_count(
      new.match_date,
      new.time_slot,
      fixture_id_to_ignore
    ) >= 2 then
      raise exception 'This date and time already has 2 matches.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_fixture_slot_capacity on public.fixtures;
create trigger enforce_fixture_slot_capacity
before insert or update of status, match_date, time_slot
on public.fixtures
for each row
execute function public.enforce_fixture_slot_capacity();

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

  perform public.cancel_underfilled_fixtures();

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

  if public.fixture_start_at(fixture_date, fixture_time_slot) <= now() + interval '24 hours' then
    raise exception 'Open matches must be hosted more than 24 hours before kickoff.';
  end if;

  if public.fixture_slot_is_booked(fixture_date, fixture_time_slot, null) then
    raise exception 'This date and time already has 2 matches.';
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

  perform public.cancel_underfilled_fixtures();

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

grant execute on function public.fixture_start_at(date, text) to authenticated;
grant execute on function public.fixture_active_slot_count(date, text, uuid) to authenticated;
grant execute on function public.fixture_slot_is_booked(date, text, uuid) to authenticated;
grant execute on function public.cancel_underfilled_fixtures() to authenticated;
