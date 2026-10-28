-- Production push is an explicit rollout. Installing this migration neither
-- enables delivery nor changes any existing staging configuration or secret.
-- The database environment is an administration binding, not an environment
-- inferred from a caller-supplied URL. The Edge worker independently validates
-- its own exact hosted project and FIELD_ENVIRONMENT before contacting FCM.
alter table fieldrush_private.push_dispatch_configuration
  add column environment text not null default 'staging'
    check(environment in ('staging','production'));
alter table fieldrush_private.push_dispatch_configuration
  drop constraint push_dispatch_configuration_endpoint_url_check;
alter table fieldrush_private.push_dispatch_configuration
  add constraint push_dispatch_configuration_endpoint_url_check check(
    endpoint_url is null or endpoint_url=case environment
      when 'staging' then 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch'
      when 'production' then 'https://zjsjuuhborxrlmdcpvlj.supabase.co/functions/v1/fieldrush-push-dispatch'
    end
  );

-- Serialize provider enable/disable with environment and dispatcher changes so
-- concurrent administration cannot turn delivery on during an environment swap.
create or replace function public.configure_push_delivery(firebase_project_id_to_use text,enabled_to_use boolean)
returns void language plpgsql security definer
set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the push service can configure delivery.' using errcode='42501';
  end if;
  if enabled_to_use is null or firebase_project_id_to_use is null
    or firebase_project_id_to_use !~ '^[a-z][a-z0-9-]{4,62}$' then
    raise exception 'Provide a valid Firebase project and explicit enable flag.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-push-dispatch-configuration',0));
  update fieldrush_private.push_configuration
    set enabled=enabled_to_use,firebase_project_id=firebase_project_id_to_use where singleton;
end;
$$;
revoke all on function public.configure_push_delivery(text,boolean) from public,anon,authenticated;
grant execute on function public.configure_push_delivery(text,boolean) to service_role;

create function public.configure_push_dispatch_environment(environment_to_use text)
returns void language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
declare current_environment text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the push administration service can configure the environment.' using errcode='42501';
  end if;
  if environment_to_use is null or environment_to_use not in ('staging','production') then
    raise exception 'Choose the exact hosted push environment.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-push-dispatch-configuration',0));
  select environment into current_environment
    from fieldrush_private.push_dispatch_configuration where singleton;
  if current_environment=environment_to_use then return; end if;
  if exists(select 1 from fieldrush_private.push_dispatch_configuration where singleton and enabled)
    or exists(select 1 from fieldrush_private.push_configuration where singleton and enabled) then
    raise exception 'Disable push delivery and dispatch before changing the environment.' using errcode='55000';
  end if;
  update fieldrush_private.push_dispatch_configuration
    set environment=environment_to_use,endpoint_url=null where singleton;
  -- Changing environments cannot inherit an old provider configuration. The
  -- next explicit dispatch setup supplies and stores that environment's secret.
  update fieldrush_private.push_configuration set firebase_project_id=null where singleton;
end;
$$;
revoke all on function public.configure_push_dispatch_environment(text) from public,anon,authenticated;
grant execute on function public.configure_push_dispatch_environment(text) to service_role;

create or replace function public.configure_push_dispatch(endpoint_url_to_use text,worker_secret_to_use text,enabled_to_use boolean)
returns void language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
declare secret_id uuid; expected_endpoint text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the push administration service can configure dispatch.' using errcode='42501';
  end if;
  if enabled_to_use is null then
    raise exception 'Choose whether dispatch is enabled.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-push-dispatch-configuration',0));
  -- Emergency disable remains independent of provider or Vault availability.
  if not enabled_to_use then
    update fieldrush_private.push_dispatch_configuration set enabled=false where singleton;
    return;
  end if;
  select case environment
      when 'staging' then 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch'
      when 'production' then 'https://zjsjuuhborxrlmdcpvlj.supabase.co/functions/v1/fieldrush-push-dispatch'
    end into expected_endpoint
    from fieldrush_private.push_dispatch_configuration where singleton;
  if expected_endpoint is null or endpoint_url_to_use is distinct from expected_endpoint
    or worker_secret_to_use is null or char_length(worker_secret_to_use) not between 32 and 512
    or worker_secret_to_use !~ '^[!-~]+$'
    or not exists(select 1 from fieldrush_private.push_configuration where singleton and enabled) then
    raise exception 'Configure this environment and push delivery before enabling dispatch.' using errcode='22023';
  end if;
  select id into secret_id from vault.secrets where name='fieldrush_push_worker_secret';
  if secret_id is null then
    perform vault.create_secret(worker_secret_to_use,'fieldrush_push_worker_secret','Protected push dispatcher authorization');
  else
    perform vault.update_secret(secret_id,worker_secret_to_use);
  end if;
  update fieldrush_private.push_dispatch_configuration
    set endpoint_url=endpoint_url_to_use,enabled=true where singleton;
end;
$$;
revoke all on function public.configure_push_dispatch(text,text,boolean) from public,anon,authenticated;
grant execute on function public.configure_push_dispatch(text,text,boolean) to service_role;
notify pgrst,'reload schema';
