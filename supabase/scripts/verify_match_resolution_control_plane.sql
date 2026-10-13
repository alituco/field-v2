\set ON_ERROR_STOP on

-- Run after the local development seed. Every mutation is rolled back.
begin;

create or replace function pg_temp.verification_player_has_free_game_slot(player_id uuid)
returns boolean language plpgsql as $availability$
begin
  perform public.assert_player_has_one_game(player_id,'SOLO','00000000-0000-0000-0000-000000000000',true);
  return true;
exception when raise_exception then return false;
end;
$availability$;

do $verify$
declare
  admin_id uuid;
  fixture_to_test record;
  review_case public.match_resolution_cases%rowtype;
  member_ids uuid[];
  home_member_id uuid;
  away_member_id uuid;
  initial_home_rating integer;
  initial_away_rating integer;
  initial_home_wins integer;
  initial_away_wins integer;
  initial_home_losses integer;
  initial_away_losses integer;
  preview_result jsonb;
  legacy_preview_result jsonb;
  legacy_no_show_preview jsonb;
  first_result jsonb;
  correction_result jsonb;
  played_correction_result jsonb;
  dispute_result jsonb;
  participant_result jsonb;
  detected_count integer;
  legacy_case_id uuid;
  first_revision_id uuid;
  second_revision_id uuid;
  expected_old_incidents integer;
  unresolved_old_incidents integer;
  second_incidents integer;
  corrected_home_score integer;
  corrected_away_score integer;
  solo_player_ids uuid[];
  solo_game_id uuid;
  solo_game_starts_at timestamptz;
  solo_past_starts_at timestamptz;
  solo_case public.match_resolution_cases%rowtype;
  solo_booking_ids uuid[];
  solo_cancelled_booking_id uuid;
  solo_first_result jsonb;
  solo_correction_result jsonb;
  solo_repeat_result jsonb;
  solo_refund_before integer;
  solo_wallet_credits_before integer;
  solo_wallet_credit_fils_before integer;
  solo_participant_result jsonb;
  function_definition text;
  expected_clan_rating_events integer;
  expected_solo_rating_events integer;
  clan_track_ratings_before jsonb;
  clan_legacy_ratings_before jsonb;
  solo_track_ratings_before jsonb;
  solo_legacy_ratings_before jsonb;
