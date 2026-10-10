-- Keep a referee-attributed clan abandonment financially pending until the
-- admin reviews the provisional forfeit. The generic stoppage RPC changes the
-- fixture to CANCELLED before referee_report_clan_forfeit writes its decision,
-- so the Field-cancellation trigger needs a transaction-local intent marker.
--
-- CONFIRM applies the snapshotted after-kickoff clan cancellation policy:
-- the reported clan receives its configured refund, its reliability deposit
-- is returned or forfeited by policy, the opponent is made whole, and only
-- Clan SR receives the official configured-score forfeit. OVERTURN treats the
-- abandonment as Field-caused and returns both captured amounts in full.

create or replace function public.settle_reviewed_clan_forfeit_reliability(
  actor_admin_id uuid,
  decision_id_to_settle uuid,
  confirm_forfeit boolean,
  review_note_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  decision_to_settle public.match_forfeit_decisions%rowtype;
  fixture_to_settle public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  cancellation_rule jsonb;
  reported_side text;
  opponent_side text;
  reported_payer_id uuid;
  opponent_payer_id uuid;
  reported_base_fils integer := 0;
  opponent_base_fils integer := 0;
  reported_deposit_fils integer := 0;
  opponent_deposit_fils integer := 0;
  reported_deposit_status text;
  opponent_deposit_status text;
  reported_existing_refund_fils integer := 0;
  opponent_existing_refund_fils integer := 0;
  reported_refund_bps integer := 0;
  reported_strike_delta integer := 0;
  reported_fee_refund_fils integer := 0;
  reported_deposit_refund_fils integer := 0;
  opponent_fee_refund_fils integer := 0;
  opponent_deposit_refund_fils integer := 0;
  missing_reported_fee_refund_fils integer := 0;
  missing_opponent_fee_refund_fils integer := 0;
  reported_deposit_forfeited boolean := false;
  cancellation_id_to_use uuid;
  incident_id_to_use uuid;
  settlement_note text := trim(coalesce(review_note_to_use, ''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if decision_id_to_settle is null then
    raise exception 'Forfeit decision is required.';
  end if;
  if char_length(settlement_note) < 10
    or char_length(settlement_note) > 2000
  then
    raise exception 'Add a clear review note (at least 10 characters).';
  end if;

  select * into decision_to_settle
  from public.match_forfeit_decisions decision
  where decision.id = decision_id_to_settle
  for update;
  if decision_to_settle.id is null then
    raise exception 'Forfeit decision not found.';
  end if;
  if decision_to_settle.state <> 'PENDING_REVIEW' then
    raise exception 'Only a pending provisional forfeit can be settled.';
  end if;

  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = decision_to_settle.fixture_id
  for update;
  if fixture_to_settle.id is null then
    raise exception 'Match not found.';
  end if;
  if fixture_to_settle.status <> 'CANCELLED'
    or fixture_to_settle.cancellation_context ->> 'forfeit_decision_id'
      is distinct from decision_to_settle.id::text
  then
    raise exception 'The abandoned match no longer matches this pending forfeit.';
  end if;

  reported_side := case
    when decision_to_settle.reported_clan_id = fixture_to_settle.home_clan_id
      then 'HOME'
    when decision_to_settle.reported_clan_id = fixture_to_settle.away_clan_id
      then 'AWAY'
    else null
  end;
  if reported_side is null
    or decision_to_settle.awarded_clan_id not in (
      fixture_to_settle.home_clan_id,
      fixture_to_settle.away_clan_id
    )
  then
    raise exception 'The provisional forfeit clans no longer match the fixture.';
  end if;
  opponent_side := case when reported_side = 'HOME' then 'AWAY' else 'HOME' end;

  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_to_settle.id
  );

  if reported_side = 'HOME' then
    reported_payer_id := fixture_to_settle.home_paid_by;
    opponent_payer_id := fixture_to_settle.away_paid_by;
    reported_base_fils := coalesce(fixture_to_settle.home_base_amount_fils, 0);
    opponent_base_fils := coalesce(fixture_to_settle.away_base_amount_fils, 0);
    reported_deposit_fils := fixture_to_settle.home_reliability_deposit_fils;
    opponent_deposit_fils := fixture_to_settle.away_reliability_deposit_fils;
    reported_deposit_status := fixture_to_settle.home_deposit_status;
    opponent_deposit_status := fixture_to_settle.away_deposit_status;
    reported_existing_refund_fils := fixture_to_settle.home_refund_amount_fils;
    opponent_existing_refund_fils := fixture_to_settle.away_refund_amount_fils;
  else
    reported_payer_id := fixture_to_settle.away_paid_by;
    opponent_payer_id := fixture_to_settle.home_paid_by;
    reported_base_fils := coalesce(fixture_to_settle.away_base_amount_fils, 0);
    opponent_base_fils := coalesce(fixture_to_settle.home_base_amount_fils, 0);
    reported_deposit_fils := fixture_to_settle.away_reliability_deposit_fils;
    opponent_deposit_fils := fixture_to_settle.home_reliability_deposit_fils;
    reported_deposit_status := fixture_to_settle.away_deposit_status;
    opponent_deposit_status := fixture_to_settle.home_deposit_status;
    reported_existing_refund_fils := fixture_to_settle.away_refund_amount_fils;
    opponent_existing_refund_fils := fixture_to_settle.home_refund_amount_fils;
  end if;

  if confirm_forfeit then
    cancellation_rule := terms_to_use.policy_snapshot #>
      '{clan,cancellations,afterKickoff}';
    reported_refund_bps := (cancellation_rule ->> 'refundBps')::integer;
    reported_strike_delta := (cancellation_rule ->> 'strikes')::integer;
    select exists (
      select 1
      from jsonb_array_elements_text(
        terms_to_use.policy_snapshot #>
          '{clan,reliabilityDeposit,forfeitOutcomes}'
      ) forfeited(outcome)
      where forfeited.outcome = 'NO_SHOW'
    ) into reported_deposit_forfeited;
    reported_deposit_forfeited := reported_deposit_fils > 0
      and reported_deposit_forfeited;
    reported_fee_refund_fils := (
      reported_base_fils::bigint * reported_refund_bps / 10000
    )::integer;
    reported_deposit_refund_fils := case
      when reported_deposit_forfeited then 0
      else reported_deposit_fils
    end;
    opponent_fee_refund_fils := opponent_base_fils;
    opponent_deposit_refund_fils := opponent_deposit_fils;

    missing_reported_fee_refund_fils := greatest(
      0,
      reported_fee_refund_fils - least(
        reported_fee_refund_fils,
        reported_existing_refund_fils
      )
    );
    missing_opponent_fee_refund_fils := greatest(
      0,
      opponent_fee_refund_fils - least(
        opponent_fee_refund_fils,
        opponent_existing_refund_fils
      )
    );

    insert into public.clan_fixture_cancellations (
      fixture_id,
      cancelling_clan_id,
      cancelled_by,
      cancellation_band,
      outcome,
      strike_delta,
      refund_bps,
      refund_amount_fils,
      deposit_forfeited,
      opponent_refund_amount_fils,
      creates_forfeit,
      policy_version_id,
      policy_snapshot,
      reason
    ) values (
      fixture_to_settle.id,
      decision_to_settle.reported_clan_id,
      decision_to_settle.created_by,
      'afterKickoff',
      'NO_SHOW',
      reported_strike_delta,
      reported_refund_bps,
      reported_fee_refund_fils + reported_deposit_refund_fils,
      reported_deposit_forfeited,
      opponent_fee_refund_fils + opponent_deposit_refund_fils,
      true,
      terms_to_use.policy_version_id,
      terms_to_use.policy_snapshot,
      left(
        'Referee-attributed abandonment confirmed by admin: ' || settlement_note,
        1000
      )
    )
    on conflict (fixture_id) do nothing
    returning id into cancellation_id_to_use;

    if cancellation_id_to_use is null then
      select cancellation.id into cancellation_id_to_use
      from public.clan_fixture_cancellations cancellation
      where cancellation.fixture_id = fixture_to_settle.id
        and cancellation.cancelling_clan_id = decision_to_settle.reported_clan_id
        and cancellation.cancellation_band = 'afterKickoff'
        and cancellation.creates_forfeit;
      if cancellation_id_to_use is null then
        raise exception 'This fixture already has a different clan cancellation settlement.';
      end if;
    end if;

    if missing_reported_fee_refund_fils > 0
      and reported_payer_id is not null
    then
      perform public.credit_field_wallet(
        reported_payer_id,
        missing_reported_fee_refund_fils,
        'BOOKING_REFUND',
        'reviewed-forfeit-fee:' || decision_to_settle.id::text || ':' ||
          reported_side,
        'Policy-based clan fee refund after a confirmed referee forfeit.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', fixture_to_settle.id,
          'decision_id', decision_to_settle.id,
          'side', reported_side,
          'refund_bps', reported_refund_bps
        )
      );
    end if;
    if reported_deposit_refund_fils > 0
      and reported_deposit_status <> 'RETURNED'
      and reported_payer_id is not null
    then
      perform public.credit_field_wallet(
        reported_payer_id,
        reported_deposit_refund_fils,
        'RELIABILITY_DEPOSIT_RETURN',
        'reviewed-forfeit-deposit:' || decision_to_settle.id::text || ':' ||
          reported_side,
        'Clan reliability deposit returned under the confirmed forfeit policy.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', fixture_to_settle.id,
          'decision_id', decision_to_settle.id,
          'side', reported_side
        )
      );
    end if;
    if missing_opponent_fee_refund_fils > 0
      and opponent_payer_id is not null
    then
      perform public.credit_field_wallet(
        opponent_payer_id,
        missing_opponent_fee_refund_fils,
        'FIELD_CANCELLATION_REFUND',
        'reviewed-forfeit-opponent-fee:' || decision_to_settle.id::text || ':' ||
          opponent_side,
        'Clan match fee returned because the opponent caused a confirmed forfeit.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', fixture_to_settle.id,
          'decision_id', decision_to_settle.id,
          'side', opponent_side
        )
      );
    end if;
    if opponent_deposit_fils > 0
      and opponent_deposit_status <> 'RETURNED'
      and opponent_payer_id is not null
    then
      perform public.credit_field_wallet(
        opponent_payer_id,
        opponent_deposit_fils,
        'RELIABILITY_DEPOSIT_RETURN',
        'reviewed-forfeit-opponent-deposit:' ||
          decision_to_settle.id::text || ':' || opponent_side,
        'Clan reliability deposit returned because the opponent caused a confirmed forfeit.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', fixture_to_settle.id,
          'decision_id', decision_to_settle.id,
          'side', opponent_side
        )
      );
    end if;

    if reported_side = 'HOME' then
      update public.fixtures set
        home_refund_bps = greatest(home_refund_bps, reported_refund_bps),
        home_refund_amount_fils = greatest(
          home_refund_amount_fils,
          reported_fee_refund_fils + reported_deposit_refund_fils
        ),
        home_deposit_status = case
          when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
          when reported_deposit_forfeited
            and home_deposit_status <> 'RETURNED' then 'FORFEITED'
          else 'RETURNED'
        end,
        away_refund_bps = 10000,
        away_refund_amount_fils = greatest(
          away_refund_amount_fils,
          opponent_fee_refund_fils + opponent_deposit_refund_fils
        ),
        away_deposit_status = case
          when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
          else 'RETURNED'
        end,
        cancellation_context = cancellation_context || jsonb_build_object(
          'reliability_forfeit_without_play', true,
          'forfeit_finance_state', 'CONFIRMED_POLICY_SETTLED',
          'clan_cancellation_id', cancellation_id_to_use,
          'reliability_policy_version_id', terms_to_use.policy_version_id
        )
      where id = fixture_to_settle.id;
    else
      update public.fixtures set
        away_refund_bps = greatest(away_refund_bps, reported_refund_bps),
        away_refund_amount_fils = greatest(
          away_refund_amount_fils,
          reported_fee_refund_fils + reported_deposit_refund_fils
        ),
        away_deposit_status = case
          when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
          when reported_deposit_forfeited
            and away_deposit_status <> 'RETURNED' then 'FORFEITED'
          else 'RETURNED'
        end,
        home_refund_bps = 10000,
        home_refund_amount_fils = greatest(
          home_refund_amount_fils,
          opponent_fee_refund_fils + opponent_deposit_refund_fils
        ),
        home_deposit_status = case
          when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
          else 'RETURNED'
        end,
        cancellation_context = cancellation_context || jsonb_build_object(
          'reliability_forfeit_without_play', true,
          'forfeit_finance_state', 'CONFIRMED_POLICY_SETTLED',
          'clan_cancellation_id', cancellation_id_to_use,
          'reliability_policy_version_id', terms_to_use.policy_version_id
        )
      where id = fixture_to_settle.id;
    end if;

    incident_id_to_use :=
      public.record_clan_cancellation_reliability_incident(
        fixture_to_settle.id,
        decision_to_settle.reported_clan_id,
        'NO_SHOW',
        reported_strike_delta,
        cancellation_id_to_use,
        clock_timestamp()
      );
    perform public.resolve_clan_cancellation_attendance(
      fixture_to_settle.id,
      decision_to_settle.reported_clan_id,
      true,
      decision_to_settle.created_by
    );
    update public.fixture_player_appearances
    set played = false, rating_change = null
    where fixture_id = fixture_to_settle.id;

    return jsonb_build_object(
      'decision_id', decision_to_settle.id,
      'fixture_id', fixture_to_settle.id,
      'settlement', 'CONFIRMED_POLICY_SETTLED',
      'reported_clan_id', decision_to_settle.reported_clan_id,
      'reported_refund_bps', reported_refund_bps,
      'reported_strike_delta', reported_strike_delta,
      'reported_deposit_forfeited', reported_deposit_forfeited,
      'opponent_refund_fils',
        opponent_fee_refund_fils + opponent_deposit_refund_fils,
      'incident_id', incident_id_to_use,
      'policy_version_id', terms_to_use.policy_version_id
    );
  end if;

  -- An overturned team-attribution becomes a neutral, Field-caused
  -- abandonment. Reuse the common policy correction for attendance, incidents,
  -- sanctions and appeals, then settle only the still-missing wallet amounts.
  perform public.apply_policy_field_cancellation(
    actor_admin_id,
    'CLAN',
    fixture_to_settle.id,
    'Admin overturned provisional clan forfeit: ' || settlement_note
  );

  reported_fee_refund_fils := reported_base_fils;
  opponent_fee_refund_fils := opponent_base_fils;
  reported_deposit_refund_fils := reported_deposit_fils;
  opponent_deposit_refund_fils := opponent_deposit_fils;
  missing_reported_fee_refund_fils := greatest(
    0,
    reported_base_fils - least(
      reported_base_fils,
      reported_existing_refund_fils
    )
  );
  missing_opponent_fee_refund_fils := greatest(
    0,
    opponent_base_fils - least(
      opponent_base_fils,
      opponent_existing_refund_fils
    )
  );

  if missing_reported_fee_refund_fils > 0
    and reported_payer_id is not null
  then
    perform public.credit_field_wallet(
      reported_payer_id,
      missing_reported_fee_refund_fils,
      'FIELD_CANCELLATION_REFUND',
      'overturned-forfeit-fee:' || decision_to_settle.id::text || ':' ||
        reported_side,
      'Clan match fee returned after Field overturned the provisional forfeit.',
      terms_to_use.policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', fixture_to_settle.id,
        'decision_id', decision_to_settle.id,
        'side', reported_side
      )
    );
  end if;
  if reported_deposit_fils > 0
    and reported_deposit_status <> 'RETURNED'
    and reported_payer_id is not null
  then
    perform public.credit_field_wallet(
      reported_payer_id,
      reported_deposit_fils,
      'RELIABILITY_DEPOSIT_RETURN',
      'overturned-forfeit-deposit:' || decision_to_settle.id::text || ':' ||
        reported_side,
      'Clan reliability deposit returned after Field overturned the provisional forfeit.',
      terms_to_use.policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', fixture_to_settle.id,
        'decision_id', decision_to_settle.id,
        'side', reported_side
      )
    );
  end if;
  if missing_opponent_fee_refund_fils > 0
    and opponent_payer_id is not null
  then
    perform public.credit_field_wallet(
      opponent_payer_id,
      missing_opponent_fee_refund_fils,
      'FIELD_CANCELLATION_REFUND',
      'overturned-forfeit-fee:' || decision_to_settle.id::text || ':' ||
        opponent_side,
      'Clan match fee returned after Field overturned the provisional forfeit.',
      terms_to_use.policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', fixture_to_settle.id,
        'decision_id', decision_to_settle.id,
        'side', opponent_side
      )
    );
  end if;
  if opponent_deposit_fils > 0
    and opponent_deposit_status <> 'RETURNED'
    and opponent_payer_id is not null
  then
    perform public.credit_field_wallet(
      opponent_payer_id,
      opponent_deposit_fils,
      'RELIABILITY_DEPOSIT_RETURN',
      'overturned-forfeit-deposit:' || decision_to_settle.id::text || ':' ||
        opponent_side,
      'Clan reliability deposit returned after Field overturned the provisional forfeit.',
      terms_to_use.policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', fixture_to_settle.id,
        'decision_id', decision_to_settle.id,
        'side', opponent_side
      )
    );
  end if;

  update public.fixtures set
    home_refund_bps = case when home_paid_by is null then home_refund_bps
      else 10000 end,
    home_refund_amount_fils = case when home_paid_by is null
      then home_refund_amount_fils else coalesce(home_amount_paid_fils, 0) end,
    home_deposit_status = case
      when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
      else 'RETURNED' end,
    away_refund_bps = case when away_paid_by is null then away_refund_bps
      else 10000 end,
    away_refund_amount_fils = case when away_paid_by is null
      then away_refund_amount_fils else coalesce(away_amount_paid_fils, 0) end,
    away_deposit_status = case
      when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
      else 'RETURNED' end,
    cancellation_context = cancellation_context || jsonb_build_object(
      'forfeit_finance_state', 'OVERTURNED_FIELD_SETTLED',
      'reliability_forfeit_without_play', true
    )
  where id = fixture_to_settle.id;

  update public.fixture_player_appearances
  set played = false, rating_change = null
  where fixture_id = fixture_to_settle.id;

  return jsonb_build_object(
    'decision_id', decision_to_settle.id,
    'fixture_id', fixture_to_settle.id,
    'settlement', 'OVERTURNED_FIELD_SETTLED',
    'home_refund_fils', coalesce(fixture_to_settle.home_amount_paid_fils, 0),
    'away_refund_fils', coalesce(fixture_to_settle.away_amount_paid_fils, 0)
  );
