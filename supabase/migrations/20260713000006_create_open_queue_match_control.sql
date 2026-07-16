alter table public.open_queue_games
add column if not exists video_url text;

alter table public.open_queue_bookings
add column if not exists played boolean not null default false;

create index if not exists open_queue_bookings_played_profile_idx
on public.open_queue_bookings (profile_id, game_id)
where status = 'CONFIRMED' and played;

create table if not exists public.open_queue_referee_assignments (
  game_id uuid primary key
    references public.open_queue_games(id) on delete cascade,
  referee_id uuid not null
    references public.referee_profiles(profile_id) on delete restrict,
  assigned_by uuid
    references public.referee_profiles(profile_id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists open_queue_referee_assignments_referee_idx
on public.open_queue_referee_assignments (referee_id, created_at desc);

drop trigger if exists set_open_queue_referee_assignments_updated_at
on public.open_queue_referee_assignments;
create trigger set_open_queue_referee_assignments_updated_at
before update on public.open_queue_referee_assignments
for each row execute function public.set_updated_at();

create table if not exists public.open_queue_clock_states (
  game_id uuid primary key
    references public.open_queue_games(id) on delete cascade,
  status text not null default 'NOT_STARTED' check (
    status in ('NOT_STARTED', 'RUNNING', 'PAUSED', 'ENDED')
  ),
  started_at timestamptz,
  accumulated_seconds integer not null default 0 check (
    accumulated_seconds between 0 and 10800
  ),
  duration_seconds integer not null default 3600 check (
    duration_seconds between 600 and 14400
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'RUNNING' and started_at is not null)
    or status <> 'RUNNING'
  )
);

drop trigger if exists set_open_queue_clock_states_updated_at
on public.open_queue_clock_states;
create trigger set_open_queue_clock_states_updated_at
before update on public.open_queue_clock_states
for each row execute function public.set_updated_at();

create table if not exists public.open_queue_goals (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null
    references public.open_queue_games(id) on delete cascade,
  team text not null check (team in ('WHITE', 'BLACK')),
  profile_id uuid not null
    references public.profiles(id) on delete restrict,
  assist_profile_id uuid
    references public.profiles(id) on delete set null,
  minute integer not null check (minute between 1 and 240),
  created_at timestamptz not null default now(),
  check (assist_profile_id is null or assist_profile_id <> profile_id)
);

create index if not exists open_queue_goals_game_minute_idx
on public.open_queue_goals (game_id, minute, created_at);

create index if not exists open_queue_goals_profile_idx
on public.open_queue_goals (profile_id, created_at desc);

create index if not exists open_queue_goals_assist_profile_idx
on public.open_queue_goals (assist_profile_id, created_at desc)
where assist_profile_id is not null;

create table if not exists public.open_queue_events (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null
    references public.open_queue_games(id) on delete cascade,
  event_type text not null check (
    event_type in (
      'MATCH_STARTED',
      'MATCH_PAUSED',
      'MATCH_RESUMED',
      'MATCH_ENDED',
      'GOAL',
      'BLUE_CARD',
      'BLUE_CARD_EXPIRED',
      'CORRECTION'
    )
  ),
  team text check (team in ('WHITE', 'BLACK')),
  profile_id uuid references public.profiles(id) on delete set null,
  assist_profile_id uuid references public.profiles(id) on delete set null,
  blue_card_id uuid,
  minute integer not null default 0 check (minute between 0 and 240),
  second integer not null default 0 check (second between 0 and 59),
  note text not null default '',
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (
    event_type not in ('GOAL', 'BLUE_CARD', 'BLUE_CARD_EXPIRED')
    or (team is not null and profile_id is not null)
  ),
  check (assist_profile_id is null or assist_profile_id <> profile_id)
);

create index if not exists open_queue_events_game_occurred_idx
on public.open_queue_events (game_id, occurred_at, created_at);

create index if not exists open_queue_events_profile_idx
on public.open_queue_events (profile_id, occurred_at desc)
where profile_id is not null;

create table if not exists public.open_queue_blue_cards (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null
    references public.open_queue_games(id) on delete cascade,
  team text not null check (team in ('WHITE', 'BLACK')),
  profile_id uuid not null
    references public.profiles(id) on delete cascade,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  duration_seconds integer not null default 120 check (
    duration_seconds between 30 and 600
  ),
  status text not null default 'ACTIVE' check (
    status in ('ACTIVE', 'EXPIRED', 'CLEARED')
  ),
  minute integer not null default 0 check (minute between 0 and 240),
  second integer not null default 0 check (second between 0 and 59),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > started_at)
);

