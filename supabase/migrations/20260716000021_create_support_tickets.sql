-- Private customer-support requests are deliberately separate from moderation
-- reports. A support request must never increase a player or clan flag count or
-- become evidence for an automatic competitive sanction.

alter table public.admin_audit_events
drop constraint if exists admin_audit_events_entity_type_check;

alter table public.admin_audit_events
add constraint admin_audit_events_entity_type_check
check (
  entity_type in (
    'REPORT',
    'PLAYER',
    'CLAN',
    'CLAN_MATCH',
    'SOLO_MATCH',
    'ACTION',
    'POLICY',
    'ATTENDANCE',
    'APPEAL',
    'SANCTION',
    'SUPPORT_TICKET'
  )
);

create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  reference_number bigint generated always as identity
    (start with 1000 increment by 1) unique,
  requester_profile_id uuid references public.profiles(id) on delete set null,
  client_request_id uuid not null,
  category text not null check (
    category in (
      'APP_OR_TECHNICAL',
      'BOOKING_OR_PAYMENT',
      'MATCH_OR_VENUE',
      'ACCOUNT_OR_PROFILE',
      'SAFETY',
      'FEEDBACK',
      'OTHER'
    )
  ),
  details text not null check (
    char_length(trim(details)) between 10 and 4000
  ),
  context jsonb not null default '{}'::jsonb check (
    jsonb_typeof(context) = 'object'
    and octet_length(context::text) <= 8192
  ),
  priority text not null default 'NORMAL' check (
    priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT')
  ),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED', 'DUPLICATE')
  ),
  assigned_admin_id uuid references public.referee_profiles(profile_id)
    on delete set null,
  resolution_note text check (
    resolution_note is null
    or char_length(trim(resolution_note)) between 3 and 2000
  ),
  admin_note text check (
    admin_note is null or char_length(trim(admin_note)) between 3 and 3000
  ),
  resolved_by uuid references public.referee_profiles(profile_id)
    on delete restrict,
  resolved_at timestamptz,
  revision integer not null default 0 check (revision >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (requester_profile_id, client_request_id),
  check (
    (
      status in ('RESOLVED', 'CLOSED', 'DUPLICATE')
      and resolution_note is not null
      and resolved_by is not null
      and resolved_at is not null
    )
    or
    (
      status in ('OPEN', 'IN_PROGRESS')
      and resolution_note is null
      and resolved_by is null
      and resolved_at is null
    )
  )
);

create index support_tickets_queue_idx
on public.support_tickets (status, updated_at desc, id);

create index support_tickets_assignee_queue_idx
on public.support_tickets (assigned_admin_id, status, updated_at desc)
where assigned_admin_id is not null;

create index support_tickets_requester_created_idx
on public.support_tickets (requester_profile_id, created_at desc)
where requester_profile_id is not null;

drop trigger if exists set_support_tickets_updated_at
on public.support_tickets;
create trigger set_support_tickets_updated_at
before update on public.support_tickets
for each row execute function public.set_updated_at();

alter table public.support_tickets enable row level security;

-- There is intentionally no authenticated table policy. Players submit through
-- the narrowly scoped RPC below; the server-side admin application reads the
-- private queue with its service role after independently authenticating an
-- active admin.
revoke all on table public.support_tickets
from public, anon, authenticated, service_role;
grant select on table public.support_tickets to service_role;
revoke all on sequence public.support_tickets_reference_number_seq
from public, anon, authenticated, service_role;

