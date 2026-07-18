-- Effective-dated Field reliability policy.
--
-- Published versions are append-only. Operational decisions resolve the
-- greatest published effective_from at or before the scheduled kickoff and
-- persist that policy id with the decision. Security invariants (server time,
-- referee authority, append-only ledgers, and audit logging) are deliberately
-- not configurable.

alter table public.admin_audit_events
drop constraint if exists admin_audit_events_entity_type_check;

alter table public.admin_audit_events
add constraint admin_audit_events_entity_type_check
check (
  entity_type in (
    'REPORT',
    'PLAYER',
    'CLAN',
    'CLAN_MATCH',
    'SOLO_MATCH',
    'ACTION',
    'POLICY',
    'ATTENDANCE',
    'APPEAL',
    'SANCTION'
  )
);

create or replace function public.jsonb_object_has_exact_keys(
  value_to_check jsonb,
  expected_keys text[]
)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select jsonb_typeof(value_to_check) = 'object'
    and coalesce(
      (
        select array_agg(key_name order by key_name)
        from jsonb_object_keys(value_to_check) keys(key_name)
      ),
      array[]::text[]
    ) = coalesce(
      (
        select array_agg(expected_key order by expected_key)
        from unnest(expected_keys) expected(expected_key)
      ),
      array[]::text[]
    );
$$;