alter table public.open_queue_events
drop constraint if exists open_queue_events_blue_card_id_fkey;
alter table public.open_queue_events
add constraint open_queue_events_blue_card_id_fkey
foreign key (blue_card_id)
references public.open_queue_blue_cards(id)
on delete set null;

create index if not exists open_queue_blue_cards_game_status_idx
on public.open_queue_blue_cards (game_id, status, expires_at);

create index if not exists open_queue_blue_cards_profile_idx
on public.open_queue_blue_cards (profile_id, created_at desc);

drop trigger if exists set_open_queue_blue_cards_updated_at
on public.open_queue_blue_cards;
create trigger set_open_queue_blue_cards_updated_at
before update on public.open_queue_blue_cards
for each row execute function public.set_updated_at();

create table if not exists public.open_queue_broadcasts (
  game_id uuid primary key
    references public.open_queue_games(id) on delete cascade,
  provider text not null default 'cloudflare' check (provider = 'cloudflare'),
  live_input_id text unique,
  active_video_id text,
  status text not null default 'NOT_CONFIGURED' check (
    status in (
      'NOT_CONFIGURED',
      'READY',
      'STARTING',
      'LIVE',
      'STOPPING',
      'PROCESSING',
      'REPLAY_READY',
      'ERROR'
    )
  ),
  hls_url text,
  replay_hls_url text,
  stream_requested_at timestamptz,
  stream_started_at timestamptz,
  stream_stopped_at timestamptz,
  recording_ready_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists open_queue_broadcasts_status_idx
on public.open_queue_broadcasts (status, updated_at desc);

drop trigger if exists set_open_queue_broadcasts_updated_at
on public.open_queue_broadcasts;
create trigger set_open_queue_broadcasts_updated_at
before update on public.open_queue_broadcasts
for each row execute function public.set_updated_at();

alter table public.broadcast_devices
add column if not exists current_open_queue_game_id uuid
references public.open_queue_games(id) on delete set null;

alter table public.broadcast_devices
drop constraint if exists broadcast_devices_one_current_match_check;
alter table public.broadcast_devices
add constraint broadcast_devices_one_current_match_check
check (
  current_fixture_id is null
  or current_open_queue_game_id is null
);

alter table public.broadcast_commands
add column if not exists open_queue_game_id uuid
references public.open_queue_games(id) on delete cascade;

alter table public.broadcast_commands
alter column fixture_id drop not null;

alter table public.broadcast_commands
drop constraint if exists broadcast_commands_one_match_target_check;
alter table public.broadcast_commands
add constraint broadcast_commands_one_match_target_check
check (
  (fixture_id is not null and open_queue_game_id is null)
  or (fixture_id is null and open_queue_game_id is not null)
);

create unique index if not exists broadcast_commands_open_queue_active_action_idx
on public.broadcast_commands (open_queue_game_id, action)
where open_queue_game_id is not null
  and status in ('PENDING', 'CLAIMED');

create index if not exists broadcast_commands_open_queue_game_idx
on public.broadcast_commands (open_queue_game_id, created_at desc)
where open_queue_game_id is not null;

create or replace function public.ensure_live_open_queue_game_has_started_clock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'LIVE' and old.status is distinct from 'LIVE' then
    if not exists (
      select 1
      from public.open_queue_clock_states clock
      where clock.game_id = new.id
        and clock.status in ('RUNNING', 'PAUSED')
    ) then
      raise exception 'An Open Queue game can only go live when the referee starts it.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists ensure_live_open_queue_game_has_started_clock
on public.open_queue_games;
create trigger ensure_live_open_queue_game_has_started_clock
before update of status on public.open_queue_games
for each row execute function public.ensure_live_open_queue_game_has_started_clock();

create or replace function public.validate_open_queue_goal_participants()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = new.game_id
      and booking.profile_id = new.profile_id
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = new.team
  ) then
    raise exception 'The scorer must be a confirmed player on that team.';
  end if;

  if new.assist_profile_id is not null and not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = new.game_id
      and booking.profile_id = new.assist_profile_id
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = new.team
  ) then
    raise exception 'The assisting player must be a confirmed player on that team.';
  end if;

  if not exists (
    select 1
    from public.open_queue_games game
    where game.id = new.game_id
      and game.status in ('LIVE', 'FINAL')
  ) then
    raise exception 'Goals can only be recorded for live or final Open Queue games.';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_open_queue_goal_participants
