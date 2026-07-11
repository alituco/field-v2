alter table public.clan_members
drop constraint if exists clan_members_role_check;

alter table public.clan_members
add constraint clan_members_role_check
check (role in ('owner', 'leader', 'member'));

create unique index if not exists clan_members_one_owner_per_clan_idx
on public.clan_members (clan_id)
where role = 'owner';

create or replace function public.is_clan_manager(
  clan_id_to_check uuid,
  profile_id_to_check uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.clan_members
    where clan_id = clan_id_to_check
      and profile_id = profile_id_to_check
      and role in ('owner', 'leader')
  );
$$;

revoke execute on function public.is_clan_manager(uuid, uuid) from public;
grant execute on function public.is_clan_manager(uuid, uuid) to authenticated;

drop policy if exists "Clan owners can update their clan" on public.clans;
drop policy if exists "Clan managers can update their clan" on public.clans;
create policy "Clan managers can update their clan"
on public.clans
for update
to authenticated
using (public.is_clan_manager(clans.id, auth.uid()))
with check (public.is_clan_manager(clans.id, auth.uid()));

-- Membership changes go through RPCs so role transitions and succession are atomic.
drop policy if exists "Clan owners can manage members" on public.clan_members;
drop policy if exists "Clan owners and members can remove members" on public.clan_members;

create or replace function public.set_clan_member_leader(
  clan_id_to_manage uuid,
  profile_id_to_manage uuid,
  make_leader boolean
)
returns public.clan_members
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  target_role text;
  updated_member public.clan_members%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  perform pg_advisory_xact_lock(hashtext(clan_id_to_manage::text)::bigint);

  select role into actor_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = auth.uid()
  for update;

  if actor_role is distinct from 'owner' then
    raise exception 'Only the clan owner can manage leaders.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = profile_id_to_manage
  for update;

  if target_role is null then
    raise exception 'That player is no longer in this clan.';
  end if;

  if target_role = 'owner' then
    raise exception 'The clan owner cannot be promoted or demoted.';
  end if;

  update public.clan_members
  set role = case when make_leader then 'leader' else 'member' end
  where clan_id = clan_id_to_manage and profile_id = profile_id_to_manage
  returning * into updated_member;

  return updated_member;
end;
$$;

create or replace function public.transfer_clan_ownership(
  clan_id_to_manage uuid,
  new_owner_profile_id uuid
)
returns public.clan_members
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  target_role text;
  new_owner public.clan_members%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  if new_owner_profile_id = auth.uid() then
    raise exception 'You already own this clan.';
  end if;

  perform pg_advisory_xact_lock(hashtext(clan_id_to_manage::text)::bigint);

  select role into actor_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = auth.uid()
  for update;

  if actor_role is distinct from 'owner' then
    raise exception 'Only the clan owner can transfer ownership.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = new_owner_profile_id
  for update;

  if target_role is null then
    raise exception 'Choose a player who is still in this clan.';
  end if;

  update public.clan_members
  set role = 'leader'
  where clan_id = clan_id_to_manage and profile_id = auth.uid();

  update public.clan_members
  set role = 'owner'
  where clan_id = clan_id_to_manage and profile_id = new_owner_profile_id
  returning * into new_owner;

  return new_owner;
end;
$$;

