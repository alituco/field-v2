create or replace function public.clan_member_count(clan_id_to_check uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.clan_members
  where clan_id = clan_id_to_check;
$$;

create or replace function public.ensure_clan_member_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  current_member_count integer;
begin
  if tg_op = 'UPDATE' and old.clan_id = new.clan_id then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext(new.clan_id::text)::bigint);

  select public.clan_member_count(new.clan_id)
  into current_member_count;

  if current_member_count >= 20 then
    raise exception 'Clans can have a maximum of 20 players.';
  end if;

  return new;
end;
$$;

drop trigger if exists ensure_clan_member_limit on public.clan_members;
create trigger ensure_clan_member_limit
before insert or update of clan_id
on public.clan_members
for each row
execute function public.ensure_clan_member_limit();

create or replace function public.ensure_fixture_clans_have_minimum_roster()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('OPEN', 'SCHEDULED', 'LIVE') then
    if public.clan_member_count(new.home_clan_id) < 7 then
      raise exception 'Your clan needs at least 7 players before paying for a match.';
    end if;

    if new.away_clan_id is not null
      and public.clan_member_count(new.away_clan_id) < 7 then
      raise exception 'Your clan needs at least 7 players before paying for a match.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists ensure_fixture_clans_have_minimum_roster on public.fixtures;
create trigger ensure_fixture_clans_have_minimum_roster
before insert or update of status, home_clan_id, away_clan_id
on public.fixtures
for each row
execute function public.ensure_fixture_clans_have_minimum_roster();

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

  if public.clan_member_count(home_clan_id_to_use) < 7 then
    raise exception 'Your clan needs at least 7 players before paying for a match.';
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

  if public.clan_member_count(away_clan_id_to_use) < 7 then
    raise exception 'Your clan needs at least 7 players before paying for a match.';
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

grant execute on function public.clan_member_count(uuid) to authenticated;
grant execute on function public.create_fixture(uuid, text, date, text)
to authenticated;
grant execute on function public.join_fixture(uuid, uuid) to authenticated;
