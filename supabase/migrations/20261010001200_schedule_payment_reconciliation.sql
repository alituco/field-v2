-- The worker keeps abandoned checkouts and original-method refunds moving
-- without relying on a mobile app, GitHub branch or a repeated webhook.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

create function fieldrush_private.run_stripe_reconciliation()
returns bigint language plpgsql security definer
set search_path=pg_catalog,fieldrush_private as $$
declare endpoint text; secret text; request_id bigint;
begin
  select decrypted_secret into endpoint from vault.decrypted_secrets where name='fieldrush_stripe_reconcile_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name='fieldrush_stripe_reconcile_secret';
  if endpoint is null or secret is null then raise exception 'Payment reconciliation is not configured.'; end if;
  select net.http_post(url:=endpoint,body:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),
    timeout_milliseconds:=120000) into request_id;
  return request_id;
end;
$$;
revoke all on function fieldrush_private.run_stripe_reconciliation() from public,anon,authenticated,service_role;

create function public.configure_stripe_reconciliation(endpoint_url text,reconcile_secret text)
returns bigint language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private as $$
declare secret_id uuid; job_id bigint;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the payment service can configure reconciliation.' using errcode='42501'; end if;
  if endpoint_url !~ '^https://[a-z0-9]{20}\.supabase\.co/functions/v1/stripe-payment-reconcile$'
    or char_length(coalesce(reconcile_secret,''))<32 then
    raise exception 'A hosted reconciliation endpoint and a strong worker secret are required.';
  end if;
  select id into secret_id from vault.secrets where name='fieldrush_stripe_reconcile_url';
  if secret_id is null then perform vault.create_secret(endpoint_url,'fieldrush_stripe_reconcile_url','Payment reconciliation endpoint');
  else perform vault.update_secret(secret_id,endpoint_url); end if;
  select id into secret_id from vault.secrets where name='fieldrush_stripe_reconcile_secret';
  if secret_id is null then perform vault.create_secret(reconcile_secret,'fieldrush_stripe_reconcile_secret','Payment reconciliation authorization');
  else perform vault.update_secret(secret_id,reconcile_secret); end if;
  select cron.schedule('fieldrush-stripe-reconciliation','*/5 * * * *','select fieldrush_private.run_stripe_reconciliation();') into job_id;
  return job_id;
end;
$$;
revoke all on function public.configure_stripe_reconciliation(text,text) from public,anon,authenticated;
grant execute on function public.configure_stripe_reconciliation(text,text) to service_role;
