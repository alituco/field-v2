-- Referee arrival taps are provisional until the no-show cutoff. This makes
-- an accidental tap safely reversible before play without attempting to claw
-- back wallet credits, sanctions, released bookings, or other settled effects.

alter table public.match_attendance_records
add column if not exists check_in_revision integer not null default 0;

alter table public.match_attendance_records
drop constraint if exists match_attendance_records_check_in_revision_check;
alter table public.match_attendance_records
add constraint match_attendance_records_check_in_revision_check
check (check_in_revision between 0 and 10000);

alter table public.attendance_events
drop constraint if exists attendance_events_event_type_check;
alter table public.attendance_events
add constraint attendance_events_event_type_check
check (
  event_type in (
    'EXPECTED',
    'CHECKED_IN',
    'CHECK_IN_REMOVED',
    'ATTENDANCE_FINALIZED',
    'CANCELLED',
    'NO_SHOW_FINALIZED',
    'DEPOSIT_RETURNED',
    'DEPOSIT_FORFEITED',
    'REPLACEMENT_ACTIVATED',
    'INJURY_RECORDED',
    'ADMIN_CORRECTION',
    'APPEAL_OVERTURNED'
  )
);

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
  match_started_to_use boolean := false;
  terms_to_use public.match_reliability_terms%rowtype;
  server_now_to_use timestamptz := clock_timestamp();
  unresolved_count integer;
  missing_unresolved_count integer;
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
      from public.open_queue_games game
      left join public.open_queue_clock_states clock
        on clock.game_id = game.id
      where game.id = match_id_to_use
        and (
          game.status in ('LIVE', 'FINAL', 'CANCELLED')
          or clock.status in ('RUNNING', 'PAUSED', 'ENDED')
        )
    ) into match_started_to_use;

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
      from public.fixtures fixture
      left join public.fixture_clock_states clock
        on clock.fixture_id = fixture.id
      where fixture.id = match_id_to_use
        and (
          fixture.status in ('LIVE', 'FINAL', 'CANCELLED')
          or clock.status in ('RUNNING', 'PAUSED', 'ENDED')
        )
    ) into match_started_to_use;

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

    select
      count(*) filter (
        where (attendance.expected_for_match or attendance.checked_in_at is not null)
          and attendance.outcome is null
      )::integer,
      count(*) filter (
        where attendance.expected_for_match
          and attendance.outcome is null
          and attendance.checked_in_at is null
      )::integer,
      count(*) filter (
        where attendance.expected_for_match
          and attendance.outcome = 'NO_SHOW'
      )::integer,
      count(*) filter (where attendance.expected_for_match)::integer,
      count(*) filter (where attendance.checked_in_at is not null)::integer,
      count(*) filter (
        where attendance.outcome = 'ON_TIME'
          or (
            attendance.outcome is null
            and attendance.checked_in_at is not null
            and (
              not attendance.expected_for_match
              or attendance.checked_in_at <= terms_to_use.check_in_deadline_at
            )
          )
      )::integer,
      count(*) filter (
        where attendance.outcome = 'LATE'
          or (
            attendance.outcome is null
            and attendance.expected_for_match
            and attendance.checked_in_at > terms_to_use.check_in_deadline_at
          )
      )::integer
    into
      unresolved_count,
      missing_unresolved_count,
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
        'check_in_revision', attendance.check_in_revision,
        'can_remove_check_in',
          attendance.checked_in_at is not null
          and attendance.outcome is null
          and attendance.finalized_at is null
          and server_now_to_use < terms_to_use.no_show_cutoff_at
          and not match_started_to_use,
        'status', case
          when attendance.outcome = 'ON_TIME' then 'ON_TIME'
          when attendance.outcome = 'LATE' then 'LATE'
          when attendance.outcome = 'NO_SHOW' then 'NO_SHOW'
          when attendance.outcome in ('EXCUSED', 'FIELD_CANCELLED') then 'EXCUSED'
          when attendance.checked_in_at is not null
            and attendance.expected_for_match
            and attendance.checked_in_at > terms_to_use.check_in_deadline_at
            then 'LATE'
          when attendance.checked_in_at is not null then 'ON_TIME'
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
      else missing_unresolved_count
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
  required_count_to_use integer;
  checked_side_count_to_use integer;
  check_in_detail jsonb;
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
          and not public.profile_has_active_play_restriction(member.profile_id)
      )
    )
  for update;

  if attendance_to_use.id is null then
    raise exception 'This player is not eligible for this match.';
  end if;
  if attendance_to_use.checked_in_at is not null then
    return public.get_match_reliability_context(normalized_kind, match_id_to_use);
  end if;
  if attendance_to_use.outcome is not null
    or attendance_to_use.finalized_at is not null
  then
    raise exception 'This player already has a final attendance outcome.';
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

  check_in_detail := jsonb_build_object(
    'policy_version_id', terms_to_use.policy_version_id,
    'checked_in_at', checked_in_at_to_use,
    'check_in_revision', attendance_to_use.check_in_revision,
    'check_in_deadline_at', terms_to_use.check_in_deadline_at,
    'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
    'provisional', true,
    'referee_authoritative', true,
    'planned_roster_member', attendance_to_use.expected_for_match
  );

  update public.match_attendance_records
  set
    checked_in_at = checked_in_at_to_use,
    checked_in_by = actor_referee_id,
    consequence_snapshot = consequence_snapshot || jsonb_build_object(
      'provisional_check_in', check_in_detail
    )
  where id = attendance_to_use.id;

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
    check_in_detail,
    'checked-in:' || attendance_to_use.id::text ||
      ':r' || attendance_to_use.check_in_revision::text
  ) on conflict (idempotency_key) do nothing;

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

