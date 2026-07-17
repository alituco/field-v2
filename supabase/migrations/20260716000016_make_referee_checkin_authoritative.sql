-- Attendance is recorded by the assigned referee. A clan's mobile matchday
-- roster remains the planned/no-show roster, but it must never prevent the
-- referee from recording an eligible active clan member who arrives instead.

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
  reserve_activation_minutes integer;
  reclaim_until_minutes integer;
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

  reserve_activation_minutes := (terms_to_use.policy_snapshot #>>
    '{replacement,reserveActivationMinutesAfterKickoff}')::integer;
  reclaim_until_minutes := (terms_to_use.policy_snapshot #>>
    '{replacement,originalPlayerReclaimUntilMinutesAfterKickoff}')::integer;

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
    if normalized_kind = 'CLAN' then
      perform public.initialize_fixture_reliability_roster(match_id_to_use);
    end if;
    perform public.ensure_match_attendance_records(
      normalized_kind,
      match_id_to_use
    );

    -- Match totals and no-show finalization stay scoped to the planned roster
    -- plus any player the referee has explicitly promoted by checking in.
    select
      count(*) filter (
        where attendance.expected_for_match
          and attendance.outcome is null
      )::integer,
      count(*) filter (
        where attendance.expected_for_match
          and attendance.outcome = 'NO_SHOW'
      )::integer,
      count(*) filter (where attendance.expected_for_match)::integer,
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
      and coalesce(attendance.outcome, '') not in (
        'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
      );

    -- Officials see the planned roster and, while check-in is still open,
    -- every other eligible active clan member they may need to check in.
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'attendance_record_id', attendance.id,
        'profile_id', attendance.profile_id,
        'display_name', profile.display_name,
        'expected_for_match', attendance.expected_for_match,
        'check_in_eligible', case
          when normalized_kind = 'SOLO' then attendance.expected_for_match
          when attendance.checked_in_at is not null then true
          else exists (
            select 1
            from public.fixtures fixture
            join public.clan_members member
              on member.clan_id in (
                fixture.home_clan_id,
                fixture.away_clan_id
              )
            where fixture.id = match_id_to_use
              and member.profile_id = attendance.profile_id
              and member.clan_id = attendance.clan_id
              and member.left_at is null
              and not public.profile_has_active_play_restriction(
                member.profile_id
              )
              and (
                select count(*)
                from public.match_attendance_records checked
                where checked.terms_id = terms_to_use.id
                  and checked.clan_id = attendance.clan_id
                  and checked.checked_in_at is not null
              ) < (terms_to_use.policy_snapshot #>>
                '{clan,playersPerSide}')::integer
          )
        end,
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
      ) order by
        attendance.side,
        attendance.expected_for_match desc,
        profile.display_name,
        attendance.profile_id
    ), '[]'::jsonb) into players_to_use
    from public.match_attendance_records attendance
    join public.profiles profile on profile.id = attendance.profile_id
    left join public.clans clan on clan.id = attendance.clan_id
    where attendance.terms_id = terms_to_use.id
      and (
        attendance.expected_for_match
        or attendance.checked_in_at is not null
        or (
          normalized_kind = 'CLAN'
          and server_now_to_use < terms_to_use.no_show_cutoff_at
          and exists (
            select 1
            from public.fixtures fixture
            join public.clan_members member
              on member.clan_id in (
                fixture.home_clan_id,
                fixture.away_clan_id
              )
            where fixture.id = match_id_to_use
              and member.profile_id = attendance.profile_id
              and member.clan_id = attendance.clan_id
              and member.left_at is null
              and not public.profile_has_active_play_restriction(
                member.profile_id
              )
          )
        )
      )
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
    'reserve_activation_minutes_after_kickoff', reserve_activation_minutes,
    'reserve_activation_at', terms_to_use.kickoff_at +
      make_interval(mins => reserve_activation_minutes),
    'original_player_reclaim_until_minutes_after_kickoff', reclaim_until_minutes,
    'original_player_reclaim_until_at', terms_to_use.kickoff_at +
      make_interval(mins => reclaim_until_minutes),
    'replacement_order', terms_to_use.policy_snapshot #> '{replacement,order}',
    'reserve_plan_automated', false,
    'reserve_plan_authority', 'FIELD_HOST',
    'can_check_in',
      can_view_roster
      and server_now_to_use >= terms_to_use.check_in_opens_at
      and server_now_to_use < terms_to_use.no_show_cutoff_at,
    'check_in_authority', 'REFEREE',
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

