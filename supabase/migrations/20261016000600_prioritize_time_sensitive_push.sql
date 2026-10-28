-- Urgent match alerts must not wait behind a marketing publication. Priority
-- is derived from the canonical notification, never a client-supplied field.
create function fieldrush_private.push_priority_for_type(notification_type text)
returns smallint language sql immutable set search_path=pg_catalog as $$
  select case when notification_type='NEWS_AND_OFFERS' then 2
    when notification_type in ('CLAN_CALLUP','OPEN_QUEUE_PARTY_INVITE','LADDER_MOVE','REPLAY_READY') then 1
    -- Match reminders, open spots, payments, safety and other mandatory notices
    -- take the urgent lane. Unknown operational types never become marketing.
    else 0 end::smallint;
$$;
revoke all on function fieldrush_private.push_priority_for_type(text) from public,anon,authenticated,service_role;

create function fieldrush_private.push_source_deadline(event_data jsonb,fallback_deadline timestamptz)
returns timestamptz language plpgsql stable set search_path=pg_catalog,pg_temp as $$
begin
  if event_data?'expires_at' then
    if jsonb_typeof(event_data->'expires_at') is distinct from 'string' then return '-infinity'::timestamptz; end if;
    return least(fallback_deadline,(event_data->>'expires_at')::timestamptz);
  end if;
  return fallback_deadline;
exception when invalid_datetime_format or datetime_field_overflow then return '-infinity'::timestamptz;
end;
$$;
revoke all on function fieldrush_private.push_source_deadline(jsonb,timestamptz) from public,anon,authenticated,service_role;

alter table fieldrush_private.push_deliveries add column priority smallint not null default 1 check(priority between 0 and 2);
update fieldrush_private.push_deliveries d set priority=fieldrush_private.push_priority_for_type(n.type),
  expires_at=fieldrush_private.push_source_deadline(n.data,d.expires_at)
  from public.notifications n where n.id=d.notification_id;
create index push_deliveries_priority_due on fieldrush_private.push_deliveries(priority,next_attempt_at,id)
  where status in ('PENDING','PROCESSING');

create function fieldrush_private.assign_push_delivery_priority()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare notification_type text; event_data jsonb;
begin
  select n.type,n.data into notification_type,event_data from public.notifications n where n.id=new.notification_id;
  new.priority:=fieldrush_private.push_priority_for_type(notification_type);
  new.expires_at:=fieldrush_private.push_source_deadline(event_data,new.expires_at);
  return new;
end;
$$;
revoke all on function fieldrush_private.assign_push_delivery_priority() from public,anon,authenticated,service_role;
create trigger assign_push_delivery_priority before insert on fieldrush_private.push_deliveries
  for each row execute function fieldrush_private.assign_push_delivery_priority();

create or replace function public.claim_push_deliveries(batch_size integer,claim_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
declare result jsonb; at_time timestamptz:=clock_timestamp();
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the push worker can claim deliveries.' using errcode='42501'; end if;
  if claim_id_to_use is null or batch_size is null or batch_size not between 1 and 50 then raise exception 'Provide a valid delivery claim.' using errcode='22023'; end if;
  if not exists(select 1 from fieldrush_private.push_configuration where singleton and enabled) then return '[]'::jsonb; end if;
  with expired as (
    select id from fieldrush_private.push_deliveries where status in ('PENDING','PROCESSING')
      and (locked_until is null or locked_until<at_time) and (expires_at<=at_time or attempts>=8)
    order by next_attempt_at,id limit 200 for update skip locked
  ) update fieldrush_private.push_deliveries d set status='SKIPPED',locked_until=null,
    error_code='EXPIRED_OR_EXHAUSTED',updated_at=at_time from expired where expired.id=d.id;
  -- Normal ten-delivery batch reserves 8 urgent, 1 routine, 1 marketing slots.
  -- Unused slots are immediately filled in priority order. Thus a publication
  -- cannot block a newly-due reminder, and sustained urgent traffic does not
  -- completely starve consented marketing/routine notifications.
  with reserved as materialized (
    select candidate.id from (values
      (0,greatest(batch_size-2,1)),
      (1,case when batch_size>=2 then 1 else 0 end),
      (2,case when batch_size>=3 then 1 else 0 end)
    ) band(priority,slots)
    cross join lateral (
      select d.id from fieldrush_private.push_deliveries d
      where d.priority=band.priority and d.status in ('PENDING','PROCESSING')
        and d.next_attempt_at<=at_time and (d.locked_until is null or d.locked_until<at_time)
        and d.expires_at>at_time and d.attempts<8
      order by d.next_attempt_at,d.id limit band.slots for update of d skip locked
    ) candidate
  ), fill as materialized (
    select d.id from fieldrush_private.push_deliveries d
    where d.status in ('PENDING','PROCESSING') and d.next_attempt_at<=at_time
      and (d.locked_until is null or d.locked_until<at_time) and d.expires_at>at_time and d.attempts<8
      and not exists(select 1 from reserved r where r.id=d.id)
    order by d.priority,d.next_attempt_at,d.id
    limit greatest(batch_size-(select count(*)::integer from reserved),0) for update of d skip locked
  ), due as (select id from reserved union all select id from fill),
  claimed as (
    update fieldrush_private.push_deliveries d set status='PROCESSING',claim_id=claim_id_to_use,
      locked_until=at_time+interval '2 minutes',attempts=attempts+1,updated_at=at_time
    from due where d.id=due.id returning d.id,d.priority,d.next_attempt_at
  ) select coalesce(jsonb_agg(jsonb_build_object('id',id) order by priority,next_attempt_at,id),'[]'::jsonb)
    into result from claimed;
  return result;
end;
$$;
revoke all on function public.claim_push_deliveries(integer,uuid) from public,anon,authenticated;
grant execute on function public.claim_push_deliveries(integer,uuid) to service_role;
-- Existing payload, source, consent, device binding and token-revocation checks
-- still run immediately before every send. No activation flags are changed.
notify pgrst,'reload schema';