begin
  if to_regclass('public.match_resolution_cases') is null
    or to_regclass('public.match_resolution_revisions') is null
    or to_regclass('public.match_resolution_refunds') is null
    or to_regclass('public.match_resolution_clan_sr_adjustments') is null
    or to_regclass('public.match_resolution_incident_links') is null
  then
    raise exception 'The match-resolution control-plane ledgers are missing.';
  end if;
  if to_regprocedure(
    'public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'
  ) is null
    or to_regprocedure(
      'public.admin_preview_match_case_resolution(uuid,text,uuid,integer,text,text,jsonb)'
    ) is null
    or to_regprocedure(
      'public.get_match_resolution_case(text,uuid)'
    ) is null
    or to_regprocedure(
      'public.submit_match_resolution_dispute(uuid,text)'
    ) is null
  then
    raise exception 'A required match-resolution RPC is missing.';
  end if;
  select pg_get_functiondef(
    'public.finalize_due_match_attendance()'::regprocedure
  ) into function_definition;
  if position('select 0' in lower(function_definition)) = 0 then
    raise exception 'The solo deadline worker can still infer attendance.';
  end if;
  select pg_get_functiondef(
    'public.finalize_due_clan_reliability_attendance()'::regprocedure
  ) into function_definition;
  if position('select 0' in lower(function_definition)) = 0 then
    raise exception 'The clan deadline worker can still infer attendance.';
  end if;
  select pg_get_functiondef(
    'public.record_match_resolution_incident(uuid,uuid,text,uuid,uuid,uuid,text,uuid,text,integer,uuid,jsonb,uuid,text)'::regprocedure
  ) into function_definition;
  if position('SUSPENSION_BOOKING_RELEASE' in function_definition) = 0
    or position('RELIABILITY_SANCTION' in function_definition) = 0
  then
    raise exception
      'Admin-applied sanctions do not release/refund future bookings or notify the player.';
  end if;
  if not exists (
    select 1
    from information_schema.columns column_info
    where column_info.table_schema = 'public'
      and column_info.table_name = 'fixtures'
      and column_info.column_name = 'operational_reason_code'
  ) or not exists (
    select 1
    from information_schema.columns column_info
    where column_info.table_schema = 'public'
      and column_info.table_name = 'open_queue_games'
      and column_info.column_name = 'operational_reason_code'
  ) then
    raise exception 'Operational reason codes are not exposed on both match kinds.';
  end if;
  if not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_state',
    'SELECT'
  ) or not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_state_updated_at',
    'SELECT'
  ) or not has_column_privilege(
    'authenticated',
    'public.fixtures',
    'operational_reason_code',
    'SELECT'
  ) then
    raise exception
      'Authenticated clients cannot read fixture operational state.';
  end if;
  if has_column_privilege(
    'authenticated',
    'public.fixtures',
    'home_reliability_deposit_fils',
    'SELECT'
  ) or has_column_privilege(
    'authenticated',
    'public.fixtures',
    'away_reliability_deposit_fils',
    'SELECT'
  ) then
    raise exception 'Authenticated clients can read private fixture deposits.';
  end if;
  if (
    select coalesce(
      (policy.config #>>
        '{clan,minimumOnTimeWithoutClanStrike}')::integer,
      0
    )
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from <= statement_timestamp()
    order by policy.effective_from desc, policy.version desc
    limit 1
  ) <= 0 then
    raise exception 'The published policy has no clan short-roster threshold.';
  end if;

  select referee.profile_id into admin_id
  from public.referee_profiles referee
  where referee.role = 'admin' and referee.is_active
  order by referee.created_at, referee.profile_id
  limit 1;

  select
    fixture.id,
    fixture.home_clan_id,
    fixture.away_clan_id,
    fixture.status,
    fixture.home_refund_amount_fils,
    fixture.away_refund_amount_fils
  into fixture_to_test
  from public.fixtures fixture
  where fixture.status in ('OPEN', 'SCHEDULED')
    and fixture.away_clan_id is not null
    and not exists (
      select 1
      from public.match_resolution_cases existing_case
      where existing_case.fixture_id = fixture.id
        and existing_case.current_revision > 0
    )
    and not exists (
      select 1
      from public.match_forfeit_decisions decision
      where decision.fixture_id = fixture.id
    )
    and not exists (
      select 1
      from public.clan_fixture_cancellations cancellation
      where cancellation.fixture_id = fixture.id
    )
    and not exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture.id
    )
    and not exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.fixture_id = fixture.id
        and attendance.finalized_at is not null
    )
  order by fixture.match_date desc, fixture.id
  limit 1;

  if admin_id is null or fixture_to_test.id is null then
    raise exception
      'Control-plane verification needs one active admin and one unplayed clan fixture.';
  end if;

  select member.profile_id into home_member_id
  from public.clan_members member
  where member.clan_id = fixture_to_test.home_clan_id
    and member.left_at is null
  order by member.profile_id
  limit 1;
  select member.profile_id into away_member_id
  from public.clan_members member
  where member.clan_id = fixture_to_test.away_clan_id
    and member.left_at is null
  order by member.profile_id
  limit 1;
  member_ids := array[home_member_id, away_member_id];
  if home_member_id is null or away_member_id is null then
    raise exception
      'Control-plane verification needs one active member from each clan.';
  end if;
  select case when public.player_rating_effective_at_is_current(
    public.fixture_start_at(f.match_date,f.time_slot)) then 2 else 0 end
  into expected_clan_rating_events from public.fixtures f where f.id=fixture_to_test.id;
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
  into clan_track_ratings_before from public.fieldrush_player_rating_tracks r
  where r.profile_id=any(member_ids);
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id)
  into clan_legacy_ratings_before from public.player_ratings r where r.profile_id=any(member_ids);

  select clan.skill_rating, clan.wins, clan.losses
  into initial_home_rating, initial_home_wins, initial_home_losses
  from public.clans clan
  where clan.id = fixture_to_test.home_clan_id;
  select clan.skill_rating, clan.wins, clan.losses
  into initial_away_rating, initial_away_wins, initial_away_losses
  from public.clans clan
  where clan.id = fixture_to_test.away_clan_id;

  -- The minute worker may discover this seeded overdue fixture before the
  -- verifier starts. Reuse only a consequence-free case and rebuild it inside
  -- this rolled-back transaction so the test cannot race pg_cron.
  delete from public.match_resolution_cases stale_case
  where stale_case.fixture_id = fixture_to_test.id
    and stale_case.current_revision = 0;

  -- Reproduce a legacy/corrupt FINAL record with only one score. Trigger
  -- bypass is confined to this rolled-back verifier setup; the detector and
  -- every control-plane action below run with normal triggers enabled.
  execute 'alter table public.fixtures disable trigger user';
  update public.fixtures
  set status = 'FINAL',
    home_score = 1,
    away_score = null,
    operational_state = 'NORMAL',
    operational_state_updated_at = clock_timestamp(),
    operational_reason_code = null
  where id = fixture_to_test.id;
  execute 'alter table public.fixtures enable trigger user';

  detected_count := public.detect_due_match_resolution_cases();
  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.fixture_id = fixture_to_test.id;
  if detected_count <= 0
    or review_case.id is null
    or review_case.state <> 'NO_DATA'
    or review_case.reason_code <> 'RESULT_MISSING'
    or review_case.evidence_snapshot ->> 'detection_reason_code'
      <> 'RESULT_MISSING'
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.operational_state = 'NO_DATA'
        and fixture.operational_reason_code = 'RESULT_MISSING'
    )
  then
    raise exception 'FINAL partial-score No Data detection is incorrect.';
  end if;

  legacy_preview_result := public.admin_preview_match_case_resolution(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    0,
    'RECORDED_RESULT',
    'Verification completes the authoritative legacy partial score.',
    jsonb_build_object(
      'home_score', 2,
      'away_score', 1,
      'attendance',
      jsonb_build_object(
        'players',
        jsonb_build_array(
          jsonb_build_object(
            'profile_id', home_member_id,
            'state', 'PRESENT'
          ),
          jsonb_build_object(
            'profile_id', away_member_id,
            'state', 'PRESENT'
          )
        )
      )
    )
  );
  legacy_no_show_preview := public.admin_preview_match_case_resolution(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    0,
    'HOME_NO_SHOW',
    'Verification confirms a legacy final row was actually a no-show.',
    jsonb_build_object(
      'attendance',
      jsonb_build_object('HOME', 'NO_SHOW', 'AWAY', 'PRESENT')
    )
  );
  if legacy_preview_result #>>
      '{consequences,initial_player_sr_pipeline_replayed}' <> 'true'
    or legacy_no_show_preview #>>
      '{consequences,initial_player_sr_pipeline_replayed}' <> 'false'
    or exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture_to_test.id
    )
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.status = 'FINAL'
        and fixture.home_score = 1
        and fixture.away_score is null
    )
  then
    raise exception
      'Legacy FINAL Player SR replay is missing, persistent, or enabled for a no-show.';
  end if;

  -- A finalized attendance record is evidence, not an authoritative result.
  -- Remove only the consequence-free test case, recreate a passed scheduled
  -- row with both scores absent, and materialize one legacy finalized check-in.
  legacy_case_id := review_case.id;
  delete from public.match_resolution_cases
  where id = legacy_case_id;
  execute 'alter table public.fixtures disable trigger user';
  update public.fixtures
  set status = 'SCHEDULED',
    home_score = null,
    away_score = null,
    winner_clan_id = null,
    home_sr_change = null,
    away_sr_change = null,
    operational_state = 'NORMAL',
    operational_state_updated_at = clock_timestamp(),
    operational_reason_code = null
  where id = fixture_to_test.id;
  execute 'alter table public.fixtures enable trigger user';

  perform public.ensure_match_reliability_terms(
    'CLAN', fixture_to_test.id
  );
  perform public.initialize_fixture_reliability_roster(fixture_to_test.id);
  perform public.ensure_match_attendance_records(
    'CLAN', fixture_to_test.id
  );
  execute
    'alter table public.match_attendance_records disable trigger user';
  update public.match_attendance_records
  set checked_in_at = clock_timestamp() - interval '2 hours',
    checked_in_by = admin_id,
    outcome = 'ON_TIME',
    strike_delta = 0,
    finalized_at = clock_timestamp() - interval '1 hour',
    appeal_due_at = clock_timestamp() + interval '23 hours'
  where fixture_id = fixture_to_test.id
    and profile_id = home_member_id;
  execute
    'alter table public.match_attendance_records enable trigger user';

  detected_count := public.detect_due_match_resolution_cases();
  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.fixture_id = fixture_to_test.id;
  if detected_count <= 0
    or review_case.id is null
    or review_case.state <> 'NO_DATA'
    or review_case.reason_code <> 'RESULT_MISSING'
    or not exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.fixture_id = fixture_to_test.id
        and attendance.finalized_at is not null
    )
  then
    raise exception
      'Finalized attendance incorrectly suppressed missing-result detection.';
  end if;

  -- Preview uses the real resolver but must leave every write rolled back.
  preview_result := public.admin_preview_match_case_resolution(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    0,
    'HOME_NO_SHOW',
    'Verification evidence confirms the home clan did not attend.',
    jsonb_build_object(
      'attendance',
      jsonb_build_object('HOME', 'NO_SHOW', 'AWAY', 'PRESENT')
    )
  );
  if preview_result ->> 'preview' <> 'true'
    or (preview_result ->> 'next_revision')::integer <> 1
    or exists (
      select 1
      from public.match_resolution_revisions revision
      where revision.case_id = review_case.id
    )
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.status = 'SCHEDULED'
        and fixture.home_score is null
        and fixture.away_score is null
    )
  then
    raise exception 'The exact consequence preview persisted side effects.';
  end if;

  first_result := public.admin_resolve_match_case(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    0,
    'HOME_NO_SHOW',
    'Verification evidence confirms the home clan did not attend.',
    jsonb_build_object(
      'attendance',
      jsonb_build_object('HOME', 'NO_SHOW', 'AWAY', 'PRESENT')
    )
  );
  first_revision_id := (first_result ->> 'revision_id')::uuid;
  if first_result -> 'consequences' <> preview_result -> 'consequences'
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.status = 'FINAL'
        and fixture.home_score = 0
        and fixture.away_score > 0
        and fixture.winner_clan_id = fixture_to_test.away_clan_id
        and fixture.operational_state = 'RESOLVED'
    )
    or (select clan.wins from public.clans clan
        where clan.id = fixture_to_test.home_clan_id)
      <> initial_home_wins
    or (select clan.losses from public.clans clan
        where clan.id = fixture_to_test.home_clan_id)
      <> initial_home_losses + 1
    or (select clan.wins from public.clans clan
        where clan.id = fixture_to_test.away_clan_id)
      <> initial_away_wins + 1
    or (select clan.losses from public.clans clan
        where clan.id = fixture_to_test.away_clan_id)
      <> initial_away_losses
  then
    raise exception 'One-sided no-show resolution or exact preview drifted.';
  end if;

  select count(*) into expected_old_incidents
  from public.match_resolution_incident_links link
  join public.reliability_incidents incident on incident.id = link.incident_id
  where link.revision_id = first_revision_id
    and link.effect_kind = 'APPLIED'
    and incident.strike_delta > 0;

  -- Correct directly from RESOLVED. The prior W/L, Clan SR and strikes must be
  -- reversed before the opposite finding is applied.
  correction_result := public.admin_resolve_match_case(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    1,
    'AWAY_NO_SHOW',
    'Video review proves the away clan, not the home clan, was absent.',
    jsonb_build_object(
      'attendance',
      jsonb_build_object('HOME', 'PRESENT', 'AWAY', 'NO_SHOW')
    )
  );
  second_revision_id := (correction_result ->> 'revision_id')::uuid;

  select count(*) into unresolved_old_incidents
  from public.match_resolution_incident_links link
  join public.reliability_incidents incident on incident.id = link.incident_id
  where link.revision_id = first_revision_id
    and link.effect_kind = 'APPLIED'
    and incident.strike_delta > 0
    and not exists (
      select 1
      from public.reliability_incidents reversal
      where reversal.reversal_of = incident.id
    );
  select count(*) into second_incidents
  from public.match_resolution_incident_links link
  join public.reliability_incidents incident on incident.id = link.incident_id
  where link.revision_id = second_revision_id
    and link.effect_kind = 'APPLIED'
    and incident.strike_delta > 0;

  if (correction_result ->> 'revision')::integer <> 2
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.status = 'FINAL'
        and fixture.home_score > 0
        and fixture.away_score = 0
        and fixture.winner_clan_id = fixture_to_test.home_clan_id
    )
    or (select clan.wins from public.clans clan
        where clan.id = fixture_to_test.home_clan_id)
      <> initial_home_wins + 1
    or (select clan.losses from public.clans clan
        where clan.id = fixture_to_test.home_clan_id)
      <> initial_home_losses
    or (select clan.wins from public.clans clan
        where clan.id = fixture_to_test.away_clan_id)
      <> initial_away_wins
    or (select clan.losses from public.clans clan
        where clan.id = fixture_to_test.away_clan_id)
      <> initial_away_losses + 1
    or (select count(*)
        from public.match_resolution_clan_sr_adjustments adjustment
        where adjustment.case_id = review_case.id) <> 6
    or (select clan.skill_rating from public.clans clan
        where clan.id = fixture_to_test.home_clan_id)
      <> initial_home_rating + (
        select coalesce(sum(adjustment.rating_delta), 0)
        from public.match_resolution_clan_sr_adjustments adjustment
        where adjustment.case_id = review_case.id
          and adjustment.clan_id = fixture_to_test.home_clan_id
      )
    or (select clan.skill_rating from public.clans clan
        where clan.id = fixture_to_test.away_clan_id)
      <> initial_away_rating + (
        select coalesce(sum(adjustment.rating_delta), 0)
        from public.match_resolution_clan_sr_adjustments adjustment
        where adjustment.case_id = review_case.id
          and adjustment.clan_id = fixture_to_test.away_clan_id
      )
    or (expected_old_incidents > 0 and unresolved_old_incidents <> 0)
    or (
      coalesce(
        (review_case.policy_snapshot #>>
          '{clan,entireClanNoShowStrikes}')::integer,
        0
      ) > 0 and second_incidents = 0
    )
  then
    raise exception 'Correction double-applied or failed to reverse a prior effect.';
  end if;

  -- Correct the no-show to a genuinely played result without changing its
  -- numeric forfeit score. FINAL -> FINAL would skip Player SR, so the
  -- resolver must cross its audited non-final boundary and restore only the
  -- two explicitly named participants.
  select fixture.home_score, fixture.away_score
  into corrected_home_score, corrected_away_score
  from public.fixtures fixture
  where fixture.id = fixture_to_test.id;
  played_correction_result := public.admin_resolve_match_case(
    admin_id,
    'CLAN',
    fixture_to_test.id,
    2,
    'RECORDED_RESULT',
    'Player-level evidence proves both clans played the recorded score.',
    jsonb_build_object(
      'home_score', corrected_home_score,
      'away_score', corrected_away_score,
      'attendance',
      jsonb_build_object(
        'players',
        jsonb_build_array(
          jsonb_build_object(
            'profile_id', home_member_id,
            'state', 'PRESENT'
          ),
          jsonb_build_object(
            'profile_id', away_member_id,
            'state', 'PRESENT'
          )
        )
      )
    )
  );
  if played_correction_result #>>
      '{consequences,initial_player_sr_pipeline_replayed}' <> 'true'
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.status = 'FINAL'
        and fixture.home_score = corrected_home_score
        and fixture.away_score = corrected_away_score
    )
    or (
      select count(*)
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = fixture_to_test.id
        and appearance.played
    ) <> 2
    or not exists (
      select 1
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = fixture_to_test.id
        and appearance.profile_id = home_member_id
        and appearance.side = 'HOME'
        and appearance.played
    )
    or not exists (
      select 1
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = fixture_to_test.id
        and appearance.profile_id = away_member_id
        and appearance.side = 'AWAY'
        and appearance.played
    )
    or (
      select count(*)
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture_to_test.id
    ) <> expected_clan_rating_events
    or (
      select count(distinct event.profile_id)
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture_to_test.id
    ) <> expected_clan_rating_events
    or (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
      from public.fieldrush_player_rating_tracks r where r.profile_id=any(member_ids))
      is distinct from clan_track_ratings_before
    or (expected_clan_rating_events=0 and
      (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id)
       from public.player_ratings r where r.profile_id=any(member_ids))
      is distinct from clan_legacy_ratings_before)
  then
    raise exception
      'Same-score clan correction did not restore exactly the explicit Player SR lineup (replayed %, appearances %, rating events %).',
      played_correction_result #>> '{consequences,initial_player_sr_pipeline_replayed}',
      (select count(*) from public.fixture_player_appearances where fixture_id=fixture_to_test.id and played),
      (select count(*) from public.player_rating_events where source_type='CLAN_FIXTURE' and source_id=fixture_to_test.id);
  end if;

  -- Two different affected members may dispute the same current revision.
  -- The first dispute clears resolved_at, so the second call also verifies
  -- that the deadline is revision-based rather than case-state-based.
  perform set_config('request.jwt.claim.sub', member_ids[1]::text, true);
  dispute_result := public.submit_match_resolution_dispute(
    review_case.id,
    'The attendance finding does not match our timestamped team evidence.'
  );
  perform set_config('request.jwt.claim.sub', member_ids[2]::text, true);
  perform public.submit_match_resolution_dispute(
    review_case.id,
    'Our second participant independently disputes the attendance finding.'
  );
  perform set_config('request.jwt.claim.sub', member_ids[1]::text, true);
  participant_result := public.get_match_resolution_case(
    'CLAN', fixture_to_test.id
  );

  if dispute_result ->> 'refunds_continue' <> 'true'
    or (select count(*)
        from public.match_resolution_disputes dispute
        where dispute.case_id = review_case.id
          and dispute.status = 'OPEN') <> 2
    or participant_result ->> 'state' <> 'UNDER_REVIEW'
    or participant_result ->> 'reason_code' <> 'DISPUTED'
    or participant_result ->> 'can_dispute' <> 'false'
    or participant_result ->> 'refunds_continue_during_dispute' <> 'true'
    or (participant_result #> '{resolution,consequences}')
      ? 'home_refund_target_fils'
    or (participant_result #> '{resolution,consequences}')
      ? 'away_refund_target_fils'
    or (participant_result #> '{resolution,consequences}')
      ? 'administratively_cancelled_booking_ids'
    or (participant_result #> '{resolution,consequences}')
      ? 'restored_booking_ids'
    or (participant_result #> '{resolution,consequences}')
      ? 'player_sr_lineup_profile_ids'
    or not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = fixture_to_test.id
        and fixture.operational_state = 'UNDER_REVIEW'
        and fixture.operational_reason_code = 'DISPUTED'
    )
  then
    raise exception 'Participant dispute lifecycle or finance redaction is incorrect.';
  end if;

  -- Build a rollback-only solo match in a future slot so normal booking
  -- guards run, then backdate the match/terms to exercise No Data detection.
  select array_agg(candidate.profile_id order by candidate.profile_id)
  into solo_player_ids
  from (
    select profile.id as profile_id
    from public.profiles profile
    where not public.profile_has_active_play_restriction(profile.id)
      and not public.profile_has_active_reliability_booking_restriction(
        profile.id
      )
      and pg_temp.verification_player_has_free_game_slot(profile.id)
    order by profile.id
    limit 3
  ) candidate;
  if coalesce(cardinality(solo_player_ids), 0) <> 3 then
    raise exception
      'Control-plane verification needs three unrestricted solo players.';
  end if;
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
  into solo_track_ratings_before from public.fieldrush_player_rating_tracks r
  where r.profile_id=any(solo_player_ids);
  select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id)
  into solo_legacy_ratings_before from public.player_ratings r where r.profile_id=any(solo_player_ids);
  select candidate.starts_at into solo_game_starts_at
  from (
    select
      ((day_to_use::date + time '20:30') at time zone 'Asia/Bahrain')
        as starts_at
    from generate_series(
      current_date + interval '500 days',
      current_date + interval '560 days',
      interval '1 day'
    ) generated(day_to_use)
    where extract(isodow from day_to_use) in (2, 5)
      and not exists (
        select 1
        from public.open_queue_games existing
        where existing.starts_at =
          ((day_to_use::date + time '20:30') at time zone 'Asia/Bahrain')
          and existing.status <> 'CANCELLED'
      )
    order by day_to_use
    limit 1
  ) candidate;
  if solo_game_starts_at is null then
    raise exception
      'Control-plane verification needs one unused solo schedule slot.';
  end if;
  select max(
    (day_to_use::date + time '20:30') at time zone 'Asia/Bahrain'
  )
  into solo_past_starts_at
  from generate_series(
    current_date - interval '21 days',
    current_date - interval '1 day',
    interval '1 day'
  ) generated(day_to_use)
  where extract(isodow from day_to_use) in (2, 5)
    and (
      (day_to_use::date + time '21:30') at time zone 'Asia/Bahrain'
    ) + interval '30 minutes' <= clock_timestamp();
  if solo_past_starts_at is null then
    raise exception
      'Control-plane verification needs one passed solo schedule slot.';
  end if;

  insert into public.open_queue_games (
    format_version, currency, capacity,
    goalkeeper_capacity, defender_capacity, midfielder_capacity, attacker_capacity,
    status, venue, starts_at, ends_at, timezone, created_by
  ) values (
    'LEGACY_6V6', 'BHD', 12, 2, 4, 4, 2,
    'OPEN',
    'Match resolution rollback verification',
    solo_game_starts_at,
    solo_game_starts_at + interval '1 hour',
    'Asia/Bahrain',
    solo_player_ids[1]
  ) returning id into solo_game_id;

  with inserted_booking as (
    insert into public.open_queue_bookings (
      game_id, profile_id, role, player_rating_at_booking,
      amount_paid_fils, base_amount_fils, payment_method, payment_status
    )
    select
      solo_game_id,
      player.profile_id,
      (array['GK', 'DEF', 'MID'])[player.position],
      coalesce(rating.skill_rating, 1200),
      3000,
      3000,
      'MOCK',
      'PAID'
    from unnest(solo_player_ids) with ordinality
      as player(profile_id, position)
    left join public.player_ratings rating
      on rating.profile_id = player.profile_id
    returning id, profile_id
  )
  select array_agg(
    inserted_booking.id
    order by array_position(solo_player_ids, inserted_booking.profile_id)
  )
  into solo_booking_ids
  from inserted_booking;

  update public.open_queue_bookings booking
  set team = case
    when booking.profile_id in (solo_player_ids[1], solo_player_ids[3])
      then 'WHITE'
    else 'BLACK'
  end
  where booking.game_id = solo_game_id;
  perform public.ensure_match_reliability_terms('SOLO', solo_game_id);
  perform public.ensure_match_attendance_records('SOLO', solo_game_id);

  -- This player cancels before the admin review. Their status and attendance
  -- must never enter the admin-cancelled provenance set or be restored later.
  solo_cancelled_booking_id := solo_booking_ids[3];
  update public.open_queue_bookings
  set status = 'CANCELLED', cancelled_at = clock_timestamp()
  where id = solo_cancelled_booking_id;

  execute 'alter table public.open_queue_games disable trigger user';
  update public.open_queue_games
  set starts_at = solo_past_starts_at,
    ends_at = solo_past_starts_at + interval '1 hour',
    status = 'OPEN',
    white_score = null,
    black_score = null,
    operational_state = 'NORMAL',
    operational_state_updated_at = clock_timestamp(),
    operational_reason_code = null
  where id = solo_game_id;
  execute 'alter table public.open_queue_games enable trigger user';
  execute 'alter table public.match_reliability_terms disable trigger user';
  update public.match_reliability_terms
  set kickoff_at = solo_past_starts_at,
    check_in_opens_at = solo_past_starts_at - interval '3 hours',
    check_in_deadline_at = solo_past_starts_at,
    no_show_cutoff_at = solo_past_starts_at + interval '15 minutes'
  where open_queue_game_id = solo_game_id;
  execute 'alter table public.match_reliability_terms enable trigger user';
  execute 'alter table public.match_attendance_records disable trigger user';
  update public.match_attendance_records
  set check_in_deadline_at = solo_past_starts_at,
    no_show_cutoff_at = solo_past_starts_at + interval '15 minutes'
  where open_queue_game_id = solo_game_id;
  update public.match_attendance_records
  set outcome = 'CANCELLED_EARLY',
    cancelled_at = solo_past_starts_at - interval '4 hours',
    finalized_at = solo_past_starts_at - interval '4 hours',
    strike_delta = 0
  where booking_id = solo_cancelled_booking_id;
  execute 'alter table public.match_attendance_records enable trigger user';

  -- This legacy match remains a finance/lineup correction scenario. The new
  -- rating era must not import a historical 6v6 match into either discipline.
  select case when g.format_version='FIELDRUSH_7V7'
    and public.player_rating_effective_at_is_current(g.starts_at) then 2 else 0 end
  into expected_solo_rating_events from public.open_queue_games g where g.id=solo_game_id;

  detected_count := public.detect_due_match_resolution_cases();
  select * into solo_case
  from public.match_resolution_cases candidate
  where candidate.open_queue_game_id = solo_game_id;
  if detected_count <= 0
    or solo_case.id is null
    or solo_case.state <> 'NO_DATA'
    or solo_case.reason_code <> 'NO_ACTIVITY'
  then
    raise exception 'Solo No Data detection did not create a neutral review.';
  end if;

  solo_first_result := public.admin_resolve_match_case(
    admin_id,
    'SOLO',
    solo_game_id,
    0,
    'HOME_NO_SHOW',
    'Verification marks only the supported solo side as absent.',
    jsonb_build_object(
      'attendance',
      jsonb_build_object('WHITE', 'NO_SHOW', 'BLACK', 'PRESENT'),
      'home_strikes', 0,
      'away_strikes', 0
    )
  );
  if jsonb_array_length(
      solo_first_result #>
        '{consequences,administratively_cancelled_booking_ids}'
    ) <> 2
    or not ((
      solo_first_result #>
        '{consequences,administratively_cancelled_booking_ids}'
    ) ? solo_booking_ids[1]::text)
    or not ((
      solo_first_result #>
        '{consequences,administratively_cancelled_booking_ids}'
    ) ? solo_booking_ids[2]::text)
    or (
      solo_first_result #>
        '{consequences,administratively_cancelled_booking_ids}'
    ) ? solo_cancelled_booking_id::text
    or exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = solo_game_id
        and booking.status <> 'CANCELLED'
    )
    or not exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.booking_id = solo_cancelled_booking_id
        and attendance.outcome = 'CANCELLED_EARLY'
    )
  then
    raise exception
      'Solo admin cancellation provenance included or rewrote a user cancellation.';
  end if;

  select coalesce(booking.refund_amount_fils, 0)
  into solo_refund_before
  from public.open_queue_bookings booking
  where booking.id = solo_booking_ids[2];
  select count(*), coalesce(sum(wallet_tx.amount_fils), 0)
  into solo_wallet_credits_before, solo_wallet_credit_fils_before
  from public.field_wallet_transactions wallet_tx
  where wallet_tx.booking_id = solo_booking_ids[2]
    and wallet_tx.transaction_type = 'FIELD_CANCELLATION_REFUND';
  if solo_refund_before <> 3000
    or solo_wallet_credits_before <> 1
    or solo_wallet_credit_fils_before <> 3000
  then
    raise exception 'The present solo side did not receive one full refund.';
  end if;

  solo_correction_result := public.admin_resolve_match_case(
    admin_id,
    'SOLO',
    solo_game_id,
    1,
    'RECORDED_RESULT',
    'Player-level evidence confirms the solo match was actually played.',
    jsonb_build_object(
      'home_score', 2,
      'away_score', 1,
      'attendance',
      jsonb_build_object(
        'players',
        jsonb_build_array(
          jsonb_build_object(
            'profile_id', solo_player_ids[1],
            'state', 'PRESENT'
          ),
          jsonb_build_object(
            'profile_id', solo_player_ids[2],
            'state', 'PRESENT'
          )
        )
      )
    )
  );
  if not exists (
      select 1
      from public.open_queue_games game
      where game.id = solo_game_id
        and game.status = 'FINAL'
        and game.white_score = 2
        and game.black_score = 1
    )
    or (
      select count(*)
      from public.open_queue_bookings booking
      where booking.game_id = solo_game_id
        and booking.status = 'CONFIRMED'
        and booking.played
    ) <> 2
    or not exists (
      select 1
      from public.open_queue_bookings booking
      where booking.id = solo_cancelled_booking_id
        and booking.status = 'CANCELLED'
        and not booking.played
    )
    or not exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.booking_id = solo_cancelled_booking_id
        and attendance.outcome = 'CANCELLED_EARLY'
    )
    or (
      select count(*)
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id = solo_game_id
    ) <> expected_solo_rating_events
    or jsonb_array_length(
      solo_correction_result #> '{consequences,restored_booking_ids}'
    ) <> 2
    or (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id,r.rating_track)
      from public.fieldrush_player_rating_tracks r where r.profile_id=any(solo_player_ids))
      is distinct from solo_track_ratings_before
    or (expected_solo_rating_events=0 and
      (select jsonb_agg(to_jsonb(r)-'updated_at' order by r.profile_id)
       from public.player_ratings r where r.profile_id=any(solo_player_ids))
      is distinct from solo_legacy_ratings_before)
    or jsonb_array_length(
      solo_correction_result #> '{consequences,player_sr_lineup_profile_ids}'
    ) <> 2
  then
    raise exception
      'Solo correction did not restore exactly the admin-cancelled played lineup.';
  end if;

  -- A repeated correction must preserve the exact era-appropriate ledger and
  -- the already-paid refund, including zero SR events for historical games.
  solo_repeat_result := public.admin_resolve_match_case(
    admin_id,
    'SOLO',
    solo_game_id,
    2,
    'RECORDED_RESULT',
    'Repeat verification proves correction idempotency and refund safety.',
    jsonb_build_object(
      'home_score', 2,
      'away_score', 1,
      'attendance',
      jsonb_build_object(
        'players',
        jsonb_build_array(
          jsonb_build_object(
            'profile_id', solo_player_ids[1],
            'state', 'PRESENT'
          ),
          jsonb_build_object(
            'profile_id', solo_player_ids[2],
            'state', 'PRESENT'
          )
        )
      )
    )
  );
  if (solo_repeat_result ->> 'revision')::integer <> 3
    or (
      select count(*)
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id = solo_game_id
    ) <> expected_solo_rating_events
    or (
      select coalesce(booking.refund_amount_fils, 0)
      from public.open_queue_bookings booking
      where booking.id = solo_booking_ids[2]
    ) <> solo_refund_before
    or (
      select count(*)
      from public.field_wallet_transactions wallet_tx
      where wallet_tx.booking_id = solo_booking_ids[2]
        and wallet_tx.transaction_type = 'FIELD_CANCELLATION_REFUND'
    ) <> solo_wallet_credits_before
    or (
      select coalesce(sum(wallet_tx.amount_fils), 0)
      from public.field_wallet_transactions wallet_tx
      where wallet_tx.booking_id = solo_booking_ids[2]
        and wallet_tx.transaction_type = 'FIELD_CANCELLATION_REFUND'
    ) <> solo_wallet_credit_fils_before
  then
    raise exception
      'Solo correction duplicated Player SR or clawed back/duplicated a refund.';
  end if;

  perform set_config(
    'request.jwt.claim.sub', solo_player_ids[1]::text, true
  );
  solo_participant_result := public.get_match_resolution_case(
    'SOLO', solo_game_id
  );
  if solo_participant_result ->> 'state' <> 'RESOLVED'
    or (solo_participant_result #> '{resolution,consequences}')
      ? 'administratively_cancelled_booking_ids'
    or (solo_participant_result #> '{resolution,consequences}')
      ? 'restored_booking_ids'
    or (solo_participant_result #> '{resolution,consequences}')
      ? 'player_sr_lineup_profile_ids'
  then
    raise exception
      'Solo participant resolution leaks internal correction provenance.';
  end if;
end;
$verify$;

rollback;
