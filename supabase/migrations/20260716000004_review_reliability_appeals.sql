-- Audited reliability appeal review.
--
-- Appeal decisions never delete or rewrite the reliability ledger. An
-- overturn appends a compensating incident, revokes only sanctions produced
-- by the original incident, and credits any financial correction through the
-- idempotent Field Wallet ledger.

create or replace function public.admin_review_reliability_appeal(
  actor_admin_id uuid,
  appeal_id_to_review uuid,
  decision_to_use text,
  resolution_note_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_decision text := upper(trim(coalesce(decision_to_use, '')));
  normalized_note text := trim(coalesce(resolution_note_to_use, ''));
  final_status text;
  decision_at_to_use timestamptz := clock_timestamp();
  appeal_to_review public.reliability_appeals%rowtype;
  attendance_before public.match_attendance_records%rowtype;
  attendance_after public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  original_incident public.reliability_incidents%rowtype;
  reversal_incident_id uuid;
  booking_to_correct public.open_queue_bookings%rowtype;
  active_count_before_to_use integer := 0;
  active_count_after_to_use integer := 0;
  reversed_strikes integer := 0;
  revoked_sanction_count integer := 0;
  policy_refund_bps integer := 0;
  target_fee_refund_fils integer := 0;
  target_deposit_refund_fils integer := 0;
  current_total_refund_fils integer := 0;
  current_deposit_refund_fils integer := 0;
  current_fee_refund_fils integer := 0;
  missing_fee_refund_fils integer := 0;
  missing_deposit_refund_fils integer := 0;
  corrected_total_refund_fils integer := 0;
  wallet_adjustment_fils integer := 0;
  before_state_to_audit jsonb;
  after_state_to_audit jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if normalized_decision not in ('UPHOLD', 'OVERTURN') then
    raise exception 'Decision must be UPHOLD or OVERTURN.';
  end if;
  if char_length(normalized_note) not between 10 and 2000 then
    raise exception 'Record a clear 10 to 2,000 character review note.';
  end if;

  final_status := case normalized_decision
    when 'UPHOLD' then 'UPHELD'
    else 'OVERTURNED'
  end;

  select * into appeal_to_review
  from public.reliability_appeals appeal
  where appeal.id = appeal_id_to_review
  for update;

  if appeal_to_review.id is null then
    raise exception 'Reliability appeal not found.';
  end if;

  -- A retry of the same final decision is a no-op. A conflicting second
  -- decision must go through a separate, explicit admin correction workflow.
  if appeal_to_review.status in ('UPHELD', 'OVERTURNED') then
    if appeal_to_review.status <> final_status then
      raise exception 'This appeal already has a different final decision.';
    end if;

    select incident.id into reversal_incident_id
    from public.reliability_incidents incident
    where incident.reversal_of = appeal_to_review.incident_id;

    return jsonb_build_object(
      'appeal_id', appeal_to_review.id,
      'status', appeal_to_review.status,
      'reviewed_at', appeal_to_review.reviewed_at,
      'reviewed_by', appeal_to_review.reviewed_by,
      'reversal_incident_id', reversal_incident_id,
      'idempotent', true
    );
  end if;

  select * into attendance_before
  from public.match_attendance_records attendance
  where attendance.id = appeal_to_review.attendance_id
  for update;
  if attendance_before.id is null then
    raise exception 'Appealed attendance record not found.';
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = attendance_before.terms_id;
  if terms_to_use.id is null then
    raise exception 'The original reliability policy snapshot is unavailable.';
  end if;

  select * into original_incident
  from public.reliability_incidents incident
  where incident.id = appeal_to_review.incident_id
    and incident.attendance_id = attendance_before.id
    and incident.reversal_of is null;

  if original_incident.id is null then
    select * into original_incident
    from public.reliability_incidents incident
    where incident.attendance_id = attendance_before.id
      and incident.reversal_of is null
    order by incident.created_at, incident.id
    limit 1;
  end if;

  before_state_to_audit := jsonb_build_object(
    'appeal', to_jsonb(appeal_to_review),
    'attendance', to_jsonb(attendance_before),
    'incident', case when original_incident.id is null
      then null else to_jsonb(original_incident) end
  );

  if normalized_decision = 'OVERTURN' then
    if original_incident.id is null or original_incident.strike_delta <= 0 then
      raise exception 'The original strike incident is unavailable; no automatic reversal was made.';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(attendance_before.profile_id::text, 9174)
    );

    active_count_before_to_use := public.active_reliability_strikes(
      attendance_before.profile_id,
      decision_at_to_use
    );
    reversed_strikes := original_incident.strike_delta;
    active_count_after_to_use := greatest(
      0,
      active_count_before_to_use - reversed_strikes
    );

    select incident.id into reversal_incident_id
    from public.reliability_incidents incident
    where incident.reversal_of = original_incident.id;

    if reversal_incident_id is null then
      insert into public.reliability_incidents (
        subject_type,
        profile_id,
        clan_id,
        attendance_id,
        booking_id,
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
        'APPEAL_OVERTURNED',
        -reversed_strikes,
        decision_at_to_use,
        original_incident.expires_at,
        original_incident.policy_version_id,
        original_incident.id,
        active_count_before_to_use,
        active_count_after_to_use,
        jsonb_build_object(
          'appeal_id', appeal_to_review.id,
          'reviewed_by', actor_admin_id,
          'original_outcome', attendance_before.outcome,
          'resolution_note', normalized_note
        )
      ) returning id into reversal_incident_id;
    end if;

    update public.reliability_sanctions sanction
    set
      revoked_at = decision_at_to_use,
      revoked_by = actor_admin_id,
      revocation_reason = 'Reliability appeal overturned: ' || normalized_note
    where sanction.incident_id = original_incident.id
      and sanction.revoked_at is null;
    get diagnostics revoked_sanction_count = row_count;

    -- An excused cancellation/no-show receives the same configurable no-fault
    -- refund as a Field-cancelled solo match. A player who arrived late and
    -- still played does not receive the match fee back, but does receive a
    -- forfeited reliability deposit.
    policy_refund_bps := attendance_before.refund_bps;
    corrected_total_refund_fils := attendance_before.refund_amount_fils;
    if attendance_before.booking_id is not null then
      select * into booking_to_correct
      from public.open_queue_bookings booking
      where booking.id = attendance_before.booking_id
      for update;

      if booking_to_correct.id is not null then
        policy_refund_bps := case
          when attendance_before.outcome in (
            'CANCELLED_LATE',
            'CANCELLED_VERY_LATE',
            'NO_SHOW'
          ) then coalesce(
            (terms_to_use.policy_snapshot #>>
              '{solo,outcomes,fieldCancelled,refundBps}')::integer,
            10000
          )
          else attendance_before.refund_bps
        end;
        -- An appeal correction can increase a refund, never claw back credit
        -- already awarded by the original policy outcome.
        policy_refund_bps := greatest(
          attendance_before.refund_bps,
          greatest(0, least(10000, policy_refund_bps))
        );

        target_fee_refund_fils := (
          booking_to_correct.base_amount_fils::bigint
          * policy_refund_bps
          / 10000
        )::integer;
        target_deposit_refund_fils := booking_to_correct.reliability_deposit_fils;

        current_total_refund_fils := greatest(
          0,
          coalesce(
            booking_to_correct.refund_amount_fils,
            attendance_before.refund_amount_fils,
            0
          )
        );
        current_deposit_refund_fils := case
          when attendance_before.deposit_resolution = 'RETURNED'
            or booking_to_correct.reliability_deposit_status in ('RETURNED', 'REFUNDED')
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
            and attendance_before.deposit_resolution <> 'RETURNED'
            and booking_to_correct.reliability_deposit_status not in ('RETURNED', 'REFUNDED')
          then target_deposit_refund_fils
          else 0
        end;
        corrected_total_refund_fils := greatest(
          current_total_refund_fils,
          target_fee_refund_fils + target_deposit_refund_fils
        );
        wallet_adjustment_fils := missing_fee_refund_fils
          + missing_deposit_refund_fils;

        if missing_fee_refund_fils > 0 then
          perform public.credit_field_wallet(
            attendance_before.profile_id,
            missing_fee_refund_fils,
            'APPEAL_ADJUSTMENT',
            'appeal-policy-refund:' || appeal_to_review.id::text,
            'Reliability appeal refund adjustment.',
            attendance_before.policy_version_id,
            attendance_before.booking_id,
            original_incident.id,
            jsonb_build_object(
              'appeal_id', appeal_to_review.id,
              'component', 'POLICY_REFUND',
              'policy_refund_bps', policy_refund_bps,
              'target_fee_refund_fils', target_fee_refund_fils,
              'previous_fee_refund_fils', current_fee_refund_fils
            )
          );
        end if;

        if missing_deposit_refund_fils > 0 then
          perform public.credit_field_wallet(
            attendance_before.profile_id,
            missing_deposit_refund_fils,
            'APPEAL_ADJUSTMENT',
            'appeal-deposit-return:' || appeal_to_review.id::text,
            'Reliability deposit returned after a successful appeal.',
            attendance_before.policy_version_id,
            attendance_before.booking_id,
            original_incident.id,
            jsonb_build_object(
              'appeal_id', appeal_to_review.id,
              'component', 'RELIABILITY_DEPOSIT',
              'deposit_fils', target_deposit_refund_fils
            )
          );
        end if;

        update public.open_queue_bookings booking
        set
          refund_bps = greatest(coalesce(booking.refund_bps, 0), policy_refund_bps),
          refund_percent = round(greatest(
            coalesce(booking.refund_bps, 0),
            policy_refund_bps
          ) / 100.0)::integer,
          refund_amount_fils = greatest(
            coalesce(booking.refund_amount_fils, 0),
            corrected_total_refund_fils
          ),
          refund_status = case
            when corrected_total_refund_fils > 0 then 'PROCESSED'
            else booking.refund_status
          end,
          payment_status = case
            when booking.amount_paid_fils > 0
              and corrected_total_refund_fils >= booking.amount_paid_fils
              then 'REFUNDED'
            when corrected_total_refund_fils > 0 then 'PARTIALLY_REFUNDED'
            else booking.payment_status
          end,
          reliability_deposit_status = case
            when booking.reliability_deposit_fils > 0 then 'RETURNED'
            else booking.reliability_deposit_status
          end
        where booking.id = booking_to_correct.id;
      end if;
    end if;

    update public.match_attendance_records attendance
    set
      outcome = 'EXCUSED',
      strike_delta = 0,
      refund_bps = policy_refund_bps,
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
      consequence_snapshot = attendance.consequence_snapshot ||
        jsonb_build_object(
          'appeal_correction', jsonb_build_object(
            'appeal_id', appeal_to_review.id,
            'reviewed_at', decision_at_to_use,
            'reviewed_by', actor_admin_id,
            'previous_outcome', attendance_before.outcome,
            'previous_strike_delta', attendance_before.strike_delta,
            'reversal_incident_id', reversal_incident_id,
            'revoked_sanction_count', revoked_sanction_count,
            'policy_refund_bps', policy_refund_bps,
            'wallet_adjustment_fils', wallet_adjustment_fils
          )
        )
    where attendance.id = attendance_before.id
    returning * into attendance_after;

    insert into public.attendance_events (
      attendance_id,
      event_type,
      actor_referee_id,
      event_at,
      detail,
      idempotency_key
    ) values (
      attendance_before.id,
      'APPEAL_OVERTURNED',
      actor_admin_id,
      decision_at_to_use,
      jsonb_build_object(
        'appeal_id', appeal_to_review.id,
        'previous_outcome', attendance_before.outcome,
        'corrected_outcome', 'EXCUSED',
        'reversal_incident_id', reversal_incident_id,
        'resolution_note', normalized_note
      ),
      'appeal-overturned:' || appeal_to_review.id::text
    ) on conflict (idempotency_key) do nothing;

    insert into public.attendance_events (
      attendance_id,
      event_type,
      actor_referee_id,
      event_at,
      detail,
      idempotency_key
    ) values (
      attendance_before.id,
      'ADMIN_CORRECTION',
      actor_admin_id,
      decision_at_to_use,
      jsonb_build_object(
        'source', 'RELIABILITY_APPEAL',
        'appeal_id', appeal_to_review.id,
        'before', jsonb_build_object(
          'outcome', attendance_before.outcome,
          'strike_delta', attendance_before.strike_delta,
          'refund_bps', attendance_before.refund_bps,
          'deposit_resolution', attendance_before.deposit_resolution
        ),
        'after', jsonb_build_object(
          'outcome', 'EXCUSED',
          'strike_delta', 0,
          'refund_bps', policy_refund_bps,
          'deposit_resolution', attendance_after.deposit_resolution
        )
      ),
      'appeal-admin-correction:' || appeal_to_review.id::text
    ) on conflict (idempotency_key) do nothing;
  else
    attendance_after := attendance_before;
    active_count_before_to_use := public.active_reliability_strikes(
      attendance_before.profile_id,
      decision_at_to_use
    );
    active_count_after_to_use := active_count_before_to_use;
  end if;

  update public.reliability_appeals appeal
  set
    incident_id = coalesce(appeal.incident_id, original_incident.id),
    status = final_status,
    reviewed_by = actor_admin_id,
    reviewed_at = decision_at_to_use,
    resolution_note = normalized_note
  where appeal.id = appeal_to_review.id
  returning * into appeal_to_review;

  after_state_to_audit := jsonb_build_object(
    'appeal', to_jsonb(appeal_to_review),
    'attendance', to_jsonb(attendance_after),
    'reversal_incident_id', reversal_incident_id,
    'revoked_sanction_count', revoked_sanction_count,
    'wallet_adjustment_fils', wallet_adjustment_fils,
    'policy_refund_bps', policy_refund_bps
  );

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
    case normalized_decision
      when 'UPHOLD' then 'RELIABILITY_APPEAL_UPHELD'
      else 'RELIABILITY_APPEAL_OVERTURNED'
    end,
    'APPEAL',
    appeal_to_review.id,
    normalized_note,
    before_state_to_audit,
    after_state_to_audit
  );

  insert into public.notifications (
    recipient_profile_id,
    type,
    title,
    body,
    related_entity_type,
    related_entity_id,
    data
  ) values (
    appeal_to_review.appellant_profile_id,
    'RELIABILITY_APPEAL_DECIDED',
    case normalized_decision
      when 'UPHOLD' then 'Reliability appeal reviewed'
      else 'Reliability appeal approved'
    end,
    case normalized_decision
      when 'UPHOLD' then
        'The original attendance decision remains in place. Open your reliability history for the review note.'
      else
        'Your attendance outcome was corrected to excused. Any strike, related sanction, deposit, and eligible refund were corrected.'
    end,
    'RELIABILITY_APPEAL',
    appeal_to_review.id,
    jsonb_build_object(
      'appeal_id', appeal_to_review.id,
      'status', appeal_to_review.status,
      'wallet_adjustment_fils', wallet_adjustment_fils,
      'active_strikes', active_count_after_to_use
    )
  );

  return jsonb_build_object(
    'appeal_id', appeal_to_review.id,
    'status', appeal_to_review.status,
    'reviewed_at', appeal_to_review.reviewed_at,
    'reviewed_by', appeal_to_review.reviewed_by,
    'attendance_id', attendance_before.id,
    'attendance_outcome', attendance_after.outcome,
    'reversal_incident_id', reversal_incident_id,
    'reversed_strikes', reversed_strikes,
    'active_strikes_before', active_count_before_to_use,
    'active_strikes_after', active_count_after_to_use,
    'revoked_sanction_count', revoked_sanction_count,
    'wallet_adjustment_fils', wallet_adjustment_fils,
    'policy_refund_bps', policy_refund_bps,
    'idempotent', false
  );
end;
$$;

revoke all on function public.admin_review_reliability_appeal(
  uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.admin_review_reliability_appeal(
  uuid, uuid, text, text
) to service_role;

comment on function public.admin_review_reliability_appeal(
  uuid, uuid, text, text
) is
'Finalizes a reliability appeal with an immutable audit trail. Overturns append a compensating strike incident, revoke only incident-caused sanctions, correct attendance to EXCUSED, and idempotently credit Field Wallet adjustments.';
