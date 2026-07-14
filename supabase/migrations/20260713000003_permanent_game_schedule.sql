alter table public.fixtures
drop constraint if exists fixtures_day_check;

alter table public.fixtures
drop constraint if exists fixtures_time_slot_check;

alter table public.fixtures
drop constraint if exists fixtures_day_matches_date_check;

alter table public.fixtures
add constraint fixtures_day_check
check (day in ('TUESDAY', 'FRIDAY')) not valid;

alter table public.fixtures
add constraint fixtures_time_slot_check
check (time_slot = '7:00 PM - 8:00 PM') not valid;

alter table public.fixtures
add constraint fixtures_day_matches_date_check
check (
  (day = 'TUESDAY' and extract(isodow from match_date) = 2)
  or (day = 'FRIDAY' and extract(isodow from match_date) = 5)
) not valid;

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

  if not public.is_clan_manager(home_clan_id_to_use, auth.uid()) then
    raise exception 'Only clan owners and leaders can host a match.';
  end if;

  if public.clan_member_count(home_clan_id_to_use) < 7 then
    raise exception 'Your clan needs at least 7 players before paying for a match.';
  end if;

  if fixture_date < current_date then
    raise exception 'Match date cannot be in the past.';
  end if;

  if fixture_time_slot is distinct from '7:00 PM - 8:00 PM' then
    raise exception 'Clan matches can only be scheduled from 7:00 PM to 8:00 PM.';
  end if;

  fixture_day := case extract(isodow from fixture_date)
    when 2 then 'TUESDAY'
    when 5 then 'FRIDAY'
    else null
  end;

  if fixture_day is null then
    raise exception 'Clan matches can only be hosted on Tuesday or Friday.';
  end if;

  if public.fixture_start_at(fixture_date, fixture_time_slot) <= now() + interval '24 hours' then
    raise exception 'Open matches must be hosted more than 24 hours before kickoff.';
  end if;

  if public.fixture_slot_is_booked(fixture_date, fixture_time_slot, null) then
    raise exception 'This date and time is already booked.';
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
    created_by,
    home_paid_by,
    home_paid_at
  )
  values (
    home_clan_id_to_use,
    trim(fixture_venue),
    fixture_day,
    fixture_time_slot,
    fixture_date,
    auth.uid(),
    auth.uid(),
    now()
  )
  returning * into created_fixture;

  return created_fixture;
end;
$$;

revoke all on function public.create_fixture(uuid, text, date, text)
from public, anon;
grant execute on function public.create_fixture(uuid, text, date, text)
to authenticated;

alter table public.open_queue_games
drop constraint if exists open_queue_games_permanent_timezone_check;

alter table public.open_queue_games
drop constraint if exists open_queue_games_permanent_schedule_check;

alter table public.open_queue_games
add constraint open_queue_games_permanent_timezone_check
check (timezone = 'Asia/Bahrain') not valid;

alter table public.open_queue_games
add constraint open_queue_games_permanent_schedule_check
check (
  extract(
    isodow from (starts_at at time zone 'Asia/Bahrain')
  ) in (2, 5)
  and (starts_at at time zone 'Asia/Bahrain')::time = time '20:30:00'
  and ends_at = starts_at + interval '1 hour'
) not valid;

create or replace function public.enforce_open_queue_permanent_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  local_start timestamp;
begin
  if new.timezone is distinct from 'Asia/Bahrain' then
    raise exception 'Open Queue games must use the Asia/Bahrain timezone.';
  end if;

  if new.starts_at is null then
    raise exception 'Open Queue games need a start time.';
  end if;

  if new.ends_at is null then
    raise exception 'Open Queue games need an end time.';
  end if;

  local_start := new.starts_at at time zone 'Asia/Bahrain';

  if extract(isodow from local_start) not in (2, 5) then
    raise exception 'Open Queue games can only be scheduled on Tuesday or Friday.';
  end if;

  if local_start::time is distinct from time '20:30:00' then
    raise exception 'Open Queue games must start at 8:30 PM Bahrain time.';
  end if;

  if new.ends_at is distinct from new.starts_at + interval '1 hour' then
    raise exception 'Open Queue games must run from 8:30 PM to 9:30 PM.';
  end if;

  if new.status <> 'CANCELLED' then
    perform pg_advisory_xact_lock(
      hashtextextended(
        'open-queue-start|' || extract(epoch from new.starts_at)::text,
        0
      )
    );

    if exists (
      select 1
      from public.open_queue_games existing
      where existing.starts_at = new.starts_at
        and existing.status <> 'CANCELLED'
        and existing.id <> new.id
    ) then
      raise exception 'An Open Queue game already exists at that start time.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_open_queue_permanent_schedule
on public.open_queue_games;
create trigger enforce_open_queue_permanent_schedule
before insert or update of status, starts_at, ends_at, timezone
on public.open_queue_games
for each row execute function public.enforce_open_queue_permanent_schedule();

drop index if exists public.open_queue_games_one_active_start_idx;
create unique index open_queue_games_one_active_start_idx
on public.open_queue_games (starts_at)
where status <> 'CANCELLED';

revoke all on function public.enforce_open_queue_permanent_schedule()
from public, anon, authenticated;
