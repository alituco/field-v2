begin;

do $verify$
declare
  seeded_config jsonb;
  supported_config jsonb;
  function_text text;
  result_signature text;
  published_count integer;
begin
  select policy.config into seeded_config
  from public.reliability_policy_versions policy
  where policy.version = 1
    and policy.state = 'PUBLISHED';

  if seeded_config is null then
    raise exception 'Missing the initial published reliability policy.';
  end if;
  if not public.reliability_policy_config_is_valid(seeded_config) then
    raise exception 'The initial reliability policy does not pass its database validator.';
  end if;
  if (seeded_config #>> '{attendance,checkInOpenLeadMinutes}')::integer <> 120 then
    raise exception 'The initial check-in opening lead must be 120 minutes.';
  end if;
  supported_config := jsonb_set(
    jsonb_set(seeded_config, '{solo,playersPerSide}', '6'::jsonb),
    '{clan,playersPerSide}',
    '6'::jsonb
  );
  if not public.reliability_policy_release_controls_are_valid(supported_config) then
    raise exception 'The current six-a-side format violates a release-locked structural control.';
  end if;
  if public.reliability_policy_release_controls_are_valid(
    jsonb_set(supported_config, '{solo,playersPerSide}', '7'::jsonb)
  ) or public.reliability_policy_release_controls_are_valid(
    jsonb_set(supported_config, '{clan,playersPerSide}', '7'::jsonb)
  ) or public.reliability_policy_release_controls_are_valid(
    jsonb_set(
      supported_config,
      '{appeals,routineTrafficAutomaticallyExcused}',
      'true'::jsonb
    )
  ) then
    raise exception 'A workflow-dependent release control is not fail-closed.';
  end if;
  if not public.reliability_policy_release_controls_are_valid(
    jsonb_set(
      supported_config,
      '{clan,cancellations,late,refundBps}',
      '6000'::jsonb
    )
  ) or not public.reliability_policy_release_controls_are_valid(
    jsonb_set(
      supported_config,
      '{clan,reliabilityDeposit,depositBps}',
      '2500'::jsonb
    )
  ) then
    raise exception 'Policy-backed clan cancellation or deposit controls remain locked.';
  end if;
  if not public.reliability_policy_release_controls_are_valid(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          supported_config,
          '{replacement,originalPlayerReclaimUntilMinutesAfterKickoff}',
          '8'::jsonb
        ),
        '{replacement,reserveActivationMinutesAfterKickoff}',
        '12'::jsonb
      ),
      '{replacement,order}',
      '["ON_FIELD_RESERVE","EMERGENCY_NOTIFICATION","PLAY_SHORTHANDED"]'::jsonb
    )
  ) then
    raise exception 'The policy-backed manual reserve plan remains locked.';
  end if;

  select count(*) into published_count
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= clock_timestamp();
  if published_count < 1 then
    raise exception 'No effective published reliability policy is available.';
  end if;

  if public.reliability_policy_config_is_valid(
    seeded_config #- '{attendance,checkInOpenLeadMinutes}'
  ) then
    raise exception 'Validator accepted a missing check-in opening setting.';
  end if;
  if public.reliability_policy_config_is_valid(
    jsonb_set(seeded_config, '{attendance,checkInOpenLeadMinutes}', '15'::jsonb)
  ) then
    raise exception 'Validator accepted check-in opening at the hard deadline.';
  end if;
  if public.reliability_policy_config_is_valid(
    jsonb_set(seeded_config, '{solo,sanctions}', '[]'::jsonb)
  ) then
    raise exception 'Validator accepted an empty solo sanction ladder.';
  end if;
  if public.reliability_policy_config_is_valid(
    jsonb_set(
      seeded_config,
      '{replacement,order}',
      '["EMERGENCY_NOTIFICATION","EMERGENCY_NOTIFICATION","PLAY_SHORTHANDED"]'::jsonb
    )
  ) then
    raise exception 'Validator accepted duplicate replacement steps.';
  end if;
  if public.reliability_policy_config_is_valid(
    jsonb_set(
      seeded_config,
      '{replacement,lateCancellationDiscountBps}',
      '2500'::jsonb
    )
  ) then
    raise exception 'Validator accepted conflicting replacement discounts.';
  end if;
  if public.reliability_policy_config_is_valid(
    jsonb_set(seeded_config, '{unexpectedSetting}', 'true'::jsonb)
  ) then
    raise exception 'Validator accepted an unknown policy setting.';
  end if;

  if to_regprocedure(
    'public.admin_create_reliability_policy_draft(uuid,uuid,timestamptz,text)'
  ) is null then
    raise exception 'Missing admin_create_reliability_policy_draft RPC.';
  end if;
  if to_regprocedure(
    'public.admin_update_reliability_policy_draft(uuid,uuid,jsonb,timestamptz,text,timestamptz)'
  ) is null then
    raise exception 'Missing admin_update_reliability_policy_draft RPC.';
  end if;
  if to_regprocedure(
    'public.admin_publish_reliability_policy(uuid,uuid,text)'
  ) is null then
    raise exception 'Missing admin_publish_reliability_policy RPC.';
  end if;
  if to_regprocedure(
    'public.admin_review_reliability_appeal(uuid,uuid,text,text)'
  ) is null then
    raise exception 'Missing admin_review_reliability_appeal RPC.';
  end if;

  if to_regprocedure(
    'public.get_match_reliability_context(text,uuid)'
  ) is null
    or to_regprocedure(
      'public.referee_check_in_player(uuid,text,uuid,uuid)'
    ) is null
    or to_regprocedure(
      'public.referee_finalize_match_attendance(uuid,text,uuid)'
    ) is null
    or to_regprocedure(
      'public.referee_remove_player_check_in(uuid,text,uuid,uuid,integer,text,text)'
    ) is null
    or to_regprocedure('public.get_my_reliability_status()') is null
    or to_regprocedure(
      'public.submit_reliability_appeal(uuid,text,text)'
    ) is null
  then
    raise exception 'One or more stable reliability client RPCs are missing.';
  end if;
  if to_regprocedure(
      'public.preview_open_queue_booking_cost(uuid,text)'
    ) is null
    or to_regprocedure(
      'public.preview_create_clan_fixture_charge(uuid,date,text)'
    ) is null
    or to_regprocedure(
      'public.preview_join_clan_fixture_charge(uuid,uuid)'
    ) is null
    or to_regprocedure(
      'public.preview_clan_fixture_cancellation(uuid)'
    ) is null
    or to_regprocedure(
      'public.cancel_clan_fixture_booking(uuid,text)'
    ) is null
  then
    raise exception 'One or more stable booking/fixture quote RPCs are missing.';
  end if;

  select pg_get_functiondef(
    'public.admin_publish_reliability_policy(uuid,uuid,text)'::regprocedure
  ) into function_text;
  if position('pg_advisory_xact_lock' in function_text) = 0
    or position('current_same_time' in function_text) = 0
    or position('RELIABILITY_POLICY_SCHEDULED_REPLACED' in function_text) = 0
  then
    raise exception 'Scheduled policy replacement is not concurrency-safe or auditable.';
  end if;
  if not exists (
    select 1
    from pg_index index_info
    join pg_class index_class on index_class.oid = index_info.indexrelid
    where index_class.relname = 'reliability_policy_published_supersession_idx'
      and index_info.indisunique
  ) then
    raise exception 'Published policy successor branches are not constrained.';
  end if;

  select pg_get_functiondef(
    'public.preview_clan_fixture_cancellation(uuid)'::regprocedure
  ) into function_text;
  if position('payer_profile_id' in function_text) = 0
    or position('- ''payer_profile_id''' in function_text) = 0
    or position('- ''opponent_payer_profile_id''' in function_text) = 0
  then
    raise exception 'Public clan cancellation preview does not strip payer UUIDs.';
  end if;

  select pg_get_functiondef(
    'public.preview_join_clan_fixture_charge(uuid,uuid)'::regprocedure
  ) into function_text;
  if position('terms_to_use.policy_snapshot' in function_text) = 0
    or position('clan_fixture_charge_quote_from_snapshot' in function_text) = 0
  then
    raise exception 'AWAY clan preview does not use the fixture''s frozen policy snapshot.';
  end if;
  select pg_get_functiondef(
    'public.snapshot_clan_fixture_charge()'::regprocedure
  ) into function_text;
  if position('terms_to_use.policy_snapshot' in function_text) = 0
    or position('new.away_charge_policy_version_id' in function_text) = 0
  then
    raise exception 'Persisted AWAY clan charge can diverge from the frozen fixture policy.';
  end if;

  if not exists (
    select 1
    from information_schema.columns column_info
    where column_info.table_schema = 'public'
      and column_info.table_name = 'match_reliability_terms'
      and column_info.column_name = 'check_in_opens_at'
      and column_info.is_nullable = 'NO'
  ) then
    raise exception 'match_reliability_terms.check_in_opens_at is missing.';
  end if;

  select pg_get_functiondef(
    'public.get_match_reliability_context(text,uuid)'::regprocedure
  ) into function_text;
  if position('check_in_opens_at' in function_text) = 0
    or position('TIMING_ONLY' in function_text) = 0
    or position('can_view_roster' in function_text) = 0
    or position('request_role = ''service_role''' in function_text) = 0
    or position('reserve_plan_automated' in function_text) = 0
    or position('replacement_order' in function_text) = 0
  then
    raise exception 'Match context timing or privacy scoping is incomplete.';
  end if;
  if position('server_now_to_use >= terms_to_use.check_in_opens_at' in function_text) > 0
    or position('can_view_roster
      and server_now_to_use < terms_to_use.no_show_cutoff_at' in function_text) = 0
  then
    raise exception 'Assigned referees cannot start check-in before the reminder window.';
  end if;

  select pg_get_functiondef(
    'public.get_my_reliability_status()'::regprocedure
  ) into function_text;
  if position('allowed_appeal_categories' in function_text) = 0
    or position('terms.policy_snapshot' in function_text) = 0
  then
    raise exception 'Reliability status does not return snapshot-specific appeal categories.';
  end if;

  select pg_get_functiondef(
    'public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure
  ) into function_text;
  if position('postCheckInDeadlineMarketplaceEnabled' in function_text) = 0
    or position('clock_timestamp() >= terms_to_use.check_in_deadline_at' in function_text) = 0
  then
    raise exception 'Booking does not enforce the policy marketplace cutoff.';
  end if;

  select pg_get_functiondef(
    'public.cancel_open_queue_booking(uuid)'::regprocedure
  ) into function_text;
  if position('replacement_marketplace_open' in function_text) = 0
    or position('profile_has_active_play_restriction' in function_text) = 0
  then
    raise exception 'Replacement promotion ignores its cutoff or play restrictions.';
  end if;

  select pg_get_functiondef(
    'public.list_open_queue_games()'::regprocedure
  ) into function_text;
  if position('postCheckInDeadlineMarketplaceEnabled' in function_text) = 0
    or position('terms.check_in_deadline_at' in function_text) = 0
  then
    raise exception 'Closed marketplace games remain in the joinable listing.';
  end if;

  select pg_get_functiondef(
    'public.admin_cancel_match(uuid,text,uuid,text,text)'::regprocedure
  ) into function_text;
  if position('apply_policy_field_cancellation' in function_text) = 0 then
    raise exception 'Admin cancellation bypasses the reliability policy.';
  end if;

  select pg_get_functiondef(
    'public.apply_policy_field_cancellation(uuid,text,uuid,text)'::regprocedure
  ) into function_text;
  if position('FIELD_CANCELLATION_REFUND' in function_text) = 0
    or position('RELIABILITY_DEPOSIT_RETURN' in function_text) = 0
    or position('FIELD_CANCELLED' in function_text) = 0
    or position('field-cancel-fee:' in function_text) = 0
    or position('field-cancel-deposit:' in function_text) = 0
  then
    raise exception 'Field cancellation is missing policy, wallet, or idempotency handling.';
  end if;

  select pg_get_functiondef(
    'public.referee_check_in_player(uuid,text,uuid,uuid)'::regprocedure
  ) into function_text;
  if position('checked_in_at_to_use < terms_to_use.check_in_opens_at' in function_text) > 0
  then
    raise exception 'Referee check-in still rejects early arrivals.';
  end if;
  if position('checked_side_count_to_use >= required_count_to_use' in function_text) = 0
    or position('required_count_to_use := 10;' in function_text) = 0
    or position('planned_roster_member' in function_text) = 0
    or position('profile_has_active_play_restriction' in function_text) = 0
    or position('''provisional'', true' in function_text) = 0
    or position('settle_reliability_deposit' in function_text) > 0
  then
    raise exception 'Referee check-in lacks provisional safety, eligibility, or the side cap.';
  end if;

  select pg_get_functiondef(
    'public.get_match_reliability_context(text,uuid)'::regprocedure
  ) into function_text;
  if position(') < 10' in function_text) = 0 then
    raise exception 'Clan check-in eligibility does not allow the ten-player matchday squad.';
  end if;

  select pg_get_functiondef(
    'public.referee_remove_player_check_in(uuid,text,uuid,uuid,integer,text,text)'::regprocedure
  ) into function_text;
  if position('CHECK_IN_REMOVED' in function_text) = 0
    or position('REFEREE_CHECK_IN_REMOVED' in function_text) = 0
    or position('expected_revision_to_use' in function_text) = 0
    or position('Check-ins cannot be removed after the match has started.' in function_text) = 0
  then
    raise exception 'Referee check-in removal lacks concurrency, lifecycle, or audit safeguards.';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.referee_remove_player_check_in(uuid,text,uuid,uuid,integer,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Players can execute the referee-only check-in correction RPC.';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.referee_check_in_player(uuid,text,uuid,uuid)',
    'EXECUTE'
  ) then
    raise exception 'Players can execute the referee-only check-in RPC.';
  end if;

  select pg_get_functiondef(
    'public.get_match_reliability_context(text,uuid)'::regprocedure
  ) into function_text;
  if position('''check_in_authority'', ''REFEREE''' in function_text) = 0
    or position('''expected_for_match'', attendance.expected_for_match' in function_text) = 0
    or position('can_view_roster' in function_text) = 0
  then
    raise exception 'Attendance context does not expose referee authority safely.';
  end if;

  select pg_get_functiondef(
    'public.finalize_clan_reliability_outcomes(uuid,uuid)'::regprocedure
  ) into function_text;
  if position('count(*) filter (where attendance.expected_for_match)' in function_text) = 0
    or position('and attendance.expected_for_match;' in function_text) > 0
  then
    raise exception 'Clan readiness does not count referee-confirmed substitutes safely.';
  end if;

  select pg_get_functiondef(
    'public.finalize_due_match_attendance()'::regprocedure
  ) into function_text;
  if position('''CLAN''' in function_text) > 0 then
    raise exception 'The attendance cron must not auto-finalize clan rosters.';
  end if;

  select pg_get_function_result(
    'public.preview_open_queue_cancellation(uuid)'::regprocedure
  ) into result_signature;
  if position('server_now timestamp with time zone' in result_signature) = 0
    or position('policy_version_id uuid' in result_signature) = 0
    or position('outcome_code text' in result_signature) = 0
    or position('strike_delta integer' in result_signature) = 0
    or position('refund_bps integer' in result_signature) = 0
    or position('refund_destination text' in result_signature) = 0
    or position('deposit_forfeited boolean' in result_signature) = 0
    or position('explanation text' in result_signature) = 0
  then
    raise exception 'Cancellation preview is missing required policy decision fields: %',
      result_signature;
  end if;

  select pg_get_functiondef(
    'public.open_queue_cancellation_quote(uuid,uuid,timestamptz)'::regprocedure
  ) into function_text;
  if position('booking_to_preview.cancelled_at is null' in function_text) = 0
    or position('not attendance_is_final' in function_text) = 0
  then
    raise exception 'Cancellation decisions are not protected against repeat finalization.';
  end if;

  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.reliability_policy_versions'::regclass
      and trigger_info.tgname = 'protect_published_reliability_policy'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Published policies are not protected by an immutability trigger.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.clan_fixture_cancellations'::regclass
      and trigger_info.tgname =
        'protect_clan_fixture_cancellations_append_only'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan cancellation evidence is not append-only.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid =
        'public.clan_match_reliability_outcomes'::regclass
      and trigger_info.tgname =
        'settle_clan_reliability_deposit_from_outcome'
      and not trigger_info.tgisinternal
  ) or not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname = 'settle_field_cancelled_clan_fixture'
      and not trigger_info.tgisinternal
  ) or not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname =
        'a_settle_completed_clan_fixture_finance'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan deposit, field cancellation, or FINAL settlement trigger is missing.';
  end if;
  if not exists (
    select 1
    from pg_constraint constraint_info
    where constraint_info.conrelid =
      'public.reliability_policy_versions'::regclass
      and constraint_info.conname =
        'reliability_policy_release_controls_check'
  ) then
    raise exception 'Release-locked reliability controls are not constrained.';
  end if;
  if not exists (
    select 1
    from pg_constraint constraint_info
    where constraint_info.conrelid = 'public.fixtures'::regclass
      and constraint_info.conname =
        'fixtures_clan_charge_policy_consistency_check'
  ) then
    raise exception 'Clan HOME/AWAY charge policy consistency is not constrained.';
  end if;
  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.open_queue_bookings'::regclass
      and trigger_info.tgname = 'require_checked_in_solo_participant'
      and not trigger_info.tgisinternal
  ) or not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixture_player_appearances'::regclass
      and trigger_info.tgname = 'require_checked_in_clan_participant'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Played-lineup check-in guards are missing.';
  end if;

  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.open_queue_bookings'::regclass
      and trigger_info.tgname = 'prevent_same_solo_game_rebooking'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Cancelled solo bookings can still poison a same-game rebooking attendance row.';
  end if;

  if not exists (
    select 1
    from cron.job job
    where job.jobname = 'finalize-field-reliability-attendance'
      and job.schedule = '* * * * *'
  ) then
    raise exception 'The minute-by-minute solo attendance finalizer is missing.';
  end if;

  if has_function_privilege(
      'anon', 'public.get_match_reliability_context(text,uuid)', 'EXECUTE'
    )
    or not has_function_privilege(
      'authenticated', 'public.get_match_reliability_context(text,uuid)', 'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.admin_publish_reliability_policy(uuid,uuid,text)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'service_role',
      'public.admin_publish_reliability_policy(uuid,uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.apply_policy_field_cancellation(uuid,text,uuid,text)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'service_role',
      'public.apply_policy_field_cancellation(uuid,text,uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.preview_open_queue_booking_cost(uuid,text)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'authenticated',
      'public.preview_open_queue_booking_cost(uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.preview_clan_fixture_cancellation(uuid)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'authenticated',
      'public.preview_clan_fixture_cancellation(uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.clan_fixture_cancellation_quote(uuid,uuid,timestamptz)',
      'EXECUTE'
    )
  then
    raise exception 'Reliability RPC grants do not match the security contract.';
  end if;
end;
$verify$;

rollback;