create or replace function public.referee_remove_player_check_in(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_remove uuid,
  expected_revision_to_use integer,
  reason_code_to_use text,
  reason_note_to_use text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_reason text := upper(trim(coalesce(reason_code_to_use, '')));
  normalized_note text := trim(coalesce(reason_note_to_use, ''));
  correction_at_to_use timestamptz := clock_timestamp();
  attendance_before public.match_attendance_records%rowtype;
  attendance_after public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  match_status_to_use text;
  clock_status_to_use text;
  event_key_to_use text;
  audit_reason text;
begin
  if normalized_kind not in ('SOLO', 'CLAN') then
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;
  if normalized_reason not in (
    'WRONG_PLAYER', 'PLAYER_NOT_PRESENT', 'OPERATOR_ERROR', 'OTHER'
  ) then
    raise exception 'Choose a valid check-in correction reason.';
  end if;
  if char_length(normalized_note) > 500 then
    raise exception 'The correction note must be 500 characters or fewer.';
  end if;
  if normalized_reason = 'OTHER' and char_length(normalized_note) < 5 then
    raise exception 'Add a short note explaining this attendance correction.';
  end if;
  if expected_revision_to_use is null
    or expected_revision_to_use not between 0 and 10000
  then
    raise exception 'Refresh the player list before removing this check-in.';
  end if;
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'You are not assigned to manage this match.';
  end if;

  if normalized_kind = 'SOLO' then
    select game.status, coalesce(clock.status, 'NOT_STARTED')
    into match_status_to_use, clock_status_to_use
    from public.open_queue_games game
    left join public.open_queue_clock_states clock on clock.game_id = game.id
    where game.id = match_id_to_use
    for update of game;
    if match_status_to_use not in ('OPEN', 'FULL')
      or clock_status_to_use <> 'NOT_STARTED'
    then
      raise exception 'Check-ins cannot be removed after the match has started.';
    end if;
  else
    select fixture.status, coalesce(clock.status, 'NOT_STARTED')
    into match_status_to_use, clock_status_to_use
    from public.fixtures fixture
    left join public.fixture_clock_states clock on clock.fixture_id = fixture.id
    where fixture.id = match_id_to_use
    for update of fixture;
    if match_status_to_use not in ('OPEN', 'SCHEDULED')
      or clock_status_to_use <> 'NOT_STARTED'
    then
      raise exception 'Check-ins cannot be removed after the match has started.';
    end if;
  end if;
  if match_status_to_use is null then
    raise exception 'Match not found.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );
  if correction_at_to_use >= terms_to_use.no_show_cutoff_at then
    raise exception 'Attendance is already at the no-show cutoff. Ask an admin to review it.';
  end if;

  select * into attendance_before
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
    and attendance.profile_id = profile_id_to_remove
  for update;
  if attendance_before.id is null then
    raise exception 'Attendance record not found.';
  end if;

  event_key_to_use := 'check-in-removed:' || attendance_before.id::text ||
    ':r' || expected_revision_to_use::text;
  if attendance_before.checked_in_at is null then
    if attendance_before.check_in_revision = expected_revision_to_use + 1
      and exists (
        select 1
        from public.attendance_events event
        where event.idempotency_key = event_key_to_use
      )
    then
      return public.get_match_reliability_context(
        normalized_kind,
        match_id_to_use
      );
    end if;
    raise exception 'This player is not currently checked in. Refresh the player list.';
  end if;
  if attendance_before.check_in_revision <> expected_revision_to_use then
    raise exception 'This check-in changed. Refresh the player list before correcting it.';
  end if;
  if attendance_before.outcome is not null
    or attendance_before.finalized_at is not null
  then
    raise exception 'This attendance outcome is already final and requires admin review.';
  end if;
  if exists (
    select 1
    from public.reliability_appeals appeal
    where appeal.attendance_id = attendance_before.id
  ) then
    raise exception 'An attendance appeal already exists. Ask an admin to review it.';
  end if;

  update public.match_attendance_records attendance
  set
    checked_in_at = null,
    checked_in_by = null,
    check_in_revision = attendance.check_in_revision + 1,
    consequence_snapshot = attendance.consequence_snapshot ||
      jsonb_build_object(
        'last_check_in_removal', jsonb_build_object(
          'removed_at', correction_at_to_use,
          'removed_by', actor_referee_id,
          'reason_code', normalized_reason,
          'reason_note', nullif(normalized_note, ''),
          'removed_revision', expected_revision_to_use
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
    'CHECK_IN_REMOVED',
    actor_referee_id,
    correction_at_to_use,
    jsonb_build_object(
      'reason_code', normalized_reason,
      'reason_note', nullif(normalized_note, ''),
      'removed_revision', expected_revision_to_use,
      'next_revision', attendance_after.check_in_revision,
      'before', jsonb_build_object(
        'checked_in_at', attendance_before.checked_in_at,
        'checked_in_by', attendance_before.checked_in_by,
        'outcome', attendance_before.outcome
      ),
      'after', jsonb_build_object(
        'checked_in_at', attendance_after.checked_in_at,
        'checked_in_by', attendance_after.checked_in_by,
        'outcome', attendance_after.outcome
      )
    ),
    event_key_to_use
  ) on conflict (idempotency_key) do nothing;

  audit_reason := case normalized_reason
    when 'WRONG_PLAYER' then 'Wrong player was checked in.'
    when 'PLAYER_NOT_PRESENT' then 'Player had not arrived.'
    when 'OPERATOR_ERROR' then 'Referee check-in was recorded by mistake.'
    else 'Other attendance correction.'
  end || case when normalized_note = '' then '' else ' ' || normalized_note end;

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state
  ) values (
    actor_referee_id,
    'REFEREE_CHECK_IN_REMOVED',
    case normalized_kind when 'SOLO' then 'SOLO_MATCH' else 'CLAN_MATCH' end,
    match_id_to_use,
    audit_reason,
    jsonb_build_object(
      'attendance_id', attendance_before.id,
      'profile_id', attendance_before.profile_id,
      'checked_in_at', attendance_before.checked_in_at,
      'checked_in_by', attendance_before.checked_in_by,
      'check_in_revision', attendance_before.check_in_revision
    ),
    jsonb_build_object(
      'attendance_id', attendance_after.id,
      'profile_id', attendance_after.profile_id,
      'checked_in_at', attendance_after.checked_in_at,
      'checked_in_by', attendance_after.checked_in_by,
      'check_in_revision', attendance_after.check_in_revision,
      'reason_code', normalized_reason
    )
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
    attendance_before.profile_id,
    'ATTENDANCE_CORRECTED',
    'Match check-in corrected',
    'The referee removed your check-in. You are not currently marked as arrived.',
    'MATCH_ATTENDANCE',
    attendance_before.id,
    jsonb_build_object(
      'attendance_id', attendance_before.id,
      'match_kind', normalized_kind,
      'match_id', match_id_to_use,
      'reason_code', normalized_reason,
      'corrected_at', correction_at_to_use
    )
  );

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

create or replace function public.finalize_match_attendance_internal(
  match_kind_to_use text,
  match_id_to_use uuid,
  actor_referee_id_to_use uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_finalize public.match_attendance_records%rowtype;
  rule_to_use jsonb;
  outcome_to_use text;
  event_type_to_use text;
  event_key_to_use text;
  strike_delta_to_use integer;
  positive_multiplier integer;
  negative_multiplier integer;
  forfeit_deposit boolean;
  finalized_count integer := 0;
  finalized_at_to_use timestamptz := clock_timestamp();
begin
  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);
  if normalized_kind = 'CLAN' then
    perform public.initialize_fixture_reliability_roster(match_id_to_use);
  end if;
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  if finalized_at_to_use < terms_to_use.no_show_cutoff_at then
    return 0;
  end if;

  for attendance_to_finalize in
    select *
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.outcome is null
      and (
        attendance.expected_for_match
        or attendance.checked_in_at is not null
      )
    order by attendance.profile_id
    for update
  loop
    positive_multiplier := 10000;
    negative_multiplier := 10000;

    if attendance_to_finalize.checked_in_at is null then
      outcome_to_use := 'NO_SHOW';
      event_type_to_use := 'NO_SHOW_FINALIZED';
      event_key_to_use := 'no-show:' || attendance_to_finalize.id::text ||
        ':r' || attendance_to_finalize.check_in_revision::text;
      rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,noShow}';
    elsif not attendance_to_finalize.expected_for_match
      or attendance_to_finalize.checked_in_at <= terms_to_use.check_in_deadline_at
    then
      outcome_to_use := 'ON_TIME';
      event_type_to_use := 'ATTENDANCE_FINALIZED';
      event_key_to_use := 'attendance-finalized:' ||
        attendance_to_finalize.id::text || ':r' ||
        attendance_to_finalize.check_in_revision::text;
      rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,onTime}';
    else
      outcome_to_use := 'LATE';
      event_type_to_use := 'ATTENDANCE_FINALIZED';
      event_key_to_use := 'attendance-finalized:' ||
        attendance_to_finalize.id::text || ':r' ||
        attendance_to_finalize.check_in_revision::text;
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

    update public.match_attendance_records attendance
    set
      outcome = outcome_to_use,
      strike_delta = strike_delta_to_use,
      refund_bps = (rule_to_use ->> 'refundBps')::integer,
      refund_amount_fils = 0,
      positive_sr_multiplier_bps = positive_multiplier,
      negative_sr_multiplier_bps = negative_multiplier,
      finalized_at = finalized_at_to_use,
      appeal_due_at = finalized_at_to_use + make_interval(
        hours => (terms_to_use.policy_snapshot #>>
          '{attendance,appealWindowHours}')::integer
      ),
      consequence_snapshot = attendance.consequence_snapshot ||
        jsonb_build_object(
          'final_attendance_decision', jsonb_build_object(
            'policy_version_id', terms_to_use.policy_version_id,
            'outcome_code', outcome_to_use,
            'strike_delta', strike_delta_to_use,
            'refund_bps', (rule_to_use ->> 'refundBps')::integer,
            'deposit_forfeited', forfeit_deposit,
            'positive_sr_multiplier_bps', positive_multiplier,
            'negative_sr_multiplier_bps', negative_multiplier,
            'checked_in_at', attendance.checked_in_at,
            'check_in_revision', attendance.check_in_revision,
            'check_in_deadline_at', terms_to_use.check_in_deadline_at,
            'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
            'finalized_at', finalized_at_to_use
          )
        )
    where attendance.id = attendance_to_finalize.id
    returning * into attendance_to_finalize;

    if outcome_to_use = 'NO_SHOW'
      and attendance_to_finalize.booking_id is not null
    then
      update public.open_queue_bookings
      set played = false
      where id = attendance_to_finalize.booking_id
        and not exists (
          select 1
          from public.player_rating_events event
          where event.source_type = 'OPEN_QUEUE'
            and event.source_id = attendance_to_finalize.open_queue_game_id
        );
    end if;

    insert into public.attendance_events (
      attendance_id,
      event_type,
      actor_referee_id,
      event_at,
      detail,
      idempotency_key
    ) values (
      attendance_to_finalize.id,
      event_type_to_use,
      actor_referee_id_to_use,
      finalized_at_to_use,
      attendance_to_finalize.consequence_snapshot,
      event_key_to_use
    ) on conflict (idempotency_key) do nothing;

    perform public.settle_reliability_deposit(
      attendance_to_finalize.id,
      not forfeit_deposit
    );
    perform public.apply_attendance_refund(attendance_to_finalize.id);
    perform public.record_reliability_incident(
      attendance_to_finalize.id,
      outcome_to_use,
      strike_delta_to_use,
      finalized_at_to_use
    );

    if outcome_to_use in ('LATE', 'NO_SHOW') then
      insert into public.notifications (
        recipient_profile_id,
        type,
        title,
        body,
        related_entity_type,
        related_entity_id,
        data
      ) values (
        attendance_to_finalize.profile_id,
        'RELIABILITY_OUTCOME',
        case outcome_to_use
          when 'LATE' then 'Attendance finalized as late'
          else 'Attendance finalized as a no-show'
        end,
        case outcome_to_use
          when 'LATE' then
            'The no-show cutoff passed and your recorded arrival was after the on-time deadline.'
          else
            'The no-show cutoff passed without a referee check-in.'
        end || case when strike_delta_to_use > 0 then
          ' ' || strike_delta_to_use ||
          case when strike_delta_to_use = 1
            then ' reliability strike was added.'
            else ' reliability strikes were added.' end
          else '' end,
        'MATCH_ATTENDANCE',
        attendance_to_finalize.id,
        attendance_to_finalize.consequence_snapshot
      );
    end if;

    finalized_count := finalized_count + 1;
  end loop;

  return finalized_count;
