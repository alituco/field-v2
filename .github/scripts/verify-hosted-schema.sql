do $field_hosted_schema$
declare
  missing_tables text[];
  missing_functions text[];
  ranks_function regprocedure;
begin
  select array_agg(table_name order by table_name)
  into missing_tables
  from unnest(array[
    'profiles',
    'clans',
    'fixtures',
    'open_queue_games',
    'open_queue_bookings',
    'season_zero_waitlist',
    'reliability_policy_versions',
    'payment_intents',
    'payment_refunds',
    'payment_webhook_events',
    'external_payment_refunds',
    'game_payment_settings'
  ]) as required(table_name)
  where to_regclass(format('public.%I', table_name)) is null;

  if missing_tables is not null then
    raise exception
      'Hosted schema is missing required tables: %',
      array_to_string(missing_tables, ', ');
  end if;

  select array_agg(function_name order by function_name)
  into missing_functions
  from unnest(array[
    'book_open_queue_game',
    'cancel_open_queue_booking',
    'preview_open_queue_cancellation',
    'record_stripe_payment_capture',
    'finalize_payment_intent',
    'configure_stripe_reconciliation',
    'get_game_payment_settings',
    'admin_set_game_payment_settings',
    'record_external_stripe_refund'
  ]) as required(function_name)
  where not exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = function_name
  );

  if missing_functions is not null then
    raise exception
      'Hosted schema is missing required functions: %',
      array_to_string(missing_functions, ', ');
  end if;

  -- Mobile Ranks requires this exact RPC signature, not just a function with
  -- the same name. Check it before declaring a hosted deployment successful.
  ranks_function := to_regprocedure(
    'public.list_fieldrush_player_rating_page(text,date,date,integer,integer)'
  );
  if ranks_function is null then
    raise exception 'Hosted schema is missing the Fieldrush Ranks RPC.';
  end if;
  if not has_function_privilege('authenticated', ranks_function, 'execute')
    or has_function_privilege('anon', ranks_function, 'execute') then
    raise exception 'Fieldrush Ranks must be executable by signed-in users only.';
  end if;
  if (select proargnames from pg_proc where oid = ranks_function) is distinct from
    array['region_to_use', 'season_starts_on', 'season_ends_on',
          'offset_to_use', 'page_size_to_use']::text[] then
    raise exception 'Fieldrush Ranks RPC argument names do not match the mobile contract.';
  end if;

  if not exists (
    select 1
    from public.reliability_policy_versions
    where state = 'PUBLISHED'
  ) then
    raise exception 'Hosted schema has no published reliability policy.';
  end if;
end;
$field_hosted_schema$;