create or replace function public.submit_support_ticket(
  category_to_use text,
  details_to_use text,
  context_to_use jsonb default '{}'::jsonb,
  client_request_id_to_use uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  requester_id uuid := auth.uid();
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  normalized_context jsonb := coalesce(context_to_use, '{}'::jsonb);
  request_id uuid := coalesce(client_request_id_to_use, gen_random_uuid());
  priority_to_use text;
  tickets_in_last_hour integer;
  existing_ticket public.support_tickets%rowtype;
  created_ticket public.support_tickets%rowtype;
  reference_to_return text;
begin
  if requester_id is null then
    raise exception 'You need to sign in again.';
  end if;

  if not exists (
    select 1
    from public.profiles profile
    where profile.id = requester_id
  ) then
    raise exception 'Finish setting up your profile before contacting support.';
  end if;

  if normalized_category not in (
    'APP_OR_TECHNICAL',
    'BOOKING_OR_PAYMENT',
    'MATCH_OR_VENUE',
    'ACCOUNT_OR_PROFILE',
    'SAFETY',
    'FEEDBACK',
    'OTHER'
  ) then
    raise exception 'Choose a valid support category.';
  end if;

  if char_length(normalized_details) not between 10 and 4000 then
    raise exception 'Describe the issue in 10 to 4000 characters.';
  end if;

  if jsonb_typeof(normalized_context) <> 'object'
    or octet_length(normalized_context::text) > 8192
  then
    raise exception 'The support request context is invalid or too large.';
  end if;

  -- Serialize requests from one account so parallel taps cannot evade either
  -- idempotency or the rolling rate limit.
  perform pg_advisory_xact_lock(
    hashtextextended(requester_id::text, 0)
  );

  if client_request_id_to_use is not null then
    select ticket.*
    into existing_ticket
    from public.support_tickets ticket
    where ticket.requester_profile_id = requester_id
      and ticket.client_request_id = client_request_id_to_use;

    if existing_ticket.id is not null then
      reference_to_return := 'FIELD-' || case
        when existing_ticket.reference_number < 1000000
          then lpad(existing_ticket.reference_number::text, 6, '0')
        else existing_ticket.reference_number::text
      end;

      return jsonb_build_object(
        'ticket_id', existing_ticket.id,
        'reference', reference_to_return
      );
    end if;
  end if;

  select count(*)::integer
  into tickets_in_last_hour
  from public.support_tickets ticket
  where ticket.requester_profile_id = requester_id
    and ticket.created_at >= clock_timestamp() - interval '1 hour';

  if tickets_in_last_hour >= 5 then
    raise exception 'You have sent several support requests recently. Try again in an hour.';
  end if;

  -- Priority is server-owned. A client cannot label its own request urgent.
  priority_to_use := case
    when normalized_category = 'SAFETY' then 'HIGH'
    else 'NORMAL'
  end;

  insert into public.support_tickets (
    requester_profile_id,
    client_request_id,
    category,
    details,
    context,
    priority
  ) values (
    requester_id,
    request_id,
    normalized_category,
    normalized_details,
    normalized_context,
    priority_to_use
  )
  returning * into created_ticket;

  reference_to_return := 'FIELD-' || case
    when created_ticket.reference_number < 1000000
      then lpad(created_ticket.reference_number::text, 6, '0')
    else created_ticket.reference_number::text
  end;

  return jsonb_build_object(
    'ticket_id', created_ticket.id,
    'reference', reference_to_return
  );
end;
$$;

create or replace function public.admin_update_support_ticket(
  actor_admin_id uuid,
  ticket_id_to_update uuid,
  action_to_take text,
  expected_revision_to_use integer,
  resolution_note_to_use text default null,
  admin_note_to_use text default null
)
returns public.support_tickets
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_action text := upper(trim(coalesce(action_to_take, '')));
  normalized_resolution_note text :=
    nullif(trim(coalesce(resolution_note_to_use, '')), '');
  normalized_admin_note text :=
    nullif(trim(coalesce(admin_note_to_use, '')), '');
  ticket_before public.support_tickets%rowtype;
  ticket_after public.support_tickets%rowtype;
  next_status text;
  audit_reason text;
  reference_to_use text;
  notification_title text;
  notification_body text;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;

  if expected_revision_to_use is null or expected_revision_to_use < 0 then
    raise exception 'A valid support ticket revision is required.';
  end if;

  if normalized_action not in (
    'START',
    'RESOLVE',
    'CLOSE',
    'REOPEN',
    'DUPLICATE'
  ) then
    raise exception 'Choose a valid support ticket action.';
  end if;

  if normalized_resolution_note is not null
    and char_length(normalized_resolution_note) > 2000
  then
    raise exception 'The resolution note must be 2000 characters or fewer.';
  end if;
  if normalized_admin_note is not null
    and char_length(normalized_admin_note) not between 3 and 3000
  then
    raise exception 'The private admin note must be 3 to 3000 characters.';
  end if;

  select ticket.*
  into ticket_before
  from public.support_tickets ticket
  where ticket.id = ticket_id_to_update
  for update;

  if ticket_before.id is null then
    raise exception 'Support ticket not found.';
  end if;

  if ticket_before.revision <> expected_revision_to_use then
    raise exception 'This support ticket changed. Refresh it before trying again.';
  end if;

  if normalized_action = 'START' then
    if ticket_before.status <> 'OPEN' then
      raise exception 'Only an open support ticket can be started.';
    end if;
    next_status := 'IN_PROGRESS';
  elsif normalized_action = 'RESOLVE' then
    if ticket_before.status not in ('OPEN', 'IN_PROGRESS') then
      raise exception 'Only an open support ticket can be resolved.';
    end if;
    if normalized_resolution_note is null
      or char_length(normalized_resolution_note) < 3
    then
      raise exception 'Add a short resolution note.';
    end if;
    next_status := 'RESOLVED';
  elsif normalized_action = 'CLOSE' then
    if ticket_before.status <> 'RESOLVED' then
      raise exception 'Resolve this support ticket before closing it.';
    end if;
    if normalized_admin_note is null then
      raise exception 'Record why this resolved request is being closed.';
    end if;
    if normalized_resolution_note is not null
      and char_length(normalized_resolution_note) < 3
    then
      raise exception 'The resolution note must contain at least 3 characters.';
    end if;
    next_status := 'CLOSED';
  elsif normalized_action = 'REOPEN' then
    if ticket_before.status not in ('RESOLVED', 'CLOSED', 'DUPLICATE') then
      raise exception 'Only a completed support ticket can be reopened.';
    end if;
    next_status := 'IN_PROGRESS';
  else
    if ticket_before.status not in ('OPEN', 'IN_PROGRESS') then
      raise exception 'Only an open support ticket can be marked duplicate.';
    end if;
    if normalized_resolution_note is null
      or char_length(normalized_resolution_note) < 3
    then
      raise exception 'Explain which request this duplicates.';
    end if;
    if normalized_admin_note is null then
      raise exception 'Record which request this duplicates in the private note.';
    end if;
    next_status := 'DUPLICATE';
  end if;

  update public.support_tickets
  set
    status = next_status,
    assigned_admin_id = case
      when assigned_admin_id is null
        or normalized_action in ('START', 'REOPEN')
        then actor_admin_id
      else assigned_admin_id
    end,
    resolution_note = case
      when normalized_action = 'REOPEN' then null
      when normalized_action in ('RESOLVE', 'DUPLICATE')
        then normalized_resolution_note
      when normalized_action = 'CLOSE'
        then coalesce(normalized_resolution_note, resolution_note)
      else resolution_note
    end,
    admin_note = coalesce(normalized_admin_note, admin_note),
    resolved_by = case
      when normalized_action = 'REOPEN' then null
      when normalized_action in ('RESOLVE', 'DUPLICATE') then actor_admin_id
      else resolved_by
    end,
    resolved_at = case
      when normalized_action = 'REOPEN' then null
      when normalized_action in ('RESOLVE', 'DUPLICATE')
        then clock_timestamp()
      else resolved_at
    end,
    revision = revision + 1
  where id = ticket_id_to_update
  returning * into ticket_after;

  audit_reason := left(
    coalesce(normalized_admin_note, normalized_resolution_note, ''),
    2000
  );

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state
  ) values (
    actor_admin_id,
    'SUPPORT_TICKET_' || normalized_action,
    'SUPPORT_TICKET',
    ticket_after.id,
    audit_reason,
    jsonb_build_object(
      'status', ticket_before.status,
      'assigned_admin_id', ticket_before.assigned_admin_id,
      'resolution_note', ticket_before.resolution_note,
      'admin_note', ticket_before.admin_note,
      'resolved_by', ticket_before.resolved_by,
      'resolved_at', ticket_before.resolved_at,
      'revision', ticket_before.revision
    ),
    jsonb_build_object(
      'status', ticket_after.status,
      'assigned_admin_id', ticket_after.assigned_admin_id,
      'resolution_note', ticket_after.resolution_note,
      'admin_note', ticket_after.admin_note,
      'resolved_by', ticket_after.resolved_by,
      'resolved_at', ticket_after.resolved_at,
      'revision', ticket_after.revision
    )
  );

  -- Only terminal, user-visible decisions create a notification. Private admin
  -- notes are never copied into the notification body.
  if normalized_action in ('RESOLVE', 'CLOSE', 'DUPLICATE')
    and ticket_after.requester_profile_id is not null
  then
    reference_to_use := 'FIELD-' || case
      when ticket_after.reference_number < 1000000
        then lpad(ticket_after.reference_number::text, 6, '0')
      else ticket_after.reference_number::text
    end;

    notification_title := case normalized_action
      when 'RESOLVE' then 'Support request resolved'
      when 'CLOSE' then 'Support request closed'
      else 'Support request updated'
    end;
    notification_body := left(
      reference_to_use || ' · ' || ticket_after.resolution_note,
      300
    );

    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    ) values (
      ticket_after.requester_profile_id,
      'SUPPORT_TICKET_UPDATE',
      notification_title,
      notification_body,
      'SUPPORT_TICKET',
      ticket_after.id,
      jsonb_build_object(
        'ticket_id', ticket_after.id,
        'reference', reference_to_use,
        'status', ticket_after.status,
        'resolution_note', ticket_after.resolution_note
      )
    );
  end if;

  return ticket_after;
end;
$$;

revoke all on function public.submit_support_ticket(
  text, text, jsonb, uuid
) from public, anon, authenticated;
grant execute on function public.submit_support_ticket(
  text, text, jsonb, uuid
) to authenticated;

revoke all on function public.admin_update_support_ticket(
  uuid, uuid, text, integer, text, text
) from public, anon, authenticated;
grant execute on function public.admin_update_support_ticket(
  uuid, uuid, text, integer, text, text
) to service_role;

comment on table public.support_tickets is
'Private customer-support requests. These are operational requests, not moderation reports or player flags.';

comment on column public.support_tickets.client_request_id is
'Client-generated retry key. Reusing it for the same requester returns the original ticket.';

comment on column public.support_tickets.admin_note is
'Private operational note. It is never included in player notifications.';