create or replace function public.referee_check_in_player(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_check_in uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  attendance_to_use public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  checked_in_at_to_use timestamptz := clock_timestamp();
  outcome_to_use text;
  rule_to_use jsonb;
  strike_delta_to_use integer;
  positive_multiplier integer := 10000;
  negative_multiplier integer := 10000;
  forfeit_deposit boolean;
  required_count_to_use integer;
  checked_side_count_to_use integer;
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'You are not assigned to manage this match.';
  end if;
  if normalized_kind = 'SOLO' and not exists (
    select 1
    from public.open_queue_games game
    where game.id = match_id_to_use
      and game.status in ('OPEN', 'FULL', 'LIVE')
  ) then
    raise exception 'This solo match is not active.';
  elsif normalized_kind = 'CLAN' and not exists (
    select 1
    from public.fixtures fixture
    where fixture.id = match_id_to_use
      and fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
  ) then
    raise exception 'This clan match is not active.';
  end if;

  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);
  if normalized_kind = 'CLAN' then
    perform public.initialize_fixture_reliability_roster(match_id_to_use);
  end if;
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
    and attendance.profile_id = profile_id_to_check_in
    and (
      normalized_kind <> 'CLAN'
      or exists (
        select 1
        from public.fixtures fixture
        join public.clan_members member
          on member.clan_id in (
            fixture.home_clan_id,
            fixture.away_clan_id
          )
        where fixture.id = match_id_to_use
          and member.profile_id = attendance.profile_id
          and member.clan_id = attendance.clan_id
          and member.left_at is null
          and not public.profile_has_active_play_restriction(
            member.profile_id
          )
      )
    )
  for update;
  if attendance_to_use.id is null then
    raise exception 'This player is not eligible for this match.';
  end if;
  if attendance_to_use.checked_in_at is not null then
    return public.get_match_reliability_context(normalized_kind, match_id_to_use);
  end if;
  if attendance_to_use.outcome is not null then
    raise exception 'This player already has a final attendance outcome.';
  end if;
  if checked_in_at_to_use < terms_to_use.check_in_opens_at then
    raise exception 'Check-in opens at %.', terms_to_use.check_in_opens_at;
  end if;
  if checked_in_at_to_use >= terms_to_use.no_show_cutoff_at then
    raise exception 'The no-show cutoff has passed. Finalize attendance instead.';
  end if;

  if normalized_kind = 'CLAN' then
    required_count_to_use := (terms_to_use.policy_snapshot #>>
      '{clan,playersPerSide}')::integer;
    select count(*)::integer into checked_side_count_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.clan_id = attendance_to_use.clan_id
      and attendance.checked_in_at is not null;
    if checked_side_count_to_use >= required_count_to_use then
      raise exception 'This team already has all % players checked in.',
        required_count_to_use;
    end if;
  end if;

  if checked_in_at_to_use <= terms_to_use.check_in_deadline_at then
    outcome_to_use := 'ON_TIME';
    rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,onTime}';
  else
    outcome_to_use := 'LATE';
    rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,late}';
    positive_multiplier := (terms_to_use.policy_snapshot #>>
      '{sr,latePositiveMultiplierBps}')::integer;
    negative_multiplier := (terms_to_use.policy_snapshot #>>
      '{sr,lateNegativeMultiplierBps}')::integer;
  end if;
  strike_delta_to_use := (rule_to_use ->> 'strikes')::integer;
  select exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #>
        '{solo,reliabilityDeposit,forfeitOutcomes}'
    ) forfeited(outcome)
    where forfeited.outcome = outcome_to_use
  ) into forfeit_deposit;

  update public.match_attendance_records
  set
    checked_in_at = checked_in_at_to_use,
    checked_in_by = actor_referee_id,
    outcome = outcome_to_use,
    strike_delta = strike_delta_to_use,
    refund_bps = (rule_to_use ->> 'refundBps')::integer,
    positive_sr_multiplier_bps = positive_multiplier,
    negative_sr_multiplier_bps = negative_multiplier,
    finalized_at = checked_in_at_to_use,
    appeal_due_at = checked_in_at_to_use + make_interval(
      hours => (terms_to_use.policy_snapshot #>>
        '{attendance,appealWindowHours}')::integer
    ),
    consequence_snapshot = jsonb_build_object(
      'policy_version_id', terms_to_use.policy_version_id,
      'outcome_code', outcome_to_use,
      'strike_delta', strike_delta_to_use,
      'refund_bps', (rule_to_use ->> 'refundBps')::integer,
      'deposit_forfeited', forfeit_deposit,
      'positive_sr_multiplier_bps', positive_multiplier,
      'negative_sr_multiplier_bps', negative_multiplier,
      'checked_in_at', checked_in_at_to_use,
      'check_in_opens_at', terms_to_use.check_in_opens_at,
      'check_in_deadline_at', terms_to_use.check_in_deadline_at,
      'referee_authoritative', true,
      'planned_roster_member', attendance_to_use.expected_for_match
    )
  where id = attendance_to_use.id
  returning * into attendance_to_use;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    actor_referee_id,
    event_at,
    detail,
    idempotency_key
  ) values (
    attendance_to_use.id,
    'CHECKED_IN',
    actor_referee_id,
    checked_in_at_to_use,
    attendance_to_use.consequence_snapshot,
    'checked-in:' || attendance_to_use.id::text
  ) on conflict (idempotency_key) do nothing;

  perform public.settle_reliability_deposit(
    attendance_to_use.id,
    not forfeit_deposit
  );
  perform public.apply_attendance_refund(attendance_to_use.id);

  perform public.record_reliability_incident(
    attendance_to_use.id,
    outcome_to_use,
    strike_delta_to_use,
    checked_in_at_to_use
  );

  if strike_delta_to_use > 0 then
    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    ) values (
      attendance_to_use.profile_id,
      'RELIABILITY_OUTCOME',
      'Attendance recorded as late',
      'Checked in after the hard deadline. ' || strike_delta_to_use ||
        case when strike_delta_to_use = 1
          then ' reliability strike was added.'
          else ' reliability strikes were added.' end,
      'MATCH_ATTENDANCE',
      attendance_to_use.id,
      attendance_to_use.consequence_snapshot
    );
  end if;

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