end;
$$;

-- Mark only the outer, team-attributable forfeit transaction before the inner
-- generic ABANDON call reaches the Field-cancellation trigger.
do $migration$
declare
  function_definition text;
  old_text text := $old$  stoppage_id_to_use := public.referee_record_match_stoppage($old$;
  new_text text := $new$  perform set_config(
    'field.pending_clan_forfeit_fixture_id',
    fixture_id_to_stop::text,
    true
  );

  stoppage_id_to_use := public.referee_record_match_stoppage($new$;
begin
  select pg_get_functiondef(
    'public.referee_report_clan_forfeit(uuid,uuid,uuid,text,text,text,text,integer)'::regprocedure
  ) into function_definition;
  if position('field.pending_clan_forfeit_fixture_id' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not mark the provisional clan forfeit before abandonment.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

-- The normal Field settlement still runs for neutral referee abandonments,
-- admin/venue cancellations and automatic underfilled fixtures. Only the
-- marked provisional-forfeit transaction is deferred.
do $migration$
declare
  function_definition text;
  old_text text := $old$  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = new.id
  for update;$old$;
  new_text text := $new$  if nullif(
    current_setting('field.pending_clan_forfeit_fixture_id', true),
    ''
  ) = new.id::text then
    return new;
  end if;

  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = new.id
  for update;$new$;
begin
  select pg_get_functiondef(
    'public.settle_field_cancelled_clan_fixture()'::regprocedure
  ) into function_definition;
  if position('field.pending_clan_forfeit_fixture_id' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not defer Field settlement for a provisional clan forfeit.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

-- Settle finance/reliability immediately before the existing admin review
-- mutates Clan SR and fixture status. This makes the whole review transaction
-- atomic and keeps its existing network-retry guard authoritative.
do $migration$
declare
  function_definition text;
  old_confirm text := $old$  if normalized_action = 'CONFIRM' then
    -- This mirrors normal clan finalization.$old$;
  new_confirm text := $new$  if normalized_action = 'CONFIRM' then
    perform public.settle_reviewed_clan_forfeit_reliability(
      actor_admin_id,
      decision.id,
      true,
      normalized_note
    );

    -- This mirrors normal clan finalization.$new$;
  old_overturn text := $old$  else
    -- Rejecting the provisional result restores the actual score at the stop.$old$;
  new_overturn text := $new$  else
    perform public.settle_reviewed_clan_forfeit_reliability(
      actor_admin_id,
      decision.id,
      false,
      normalized_note
    );

    -- Rejecting the provisional result restores the actual score at the stop.$new$;
begin
  select pg_get_functiondef(
    'public.admin_review_clan_forfeit(uuid,uuid,text,text)'::regprocedure
  ) into function_definition;
  if position('settle_reviewed_clan_forfeit_reliability' in function_definition) = 0 then
    if position(old_confirm in function_definition) = 0
      or position(old_overturn in function_definition) = 0
    then
      raise exception 'Could not attach reliability settlement to clan forfeit review.';
    end if;
    function_definition := replace(function_definition, old_confirm, new_confirm);
    function_definition := replace(function_definition, old_overturn, new_overturn);
    function_definition := replace(
      function_definition,
      'NORMAL_FINALIZATION_ON_CONFIRMATION',
      'CLAN_SR_ONLY_NO_PLAYER_SR'
    );
    execute function_definition;
  end if;
end;
$migration$;

revoke all on function public.settle_reviewed_clan_forfeit_reliability(
  uuid, uuid, boolean, text
) from public, anon, authenticated;
grant execute on function public.settle_reviewed_clan_forfeit_reliability(
  uuid, uuid, boolean, text
) to service_role;

comment on function public.settle_reviewed_clan_forfeit_reliability(
  uuid, uuid, boolean, text
) is
'Atomically applies the policy-backed wallet, deposit, attendance and reliability result when an admin confirms or overturns a referee-attributed provisional clan forfeit.';