on public.open_queue_goals;
create trigger validate_open_queue_goal_participants
before insert or update of game_id, team, profile_id, assist_profile_id
on public.open_queue_goals
for each row execute function public.validate_open_queue_goal_participants();

create or replace function public.sync_open_queue_score_from_goals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_id_to_sync uuid;
begin
  game_id_to_sync := case when tg_op = 'DELETE' then old.game_id else new.game_id end;

  update public.open_queue_games game
  set
    white_score = (
      select count(*)::integer
      from public.open_queue_goals goal
      where goal.game_id = game_id_to_sync
        and goal.team = 'WHITE'
    ),
    black_score = (
      select count(*)::integer
      from public.open_queue_goals goal
      where goal.game_id = game_id_to_sync
        and goal.team = 'BLACK'
    )
  where game.id = game_id_to_sync
    and game.status in ('LIVE', 'FINAL');

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists sync_open_queue_score_from_goals
on public.open_queue_goals;
create trigger sync_open_queue_score_from_goals
after insert or update of game_id, team or delete
on public.open_queue_goals
for each row execute function public.sync_open_queue_score_from_goals();

create or replace function public.referee_complete_open_queue_game(
  game_id_to_complete uuid
)
returns public.open_queue_games
language plpgsql
security definer
set search_path = public
as $$
declare
  game_to_complete public.open_queue_games%rowtype;
  completed_game public.open_queue_games%rowtype;
  clock_to_stop public.open_queue_clock_states%rowtype;
  elapsed_seconds integer;
  white_score_to_use integer;
  black_score_to_use integer;
begin
  select *
  into game_to_complete
  from public.open_queue_games
  where id = game_id_to_complete
  for update;

  if game_to_complete.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_complete.status = 'FINAL' then
    raise exception 'This Open Queue game is already final.';
  end if;

  if game_to_complete.status <> 'LIVE' then
    raise exception 'Only a live Open Queue game can be finalized.';
  end if;

  select *
  into clock_to_stop
  from public.open_queue_clock_states
  where game_id = game_id_to_complete
  for update;

  if clock_to_stop.game_id is null then
    raise exception 'The Open Queue match clock has not been started.';
  end if;

  elapsed_seconds := least(
    10800,
    greatest(
      0,
      clock_to_stop.accumulated_seconds + case
        when clock_to_stop.status = 'RUNNING' and clock_to_stop.started_at is not null
          then greatest(
            0,
            floor(extract(epoch from (now() - clock_to_stop.started_at)))::integer
          )
        else 0
      end
    )
  );

  if not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_complete
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'WHITE'
  ) or not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_complete
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'BLACK'
  ) then
    raise exception 'Confirm at least one participating player on each team.';
  end if;

  select
    (count(*) filter (where goal.team = 'WHITE'))::integer,
    (count(*) filter (where goal.team = 'BLACK'))::integer
  into white_score_to_use, black_score_to_use
  from public.open_queue_goals goal
  where goal.game_id = game_id_to_complete;

  update public.open_queue_clock_states
  set
    status = 'ENDED',
    started_at = null,
    accumulated_seconds = elapsed_seconds
  where game_id = game_id_to_complete;

  if not exists (
    select 1
    from public.open_queue_events event
    where event.game_id = game_id_to_complete
      and event.event_type = 'MATCH_ENDED'
  ) then
    insert into public.open_queue_events (
      game_id,
      event_type,
      minute,
      second,
      occurred_at
    ) values (
      game_id_to_complete,
      'MATCH_ENDED',
      least(180, floor(elapsed_seconds / 60)::integer),
      elapsed_seconds % 60,
      now()
    );
  end if;

  update public.open_queue_blue_cards
  set status = 'CLEARED'
  where game_id = game_id_to_complete
    and status = 'ACTIVE';

  update public.open_queue_games
  set
    status = 'FINAL',
    white_score = coalesce(white_score_to_use, 0),
    black_score = coalesce(black_score_to_use, 0)
  where id = game_id_to_complete
  returning * into completed_game;

  return completed_game;
