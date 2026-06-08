create unique index if not exists fixtures_one_active_match_per_slot_idx
on public.fixtures (match_date, time_slot)
where status in ('OPEN', 'SCHEDULED', 'LIVE');

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

grant execute on function public.fixture_slot_is_booked(date, text, uuid)
to authenticated;
