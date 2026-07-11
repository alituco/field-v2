alter table public.fixtures
add column if not exists cancellation_code text,
add column if not exists cancelled_by uuid,
add column if not exists cancellation_context jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fixtures_cancelled_by_fkey'
  ) then
    alter table public.fixtures
    add constraint fixtures_cancelled_by_fkey
    foreign key (cancelled_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

update public.fixtures
set
  cancellation_code = case
    when lower(coalesce(cancellation_reason, '')) like '%24 hour%'
      then 'NO_OPPONENT_24H'
    when lower(coalesce(cancellation_reason, '')) like '%another match%'
      then 'SLOT_CONFLICT_MIGRATION'
    when lower(coalesce(cancellation_reason, '')) like '%clan deleted%'
      then 'CLAN_ARCHIVED'
    else 'LEGACY_OTHER'
  end,
  cancellation_reason = coalesce(
    nullif(trim(cancellation_reason), ''),
    'Cancelled before detailed cancellation tracking was enabled.'
  ),
  cancelled_at = coalesce(cancelled_at, updated_at, now()),
  cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
where status = 'CANCELLED';

alter table public.fixtures
drop constraint if exists fixtures_cancellation_code_check;
alter table public.fixtures
add constraint fixtures_cancellation_code_check
check (
  cancellation_code is null
  or cancellation_code in (
    'NO_OPPONENT_24H',
    'CLAN_ARCHIVED',
    'SLOT_CONFLICT_MIGRATION',
    'ADMIN_CANCELLED',
    'LEGACY_OTHER'
  )
);

alter table public.fixtures
drop constraint if exists fixtures_cancellation_details_check;
alter table public.fixtures
add constraint fixtures_cancellation_details_check
check (
  (
    status = 'CANCELLED'
    and cancellation_code is not null
    and cancelled_at is not null
    and nullif(trim(cancellation_reason), '') is not null
  )
  or (
    status <> 'CANCELLED'
    and cancellation_code is null
    and cancelled_at is null
    and cancellation_reason is null
    and cancelled_by is null
  )
);

create index if not exists fixtures_cancellation_code_idx
on public.fixtures (cancellation_code)
where status = 'CANCELLED';

alter table public.clan_join_requests
add column if not exists cancellation_code text,
add column if not exists cancellation_reason text,
add column if not exists cancelled_at timestamptz,
add column if not exists cancelled_by uuid,
add column if not exists cancellation_context jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'clan_join_requests_cancelled_by_fkey'
  ) then
    alter table public.clan_join_requests
    add constraint clan_join_requests_cancelled_by_fkey
    foreign key (cancelled_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

update public.clan_join_requests
set
  cancellation_code = 'LEGACY_OTHER',
  cancellation_reason =
    'Cancelled before detailed cancellation tracking was enabled.',
  cancelled_at = coalesce(reviewed_at, updated_at, now()),
  cancelled_by = reviewed_by,
  cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
where status = 'CANCELLED';

alter table public.clan_join_requests
drop constraint if exists clan_join_requests_cancellation_code_check;
alter table public.clan_join_requests
add constraint clan_join_requests_cancellation_code_check
check (
  cancellation_code is null
  or cancellation_code in (
    'REQUESTER_CANCELLED',
    'CLAN_ARCHIVED',
    'JOINED_ANOTHER_CLAN',
    'CREATED_CLAN',
    'ADMIN_CANCELLED',
    'LEGACY_OTHER'
  )
);

alter table public.clan_join_requests
drop constraint if exists clan_join_requests_cancellation_details_check;
alter table public.clan_join_requests
add constraint clan_join_requests_cancellation_details_check
check (
  (
    status = 'CANCELLED'
    and cancellation_code is not null
    and cancelled_at is not null
    and nullif(trim(cancellation_reason), '') is not null
  )
  or (
    status <> 'CANCELLED'
    and cancellation_code is null
    and cancellation_reason is null
    and cancelled_at is null
    and cancelled_by is null
  )
);

create index if not exists clan_join_requests_cancellation_code_idx
on public.clan_join_requests (cancellation_code)
where status = 'CANCELLED';

create or replace function public.cancel_underfilled_fixtures()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cancelled_count integer;
begin
  update public.fixtures
  set
    status = 'CANCELLED',
    cancelled_at = now(),
    cancelled_by = null,
    cancellation_code = 'NO_OPPONENT_24H',
    cancellation_reason =
      'No opponent joined by the 24-hour cutoff before kickoff.',
    cancellation_context = jsonb_build_object(
      'cutoff_hours', 24,
      'kickoff_at', public.fixture_start_at(match_date, time_slot)
    ),
    updated_at = now()
  where status = 'OPEN'
    and away_clan_id is null
    and public.fixture_start_at(match_date, time_slot)
      <= now() + interval '24 hours';

  get diagnostics cancelled_count = row_count;
  return cancelled_count;
end;
$$;

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
    reviewed_by,
    cancellation_code,
    cancellation_reason,
    cancelled_at,
    cancelled_by,
    cancellation_context
  )
  values (
    clan_id_to_join,
    auth.uid(),
    'PENDING',
    now(),
    null,
    null,
    null,
    null,
    null,
    null,
    '{}'::jsonb
  )
  on conflict (clan_id, profile_id)
  do update set
    status = 'PENDING',
    requested_at = now(),
    reviewed_at = null,
    reviewed_by = null,
    cancellation_code = null,
    cancellation_reason = null,
    cancelled_at = null,
    cancelled_by = null,
    cancellation_context = '{}'::jsonb
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
    reviewed_by = auth.uid(),
    cancellation_code = 'REQUESTER_CANCELLED',
    cancellation_reason = 'The player cancelled their join request.',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    cancellation_context = jsonb_build_object('source', 'PLAYER_ACTION')
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
  accepted_clan_name text;
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
    reviewed_by = auth.uid(),
    cancellation_code = null,
    cancellation_reason = null,
    cancelled_at = null,
    cancelled_by = null,
    cancellation_context = '{}'::jsonb
  where id = request_to_review.id
  returning * into reviewed_request;

  if approve_request then
    select name into accepted_clan_name
    from public.clans
    where id = request_to_review.clan_id;

    update public.clan_join_requests
    set
      status = 'CANCELLED',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      cancellation_code = 'JOINED_ANOTHER_CLAN',
      cancellation_reason = format(
        'Request cancelled because the player joined %s.',
        coalesce(accepted_clan_name, 'another clan')
      ),
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_context = jsonb_build_object(
        'accepted_clan_id', request_to_review.clan_id,
        'accepted_clan_name', accepted_clan_name
      )
    where profile_id = request_to_review.profile_id
      and id <> request_to_review.id
      and status = 'PENDING';
  end if;

  return reviewed_request;
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

  select * into archived_clan
  from public.clans
  where id = clan_id_to_archive
  for update;

  if archived_clan.id is null or archived_clan.archived_at is not null then
    raise exception 'This clan has already been deleted.';
  end if;

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
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    cancellation_code = 'CLAN_ARCHIVED',
    cancellation_reason = format(
      'Match cancelled because %s was deleted.',
      archived_clan.name
    ),
    cancellation_context = jsonb_build_object(
      'archived_clan_id', archived_clan.id,
      'archived_clan_name', archived_clan.name
    )
  where status in ('OPEN', 'SCHEDULED')
    and (
      home_clan_id = clan_id_to_archive
      or away_clan_id = clan_id_to_archive
    );

  update public.clan_join_requests
  set
    status = 'CANCELLED',
    reviewed_at = now(),
    reviewed_by = auth.uid(),
    cancellation_code = 'CLAN_ARCHIVED',
    cancellation_reason = format(
      'Request cancelled because %s was deleted.',
      archived_clan.name
    ),
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    cancellation_context = jsonb_build_object(
      'archived_clan_id', archived_clan.id,
      'archived_clan_name', archived_clan.name
    )
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
    reviewed_by = new.created_by,
    cancellation_code = 'CREATED_CLAN',
    cancellation_reason = format(
      'Request cancelled because the player created %s.',
      new.name
    ),
    cancelled_at = now(),
    cancelled_by = new.created_by,
    cancellation_context = jsonb_build_object(
      'created_clan_id', new.id,
      'created_clan_name', new.name
    )
  where profile_id = new.created_by and status = 'PENDING';

  return new;
end;
$$;
