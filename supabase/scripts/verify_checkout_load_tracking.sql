-- Rollback-only verification; the runner supplies BEGIN and ROLLBACK.
create function pg_temp.assert_checkout_load(ok boolean, message text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Checkout load tracking: %', message; end if;
end; $$;

select pg_temp.assert_checkout_load(
  not has_function_privilege('anon', 'public.record_checkout_load_event(uuid,text,text,text,integer,text)', 'execute')
  and has_function_privilege('authenticated', 'public.record_checkout_load_event(uuid,text,text,text,integer,text)', 'execute'),
  'only signed-in clients can call the writer');
select pg_temp.assert_checkout_load(not exists (
  select 1 from (values ('anon'), ('authenticated')) roles(role_name)
  cross join (values ('checkout_load_attempts'), ('checkout_load_hourly_quota'), ('checkout_load_health_daily')) sources(source_name)
  where has_table_privilege(roles.role_name, 'fieldrush_private.' || sources.source_name, 'select,insert,update,delete')
), 'clients cannot read or modify the backing tables or operator view directly');

set local role authenticated;
select set_config('request.jwt.claim.sub','10101010-0000-4000-8000-000000000001',true);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000001','started','ios','1.0.1+42',0);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000001','failed','ios','1.0.1+42',250,'selector_failed');
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000001','started','ios','1.0.1+42',0);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000001','ready','ios','1.0.1+42',300);
-- A client that loses its initial request can still report its terminal event.
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000002','timed_out','android','1.0.1',20000,'configuration_timeout');
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000002','started','android','1.0.1',0);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000003','started','other','unknown',0);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000004','started','ios','1.0.2',0);

do $$
begin
  begin
    perform public.record_checkout_load_event(gen_random_uuid(),'failed','ios','1.0.1',0,'an arbitrary error');
    raise exception 'accepted arbitrary failure message';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.record_checkout_load_event(gen_random_uuid(),'failed','ios','1.0.1',0);
    raise exception 'accepted missing failure reason';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.record_checkout_load_event(gen_random_uuid(),'ready','ios','1.0.1',0,'configuration_failed');
    raise exception 'accepted failure reason on success';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.record_checkout_load_event(gen_random_uuid(),'started','ios','arbitrary version text',0);
    raise exception 'accepted free-form version text';
  exception when invalid_parameter_value then null; end;
end; $$;

select set_config('request.jwt.claim.sub','10101010-0000-4000-8000-000000000002',true);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000001','closed','android','1.0.3',100);
reset role;

-- Use only the synthetic actors' hashes; no pre-existing rows are modified.
update fieldrush_private.checkout_load_attempts set first_received_at = now() - interval '6 minutes'
  where attempt_key = sha256(uuid_send('10101010-0000-4000-8000-000000000001'::uuid)
                            || uuid_send('00000000-0000-4000-8000-000000000004'::uuid));
select pg_temp.assert_checkout_load(
  (select outcome = 'failed' and reason = 'selector_failed' and elapsed_ms = 250
   from fieldrush_private.checkout_load_attempts
   where attempt_key = sha256(uuid_send('10101010-0000-4000-8000-000000000001'::uuid)
                           || uuid_send('00000000-0000-4000-8000-000000000001'::uuid))),
  'first terminal outcome and elapsed time survive duplicates and out-of-order requests');
select pg_temp.assert_checkout_load((select count(*) = 5 from fieldrush_private.checkout_load_health_daily
  where (load_status, platform, app_version) in (
    ('failed','ios','1.0.1+42'), ('timed_out','android','1.0.1'), ('closed','android','1.0.3'),
    ('loading','other','unknown'), ('unconfirmed','ios','1.0.2')
  ) and attempts = 1), 'confirmed outcomes, even without start, are distinct from loading and stale');

set local role authenticated;
-- 1 prior new attempt for this actor + 119 allowed + 1 over quota.
do $$ begin
  for i in 1..120 loop
    perform public.record_checkout_load_event(gen_random_uuid(),'started','ios','1.0.4+98',0);
  end loop;
end $$;
select set_config('request.jwt.claim.sub','10101010-0000-4000-8000-000000000001',true);
select public.record_checkout_load_event('00000000-0000-4000-8000-000000000004','ready','ios','1.0.2',300000);
reset role;

select pg_temp.assert_checkout_load(
  (select attempts = 119 from fieldrush_private.checkout_load_health_daily
   where load_status = 'loading' and app_version = '1.0.4+98'),
  'bounded new rows per actor each hour');
select pg_temp.assert_checkout_load(
  (select attempts = 1 from fieldrush_private.checkout_load_health_daily
   where load_status = 'ready' and app_version = '1.0.2' and median_elapsed_ms = 300000),
  'a late terminal event resolves an unconfirmed start');
select pg_temp.assert_checkout_load(
  (select schedule = '17 * * * *' from cron.job where jobname='checkout-load-retention' and active),
  'retention is scheduled');
