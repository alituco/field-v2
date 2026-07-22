-- Admin-managed standby players for Solo and Clan games. A reserve assignment
-- is operational metadata only: it does not create a paid booking, alter the
-- official six-player roster, or make the player rating-eligible by itself.

create table if not exists public.match_reserve_assignments (
  id uuid primary key default gen_random_uuid(),
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  side text not null check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'REMOVED')),
  note text not null check (char_length(trim(note)) between 3 and 500),
  added_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  added_at timestamptz not null default clock_timestamp(),
  removed_by uuid references public.referee_profiles(profile_id)
    on delete restrict,
  removed_at timestamptz,
  removal_reason text check (
    removal_reason is null
    or char_length(trim(removal_reason)) between 3 and 500
  ),
  check (
    (match_kind = 'CLAN' and fixture_id is not null
      and open_queue_game_id is null and side in ('HOME', 'AWAY'))
    or
    (match_kind = 'SOLO' and open_queue_game_id is not null
      and fixture_id is null and side in ('WHITE', 'BLACK'))
  ),
  check (
    (status = 'ACTIVE' and removed_by is null and removed_at is null
      and removal_reason is null)
    or
    (status = 'REMOVED' and removed_by is not null and removed_at is not null
      and removal_reason is not null)
  )
);

create unique index if not exists match_reserve_active_fixture_side_idx
on public.match_reserve_assignments (fixture_id, side)
where status = 'ACTIVE' and fixture_id is not null;

create unique index if not exists match_reserve_active_solo_side_idx
on public.match_reserve_assignments (open_queue_game_id, side)
where status = 'ACTIVE' and open_queue_game_id is not null;

create unique index if not exists match_reserve_active_fixture_player_idx
on public.match_reserve_assignments (fixture_id, profile_id)
where status = 'ACTIVE' and fixture_id is not null;

create unique index if not exists match_reserve_active_solo_player_idx
on public.match_reserve_assignments (open_queue_game_id, profile_id)
where status = 'ACTIVE' and open_queue_game_id is not null;

create index if not exists match_reserve_fixture_history_idx
on public.match_reserve_assignments (fixture_id, added_at desc)
where fixture_id is not null;

create index if not exists match_reserve_solo_history_idx
on public.match_reserve_assignments (open_queue_game_id, added_at desc)
where open_queue_game_id is not null;

alter table public.match_reserve_assignments enable row level security;
revoke all on table public.match_reserve_assignments
from public, anon, authenticated;
grant all on table public.match_reserve_assignments to service_role;

