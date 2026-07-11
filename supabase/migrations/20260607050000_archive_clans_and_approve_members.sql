alter table public.clans
add column if not exists archived_at timestamptz,
add column if not exists archived_by uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'clans_archived_by_fkey'
  ) then
    alter table public.clans
    add constraint clans_archived_by_fkey
    foreign key (archived_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

create index if not exists clans_archived_at_idx
on public.clans (archived_at);

alter table public.clan_members
add column if not exists left_at timestamptz,
add column if not exists removed_by uuid,
add column if not exists removal_reason text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'clan_members_removed_by_fkey'
  ) then
    alter table public.clan_members
    add constraint clan_members_removed_by_fkey
    foreign key (removed_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

alter table public.clan_members
drop constraint if exists clan_members_removal_reason_check;

alter table public.clan_members
add constraint clan_members_removal_reason_check
check (
  removal_reason is null
  or removal_reason in ('LEFT', 'KICKED', 'CLAN_ARCHIVED')
);

alter table public.clan_members
drop constraint if exists clan_members_profile_id_key;

drop index if exists public.clan_members_one_owner_per_clan_idx;

create unique index clan_members_one_active_owner_per_clan_idx
on public.clan_members (clan_id)
where role = 'owner' and left_at is null;

create unique index clan_members_one_active_clan_per_profile_idx
on public.clan_members (profile_id)
where left_at is null;

create or replace function public.profile_has_clan(profile_id_to_check uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.clan_members cm
    join public.clans c on c.id = cm.clan_id
    where cm.profile_id = profile_id_to_check
      and cm.left_at is null
      and c.archived_at is null
  );
$$;

create or replace function public.is_clan_owner(
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
    from public.clan_members cm
    join public.clans c on c.id = cm.clan_id
    where cm.clan_id = clan_id_to_check
      and cm.profile_id = profile_id_to_check
      and cm.role = 'owner'
      and cm.left_at is null
      and c.archived_at is null
  );
$$;

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
    from public.clan_members cm
    join public.clans c on c.id = cm.clan_id
    where cm.clan_id = clan_id_to_check
      and cm.profile_id = profile_id_to_check
      and cm.role in ('owner', 'leader')
      and cm.left_at is null
      and c.archived_at is null
  );
$$;