end;
$$;

create or replace function public.auto_stop_overdue_open_queue_clocks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  overdue_clock record;
  stopped_count integer := 0;
begin
  for overdue_clock in
    select clock.game_id
    from public.open_queue_clock_states clock
    join public.open_queue_games game on game.id = clock.game_id
    where game.status = 'LIVE'
      and (
        (
          clock.status = 'RUNNING'
          and clock.started_at is not null
          and clock.accumulated_seconds
            + greatest(
              0,
              floor(extract(epoch from (now() - clock.started_at)))::integer
            ) >= 10800
        )
        or (
          clock.status = 'PAUSED'
          and clock.accumulated_seconds >= 10800
        )
      )
    for update of clock skip locked
  loop
    begin
      update public.open_queue_clock_states
      set
        status = 'ENDED',
        started_at = null,
        accumulated_seconds = 10800
      where game_id = overdue_clock.game_id;

      if not exists (
        select 1
        from public.open_queue_events event
        where event.game_id = overdue_clock.game_id
          and event.event_type = 'MATCH_ENDED'
      ) then
        insert into public.open_queue_events (
          game_id,
          event_type,
          minute,
          second,
          note,
          occurred_at
        ) values (
          overdue_clock.game_id,
          'MATCH_ENDED',
          180,
          0,
          'Automatically stopped after 3 hours of playtime.',
          now()
        );
      end if;

      perform public.referee_complete_open_queue_game(overdue_clock.game_id);

      update public.open_queue_clock_states
      set
        status = 'ENDED',
        started_at = null,
        accumulated_seconds = 10800
      where game_id = overdue_clock.game_id;

      stopped_count := stopped_count + 1;
    exception
      when others then
        raise warning 'Could not auto-stop Open Queue game %: %',
          overdue_clock.game_id,
          sqlerrm;
    end;
  end loop;

  return stopped_count;
end;
$$;

