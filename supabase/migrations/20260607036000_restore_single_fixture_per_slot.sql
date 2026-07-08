update public.fixtures
set
  status = 'CANCELLED',
  cancelled_at = coalesce(cancelled_at, now()),
  cancellation_reason = coalesce(
    cancellation_reason,
    'Cancelled because another match already owns this date and time slot.'
  ),
  updated_at = now()
where id in (
  select id
  from (
    select
      id,
      row_number() over (
        partition by match_date, time_slot
        order by created_at, id
      ) as slot_rank
    from public.fixtures
    where status in ('OPEN', 'SCHEDULED', 'LIVE')
  ) ranked
  where slot_rank > 1
);

drop index if exists public.fixtures_active_slot_idx;

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
  select public.fixture_active_slot_count(
    fixture_date_to_check,
    fixture_time_slot_to_check,
    fixture_id_to_ignore
  ) >= 1;
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
    ) >= 1 then
      raise exception 'This date and time is already booked.';
    end if;
  end if;

  return new;
end;
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

grant execute on function public.create_fixture(uuid, text, date, text)
to authenticated;
