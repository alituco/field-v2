-- Run after 20260716000021_create_support_tickets.sql. Every verification row
-- is rolled back, including its audit events and player notifications.

begin;

-- Begin as the player; switch to the service only for the admin API actions.
select set_config('request.jwt.claim.role', 'authenticated', true);

do $verify$
declare
  requester_id uuid;
  admin_id uuid;
  request_id uuid := gen_random_uuid();
  response jsonb;
  replay_response jsonb;
  ticket_id uuid;
  safety_ticket_id uuid;
  ticket_row public.support_tickets%rowtype;
  index_number integer;
  rate_limit_rejected boolean := false;
  stale_revision_rejected boolean := false;
  close_without_note_rejected boolean := false;
  duplicate_without_note_rejected boolean := false;
begin
  select profile.id
  into requester_id
  from public.profiles profile
  where not exists (
    select 1
    from public.support_tickets ticket
    where ticket.requester_profile_id = profile.id
      and ticket.created_at >= clock_timestamp() - interval '1 hour'
  )
  order by profile.created_at, profile.id
  limit 1;

  select referee.profile_id
  into admin_id
  from public.referee_profiles referee
  where referee.role = 'admin'
    and referee.is_active
    and fieldrush_private.staff_identity_is_active(referee.profile_id)
  order by referee.created_at, referee.profile_id
  limit 1;

  if requester_id is null or admin_id is null then
    raise exception 'Support verification needs one unused profile and one active admin.';
  end if;

  perform set_config('request.jwt.claim.sub', requester_id::text, true);

  response := public.submit_support_ticket(
    'APP_OR_TECHNICAL',
    'Verification-only support request that will be rolled back.',
    jsonb_build_object(
      'entry_point', 'support_verification',
      'app_version', 'verification'
    ),
    request_id
  );
  ticket_id := (response ->> 'ticket_id')::uuid;

  if response ->> 'reference' not like 'FIELD-%' then
    raise exception 'Support submission did not return a friendly reference.';
  end if;

  select ticket.*
  into ticket_row
  from public.support_tickets ticket
  where ticket.id = ticket_id;

  if ticket_row.requester_profile_id is distinct from requester_id
    or ticket_row.category <> 'APP_OR_TECHNICAL'
    or ticket_row.priority <> 'NORMAL'
    or ticket_row.status <> 'OPEN'
    or ticket_row.revision <> 0
  then
    raise exception 'Support submission did not preserve server-owned identity or state.';
  end if;

  replay_response := public.submit_support_ticket(
    'SAFETY',
    'A retry must return the original request instead of changing it.',
    '{}'::jsonb,
    request_id
  );

  if replay_response ->> 'ticket_id' <> response ->> 'ticket_id'
    or replay_response ->> 'reference' <> response ->> 'reference'
  then
    raise exception 'Client request idempotency did not return the original ticket.';
  end if;

  response := public.submit_support_ticket(
    'SAFETY',
    'Verification-only safety request that will be rolled back.',
    '{}'::jsonb,
    gen_random_uuid()
  );
  safety_ticket_id := (response ->> 'ticket_id')::uuid;

  if not exists (
    select 1
    from public.support_tickets ticket
    where ticket.id = safety_ticket_id
      and ticket.priority = 'HIGH'
  ) then
    raise exception 'Safety support requests are not receiving server-owned high priority.';
  end if;

  -- The first request, safety request, and these three requests reach the
  -- five-per-hour ceiling.
  for index_number in 1..3 loop
    perform public.submit_support_ticket(
      'FEEDBACK',
      'Verification-only rate-limit request number ' || index_number || '.',
      '{}'::jsonb,
      gen_random_uuid()
    );
  end loop;

  begin
    perform public.submit_support_ticket(
      'OTHER',
      'This sixth unique support request must be rejected by the rate limit.',
      '{}'::jsonb,
      gen_random_uuid()
    );
  exception when others then
    if position('try again in an hour' in lower(sqlerrm)) > 0 then
      rate_limit_rejected := true;
    else
      raise;
    end if;
  end;

  if not rate_limit_rejected then
    raise exception 'The five-per-hour support rate limit was not enforced.';
  end if;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  select *
  into ticket_row
  from public.admin_update_support_ticket(
    admin_id,
    ticket_id,
    'START',
    0,
    null,
    'Verification-only private admin note.'
  );

  if ticket_row.status <> 'IN_PROGRESS'
    or ticket_row.revision <> 1
    or ticket_row.assigned_admin_id is distinct from admin_id
  then
    raise exception 'START did not claim and begin the support request.';
  end if;

  begin
    perform public.admin_update_support_ticket(
      admin_id,
      ticket_id,
      'RESOLVE',
      0,
      'This stale revision must not be accepted.',
      null
    );
  exception when others then
    if position('refresh it' in lower(sqlerrm)) > 0 then
      stale_revision_rejected := true;
    else
      raise;
    end if;
  end;

  if not stale_revision_rejected then
    raise exception 'A stale support ticket revision was accepted.';
  end if;

  select *
  into ticket_row
  from public.admin_update_support_ticket(
    admin_id,
    ticket_id,
    'RESOLVE',
    1,
    'The verification request was reviewed and resolved.',
    null
  );

  if ticket_row.status <> 'RESOLVED'
    or ticket_row.revision <> 2
    or ticket_row.resolved_by is distinct from admin_id
    or ticket_row.resolved_at is null
  then
    raise exception 'RESOLVE did not persist terminal support state.';
  end if;

  if not exists (
    select 1
    from public.notifications notification
    where notification.recipient_profile_id = requester_id
      and notification.type = 'SUPPORT_TICKET_UPDATE'
      and notification.related_entity_type = 'SUPPORT_TICKET'
      and notification.related_entity_id = ticket_id
      and notification.data ->> 'status' = 'RESOLVED'
      and notification.data ->> 'resolution_note' =
        'The verification request was reviewed and resolved.'
  ) then
    raise exception 'RESOLVE did not notify the requester.';
  end if;
  if exists (
    select 1
    from public.notifications notification
    where notification.related_entity_type = 'SUPPORT_TICKET'
      and notification.related_entity_id = ticket_id
      and notification.body ilike '%Verification-only private admin note%'
  ) then
    raise exception 'A private support admin note leaked into a player notification.';
  end if;

  begin
    perform public.admin_update_support_ticket(
      admin_id,
      ticket_id,
      'CLOSE',
      2,
      null,
      null
    );
  exception when others then
    if position('being closed' in lower(sqlerrm)) > 0 then
      close_without_note_rejected := true;
    else
      raise;
    end if;
  end;

  if not close_without_note_rejected then
    raise exception 'CLOSE accepted a missing private audit note.';
  end if;

  select *
  into ticket_row
  from public.admin_update_support_ticket(
    admin_id,
    ticket_id,
    'CLOSE',
    2,
    null,
    'Closing the resolved verification request.'
  );

  if ticket_row.status <> 'CLOSED' or ticket_row.revision <> 3 then
    raise exception 'CLOSE did not preserve a completed support request.';
  end if;

  select *
  into ticket_row
  from public.admin_update_support_ticket(
    admin_id,
    ticket_id,
    'REOPEN',
    3,
    null,
    'Reopening for verification.'
  );

  if ticket_row.status <> 'IN_PROGRESS'
    or ticket_row.revision <> 4
    or ticket_row.assigned_admin_id is distinct from admin_id
    or ticket_row.resolution_note is not null
    or ticket_row.resolved_by is not null
    or ticket_row.resolved_at is not null
  then
    raise exception 'REOPEN did not clear the completed support state.';
  end if;

  begin
    perform public.admin_update_support_ticket(
      admin_id,
      ticket_id,
      'DUPLICATE',
      4,
      'This verification request duplicates another test request.',
      null
    );
  exception when others then
    if position('private note' in lower(sqlerrm)) > 0 then
      duplicate_without_note_rejected := true;
    else
      raise;
    end if;
  end;

  if not duplicate_without_note_rejected then
    raise exception 'DUPLICATE accepted a missing private audit note.';
  end if;

  select *
  into ticket_row
  from public.admin_update_support_ticket(
    admin_id,
    ticket_id,
    'DUPLICATE',
    4,
    'This verification request duplicates another test request.',
    'Duplicate of the verification safety request.'
  );

  if ticket_row.status <> 'DUPLICATE' or ticket_row.revision <> 5 then
    raise exception 'DUPLICATE did not complete the support request.';
  end if;

  if (
    select count(distinct notification.data ->> 'status')
    from public.notifications notification
    where notification.recipient_profile_id = requester_id
      and notification.type = 'SUPPORT_TICKET_UPDATE'
      and notification.related_entity_id = ticket_id
      and notification.data ->> 'status' in (
        'RESOLVED',
        'CLOSED',
        'DUPLICATE'
      )
  ) <> 3 then
    raise exception 'One or more terminal support updates did not notify the requester.';
  end if;

  if (
    select count(*)
    from public.admin_audit_events audit
    where audit.entity_type = 'SUPPORT_TICKET'
      and audit.entity_id = ticket_id
      and audit.action in (
        'SUPPORT_TICKET_START',
        'SUPPORT_TICKET_RESOLVE',
        'SUPPORT_TICKET_CLOSE',
        'SUPPORT_TICKET_REOPEN',
        'SUPPORT_TICKET_DUPLICATE'
      )
  ) <> 5 then
    raise exception 'Support ticket transitions were not fully audited.';
  end if;

  if exists (
    select 1
    from public.moderation_reports report
    where report.reporter_profile_id = requester_id
      and report.details =
        'Verification-only support request that will be rolled back.'
  ) then
    raise exception 'A support request leaked into the moderation report system.';
  end if;
