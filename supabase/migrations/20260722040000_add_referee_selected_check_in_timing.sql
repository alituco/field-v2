-- Referees record a clear arrival category instead of relying on the wall-clock
-- tap time as a proxy for what happened. The real server timestamp remains in
-- the immutable attendance event for audit purposes. Existing reliability
-- calculations keep working by storing a category-representative timestamp on
-- the attendance row.

alter table public.match_attendance_records
add column if not exists check_in_timing text;

alter table public.match_attendance_records
drop constraint if exists match_attendance_records_check_in_timing_check;

alter table public.match_attendance_records
add constraint match_attendance_records_check_in_timing_check check (
  check_in_timing is null
  or check_in_timing in ('EARLY', 'LATE', 'AFTER_KICKOFF')
);

update public.match_attendance_records attendance
set check_in_timing = case
  when attendance.checked_in_at > terms.kickoff_at then 'AFTER_KICKOFF'
  when attendance.checked_in_at > terms.check_in_deadline_at then 'LATE'
  else 'EARLY'
end
from public.match_reliability_terms terms
where attendance.terms_id = terms.id
  and attendance.checked_in_at is not null
  and attendance.check_in_timing is null;

create or replace function public.clear_removed_check_in_timing()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.checked_in_at is null then
    new.check_in_timing := null;
  end if;
  return new;
end;
$$;

drop trigger if exists clear_removed_check_in_timing
on public.match_attendance_records;
create trigger clear_removed_check_in_timing
before insert or update of checked_in_at
on public.match_attendance_records
for each row execute function public.clear_removed_check_in_timing();

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
begin
  if normalized_timing not in ('EARLY', 'LATE', 'AFTER_KICKOFF') then
    raise exception 'Choose whether the player arrived early, late, or after kickoff.';
  end if;

  -- The established function retains every authorization, match-state,
  -- eligibility, roster-cap, revision, and audit guard.
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

  if normalized_timing = 'EARLY' then
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
          'recorded_by', actor_referee_id
        )
      )
  where attendance.id = attendance_to_use.id;

  update public.attendance_events event
  set detail = event.detail || jsonb_build_object(
    'check_in_timing', normalized_timing,
    'actual_recorded_at', actual_checked_in_at,
    'classified_at', classified_checked_in_at
  )
  where event.attendance_id = attendance_to_use.id
    and event.event_type = 'CHECKED_IN'
    and event.idempotency_key = 'checked-in:' || attendance_to_use.id::text ||
      ':r' || attendance_to_use.check_in_revision::text;

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

revoke all on function public.clear_removed_check_in_timing()
from public, anon, authenticated;

revoke all on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) from public, anon, authenticated;
grant execute on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) to service_role;

comment on column public.match_attendance_records.check_in_timing is
'Referee-selected arrival category. The exact server event time remains private audit evidence.';

comment on function public.referee_check_in_player_with_timing(
  uuid,text,uuid,uuid,text
) is
'Records an audited player check-in classified by the referee as early, late, or after kickoff while preserving the actual server tap time in the event trail.';
