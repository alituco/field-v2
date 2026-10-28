-- Run only on the freshly replayed local schema, inside BEGIN/ROLLBACK.
-- This verifier never calls net.http_post or an external push provider.
do $$
declare test_secret text; secret_count integer;
begin
  if (select enabled from fieldrush_private.push_configuration where singleton)
    or (select enabled from fieldrush_private.push_dispatch_configuration where singleton) then
    raise exception 'A fresh schema must leave both push delivery and dispatch disabled.';
  end if;
  if fieldrush_private.dispatch_pending_push() is not null then
    raise exception 'Disabled push dispatch must not create a network request.';
  end if;
  if not exists(select 1 from cron.job where jobname='fieldrush-push-dispatch'
    and schedule='* * * * *' and command='select fieldrush_private.dispatch_pending_push();') then
    raise exception 'The protected dispatcher schedule is missing.';
  end if;
  foreach test_secret in array array['anon','authenticated'] loop
    if has_function_privilege(test_secret,'public.configure_push_delivery(text,boolean)','EXECUTE')
      or has_function_privilege(test_secret,'public.configure_push_dispatch(text,text,boolean)','EXECUTE')
      or has_function_privilege(test_secret,'public.get_push_delivery_payload(uuid,uuid)','EXECUTE')
      or has_function_privilege(test_secret,'fieldrush_private.dispatch_pending_push()','EXECUTE')
      or has_table_privilege(test_secret,'fieldrush_private.push_devices','SELECT')
      or has_table_privilege(test_secret,'fieldrush_private.push_deliveries','SELECT') then
      raise exception 'A client role can read or dispatch private push state.';
    end if;
  end loop;
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.configure_push_dispatch(null,null,false);
    raise exception 'An authenticated player configured push dispatch.';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.role','service_role',true);
  test_secret:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  select count(*) into secret_count from vault.secrets;
  begin
    perform public.configure_push_dispatch('https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch',test_secret,true);
    raise exception 'Dispatch was enabled without a configured Firebase capability.';
  exception when invalid_parameter_value then null; end;
  if (select count(*) from vault.secrets)<>secret_count then
    raise exception 'Rejected push setup persisted a Vault secret.';
  end if;
  perform public.configure_push_delivery('fieldrush-local-verification',true);
  perform public.configure_push_dispatch('https://nfdkdhdevpstfspazbfn.supabase.co/functions/v1/fieldrush-push-dispatch',test_secret,true);
  if not exists(select 1 from vault.decrypted_secrets where name='fieldrush_push_worker_secret' and decrypted_secret=test_secret) then
    raise exception 'The protected worker authorization was not stored in Vault.';
  end if;
  perform public.configure_push_dispatch(null,null,false);
  if fieldrush_private.dispatch_pending_push() is not null then
    raise exception 'Disabling dispatch did not stop scheduled sends.';
  end if;
  raise notice 'Push defaults, client isolation, guarded configuration, Vault and disabled dispatch verified without provider calls.';
end;
$$;