-- Clan-level readiness counts actual referee-confirmed arrivals, including an
-- eligible substitute, while expected_count remains the seven-player planned
-- roster used for individual no-show liability.
do $migration$
declare
  function_definition text;
  old_text text;
  new_text text;
begin
  select pg_get_functiondef(
    'public.finalize_clan_reliability_outcomes(uuid,uuid)'::regprocedure
  ) into function_definition;

  old_text := $old$    select
      count(*)::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.check_in_deadline_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.kickoff_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at < terms_to_use.no_show_cutoff_at
      )::integer
    into
      expected_count_to_use,
      on_time_count_to_use,
      kickoff_count_to_use,
      cutoff_count_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.clan_id = clan_id_to_use
      and attendance.expected_for_match;$old$;

  new_text := $new$    select
      count(*) filter (where attendance.expected_for_match)::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.check_in_deadline_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.kickoff_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at < terms_to_use.no_show_cutoff_at
      )::integer
    into
      expected_count_to_use,
      on_time_count_to_use,
      kickoff_count_to_use,
      cutoff_count_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.clan_id = clan_id_to_use;$new$;

  if position(old_text in function_definition) = 0 then
    raise exception 'Could not make clan readiness use referee-confirmed arrivals.';
  end if;
  execute replace(function_definition, old_text, new_text);
end;
$migration$;

-- One attendance record currently represents one player in one solo game.
-- Prevent a cancelled booking from being recreated for that same player/game,
-- which would otherwise inherit the already-final cancellation outcome and
-- make official check-in impossible. The reopened place remains available to
-- every other eligible player as intended by the cancellation policy.
create or replace function public.prevent_same_solo_game_rebooking()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1
    from public.open_queue_bookings prior
    where prior.game_id = new.game_id
      and prior.profile_id = new.profile_id
      and prior.status = 'CANCELLED'
  ) then
    raise exception 'After cancelling a solo game, you cannot book that same game again.';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_same_solo_game_rebooking
on public.open_queue_bookings;
create trigger prevent_same_solo_game_rebooking
before insert on public.open_queue_bookings
for each row execute function public.prevent_same_solo_game_rebooking();

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

revoke all on function public.referee_check_in_player(uuid,text,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.referee_check_in_player(uuid,text,uuid,uuid)
to service_role;

revoke all on function public.prevent_same_solo_game_rebooking()
from public, anon, authenticated;

comment on function public.get_match_reliability_context(text,uuid) is
'Returns player-safe timing to participants and an official roster plus eligible referee check-in candidates only to the assigned referee or service role.';

comment on function public.referee_check_in_player(uuid,text,uuid,uuid) is
'Records referee-authoritative attendance for an eligible active match player without allowing mobile self check-in or expanding the seven-player planned no-show roster.';

comment on function public.prevent_same_solo_game_rebooking() is
'Prevents a cancelled same-game booking from reusing a finalized attendance record; the cancelled place stays open for another eligible player.';
