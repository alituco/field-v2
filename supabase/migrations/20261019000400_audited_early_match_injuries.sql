-- The legacy admin test-start flow records an immutable early-start approval,
-- checks in the entire booked lineup and starts the real match clock. Its
-- injury writer must recognize that same kickoff without moving any scheduled
-- attendance, cancellation or refund deadline. Season 0 still starts on time.
-- Patch only the kickoff guard so current-booking attendance selection and all
-- other authorization, live-match, policy, roster and input checks are retained.
do $migration$
declare
  definition text;
  old_guard text := $old$  if clock_timestamp() < terms_to_use.kickoff_at then
    raise exception 'Shorthanded play can only be recorded from kickoff.';
  end if;$old$;
  new_guard text := $new$  if clock_timestamp() < terms_to_use.kickoff_at
    and not (
      normalized_kind = 'SOLO'
      and exists (
        select 1
        from public.open_queue_games game
        join public.open_queue_clock_states match_clock on match_clock.game_id = game.id
        where game.id = match_id_to_use
          and game.rating_policy_id = 'LEGACY'
          and game.status = 'LIVE'
          and game.teams_assigned_at is not null
          and match_clock.status in ('RUNNING', 'PAUSED')
          and exists (
            select 1 from public.admin_audit_events audit
            where audit.action = 'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'
              and audit.entity_type = 'SOLO_MATCH'
              and audit.entity_id = game.id
          )
          and exists (
            select 1 from public.open_queue_events match_event
            where match_event.game_id = game.id
              and match_event.event_type = 'MATCH_STARTED'
              and match_event.occurred_at <= clock_timestamp()
          )
          and game.capacity = (
            select count(*) from public.open_queue_bookings booking
            where booking.game_id = game.id and booking.status = 'CONFIRMED'
          )
          and not exists (
            select 1
            from public.open_queue_bookings booking
            left join public.current_match_attendance_records attendance
              on attendance.booking_id = booking.id
              and attendance.open_queue_game_id = game.id
              and attendance.profile_id = booking.profile_id
              and attendance.match_kind = 'SOLO'
            where booking.game_id = game.id
              and booking.status = 'CONFIRMED'
              and (
                not booking.played
                or booking.team is null
                or attendance.checked_in_at is null
              )
          )
      )
    )
  then
    raise exception 'Shorthanded play can only be recorded from kickoff.';
  end if;$new$;
begin
  definition := pg_get_functiondef(
    'public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)'::regprocedure
  );
  if position(old_guard in definition) = 0
    or position('from public.current_match_attendance_records attendance' in definition) = 0
  then
    raise exception 'The current shorthanded kickoff/attendance contract changed.';
  end if;
  execute replace(definition, old_guard, new_guard);
end;
$migration$;