create or replace function public.get_open_queue_match_detail(
  game_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  select jsonb_build_object(
    'id', game.id,
    'status', game.status,
    'venue', game.venue,
    'starts_at', game.starts_at,
    'ends_at', game.ends_at,
    'timezone', game.timezone,
    'price_fils', game.price_fils,
    'age_label', game.age_label,
    'capacity', game.capacity,
    'confirmed_count', booking_counts.confirmed_count,
    'goalkeeper_spots', greatest(
      0,
      game.goalkeeper_capacity - booking_counts.goalkeeper_count
    ),
    'defender_spots', greatest(
      0,
      game.defender_capacity - booking_counts.defender_count
    ),
    'midfielder_spots', greatest(
      0,
      game.midfielder_capacity - booking_counts.midfielder_count
    ),
    'attacker_spots', greatest(
      0,
      game.attacker_capacity - booking_counts.attacker_count
    ),
    'white_score', game.white_score,
    'black_score', game.black_score,
    'video_url', game.video_url,
    'my_booking_id', my_booking.id,
    'my_booking_role', my_booking.role,
    'my_booking_team', my_booking.team,
    'clock_status', clock.status,
    'clock_started_at', clock.started_at,
    'clock_accumulated_seconds', clock.accumulated_seconds,
    'clock_duration_seconds', clock.duration_seconds,
    'clock', case when clock.game_id is null then null else jsonb_build_object(
      'status', clock.status,
      'started_at', clock.started_at,
      'accumulated_seconds', clock.accumulated_seconds,
      'duration_seconds', clock.duration_seconds
    ) end,
    'players', players.items,
    'goals', goals.items,
    'scorers', goals.items,
    'events', events.items,
    'blue_cards', blue_cards.items,
    'broadcast_status', broadcast.status,
    'broadcast_hls_url', broadcast.hls_url,
    'broadcast_replay_hls_url', broadcast.replay_hls_url,
    'broadcast_stream_started_at', broadcast.stream_started_at,
    'broadcast_stream_stopped_at', broadcast.stream_stopped_at,
    'broadcast', case when broadcast.game_id is null then null else jsonb_build_object(
      'status', broadcast.status,
      'hls_url', broadcast.hls_url,
      'replay_hls_url', broadcast.replay_hls_url,
      'stream_started_at', broadcast.stream_started_at,
      'stream_stopped_at', broadcast.stream_stopped_at,
      'recording_ready_at', broadcast.recording_ready_at,
      'error_message', broadcast.error_message
    ) end
  )
  into result
  from public.open_queue_games game
  left join public.open_queue_clock_states clock
    on clock.game_id = game.id
  left join public.open_queue_broadcasts broadcast
    on broadcast.game_id = game.id
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
    select booking.id, booking.role, booking.team
    from public.open_queue_bookings booking
    where booking.game_id = game.id
      and booking.profile_id = auth.uid()
      and booking.status = 'CONFIRMED'
    order by booking.booked_at desc
    limit 1
  ) my_booking on true
  cross join lateral (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', profile.id,
          'display_name', profile.display_name,
          'username', profile.username,
          'avatar_url', profile.avatar_url,
          'role', booking.role,
          'team', booking.team,
          'played', booking.played
        ) order by booking.team, booking.role, profile.display_name, profile.id
      ),
      '[]'::jsonb
    ) as items
    from public.open_queue_bookings booking
    join public.profiles profile on profile.id = booking.profile_id
    where booking.game_id = game.id
      and booking.status = 'CONFIRMED'
  ) players
  cross join lateral (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', goal.id,
          'game_id', goal.game_id,
          'team', goal.team,
          'profile_id', goal.profile_id,
          'assist_profile_id', goal.assist_profile_id,
          'minute', goal.minute,
          'created_at', goal.created_at,
          'scorer', jsonb_build_object(
            'id', scorer.id,
            'display_name', scorer.display_name,
            'username', scorer.username,
            'avatar_url', scorer.avatar_url
          ),
          'assist', case when assist.id is null then null else jsonb_build_object(
            'id', assist.id,
            'display_name', assist.display_name,
            'username', assist.username,
            'avatar_url', assist.avatar_url
          ) end
        ) order by goal.minute, goal.created_at, goal.id
      ),
      '[]'::jsonb
    ) as items
    from public.open_queue_goals goal
    join public.profiles scorer on scorer.id = goal.profile_id
    left join public.profiles assist on assist.id = goal.assist_profile_id
    where goal.game_id = game.id
  ) goals
  cross join lateral (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', event.id,
          'game_id', event.game_id,
          'event_type', event.event_type,
          'team', event.team,
          'profile_id', event.profile_id,
          'assist_profile_id', event.assist_profile_id,
          'blue_card_id', event.blue_card_id,
          'minute', event.minute,
          'second', event.second,
          'note', event.note,
          'occurred_at', event.occurred_at,
          'created_at', event.created_at,
          'player', case when player.id is null then null else jsonb_build_object(
            'id', player.id,
            'display_name', player.display_name,
            'username', player.username,
            'avatar_url', player.avatar_url
          ) end,
          'assist', case when event_assist.id is null then null else jsonb_build_object(
            'id', event_assist.id,
            'display_name', event_assist.display_name,
            'username', event_assist.username,
            'avatar_url', event_assist.avatar_url
          ) end
        ) order by event.minute, event.second, event.occurred_at, event.id
      ),
      '[]'::jsonb
    ) as items
    from public.open_queue_events event
    left join public.profiles player on player.id = event.profile_id
    left join public.profiles event_assist on event_assist.id = event.assist_profile_id
    where event.game_id = game.id
  ) events
  cross join lateral (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', card.id,
          'game_id', card.game_id,
          'team', card.team,
          'profile_id', card.profile_id,
          'started_at', card.started_at,
          'expires_at', card.expires_at,
          'duration_seconds', card.duration_seconds,
          'status', card.status,
          'minute', card.minute,
          'second', card.second
        ) order by card.started_at, card.id
      ),
      '[]'::jsonb
    ) as items
    from public.open_queue_blue_cards card
    where card.game_id = game.id
  ) blue_cards
  where game.id = game_id_to_use;

  if result is null then
    raise exception 'Open Queue game not found.';
  end if;

  return result;
