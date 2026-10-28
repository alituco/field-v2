-- Installing the dispatcher never activates delivery. Its worker secret is
-- stored only in Vault and must also be configured in the staging Edge runtime.
create table fieldrush_private.push_dispatch_configuration (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  endpoint_url text,
  check(endpoint_url is null or endpoint_url='https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch')
);
insert into fieldrush_private.push_dispatch_configuration(singleton) values(true);
alter table fieldrush_private.push_dispatch_configuration enable row level security;
revoke all on fieldrush_private.push_dispatch_configuration from public,anon,authenticated,service_role;

create function public.configure_push_dispatch(endpoint_url_to_use text,worker_secret_to_use text,enabled_to_use boolean)
returns void language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
declare secret_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the push administration service can configure dispatch.' using errcode='42501';
  end if;
  if enabled_to_use is null then
    raise exception 'Choose whether dispatch is enabled.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-push-dispatch-configuration',0));
  -- Disabling must remain possible even after provider credentials are revoked.
  if not enabled_to_use then
    update fieldrush_private.push_dispatch_configuration set enabled=false where singleton;
    return;
  end if;
  if endpoint_url_to_use is distinct from 'https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch'
    or worker_secret_to_use is null or char_length(worker_secret_to_use) not between 32 and 512
    or worker_secret_to_use !~ '^[!-~]+$'
    or not exists(select 1 from fieldrush_private.push_configuration where singleton and enabled) then
    raise exception 'Staging push delivery must be configured before dispatch can be enabled.' using errcode='22023';
  end if;
  select id into secret_id from vault.secrets where name='fieldrush_push_worker_secret';
  if secret_id is null then
    perform vault.create_secret(worker_secret_to_use,'fieldrush_push_worker_secret','Protected staging push dispatcher authorization');
  else
    perform vault.update_secret(secret_id,worker_secret_to_use);
  end if;
  update fieldrush_private.push_dispatch_configuration
    set endpoint_url=endpoint_url_to_use,enabled=true where singleton;
end;
$$;
revoke all on function public.configure_push_dispatch(text,text,boolean) from public,anon,authenticated;
grant execute on function public.configure_push_dispatch(text,text,boolean) to service_role;

create function fieldrush_private.dispatch_pending_push()
returns bigint language plpgsql security definer
set search_path=pg_catalog,fieldrush_private,pg_temp as $$
declare endpoint text; worker_secret text; request_id bigint;
begin
  select d.endpoint_url into endpoint from fieldrush_private.push_dispatch_configuration d
    join fieldrush_private.push_configuration c on c.singleton and c.enabled
    where d.singleton and d.enabled;
  if endpoint is null then return null; end if;
  select decrypted_secret into worker_secret from vault.decrypted_secrets where name='fieldrush_push_worker_secret';
  if worker_secret is null or char_length(worker_secret) not between 32 and 512
    or worker_secret !~ '^[!-~]+$' then return null; end if;
  select net.http_post(url:=endpoint,body:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||worker_secret),
    timeout_milliseconds:=90000) into request_id;
  return request_id;
end;
$$;
revoke all on function fieldrush_private.dispatch_pending_push() from public,anon,authenticated,service_role;

-- The cron job is inert while either configuration flag is false (the default).
select cron.schedule('fieldrush-push-dispatch','* * * * *','select fieldrush_private.dispatch_pending_push();');
notify pgrst,'reload schema';
