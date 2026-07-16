-- Game-scoped parties let friends who have already booked the same solo game
-- ask to be placed together. Party membership is deliberately private and is
-- only exposed through auth-scoped RPCs to confirmed players in that game.
create table public.open_queue_parties (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.open_queue_games(id) on delete cascade,
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'ACTIVE' check (
    status in ('ACTIVE', 'DISBANDED')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ended_at timestamptz,
  unique (id, game_id),
  check (
    (status = 'ACTIVE' and ended_at is null)
    or (status = 'DISBANDED' and ended_at is not null)
  )
);

create unique index open_queue_parties_active_owner_idx
on public.open_queue_parties (game_id, owner_profile_id)
where status = 'ACTIVE';

create index open_queue_parties_game_status_idx
on public.open_queue_parties (game_id, status, created_at);

create table public.open_queue_party_members (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null,
  game_id uuid not null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (
    status in (
      'INVITED', 'ACCEPTED', 'DECLINED', 'CANCELLED', 'LEFT'
    )
  ),
  invited_by uuid not null references public.profiles(id) on delete cascade,
  invited_at timestamptz not null default now(),
  responded_at timestamptz,
  joined_at timestamptz,
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint open_queue_party_members_party_game_fkey
    foreign key (party_id, game_id)
    references public.open_queue_parties(id, game_id)
    on delete cascade,
  constraint open_queue_party_members_party_profile_key
    unique (party_id, profile_id),
  check (
    (status = 'INVITED' and responded_at is null and joined_at is null and ended_at is null)
    or (status = 'ACCEPTED' and responded_at is not null and joined_at is not null and ended_at is null)
    or (status in ('DECLINED', 'CANCELLED', 'LEFT') and ended_at is not null)
  )
);

-- A player may receive more than one invitation, but can only belong to one
-- accepted party in a game. Accepting one invitation cancels every other one.
create unique index open_queue_party_members_one_accepted_idx
on public.open_queue_party_members (game_id, profile_id)
where status = 'ACCEPTED';

create index open_queue_party_members_party_status_idx
on public.open_queue_party_members (party_id, status, invited_at);

create index open_queue_party_members_profile_status_idx
on public.open_queue_party_members (game_id, profile_id, status);

drop trigger if exists set_open_queue_parties_updated_at
on public.open_queue_parties;

create trigger set_open_queue_parties_updated_at
before update on public.open_queue_parties
for each row execute function public.set_updated_at();

drop trigger if exists set_open_queue_party_members_updated_at
on public.open_queue_party_members;

create trigger set_open_queue_party_members_updated_at
before update on public.open_queue_party_members
for each row execute function public.set_updated_at();

alter table public.open_queue_parties enable row level security;

alter table public.open_queue_party_members enable row level security;

-- There are intentionally no client table policies. In particular, another
-- booked player cannot enumerate invitations or social connections directly.
revoke all on table public.open_queue_parties from public, anon, authenticated;

revoke all on table public.open_queue_party_members from public, anon, authenticated;

grant all on table public.open_queue_parties to service_role;

grant all on table public.open_queue_party_members to service_role;

-- Validate parties against the final role template even while the game still
-- has vacancies. Every missing booked place is represented as an independent
-- future singleton, so an impossible party is rejected when it is accepted,
-- rather than surprising the final person who books the game.
create or replace function public.open_queue_party_assignment_is_possible(
  game_id_to_check uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  assignment_exists boolean := false;
begin
  if not exists (
    select 1
    from public.open_queue_games game
    where game.id = game_id_to_check
  ) then
    return false;
  end if;

  if exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_check
      and booking.status = 'CONFIRMED'
    group by booking.role
    having count(*) > case booking.role
      when 'GK' then 2
      when 'DEF' then 4
      when 'MID' then 4
      when 'ATT' then 2
    end
  ) then
    return false;
  end if;

  with accepted_party_units as (
    select
      'party:' || party.id::text as unit_key,
      count(*) filter (where booking.role = 'GK')::integer as gk_count,
      count(*) filter (where booking.role = 'DEF')::integer as def_count,
      count(*) filter (where booking.role = 'MID')::integer as mid_count,
      count(*) filter (where booking.role = 'ATT')::integer as att_count
    from public.open_queue_parties party
    join public.open_queue_party_members member
      on member.party_id = party.id
      and member.game_id = party.game_id
      and member.status = 'ACCEPTED'
    join public.open_queue_bookings booking
      on booking.game_id = member.game_id
      and booking.profile_id = member.profile_id
      and booking.status = 'CONFIRMED'
    where party.game_id = game_id_to_check
      and party.status = 'ACTIVE'
    group by party.id
  ),
  ungrouped_booked_units as (
    select
      'booking:' || booking.id::text as unit_key,
      (booking.role = 'GK')::integer as gk_count,
      (booking.role = 'DEF')::integer as def_count,
      (booking.role = 'MID')::integer as mid_count,
      (booking.role = 'ATT')::integer as att_count
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_check
      and booking.status = 'CONFIRMED'
      and not exists (
        select 1
        from public.open_queue_party_members member
        join public.open_queue_parties party
          on party.id = member.party_id
          and party.game_id = member.game_id
          and party.status = 'ACTIVE'
        where member.game_id = booking.game_id
          and member.profile_id = booking.profile_id
          and member.status = 'ACCEPTED'
      )
  ),
  booked_role_counts as (
    select
      count(*) filter (where booking.role = 'GK')::integer as gk_count,
      count(*) filter (where booking.role = 'DEF')::integer as def_count,
      count(*) filter (where booking.role = 'MID')::integer as mid_count,
      count(*) filter (where booking.role = 'ATT')::integer as att_count
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_check
      and booking.status = 'CONFIRMED'
  ),
  future_singleton_units as (
    select
      'future:GK:' || slot::text as unit_key,
      1 as gk_count, 0 as def_count, 0 as mid_count, 0 as att_count
    from booked_role_counts counts
    cross join lateral generate_series(1, greatest(0, 2 - counts.gk_count)) slot
    union all
    select
      'future:DEF:' || slot::text,
      0, 1, 0, 0
    from booked_role_counts counts
    cross join lateral generate_series(1, greatest(0, 4 - counts.def_count)) slot
    union all
    select
      'future:MID:' || slot::text,
      0, 0, 1, 0
    from booked_role_counts counts
    cross join lateral generate_series(1, greatest(0, 4 - counts.mid_count)) slot
    union all
    select
      'future:ATT:' || slot::text,
      0, 0, 0, 1
    from booked_role_counts counts
    cross join lateral generate_series(1, greatest(0, 2 - counts.att_count)) slot
  ),
  all_units as (
    select * from accepted_party_units
    union all
    select * from ungrouped_booked_units
    union all
    select * from future_singleton_units
  ),
  numbered_units as (
    select
      unit.*,
      (row_number() over (order by unit.unit_key) - 1)::integer as unit_index
    from all_units unit
  ),
  unit_total as (
    select count(*)::integer as unit_count
    from numbered_units
  ),
  candidate_masks as (
    select mask
    from unit_total total
    cross join lateral generate_series(
      0::bigint,
      ((1::bigint << total.unit_count) - 1)::bigint
    ) mask
  )
  select exists (
    select 1
    from candidate_masks candidate
    cross join lateral (
      select
        coalesce(sum(unit.gk_count) filter (
          where (candidate.mask & (1::bigint << unit.unit_index)) <> 0
        ), 0)::integer as gk_count,
        coalesce(sum(unit.def_count) filter (
          where (candidate.mask & (1::bigint << unit.unit_index)) <> 0
        ), 0)::integer as def_count,
        coalesce(sum(unit.mid_count) filter (
          where (candidate.mask & (1::bigint << unit.unit_index)) <> 0
        ), 0)::integer as mid_count,
        coalesce(sum(unit.att_count) filter (
          where (candidate.mask & (1::bigint << unit.unit_index)) <> 0
        ), 0)::integer as att_count
      from numbered_units unit
    ) white_load
    where white_load.gk_count = 1
      and white_load.def_count = 2
      and white_load.mid_count = 2
      and white_load.att_count = 1
  ) into assignment_exists;

  return assignment_exists;
end;
$$;

-- Replace the existing SR-balancing assignment with the same exhaustive,
-- deterministic search plus a no-split condition for accepted parties.
create or replace function public.assign_open_queue_teams(
  game_id_to_assign uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  game_to_assign public.open_queue_games%rowtype;
  confirmed_count integer;
  goalkeeper_count integer;
  defender_count integer;
  midfielder_count integer;
  attacker_count integer;
  assignment_is_exact boolean;
  assignment_respects_parties boolean;
  white_booking_ids uuid[];
  white_average numeric;
  black_average numeric;
  overall_average numeric;
begin
  select * into game_to_assign
  from public.open_queue_games
  where id = game_id_to_assign
  for update;

  if game_to_assign.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_assign.status <> 'FULL' then
    raise exception 'Teams can only be assigned when an Open Queue game is full.';
  end if;

  select
    count(*)::integer,
    (count(*) filter (where booking.role = 'GK'))::integer,
    (count(*) filter (where booking.role = 'DEF'))::integer,
    (count(*) filter (where booking.role = 'MID'))::integer,
    (count(*) filter (where booking.role = 'ATT'))::integer
  into
    confirmed_count,
    goalkeeper_count,
    defender_count,
    midfielder_count,
    attacker_count
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED';

  if confirmed_count <> 12
    or goalkeeper_count <> 2
    or defender_count <> 4
    or midfielder_count <> 4
    or attacker_count <> 2
  then
    raise exception 'A full Open Queue game needs 2 GK, 4 DEF, 4 MID, and 2 ATT players.';
  end if;

  select
    count(*) = 12
    and (count(*) filter (where booking.team = 'WHITE')) = 6
    and (count(*) filter (where booking.team = 'BLACK')) = 6
    and (count(*) filter (where booking.team = 'WHITE' and booking.role = 'GK')) = 1
    and (count(*) filter (where booking.team = 'WHITE' and booking.role = 'DEF')) = 2
    and (count(*) filter (where booking.team = 'WHITE' and booking.role = 'MID')) = 2
    and (count(*) filter (where booking.team = 'WHITE' and booking.role = 'ATT')) = 1
    and (count(*) filter (where booking.team = 'BLACK' and booking.role = 'GK')) = 1
    and (count(*) filter (where booking.team = 'BLACK' and booking.role = 'DEF')) = 2
    and (count(*) filter (where booking.team = 'BLACK' and booking.role = 'MID')) = 2
    and (count(*) filter (where booking.team = 'BLACK' and booking.role = 'ATT')) = 1
  into assignment_is_exact
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED';

  select not exists (
    select 1
    from public.open_queue_parties party
    join public.open_queue_party_members member
      on member.party_id = party.id
      and member.game_id = party.game_id
      and member.status = 'ACCEPTED'
    join public.open_queue_bookings booking
      on booking.game_id = member.game_id
      and booking.profile_id = member.profile_id
      and booking.status = 'CONFIRMED'
    where party.game_id = game_id_to_assign
      and party.status = 'ACTIVE'
    group by party.id
    having count(distinct booking.team) > 1
      or bool_or(booking.team is null)
  ) into assignment_respects_parties;

  if game_to_assign.teams_assigned_at is not null
    and game_to_assign.white_average_sr is not null
    and game_to_assign.black_average_sr is not null
    and game_to_assign.match_average_sr is not null
    and game_to_assign.team_sr_spread is not null
    and assignment_is_exact
    and assignment_respects_parties
    and not exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = game_id_to_assign
        and booking.status = 'CONFIRMED'
        and (
          booking.team is null
          or booking.rating_at_team_assignment is null
        )
    )
  then
    return;
  end if;

  insert into public.player_ratings (profile_id)
  select booking.profile_id
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED'
  on conflict (profile_id) do nothing;

  perform rating.profile_id
  from public.player_ratings rating
  join public.open_queue_bookings booking
    on booking.profile_id = rating.profile_id
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED'
  order by rating.profile_id
  for update of rating;

  with participants as (
    select
      booking.id,
      booking.role,
      rating.skill_rating as sr
    from public.open_queue_bookings booking
    join public.player_ratings rating on rating.profile_id = booking.profile_id
    where booking.game_id = game_id_to_assign
      and booking.status = 'CONFIRMED'
  ),
  goalkeeper_choices as (
    select participant.id, participant.sr
    from participants participant
    where participant.role = 'GK'
  ),
  defender_choices as (
    select
      first_player.id as first_id,
      second_player.id as second_id,
      first_player.sr + second_player.sr as sr
    from participants first_player
    join participants second_player on first_player.id < second_player.id
    where first_player.role = 'DEF'
      and second_player.role = 'DEF'
  ),
  midfielder_choices as (
    select
      first_player.id as first_id,
      second_player.id as second_id,
      first_player.sr + second_player.sr as sr
    from participants first_player
    join participants second_player on first_player.id < second_player.id
    where first_player.role = 'MID'
      and second_player.role = 'MID'
  ),
  attacker_choices as (
    select participant.id, participant.sr
    from participants participant
    where participant.role = 'ATT'
  ),
  total as (
    select sum(participant.sr)::integer as total_sr
    from participants participant
  ),
  raw_candidates as (
    select
      array[
        goalkeeper.id,
        defender.first_id,
        defender.second_id,
        midfielder.first_id,
        midfielder.second_id,
        attacker.id
      ]::uuid[] as booking_ids,
      goalkeeper.sr + defender.sr + midfielder.sr + attacker.sr as white_total,
      concat_ws(
        '|',
        goalkeeper.id::text,
        defender.first_id::text,
        defender.second_id::text,
        midfielder.first_id::text,
        midfielder.second_id::text,
        attacker.id::text
      ) as deterministic_key
    from goalkeeper_choices goalkeeper
    cross join defender_choices defender
    cross join midfielder_choices midfielder
    cross join attacker_choices attacker
  ),
  valid_candidates as (
    select candidate.*
    from raw_candidates candidate
    where not exists (
      select 1
      from public.open_queue_parties party
      join public.open_queue_party_members member
        on member.party_id = party.id
        and member.game_id = party.game_id
        and member.status = 'ACCEPTED'
      join public.open_queue_bookings booking
        on booking.game_id = member.game_id
        and booking.profile_id = member.profile_id
        and booking.status = 'CONFIRMED'
      where party.game_id = game_id_to_assign
        and party.status = 'ACTIVE'
      group by party.id
      having count(*) filter (where booking.id = any(candidate.booking_ids)) > 0
        and count(*) filter (where booking.id = any(candidate.booking_ids)) < count(*)
    )
  )
  select candidate.booking_ids
  into white_booking_ids
  from valid_candidates candidate
  cross join total
  order by
    abs((candidate.white_total * 2) - total.total_sr),
    candidate.deterministic_key
  limit 1;

  if white_booking_ids is null or cardinality(white_booking_ids) <> 6 then
    raise exception 'These party combinations cannot produce balanced Open Queue teams.';
  end if;

  update public.open_queue_bookings booking
  set
    team = case
      when booking.id = any(white_booking_ids) then 'WHITE'
      else 'BLACK'
    end,
    rating_at_team_assignment = rating.skill_rating,
    rating_at_match_start = null,
    rating_change = null
  from public.player_ratings rating
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED'
    and rating.profile_id = booking.profile_id;

  select
    avg(booking.rating_at_team_assignment) filter (where booking.team = 'WHITE'),
    avg(booking.rating_at_team_assignment) filter (where booking.team = 'BLACK'),
    avg(booking.rating_at_team_assignment)
  into white_average, black_average, overall_average
  from public.open_queue_bookings booking
  where booking.game_id = game_id_to_assign
    and booking.status = 'CONFIRMED';

  update public.open_queue_games
  set
    white_average_sr = round(white_average, 2),
    black_average_sr = round(black_average, 2),
    match_average_sr = round(overall_average, 2),
    team_sr_spread = round(abs(white_average - black_average), 2),
    teams_assigned_at = clock_timestamp()
  where id = game_id_to_assign;
end;
$$;

create or replace function public.reassign_open_queue_teams_after_party_change(
  game_id_to_reassign uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  game_status text;
begin
  select game.status into game_status
  from public.open_queue_games game
  where game.id = game_id_to_reassign
  for update;

  if game_status <> 'FULL' then
    return;
  end if;

  update public.open_queue_bookings
  set
    team = null,
    rating_at_team_assignment = null,
    rating_at_match_start = null,
    rating_change = null
  where game_id = game_id_to_reassign
    and status = 'CONFIRMED';

  update public.open_queue_games
  set
    white_average_sr = null,
    black_average_sr = null,
    match_average_sr = null,
    team_sr_spread = null,
    teams_assigned_at = null
  where id = game_id_to_reassign;

  perform public.assign_open_queue_teams(game_id_to_reassign);
end;
$$;

create or replace function public.create_open_queue_party(
  game_id_to_use uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  game_to_use public.open_queue_games%rowtype;
  party_id_to_return uuid;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = game_id_to_use
  for update;

  if game_to_use.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = game_id_to_use
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;
  if exists (
    select 1
    from public.open_queue_party_members member
    join public.open_queue_parties party on party.id = member.party_id
    where member.game_id = game_id_to_use
      and member.profile_id = user_id
      and member.status = 'ACCEPTED'
      and party.status = 'ACTIVE'
  ) then
    raise exception 'You are already in a party for this game.';
  end if;

  -- Creating a party is equivalent to accepting its owner seat.
  update public.open_queue_party_members member
  set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  from public.open_queue_parties party
  where member.party_id = party.id
    and member.game_id = game_id_to_use
    and member.profile_id = user_id
    and member.status = 'INVITED'
    and party.status = 'ACTIVE';

  insert into public.open_queue_parties (game_id, owner_profile_id)
  values (game_id_to_use, user_id)
  returning id into party_id_to_return;

  insert into public.open_queue_party_members (
    party_id, game_id, profile_id, status, invited_by,
    responded_at, joined_at
  ) values (
    party_id_to_return, game_id_to_use, user_id, 'ACCEPTED', user_id,
    clock_timestamp(), clock_timestamp()
  );

  if not public.open_queue_party_assignment_is_possible(game_id_to_use) then
    raise exception 'This party cannot fit the required solo team positions.';
  end if;

  perform public.reassign_open_queue_teams_after_party_change(game_id_to_use);
  return party_id_to_return;
end;
$$;

create or replace function public.invite_open_queue_party_member(
  party_id_to_use uuid,
  target_profile_id_to_use uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
  existing_member public.open_queue_party_members%rowtype;
  membership_id_to_return uuid;
  active_seat_count integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if target_profile_id_to_use is null or target_profile_id_to_use = user_id then
    raise exception 'Choose another booked player to invite.';
  end if;

  select party.* into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use;
  if party_to_use.id is null then
    raise exception 'Party not found.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = party_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use
  for update;

  if party_to_use.status <> 'ACTIVE' then
    raise exception 'This party is no longer active.';
  end if;
  if party_to_use.owner_profile_id <> user_id then
    raise exception 'Only the party leader can invite players.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = party_to_use.game_id
      and booking.profile_id = target_profile_id_to_use
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'That player does not have a confirmed booking in this game.';
  end if;
  if exists (
    select 1
    from public.open_queue_party_members member
    join public.open_queue_parties party on party.id = member.party_id
    where member.game_id = party_to_use.game_id
      and member.profile_id = target_profile_id_to_use
      and member.status = 'ACCEPTED'
      and party.status = 'ACTIVE'
  ) then
    raise exception 'That player is already in a party for this game.';
  end if;

  select count(*)::integer into active_seat_count
  from public.open_queue_party_members member
  where member.party_id = party_id_to_use
    and member.status in ('ACCEPTED', 'INVITED');
  if active_seat_count >= 4 then
    raise exception 'A party can have at most 4 players, including pending invitations.';
  end if;

  select * into existing_member
  from public.open_queue_party_members member
  where member.party_id = party_id_to_use
    and member.profile_id = target_profile_id_to_use
  for update;

  if existing_member.status in ('INVITED', 'ACCEPTED') then
    raise exception 'This player has already been invited to this party.';
  elsif existing_member.id is not null then
    update public.open_queue_party_members
    set
      status = 'INVITED',
      invited_by = user_id,
      invited_at = clock_timestamp(),
      responded_at = null,
      joined_at = null,
      ended_at = null
    where id = existing_member.id
    returning id into membership_id_to_return;
  else
    insert into public.open_queue_party_members (
      party_id, game_id, profile_id, status, invited_by
    ) values (
      party_id_to_use, party_to_use.game_id,
      target_profile_id_to_use, 'INVITED', user_id
    ) returning id into membership_id_to_return;
  end if;

  return membership_id_to_return;
end;
$$;

create or replace function public.respond_open_queue_party_invitation(
  membership_id_to_use uuid,
  accept_to_use boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  membership_to_use public.open_queue_party_members%rowtype;
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
  accepted_count_to_return integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if accept_to_use is null then
    raise exception 'Choose whether to accept or decline this invitation.';
  end if;

  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use;
  if membership_to_use.id is null or membership_to_use.profile_id <> user_id then
    raise exception 'Party invitation not found.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = membership_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = membership_to_use.party_id
  for update;
  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use
  for update;

  if membership_to_use.status <> 'INVITED' or party_to_use.status <> 'ACTIVE' then
    raise exception 'This party invitation is no longer active.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = membership_to_use.game_id
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;

  if not accept_to_use then
    update public.open_queue_party_members
    set status = 'DECLINED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
    where id = membership_id_to_use;

    select count(*)::integer into accepted_count_to_return
    from public.open_queue_party_members member
    where member.party_id = membership_to_use.party_id
      and member.status = 'ACCEPTED';

    return jsonb_build_object(
      'membership_id', membership_id_to_use,
      'party_id', membership_to_use.party_id,
      'status', 'DECLINED',
      'accepted_count', accepted_count_to_return
    );
  end if;

  select count(*)::integer into accepted_count_to_return
  from public.open_queue_party_members member
  where member.party_id = membership_to_use.party_id
    and member.status = 'ACCEPTED';
  if accepted_count_to_return >= 4 then
    raise exception 'This party already has 4 players.';
  end if;
  if exists (
    select 1
    from public.open_queue_party_members member
    join public.open_queue_parties party on party.id = member.party_id
    where member.game_id = membership_to_use.game_id
      and member.profile_id = user_id
      and member.status = 'ACCEPTED'
      and party.status = 'ACTIVE'
  ) then
    raise exception 'You are already in a party for this game.';
  end if;

  update public.open_queue_party_members
  set status = 'ACCEPTED', responded_at = clock_timestamp(), joined_at = clock_timestamp()
  where id = membership_id_to_use;

  update public.open_queue_party_members member
  set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  from public.open_queue_parties party
  where member.party_id = party.id
    and member.game_id = membership_to_use.game_id
    and member.profile_id = user_id
    and member.status = 'INVITED'
    and member.id <> membership_id_to_use
    and party.status = 'ACTIVE';

  if not public.open_queue_party_assignment_is_possible(membership_to_use.game_id) then
    raise exception 'Joining this party would make the required 1 GK, 2 DEF, 2 MID, and 1 ATT teams impossible.';
  end if;

  perform public.reassign_open_queue_teams_after_party_change(
    membership_to_use.game_id
  );

  select count(*)::integer into accepted_count_to_return
  from public.open_queue_party_members member
  where member.party_id = membership_to_use.party_id
    and member.status = 'ACCEPTED';

  return jsonb_build_object(
    'membership_id', membership_id_to_use,
    'party_id', membership_to_use.party_id,
    'status', 'ACCEPTED',
    'accepted_count', accepted_count_to_return
  );
end;
$$;

create or replace function public.cancel_open_queue_party_invitation(
  membership_id_to_use uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  membership_to_use public.open_queue_party_members%rowtype;
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use;
  if membership_to_use.id is null then
    raise exception 'Party invitation not found.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = membership_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = membership_to_use.party_id
  for update;
  select * into membership_to_use
  from public.open_queue_party_members member
  where member.id = membership_id_to_use
  for update;

  if party_to_use.owner_profile_id <> user_id then
    raise exception 'Only the party leader can cancel an invitation.';
  end if;
  if membership_to_use.status <> 'INVITED' or party_to_use.status <> 'ACTIVE' then
    raise exception 'This party invitation is no longer active.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties are only available before this solo game starts.';
  end if;

  update public.open_queue_party_members
  set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  where id = membership_id_to_use;

  return jsonb_build_object(
    'membership_id', membership_id_to_use,
    'party_id', membership_to_use.party_id,
    'status', 'CANCELLED'
  );
end;
$$;

create or replace function public.leave_open_queue_party(
  party_id_to_use uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  party_to_use public.open_queue_parties%rowtype;
  membership_to_use public.open_queue_party_members%rowtype;
  game_to_use public.open_queue_games%rowtype;
  successor_id uuid;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use;
  if party_to_use.id is null then
    raise exception 'Party not found.';
  end if;
  select * into game_to_use
  from public.open_queue_games game
  where game.id = party_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use
  for update;
  select * into membership_to_use
  from public.open_queue_party_members member
  where member.party_id = party_id_to_use
    and member.profile_id = user_id
    and member.status = 'ACCEPTED'
  for update;

  if membership_to_use.id is null or party_to_use.status <> 'ACTIVE' then
    raise exception 'You are not in this active party.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties cannot be changed after this solo game starts.';
  end if;

  update public.open_queue_party_members
  set status = 'LEFT', ended_at = clock_timestamp()
  where id = membership_to_use.id;

  if party_to_use.owner_profile_id = user_id then
    select member.profile_id into successor_id
    from public.open_queue_party_members member
    where member.party_id = party_id_to_use
      and member.status = 'ACCEPTED'
    order by member.joined_at, member.id
    limit 1;

    if successor_id is null then
      update public.open_queue_parties
      set status = 'DISBANDED', ended_at = clock_timestamp()
      where id = party_id_to_use;
      update public.open_queue_party_members
      set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
      where party_id = party_id_to_use
        and status = 'INVITED';
    else
      update public.open_queue_parties
      set owner_profile_id = successor_id
      where id = party_id_to_use;
    end if;
  end if;

  perform public.reassign_open_queue_teams_after_party_change(
    party_to_use.game_id
  );
end;
$$;

create or replace function public.disband_open_queue_party(
  party_id_to_use uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  party_to_use public.open_queue_parties%rowtype;
  game_to_use public.open_queue_games%rowtype;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use;
  if party_to_use.id is null then
    raise exception 'Party not found.';
  end if;
  select * into game_to_use
  from public.open_queue_games game
  where game.id = party_to_use.game_id
  for update;
  select * into party_to_use
  from public.open_queue_parties party
  where party.id = party_id_to_use
  for update;

  if party_to_use.owner_profile_id <> user_id then
    raise exception 'Only the party leader can disband this party.';
  end if;
  if party_to_use.status <> 'ACTIVE' then
    raise exception 'This party is no longer active.';
  end if;
  if game_to_use.status not in ('OPEN', 'FULL') or now() >= game_to_use.starts_at then
    raise exception 'Parties cannot be changed after this solo game starts.';
  end if;

  update public.open_queue_parties
  set status = 'DISBANDED', ended_at = clock_timestamp()
  where id = party_id_to_use;
  update public.open_queue_party_members
  set
    status = case when status = 'INVITED' then 'CANCELLED' else 'LEFT' end,
    responded_at = coalesce(responded_at, clock_timestamp()),
    ended_at = clock_timestamp()
  where party_id = party_id_to_use
    and status in ('INVITED', 'ACCEPTED');

  perform public.reassign_open_queue_teams_after_party_change(
    party_to_use.game_id
  );
end;
$$;

-- A booking cancellation immediately removes that player from the party. If
-- the leader cancels, leadership moves to the oldest remaining accepted member.
create or replace function public.cleanup_open_queue_party_booking_exit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_id_to_clean uuid := old.game_id;
  profile_id_to_clean uuid := old.profile_id;
  membership_to_clean record;
  successor_id uuid;
begin
  if tg_op = 'UPDATE' and not (
    old.status = 'CONFIRMED' and new.status <> 'CONFIRMED'
  ) then
    return new;
  end if;
  if tg_op = 'DELETE' and old.status <> 'CONFIRMED' then
    return old;
  end if;

  update public.open_queue_party_members member
  set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
  from public.open_queue_parties party
  where member.party_id = party.id
    and member.game_id = game_id_to_clean
    and member.profile_id = profile_id_to_clean
    and member.status = 'INVITED'
    and party.status = 'ACTIVE';

  select
    member.id as membership_id,
    member.party_id,
    party.owner_profile_id
  into membership_to_clean
  from public.open_queue_party_members member
  join public.open_queue_parties party on party.id = member.party_id
  where member.game_id = game_id_to_clean
    and member.profile_id = profile_id_to_clean
    and member.status = 'ACCEPTED'
    and party.status = 'ACTIVE'
  for update of party, member;

  if membership_to_clean.membership_id is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  update public.open_queue_party_members
  set status = 'LEFT', ended_at = clock_timestamp()
  where id = membership_to_clean.membership_id;

  if membership_to_clean.owner_profile_id = profile_id_to_clean then
    select member.profile_id into successor_id
    from public.open_queue_party_members member
    where member.party_id = membership_to_clean.party_id
      and member.status = 'ACCEPTED'
    order by member.joined_at, member.id
    limit 1;

    if successor_id is null then
      update public.open_queue_parties
      set status = 'DISBANDED', ended_at = clock_timestamp()
      where id = membership_to_clean.party_id;
      update public.open_queue_party_members
      set status = 'CANCELLED', responded_at = clock_timestamp(), ended_at = clock_timestamp()
      where party_id = membership_to_clean.party_id
        and status = 'INVITED';
    else
      update public.open_queue_parties
      set owner_profile_id = successor_id
      where id = membership_to_clean.party_id;
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists cleanup_open_queue_party_booking_exit
on public.open_queue_bookings;

create trigger cleanup_open_queue_party_booking_exit
after update of status or delete on public.open_queue_bookings
for each row execute function public.cleanup_open_queue_party_booking_exit();

create or replace function public.close_cancelled_open_queue_parties()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'CANCELLED' and old.status <> 'CANCELLED' then
    update public.open_queue_party_members member
    set
      status = case when member.status = 'INVITED' then 'CANCELLED' else 'LEFT' end,
      responded_at = coalesce(member.responded_at, clock_timestamp()),
      ended_at = clock_timestamp()
    from public.open_queue_parties party
    where member.party_id = party.id
      and party.game_id = new.id
      and party.status = 'ACTIVE'
      and member.status in ('INVITED', 'ACCEPTED');

    update public.open_queue_parties
    set status = 'DISBANDED', ended_at = clock_timestamp()
    where game_id = new.id
      and status = 'ACTIVE';
  end if;
  return new;
end;
$$;

drop trigger if exists close_cancelled_open_queue_parties
on public.open_queue_games;

create trigger close_cancelled_open_queue_parties
after update of status on public.open_queue_games
for each row execute function public.close_cancelled_open_queue_parties();

create or replace function public.get_open_queue_party_context(
  game_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  game_to_use public.open_queue_games%rowtype;
  my_party_id uuid;
  my_party_payload jsonb;
  received_invites_payload jsonb;
  eligible_players_payload jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into game_to_use
  from public.open_queue_games game
  where game.id = game_id_to_use;
  if game_to_use.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = game_id_to_use
      and booking.profile_id = user_id
      and booking.status = 'CONFIRMED'
  ) then
    raise exception 'You need a confirmed booking in this solo game.';
  end if;

  select party.id into my_party_id
  from public.open_queue_party_members member
  join public.open_queue_parties party on party.id = member.party_id
  where member.game_id = game_id_to_use
    and member.profile_id = user_id
    and member.status = 'ACCEPTED'
    and party.status = 'ACTIVE'
  limit 1;

  if my_party_id is not null then
    select jsonb_build_object(
      'id', party.id,
      'owner_profile_id', party.owner_profile_id,
      'is_owner', party.owner_profile_id = user_id,
      'accepted_count', (
        select count(*)::integer
        from public.open_queue_party_members accepted
        where accepted.party_id = party.id and accepted.status = 'ACCEPTED'
      ),
      'invited_count', (
        select count(*)::integer
        from public.open_queue_party_members invited
        where invited.party_id = party.id and invited.status = 'INVITED'
      ),
      'members', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'membership_id', member.id,
            'profile_id', member.profile_id,
            'display_name', profile.display_name,
            'username', profile.username,
            'avatar_url', profile.avatar_url,
            'role', booking.role,
            'position', booking.role,
            'status', member.status,
            'is_owner', member.profile_id = party.owner_profile_id,
            'invited_at', member.invited_at,
            'joined_at', member.joined_at
          ) order by
            (member.profile_id = party.owner_profile_id) desc,
            member.joined_at nulls last,
            member.invited_at,
            member.id
        ), '[]'::jsonb)
        from public.open_queue_party_members member
        join public.profiles profile on profile.id = member.profile_id
        join public.open_queue_bookings booking
          on booking.game_id = member.game_id
          and booking.profile_id = member.profile_id
          and booking.status = 'CONFIRMED'
        where member.party_id = party.id
          and member.status in ('ACCEPTED', 'INVITED')
      )
    ) into my_party_payload
    from public.open_queue_parties party
    where party.id = my_party_id;
  end if;

  select coalesce(jsonb_agg(invitation.payload order by invitation.invited_at), '[]'::jsonb)
  into received_invites_payload
  from (
    select
      member.invited_at,
      jsonb_build_object(
        'membership_id', member.id,
        'party_id', party.id,
        'invited_at', member.invited_at,
        'accepted_count', (
          select count(*)::integer
          from public.open_queue_party_members accepted
          where accepted.party_id = party.id and accepted.status = 'ACCEPTED'
        ),
        'owner', jsonb_build_object(
          'profile_id', owner_profile.id,
          'display_name', owner_profile.display_name,
          'username', owner_profile.username,
          'avatar_url', owner_profile.avatar_url,
          'role', owner_booking.role,
          'position', owner_booking.role
        ),
        'members', (
          select coalesce(jsonb_agg(
            jsonb_build_object(
              'membership_id', accepted.id,
              'profile_id', accepted.profile_id,
              'display_name', accepted_profile.display_name,
              'username', accepted_profile.username,
              'avatar_url', accepted_profile.avatar_url,
              'role', accepted_booking.role,
              'position', accepted_booking.role,
              'status', accepted.status,
              'is_owner', accepted.profile_id = party.owner_profile_id,
              'invited_at', accepted.invited_at,
              'joined_at', accepted.joined_at
            ) order by
              (accepted.profile_id = party.owner_profile_id) desc,
              accepted.joined_at,
              accepted.id
          ), '[]'::jsonb)
          from public.open_queue_party_members accepted
          join public.profiles accepted_profile on accepted_profile.id = accepted.profile_id
          join public.open_queue_bookings accepted_booking
            on accepted_booking.game_id = accepted.game_id
            and accepted_booking.profile_id = accepted.profile_id
            and accepted_booking.status = 'CONFIRMED'
          where accepted.party_id = party.id
            and accepted.status = 'ACCEPTED'
        )
      ) as payload
    from public.open_queue_party_members member
    join public.open_queue_parties party
      on party.id = member.party_id and party.status = 'ACTIVE'
    join public.profiles owner_profile on owner_profile.id = party.owner_profile_id
    join public.open_queue_bookings owner_booking
      on owner_booking.game_id = party.game_id
      and owner_booking.profile_id = party.owner_profile_id
      and owner_booking.status = 'CONFIRMED'
    where member.game_id = game_id_to_use
      and member.profile_id = user_id
      and member.status = 'INVITED'
      and game_to_use.status in ('OPEN', 'FULL')
      and now() < game_to_use.starts_at
  ) invitation;

  if my_party_id is not null and exists (
    select 1 from public.open_queue_parties party
    where party.id = my_party_id and party.owner_profile_id = user_id
  ) and game_to_use.status in ('OPEN', 'FULL') and now() < game_to_use.starts_at then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'profile_id', profile.id,
        'display_name', profile.display_name,
        'username', profile.username,
        'avatar_url', profile.avatar_url,
        'role', booking.role,
        'position', booking.role
      ) order by lower(profile.display_name), profile.id
    ), '[]'::jsonb)
    into eligible_players_payload
    from public.open_queue_bookings booking
    join public.profiles profile on profile.id = booking.profile_id
    where booking.game_id = game_id_to_use
      and booking.status = 'CONFIRMED'
      and booking.profile_id <> user_id
      and not exists (
        select 1
        from public.open_queue_party_members same_party_member
        where same_party_member.party_id = my_party_id
          and same_party_member.profile_id = booking.profile_id
          and same_party_member.status in ('INVITED', 'ACCEPTED')
      )
      and not exists (
        select 1
        from public.open_queue_party_members accepted_member
        join public.open_queue_parties accepted_party
          on accepted_party.id = accepted_member.party_id
          and accepted_party.status = 'ACTIVE'
        where accepted_member.game_id = game_id_to_use
          and accepted_member.profile_id = booking.profile_id
          and accepted_member.status = 'ACCEPTED'
      );
  else
    eligible_players_payload := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'game_id', game_to_use.id,
    'game_status', game_to_use.status,
    'can_use_parties', game_to_use.status in ('OPEN', 'FULL')
      and now() < game_to_use.starts_at,
    'max_party_size', 4,
    'my_party', my_party_payload,
    'received_invites', coalesce(received_invites_payload, '[]'::jsonb),
    'eligible_players', coalesce(eligible_players_payload, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.open_queue_party_assignment_is_possible(uuid)
from public, anon, authenticated;

revoke all on function public.reassign_open_queue_teams_after_party_change(uuid)
from public, anon, authenticated;

revoke all on function public.cleanup_open_queue_party_booking_exit()
from public, anon, authenticated;

revoke all on function public.close_cancelled_open_queue_parties()
from public, anon, authenticated;

revoke all on function public.create_open_queue_party(uuid)
from public, anon, authenticated;

grant execute on function public.create_open_queue_party(uuid) to authenticated;

revoke all on function public.invite_open_queue_party_member(uuid, uuid)
from public, anon, authenticated;

grant execute on function public.invite_open_queue_party_member(uuid, uuid) to authenticated;

revoke all on function public.respond_open_queue_party_invitation(uuid, boolean)
from public, anon, authenticated;

grant execute on function public.respond_open_queue_party_invitation(uuid, boolean) to authenticated;

revoke all on function public.cancel_open_queue_party_invitation(uuid)
from public, anon, authenticated;

grant execute on function public.cancel_open_queue_party_invitation(uuid) to authenticated;

revoke all on function public.leave_open_queue_party(uuid)
from public, anon, authenticated;

grant execute on function public.leave_open_queue_party(uuid) to authenticated;

revoke all on function public.disband_open_queue_party(uuid)
from public, anon, authenticated;

grant execute on function public.disband_open_queue_party(uuid) to authenticated;

revoke all on function public.get_open_queue_party_context(uuid)
from public, anon, authenticated;

grant execute on function public.get_open_queue_party_context(uuid) to authenticated;

comment on table public.open_queue_parties is
'Private, game-scoped solo parties with a maximum of four accepted players.';

comment on function public.get_open_queue_party_context(uuid) is
'Returns only the signed-in confirmed player party, invitations, and eligible same-game invitees.';

comment on function public.open_queue_party_assignment_is_possible(uuid) is
'Validates accepted parties against exact future 6v6 role slots using singleton placeholders for unfilled bookings.';
