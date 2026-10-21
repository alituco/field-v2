begin;

select set_config('request.jwt.claim.role', 'service_role', true);

do $verify$
declare
  fixture_to_test public.fixtures%rowtype;
  actor_referee_id uuid;
  home_players uuid[];
  away_players uuid[];
  lineup_players uuid[];
  player_id_to_check uuid;
  late_substitute_id uuid;
  attendance_to_verify public.match_attendance_records%rowtype;
  terms_to_verify public.match_reliability_terms%rowtype;
  finished_fixture public.fixtures%rowtype;
begin
  select fixture.* into fixture_to_test
  from public.fixtures fixture
  where fixture.status = 'SCHEDULED'
    and fixture.away_clan_id is not null
    and (
      select count(*)
      from public.clan_members member
      where member.clan_id = fixture.home_clan_id
        and member.left_at is null
    ) >= 7
    and (
      select count(*)
      from public.clan_members member
      where member.clan_id = fixture.away_clan_id
        and member.left_at is null
    ) >= 6
  order by fixture.match_date, fixture.time_slot, fixture.id
  limit 1
  for update;

  if fixture_to_test.id is null then
    raise exception
      'Clan attendance flexibility verification needs one scheduled fixture with 7 home and 6 away members.';
  end if;

  -- This representative historical clan fixture is about to become active.
  -- Isolate its players from the independent synthetic solo seed first; the
  -- canonical one-game guard stays enabled and every change is rolled back.
  update public.open_queue_games game
  set status='CANCELLED',cancellation_code='ADMIN_DECISION',
    cancellation_reason='Isolate clan attendance rollback verification.',
    cancelled_at=clock_timestamp(),cancelled_by=fixture_to_test.created_by,
    cancellation_context=jsonb_build_object('source','CLAN_ATTENDANCE_ROLLBACK_VERIFICATION')
  where public.player_game_blocks_registration(game.status,game.ends_at,game.operational_state)
    and exists (
      select 1 from public.open_queue_bookings booking
      join public.clan_members member on member.profile_id=booking.profile_id and member.left_at is null
      where booking.game_id=game.id and booking.status='CONFIRMED'
        and member.clan_id in (fixture_to_test.home_clan_id,fixture_to_test.away_clan_id)
    );

  -- Keep the verifier stable after the checked-in seed dates have passed.
  -- The reschedule is rolled back with the rest of this script.
  update public.fixtures fixture
  set match_date = current_date + (
    case fixture.day
      when 'TUESDAY' then 2
      else 5
    end
    - extract(dow from current_date)::integer
    + 7
  ) % 7 + 7
  where fixture.id = fixture_to_test.id
  returning fixture.* into fixture_to_test;

  select referee.profile_id into actor_referee_id
  from public.referee_profiles referee
  where referee.is_active
    and fieldrush_private.staff_identity_is_active(referee.profile_id)
  order by (referee.role = 'admin') desc, referee.created_at, referee.profile_id
  limit 1;

  if actor_referee_id is null then
    raise exception
      'Clan attendance flexibility verification needs an active referee.';
  end if;

  insert into public.fixture_referee_assignments (
    fixture_id,
    referee_id,
    assigned_by
  ) values (
    fixture_to_test.id,
    actor_referee_id,
    actor_referee_id
  ) on conflict (fixture_id) do update
  set
    referee_id = excluded.referee_id,
    assigned_by = excluded.assigned_by;

  select (array_agg(
    member.profile_id order by member.created_at, member.profile_id
  ))[1:7]
  into home_players
  from public.clan_members member
  where member.clan_id = fixture_to_test.home_clan_id
    and member.left_at is null;

  select (array_agg(
    member.profile_id order by member.created_at, member.profile_id
  ))[1:6]
  into away_players
  from public.clan_members member
  where member.clan_id = fixture_to_test.away_clan_id
    and member.left_at is null;

  perform public.ensure_match_attendance_records('CLAN', fixture_to_test.id);
  perform public.initialize_fixture_reliability_roster(fixture_to_test.id);

  foreach player_id_to_check in array home_players[1:6]
  loop
    perform public.referee_check_in_player_with_timing(
      actor_referee_id,
      'CLAN',
      fixture_to_test.id,
      player_id_to_check,
      'EARLY'
    );
  end loop;

  foreach player_id_to_check in array away_players
  loop
    perform public.referee_check_in_player_with_timing(
      actor_referee_id,
      'CLAN',
      fixture_to_test.id,
      player_id_to_check,
      'EARLY'
    );
  end loop;

  late_substitute_id := home_players[7];
  perform public.referee_check_in_player_with_timing(
    actor_referee_id,
    'CLAN',
    fixture_to_test.id,
    late_substitute_id,
    'LATE'
  );

  select * into attendance_to_verify
  from public.match_attendance_records attendance
  where attendance.fixture_id = fixture_to_test.id
    and attendance.profile_id = late_substitute_id;

  select * into terms_to_verify
  from public.match_reliability_terms terms
  where terms.match_kind = 'CLAN'
    and terms.fixture_id = fixture_to_test.id;

  if attendance_to_verify.check_in_timing <> 'LATE'
    or attendance_to_verify.checked_in_at > terms_to_verify.check_in_deadline_at
    or coalesce(
      (
        attendance_to_verify.consequence_snapshot #>>
          '{referee_selected_check_in,late_penalty_waived}'
      )::boolean,
      false
    ) is not true
    or attendance_to_verify.consequence_snapshot #>>
      '{referee_selected_check_in,waiver_reason}' <>
        'FULL_PLAYING_SIDE_ALREADY_CHECKED_IN'
  then
    raise exception
      'A late clan substitute was not audited and protected after six teammates checked in.';
  end if;

  lineup_players := home_players[1:6] || away_players;
  perform public.referee_start_fixture_atomic(
    fixture_to_test.id,
    lineup_players,
    3600
  );
  finished_fixture := public.referee_finish_fixture_atomic(
    fixture_to_test.id
  );

  if finished_fixture.status <> 'FINAL' then
    raise exception
      'The referee could not finalize a clan fixture before attendance cutoff.';
  end if;
end;
$verify$;

rollback;
