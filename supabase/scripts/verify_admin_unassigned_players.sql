-- Disposable full-schema regression, run by the isolated migration harness.
-- No policy activation, external provider calls or hosted database changes.
select set_config('request.jwt.claim.role', 'service_role', true);
create temporary table admin_placement_checks(label text);
create sequence pg_temp.admin_placement_person;
create function pg_temp.placement_expect(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Admin player placement: %', label; end if;
  insert into admin_placement_checks values(label);
end $$;
create function pg_temp.placement_reject(statement text, expected text) returns void language plpgsql as $$
declare rejected boolean := false;
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm) = 0 then raise; end if;
    rejected := true;
  end;
  perform pg_temp.placement_expect(rejected, 'Rejected: ' || expected);
end $$;
create function pg_temp.placement_player() returns uuid language plpgsql as $$
declare player uuid := gen_random_uuid(); n bigint := nextval('pg_temp.admin_placement_person');
  previous_sub text := current_setting('request.jwt.claim.sub', true);
begin
  insert into auth.users(id, phone, phone_confirmed_at) values(player, '1555921' || lpad(n::text, 4, '0'), now());
  perform set_config('request.jwt.claim.sub', player::text, true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name', 'Placement', 'last_name', 'Fixture',
    'username', 'placement_fixture_' || n, 'date_of_birth', '2000-01-01',
    'email', 'placement_fixture_' || n || '@example.test', 'skill_assessment', 'not_sure'), 'fieldrush-v1', 'fieldrush-v1');
  perform set_config('request.jwt.claim.sub', coalesce(previous_sub, ''), true);
  return player;
end $$;

do $$
declare
  actor uuid := pg_temp.placement_player(); login uuid := gen_random_uuid();
  game uuid; legacy_format text; capacity_to_use integer; kickoff timestamptz; player uuid;
  target_white uuid; target_black uuid; entries jsonb; response jsonb; request uuid;
  before_bookings jsonb; before_game jsonb; i integer; pass integer := 0;
  retained_white uuid[]; retained_black uuid[];
