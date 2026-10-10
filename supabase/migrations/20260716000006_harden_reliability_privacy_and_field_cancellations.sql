-- Final reliability hardening for the first policy-backed release.
--
-- 1. Policy fields without an authoritative runtime workflow are held at the
--    Season Zero defaults. A later migration can relax this constraint when
--    the corresponding reserve/clan billing workflow ships.
-- 2. Player-facing match context exposes clocks only. Individual attendance
--    and reliability outcomes are restricted to the assigned referee/admin
--    service path.
-- 3. Field/admin-caused cancellations use the match's snapshotted policy,
--    append compensating reliability records, and credit Field Wallet exactly
--    once. Existing historical matches are not backfilled or rewritten.

create or replace function public.reliability_policy_release_controls_are_valid(
  config_to_check jsonb
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return
    (config_to_check #>> '{solo,playersPerSide}')::integer = 6
    and (config_to_check #>> '{clan,playersPerSide}')::integer = 7
    and (config_to_check #>> '{solo,outcomes,fieldCancelled,strikes}')::integer = 0
    and (config_to_check #>> '{replacement,reserveActivationMinutesAfterKickoff}')::integer = 10
    and (config_to_check #>> '{replacement,originalPlayerReclaimUntilMinutesAfterKickoff}')::integer = 10
    and config_to_check #> '{replacement,order}' =
      '["EMERGENCY_NOTIFICATION","ON_FIELD_RESERVE","PLAY_SHORTHANDED"]'::jsonb
    and (config_to_check #>> '{injury,strikeDelta}')::integer = 0
    and (config_to_check #>> '{injury,requiresRefereeVerification}')::boolean
      is true
    and not (config_to_check #>>
      '{appeals,routineTrafficAutomaticallyExcused}')::boolean
    and config_to_check #> '{clan,cancellations}' =
      '{
        "early":{"minimumHoursBeforeKickoff":24,"strikes":0,"refundBps":10000},
        "late":{"minimumHoursBeforeKickoff":10,"strikes":1,"refundBps":5000},
        "veryLate":{"strikes":2,"refundBps":0},
        "afterKickoff":{"strikes":2,"refundBps":0,"forfeit":true}
      }'::jsonb
    and config_to_check #> '{clan,reliabilityDeposit}' =
      '{
        "activeStrikeThreshold":2,
        "depositBps":2000,
        "forfeitOutcomes":[
          "PARTIAL_LATE","FORFEIT","ENTIRE_CLAN_NO_SHOW",
          "CANCELLED_LATE","CANCELLED_VERY_LATE","NO_SHOW"
        ]
      }'::jsonb;
exception
  when others then
    return false;
end;
$$;

alter table public.reliability_policy_versions
drop constraint if exists reliability_policy_release_controls_check;
alter table public.reliability_policy_versions
add constraint reliability_policy_release_controls_check
check (public.reliability_policy_release_controls_are_valid(config));

revoke all on function public.reliability_policy_release_controls_are_valid(jsonb)
from public, anon, authenticated;
grant execute on function public.reliability_policy_release_controls_are_valid(jsonb)
to service_role;

create or replace function public.get_match_reliability_context(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  caller_id uuid := auth.uid();
  request_role text := coalesce(
    auth.role(),
    current_setting('request.jwt.claim.role', true),
    ''
  );
  can_view_roster boolean := false;
  viewer_is_participant boolean := false;
  terms_to_use public.match_reliability_terms%rowtype;
  server_now_to_use timestamptz := clock_timestamp();
  unresolved_count integer;
  no_show_count integer;
  expected_count_to_use integer;
  checked_in_count_to_use integer;
  on_time_count_to_use integer;
  late_count_to_use integer;
  players_to_use jsonb := '[]'::jsonb;
begin
  if normalized_kind not in ('SOLO', 'CLAN') then
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;
  if caller_id is null and request_role <> 'service_role' then
    raise exception 'You need to sign in again.';
  end if;

  can_view_roster := request_role = 'service_role'
    or (
      caller_id is not null
      and public.referee_can_manage_reliability_match(
        caller_id,
        normalized_kind,
        match_id_to_use
      )
    );

  select * into terms_to_use
  from public.match_reliability_terms terms
  where (
    normalized_kind = 'SOLO'
    and terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = match_id_to_use
  ) or (
    normalized_kind = 'CLAN'
    and terms.match_kind = 'CLAN'
    and terms.fixture_id = match_id_to_use
  );

  if terms_to_use.id is null then
    terms_to_use := public.ensure_match_reliability_terms(
      normalized_kind,
      match_id_to_use
    );
  end if;

  if normalized_kind = 'SOLO' then
    select exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.profile_id = caller_id
        and booking.status = 'CONFIRMED'
    ) into viewer_is_participant;
  else
    select exists (
      select 1
      from public.fixture_reliability_roster_history roster
      where roster.fixture_id = match_id_to_use
        and roster.profile_id = caller_id
        and roster.status = 'CONFIRMED'
    ) into viewer_is_participant;
  end if;

  if can_view_roster then
    perform public.ensure_match_attendance_records(
      normalized_kind,
      match_id_to_use
    );
    if normalized_kind = 'CLAN' then
      perform public.initialize_fixture_reliability_roster(match_id_to_use);
    end if;

    select
      count(*) filter (where attendance.outcome is null)::integer,
      count(*) filter (where attendance.outcome = 'NO_SHOW')::integer,
      count(*)::integer,
      count(*) filter (
        where attendance.checked_in_at is not null
      )::integer,
      count(*) filter (where attendance.outcome = 'ON_TIME')::integer,
      count(*) filter (where attendance.outcome = 'LATE')::integer
    into
      unresolved_count,
      no_show_count,
      expected_count_to_use,
      checked_in_count_to_use,
      on_time_count_to_use,
      late_count_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.expected_for_match
      and coalesce(attendance.outcome, '') not in (
        'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
      );

    select coalesce(jsonb_agg(
      jsonb_build_object(
        'attendance_record_id', attendance.id,
        'profile_id', attendance.profile_id,
        'display_name', profile.display_name,
        'team_id', coalesce(attendance.clan_id::text, attendance.side),
        'team_name', coalesce(clan.name, attendance.side),
        'side', attendance.side,
        'role', attendance.role,
        'checked_in_at', attendance.checked_in_at,
        'outcome', attendance.outcome,
        'status', case
          when attendance.outcome = 'ON_TIME' then 'ON_TIME'
          when attendance.outcome = 'LATE' then 'LATE'
          when attendance.outcome = 'NO_SHOW' then 'NO_SHOW'
          when attendance.outcome in ('EXCUSED', 'FIELD_CANCELLED') then 'EXCUSED'
          when attendance.checked_in_at is not null then 'CHECKED_IN'
          else 'MISSING'
        end,
        'is_checked_in', attendance.checked_in_at is not null
      ) order by attendance.side, profile.display_name, attendance.profile_id
    ), '[]'::jsonb) into players_to_use
    from public.match_attendance_records attendance
    join public.profiles profile on profile.id = attendance.profile_id
    left join public.clans clan on clan.id = attendance.clan_id
    where attendance.terms_id = terms_to_use.id
      and attendance.expected_for_match
      and coalesce(attendance.outcome, '') not in (
        'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
      );
  end if;

  return jsonb_build_object(
    'server_now', server_now_to_use,
    'policy_version_id', terms_to_use.policy_version_id,
    'kickoff_at', terms_to_use.kickoff_at,
    'check_in_opens_at', terms_to_use.check_in_opens_at,
    'check_in_deadline_at', terms_to_use.check_in_deadline_at,
    'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
    'can_check_in',
      server_now_to_use >= terms_to_use.check_in_opens_at
      and server_now_to_use < terms_to_use.no_show_cutoff_at,
    'can_finalize_attendance', case when can_view_roster
      then server_now_to_use >= terms_to_use.no_show_cutoff_at
        and coalesce(unresolved_count, 0) > 0
      else false
    end,
    'attendance_finalized', case when can_view_roster
      then coalesce(unresolved_count, 0) = 0
      else null
    end,
    'expected_count', case when can_view_roster
      then expected_count_to_use else null end,
    'checked_in_count', case when can_view_roster
      then checked_in_count_to_use else null end,
    'on_time_count', case when can_view_roster
      then on_time_count_to_use else null end,
    'late_count', case when can_view_roster
      then late_count_to_use else null end,
    'missing_count', case when not can_view_roster then null
      when unresolved_count = 0 then no_show_count
      else unresolved_count
    end,
    'players', players_to_use,
    'viewer_scope', case when can_view_roster
      then 'MATCH_OFFICIAL' else 'TIMING_ONLY' end,
    'viewer_is_participant', viewer_is_participant
  );
end;
$$;

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

create or replace function public.reverse_match_reliability_incidents_for_field_cancel(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  reason_to_use text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  original_incident public.reliability_incidents%rowtype;
  active_before integer;
  active_after integer;
  reversed_count integer := 0;
begin
  for original_incident in
    select incident.*
    from public.reliability_incidents incident
    left join public.match_attendance_records attendance
      on attendance.id = incident.attendance_id
    left join public.open_queue_bookings booking
      on booking.id = attendance.booking_id
    where incident.reversal_of is null
      and incident.strike_delta > 0
      and not exists (
        select 1
        from public.reliability_incidents reversal
        where reversal.reversal_of = incident.id
      )
      and (
        (
          normalized_kind = 'SOLO'
          and attendance.open_queue_game_id = match_id_to_use
          and attendance.expected_for_match
          and booking.status = 'CONFIRMED'
        )
        or (
          normalized_kind = 'CLAN'
          and (
            (
              attendance.fixture_id = match_id_to_use
              and attendance.expected_for_match
            )
            or (
              incident.subject_type = 'CLAN'
              and (
                incident.fixture_id = match_id_to_use
                or incident.detail ->> 'fixture_id' = match_id_to_use::text
              )
            )
          )
        )
      )
    order by incident.occurred_at, incident.id
    for update of incident
  loop
    if original_incident.subject_type = 'PLAYER' then
      perform pg_advisory_xact_lock(
        hashtextextended(original_incident.profile_id::text, 9174)
      );
      active_before := public.active_reliability_strikes(
        original_incident.profile_id,
        clock_timestamp()
      );
    else
      perform pg_advisory_xact_lock(
        hashtextextended(original_incident.clan_id::text, 9175)
      );
      active_before := public.active_clan_reliability_strikes(
        original_incident.clan_id,
        clock_timestamp()
      );
    end if;
    active_after := greatest(
      0,
      active_before - original_incident.strike_delta
    );

    insert into public.reliability_incidents (
      subject_type,
      profile_id,
      clan_id,
      attendance_id,
      booking_id,
      fixture_id,
      outcome,
      strike_delta,
      occurred_at,
      expires_at,
      policy_version_id,
      reversal_of,
      active_count_before,
      active_count_after,
      detail
    ) values (
      original_incident.subject_type,
      original_incident.profile_id,
      original_incident.clan_id,
      original_incident.attendance_id,
      original_incident.booking_id,
      original_incident.fixture_id,
      'FIELD_CANCELLED',
      -original_incident.strike_delta,
      clock_timestamp(),
      original_incident.expires_at,
      original_incident.policy_version_id,
      original_incident.id,
      active_before,
      active_after,
      jsonb_build_object(
        'match_kind', normalized_kind,
        'match_id', match_id_to_use,
        'cancelled_by', actor_admin_id,
        'reason', trim(reason_to_use)
      )
    ) on conflict do nothing;

    if found then
      reversed_count := reversed_count + 1;
    end if;

    update public.reliability_sanctions sanction
    set
      revoked_at = coalesce(sanction.revoked_at, clock_timestamp()),
      revoked_by = case when sanction.revoked_at is null
        then actor_admin_id else sanction.revoked_by end,
      revocation_reason = case when sanction.revoked_at is null
        then 'Match cancelled by Field: ' || trim(reason_to_use)
        else sanction.revocation_reason end
    where sanction.incident_id = original_incident.id
      and sanction.revoked_at is null;
  end loop;

  return reversed_count;
end;
$$;

create or replace function public.apply_policy_field_cancellation(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  terms_to_use public.match_reliability_terms%rowtype;
  policy_applies boolean := false;
  kickoff_to_use timestamptz;
  cancellation_at timestamptz := clock_timestamp();
  refund_bps_to_use integer := 0;
  reversed_count integer := 0;
  affected_count integer := 0;
  attendance_to_cancel public.match_attendance_records%rowtype;
  booking_to_cancel public.open_queue_bookings%rowtype;
  target_fee_refund_fils integer;
  target_deposit_refund_fils integer;
  target_total_refund_fils integer;
  corrected_total_refund_fils integer;
  current_total_refund_fils integer;
  current_deposit_refund_fils integer;
  current_fee_refund_fils integer;
  missing_fee_refund_fils integer;
  missing_deposit_refund_fils integer;
begin
  if normalized_kind = 'SOLO' then
    select game.starts_at into kickoff_to_use
    from public.open_queue_games game
    where game.id = match_id_to_use;
  elsif normalized_kind = 'CLAN' then
    select public.fixture_start_at(fixture.match_date, fixture.time_slot)
    into kickoff_to_use
    from public.fixtures fixture
    where fixture.id = match_id_to_use;
  else
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where (
    normalized_kind = 'SOLO'
    and terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = match_id_to_use
  ) or (
    normalized_kind = 'CLAN'
    and terms.match_kind = 'CLAN'
    and terms.fixture_id = match_id_to_use
  );

  if terms_to_use.id is null and exists (
    select 1
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from <= kickoff_to_use
  ) then
    terms_to_use := public.ensure_match_reliability_terms(
      normalized_kind,
      match_id_to_use
    );
  end if;

  if terms_to_use.id is null then
    return jsonb_build_object(
      'policy_applied', false,
      'affected_count', 0,
      'reversed_incident_count', 0
    );
  end if;

  select exists (
    select 1
    from public.reliability_policy_versions policy
    where policy.id = terms_to_use.policy_version_id
      and policy.effective_from <= terms_to_use.kickoff_at
  ) into policy_applies;
  if not policy_applies then
    return jsonb_build_object(
      'policy_applied', false,
      'affected_count', 0,
      'reversed_incident_count', 0
    );
  end if;

  perform public.ensure_match_attendance_records(
    normalized_kind,
    match_id_to_use
  );
  if normalized_kind = 'CLAN' then
    perform public.initialize_fixture_reliability_roster(match_id_to_use);
  end if;

  reversed_count := public.reverse_match_reliability_incidents_for_field_cancel(
    actor_admin_id,
    normalized_kind,
    match_id_to_use,
    reason_to_use
  );

  if normalized_kind = 'SOLO' then
    refund_bps_to_use := (terms_to_use.policy_snapshot #>>
      '{solo,outcomes,fieldCancelled,refundBps}')::integer;

    for booking_to_cancel in
      select booking.*
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.status = 'CONFIRMED'
      order by booking.id
      for update
    loop
      select * into attendance_to_cancel
      from public.match_attendance_records attendance
      where attendance.terms_id = terms_to_use.id
        and attendance.booking_id = booking_to_cancel.id
        and attendance.expected_for_match
      for update;
      if attendance_to_cancel.id is null then
        continue;
      end if;

      target_fee_refund_fils := (
        booking_to_cancel.base_amount_fils::bigint
          * refund_bps_to_use / 10000
      )::integer;
      target_deposit_refund_fils :=
        booking_to_cancel.reliability_deposit_fils;
      target_total_refund_fils := target_fee_refund_fils
        + target_deposit_refund_fils;
      current_total_refund_fils := greatest(
        0,
        coalesce(booking_to_cancel.refund_amount_fils, 0),
        coalesce(attendance_to_cancel.refund_amount_fils, 0)
      );
      corrected_total_refund_fils := greatest(
        current_total_refund_fils,
        target_total_refund_fils
      );
      current_deposit_refund_fils := case
        when attendance_to_cancel.deposit_resolution = 'RETURNED'
          or booking_to_cancel.reliability_deposit_status in (
            'RETURNED', 'REFUNDED'
          )
        then least(
          target_deposit_refund_fils,
          current_total_refund_fils
        )
        else 0
      end;
      current_fee_refund_fils := least(
        target_fee_refund_fils,
        greatest(0, current_total_refund_fils - current_deposit_refund_fils)
      );
      missing_fee_refund_fils := greatest(
        0,
        target_fee_refund_fils - current_fee_refund_fils
      );
      missing_deposit_refund_fils := case
        when target_deposit_refund_fils > 0
          and attendance_to_cancel.deposit_resolution <> 'RETURNED'
          and booking_to_cancel.reliability_deposit_status not in (
            'RETURNED', 'REFUNDED'
          )
        then target_deposit_refund_fils
        else 0
      end;

      if missing_fee_refund_fils > 0 then
        perform public.credit_field_wallet(
          booking_to_cancel.profile_id,
          missing_fee_refund_fils,
          'FIELD_CANCELLATION_REFUND',
          'field-cancel-fee:' || attendance_to_cancel.id::text,
          'Policy-based refund after Field cancelled the match.',
          attendance_to_cancel.policy_version_id,
          booking_to_cancel.id,
          null,
          jsonb_build_object(
            'attendance_id', attendance_to_cancel.id,
            'refund_bps', refund_bps_to_use,
            'match_id', match_id_to_use
          )
        );
      end if;
      if missing_deposit_refund_fils > 0 then
        perform public.credit_field_wallet(
          booking_to_cancel.profile_id,
          missing_deposit_refund_fils,
          'RELIABILITY_DEPOSIT_RETURN',
          'field-cancel-deposit:' || attendance_to_cancel.id::text,
          'Reliability deposit returned after Field cancelled the match.',
          attendance_to_cancel.policy_version_id,
          booking_to_cancel.id,
          null,
          jsonb_build_object(
            'attendance_id', attendance_to_cancel.id,
            'match_id', match_id_to_use
          )
        );
      end if;

      update public.match_attendance_records attendance
      set
        cancelled_at = cancellation_at,
        outcome = 'FIELD_CANCELLED',
        strike_delta = 0,
        refund_bps = greatest(attendance.refund_bps, refund_bps_to_use),
        refund_amount_fils = greatest(
          attendance.refund_amount_fils,
          corrected_total_refund_fils
        ),
        deposit_resolution = case
          when attendance.reliability_deposit_fils > 0 then 'RETURNED'
          else attendance.deposit_resolution
        end,
        positive_sr_multiplier_bps = 10000,
        negative_sr_multiplier_bps = 10000,
        finalized_at = cancellation_at,
        consequence_snapshot = attendance.consequence_snapshot ||
          jsonb_build_object(
            'outcome_code', 'FIELD_CANCELLED',
            'policy_version_id', terms_to_use.policy_version_id,
            'refund_bps', refund_bps_to_use,
            'cancelled_by', actor_admin_id,
            'reason', trim(reason_to_use)
          )
      where attendance.id = attendance_to_cancel.id;

      update public.open_queue_bookings booking
      set
        status = 'CANCELLED',
        team = null,
        played = false,
        rating_at_team_assignment = null,
        rating_at_match_start = null,
        rating_change = null,
        cancelled_at = cancellation_at,
        refund_bps = greatest(
          coalesce(booking.refund_bps, 0),
          refund_bps_to_use
        ),
        refund_percent = round(greatest(
          coalesce(booking.refund_bps, 0),
          refund_bps_to_use
        ) / 100.0)::integer,
        refund_amount_fils = greatest(
          coalesce(booking.refund_amount_fils, 0),
          corrected_total_refund_fils
        ),
        refund_status = case when corrected_total_refund_fils > 0
          then 'PROCESSED' else 'NOT_DUE' end,
        payment_status = case
          when booking.amount_paid_fils > 0
            and corrected_total_refund_fils >= booking.amount_paid_fils
            then 'REFUNDED'
          when corrected_total_refund_fils > 0 then 'PARTIALLY_REFUNDED'
          else 'NO_REFUND'
        end,
        reliability_deposit_status = case
          when booking.reliability_deposit_fils > 0 then 'RETURNED'
          else booking.reliability_deposit_status
        end
      where booking.id = booking_to_cancel.id;

      insert into public.attendance_events (
        attendance_id,
        event_type,
        actor_referee_id,
        event_at,
        detail,
        idempotency_key
      ) values (
        attendance_to_cancel.id,
        'ADMIN_CORRECTION',
        actor_admin_id,
        cancellation_at,
        jsonb_build_object(
          'source', 'FIELD_CANCELLATION',
          'previous_outcome', attendance_to_cancel.outcome,
          'corrected_outcome', 'FIELD_CANCELLED',
          'refund_bps', refund_bps_to_use,
          'refund_amount_fils', corrected_total_refund_fils,
          'reason', trim(reason_to_use)
        ),
        'field-cancelled:' || attendance_to_cancel.id::text
      ) on conflict (idempotency_key) do nothing;

      affected_count := affected_count + 1;
    end loop;
  else
    for attendance_to_cancel in
      select attendance.*
      from public.match_attendance_records attendance
      where attendance.terms_id = terms_to_use.id
        and attendance.expected_for_match
      order by attendance.id
      for update
    loop
      update public.match_attendance_records attendance
      set
        cancelled_at = cancellation_at,
        outcome = 'FIELD_CANCELLED',
        strike_delta = 0,
        refund_bps = 0,
        refund_amount_fils = 0,
        positive_sr_multiplier_bps = 10000,
        negative_sr_multiplier_bps = 10000,
        finalized_at = cancellation_at,
        consequence_snapshot = attendance.consequence_snapshot ||
          jsonb_build_object(
            'outcome_code', 'FIELD_CANCELLED',
            'policy_version_id', terms_to_use.policy_version_id,
            'cancelled_by', actor_admin_id,
            'reason', trim(reason_to_use)
          )
      where attendance.id = attendance_to_cancel.id;

      insert into public.attendance_events (
        attendance_id,
        event_type,
        actor_referee_id,
        event_at,
        detail,
        idempotency_key
      ) values (
        attendance_to_cancel.id,
        'ADMIN_CORRECTION',
        actor_admin_id,
        cancellation_at,
        jsonb_build_object(
          'source', 'FIELD_CANCELLATION',
          'previous_outcome', attendance_to_cancel.outcome,
          'corrected_outcome', 'FIELD_CANCELLED',
          'reason', trim(reason_to_use)
        ),
        'field-cancelled:' || attendance_to_cancel.id::text
      ) on conflict (idempotency_key) do nothing;

      affected_count := affected_count + 1;
    end loop;
  end if;

  update public.reliability_appeals appeal
  set
    status = 'OVERTURNED',
    reviewed_by = actor_admin_id,
    reviewed_at = cancellation_at,
    resolution_note = 'The match was cancelled by Field: ' ||
      left(trim(reason_to_use), 1950)
  where appeal.status in ('OPEN', 'REVIEWING')
    and exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.id = appeal.attendance_id
        and attendance.terms_id = terms_to_use.id
        and attendance.outcome = 'FIELD_CANCELLED'
    );

  return jsonb_build_object(
    'policy_applied', true,
    'policy_version_id', terms_to_use.policy_version_id,
    'refund_bps', case when normalized_kind = 'SOLO'
      then refund_bps_to_use else null end,
    'affected_count', affected_count,
    'reversed_incident_count', reversed_count
  );
end;
$$;

create or replace function public.admin_cancel_match(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_cancel uuid,
  reason_code_to_use text,
  reason_to_use text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_code text := upper(trim(coalesce(reason_code_to_use, '')));
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  fixture_before public.fixtures%rowtype;
  game_before public.open_queue_games%rowtype;
  reliability_result jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if char_length(normalized_reason) < 5 then
    raise exception 'Add a clear cancellation reason.';
  end if;
  if normalized_code not in (
    'WEATHER_OR_VENUE', 'SAFETY', 'NO_REFEREE',
    'INSUFFICIENT_PLAYERS', 'TECHNICAL', 'ADMIN_DECISION', 'OTHER'
  ) then
    raise exception 'Choose a valid cancellation reason.';
  end if;

  if normalized_kind = 'CLAN' then
    select * into fixture_before
    from public.fixtures fixture
    where fixture.id = match_id_to_cancel
    for update;
    if fixture_before.id is null then
      raise exception 'Match not found.';
    end if;
    if fixture_before.status = 'FINAL' then
      raise exception 'Final matches cannot be cancelled. Correct the official score instead.';
    end if;
    if fixture_before.status = 'CANCELLED' then
      raise exception 'This match is already cancelled.';
    end if;

    reliability_result := public.apply_policy_field_cancellation(
      actor_admin_id,
      'CLAN',
      match_id_to_cancel,
      normalized_reason
    );

    update public.fixtures
    set
      status = 'CANCELLED',
      cancellation_code = case
        when normalized_code = 'OTHER' then 'ADMIN_CANCELLED'
        else normalized_code
      end,
      cancellation_reason = normalized_reason,
      cancelled_at = clock_timestamp(),
      cancelled_by = actor_admin_id,
      cancellation_context = jsonb_build_object(
        'source', 'ADMIN_PANEL',
        'previous_status', fixture_before.status,
        'reliability', reliability_result
      )
    where id = match_id_to_cancel;

    update public.fixture_clock_states
    set status = 'ENDED', started_at = null
    where fixture_id = match_id_to_cancel;
    update public.fixture_blue_cards
    set status = 'CLEARED'
    where fixture_id = match_id_to_cancel and status = 'ACTIVE';
  else
    select * into game_before
    from public.open_queue_games game
    where game.id = match_id_to_cancel
    for update;
    if game_before.id is null then
      raise exception 'Solo match not found.';
    end if;
    if game_before.status = 'FINAL' then
      raise exception 'Final matches cannot be cancelled. Correct the official score instead.';
    end if;
    if game_before.status = 'CANCELLED' then
      raise exception 'This match is already cancelled.';
    end if;

    reliability_result := public.apply_policy_field_cancellation(
      actor_admin_id,
      'SOLO',
      match_id_to_cancel,
      normalized_reason
    );

    update public.open_queue_games
    set
      status = 'CANCELLED',
      cancellation_code = normalized_code,
      cancellation_reason = normalized_reason,
      cancelled_at = clock_timestamp(),
      cancelled_by = actor_admin_id,
      cancellation_context = jsonb_build_object(
        'source', 'ADMIN_PANEL',
        'previous_status', game_before.status,
        'reliability', reliability_result
      )
    where id = match_id_to_cancel;

    -- Pre-policy matches retain the legacy projection. No historical match is
    -- automatically backfilled or credited by this migration.
    if not coalesce(
      (reliability_result ->> 'policy_applied')::boolean,
      false
    ) then
      update public.open_queue_bookings
      set
        status = 'CANCELLED',
        team = null,
        played = false,
        rating_at_team_assignment = null,
        rating_at_match_start = null,
        rating_change = null,
        cancelled_at = clock_timestamp(),
        refund_percent = 100,
        refund_amount_fils = amount_paid_fils,
        refund_status = 'PROCESSED',
        payment_status = 'REFUNDED'
      where game_id = match_id_to_cancel
        and status = 'CONFIRMED';
    end if;

    update public.open_queue_clock_states
    set status = 'ENDED', started_at = null
    where game_id = match_id_to_cancel;
    update public.open_queue_blue_cards
    set status = 'CLEARED'
    where game_id = match_id_to_cancel and status = 'ACTIVE';
  end if;

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state
  ) values (
    actor_admin_id,
    'MATCH_CANCELLED',
    case when normalized_kind = 'CLAN'
      then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_cancel,
    normalized_reason,
    case when normalized_kind = 'CLAN'
      then to_jsonb(fixture_before) else to_jsonb(game_before) end,
    jsonb_build_object(
      'status', 'CANCELLED',
      'reason_code', normalized_code,
      'reliability', reliability_result
    )
  );
end;
$$;

revoke all on function public.reverse_match_reliability_incidents_for_field_cancel(
  uuid,text,uuid,text
) from public, anon, authenticated;
grant execute on function public.reverse_match_reliability_incidents_for_field_cancel(
  uuid,text,uuid,text
) to service_role;

revoke all on function public.apply_policy_field_cancellation(
  uuid,text,uuid,text
) from public, anon, authenticated;
grant execute on function public.apply_policy_field_cancellation(
  uuid,text,uuid,text
) to service_role;

revoke all on function public.admin_cancel_match(uuid,text,uuid,text,text)
from public, anon, authenticated;
grant execute on function public.admin_cancel_match(uuid,text,uuid,text,text)
to service_role;
