create table if not exists public.player_ratings (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  skill_rating integer not null default 1200 check (skill_rating >= 0),
  matches_played integer not null default 0 check (matches_played >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  draws integer not null default 0 check (draws >= 0),
  last_change integer not null default 0,
  region text not null default 'bahrain' check (
    char_length(trim(region)) between 2 and 40
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.player_ratings (profile_id)
select id from public.profiles
on conflict (profile_id) do nothing;

create or replace function public.ensure_profile_player_rating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_ratings (profile_id)
  values (new.id)
  on conflict (profile_id) do nothing;
  return new;
end;
$$;

drop trigger if exists ensure_profile_player_rating on public.profiles;
create trigger ensure_profile_player_rating
after insert on public.profiles
for each row execute function public.ensure_profile_player_rating();

drop trigger if exists set_player_ratings_updated_at on public.player_ratings;
create trigger set_player_ratings_updated_at
before update on public.player_ratings
for each row execute function public.set_updated_at();

create table if not exists public.player_rating_events (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  source_type text not null check (
    source_type in ('CLAN_FIXTURE', 'OPEN_QUEUE')
  ),
  source_id uuid not null,
  side text not null check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  result text not null check (result in ('WIN', 'LOSS', 'DRAW')),
  rating_before integer not null check (rating_before >= 0),
  rating_change integer not null,
  rating_after integer not null check (rating_after >= 0),
  created_at timestamptz not null default now(),
  unique (source_type, source_id, profile_id)
);

create index if not exists player_rating_events_profile_idx
on public.player_rating_events (profile_id, created_at desc);

create table if not exists public.fixture_player_appearances (
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  clan_id uuid not null references public.clans(id) on delete cascade,
  side text not null check (side in ('HOME', 'AWAY')),
  played boolean not null default false,
  rating_at_start integer not null check (rating_at_start >= 0),
  rating_change integer,
  created_at timestamptz not null default now(),
  primary key (fixture_id, profile_id)
);

create index if not exists fixture_player_appearances_profile_idx
on public.fixture_player_appearances (profile_id, fixture_id);

create or replace function public.snapshot_fixture_player_appearances(
  fixture_id_to_snapshot uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_to_snapshot public.fixtures%rowtype;
begin
  select * into fixture_to_snapshot
  from public.fixtures
  where id = fixture_id_to_snapshot;

  if fixture_to_snapshot.id is null
    or fixture_to_snapshot.away_clan_id is null then
    return;
  end if;

  insert into public.player_ratings (profile_id)
  select cm.profile_id
  from public.clan_members cm
  where cm.clan_id in (
    fixture_to_snapshot.home_clan_id,
    fixture_to_snapshot.away_clan_id
  )
    and cm.left_at is null
  on conflict (profile_id) do nothing;

  insert into public.fixture_player_appearances (
    fixture_id,
    profile_id,
    clan_id,
    side,
    rating_at_start
  )
  select
    fixture_to_snapshot.id,
    cm.profile_id,
    cm.clan_id,
    case
      when cm.clan_id = fixture_to_snapshot.home_clan_id then 'HOME'
      else 'AWAY'
    end,
    pr.skill_rating
  from public.clan_members cm
  join public.player_ratings pr on pr.profile_id = cm.profile_id
  where cm.clan_id in (
    fixture_to_snapshot.home_clan_id,
    fixture_to_snapshot.away_clan_id
  )
    and cm.left_at is null
  on conflict (fixture_id, profile_id) do nothing;
end;
$$;

create or replace function public.snapshot_fixture_players_when_live()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'LIVE' and old.status is distinct from new.status then
    perform public.snapshot_fixture_player_appearances(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists snapshot_fixture_players_when_live on public.fixtures;
create trigger snapshot_fixture_players_when_live
after update of status on public.fixtures
for each row execute function public.snapshot_fixture_players_when_live();

create or replace function public.apply_clan_fixture_player_ratings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  participant record;
  opponent_average numeric;
  actual_score numeric;
  expected_score numeric;
  raw_change numeric;
  computed_change integer;
  current_rating integer;
  next_rating integer;
  result_to_use text;
  inserted_event uuid;
begin
  if new.status <> 'FINAL' or old.status = 'FINAL' then
    return new;
  end if;

  if new.home_score is null or new.away_score is null then
    return new;
  end if;

  perform public.snapshot_fixture_player_appearances(new.id);

  for participant in
    select appearance.*
    from public.fixture_player_appearances appearance
    where appearance.fixture_id = new.id
      and appearance.played = true
    order by appearance.profile_id
  loop
    select skill_rating into current_rating
    from public.player_ratings
    where profile_id = participant.profile_id
    for update;

    select avg(opponent.rating_at_start)::numeric
    into opponent_average
    from public.fixture_player_appearances opponent
    where opponent.fixture_id = new.id
      and opponent.played = true
      and opponent.side <> participant.side;

    if opponent_average is null then
      continue;
    end if;

    if new.home_score = new.away_score then
      actual_score := 0.5;
      result_to_use := 'DRAW';
    elsif
      (participant.side = 'HOME' and new.home_score > new.away_score)
      or (participant.side = 'AWAY' and new.away_score > new.home_score)
    then
      actual_score := 1;
      result_to_use := 'WIN';
    else
      actual_score := 0;
      result_to_use := 'LOSS';
    end if;

    expected_score := 1 / (
      1 + power(
        10::numeric,
        ((opponent_average - participant.rating_at_start)::numeric / 400)
      )
    );
    raw_change := 24 * (actual_score - expected_score);
    computed_change := round(raw_change)::integer;

    if result_to_use = 'WIN' and computed_change < 3 then
      computed_change := 3;
    elsif result_to_use = 'LOSS' and computed_change > -3 then
      computed_change := -3;
    end if;

    computed_change := greatest(-32, least(32, computed_change));
    next_rating := greatest(0, current_rating + computed_change);
    inserted_event := null;

    insert into public.player_rating_events (
      profile_id,
      source_type,
      source_id,
      side,
      result,
      rating_before,
      rating_change,
      rating_after
    )
    values (
      participant.profile_id,
      'CLAN_FIXTURE',
      new.id,
      participant.side,
      result_to_use,
      current_rating,
      computed_change,
      next_rating
    )
    on conflict (source_type, source_id, profile_id) do nothing
    returning id into inserted_event;

    if inserted_event is not null then
      update public.player_ratings
      set
        skill_rating = next_rating,
        matches_played = matches_played + 1,
        wins = wins + case when result_to_use = 'WIN' then 1 else 0 end,
        losses = losses + case when result_to_use = 'LOSS' then 1 else 0 end,
        draws = draws + case when result_to_use = 'DRAW' then 1 else 0 end,
        last_change = computed_change
      where profile_id = participant.profile_id;

      update public.fixture_player_appearances
      set rating_change = computed_change
      where fixture_id = new.id
        and profile_id = participant.profile_id;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists apply_clan_fixture_player_ratings on public.fixtures;
create trigger apply_clan_fixture_player_ratings
after update of status on public.fixtures
for each row execute function public.apply_clan_fixture_player_ratings();

create table if not exists public.open_queue_games (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'FULL', 'LIVE', 'FINAL', 'CANCELLED')
  ),
  venue text not null check (char_length(trim(venue)) between 2 and 80),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  timezone text not null default 'Asia/Bahrain',
  price_fils integer not null default 3000 check (price_fils >= 0),
  age_label text not null default 'All ages' check (
    char_length(trim(age_label)) between 2 and 40
  ),
  capacity integer not null default 12 check (capacity = 12),
  goalkeeper_capacity integer not null default 2 check (goalkeeper_capacity = 2),
  defender_capacity integer not null default 4 check (defender_capacity = 4),
  midfielder_capacity integer not null default 4 check (midfielder_capacity = 4),
  attacker_capacity integer not null default 2 check (attacker_capacity = 2),
  white_score integer check (white_score >= 0),
  black_score integer check (black_score >= 0),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (
    goalkeeper_capacity + defender_capacity + midfielder_capacity +
    attacker_capacity = capacity
  )
);

create unique index if not exists open_queue_games_venue_start_unique_idx
on public.open_queue_games (lower(venue), starts_at)
where status <> 'CANCELLED';

create index if not exists open_queue_games_start_idx
on public.open_queue_games (starts_at, status);

drop trigger if exists set_open_queue_games_updated_at on public.open_queue_games;
create trigger set_open_queue_games_updated_at
before update on public.open_queue_games
for each row execute function public.set_updated_at();

create table if not exists public.open_queue_bookings (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.open_queue_games(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('GK', 'DEF', 'MID', 'ATT')),
  status text not null default 'CONFIRMED' check (
    status in ('CONFIRMED', 'CANCELLED')
  ),
  team text check (team in ('WHITE', 'BLACK')),
  player_rating_at_booking integer not null check (
    player_rating_at_booking >= 0
  ),
  amount_paid_fils integer not null check (amount_paid_fils >= 0),
  payment_method text not null check (
    payment_method in ('APPLE_PAY', 'BENEFITPAY', 'MOCK')
  ),
  payment_reference text,
  payment_status text not null default 'PAID' check (
    payment_status in ('PAID', 'PARTIALLY_REFUNDED', 'NO_REFUND')
  ),
  booked_at timestamptz not null default now(),
  cancelled_at timestamptz,
  refund_percent integer check (refund_percent in (0, 50)),
  refund_amount_fils integer check (refund_amount_fils >= 0),
  refund_status text check (refund_status in ('NOT_DUE', 'DUE')),
  updated_at timestamptz not null default now()
);

create unique index if not exists open_queue_active_booking_unique_idx
on public.open_queue_bookings (game_id, profile_id)
where status = 'CONFIRMED';

create index if not exists open_queue_bookings_game_role_idx
on public.open_queue_bookings (game_id, role, status);

create index if not exists open_queue_bookings_profile_idx
on public.open_queue_bookings (profile_id, booked_at desc);

drop trigger if exists set_open_queue_bookings_updated_at on public.open_queue_bookings;
create trigger set_open_queue_bookings_updated_at
before update on public.open_queue_bookings
for each row execute function public.set_updated_at();

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
begin
  if new.status <> 'CONFIRMED' then
    return new;
  end if;

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
before insert or update of game_id, role, status
on public.open_queue_bookings
for each row execute function public.enforce_open_queue_booking_capacity();

create or replace function public.sync_open_queue_game_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_id_to_sync uuid;
  confirmed_count integer;
  game_capacity integer;
begin
  if tg_op = 'DELETE' then
    game_id_to_sync := old.game_id;
  else
    game_id_to_sync := new.game_id;
  end if;

  select capacity into game_capacity
  from public.open_queue_games
  where id = game_id_to_sync;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings
  where game_id = game_id_to_sync
    and status = 'CONFIRMED';

  update public.open_queue_games
  set status = case
    when confirmed_count >= game_capacity then 'FULL'
    else 'OPEN'
  end
  where id = game_id_to_sync
    and status in ('OPEN', 'FULL');

  if confirmed_count >= game_capacity then
    perform public.assign_open_queue_teams(game_id_to_sync);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_open_queue_game_status on public.open_queue_bookings;
create trigger sync_open_queue_game_status
after insert or update of status or delete
on public.open_queue_bookings
for each row execute function public.sync_open_queue_game_status();

create or replace function public.assign_open_queue_teams(
  game_id_to_assign uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  with ranked as (
    select
      booking.id,
      booking.role,
      row_number() over (
        partition by booking.role
        order by booking.player_rating_at_booking desc, booking.booked_at, booking.id
      ) as role_rank
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_assign
      and booking.status = 'CONFIRMED'
  )
  update public.open_queue_bookings booking
  set team = case
    when ranked.role in ('GK', 'ATT') then
      case when ranked.role_rank = 1 then 'WHITE' else 'BLACK' end
    else
      case when ranked.role_rank in (1, 4) then 'WHITE' else 'BLACK' end
  end
  from ranked
  where booking.id = ranked.id;
end;
$$;

create or replace function public.book_open_queue_game(
  game_id_to_book uuid,
  role_to_book text,
  payment_method_to_use text,
  payment_reference_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  game_to_book public.open_queue_games%rowtype;
  rating_to_use integer;
  booking_id uuid;
  confirmed_count integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  if role_to_book not in ('GK', 'DEF', 'MID', 'ATT') then
    raise exception 'Choose a valid position.';
  end if;

  if payment_method_to_use not in ('APPLE_PAY', 'BENEFITPAY', 'MOCK') then
    raise exception 'Choose a valid payment method.';
  end if;

  perform pg_advisory_xact_lock(hashtext(user_id::text)::bigint);

  select * into game_to_book
  from public.open_queue_games
  where id = game_id_to_book
  for update;

  if game_to_book.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_book.status <> 'OPEN' then
    raise exception 'This Open Queue game is full.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    where existing.game_id = game_to_book.id
      and existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
  ) then
    raise exception 'You already booked this Open Queue game.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    join public.open_queue_games other_game on other_game.id = existing.game_id
    where existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
      and other_game.status in ('OPEN', 'FULL', 'LIVE')
      and tstzrange(other_game.starts_at, other_game.ends_at, '[)') &&
          tstzrange(game_to_book.starts_at, game_to_book.ends_at, '[)')
  ) then
    raise exception 'You already have another game at this time.';
  end if;

  insert into public.player_ratings (profile_id)
  values (user_id)
  on conflict (profile_id) do nothing;

  select skill_rating into rating_to_use
  from public.player_ratings
  where profile_id = user_id
  for update;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    payment_method,
    payment_reference
  )
  values (
    game_to_book.id,
    user_id,
    role_to_book,
    rating_to_use,
    game_to_book.price_fils,
    payment_method_to_use,
    nullif(trim(payment_reference_to_use), '')
  )
  returning id into booking_id;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings
  where game_id = game_to_book.id
    and status = 'CONFIRMED';

  if confirmed_count = game_to_book.capacity then
    perform public.assign_open_queue_teams(game_to_book.id);
  end if;

  return booking_id;
end;
$$;

create or replace function public.preview_open_queue_cancellation(
  booking_id_to_preview uuid
)
returns table (
  can_cancel boolean,
  refund_percent integer,
  refund_amount_fils integer,
  refund_cutoff_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  booking_to_preview public.open_queue_bookings%rowtype;
  game_to_preview public.open_queue_games%rowtype;
  cutoff_at timestamptz;
  percent_to_refund integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into booking_to_preview
  from public.open_queue_bookings
  where id = booking_id_to_preview
    and profile_id = user_id;

  if booking_to_preview.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into game_to_preview
  from public.open_queue_games
  where id = booking_to_preview.game_id;

  cutoff_at := (
    (game_to_preview.starts_at at time zone game_to_preview.timezone)::date::timestamp
    at time zone game_to_preview.timezone
  );
  percent_to_refund := case when now() < cutoff_at then 50 else 0 end;

  return query select
    booking_to_preview.status = 'CONFIRMED' and now() < game_to_preview.starts_at,
    percent_to_refund,
    (booking_to_preview.amount_paid_fils * percent_to_refund / 100),
    cutoff_at;
end;
$$;

create or replace function public.cancel_open_queue_booking(
  booking_id_to_cancel uuid
)
returns public.open_queue_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  booking_to_cancel public.open_queue_bookings%rowtype;
  game_to_reopen public.open_queue_games%rowtype;
  cutoff_at timestamptz;
  percent_to_refund integer;
  cancelled_booking public.open_queue_bookings%rowtype;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select game.* into game_to_reopen
  from public.open_queue_bookings booking
  join public.open_queue_games game on game.id = booking.game_id
  where booking.id = booking_id_to_cancel
    and booking.profile_id = user_id
  for update of game;

  if game_to_reopen.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into booking_to_cancel
  from public.open_queue_bookings
  where id = booking_id_to_cancel
    and profile_id = user_id
  for update;

  if booking_to_cancel.status <> 'CONFIRMED' then
    raise exception 'This booking is already cancelled.';
  end if;

  if now() >= game_to_reopen.starts_at then
    raise exception 'This game has already started.';
  end if;

  cutoff_at := (
    (game_to_reopen.starts_at at time zone game_to_reopen.timezone)::date::timestamp
    at time zone game_to_reopen.timezone
  );
  percent_to_refund := case when now() < cutoff_at then 50 else 0 end;

  update public.open_queue_bookings
  set
    status = 'CANCELLED',
    team = null,
    cancelled_at = now(),
    refund_percent = percent_to_refund,
    refund_amount_fils = amount_paid_fils * percent_to_refund / 100,
    refund_status = case when percent_to_refund > 0 then 'DUE' else 'NOT_DUE' end,
    payment_status = case
      when percent_to_refund > 0 then 'PARTIALLY_REFUNDED'
      else 'NO_REFUND'
    end
  where id = booking_to_cancel.id
  returning * into cancelled_booking;

  update public.open_queue_bookings
  set team = null
  where game_id = game_to_reopen.id
    and status = 'CONFIRMED';

  return cancelled_booking;
end;
$$;

create or replace function public.list_open_queue_games()
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
  attacker_spots integer
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
    count(booking.id)::integer,
    greatest(
      0,
      game.goalkeeper_capacity -
      (count(booking.id) filter (where booking.role = 'GK'))::integer
    ),
    greatest(
      0,
      game.defender_capacity -
      (count(booking.id) filter (where booking.role = 'DEF'))::integer
    ),
    greatest(
      0,
      game.midfielder_capacity -
      (count(booking.id) filter (where booking.role = 'MID'))::integer
    ),
    greatest(
      0,
      game.attacker_capacity -
      (count(booking.id) filter (where booking.role = 'ATT'))::integer
    )
  from public.open_queue_games game
  left join public.open_queue_bookings booking
    on booking.game_id = game.id
    and booking.status = 'CONFIRMED'
  where game.status in ('OPEN', 'FULL')
    and game.starts_at > now()
  group by game.id
  order by game.starts_at
  limit 40;
end;
$$;

create or replace function public.list_player_rating_leaderboard(
  region_to_use text default 'bahrain'
)
returns table (
  rank bigint,
  profile_id uuid,
  display_name text,
  username text,
  avatar_url text,
  skill_rating integer,
  matches_played integer,
  wins integer,
  losses integer,
  draws integer,
  last_change integer,
  region text
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
    rank() over (
      order by rating.skill_rating desc, rating.matches_played desc, profile.display_name
    ),
    profile.id,
    profile.display_name,
    profile.username,
    profile.avatar_url,
    rating.skill_rating,
    rating.matches_played,
    rating.wins,
    rating.losses,
    rating.draws,
    rating.last_change,
    rating.region
  from public.player_ratings rating
  join public.profiles profile on profile.id = rating.profile_id
  where lower(rating.region) = lower(trim(region_to_use))
  order by rating.skill_rating desc, rating.matches_played desc, profile.display_name
  limit 100;
end;
$$;

create or replace function public.get_my_player_rating()
returns table (
  rank bigint,
  profile_id uuid,
  display_name text,
  username text,
  avatar_url text,
  skill_rating integer,
  matches_played integer,
  wins integer,
  losses integer,
  draws integer,
  last_change integer,
  region text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  return query
  select
    1 + (
      select count(*)
      from public.player_ratings ahead
      where lower(ahead.region) = lower(rating.region)
        and (
          ahead.skill_rating > rating.skill_rating
          or (
            ahead.skill_rating = rating.skill_rating
            and ahead.matches_played > rating.matches_played
          )
        )
    ),
    profile.id,
    profile.display_name,
    profile.username,
    profile.avatar_url,
    rating.skill_rating,
    rating.matches_played,
    rating.wins,
    rating.losses,
    rating.draws,
    rating.last_change,
    rating.region
  from public.player_ratings rating
  join public.profiles profile on profile.id = rating.profile_id
  where rating.profile_id = user_id;
end;
$$;

alter table public.player_ratings enable row level security;
alter table public.player_rating_events enable row level security;
alter table public.fixture_player_appearances enable row level security;
alter table public.open_queue_games enable row level security;
alter table public.open_queue_bookings enable row level security;

drop policy if exists "Player ratings are readable by authenticated users"
on public.player_ratings;
create policy "Player ratings are readable by authenticated users"
on public.player_ratings for select to authenticated using (true);

drop policy if exists "Users can read their own rating history"
on public.player_rating_events;
create policy "Users can read their own rating history"
on public.player_rating_events for select to authenticated
using (profile_id = auth.uid());

drop policy if exists "Fixture appearances are readable by authenticated users"
on public.fixture_player_appearances;
create policy "Fixture appearances are readable by authenticated users"
on public.fixture_player_appearances for select to authenticated using (true);

drop policy if exists "Open Queue games are readable by authenticated users"
on public.open_queue_games;
create policy "Open Queue games are readable by authenticated users"
on public.open_queue_games for select to authenticated using (true);

drop policy if exists "Users can read their own Open Queue bookings"
on public.open_queue_bookings;
create policy "Users can read their own Open Queue bookings"
on public.open_queue_bookings for select to authenticated
using (profile_id = auth.uid());

revoke insert, update, delete on public.player_ratings from authenticated;
revoke insert, update, delete on public.player_rating_events from authenticated;
revoke insert, update, delete on public.fixture_player_appearances from authenticated;
revoke insert, update, delete on public.open_queue_games from authenticated;
revoke insert, update, delete on public.open_queue_bookings from authenticated;

revoke execute on function public.ensure_profile_player_rating() from public;
revoke execute on function public.snapshot_fixture_player_appearances(uuid) from public;
revoke execute on function public.snapshot_fixture_players_when_live() from public;
revoke execute on function public.apply_clan_fixture_player_ratings() from public;
revoke execute on function public.enforce_open_queue_booking_capacity() from public;
revoke execute on function public.sync_open_queue_game_status() from public;
revoke execute on function public.assign_open_queue_teams(uuid) from public;

revoke execute on function public.book_open_queue_game(uuid, text, text, text)
from public;
revoke execute on function public.preview_open_queue_cancellation(uuid)
from public;
revoke execute on function public.cancel_open_queue_booking(uuid)
from public;
revoke execute on function public.list_open_queue_games() from public;
revoke execute on function public.list_player_rating_leaderboard(text)
from public;
revoke execute on function public.get_my_player_rating() from public;

grant execute on function public.book_open_queue_game(uuid, text, text, text)
to authenticated;
grant execute on function public.preview_open_queue_cancellation(uuid)
to authenticated;
grant execute on function public.cancel_open_queue_booking(uuid)
to authenticated;
grant execute on function public.list_open_queue_games() to authenticated;
grant execute on function public.list_player_rating_leaderboard(text)
to authenticated;
grant execute on function public.get_my_player_rating() to authenticated;

revoke all on function public.snapshot_fixture_player_appearances(uuid)
from public, anon, authenticated;
revoke all on function public.assign_open_queue_teams(uuid)
from public, anon, authenticated;

revoke all on function public.book_open_queue_game(uuid, text, text, text)
from public, anon;
grant execute on function public.book_open_queue_game(uuid, text, text, text)
to authenticated;

revoke all on function public.preview_open_queue_cancellation(uuid)
from public, anon;
grant execute on function public.preview_open_queue_cancellation(uuid)
to authenticated;

revoke all on function public.cancel_open_queue_booking(uuid)
from public, anon;
grant execute on function public.cancel_open_queue_booking(uuid)
to authenticated;

revoke all on function public.list_open_queue_games()
from public, anon;
grant execute on function public.list_open_queue_games()
to authenticated;

revoke all on function public.list_player_rating_leaderboard(text)
from public, anon;
grant execute on function public.list_player_rating_leaderboard(text)
to authenticated;

grant select on public.player_ratings to authenticated;
grant select on public.player_rating_events to authenticated;
grant select on public.fixture_player_appearances to authenticated;
grant select on public.open_queue_games to authenticated;
grant select on public.open_queue_bookings to authenticated;
