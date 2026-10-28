-- Party context has always been VOLATILE: resolving its cancellation window
-- locks the game and lazily binds reliability terms. The lifetime-SR privacy
-- wrapper accidentally declared it STABLE, so PostgREST ran even POST calls in
-- a read-only transaction and PostgreSQL rejected SELECT ... FOR UPDATE.
-- Change only the wrapper's transaction contract; retain its privacy masking,
-- authorization, private implementation, and locking behavior unchanged.
alter function public.get_open_queue_party_context(uuid) volatile;

do $migration$
begin
  if (select provolatile from pg_proc
      where oid='public.get_open_queue_party_context_before_sr_privacy(uuid)'::regprocedure)
      is distinct from 'v'::"char" then
    raise exception 'Party context implementation must remain VOLATILE.';
  end if;
  if has_function_privilege('anon','public.get_open_queue_party_context(uuid)','execute')
    or not has_function_privilege('authenticated','public.get_open_queue_party_context(uuid)','execute')
    or not has_function_privilege('service_role','public.get_open_queue_party_context(uuid)','execute') then
    raise exception 'Party context wrapper permissions changed.';
  end if;
  if has_function_privilege('anon','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute')
    or has_function_privilege('authenticated','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute')
    or has_function_privilege('service_role','public.get_open_queue_party_context_before_sr_privacy(uuid)','execute') then
    raise exception 'Unmasked party context implementation must remain private.';
  end if;
end;
$migration$;

notify pgrst,'reload schema';