create or replace function public.admin_assign_match_reserve(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_use uuid,
  side_to_use text,
  note_to_use text
)
returns public.match_reserve_assignments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_side text := upper(trim(coalesce(side_to_use, '')));
  match_status text;
  clan_id_to_use uuid;
  assignment public.match_reserve_assignments%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(trim(coalesce(note_to_use, ''))) not between 3 and 500 then
    raise exception 'Explain why this player is being added as the reserve.';
  end if;
  if not exists (select 1 from public.profiles where id = profile_id_to_use) then
    raise exception 'Player not found.';
  end if;

  if normalized_kind = 'SOLO' then
    if normalized_side not in ('WHITE', 'BLACK') then
      raise exception 'Choose White or Black for a solo reserve.';
    end if;
    select game.status into match_status
    from public.open_queue_games game
    where game.id = match_id_to_use
    for update;
    if match_status is null then raise exception 'Solo game not found.'; end if;
    if match_status not in ('OPEN', 'FULL') then
      raise exception 'Reserves can only be changed before a solo game starts.';
    end if;
    if exists (
      select 1 from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.profile_id = profile_id_to_use
        and booking.status = 'CONFIRMED'
    ) then
      raise exception 'This player already has a confirmed place in the game.';
    end if;
  elsif normalized_kind = 'CLAN' then
    if normalized_side not in ('HOME', 'AWAY') then
      raise exception 'Choose Home or Away for a clan reserve.';
    end if;
    select fixture.status,
      case when normalized_side = 'HOME'
        then fixture.home_clan_id else fixture.away_clan_id end
    into match_status, clan_id_to_use
    from public.fixtures fixture
    where fixture.id = match_id_to_use
    for update;
    if match_status is null then raise exception 'Clan fixture not found.'; end if;
    if clan_id_to_use is null then raise exception 'This fixture does not have both clans yet.'; end if;
    if match_status not in ('OPEN', 'SCHEDULED') then
      raise exception 'Reserves can only be changed before a clan game starts.';
    end if;
    if not exists (
      select 1 from public.clan_members member
      where member.clan_id = clan_id_to_use
        and member.profile_id = profile_id_to_use
        and member.left_at is null
    ) then
      raise exception 'The reserve must be an active member of that clan.';
    end if;
    if exists (
      select 1 from public.fixture_reliability_roster_history roster
      where roster.fixture_id = match_id_to_use
        and roster.profile_id = profile_id_to_use
        and roster.status = 'CONFIRMED'
    ) then
      raise exception 'This player is already in the confirmed match roster.';
    end if;
  else
    raise exception 'Game type must be solo or clan.';
  end if;

  if exists (
    select 1 from public.match_reserve_assignments reserve
    where reserve.status = 'ACTIVE'
      and reserve.side = normalized_side
      and (
        (normalized_kind = 'SOLO' and reserve.open_queue_game_id = match_id_to_use)
        or (normalized_kind = 'CLAN' and reserve.fixture_id = match_id_to_use)
      )
  ) then
    raise exception 'That side already has a reserve. Remove the current reserve first.';
  end if;

  insert into public.match_reserve_assignments (
    match_kind,
    fixture_id,
    open_queue_game_id,
    profile_id,
    side,
    note,
    added_by
  ) values (
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    profile_id_to_use,
    normalized_side,
    trim(note_to_use),
    actor_admin_id
  ) returning * into assignment;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    'MATCH_RESERVE_ASSIGNED',
    case when normalized_kind = 'SOLO' then 'SOLO_MATCH' else 'CLAN_MATCH' end,
    match_id_to_use,
    trim(note_to_use),
    '{}'::jsonb,
    jsonb_build_object(
      'reserve_assignment_id', assignment.id,
      'profile_id', profile_id_to_use,
      'side', normalized_side
    )
  );

  return assignment;
end;
$$;

create or replace function public.admin_remove_match_reserve(
  actor_admin_id uuid,
  assignment_id_to_remove uuid,
  reason_to_use text
)
returns public.match_reserve_assignments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  assignment public.match_reserve_assignments%rowtype;
  match_id uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(trim(coalesce(reason_to_use, ''))) not between 3 and 500 then
    raise exception 'Explain why this reserve is being removed.';
  end if;

  select * into assignment
  from public.match_reserve_assignments reserve
  where reserve.id = assignment_id_to_remove
  for update;
  if assignment.id is null then raise exception 'Reserve assignment not found.'; end if;
  if assignment.status <> 'ACTIVE' then return assignment; end if;

  update public.match_reserve_assignments
  set status = 'REMOVED',
      removed_by = actor_admin_id,
      removed_at = clock_timestamp(),
      removal_reason = trim(reason_to_use)
  where id = assignment.id
  returning * into assignment;

  match_id := coalesce(assignment.fixture_id, assignment.open_queue_game_id);
  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    'MATCH_RESERVE_REMOVED',
    case when assignment.match_kind = 'SOLO' then 'SOLO_MATCH' else 'CLAN_MATCH' end,
    match_id,
    trim(reason_to_use),
    jsonb_build_object(
      'reserve_assignment_id', assignment.id,
      'profile_id', assignment.profile_id,
      'side', assignment.side,
      'status', 'ACTIVE'
    ),
    jsonb_build_object('status', 'REMOVED')
  );

  return assignment;
end;
$$;

revoke all on function public.admin_assign_match_reserve(
  uuid, text, uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.admin_assign_match_reserve(
  uuid, text, uuid, uuid, text, text
) to service_role;

revoke all on function public.admin_remove_match_reserve(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.admin_remove_match_reserve(uuid, uuid, text)
to service_role;

comment on table public.match_reserve_assignments is
'Audited one-per-side standby assignments. These do not alter bookings, official rosters, payments, attendance, or rating eligibility.';
