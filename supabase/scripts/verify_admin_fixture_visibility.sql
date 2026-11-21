-- Run inside test_season_zero_migration_chain.mjs's disposable transaction.
do $$
declare
  actor uuid := gen_random_uuid();
  login uuid := gen_random_uuid();
  player uuid := gen_random_uuid();
  past_game uuid := gen_random_uuid();
  future_game uuid := gen_random_uuid();
  live_game uuid := gen_random_uuid();
  kickoff timestamptz := date_trunc('minute', now()) - interval '3 days';
  original_game jsonb;
  original_booking jsonb;
  hidden jsonb;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into auth.users(id, email, email_confirmed_at, raw_app_meta_data) values
    (login, 'fixtures-admin@example.test', now(), '{"fieldrush_account_type":"staff"}'::jsonb);
  insert into public.referee_profiles(profile_id, auth_user_id, email, display_name, role, is_active)
    values (actor, login, 'fixtures-admin@example.test', 'Fixtures admin', 'admin', true);
  insert into auth.users(id, phone, phone_confirmed_at) values (player, '15559230001', now());
  perform set_config('request.jwt.claim.sub', player::text, true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object(
    'first_name','Fixture','last_name','Player','username','fixture_visibility','date_of_birth','2000-01-01',
    'email','fixture-visibility@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');

  insert into public.open_queue_games(id, status, venue, starts_at, ends_at, timezone, price_fils)
    values (past_game, 'OPEN', 'Past fixture', kickoff + interval '4 days', kickoff + interval '4 days 1 hour', 'America/Phoenix', 0),
           (live_game, 'LIVE', 'Late live fixture', kickoff - interval '1 day', kickoff - interval '23 hours', 'America/Phoenix', 0),
           (future_game, 'OPEN', 'Future fixture', kickoff + interval '5 days', kickoff + interval '5 days 1 hour', 'America/Phoenix', 0);
  insert into public.open_queue_bookings(game_id, profile_id, role, status, amount_paid_fils, base_amount_fils, payment_method)
    values (past_game, player, 'ATT', 'CONFIRMED', 0, 0, 'FREE');
  -- Simulate time passing after checkout in this disposable transaction.
  set constraints all immediate;
  alter table public.open_queue_games disable trigger enforce_open_queue_permanent_schedule;
  update public.open_queue_games set starts_at = kickoff, ends_at = kickoff + interval '1 hour' where id = past_game;
  alter table public.open_queue_games enable trigger enforce_open_queue_permanent_schedule;
  select to_jsonb(g) into strict original_game from public.open_queue_games g where id = past_game;
  select to_jsonb(b) into strict original_booking from public.open_queue_bookings b where game_id = past_game;

  assert exists (select from public.list_open_queue_fixture_games() where id = past_game), 'Existing game must start visible';
  begin
    perform public.admin_set_solo_fixture_visibility(player, past_game, true);
    raise exception 'Player could act as an administrator';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_set_solo_fixture_visibility(actor, future_game, true);
    raise exception 'Hid a future game';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.admin_set_solo_fixture_visibility(actor, live_game, true);
    raise exception 'Hid a live game';
  exception when invalid_parameter_value then null; end;

  hidden := public.admin_set_solo_fixture_visibility(actor, past_game, true);
  assert hidden->>'fixtures_hidden_at' is not null;
  assert public.admin_set_solo_fixture_visibility(actor, past_game, true) = hidden;
  assert (select count(*) = 1 from public.admin_audit_events where entity_id = past_game and action = 'SOLO_FIXTURE_HIDDEN');

  set local role authenticated;
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  assert not exists (select from public.list_open_queue_fixture_games() where id = past_game), 'Hidden game leaked from Fixtures';
  assert exists (select from public.list_open_queue_fixture_games() where id = future_game), 'Neighbor game disappeared';
  assert exists (select from public.open_queue_games g join public.solo_fixture_visibility v on v.game_id = g.id
    where g.id = past_game and v.hidden_at = (hidden->>'fixtures_hidden_at')::timestamptz), 'Player cannot read visibility metadata';
  assert exists (select from public.open_queue_bookings where game_id = past_game and profile_id = auth.uid()),
    'Player lost access to their booking';
  assert not has_function_privilege(current_user, 'public.admin_set_solo_fixture_visibility(uuid,uuid,boolean)', 'EXECUTE');
  assert not has_table_privilege(current_user, 'public.solo_fixture_visibility', 'INSERT, UPDATE, DELETE');
  reset role;
  perform set_config('request.jwt.claim.role', 'service_role', true);

  assert (select to_jsonb(g) = original_game from public.open_queue_games g where id = past_game);
  assert (select to_jsonb(b) = original_booking from public.open_queue_bookings b where game_id = past_game);
  perform public.admin_set_solo_fixture_visibility(actor, past_game, false);
  perform public.admin_set_solo_fixture_visibility(actor, past_game, false);
  assert (select count(*) = 1 from public.admin_audit_events where entity_id = past_game and action = 'SOLO_FIXTURE_RESTORED');
  assert not exists (select from public.solo_fixture_visibility where game_id = past_game);
  assert exists (select from public.list_open_queue_fixture_games() where id = past_game), 'Restored game absent from Fixtures';
end $$;