begin
  insert into public.referee_profiles(profile_id, display_name, phone, role, is_active)
    values(actor, 'Placement admin', '+15559210001', 'admin', true);
  insert into auth.users(id, email, email_confirmed_at, raw_app_meta_data)
    values(login, login::text || '@staff-fixture.example', now(), '{"fieldrush_account_type":"staff"}'::jsonb);
  update public.referee_profiles set auth_user_id = login, email = login::text || '@staff-fixture.example' where profile_id = actor;
  perform pg_temp.placement_expect(not (select enabled from fieldrush_rating_private.season_zero_activation), 'Season 0 starts disabled');
  foreach legacy_format in array array['FIELDRUSH_7V7', 'LEGACY_6V6'] loop
    pass := pass + 1;
    capacity_to_use := case legacy_format when 'LEGACY_6V6' then 12 else 14 end;
    retained_white := array[]::uuid[]; retained_black := array[]::uuid[];
    kickoff := ((date_trunc('week', now())::date + 11 + pass * 7) + time '20:30')
      at time zone case legacy_format when 'LEGACY_6V6' then 'Asia/Bahrain' else 'America/Phoenix' end;
    insert into public.open_queue_games(format_version, currency, timezone, capacity, goalkeeper_capacity,
      defender_capacity, midfielder_capacity, attacker_capacity, venue, starts_at, ends_at, price_fils,
      minimum_players, participation_rules_version)
      values(legacy_format, case legacy_format when 'LEGACY_6V6' then 'BHD' else 'USD' end,
        case legacy_format when 'LEGACY_6V6' then 'Asia/Bahrain' else 'America/Phoenix' end,
        capacity_to_use, 2, 4, case legacy_format when 'LEGACY_6V6' then 4 else 0 end,
        case legacy_format when 'LEGACY_6V6' then 2 else 8 end,
        'Disposable late-player placement ' || legacy_format, kickoff, kickoff + interval '1 hour', 0, 10, 's0-standard-v1')
      returning id into game;
    -- Six retained players plus two late, unassigned attackers: below both
    -- legacy full-roster sizes and below the Season 0 ten-player minimum.
    for i in 1..8 loop
      player := pg_temp.placement_player();
      if i = 7 then target_white := player; elsif i = 8 then target_black := player; end if;
      insert into public.open_queue_bookings(game_id, profile_id, role, status, amount_paid_fils, base_amount_fils, payment_method)
        values(game, player, case when i in (1, 4) then 'GK' when i in (7, 8) then 'ATT' else 'DEF' end,
          'CONFIRMED', 0, 0, 'FREE');
      if i <= 3 then retained_white := array_append(retained_white, player);
      elsif i <= 6 then retained_black := array_append(retained_black, player); end if;
    end loop;
    update public.open_queue_bookings set team = case when profile_id = any(retained_white) then 'WHITE' else 'BLACK' end,
      rating_at_team_assignment = 1000 where game_id = game and profile_id = any(retained_white || retained_black) and status = 'CONFIRMED';
    update public.open_queue_games set teams_assigned_at = clock_timestamp() where id = game;
    -- Establish the committed game's prior notification snapshot, then exercise
    -- the same observer invoked by deferred booking/game triggers after save.
    perform fieldrush_private.observe_player_game_notice(game);
    select jsonb_agg(to_jsonb(b) order by id) into before_bookings from public.open_queue_bookings b
      where game_id = game and profile_id not in (target_white, target_black);
    select to_jsonb(g) - array['updated_at', 'white_average_sr', 'black_average_sr', 'match_average_sr', 'team_sr_spread']
      into before_game from public.open_queue_games g where id = game;
    entries := jsonb_build_array(jsonb_build_object('profile_id', target_white, 'to_team', 'WHITE'),
      jsonb_build_object('profile_id', target_black, 'to_team', 'BLACK'));
    request := gen_random_uuid();
    response := public.admin_assign_unassigned_open_queue_players(actor, game, request, entries);
    perform fieldrush_private.observe_player_game_notice(game);
    perform pg_temp.placement_expect(response->>'action' = 'ASSIGN_UNASSIGNED' and (response->>'assigned_count')::integer = 2,
      'Places late players in ' || legacy_format);
    perform pg_temp.placement_expect((select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b
      where game_id = game and profile_id not in (target_white, target_black)) = before_bookings,
      'All retained booking fields unchanged in ' || legacy_format);
    perform pg_temp.placement_expect((select to_jsonb(g) - array['updated_at', 'white_average_sr', 'black_average_sr', 'match_average_sr', 'team_sr_spread']
      from public.open_queue_games g where id = game) = before_game, 'Format, rating policy and kickoff rules unchanged in ' || legacy_format);
    perform pg_temp.placement_expect((select team = 'WHITE' and not played and rating_at_match_start is null
      from public.open_queue_bookings where game_id = game and profile_id = target_white and status = 'CONFIRMED'), 'No invented participation in ' || legacy_format);
    perform pg_temp.placement_expect(public.admin_assign_unassigned_open_queue_players(actor, game, request, entries) = response,
      'Exact retry idempotency in ' || legacy_format);
    perform pg_temp.placement_reject(format('select public.admin_assign_unassigned_open_queue_players(%L,%L,%L,%L::jsonb)',
      actor, game, gen_random_uuid(), entries), 'already been assigned');
    perform pg_temp.placement_expect((select count(*) = 1 from public.admin_audit_events
      where entity_id = game and action = 'OPEN_QUEUE_UNASSIGNED_PLAYERS_PLACED'), 'One audit entry in ' || legacy_format);
    perform pg_temp.placement_expect((select count(*) = 2 from public.notifications
      where related_entity_id = game and type = 'SOLO_TEAM_READY' and recipient_profile_id in (target_white, target_black)),
      'Team notices only for the two newly placed players in ' || legacy_format);
    -- Immutable actual kickoff remains authoritative even after reset clock /
    -- event rows, while the visible game status still happens to say OPEN.
    update public.open_queue_bookings set team = null where game_id = game and profile_id = target_white;
    insert into public.open_queue_events(game_id, event_type) values(game, 'MATCH_STARTED');
    delete from public.open_queue_events where game_id = game and event_type = 'MATCH_STARTED';
    perform pg_temp.placement_expect((select actual_started_at is not null from public.open_queue_games where id = game)
      and not exists(select 1 from public.open_queue_clock_states where game_id = game)
      and not exists(select 1 from public.open_queue_events where game_id = game and event_type = 'MATCH_STARTED'),
      'Only immutable kickoff evidence remains in ' || legacy_format);
    perform pg_temp.placement_reject(format('select public.admin_assign_unassigned_open_queue_players(%L,%L,%L,%L::jsonb)',
      actor, game, gen_random_uuid(), jsonb_build_array(entries->0)), 'before actual kickoff');
  end loop;
  perform pg_temp.placement_expect(not (select enabled from fieldrush_rating_private.season_zero_activation), 'Season 0 remains disabled');
end $$;
set constraints all immediate;
select count(*) as verified_admin_placement_checks from admin_placement_checks;
