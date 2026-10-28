-- Disabled until a reviewed staging Firebase/APNs configuration is installed.
-- Tokens and delivery state are private, never player-readable profile fields.
create table fieldrush_private.push_configuration(
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  firebase_project_id text,
  check(not enabled or (firebase_project_id is not null and firebase_project_id ~ '^[a-z][a-z0-9-]{4,62}$'))
);
insert into fieldrush_private.push_configuration(singleton) values(true);
create table fieldrush_private.push_devices(
  installation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  binding_version bigint not null check(binding_version>0),
  registration_token text not null unique check(char_length(registration_token) between 20 and 4096),
  platform text not null check(platform in ('ios','android')),
  firebase_project_id text not null,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
-- A revocation must win even if the matching registration request is still in
-- flight and has not created its device row yet.
create table fieldrush_private.push_binding_tombstones(
  installation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  binding_version bigint not null check(binding_version>0)
);
create table fieldrush_private.push_deliveries(
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  installation_id uuid not null references fieldrush_private.push_devices(installation_id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  binding_version bigint not null,
  status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','SENT','SKIPPED','FAILED')),
  attempts integer not null default 0,
  claim_id uuid,
  locked_until timestamptz,
  next_attempt_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '24 hours',
  provider_message_id text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(notification_id,installation_id)
);
create index push_deliveries_due on fieldrush_private.push_deliveries(next_attempt_at)
  where status in ('PENDING','PROCESSING');
revoke all on fieldrush_private.push_configuration,fieldrush_private.push_devices,fieldrush_private.push_binding_tombstones,fieldrush_private.push_deliveries
  from public,anon,authenticated,service_role;
alter table fieldrush_private.push_configuration enable row level security;
alter table fieldrush_private.push_devices enable row level security;
alter table fieldrush_private.push_binding_tombstones enable row level security;
alter table fieldrush_private.push_deliveries enable row level security;

create function public.get_my_push_capability()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
begin
  perform fieldrush_private.require_user();
  return (select jsonb_build_object('enabled',enabled,'firebase_project_id',firebase_project_id)
    from fieldrush_private.push_configuration where singleton);
end;
$$;
revoke all on function public.get_my_push_capability() from public,anon;
grant execute on function public.get_my_push_capability() to authenticated;

create function public.configure_push_delivery(firebase_project_id_to_use text,enabled_to_use boolean)
returns void language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the push service can configure delivery.' using errcode='42501'; end if;
  if enabled_to_use is null or firebase_project_id_to_use is null or firebase_project_id_to_use !~ '^[a-z][a-z0-9-]{4,62}$' then raise exception 'Provide a valid Firebase project and explicit enable flag.' using errcode='22023'; end if;
  update fieldrush_private.push_configuration set enabled=enabled_to_use,firebase_project_id=firebase_project_id_to_use where singleton;
end;
$$;
revoke all on function public.configure_push_delivery(text,boolean) from public,anon,authenticated;
grant execute on function public.configure_push_delivery(text,boolean) to service_role;

create function public.register_my_push_device(installation_id_to_use uuid,binding_version_to_use bigint,
  token_to_use text,platform_to_use text,firebase_project_id_to_use text)
returns void language plpgsql security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user(); current_device fieldrush_private.push_devices%rowtype;
begin
  if installation_id_to_use is null or binding_version_to_use is null or binding_version_to_use<=0
    or char_length(coalesce(token_to_use,'')) not between 20 and 4096 or token_to_use ~ '[[:space:][:cntrl:]]'
    or platform_to_use not in ('ios','android') or platform_to_use is null then
    raise exception 'Provide a valid device registration.' using errcode='22023';
  end if;
  if not public.is_fieldrush_account_active(caller) then raise exception 'Complete signup before enabling phone notifications.' using errcode='42501'; end if;
  if not exists(select 1 from fieldrush_private.push_configuration where singleton and enabled
    and firebase_project_id=firebase_project_id_to_use) then raise exception 'Phone notifications are not configured.' using errcode='55000'; end if;
  perform pg_advisory_xact_lock(hashtextextended('push-installation:'||installation_id_to_use::text,0));
  if exists(select 1 from fieldrush_private.push_binding_tombstones where installation_id=installation_id_to_use
    and binding_version>=binding_version_to_use) then
    raise exception 'This device registration was revoked. Refresh notification settings.' using errcode='40001';
  end if;
  select * into current_device from fieldrush_private.push_devices where installation_id=installation_id_to_use for update;
  if found and (binding_version_to_use<current_device.binding_version
    or (binding_version_to_use=current_device.binding_version and (current_device.user_id<>caller or not current_device.active))) then
    raise exception 'This device registration is stale. Refresh notification settings.' using errcode='40001';
  end if;
  -- A token cannot belong to multiple installations, including after reinstall.
  -- Refuse rather than reassign a different installation on a guessed token.
  if exists(select 1 from fieldrush_private.push_devices where registration_token=token_to_use and installation_id<>installation_id_to_use) then
    raise exception 'Refresh this device notification token and try again.' using errcode='40001';
  end if;
  insert into fieldrush_private.push_devices(installation_id,user_id,binding_version,registration_token,platform,firebase_project_id)
  values(installation_id_to_use,caller,binding_version_to_use,token_to_use,platform_to_use,firebase_project_id_to_use)
  on conflict(installation_id) do update set user_id=excluded.user_id,binding_version=excluded.binding_version,
    registration_token=excluded.registration_token,platform=excluded.platform,firebase_project_id=excluded.firebase_project_id,
    active=true,updated_at=clock_timestamp();
end;
$$;
revoke all on function public.register_my_push_device(uuid,bigint,text,text,text) from public,anon;
grant execute on function public.register_my_push_device(uuid,bigint,text,text,text) to authenticated;

create function public.revoke_my_push_device(installation_id_to_use uuid,binding_version_to_use bigint)
returns void language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
declare caller uuid:=fieldrush_private.require_user();
begin
  if installation_id_to_use is null or binding_version_to_use is null or binding_version_to_use<=0 then raise exception 'Provide a valid device revocation.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('push-installation:'||installation_id_to_use::text,0));
  if not exists(select 1 from fieldrush_private.push_devices where installation_id=installation_id_to_use and user_id<>caller) then
    insert into fieldrush_private.push_binding_tombstones(installation_id,user_id,binding_version)
    values(installation_id_to_use,caller,binding_version_to_use)
    on conflict(installation_id) do update set user_id=excluded.user_id,binding_version=greatest(push_binding_tombstones.binding_version,excluded.binding_version);
  end if;
  update fieldrush_private.push_devices set active=false,binding_version=binding_version_to_use,updated_at=clock_timestamp()
    where installation_id=installation_id_to_use and user_id=caller and binding_version<=binding_version_to_use;
end;
$$;
revoke all on function public.revoke_my_push_device(uuid,bigint) from public,anon;
grant execute on function public.revoke_my_push_device(uuid,bigint) to authenticated;

create function fieldrush_private.enqueue_notification_push(notification_id_to_use uuid)
returns void language sql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  insert into fieldrush_private.push_deliveries(notification_id,installation_id,recipient_id,binding_version)
  select n.id,d.installation_id,n.recipient_profile_id,d.binding_version
  from public.notifications n join fieldrush_private.push_devices d on d.user_id=n.recipient_profile_id and d.active
  join fieldrush_private.push_configuration c on c.singleton and c.enabled and c.firebase_project_id=d.firebase_project_id
  where n.id=notification_id_to_use and n.dismissed_at is null and n.resolved_at is null and n.read_at is null
    and fieldrush_private.notification_preference_allows(n.recipient_profile_id,n.type)
  on conflict(notification_id,installation_id) do nothing;
$$;
revoke all on function fieldrush_private.enqueue_notification_push(uuid) from public,anon,authenticated,service_role;
create function fieldrush_private.enqueue_inserted_notification_push()
returns trigger language plpgsql security definer set search_path=pg_catalog,fieldrush_private,pg_temp as $$
begin perform fieldrush_private.enqueue_notification_push(new.id); return new; end;
$$;
revoke all on function fieldrush_private.enqueue_inserted_notification_push() from public,anon,authenticated,service_role;
create trigger enqueue_notification_push after insert on public.notifications
  for each row execute function fieldrush_private.enqueue_inserted_notification_push();

-- Claims return identifiers only. Payloads must be rechecked immediately before
-- dispatch, including current device owner/binding, preferences and dismissal.
-- The following event-source migration replaces this hook with authoritative
-- booking/roster/recording/publication checks for its generated optional events.
create function fieldrush_private.notification_source_is_current(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog as $$select true;$$;
revoke all on function fieldrush_private.notification_source_is_current(uuid)
  from public,anon,authenticated,service_role;

create function public.claim_push_deliveries(batch_size integer,claim_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
declare result jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the push worker can claim deliveries.' using errcode='42501'; end if;
  if claim_id_to_use is null or batch_size is null or batch_size not between 1 and 50 then raise exception 'Provide a valid delivery claim.' using errcode='22023'; end if;
  if not exists(select 1 from fieldrush_private.push_configuration where singleton and enabled) then return '[]'::jsonb; end if;
  with due as(select id from fieldrush_private.push_deliveries where status in ('PENDING','PROCESSING')
    and next_attempt_at<=clock_timestamp() and (locked_until is null or locked_until<clock_timestamp())
    order by next_attempt_at,id for update skip locked limit batch_size),
  claimed as(update fieldrush_private.push_deliveries d set status='PROCESSING',claim_id=claim_id_to_use,
    locked_until=clock_timestamp()+interval '2 minutes',attempts=attempts+1,updated_at=clock_timestamp()
    from due where d.id=due.id returning d.id)
  select coalesce(jsonb_agg(jsonb_build_object('id',id)),'[]'::jsonb) into result from claimed;
  return result;
end;
$$;
revoke all on function public.claim_push_deliveries(integer,uuid) from public,anon,authenticated;
grant execute on function public.claim_push_deliveries(integer,uuid) to service_role;

create function public.get_push_delivery_payload(delivery_id_to_use uuid,claim_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare delivery fieldrush_private.push_deliveries%rowtype; result jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the push worker can read delivery payloads.' using errcode='42501'; end if;
  select * into delivery from fieldrush_private.push_deliveries where id=delivery_id_to_use
    and status='PROCESSING' and claim_id=claim_id_to_use and locked_until>clock_timestamp() for update;
  if not found then return null; end if;
  select jsonb_build_object('delivery_id',delivery.id,'notification_id',n.id,'token',d.registration_token,
    'firebase_project_id',d.firebase_project_id,'platform',d.platform,'title','Fieldrush',
    'body','You have a new update. Open Fieldrush to view it.') into result
  from public.notifications n join fieldrush_private.push_devices d on d.installation_id=delivery.installation_id
  join fieldrush_private.push_configuration c on c.singleton and c.enabled and c.firebase_project_id=d.firebase_project_id
  where n.id=delivery.notification_id and n.recipient_profile_id=delivery.recipient_id
    and d.user_id=delivery.recipient_id and d.active and d.binding_version=delivery.binding_version
    and delivery.expires_at>clock_timestamp() and delivery.attempts<=8
    and n.dismissed_at is null and n.resolved_at is null and n.read_at is null
    and public.is_fieldrush_account_active(delivery.recipient_id)
    and fieldrush_private.notification_source_is_current(n.id)
    and fieldrush_private.notification_preference_allows(n.recipient_profile_id,n.type);
  if result is null then update fieldrush_private.push_deliveries set status='SKIPPED',locked_until=null,
    error_code='NOT_ELIGIBLE',updated_at=clock_timestamp() where id=delivery.id; end if;
  return result;
end;
$$;
revoke all on function public.get_push_delivery_payload(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_push_delivery_payload(uuid,uuid) to service_role;

create function public.complete_push_delivery(delivery_id_to_use uuid,claim_id_to_use uuid,
  outcome_to_use text,provider_message_id_to_use text default null,error_code_to_use text default null,
  retry_after_seconds_to_use integer default null,registration_token_to_invalidate text default null)
returns void language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
declare delivery fieldrush_private.push_deliveries%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the push worker can complete deliveries.' using errcode='42501'; end if;
  if outcome_to_use not in ('SENT','RETRY','INVALID_TOKEN','FAILED') or outcome_to_use is null
    or char_length(coalesce(provider_message_id_to_use,''))>255 or char_length(coalesce(error_code_to_use,''))>80
    or coalesce(error_code_to_use,'') !~ '^[A-Z0-9_]*$'
    or coalesce(retry_after_seconds_to_use,0) not between 0 and 86400 then raise exception 'Provide a valid delivery outcome.' using errcode='22023'; end if;
  select * into delivery from fieldrush_private.push_deliveries where id=delivery_id_to_use and status='PROCESSING'
    and claim_id=claim_id_to_use and locked_until>clock_timestamp();
  if not found then return; end if;
  if outcome_to_use='INVALID_TOKEN' then
    -- Auth deletion locks a device before cascading its delivery rows. Match
    -- that order so an invalid-token acknowledgement cannot deadlock deletion.
    perform 1 from fieldrush_private.push_devices where installation_id=delivery.installation_id for update;
  end if;
  select * into delivery from fieldrush_private.push_deliveries where id=delivery_id_to_use and status='PROCESSING'
    and claim_id=claim_id_to_use and locked_until>clock_timestamp() for update;
  if not found then return; end if;
  if outcome_to_use='INVALID_TOKEN' then
    update fieldrush_private.push_devices set active=false,updated_at=clock_timestamp()
      where installation_id=delivery.installation_id and user_id=delivery.recipient_id and binding_version=delivery.binding_version
        and registration_token=registration_token_to_invalidate;
  end if;
  update fieldrush_private.push_deliveries set status=case when outcome_to_use='SENT' then 'SENT'
      when outcome_to_use='RETRY' and attempts<8 and expires_at>clock_timestamp() then 'PENDING' else 'FAILED' end,
    provider_message_id=case when outcome_to_use='SENT' then provider_message_id_to_use else null end,
    error_code=error_code_to_use,locked_until=null,claim_id=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(least(1800,30*power(2,attempts)::integer),coalesce(retry_after_seconds_to_use,0))),updated_at=clock_timestamp()
    where id=delivery.id;
end;
$$;
revoke all on function public.complete_push_delivery(uuid,uuid,text,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.complete_push_delivery(uuid,uuid,text,text,text,integer,text) to service_role;

notify pgrst,'reload schema';