end;
$$;

-- Existing future test check-ins with no wallet, deposit, refund, strike,
-- incident, or appeal effects can be moved to the provisional model safely.
-- Anything with a settled consequence remains final for admin review.
with safe_existing as (
  select attendance.id
  from public.match_attendance_records attendance
  where attendance.checked_in_at is not null
    and attendance.outcome = 'ON_TIME'
    and attendance.strike_delta = 0
    and attendance.refund_bps = 0
    and attendance.refund_amount_fils = 0
    and attendance.reliability_deposit_fils = 0
    and attendance.deposit_resolution = 'NOT_REQUIRED'
    and not exists (
      select 1 from public.reliability_incidents incident
      where incident.attendance_id = attendance.id
    )
    and not exists (
      select 1 from public.reliability_appeals appeal
      where appeal.attendance_id = attendance.id
    )
    and not exists (
      select 1 from public.field_wallet_transactions wallet
      where wallet.metadata ->> 'attendance_id' = attendance.id::text
        or wallet.idempotency_key in (
          'deposit-return:' || attendance.id::text,
          'attendance-fee-refund:' || attendance.id::text
        )
    )
    and (
      (
        attendance.match_kind = 'SOLO'
        and exists (
          select 1
          from public.open_queue_games game
          left join public.open_queue_clock_states clock on clock.game_id = game.id
          where game.id = attendance.open_queue_game_id
            and game.status in ('OPEN', 'FULL')
            and coalesce(clock.status, 'NOT_STARTED') = 'NOT_STARTED'
        )
      )
      or (
        attendance.match_kind = 'CLAN'
        and exists (
          select 1
          from public.fixtures fixture
          left join public.fixture_clock_states clock on clock.fixture_id = fixture.id
          where fixture.id = attendance.fixture_id
            and fixture.status in ('OPEN', 'SCHEDULED')
            and coalesce(clock.status, 'NOT_STARTED') = 'NOT_STARTED'
        )
      )
    )
), provisionalized as (
  update public.match_attendance_records attendance
  set
    outcome = null,
    strike_delta = 0,
    refund_bps = 0,
    refund_amount_fils = 0,
    positive_sr_multiplier_bps = 10000,
    negative_sr_multiplier_bps = 10000,
    finalized_at = null,
    appeal_due_at = null,
    consequence_snapshot = attendance.consequence_snapshot ||
      jsonb_build_object(
        'provisionalized_by_migration', jsonb_build_object(
          'previous_outcome', attendance.outcome,
          'migrated_at', clock_timestamp(),
          'reason', 'ENABLE_SAFE_REFEREE_CHECK_IN_CORRECTIONS'
        )
      )
  where attendance.id in (select id from safe_existing)
  returning attendance.id, attendance.checked_in_at,
    attendance.checked_in_by, attendance.check_in_revision
)
insert into public.attendance_events (
  attendance_id,
  event_type,
  actor_referee_id,
  detail,
  idempotency_key
)
select
  provisionalized.id,
  'ADMIN_CORRECTION',
  null,
  jsonb_build_object(
    'source', 'PROVISIONAL_CHECK_IN_MIGRATION',
    'checked_in_at', provisionalized.checked_in_at,
    'checked_in_by', provisionalized.checked_in_by,
    'check_in_revision', provisionalized.check_in_revision,
    'previous_outcome', 'ON_TIME',
    'corrected_outcome', null
  ),
  'provisionalized-check-in:' || provisionalized.id::text
