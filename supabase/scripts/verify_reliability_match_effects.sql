begin;

do $verify$
declare
  function_text text;
  trigger_text text;
begin
  if to_regclass('public.fixture_reliability_roster_history') is null
    or to_regclass('public.match_shorthanded_periods') is null
    or to_regclass('public.match_verified_injuries') is null
    or to_regclass('public.clan_match_reliability_outcomes') is null
  then
    raise exception 'One or more reliability match-effect ledgers are missing.';
  end if;

  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid =
        'public.fixture_reliability_roster_history'::regclass
      and trigger_info.tgname =
        'protect_fixture_reliability_roster_history'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Fixture reliability roster history is not protected.';
  end if;
  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.reliability_sanctions'::regclass
      and trigger_info.tgname = 'release_clan_rosters_on_player_suspension'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Player suspensions do not release future clan rosters.';
  end if;

  select pg_get_functiondef(
    'public.release_suspended_player_future_clan_rosters(uuid,uuid,timestamptz)'::regprocedure
  ) into function_text;
  if position('terms.check_in_deadline_at > clock_timestamp()' in function_text) = 0
    or position('sync_fixture_reliability_expected_roster' in function_text) = 0
    or position('CLAN_ROSTER_PLACE_RELEASED' in function_text) = 0
  then
    raise exception 'Suspended-player roster release is not deadline-safe or auditable.';
  end if;

  select pg_get_functiondef(
    'public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure
  ) into function_text;
  if position('attendance.expected_for_match' in function_text) = 0 then
    raise exception 'Clan attendance finalization can still strike bench members.';
  end if;

  select pg_get_functiondef(
    'public.finalize_clan_reliability_outcomes(uuid,uuid)'::regprocedure
  ) into function_text;
  if position('count(*) filter (where attendance.expected_for_match)' in function_text) = 0
    or position('and attendance.expected_for_match;' in function_text) > 0
  then
    raise exception 'Clan readiness ignores referee-confirmed substitute attendance.';
  end if;

  select pg_get_functiondef(
    'public.apply_open_queue_player_ratings_on_final()'::regprocedure
  ) into trigger_text;
  if position('finalize_match_attendance_internal' in trigger_text) = 0
    or position('finalize_match_attendance_internal' in trigger_text)
      > position('apply_open_queue_player_ratings(new.id)' in trigger_text)
  then
    raise exception 'Solo no-shows are not finalized before the base SR ledger.';
  end if;

  select pg_get_functiondef(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure
  ) into function_text;
  if position('period.started_match_second between 0 and 30' in function_text) = 0
    or position('coalesce(period.ended_match_second, match_seconds)' in function_text) = 0
    or position('base_amount_fils::bigint * injury_refund_bps' in function_text) = 0
    or position('policy_effective_from > game_to_apply.starts_at' in function_text) = 0
  then
    raise exception 'SR protection/refund logic is missing an audited safeguard.';
  end if;

  select pg_get_functiondef(
    'public.apply_clan_reliability_rating_adjustments(uuid)'::regprocedure
  ) into function_text;
  if position('attendance.positive_sr_multiplier_bps' in function_text) = 0
    or position('attendance.negative_sr_multiplier_bps' in function_text) = 0
    or position('SHORTHANDED_TEAM' in function_text) = 0
    or position('VERIFIED_INJURY' in function_text) = 0
    or position('terms_to_use.policy_snapshot' in function_text) = 0
  then
    raise exception 'Clan Player SR does not consume the snapshotted reliability outcomes.';
  end if;
  select pg_get_functiondef(
    'public.apply_clan_fixture_player_ratings()'::regprocedure
  ) into function_text;
  if position('reliability_forfeit_without_play' in function_text) = 0 then
    raise exception 'Unplayed clan forfeits can still create base Player SR.';
  end if;

  select pg_get_functiondef(
    'public.enforce_clan_reliability_final_cutoff()'::regprocedure
  ) into function_text;
  if position('terms_to_use.no_show_cutoff_at' in function_text) = 0
    or position('reliability_forfeit_without_play' in function_text) = 0
  then
    raise exception 'Ordinary clan fixtures can finalize before attendance is authoritative.';
  end if;
  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname = 'enforce_clan_reliability_final_cutoff'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan FINAL cutoff enforcement trigger is missing.';
  end if;

  select pg_get_functiondef(
    'public.cancel_clan_fixture_booking(uuid,text)'::regprocedure
  ) into function_text;
  if position('set played = false' in function_text) = 0
    or position('reliability_forfeit_without_play' in function_text) = 0
    or position('set played = false' in function_text) >
      position('reliability_forfeit_without_play' in function_text)
  then
    raise exception 'Clan cancellation forfeits are not Player-SR safe.';
  end if;

  select pg_get_functiondef(
    'public.settle_clan_reliability_deposit_from_outcome()'::regprocedure
  ) into function_text;
  if position('fixture_to_settle.status <> ''FINAL''' in function_text) = 0
    or position('RELIABILITY_DEPOSIT_RETURN' in function_text) = 0
  then
    raise exception 'Clan deposits can return before a LIVE match is safely complete.';
  end if;

  select pg_get_functiondef(
    'public.settle_completed_clan_fixture_finance()'::regprocedure
  ) into function_text;
  if position('select * into fixture_to_settle' in function_text) = 0
    or position('fixture_to_settle.home_deposit_status' in function_text) = 0
    or position('fixture_to_settle.away_deposit_status' in function_text) = 0
    or position('clan_fixture_cancellations' in function_text) = 0
  then
    raise exception 'Completed clan deposit settlement is stale or cancellation-unsafe.';
  end if;
  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname = 'a_settle_completed_clan_fixture_finance'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan attendance/finance does not settle before Player SR.';
  end if;

  select pg_get_functiondef(
    'public.finalize_due_clan_reliability_attendance()'::regprocedure
  ) into function_text;
  if position('''FINAL''' in function_text) = 0
    or position('reliability_forfeit_without_play' in function_text) = 0
    or position('clan_fixture_cancellations' in function_text) = 0
  then
    raise exception 'Historical FINAL clan attendance cannot settle safely at cutoff.';
  end if;
  if not exists (
    select 1
    from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname = 'apply_clan_reliability_ratings_on_final'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan reliability Player SR finalization trigger is missing.';
  end if;

  select pg_get_functiondef(
    'public.referee_report_clan_forfeit(uuid,uuid,uuid,text,text,text,text,integer)'::regprocedure
  ) into function_text;
  if position('field.pending_clan_forfeit_fixture_id' in function_text) = 0
    or position('set_config' in function_text) = 0
  then
    raise exception 'A provisional clan forfeit is not marked before ABANDON.';
  end if;

  select pg_get_functiondef(
    'public.settle_field_cancelled_clan_fixture()'::regprocedure
  ) into function_text;
  if position('field.pending_clan_forfeit_fixture_id' in function_text) = 0
    or position('current_setting' in function_text) = 0
  then
    raise exception 'Provisional clan forfeits can still receive an early Field refund.';
  end if;

  select pg_get_functiondef(
    'public.admin_review_clan_forfeit(uuid,uuid,text,text)'::regprocedure
  ) into function_text;
  if position('settle_reviewed_clan_forfeit_reliability' in function_text) = 0
    or position('CLAN_SR_ONLY_NO_PLAYER_SR' in function_text) = 0
  then
    raise exception 'Clan forfeit review does not settle reliability before FINAL.';
  end if;

  select pg_get_functiondef(
    'public.settle_reviewed_clan_forfeit_reliability(uuid,uuid,boolean,text)'::regprocedure
  ) into function_text;
  if position('clan_fixture_cancellations' in function_text) = 0
    or position('afterKickoff' in function_text) = 0
    or position('reviewed-forfeit-opponent-fee:' in function_text) = 0
    or position('overturned-forfeit-fee:' in function_text) = 0
    or position('apply_policy_field_cancellation' in function_text) = 0
    or position('reliability_forfeit_without_play' in function_text) = 0
  then
    raise exception 'Reviewed clan forfeit finance is not complete or idempotent.';
  end if;

  select pg_get_functiondef(
    'public.settle_verified_early_injury_refunds(uuid,uuid,uuid)'::regprocedure
  ) into function_text;
  if position('target_fee_refund_fils' in function_text) = 0
    or position('target_deposit_refund_fils' in function_text) = 0
    or position('verified-injury-fee-refund:' in function_text) = 0
    or position('verified-injury-deposit-refund:' in function_text) = 0
    or position('target_total_refund_fils >= booking.amount_paid_fils' in function_text) = 0
  then
    raise exception 'Early verified-injury refunds do not separate fee and deposit.';
  end if;
  select pg_get_functiondef(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure
  ) into function_text;
  if position('settle_verified_early_injury_refunds' in function_text) = 0
    or position('''ON_TIME'', ''EXCUSED''' in function_text) = 0
  then
    raise exception 'The solo finalization path does not use corrected injury refunds.';
  end if;
  select pg_get_functiondef(
    'public.apply_clan_reliability_rating_adjustments(uuid)'::regprocedure
  ) into function_text;
  if position('''ON_TIME'', ''EXCUSED''' in function_text) = 0 then
    raise exception 'Pre-final approved clan appeals are not SR-neutral.';
  end if;
  if not exists (
    select 1
    from pg_constraint constraint_info
    where constraint_info.conrelid = 'public.player_rating_events'::regclass
      and constraint_info.conname =
        'player_rating_events_attendance_outcome_check'
      and position(
        'EXCUSED' in pg_get_constraintdef(constraint_info.oid)
      ) > 0
  ) then
    raise exception 'Player rating events reject approved pre-final appeals.';
  end if;

  select pg_get_functiondef(
    'public.clan_has_active_participation_suspension(uuid,timestamptz)'::regprocedure
  ) into function_text;
  if position('PARTICIPATION_SUSPENSION' in function_text) = 0
    or position('INDEFINITE_SUSPENSION' in function_text) = 0
    or position('BOOKING_RESTRICTION' in function_text) > 0
  then
    raise exception 'Clan start enforcement does not distinguish participation from booking restrictions.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname =
        'enforce_clan_participation_suspension_at_start'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan participation suspensions do not block fixture start.';
  end if;
  select pg_get_functiondef(
    'public.referee_start_fixture_atomic(uuid,uuid[],integer)'::regprocedure
  ) into function_text;
  if position('participant_clan.clan_id' in function_text) = 0
    or position('pg_advisory_xact_lock' in function_text) = 0
  then
    raise exception 'Fixture start can race an active clan suspension.';
  end if;
  select pg_get_functiondef(
    'public.release_suspended_clan_future_fixtures(uuid,uuid,timestamptz)'::regprocedure
  ) into function_text;
  if position('fixture.id is distinct from source_fixture_id' in function_text) = 0
    or position('clan_reliability_fixture_releases' in function_text) = 0
    or position('status = ''CANCELLED''' in function_text) = 0
    or position('ADMIN_CANCELLED' in function_text) = 0
  then
    raise exception 'Clan suspensions do not safely release unrelated future fixtures.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.reliability_sanctions'::regclass
      and trigger_info.tgname =
        'release_fixtures_on_clan_participation_suspension'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Clan participation sanctions do not trigger fixture release.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.fixtures'::regclass
      and trigger_info.tgname = 'settle_field_cancelled_clan_fixture'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Automatically released clan fixtures do not trigger full Field settlement.';
  end if;
  select pg_get_functiondef(
    'public.settle_field_cancelled_clan_fixture()'::regprocedure
  ) into function_text;
  if position('field-clan-cancel-fee:' in function_text) = 0
    or position('field-clan-cancel-deposit:' in function_text) = 0
    or position(
      'new.cancellation_code = ''CLAN_CANCELLED''' in function_text
    ) = 0
  then
    raise exception 'The clan Field-cancellation trigger does not fully and idempotently refund automatic releases.';
  end if;

  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public'
      and table_name = 'reliability_sr_appeal_adjustments'
  ) then
    raise exception 'Append-only appeal SR correction ledger is missing.';
  end if;
  select pg_get_functiondef(
    'public.apply_late_appeal_sr_correction(uuid,uuid,uuid)'::regprocedure
  ) into function_text;
  if position('pre_reliability_change' in function_text) = 0
    or position('neutral_multiplier_bps' in function_text) = 0
    or position('reliability_sr_appeal_adjustments' in function_text) = 0
    or position('rating_at_match_start' in function_text) = 0
    or position('shorthanded_side_count' in function_text) = 0
  then
    raise exception 'Post-final late appeals do not append a safe SR correction.';
  end if;
  select pg_get_functiondef(
    'public.reconcile_player_reliability_sanctions(uuid,uuid,uuid,text)'::regprocedure
  ) into function_text;
  if position('corrected_active_before' in function_text) = 0
    or position('reversal.reversal_of' in function_text) = 0
    or position('corrected_active_after >= sanction_to_check.threshold' in function_text) = 0
  then
    raise exception 'Appeal review does not reconcile downstream sanction thresholds.';
  end if;
  if not exists (
    select 1 from pg_trigger trigger_info
    where trigger_info.tgrelid = 'public.reliability_appeals'::regclass
      and trigger_info.tgname =
        'correct_overturned_reliability_appeal_effects'
      and not trigger_info.tgisinternal
  ) then
    raise exception 'Approved appeals do not trigger SR/sanction reconciliation.';
  end if;

  select pg_get_functiondef(
    'public.get_player_rating_history(uuid,integer)'::regprocedure
  ) into function_text;
  if position('reliability_multiplier_bps' in function_text) = 0
    or position('sr_protection_reason' in function_text) = 0
  then
    raise exception 'Player-facing SR history omits reliability audit fields.';
  end if;

  if not exists (
    select 1
    from cron.job job
    where job.jobname = 'finalize-field-clan-reliability-attendance'
      and job.schedule = '* * * * *'
  ) then
    raise exception 'Clan reliability attendance finalizer is missing.';
  end if;

  if has_function_privilege(
      'authenticated',
      'public.referee_record_verified_injury(uuid,text,uuid,uuid,boolean,boolean,boolean,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.settle_reviewed_clan_forfeit_reliability(uuid,uuid,boolean,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.settle_verified_early_injury_refunds(uuid,uuid,uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.apply_late_appeal_sr_correction(uuid,uuid,uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.reconcile_player_reliability_sanctions(uuid,uuid,uuid,text)',
      'EXECUTE'
    )
  then
    raise exception 'Private referee/reliability RPCs are exposed directly to app users.';
  end if;
end;
$verify$;

rollback;