create or replace function public.reliability_policy_config_is_valid(
  config_to_check jsonb
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  sanction jsonb;
  previous_threshold integer;
  required_path text;
begin
  if config_to_check is null then
    return false;
  end if;

  -- Keep the database contract as strict as the admin editor. Unknown or
  -- missing keys are rejected so a typo cannot silently become a no-op rule.
  if not public.jsonb_object_has_exact_keys(config_to_check, array[
      'schemaVersion', 'timezone', 'attendance', 'solo', 'replacement',
      'sr', 'injury', 'clan', 'appeals', 'wallet'
    ])
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'attendance', array[
      'checkInOpenLeadMinutes', 'checkInLeadMinutes', 'noShowGraceMinutes',
      'strikeLifetimeDays', 'appealWindowHours', 'hostCheckInRequired',
      'cancellationAfterKickoffOutcome'
    ])
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'solo', array[
      'playersPerSide', 'cancellations', 'outcomes', 'reliabilityDeposit',
      'sanctions', 'highestCrossedOnly', 'releaseFutureBookingsRefundBps',
      'teamAssignmentLeadMinutes', 'partyLockLeadMinutes'
    ])
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,cancellations}',
      array['early', 'late', 'veryLate', 'afterKickoff']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,cancellations,early}',
      array['minimumHoursBeforeKickoff', 'strikes', 'refundBps', 'advertise',
        'discountBps', 'notify']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,cancellations,late}',
      array['minimumHoursBeforeKickoff', 'strikes', 'refundBps', 'advertise',
        'discountBps', 'notify']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,cancellations,veryLate}',
      array['strikes', 'refundBps', 'advertise', 'discountBps', 'notify']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,cancellations,afterKickoff}',
      array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,outcomes}',
      array['onTime', 'late', 'noShow', 'fieldCancelled']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,outcomes,onTime}', array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,outcomes,late}', array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,outcomes,noShow}', array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,outcomes,fieldCancelled}',
      array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{solo,reliabilityDeposit}',
      array['activeStrikeThreshold', 'depositBps', 'onTimeReturnDestination',
        'forfeitOutcomes']
    )
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'replacement', array[
      'lateCancellationDiscountBps', 'notifyEligiblePlayersOnLateCancellation',
      'postCheckInDeadlineMarketplaceEnabled',
      'reserveActivationMinutesAfterKickoff',
      'originalPlayerReclaimUntilMinutesAfterKickoff', 'order', 'maxPartySize'
    ])
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'sr', array[
      'latePositiveMultiplierBps', 'lateNegativeMultiplierBps',
      'shorthandedQualifyingActualMinutes',
      'protectedLosingOnTimeMultiplierBps', 'protectedWinnerMultiplierBps',
      'disadvantagedWinnerMultiplierBps', 'latePlayerGetsTeamProtection'
    ])
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'injury', array[
      'strikeDelta', 'requiresRefereeVerification', 'halfMatchThresholdBps',
      'completedLossMultiplierBps', 'incompleteLosingMultiplierBps',
      'incompleteWinningMultiplierBps', 'incompleteRefundBps'
    ])
    or not public.jsonb_object_has_exact_keys(config_to_check -> 'clan', array[
      'playersPerSide', 'minimumOnTimeWithoutClanStrike',
      'minimumAtKickoffWithoutForfeit', 'partialAttendanceStrikes',
      'forfeitStrikes', 'entireClanNoShowStrikes', 'forfeitScore',
      'cancellations', 'reliabilityDeposit', 'sanctions'
    ])
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,cancellations}',
      array['early', 'late', 'veryLate', 'afterKickoff']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,cancellations,early}',
      array['minimumHoursBeforeKickoff', 'strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,cancellations,late}',
      array['minimumHoursBeforeKickoff', 'strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,cancellations,veryLate}',
      array['strikes', 'refundBps']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,cancellations,afterKickoff}',
      array['strikes', 'refundBps', 'forfeit']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check #> '{clan,reliabilityDeposit}',
      array['activeStrikeThreshold', 'depositBps', 'forfeitOutcomes']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check -> 'appeals',
      array['allowedCategories', 'routineTrafficAutomaticallyExcused']
    )
    or not public.jsonb_object_has_exact_keys(
      config_to_check -> 'wallet', array['refundDestination', 'currency']
    )
  then
    return false;
  end if;

  -- JSON scalar types are checked before casts so nulls and quoted numbers
  -- cannot bypass range validation.
  for required_path in
    select value from jsonb_array_elements_text($paths$[
      "schemaVersion",
      "attendance.checkInOpenLeadMinutes", "attendance.checkInLeadMinutes",
      "attendance.noShowGraceMinutes", "attendance.strikeLifetimeDays",
      "attendance.appealWindowHours", "solo.playersPerSide",
      "solo.cancellations.early.minimumHoursBeforeKickoff",
      "solo.cancellations.late.minimumHoursBeforeKickoff",
      "solo.cancellations.early.strikes", "solo.cancellations.early.refundBps",
      "solo.cancellations.early.discountBps", "solo.cancellations.late.strikes",
      "solo.cancellations.late.refundBps", "solo.cancellations.late.discountBps",
      "solo.cancellations.veryLate.strikes",
      "solo.cancellations.veryLate.refundBps",
      "solo.cancellations.veryLate.discountBps",
      "solo.cancellations.afterKickoff.strikes",
      "solo.cancellations.afterKickoff.refundBps",
      "solo.outcomes.onTime.strikes", "solo.outcomes.onTime.refundBps",
      "solo.outcomes.late.strikes", "solo.outcomes.late.refundBps",
      "solo.outcomes.noShow.strikes", "solo.outcomes.noShow.refundBps",
      "solo.outcomes.fieldCancelled.strikes",
      "solo.outcomes.fieldCancelled.refundBps",
      "solo.reliabilityDeposit.activeStrikeThreshold",
      "solo.reliabilityDeposit.depositBps",
      "solo.releaseFutureBookingsRefundBps", "solo.teamAssignmentLeadMinutes",
      "solo.partyLockLeadMinutes", "replacement.lateCancellationDiscountBps",
      "replacement.reserveActivationMinutesAfterKickoff",
      "replacement.originalPlayerReclaimUntilMinutesAfterKickoff",
      "replacement.maxPartySize", "sr.latePositiveMultiplierBps",
      "sr.lateNegativeMultiplierBps", "sr.shorthandedQualifyingActualMinutes",
      "sr.protectedLosingOnTimeMultiplierBps", "sr.protectedWinnerMultiplierBps",
      "sr.disadvantagedWinnerMultiplierBps", "injury.strikeDelta",
      "injury.halfMatchThresholdBps", "injury.completedLossMultiplierBps",
      "injury.incompleteLosingMultiplierBps",
      "injury.incompleteWinningMultiplierBps", "injury.incompleteRefundBps",
      "clan.playersPerSide", "clan.minimumOnTimeWithoutClanStrike",
      "clan.minimumAtKickoffWithoutForfeit", "clan.partialAttendanceStrikes",
      "clan.forfeitStrikes", "clan.entireClanNoShowStrikes",
      "clan.forfeitScore",
      "clan.cancellations.early.minimumHoursBeforeKickoff",
      "clan.cancellations.early.strikes", "clan.cancellations.early.refundBps",
      "clan.cancellations.late.minimumHoursBeforeKickoff",
      "clan.cancellations.late.strikes", "clan.cancellations.late.refundBps",
      "clan.cancellations.veryLate.strikes",
      "clan.cancellations.veryLate.refundBps",
      "clan.cancellations.afterKickoff.strikes",
      "clan.cancellations.afterKickoff.refundBps",
      "clan.reliabilityDeposit.activeStrikeThreshold",
      "clan.reliabilityDeposit.depositBps"
    ]$paths$::jsonb)
  loop
    if jsonb_typeof(config_to_check #> string_to_array(required_path, '.'))
      <> 'number'
      or (config_to_check #>> string_to_array(required_path, '.'))::numeric
        <> trunc((config_to_check #>>
          string_to_array(required_path, '.'))::numeric)
    then
      return false;
    end if;
  end loop;

  for required_path in
    select value from jsonb_array_elements_text($paths$[
      "attendance.hostCheckInRequired", "solo.cancellations.early.advertise",
      "solo.cancellations.early.notify", "solo.cancellations.late.advertise",
      "solo.cancellations.late.notify",
      "solo.cancellations.veryLate.advertise",
      "solo.cancellations.veryLate.notify", "solo.highestCrossedOnly",
      "replacement.notifyEligiblePlayersOnLateCancellation",
      "replacement.postCheckInDeadlineMarketplaceEnabled",
      "sr.latePlayerGetsTeamProtection", "injury.requiresRefereeVerification",
      "clan.cancellations.afterKickoff.forfeit",
      "appeals.routineTrafficAutomaticallyExcused"
    ]$paths$::jsonb)
  loop
    if jsonb_typeof(config_to_check #> string_to_array(required_path, '.'))
      <> 'boolean'
    then
      return false;
    end if;
  end loop;

  for required_path in
    select value from jsonb_array_elements_text($paths$[
      "timezone", "attendance.cancellationAfterKickoffOutcome",
      "solo.reliabilityDeposit.onTimeReturnDestination",
      "wallet.refundDestination", "wallet.currency"
    ]$paths$::jsonb)
  loop
    if jsonb_typeof(config_to_check #> string_to_array(required_path, '.'))
      <> 'string'
    then
      return false;
    end if;
  end loop;

  if jsonb_typeof(config_to_check) <> 'object'
    or (config_to_check ->> 'schemaVersion')::integer <> 1
    or config_to_check ->> 'timezone' <> 'Asia/Bahrain'
  then
    return false;
  end if;

  if jsonb_typeof(config_to_check -> 'attendance') <> 'object'
    or jsonb_typeof(config_to_check -> 'solo') <> 'object'
    or jsonb_typeof(config_to_check #> '{solo,cancellations}') <> 'object'
    or jsonb_typeof(config_to_check #> '{solo,outcomes}') <> 'object'
    or jsonb_typeof(config_to_check #> '{solo,reliabilityDeposit}') <> 'object'
    or jsonb_typeof(config_to_check #> '{solo,sanctions}') <> 'array'
    or jsonb_typeof(config_to_check -> 'replacement') <> 'object'
    or jsonb_typeof(config_to_check -> 'sr') <> 'object'
    or jsonb_typeof(config_to_check -> 'injury') <> 'object'
    or jsonb_typeof(config_to_check -> 'clan') <> 'object'
    or jsonb_typeof(config_to_check #> '{clan,cancellations}') <> 'object'
    or jsonb_typeof(config_to_check #> '{clan,reliabilityDeposit}') <> 'object'
    or jsonb_typeof(config_to_check #> '{clan,sanctions}') <> 'array'
    or jsonb_typeof(config_to_check -> 'appeals') <> 'object'
    or jsonb_typeof(config_to_check -> 'wallet') <> 'object'
  then
    return false;
  end if;

  -- Required attendance clock and review values.
  if (config_to_check #>> '{attendance,checkInOpenLeadMinutes}')::integer
      not between 0 and 10080
    or (config_to_check #>> '{attendance,checkInLeadMinutes}')::integer
      not between 0 and 1440
    or (config_to_check #>> '{attendance,checkInOpenLeadMinutes}')::integer
      <= (config_to_check #>> '{attendance,checkInLeadMinutes}')::integer
    or (config_to_check #>> '{attendance,noShowGraceMinutes}')::integer
      not between 0 and 180
    or (config_to_check #>> '{attendance,strikeLifetimeDays}')::integer
      not between 1 and 3650
    or (config_to_check #>> '{attendance,appealWindowHours}')::integer
      not between 1 and 720
    or (config_to_check #>> '{attendance,hostCheckInRequired}')::boolean is distinct from true
    or config_to_check #>> '{attendance,cancellationAfterKickoffOutcome}' <> 'NO_SHOW'
  then
    return false;
  end if;

  -- Cancellation bands must remain ordered and every money percentage uses
  -- basis points (0..10000).
  if (config_to_check #>> '{solo,cancellations,early,minimumHoursBeforeKickoff}')::numeric
      <= (config_to_check #>> '{solo,cancellations,late,minimumHoursBeforeKickoff}')::numeric
    or (config_to_check #>> '{solo,cancellations,late,minimumHoursBeforeKickoff}')::numeric < 0
    or (config_to_check #>> '{solo,cancellations,early,minimumHoursBeforeKickoff}')::numeric > 8760
    or (config_to_check #>> '{solo,cancellations,late,minimumHoursBeforeKickoff}')::numeric > 8760
    or (config_to_check #>> '{solo,playersPerSide}')::integer not between 1 and 20
    or (config_to_check #>> '{solo,teamAssignmentLeadMinutes}')::integer
      not between 0 and 10080
    or (config_to_check #>> '{solo,partyLockLeadMinutes}')::integer
      not between 0 and 10080
  then
    return false;
  end if;

  if exists (
    select 1
    from unnest(array[
      config_to_check #> '{solo,cancellations,early}',
      config_to_check #> '{solo,cancellations,late}',
      config_to_check #> '{solo,cancellations,veryLate}',
      config_to_check #> '{solo,cancellations,afterKickoff}',
      config_to_check #> '{solo,outcomes,onTime}',
      config_to_check #> '{solo,outcomes,late}',
      config_to_check #> '{solo,outcomes,noShow}',
      config_to_check #> '{solo,outcomes,fieldCancelled}',
      config_to_check #> '{clan,cancellations,early}',
      config_to_check #> '{clan,cancellations,late}',
      config_to_check #> '{clan,cancellations,veryLate}',
      config_to_check #> '{clan,cancellations,afterKickoff}'
    ]::jsonb[]) rule
    where jsonb_typeof(rule) <> 'object'
      or (rule ->> 'strikes')::integer not between 0 and 20
      or (rule ->> 'refundBps')::integer not between 0 and 10000
  ) then
    return false;
  end if;

  -- Venue/Field failures are never converted into player strikes.
  if (config_to_check #>> '{solo,outcomes,fieldCancelled,strikes}')::integer <> 0 then
    return false;
  end if;

  if (config_to_check #>> '{solo,cancellations,early,discountBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{solo,cancellations,late,discountBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{solo,cancellations,veryLate,discountBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{solo,reliabilityDeposit,depositBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{solo,releaseFutureBookingsRefundBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{replacement,lateCancellationDiscountBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{sr,latePositiveMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{sr,lateNegativeMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{sr,protectedLosingOnTimeMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{sr,protectedWinnerMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{sr,disadvantagedWinnerMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{injury,halfMatchThresholdBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{injury,completedLossMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{injury,incompleteLosingMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{injury,incompleteWinningMultiplierBps}')::integer not between 0 and 20000
    or (config_to_check #>> '{injury,incompleteRefundBps}')::integer not between 0 and 10000
    or (config_to_check #>> '{clan,reliabilityDeposit,depositBps}')::integer not between 0 and 10000
  then
    return false;
  end if;

  if (config_to_check #>> '{solo,reliabilityDeposit,activeStrikeThreshold}')::integer
      not between 1 and 20
    or config_to_check #>> '{solo,reliabilityDeposit,onTimeReturnDestination}' <> 'FIELD_WALLET'
    or jsonb_typeof(config_to_check #> '{solo,reliabilityDeposit,forfeitOutcomes}') <> 'array'
    or (config_to_check #>> '{replacement,reserveActivationMinutesAfterKickoff}')::integer
      not between 0 and 180
    or (config_to_check #>> '{replacement,originalPlayerReclaimUntilMinutesAfterKickoff}')::integer
      not between 0 and 180
    or (config_to_check #>> '{replacement,originalPlayerReclaimUntilMinutesAfterKickoff}')::integer
      > (config_to_check #>> '{replacement,reserveActivationMinutesAfterKickoff}')::integer
    or (config_to_check #>> '{replacement,maxPartySize}')::integer not between 1 and 4
    or (config_to_check #>> '{replacement,maxPartySize}')::integer
      > (config_to_check #>> '{solo,playersPerSide}')::integer
    or jsonb_typeof(config_to_check #> '{replacement,order}') <> 'array'
    or (config_to_check #>> '{sr,shorthandedQualifyingActualMinutes}')::integer
      not between 0 and 180
    or (config_to_check #>> '{injury,strikeDelta}')::integer not between 0 and 20
    or (config_to_check #>> '{solo,cancellations,late,discountBps}')::integer
      <> (config_to_check #>> '{replacement,lateCancellationDiscountBps}')::integer
    or (config_to_check #>> '{solo,cancellations,late,notify}')::boolean
      is distinct from (config_to_check #>>
        '{replacement,notifyEligiblePlayersOnLateCancellation}')::boolean
  then
    return false;
  end if;

  if (config_to_check #>> '{clan,playersPerSide}')::integer not between 1 and 20
    or (config_to_check #>> '{clan,minimumOnTimeWithoutClanStrike}')::integer
      not between 1 and 20
    or (config_to_check #>> '{clan,minimumOnTimeWithoutClanStrike}')::integer
      > (config_to_check #>> '{clan,playersPerSide}')::integer
    or (config_to_check #>> '{clan,minimumAtKickoffWithoutForfeit}')::integer
      not between 1 and 20
    or (config_to_check #>> '{clan,minimumAtKickoffWithoutForfeit}')::integer
      > (config_to_check #>> '{clan,playersPerSide}')::integer
    or (config_to_check #>> '{clan,minimumAtKickoffWithoutForfeit}')::integer < 1
    or (config_to_check #>> '{clan,partialAttendanceStrikes}')::integer
      not between 0 and 20
    or (config_to_check #>> '{clan,forfeitStrikes}')::integer not between 0 and 20
    or (config_to_check #>> '{clan,entireClanNoShowStrikes}')::integer
      not between 0 and 20
    or (config_to_check #>> '{clan,forfeitScore}')::integer not between 0 and 99
    or (config_to_check #>> '{clan,cancellations,early,minimumHoursBeforeKickoff}')::numeric
      <= (config_to_check #>> '{clan,cancellations,late,minimumHoursBeforeKickoff}')::numeric
    or (config_to_check #>> '{clan,cancellations,late,minimumHoursBeforeKickoff}')::numeric < 0
    or (config_to_check #>> '{clan,cancellations,early,minimumHoursBeforeKickoff}')::numeric > 8760
    or (config_to_check #>> '{clan,cancellations,late,minimumHoursBeforeKickoff}')::numeric > 8760
    or (config_to_check #>> '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer
      not between 1 and 20
  then
    return false;
  end if;

  if jsonb_array_length(config_to_check #> '{solo,sanctions}') = 0
    or jsonb_array_length(config_to_check #> '{clan,sanctions}') = 0
  then
    return false;
  end if;

  previous_threshold := 0;
  for sanction in
    select value from jsonb_array_elements(config_to_check #> '{solo,sanctions}')
  loop
    if not public.jsonb_object_has_exact_keys(
        sanction,
        array['threshold', 'kind', 'durationDays', 'releaseFutureBookings']
      )
      or jsonb_typeof(sanction -> 'threshold') <> 'number'
      or jsonb_typeof(sanction -> 'kind') <> 'string'
      or jsonb_typeof(sanction -> 'releaseFutureBookings') <> 'boolean'
      or (sanction ->> 'threshold')::numeric
        <> trunc((sanction ->> 'threshold')::numeric)
      or (sanction ->> 'threshold')::integer <= previous_threshold
      or (sanction ->> 'threshold')::integer > 20
      or sanction ->> 'kind' not in (
        'WARNING',
        'BOOKING_RESTRICTION',
        'PARTICIPATION_SUSPENSION',
        'INDEFINITE_SUSPENSION'
      )
      or (
        sanction ->> 'kind' = 'INDEFINITE_SUSPENSION'
        and jsonb_typeof(sanction -> 'durationDays') <> 'null'
      )
      or (
        sanction ->> 'kind' <> 'INDEFINITE_SUSPENSION'
        and (
          jsonb_typeof(sanction -> 'durationDays') <> 'number'
          or (sanction ->> 'durationDays')::numeric
            <> trunc((sanction ->> 'durationDays')::numeric)
          or (sanction ->> 'durationDays')::integer not between 0 and 3650
        )
      )
    then
      return false;
    end if;
    previous_threshold := (sanction ->> 'threshold')::integer;
  end loop;

  previous_threshold := 0;
  for sanction in
    select value from jsonb_array_elements(config_to_check #> '{clan,sanctions}')
  loop
    if not public.jsonb_object_has_exact_keys(
        sanction, array['threshold', 'kind', 'durationDays']
      )
      or jsonb_typeof(sanction -> 'threshold') <> 'number'
      or jsonb_typeof(sanction -> 'kind') <> 'string'
      or (sanction ->> 'threshold')::numeric
        <> trunc((sanction ->> 'threshold')::numeric)
      or (sanction ->> 'threshold')::integer <= previous_threshold
      or (sanction ->> 'threshold')::integer > 20
      or sanction ->> 'kind' not in (
        'WARNING',
        'BOOKING_RESTRICTION',
        'PARTICIPATION_SUSPENSION',
        'INDEFINITE_SUSPENSION'
      )
      or (
        sanction ->> 'kind' = 'INDEFINITE_SUSPENSION'
        and jsonb_typeof(sanction -> 'durationDays') <> 'null'
      )
      or (
        sanction ->> 'kind' <> 'INDEFINITE_SUSPENSION'
        and (
          jsonb_typeof(sanction -> 'durationDays') <> 'number'
          or (sanction ->> 'durationDays')::numeric
            <> trunc((sanction ->> 'durationDays')::numeric)
          or (sanction ->> 'durationDays')::integer not between 0 and 3650
        )
      )
    then
      return false;
    end if;
    previous_threshold := (sanction ->> 'threshold')::integer;
  end loop;

  if jsonb_array_length(config_to_check #> '{replacement,order}') <> 3
    or exists (
      select 1
      from jsonb_array_elements_text(
        config_to_check #> '{replacement,order}'
      ) items(item)
      where item not in (
        'EMERGENCY_NOTIFICATION', 'ON_FIELD_RESERVE', 'PLAY_SHORTHANDED'
      )
    )
    or (
      select count(distinct item)
      from jsonb_array_elements_text(
        config_to_check #> '{replacement,order}'
      ) items(item)
    ) <> 3
    or jsonb_array_length(
      config_to_check #> '{solo,reliabilityDeposit,forfeitOutcomes}'
    ) = 0
    or exists (
      select 1
      from jsonb_array_elements_text(
        config_to_check #> '{solo,reliabilityDeposit,forfeitOutcomes}'
      ) items(item)
      where item not in (
        'LATE', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE', 'NO_SHOW'
      )
    )
    or (
      select count(distinct item)
      from jsonb_array_elements_text(
        config_to_check #> '{solo,reliabilityDeposit,forfeitOutcomes}'
      ) items(item)
    ) <> jsonb_array_length(
      config_to_check #> '{solo,reliabilityDeposit,forfeitOutcomes}'
    )
    or jsonb_array_length(config_to_check #> '{appeals,allowedCategories}') = 0
    or exists (
      select 1
      from jsonb_array_elements_text(
        config_to_check #> '{appeals,allowedCategories}'
      ) items(item)
      where item not in (
        'FIELD_OR_VENUE_ERROR', 'VENUE_ACCESS_BLOCKED',
        'VERIFIED_MEDICAL_EMERGENCY', 'SERIOUS_ACCIDENT_OR_EMERGENCY',
        'WRONG_PLAYER_CHECKED_IN', 'APP_OR_OPERATOR_ERROR', 'OTHER'
      )
    )
    or (
      select count(distinct item)
      from jsonb_array_elements_text(
        config_to_check #> '{appeals,allowedCategories}'
      ) items(item)
    ) <> jsonb_array_length(config_to_check #> '{appeals,allowedCategories}')
    or jsonb_typeof(
      config_to_check #> '{clan,reliabilityDeposit,forfeitOutcomes}'
    ) <> 'array'
    or jsonb_array_length(
      config_to_check #> '{clan,reliabilityDeposit,forfeitOutcomes}'
    ) = 0
    or exists (
      select 1
      from jsonb_array_elements_text(
        config_to_check #> '{clan,reliabilityDeposit,forfeitOutcomes}'
      ) items(item)
      where item not in (
        'PARTIAL_LATE', 'FORFEIT', 'ENTIRE_CLAN_NO_SHOW',
        'CANCELLED_EARLY', 'CANCELLED_LATE',
        'CANCELLED_VERY_LATE', 'NO_SHOW'
      )
    )
    or (
      select count(distinct item)
      from jsonb_array_elements_text(
        config_to_check #> '{clan,reliabilityDeposit,forfeitOutcomes}'
      ) items(item)
    ) <> jsonb_array_length(
      config_to_check #> '{clan,reliabilityDeposit,forfeitOutcomes}'
    )
    or config_to_check #>> '{wallet,refundDestination}' <> 'FIELD_WALLET'
    or config_to_check #>> '{wallet,currency}' <> 'BHD'
  then
    return false;
  end if;

  return true;
exception
  when others then
    return false;
end;
$$;

create table public.reliability_policy_versions (
  id uuid primary key default gen_random_uuid(),
  version integer not null unique check (version > 0),
  state text not null default 'DRAFT' check (state in ('DRAFT', 'PUBLISHED')),
  schema_version integer not null default 1 check (schema_version = 1),
  effective_from timestamptz not null,
  config jsonb not null check (
    public.reliability_policy_config_is_valid(config)
  ),
  summary text not null check (char_length(trim(summary)) between 3 and 500),
  supersedes_id uuid references public.reliability_policy_versions(id)
    on delete restrict,
  created_by uuid references public.referee_profiles(profile_id)
    on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  published_by uuid references public.referee_profiles(profile_id)
    on delete restrict,
  published_at timestamptz,
  check (
    version = 1
    or effective_from = (
      date_trunc('day', effective_from at time zone 'Asia/Bahrain')
        at time zone 'Asia/Bahrain'
    )
  ),
  check (
    (state = 'DRAFT' and published_at is null and published_by is null)
    or (state = 'PUBLISHED' and published_at is not null)
  )
);

create unique index reliability_policy_published_effective_idx
on public.reliability_policy_versions (effective_from)
where state = 'PUBLISHED';

create index reliability_policy_timeline_idx
on public.reliability_policy_versions (state, effective_from desc);

drop trigger if exists set_reliability_policy_updated_at
on public.reliability_policy_versions;
create trigger set_reliability_policy_updated_at
before update on public.reliability_policy_versions
for each row execute function public.set_updated_at();

create or replace function public.protect_published_reliability_policy()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' and old.state = 'PUBLISHED' then
    raise exception 'Published reliability policies are immutable.';
  end if;
  if tg_op = 'UPDATE' and old.state = 'PUBLISHED' then
    raise exception 'Published reliability policies are immutable. Create a new version.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists protect_published_reliability_policy
on public.reliability_policy_versions;
create trigger protect_published_reliability_policy
before update or delete on public.reliability_policy_versions
for each row execute function public.protect_published_reliability_policy();

alter table public.reliability_policy_versions enable row level security;
revoke all on table public.reliability_policy_versions
from public, anon, authenticated;
grant all on table public.reliability_policy_versions to service_role;

insert into public.reliability_policy_versions (
  version,
  state,
  schema_version,
  effective_from,
  config,
  summary,
  published_at
) values (
  1,
  'PUBLISHED',
  1,
  clock_timestamp(),
  $policy$
  {
    "schemaVersion": 1,
    "timezone": "Asia/Bahrain",
    "attendance": {
      "checkInOpenLeadMinutes": 120,
      "checkInLeadMinutes": 15,
      "noShowGraceMinutes": 10,
      "strikeLifetimeDays": 90,
      "appealWindowHours": 48,
      "hostCheckInRequired": true,
      "cancellationAfterKickoffOutcome": "NO_SHOW"
    },
    "solo": {
      "playersPerSide": 6,
      "cancellations": {
        "early": {"minimumHoursBeforeKickoff": 24, "strikes": 0, "refundBps": 10000, "advertise": false, "discountBps": 0, "notify": false},
        "late": {"minimumHoursBeforeKickoff": 10, "strikes": 1, "refundBps": 5000, "advertise": true, "discountBps": 5000, "notify": true},
        "veryLate": {"strikes": 1, "refundBps": 0, "advertise": false, "discountBps": 0, "notify": false},
        "afterKickoff": {"strikes": 2, "refundBps": 0}
      },
      "outcomes": {
        "onTime": {"strikes": 0, "refundBps": 0},
        "late": {"strikes": 1, "refundBps": 0},
        "noShow": {"strikes": 2, "refundBps": 0},
        "fieldCancelled": {"strikes": 0, "refundBps": 10000}
      },
      "reliabilityDeposit": {
        "activeStrikeThreshold": 2,
        "depositBps": 2000,
        "onTimeReturnDestination": "FIELD_WALLET",
        "forfeitOutcomes": ["LATE", "CANCELLED_LATE", "CANCELLED_VERY_LATE", "NO_SHOW"]
      },
      "sanctions": [
        {"threshold": 1, "kind": "WARNING", "durationDays": 0, "releaseFutureBookings": false},
        {"threshold": 3, "kind": "BOOKING_RESTRICTION", "durationDays": 7, "releaseFutureBookings": false},
        {"threshold": 4, "kind": "BOOKING_RESTRICTION", "durationDays": 14, "releaseFutureBookings": false},
        {"threshold": 5, "kind": "PARTICIPATION_SUSPENSION", "durationDays": 30, "releaseFutureBookings": true},
        {"threshold": 6, "kind": "INDEFINITE_SUSPENSION", "durationDays": null, "releaseFutureBookings": true}
      ],
      "highestCrossedOnly": true,
      "releaseFutureBookingsRefundBps": 10000,
      "teamAssignmentLeadMinutes": 180,
      "partyLockLeadMinutes": 180
    },
    "replacement": {
      "lateCancellationDiscountBps": 5000,
      "notifyEligiblePlayersOnLateCancellation": true,
      "postCheckInDeadlineMarketplaceEnabled": false,
      "reserveActivationMinutesAfterKickoff": 10,
      "originalPlayerReclaimUntilMinutesAfterKickoff": 10,
      "order": ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE", "PLAY_SHORTHANDED"],
      "maxPartySize": 4
    },
    "sr": {
      "latePositiveMultiplierBps": 8000,
      "lateNegativeMultiplierBps": 12000,
      "shorthandedQualifyingActualMinutes": 10,
      "protectedLosingOnTimeMultiplierBps": 0,
      "protectedWinnerMultiplierBps": 8000,
      "disadvantagedWinnerMultiplierBps": 10000,
      "latePlayerGetsTeamProtection": false
    },
    "injury": {
      "strikeDelta": 0,
      "requiresRefereeVerification": true,
      "halfMatchThresholdBps": 5000,
      "completedLossMultiplierBps": 8000,
      "incompleteLosingMultiplierBps": 0,
      "incompleteWinningMultiplierBps": 10000,
      "incompleteRefundBps": 10000
    },
    "clan": {
      "playersPerSide": 7,
      "minimumOnTimeWithoutClanStrike": 6,
      "minimumAtKickoffWithoutForfeit": 6,
      "partialAttendanceStrikes": 1,
      "forfeitStrikes": 2,
      "entireClanNoShowStrikes": 2,
      "forfeitScore": 3,
      "cancellations": {
        "early": {"minimumHoursBeforeKickoff": 24, "strikes": 0, "refundBps": 10000},
        "late": {"minimumHoursBeforeKickoff": 10, "strikes": 1, "refundBps": 5000},
        "veryLate": {"strikes": 2, "refundBps": 0},
        "afterKickoff": {"strikes": 2, "refundBps": 0, "forfeit": true}
      },
      "reliabilityDeposit": {
        "activeStrikeThreshold": 2,
        "depositBps": 2000,
        "forfeitOutcomes": [
          "PARTIAL_LATE", "FORFEIT", "ENTIRE_CLAN_NO_SHOW",
          "CANCELLED_LATE", "CANCELLED_VERY_LATE", "NO_SHOW"
        ]
      },
      "sanctions": [
        {"threshold": 1, "kind": "WARNING", "durationDays": 0},
        {"threshold": 3, "kind": "BOOKING_RESTRICTION", "durationDays": 14},
        {"threshold": 4, "kind": "PARTICIPATION_SUSPENSION", "durationDays": 30},
        {"threshold": 5, "kind": "INDEFINITE_SUSPENSION", "durationDays": null}
      ]
    },
    "appeals": {
      "allowedCategories": ["FIELD_OR_VENUE_ERROR", "VENUE_ACCESS_BLOCKED", "VERIFIED_MEDICAL_EMERGENCY", "SERIOUS_ACCIDENT_OR_EMERGENCY", "WRONG_PLAYER_CHECKED_IN", "APP_OR_OPERATOR_ERROR", "OTHER"],
      "routineTrafficAutomaticallyExcused": false
    },
    "wallet": {"refundDestination": "FIELD_WALLET", "currency": "BHD"}
  }
  $policy$::jsonb,
  'Season Zero reliability policy · Draft v0.1',
  clock_timestamp()
);

create or replace function public.resolve_reliability_policy_id(
  effective_at_to_use timestamptz
)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select policy.id
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= effective_at_to_use
  order by policy.effective_from desc, policy.version desc
  limit 1;
$$;

create or replace function public.get_reliability_policy_for_time(
  effective_at_to_use timestamptz default clock_timestamp()
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', policy.id,
    'version', policy.version,
    'effective_from', policy.effective_from,
    'config', policy.config,
    'summary', policy.summary
  )
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= effective_at_to_use
  order by policy.effective_from desc, policy.version desc
  limit 1;
$$;

create or replace function public.admin_create_reliability_policy_draft(
  actor_admin_id uuid,
  source_version_id uuid,
  effective_from_to_use timestamptz,
  summary_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  source_policy public.reliability_policy_versions%rowtype;
  created_id uuid;
  next_version integer;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if effective_from_to_use <= clock_timestamp() then
    raise exception 'A reliability policy cannot be backdated.';
  end if;
  if effective_from_to_use <> (
    date_trunc('day', effective_from_to_use at time zone 'Asia/Bahrain')
      at time zone 'Asia/Bahrain'
  ) then
    raise exception 'Choose a Bahrain calendar date; policy changes begin at 12:00 AM Bahrain time.';
  end if;
  if char_length(trim(coalesce(summary_to_use, ''))) not between 3 and 500 then
    raise exception 'Describe this policy change.';
  end if;

  perform pg_advisory_xact_lock(hashtext('reliability-policy-version')::bigint);

  if source_version_id is null then
    select * into source_policy
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
    order by policy.effective_from desc, policy.version desc
    limit 1;
  else
    select * into source_policy
    from public.reliability_policy_versions policy
    where policy.id = source_version_id;
  end if;

  if source_policy.id is null then
    raise exception 'Source reliability policy not found.';
  end if;

  select coalesce(max(version), 0) + 1 into next_version
  from public.reliability_policy_versions;

  insert into public.reliability_policy_versions (
    version,
    state,
    schema_version,
    effective_from,
    config,
    summary,
    supersedes_id,
    created_by
  ) values (
    next_version,
    'DRAFT',
    1,
    effective_from_to_use,
    source_policy.config,
    trim(summary_to_use),
    source_policy.id,
    actor_admin_id
  ) returning id into created_id;

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    after_state
  ) values (
    actor_admin_id,
    'RELIABILITY_POLICY_DRAFT_CREATED',
    'POLICY',
    created_id,
    trim(summary_to_use),
    jsonb_build_object(
      'effective_from', effective_from_to_use,
      'source_policy_id', source_policy.id,
      'version', next_version
    )
  );

  return created_id;
end;
$$;

create or replace function public.admin_update_reliability_policy_draft(
  actor_admin_id uuid,
  policy_id_to_update uuid,
  config_to_use jsonb,
  effective_from_to_use timestamptz,
  summary_to_use text,
  expected_updated_at timestamptz
)
returns public.reliability_policy_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_policy public.reliability_policy_versions%rowtype;
  updated_policy public.reliability_policy_versions%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;

  select * into current_policy
  from public.reliability_policy_versions policy
  where policy.id = policy_id_to_update
  for update;

  if current_policy.id is null then
    raise exception 'Reliability policy draft not found.';
  end if;
  if current_policy.state <> 'DRAFT' then
    raise exception 'Published reliability policies cannot be edited.';
  end if;
  if expected_updated_at is null
    or current_policy.updated_at is distinct from expected_updated_at
  then
    raise exception using
      errcode = '40001',
      message = 'This draft changed in another session. Refresh before saving.';
  end if;
  if effective_from_to_use <= clock_timestamp() then
    raise exception 'A reliability policy cannot be backdated.';
  end if;
  if effective_from_to_use <> (
    date_trunc('day', effective_from_to_use at time zone 'Asia/Bahrain')
      at time zone 'Asia/Bahrain'
  ) then
    raise exception 'Choose a Bahrain calendar date; policy changes begin at 12:00 AM Bahrain time.';
  end if;
  if not public.reliability_policy_config_is_valid(config_to_use) then
    raise exception 'Reliability policy settings are incomplete or invalid.';
  end if;
  if char_length(trim(coalesce(summary_to_use, ''))) not between 3 and 500 then
    raise exception 'Describe this policy change.';
  end if;

  update public.reliability_policy_versions
  set
    config = config_to_use,
    effective_from = effective_from_to_use,
    summary = trim(summary_to_use)
  where id = current_policy.id
  returning * into updated_policy;

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
    'RELIABILITY_POLICY_DRAFT_UPDATED',
    'POLICY',
    current_policy.id,
    trim(summary_to_use),
    jsonb_build_object(
      'effective_from', current_policy.effective_from,
      'config', current_policy.config,
      'summary', current_policy.summary
    ),
    jsonb_build_object(
      'effective_from', updated_policy.effective_from,
      'config', updated_policy.config,
      'summary', updated_policy.summary
    )
  );

  return updated_policy;
end;
$$;

create or replace function public.admin_publish_reliability_policy(
  actor_admin_id uuid,
  policy_id_to_publish uuid,
  reason_to_use text
)
returns public.reliability_policy_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  draft public.reliability_policy_versions%rowtype;
  published public.reliability_policy_versions%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(trim(coalesce(reason_to_use, ''))) not between 5 and 2000 then
    raise exception 'Explain why this policy version is being published.';
  end if;

  select * into draft
  from public.reliability_policy_versions policy
  where policy.id = policy_id_to_publish
  for update;

  if draft.id is null then
    raise exception 'Reliability policy draft not found.';
  end if;
  if draft.state = 'PUBLISHED' then
    return draft;
  end if;
  if draft.effective_from <= clock_timestamp() then
    raise exception 'The effective date must still be in the future.';
  end if;
  if draft.effective_from <> (
    date_trunc('day', draft.effective_from at time zone 'Asia/Bahrain')
      at time zone 'Asia/Bahrain'
  ) then
    raise exception 'Policy changes must begin at 12:00 AM Bahrain time.';
  end if;
  if not public.reliability_policy_config_is_valid(draft.config) then
    raise exception 'Reliability policy settings are incomplete or invalid.';
  end if;
  if exists (
    select 1
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from = draft.effective_from
      and policy.id <> draft.id
  ) then
    raise exception 'Another policy is already scheduled for this exact time.';
  end if;

  update public.reliability_policy_versions
  set
    state = 'PUBLISHED',
    published_by = actor_admin_id,
    published_at = clock_timestamp()
  where id = draft.id
  returning * into published;

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
    'RELIABILITY_POLICY_PUBLISHED',
    'POLICY',
    published.id,
    trim(reason_to_use),
    jsonb_build_object('state', 'DRAFT'),
    jsonb_build_object(
      'state', 'PUBLISHED',
      'version', published.version,
      'effective_from', published.effective_from,
      'config', published.config,
      'summary', published.summary
    )
  );

  return published;
end;
$$;

revoke all on function public.jsonb_object_has_exact_keys(jsonb,text[])
from public, anon, authenticated;
revoke all on function public.reliability_policy_config_is_valid(jsonb)
from public, anon, authenticated;
revoke all on function public.resolve_reliability_policy_id(timestamptz)
from public, anon, authenticated;
revoke all on function public.get_reliability_policy_for_time(timestamptz)
from public, anon, authenticated;
grant execute on function public.get_reliability_policy_for_time(timestamptz)
to authenticated, service_role;

revoke all on function public.admin_create_reliability_policy_draft(
  uuid, uuid, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.admin_create_reliability_policy_draft(
  uuid, uuid, timestamptz, text
) to service_role;

revoke all on function public.admin_update_reliability_policy_draft(
  uuid, uuid, jsonb, timestamptz, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.admin_update_reliability_policy_draft(
  uuid, uuid, jsonb, timestamptz, text, timestamptz
) to service_role;

revoke all on function public.admin_publish_reliability_policy(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_publish_reliability_policy(
  uuid, uuid, text
) to service_role;

comment on table public.reliability_policy_versions is
'Append-only, effective-dated reliability rules. Every operational decision snapshots the published version it used.';