from provisionalized
on conflict (idempotency_key) do nothing;

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

revoke all on function public.referee_check_in_player(uuid,text,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.referee_check_in_player(uuid,text,uuid,uuid)
to service_role;

revoke all on function public.referee_remove_player_check_in(
  uuid,text,uuid,uuid,integer,text,text
) from public, anon, authenticated;
grant execute on function public.referee_remove_player_check_in(
  uuid,text,uuid,uuid,integer,text,text
) to service_role;

revoke all on function public.finalize_match_attendance_internal(
  text,uuid,uuid
) from public, anon, authenticated;
grant execute on function public.finalize_match_attendance_internal(
  text,uuid,uuid
) to service_role;

comment on function public.referee_check_in_player(uuid,text,uuid,uuid) is
'Records a revisioned provisional referee check-in. Attendance money, strikes, sanctions, and final outcomes settle once at the no-show cutoff.';

comment on function public.referee_remove_player_check_in(
  uuid,text,uuid,uuid,integer,text,text
) is
'Removes only an unsettled, pre-match referee check-in using optimistic revision control while preserving immutable attendance and admin audit history.';

comment on function public.finalize_match_attendance_internal(
  text,uuid,uuid
) is
'At the no-show cutoff, atomically classifies provisional arrivals as on-time or late, missing planned players as no-shows, and applies each policy consequence exactly once.';
