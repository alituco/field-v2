create index if not exists fixtures_upcoming_home_clan_idx
on public.fixtures (home_clan_id, match_date)
where status in ('OPEN', 'SCHEDULED');

create index if not exists fixtures_upcoming_away_clan_idx
on public.fixtures (away_clan_id, match_date)
where status in ('OPEN', 'SCHEDULED') and away_clan_id is not null;

create index if not exists open_queue_confirmed_profile_game_idx
on public.open_queue_bookings (profile_id, game_id)
where status = 'CONFIRMED';

create or replace function public.clan_upcoming_fixture_count(
  clan_id_to_check uuid,
  fixture_id_to_ignore uuid default null
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.fixtures fixture
  where fixture.status in ('OPEN', 'SCHEDULED')
    and public.fixture_start_at(fixture.match_date, fixture.time_slot) > now()
    and (
      fixture.home_clan_id = clan_id_to_check
      or fixture.away_clan_id = clan_id_to_check
    )
    and (
      fixture_id_to_ignore is null
      or fixture.id <> fixture_id_to_ignore
    );
$$;

create or replace function public.enforce_clan_upcoming_fixture_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_is_upcoming boolean;
  old_is_upcoming boolean := false;
  candidate_clan_ids uuid[] := array[]::uuid[];
  clan_id_to_check uuid;
begin
  new_is_upcoming := new.status in ('OPEN', 'SCHEDULED')
    and public.fixture_start_at(new.match_date, new.time_slot) > now();

  if not new_is_upcoming then
    return new;
  end if;

  if tg_op = 'INSERT' then
    candidate_clan_ids := array[new.home_clan_id, new.away_clan_id];
  else
    old_is_upcoming := old.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(old.match_date, old.time_slot) > now();

    if not old_is_upcoming
      or not (
        coalesce(old.home_clan_id = new.home_clan_id, false)
        or coalesce(old.away_clan_id = new.home_clan_id, false)
      )
    then
      candidate_clan_ids := array_append(
        candidate_clan_ids,
        new.home_clan_id
      );
    end if;

    if new.away_clan_id is not null
      and (
        not old_is_upcoming
        or not (
          coalesce(old.home_clan_id = new.away_clan_id, false)
          or coalesce(old.away_clan_id = new.away_clan_id, false)
        )
      )
    then
      candidate_clan_ids := array_append(
        candidate_clan_ids,
        new.away_clan_id
      );
    end if;
  end if;

  for clan_id_to_check in
    select distinct candidate.clan_id
    from unnest(candidate_clan_ids) as candidate(clan_id)
    where candidate.clan_id is not null
    order by candidate.clan_id
  loop
    perform pg_advisory_xact_lock(
      hashtext('clan-upcoming|' || clan_id_to_check::text)::bigint
    );
  end loop;

  for clan_id_to_check in
    select distinct candidate.clan_id
    from unnest(candidate_clan_ids) as candidate(clan_id)
    where candidate.clan_id is not null
    order by candidate.clan_id
  loop
    if public.clan_upcoming_fixture_count(
      clan_id_to_check,
      new.id
    ) >= 2 then
      raise exception 'Your clan can have a maximum of 2 upcoming matches. Finish or cancel one before scheduling another.';
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists enforce_clan_upcoming_fixture_limit
on public.fixtures;
create trigger enforce_clan_upcoming_fixture_limit
before insert or update of
  status,
  home_clan_id,
  away_clan_id,
  match_date,
  time_slot
on public.fixtures
for each row execute function public.enforce_clan_upcoming_fixture_limit();

create or replace function public.enforce_open_queue_booking_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_to_book public.open_queue_games%rowtype;
  confirmed_count integer;
  role_count integer;
  role_capacity integer;
  scheduled_count integer;
begin
  if new.status <> 'CONFIRMED' then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtext(new.profile_id::text)::bigint
  );

  select * into game_to_book
  from public.open_queue_games
  where id = new.game_id
  for update;

  if game_to_book.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_book.status not in ('OPEN', 'FULL') then
    raise exception 'This Open Queue game cannot accept bookings.';
  end if;

  if now() >= game_to_book.starts_at then
    raise exception 'This Open Queue game has already started.';
  end if;

  select count(*)::integer into scheduled_count
  from public.open_queue_bookings booking
  join public.open_queue_games game on game.id = booking.game_id
  where booking.profile_id = new.profile_id
    and booking.status = 'CONFIRMED'
    and booking.id <> new.id
    and game.status in ('OPEN', 'FULL')
    and game.starts_at > now();

  if scheduled_count >= 2 then
    raise exception 'You can have a maximum of 2 upcoming solo games. Cancel one before booking another.';
  end if;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings booking
  where booking.game_id = new.game_id
    and booking.status = 'CONFIRMED'
    and booking.id <> new.id;

  select count(*)::integer into role_count
  from public.open_queue_bookings booking
  where booking.game_id = new.game_id
    and booking.status = 'CONFIRMED'
    and booking.role = new.role
    and booking.id <> new.id;

  role_capacity := case new.role
    when 'GK' then game_to_book.goalkeeper_capacity
    when 'DEF' then game_to_book.defender_capacity
    when 'MID' then game_to_book.midfielder_capacity
    when 'ATT' then game_to_book.attacker_capacity
  end;

  if confirmed_count >= game_to_book.capacity then
    raise exception 'This Open Queue game is full.';
  end if;

  if role_count >= role_capacity then
    raise exception 'That position just filled. Choose another game or position.';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_open_queue_booking_capacity
on public.open_queue_bookings;
create trigger enforce_open_queue_booking_capacity
before insert or update of game_id, profile_id, role, status
on public.open_queue_bookings
for each row execute function public.enforce_open_queue_booking_capacity();

revoke all on function public.clan_upcoming_fixture_count(uuid, uuid)
from public, anon, authenticated;

revoke all on function public.enforce_clan_upcoming_fixture_limit()
from public, anon, authenticated;

revoke all on function public.enforce_open_queue_booking_capacity()
from public, anon, authenticated;