create or replace function public.kick_clan_member(
  clan_id_to_manage uuid,
  profile_id_to_remove uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  target_role text;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  if profile_id_to_remove = auth.uid() then
    raise exception 'Use Leave Clan to remove yourself.';
  end if;

  perform pg_advisory_xact_lock(hashtext(clan_id_to_manage::text)::bigint);

  select role into actor_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = auth.uid()
  for update;

  if actor_role is null or actor_role not in ('owner', 'leader') then
    raise exception 'Only clan owners and leaders can remove players.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = profile_id_to_remove
  for update;

  if target_role is null then
    raise exception 'That player is no longer in this clan.';
  end if;

  if target_role = 'owner' then
    raise exception 'Clan ownership must be transferred before the owner can leave.';
  end if;

  if actor_role = 'leader' and target_role <> 'member' then
    raise exception 'Leaders can only remove regular members.';
  end if;

  delete from public.clan_members
  where clan_id = clan_id_to_manage and profile_id = profile_id_to_remove;
end;
$$;

create or replace function public.leave_clan(clan_id_to_leave uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  leaving_role text;
  successor_profile_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  perform pg_advisory_xact_lock(hashtext(clan_id_to_leave::text)::bigint);

  select role into leaving_role
  from public.clan_members
  where clan_id = clan_id_to_leave and profile_id = auth.uid()
  for update;

  if leaving_role is null then
    raise exception 'You are no longer in this clan.';
  end if;

  if leaving_role = 'owner' then
    select profile_id into successor_profile_id
    from public.clan_members
    where clan_id = clan_id_to_leave and profile_id <> auth.uid()
    order by created_at asc, profile_id asc
    limit 1
    for update;

    if successor_profile_id is null then
      raise exception 'Add another player before leaving this clan.';
    end if;

    delete from public.clan_members
    where clan_id = clan_id_to_leave and profile_id = auth.uid();

    update public.clan_members
    set role = 'owner'
    where clan_id = clan_id_to_leave and profile_id = successor_profile_id;

    return successor_profile_id;
  end if;

  delete from public.clan_members
  where clan_id = clan_id_to_leave and profile_id = auth.uid();

  return null;
end;
$$;

revoke execute on function public.set_clan_member_leader(uuid, uuid, boolean) from public;
revoke execute on function public.transfer_clan_ownership(uuid, uuid) from public;
revoke execute on function public.kick_clan_member(uuid, uuid) from public;
revoke execute on function public.leave_clan(uuid) from public;
grant execute on function public.set_clan_member_leader(uuid, uuid, boolean) to authenticated;
grant execute on function public.transfer_clan_ownership(uuid, uuid) to authenticated;
grant execute on function public.kick_clan_member(uuid, uuid) to authenticated;
grant execute on function public.leave_clan(uuid) to authenticated;

alter table public.fixtures
add column if not exists home_paid_by uuid,
add column if not exists away_paid_by uuid,
add column if not exists home_paid_at timestamptz,
add column if not exists away_paid_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fixtures_home_paid_by_fkey'
  ) then
    alter table public.fixtures
    add constraint fixtures_home_paid_by_fkey
    foreign key (home_paid_by) references public.profiles(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'fixtures_away_paid_by_fkey'
  ) then
    alter table public.fixtures
    add constraint fixtures_away_paid_by_fkey
    foreign key (away_paid_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

create index if not exists fixtures_home_paid_by_idx
on public.fixtures (home_paid_by);

create index if not exists fixtures_away_paid_by_idx
on public.fixtures (away_paid_by);

update public.fixtures
set
  home_paid_by = created_by,
  home_paid_at = coalesce(created_at, now())
where home_paid_by is null;

update public.fixtures f
set
  away_paid_by = (
    select cm.profile_id
    from public.clan_members cm
    where cm.clan_id = f.away_clan_id
    order by
      case cm.role when 'owner' then 0 when 'leader' then 1 else 2 end,
      cm.created_at asc,
      cm.profile_id asc
    limit 1
  ),
  away_paid_at = coalesce(f.updated_at, f.created_at, now())
where f.away_clan_id is not null and f.away_paid_by is null;

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

  if not public.is_clan_manager(away_clan_id_to_use, auth.uid()) then
    raise exception 'Only clan owners and leaders can join a match.';
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
    status = 'SCHEDULED',
    away_paid_by = auth.uid(),
    away_paid_at = now()
  where id = fixture_to_join.id
  returning * into fixture_to_join;

  return fixture_to_join;
end;
$$;

grant execute on function public.create_fixture(uuid, text, date, text)
to authenticated;
grant execute on function public.join_fixture(uuid, uuid) to authenticated;