end;
$verify$;

do $catalog$
declare
  submit_definition text;
  admin_definition text;
begin
  if to_regprocedure(
    'public.submit_support_ticket(text,text,jsonb,uuid)'
  ) is null then
    raise exception 'Missing submit_support_ticket RPC.';
  end if;
  if to_regprocedure(
    'public.admin_update_support_ticket(uuid,uuid,text,integer,text,text)'
  ) is null then
    raise exception 'Missing admin_update_support_ticket RPC.';
  end if;

  if has_table_privilege(
    'authenticated',
    'public.support_tickets',
    'SELECT'
  ) or has_table_privilege(
    'authenticated',
    'public.support_tickets',
    'INSERT'
  ) or has_table_privilege(
    'authenticated',
    'public.support_tickets',
    'UPDATE'
  ) then
    raise exception 'Authenticated users have direct support ticket table access.';
  end if;

  if has_table_privilege(
    'service_role',
    'public.support_tickets',
    'INSERT'
  ) or has_table_privilege(
    'service_role',
    'public.support_tickets',
    'UPDATE'
  ) or has_table_privilege(
    'service_role',
    'public.support_tickets',
    'DELETE'
  ) then
    raise exception 'The service role can bypass the audited support RPC.';
  end if;

  if not has_table_privilege(
    'service_role',
    'public.support_tickets',
    'SELECT'
  ) then
    raise exception 'The admin service cannot read the support queue.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.submit_support_ticket(text,text,jsonb,uuid)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated users cannot execute submit_support_ticket.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.admin_update_support_ticket(uuid,uuid,text,integer,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated users can execute the admin support RPC.';
  end if;

  select pg_get_functiondef(
    'public.submit_support_ticket(text,text,jsonb,uuid)'::regprocedure
  )
  into submit_definition;

  if position('auth.uid()' in submit_definition) = 0
    or position('pg_advisory_xact_lock' in submit_definition) = 0
    or position('tickets_in_last_hour >= 5' in submit_definition) = 0
  then
    raise exception 'Support submission identity, idempotency, or rate limiting is incomplete.';
  end if;

  select pg_get_functiondef(
    'public.admin_update_support_ticket(uuid,uuid,text,integer,text,text)'::regprocedure
  )
  into admin_definition;

  if position('is_active_moderation_admin' in admin_definition) = 0
    or position('ticket_before.revision <> expected_revision_to_use' in admin_definition) = 0
    or position('SUPPORT_TICKET_' in admin_definition) = 0
  then
    raise exception 'Admin support transitions are not authorized, concurrent, and audited.';
  end if;
end;
$catalog$;

rollback;
