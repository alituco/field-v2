do $field_hosted_schema$
declare
  missing_tables text[];
  missing_functions text[];
  ranks_function regprocedure;
  protected_table text;
  rpc_signature text;
  checked_rpc regprocedure;
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
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'match_attendance_records'
      and column_name = 'is_current' and is_nullable = 'NO'
  ) or to_regclass('public.current_match_attendance_records') is null
    or to_regclass('public.match_attendance_solo_booking_idx') is null
    or to_regclass('public.match_attendance_solo_current_profile_idx') is null
  then
    raise exception 'Hosted attendance is missing safe same-game rebooking support.';
  end if;
  if has_table_privilege('anon', 'public.current_match_attendance_records', 'SELECT')
    or has_table_privilege('authenticated', 'public.current_match_attendance_records', 'SELECT')
    or not has_table_privilege('service_role', 'public.current_match_attendance_records', 'SELECT')
  then
    raise exception 'Hosted current attendance must remain server-only.';
  end if;

  -- Confirm the current mobile/admin contract before spending time on the
  -- hosted journey. Draft prizes and audit data must remain server-only.
  foreach protected_table in array array[
    'fieldrush_cities', 'fieldrush_player_rating_tracks', 'fieldrush_seasons',
    'fieldrush_season_rewards', 'fieldrush_season_audit_events'
  ] loop
    if to_regclass(format('public.%I', protected_table)) is null then
      raise exception 'Hosted schema is missing %.', protected_table;
    end if;
    if not (select relrowsecurity from pg_class
      where oid = to_regclass(format('public.%I', protected_table)))
      or has_any_column_privilege('anon', format('public.%I', protected_table), 'SELECT,INSERT,UPDATE')
      or has_any_column_privilege('authenticated', format('public.%I', protected_table), 'SELECT,INSERT,UPDATE')
      or has_table_privilege('anon', format('public.%I', protected_table), 'DELETE')
      or has_table_privilege('authenticated', format('public.%I', protected_table), 'DELETE')
      or not has_table_privilege('service_role', format('public.%I', protected_table), 'SELECT')
    then
      raise exception 'Hosted % must use RLS and server-only direct access.', protected_table;
    end if;
  end loop;

  foreach rpc_signature in array array[
    'public.list_fieldrush_cities()',
    'public.set_my_fieldrush_city(text)',
    'public.list_open_queue_games_for_city(text)',
    'public.get_fieldrush_player_ratings(uuid,date,date)',
    'public.list_fieldrush_rating_page(text,text,text,date,date,integer,integer)',
    'public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)',
    'public.list_fieldrush_seasons()',
    'public.get_fieldrush_season_rewards(text,text,text)',
    'public.search_fieldrush_players(text)',
    'public.list_fieldrush_clans()',
    'public.list_fieldrush_clan_members(uuid)'
  ] loop
    checked_rpc := to_regprocedure(rpc_signature);
    if checked_rpc is null then
      raise exception 'Hosted schema is missing %.', rpc_signature;
    end if;
    if not has_function_privilege('authenticated', checked_rpc, 'EXECUTE')
      or has_function_privilege('anon', checked_rpc, 'EXECUTE')
      or not (select prosecdef from pg_proc where oid = checked_rpc)
    then
      raise exception 'Hosted % must be a signed-in security-definer read/write boundary.', rpc_signature;
    end if;
  end loop;

  foreach rpc_signature in array array[
    'public.admin_save_fieldrush_city(uuid,text,jsonb)',
    'public.admin_list_fieldrush_seasons(uuid)',
    'public.admin_save_fieldrush_season(uuid,text,jsonb,integer)',
    'public.admin_save_fieldrush_season_reward(uuid,text,text,text,jsonb,text,text,integer)'
  ] loop
    checked_rpc := to_regprocedure(rpc_signature);
    if checked_rpc is null then
      raise exception 'Hosted schema is missing %.', rpc_signature;
    end if;
    if has_function_privilege('anon', checked_rpc, 'EXECUTE')
      or has_function_privilege('authenticated', checked_rpc, 'EXECUTE')
      or not has_function_privilege('service_role', checked_rpc, 'EXECUTE')
    then
      raise exception 'Hosted % must be executable only by the server.', rpc_signature;
    end if;
  end loop;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'fieldrush_private' and table_name = 'accounts'
      and column_name = 'preferred_city_id' and is_nullable = 'NO'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'open_queue_bookings'
      and column_name = 'rating_track' and is_generated = 'ALWAYS'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'open_queue_games'
      and column_name = 'market_city_id'
  ) then
    raise exception 'Hosted city preference, game market or booked rating track is missing.';
  end if;

  if not exists (select 1 from public.fieldrush_cities where active)
    or not exists (select 1 from public.fieldrush_seasons) then
    raise exception 'Hosted city and season catalogs are not configured.';
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
