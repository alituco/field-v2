-- Referee check-ins are provisional until the no-show cutoff so that an
-- accidental check-in can still be removed with a complete audit trail.
-- Starting a lineup must therefore accept an active provisional check-in;
-- waiting for ON_TIME/LATE finalization would make kickoff impossible.

create or replace function public.require_checked_in_match_participant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  reliability_terms_exist boolean;
  checked_in_participant boolean;
begin
  if not coalesce(new.played, false)
    or (tg_op = 'UPDATE' and coalesce(old.played, false))
  then
    return new;
  end if;

  if tg_table_name = 'open_queue_bookings' then
    select
      exists (
        select 1
        from public.match_reliability_terms terms
        where terms.match_kind = 'SOLO'
          and terms.open_queue_game_id = new.game_id
      ),
      exists (
        select 1
        from public.match_attendance_records attendance
        where attendance.match_kind = 'SOLO'
          and attendance.open_queue_game_id = new.game_id
          and attendance.profile_id = new.profile_id
          and attendance.checked_in_at is not null
          and (
            attendance.outcome is null
            or attendance.outcome in ('ON_TIME', 'LATE')
          )
      )
    into reliability_terms_exist, checked_in_participant;
  else
    select
      exists (
        select 1
        from public.match_reliability_terms terms
        where terms.match_kind = 'CLAN'
          and terms.fixture_id = new.fixture_id
      ),
      exists (
        select 1
        from public.match_attendance_records attendance
        where attendance.match_kind = 'CLAN'
          and attendance.fixture_id = new.fixture_id
          and attendance.profile_id = new.profile_id
          and attendance.checked_in_at is not null
          and (
            attendance.outcome is null
            or attendance.outcome in ('ON_TIME', 'LATE')
          )
      )
    into reliability_terms_exist, checked_in_participant;
  end if;

  if reliability_terms_exist and not checked_in_participant then
    raise exception
      'Check this player in with the Field Host before adding them to the played lineup.';
  end if;
  return new;
end;
$$;

revoke all on function public.require_checked_in_match_participant()
from public, anon, authenticated;

comment on function public.require_checked_in_match_participant() is
'Allows an active provisional or finalized referee check-in into a played lineup while rejecting unchecked, removed, cancelled, and no-show attendance.';
