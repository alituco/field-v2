create or replace function public.list_open_queue_fixture_games()
returns table (
  id uuid,
  status text,
  venue text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  price_fils integer,
  age_label text,
  capacity integer,
  confirmed_count integer,
  goalkeeper_spots integer,
  defender_spots integer,
  midfielder_spots integer,
  attacker_spots integer,
  white_score integer,
  black_score integer,
  my_booking_id uuid,
  my_booking_role text,
  my_booking_team text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    game.id,
    game.status,
    game.venue,
    game.starts_at,
    game.ends_at,
    game.timezone,
    game.price_fils,
    game.age_label,
    game.capacity,
    booking_counts.confirmed_count,
    greatest(
      0,
      game.goalkeeper_capacity - booking_counts.goalkeeper_count
    ),
    greatest(
      0,
      game.defender_capacity - booking_counts.defender_count
    ),
    greatest(
      0,
      game.midfielder_capacity - booking_counts.midfielder_count
    ),
    greatest(
      0,
      game.attacker_capacity - booking_counts.attacker_count
    ),
    game.white_score,
    game.black_score,
    my_booking.id,
    my_booking.role,
    my_booking.team
  from public.open_queue_games game
  cross join lateral (
    select
      count(*)::integer as confirmed_count,
      (count(*) filter (where booking.role = 'GK'))::integer
        as goalkeeper_count,
      (count(*) filter (where booking.role = 'DEF'))::integer
        as defender_count,
      (count(*) filter (where booking.role = 'MID'))::integer
        as midfielder_count,
      (count(*) filter (where booking.role = 'ATT'))::integer
        as attacker_count
    from public.open_queue_bookings booking
    where booking.game_id = game.id
      and booking.status = 'CONFIRMED'
  ) booking_counts
  left join lateral (
    select
      booking.id,
      booking.role,
      booking.team
    from public.open_queue_bookings booking
    where booking.game_id = game.id
      and booking.profile_id = auth.uid()
      and booking.status = 'CONFIRMED'
    order by booking.booked_at desc
    limit 1
  ) my_booking on true
  where game.status <> 'CANCELLED'
  order by game.starts_at, game.id;
end;
$$;

revoke all on function public.list_open_queue_fixture_games()
from public, anon, authenticated;
grant execute on function public.list_open_queue_fixture_games()
to authenticated;

comment on function public.list_open_queue_fixture_games() is
  'Lists non-cancelled solo games for the Fixtures tab with aggregate availability and only the caller''s booking metadata.';
