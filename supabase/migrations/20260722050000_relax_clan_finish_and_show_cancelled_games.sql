-- Keep cancelled games visible in the player Fixtures history, allow a live
-- clan game to end whenever the referee actually ends it, and protect surplus
-- clan players from late-arrival consequences once a full six-player side was
-- already present. Exact referee selections and server times remain audited.

do $migration$
declare
  fixture_feed_definition text;
begin
  select pg_get_functiondef(
    'public.list_open_queue_fixture_games()'::regprocedure
  ) into fixture_feed_definition;

  if position(
    'where game.status <> ''CANCELLED''' in fixture_feed_definition
  ) = 0 then
    raise exception
      'Could not locate the cancelled-game filter in the solo Fixtures feed.';
  end if;

  fixture_feed_definition := replace(
    fixture_feed_definition,
    'where game.status <> ''CANCELLED''',
    'where true'
  );
  execute fixture_feed_definition;
end;
$migration$;

-- FINAL is the football result, while attendance is a separate server-timed
-- ledger. The existing due-attendance worker already includes FINAL fixtures
-- and safely settles their outcomes/deposits once the cutoff arrives.
drop trigger if exists enforce_clan_reliability_final_cutoff
on public.fixtures;
drop function if exists public.enforce_clan_reliability_final_cutoff();

alter table public.attendance_events
drop constraint if exists attendance_events_event_type_check;
alter table public.attendance_events
add constraint attendance_events_event_type_check
check (
  event_type in (
    'EXPECTED',
    'CHECKED_IN',
    'CHECK_IN_CLASSIFIED',
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

create or replace function public.referee_check_in_player_with_timing(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_check_in uuid,
  check_in_timing_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_timing text := upper(trim(coalesce(check_in_timing_to_use, '')));
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_use public.match_attendance_records%rowtype;
  actual_checked_in_at timestamptz;
  classified_checked_in_at timestamptz;
  checked_clan_teammates_before integer := 0;
  full_playing_side_count constant integer := 6;
  late_penalty_waived boolean := false;
begin
  if normalized_timing not in ('EARLY', 'LATE', 'AFTER_KICKOFF') then
    raise exception 'Choose whether the player arrived early, late, or after kickoff.';
  end if;

  -- Retain the established authorization, match-state, eligibility, ten-player
  -- clan squad cap, revision, and immutable audit guards.
  perform public.referee_check_in_player(
    actor_referee_id,
    normalized_kind,
    match_id_to_use,
    profile_id_to_check_in
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
  )
  limit 1;

  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
    and attendance.profile_id = profile_id_to_check_in
  for update;

  if attendance_to_use.id is null or attendance_to_use.checked_in_at is null then
    raise exception 'The player check-in could not be classified.';
  end if;
  if attendance_to_use.check_in_timing is not null then
    raise exception 'This player is already checked in. Remove the check-in before recording it again.';
  end if;

  actual_checked_in_at := attendance_to_use.checked_in_at;

  if normalized_kind = 'CLAN'
    and normalized_timing in ('LATE', 'AFTER_KICKOFF')
  then
    select count(*)::integer into checked_clan_teammates_before
    from public.match_attendance_records teammate
    where teammate.terms_id = terms_to_use.id
      and teammate.clan_id = attendance_to_use.clan_id
      and teammate.id <> attendance_to_use.id
      and teammate.checked_in_at is not null;

    late_penalty_waived :=
      checked_clan_teammates_before >= full_playing_side_count;
  end if;

  if normalized_timing = 'EARLY' or late_penalty_waived then
    classified_checked_in_at := least(
      actual_checked_in_at,
      terms_to_use.check_in_deadline_at
    );
  elsif normalized_timing = 'LATE' then
    if terms_to_use.check_in_deadline_at >= terms_to_use.kickoff_at then
      raise exception 'This match does not have a valid late-arrival window.';
    end if;
    classified_checked_in_at := terms_to_use.check_in_deadline_at
      + interval '1 millisecond';
  else
    if terms_to_use.kickoff_at >= terms_to_use.no_show_cutoff_at then
      raise exception 'This match does not have a valid after-kickoff arrival window.';
    end if;
    classified_checked_in_at := terms_to_use.kickoff_at
      + interval '1 millisecond';
  end if;

  update public.match_attendance_records attendance
  set
    checked_in_at = classified_checked_in_at,
    check_in_timing = normalized_timing,
    consequence_snapshot = attendance.consequence_snapshot ||
      jsonb_build_object(
        'referee_selected_check_in',
        jsonb_build_object(
          'timing', normalized_timing,
          'recorded_at', actual_checked_in_at,
          'classified_at', classified_checked_in_at,
          'recorded_by', actor_referee_id,
          'late_penalty_waived', late_penalty_waived,
          'waiver_reason', case when late_penalty_waived
            then 'FULL_PLAYING_SIDE_ALREADY_CHECKED_IN'
            else null
          end,
          'checked_clan_teammates_before',
            checked_clan_teammates_before,
          'full_playing_side_count', full_playing_side_count
        )
      )
  where attendance.id = attendance_to_use.id;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    actor_referee_id,
    event_at,
    detail,
    idempotency_key
  ) values (
    attendance_to_use.id,
    'CHECK_IN_CLASSIFIED',
    actor_referee_id,
    actual_checked_in_at,
    jsonb_build_object(
      'check_in_timing', normalized_timing,
      'actual_recorded_at', actual_checked_in_at,
      'classified_at', classified_checked_in_at,
      'late_penalty_waived', late_penalty_waived,
      'waiver_reason', case when late_penalty_waived
        then 'FULL_PLAYING_SIDE_ALREADY_CHECKED_IN'
        else null
      end,
      'checked_clan_teammates_before', checked_clan_teammates_before,
      'full_playing_side_count', full_playing_side_count,
      'check_in_revision', attendance_to_use.check_in_revision
    ),
    'check-in-classified:' || attendance_to_use.id::text ||
      ':r' || attendance_to_use.check_in_revision::text
  ) on conflict (idempotency_key) do nothing;

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

revoke all on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) from public, anon, authenticated;
grant execute on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) to service_role;

comment on function public.list_open_queue_fixture_games() is
'Returns the complete authenticated Solo Fixtures feed, including cancelled games so players can see their true status.';

comment on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) is
'Records an audited referee-selected arrival category. A late clan arrival is consequence-neutral when six teammates were already checked in, while the real arrival category and server time remain in the audit trail.';