end;
$$;

drop function if exists public.list_profile_previous_games(uuid);
create function public.list_profile_previous_games(
  profile_id_to_use uuid
)
returns table (
  match_id uuid,
  match_type text,
  played_at timestamptz,
  venue text,
  home_name text,
  home_tag text,
  home_emblem text,
  away_name text,
  away_tag text,
  away_emblem text,
  home_score integer,
  away_score integer,
  player_side text,
  player_role text
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
  select previous.*
  from (
    select
      fixture.id as match_id,
      'CLAN'::text as match_type,
      public.fixture_start_at(fixture.match_date, fixture.time_slot) as played_at,
      fixture.venue,
      home.name as home_name,
      home.tag as home_tag,
      home.emblem as home_emblem,
      away.name as away_name,
      away.tag as away_tag,
      away.emblem as away_emblem,
      fixture.home_score,
      fixture.away_score,
      appearance.side as player_side,
      null::text as player_role
    from public.fixture_player_appearances appearance
    join public.fixtures fixture on fixture.id = appearance.fixture_id
    join public.clans home on home.id = fixture.home_clan_id
    join public.clans away on away.id = fixture.away_clan_id
    where appearance.profile_id = profile_id_to_use
      and appearance.played
      and fixture.status = 'FINAL'

    union all

    select
      game.id as match_id,
      'SOLO'::text as match_type,
      game.starts_at as played_at,
      game.venue,
      'White Team'::text as home_name,
      'WHITE'::text as home_tag,
      '⚪'::text as home_emblem,
      'Black Team'::text as away_name,
      'BLACK'::text as away_tag,
      '⚫'::text as away_emblem,
      game.white_score as home_score,
      game.black_score as away_score,
      booking.team as player_side,
      booking.role as player_role
    from public.open_queue_bookings booking
    join public.open_queue_games game on game.id = booking.game_id
    where booking.profile_id = profile_id_to_use
      and booking.status = 'CONFIRMED'
      and booking.played
      and game.status = 'FINAL'
  ) previous
  order by previous.played_at desc, previous.match_type, previous.match_id;
end;
$$;

alter table public.open_queue_referee_assignments enable row level security;
alter table public.open_queue_clock_states enable row level security;
alter table public.open_queue_goals enable row level security;
alter table public.open_queue_events enable row level security;
alter table public.open_queue_blue_cards enable row level security;
alter table public.open_queue_broadcasts enable row level security;

drop policy if exists "Referees can read their own Open Queue assignments"
on public.open_queue_referee_assignments;
create policy "Referees can read their own Open Queue assignments"
on public.open_queue_referee_assignments
for select
to authenticated
using (
  referee_id = auth.uid()
  or exists (
    select 1
    from public.referee_profiles referee
    where referee.profile_id = auth.uid()
      and referee.role = 'admin'
      and referee.is_active
  )
);

drop policy if exists "Open Queue clocks are readable by authenticated users"
on public.open_queue_clock_states;
create policy "Open Queue clocks are readable by authenticated users"
on public.open_queue_clock_states
for select to authenticated using (true);

drop policy if exists "Open Queue goals are readable by authenticated users"
on public.open_queue_goals;
create policy "Open Queue goals are readable by authenticated users"
on public.open_queue_goals
for select to authenticated using (true);

drop policy if exists "Open Queue events are readable by authenticated users"
on public.open_queue_events;
create policy "Open Queue events are readable by authenticated users"
on public.open_queue_events
for select to authenticated using (true);

drop policy if exists "Open Queue blue cards are readable by authenticated users"
on public.open_queue_blue_cards;
create policy "Open Queue blue cards are readable by authenticated users"
on public.open_queue_blue_cards
for select to authenticated using (true);

drop policy if exists "Open Queue broadcasts are readable by authenticated users"
on public.open_queue_broadcasts;
create policy "Open Queue broadcasts are readable by authenticated users"
on public.open_queue_broadcasts
for select to authenticated using (true);

revoke all on public.open_queue_referee_assignments from anon, authenticated;
revoke all on public.open_queue_clock_states from anon, authenticated;
revoke all on public.open_queue_goals from anon, authenticated;
revoke all on public.open_queue_events from anon, authenticated;
revoke all on public.open_queue_blue_cards from anon, authenticated;
revoke all on public.open_queue_broadcasts from anon, authenticated;

grant select on public.open_queue_referee_assignments to authenticated;
grant select on public.open_queue_clock_states to authenticated;
grant select on public.open_queue_goals to authenticated;
grant select on public.open_queue_events to authenticated;
grant select on public.open_queue_blue_cards to authenticated;
grant select on public.open_queue_broadcasts to authenticated;

revoke all on function public.ensure_live_open_queue_game_has_started_clock()
from public, anon, authenticated;
revoke all on function public.validate_open_queue_goal_participants()
from public, anon, authenticated;
revoke all on function public.sync_open_queue_score_from_goals()
from public, anon, authenticated;
revoke all on function public.referee_complete_open_queue_game(uuid)
from public, anon, authenticated;
grant execute on function public.referee_complete_open_queue_game(uuid)
to service_role;

revoke execute on function public.assign_open_queue_teams(uuid)
from public, anon, authenticated;
grant execute on function public.assign_open_queue_teams(uuid)
to service_role;

revoke all on function public.auto_stop_overdue_open_queue_clocks()
from public, anon, authenticated;
grant execute on function public.auto_stop_overdue_open_queue_clocks()
to service_role;

revoke all on function public.get_open_queue_match_detail(uuid)
from public, anon, authenticated;
grant execute on function public.get_open_queue_match_detail(uuid)
to authenticated;

revoke all on function public.list_profile_previous_games(uuid)
from public, anon, authenticated;
grant execute on function public.list_profile_previous_games(uuid)
to authenticated;

do $$
declare
  existing_job_id bigint;
begin
  select jobid
  into existing_job_id
  from cron.job
  where jobname = 'auto-stop-open-queue-at-three-hours'
  limit 1;

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;
end;
$$;

select cron.schedule(
  'auto-stop-open-queue-at-three-hours',
  '* * * * *',
  'select public.auto_stop_overdue_open_queue_clocks()'
);

comment on function public.get_open_queue_match_detail(uuid) is
  'Returns a safe, payment-free Open Queue match detail payload with roster, match control, timeline, and broadcast data.';

comment on function public.list_profile_previous_games(uuid) is
  'Lists completed clan and solo matches in which the selected profile was confirmed as having played.';