create or replace function public.clan_member_count(clan_id_to_check uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.clan_members
  where clan_id = clan_id_to_check and left_at is null;
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
  if new.left_at is not null then
    return new;
  end if;

  if tg_op = 'UPDATE'
    and old.clan_id = new.clan_id
    and old.left_at is null then
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
before insert or update of clan_id, left_at
on public.clan_members
for each row
execute function public.ensure_clan_member_limit();

create or replace function public.list_clans()
returns table (
  id uuid,
  name text,
  tag text,
  motto text,
  emblem text,
  theme_id text,
  pattern_id text,
  skill_rating integer,
  wins integer,
  losses integer,
  region text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  member_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id,
    c.name,
    c.tag,
    c.motto,
    c.emblem,
    c.theme_id,
    c.pattern_id,
    c.skill_rating,
    c.wins,
    c.losses,
    c.region,
    c.created_by,
    c.created_at,
    c.updated_at,
    count(cm.profile_id) as member_count
  from public.clans c
  left join public.clan_members cm
    on cm.clan_id = c.id and cm.left_at is null
  where c.archived_at is null
  group by c.id
  order by c.skill_rating desc, c.created_at desc;
$$;

drop policy if exists "Users can join a clan as a member" on public.clan_members;
drop policy if exists "Clan owners can delete their clan" on public.clans;

drop policy if exists "Users can create one clan for themselves" on public.clans;
create policy "Users can create one clan for themselves"
on public.clans
for insert
to authenticated
with check (
  auth.uid() = created_by
  and archived_at is null
  and archived_by is null
  and not public.profile_has_clan(auth.uid())
);

create table if not exists public.clan_join_requests (
  id uuid primary key default gen_random_uuid(),
  clan_id uuid not null references public.clans(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'PENDING' check (
    status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')
  ),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (clan_id, profile_id)
);

create index if not exists clan_join_requests_clan_status_idx
on public.clan_join_requests (clan_id, status, requested_at);

create index if not exists clan_join_requests_profile_status_idx
on public.clan_join_requests (profile_id, status);

drop trigger if exists set_clan_join_requests_updated_at
on public.clan_join_requests;
create trigger set_clan_join_requests_updated_at
before update on public.clan_join_requests
for each row
execute function public.set_updated_at();

alter table public.clan_join_requests enable row level security;

drop policy if exists "Relevant clan join requests are readable"
on public.clan_join_requests;
create policy "Relevant clan join requests are readable"
on public.clan_join_requests
for select
to authenticated
using (
  profile_id = auth.uid()
  or public.is_clan_manager(clan_id, auth.uid())
);

create or replace function public.request_clan_join(clan_id_to_join uuid)
returns public.clan_join_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_clan public.clans%rowtype;
  created_request public.clan_join_requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('profile:' || auth.uid()::text)::bigint
  );
  perform pg_advisory_xact_lock(hashtext(clan_id_to_join::text)::bigint);

  select * into requested_clan
  from public.clans
  where id = clan_id_to_join
  for update;

  if requested_clan.id is null or requested_clan.archived_at is not null then
    raise exception 'This clan is no longer available.';
  end if;

  if public.profile_has_clan(auth.uid()) then
    raise exception 'Leave your current clan before requesting another one.';
  end if;

  if public.clan_member_count(clan_id_to_join) >= 20 then
    raise exception 'This clan is full.';
  end if;

  insert into public.clan_join_requests (
    clan_id,
    profile_id,
    status,
    requested_at,
    reviewed_at,
    reviewed_by
  )
  values (
    clan_id_to_join,
    auth.uid(),
    'PENDING',
    now(),
    null,
    null
  )
  on conflict (clan_id, profile_id)
  do update set
    status = 'PENDING',
    requested_at = now(),
    reviewed_at = null,
    reviewed_by = null
  returning * into created_request;

  return created_request;
end;
$$;

create or replace function public.cancel_clan_join_request(
  request_id_to_cancel uuid
)
returns public.clan_join_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  cancelled_request public.clan_join_requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  update public.clan_join_requests
  set
    status = 'CANCELLED',
    reviewed_at = now(),
    reviewed_by = auth.uid()
  where id = request_id_to_cancel
    and profile_id = auth.uid()
    and status = 'PENDING'
  returning * into cancelled_request;

  if cancelled_request.id is null then
    raise exception 'That join request is no longer pending.';
  end if;

  return cancelled_request;
end;
$$;

create or replace function public.review_clan_join_request(
  request_id_to_review uuid,
  approve_request boolean
)
returns public.clan_join_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  request_to_review public.clan_join_requests%rowtype;
  reviewed_request public.clan_join_requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into request_to_review
  from public.clan_join_requests
  where id = request_id_to_review
  for update;

  if request_to_review.id is null then
    raise exception 'Join request not found.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('profile:' || request_to_review.profile_id::text)::bigint
  );
  perform pg_advisory_xact_lock(
    hashtext(request_to_review.clan_id::text)::bigint
  );

  if not public.is_clan_manager(request_to_review.clan_id, auth.uid()) then
    raise exception 'Only clan owners and leaders can review join requests.';
  end if;

  if request_to_review.status <> 'PENDING' then
    raise exception 'That join request has already been reviewed.';
  end if;

  if approve_request then
    if public.profile_has_clan(request_to_review.profile_id) then
      raise exception 'That player has already joined another clan.';
    end if;

    if public.clan_member_count(request_to_review.clan_id) >= 20 then
      raise exception 'This clan is full.';
    end if;

    insert into public.clan_members (
      clan_id,
      profile_id,
      role,
      created_at,
      left_at,
      removed_by,
      removal_reason
    )
    values (
      request_to_review.clan_id,
      request_to_review.profile_id,
      'member',
      now(),
      null,
      null,
      null
    )
    on conflict (clan_id, profile_id)
    do update set
      role = 'member',
      created_at = excluded.created_at,
      left_at = null,
      removed_by = null,
      removal_reason = null;
  end if;

  update public.clan_join_requests
  set
    status = case when approve_request then 'APPROVED' else 'REJECTED' end,
    reviewed_at = now(),
    reviewed_by = auth.uid()
  where id = request_to_review.id
  returning * into reviewed_request;

  if approve_request then
    update public.clan_join_requests
    set
      status = 'CANCELLED',
      reviewed_at = now(),
      reviewed_by = auth.uid()
    where profile_id = request_to_review.profile_id
      and id <> request_to_review.id
      and status = 'PENDING';
  end if;

  return reviewed_request;
end;
$$;

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
  where clan_id = clan_id_to_manage
    and profile_id = auth.uid()
    and left_at is null
  for update;

  if actor_role is distinct from 'owner' then
    raise exception 'Only the clan owner can manage leaders.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage
    and profile_id = profile_id_to_manage
    and left_at is null
  for update;

  if target_role is null then
    raise exception 'That player is no longer in this clan.';
  end if;

  if target_role = 'owner' then
    raise exception 'The clan owner cannot be promoted or demoted.';
  end if;

  update public.clan_members
  set role = case when make_leader then 'leader' else 'member' end
  where clan_id = clan_id_to_manage
    and profile_id = profile_id_to_manage
    and left_at is null
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
  where clan_id = clan_id_to_manage
    and profile_id = auth.uid()
    and left_at is null
  for update;

  if actor_role is distinct from 'owner' then
    raise exception 'Only the clan owner can transfer ownership.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage
    and profile_id = new_owner_profile_id
    and left_at is null
  for update;

  if target_role is null then
    raise exception 'Choose a player who is still in this clan.';
  end if;

  update public.clan_members
  set role = 'leader'
  where clan_id = clan_id_to_manage
    and profile_id = auth.uid()
    and left_at is null;

  update public.clan_members
  set role = 'owner'
  where clan_id = clan_id_to_manage
    and profile_id = new_owner_profile_id
    and left_at is null
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
  where clan_id = clan_id_to_manage
    and profile_id = auth.uid()
    and left_at is null
  for update;

  if actor_role is null or actor_role not in ('owner', 'leader') then
    raise exception 'Only clan owners and leaders can remove players.';
  end if;

  select role into target_role
  from public.clan_members
  where clan_id = clan_id_to_manage
    and profile_id = profile_id_to_remove
    and left_at is null
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

  update public.clan_members
  set
    left_at = now(),
    removed_by = auth.uid(),
    removal_reason = 'KICKED'
  where clan_id = clan_id_to_manage
    and profile_id = profile_id_to_remove
    and left_at is null;
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
  where clan_id = clan_id_to_leave
    and profile_id = auth.uid()
    and left_at is null
  for update;

  if leaving_role is null then
    raise exception 'You are no longer in this clan.';
  end if;

  if leaving_role = 'owner' then
    select profile_id into successor_profile_id
    from public.clan_members
    where clan_id = clan_id_to_leave
      and profile_id <> auth.uid()
      and left_at is null
    order by created_at asc, profile_id asc
    limit 1
    for update;

    if successor_profile_id is null then
      raise exception 'Add another player before leaving this clan.';
    end if;

    update public.clan_members
    set
      left_at = now(),
      removed_by = auth.uid(),
      removal_reason = 'LEFT'
    where clan_id = clan_id_to_leave
      and profile_id = auth.uid()
      and left_at is null;

    update public.clan_members
    set role = 'owner'
    where clan_id = clan_id_to_leave
      and profile_id = successor_profile_id
      and left_at is null;

    return successor_profile_id;
  end if;

  update public.clan_members
  set
    left_at = now(),
    removed_by = auth.uid(),
    removal_reason = 'LEFT'
  where clan_id = clan_id_to_leave
    and profile_id = auth.uid()
    and left_at is null;

  return null;
end;
$$;

create or replace function public.archive_clan(clan_id_to_archive uuid)
returns public.clans
language plpgsql
security definer
set search_path = public
as $$
declare
  archived_clan public.clans%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  perform pg_advisory_xact_lock(hashtext(clan_id_to_archive::text)::bigint);

  if not public.is_clan_owner(clan_id_to_archive, auth.uid()) then
    raise exception 'Only the clan owner can delete this clan.';
  end if;

  if exists (
    select 1
    from public.fixtures
    where status = 'LIVE'
      and (
        home_clan_id = clan_id_to_archive
        or away_clan_id = clan_id_to_archive
      )
  ) then
    raise exception 'A clan cannot be deleted while one of its matches is live.';
  end if;

  update public.fixtures
  set
    status = 'CANCELLED',
    cancelled_at = coalesce(cancelled_at, now()),
    cancellation_reason = 'Clan deleted.'
  where status in ('OPEN', 'SCHEDULED')
    and (
      home_clan_id = clan_id_to_archive
      or away_clan_id = clan_id_to_archive
    );

  update public.clan_join_requests
  set
    status = 'CANCELLED',
    reviewed_at = now(),
    reviewed_by = auth.uid()
  where clan_id = clan_id_to_archive and status = 'PENDING';

  update public.clan_members
  set
    left_at = now(),
    removed_by = auth.uid(),
    removal_reason = 'CLAN_ARCHIVED'
  where clan_id = clan_id_to_archive and left_at is null;

  update public.clans
  set
    archived_at = now(),
    archived_by = auth.uid()
  where id = clan_id_to_archive and archived_at is null
  returning * into archived_clan;

  if archived_clan.id is null then
    raise exception 'This clan has already been deleted.';
  end if;

  return archived_clan;
end;
$$;

create or replace function public.add_clan_owner_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.clan_members (clan_id, profile_id, role)
  values (new.id, new.created_by, 'owner');

  update public.clan_join_requests
  set
    status = 'CANCELLED',
    reviewed_at = now(),
    reviewed_by = new.created_by
  where profile_id = new.created_by and status = 'PENDING';

  return new;
end;
$$;

revoke execute on function public.request_clan_join(uuid) from public;
revoke execute on function public.cancel_clan_join_request(uuid) from public;
revoke execute on function public.review_clan_join_request(uuid, boolean) from public;
revoke execute on function public.archive_clan(uuid) from public;
grant execute on function public.request_clan_join(uuid) to authenticated;
grant execute on function public.cancel_clan_join_request(uuid) to authenticated;
grant execute on function public.review_clan_join_request(uuid, boolean)
to authenticated;
grant execute on function public.archive_clan(uuid) to authenticated;
