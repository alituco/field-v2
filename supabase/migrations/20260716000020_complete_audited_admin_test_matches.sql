-- Make the deliberately audited admin test-start path complete end-to-end.
-- Ordinary referees still cannot start a future match, ordinary attendance
-- cutoffs remain authoritative, and the permanent Tuesday/Friday schedule is
-- never rewritten. An early test is allowed only with the complete booked
-- roster checked in, and the exception is scoped to one transaction/game.

create or replace function public.admin_force_assign_open_queue_teams(
  actor_admin_id uuid,
  game_id_to_assign uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  game_before public.open_queue_games%rowtype;
  game_after public.open_queue_games%rowtype;
  confirmed_count integer;
  checked_in_count integer;
  already_audited boolean;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Record a clear 10 to 1,000 character reason.';
  end if;

  select * into game_before
  from public.open_queue_games game
  where game.id = game_id_to_assign
  for update;

  if game_before.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_before.status <> 'FULL' then
    raise exception 'A solo game must be full before it can start.';
  end if;
  if clock_timestamp() >= game_before.starts_at then
    raise exception 'This match is no longer an early start. Use the ordinary start flow.';
  end if;

  perform public.ensure_match_attendance_records('SOLO', game_before.id);

  select
    count(*)::integer,
    (count(*) filter (where attendance.checked_in_at is not null))::integer
  into confirmed_count, checked_in_count
  from public.open_queue_bookings booking
  left join public.match_attendance_records attendance
    on attendance.open_queue_game_id = booking.game_id
   and attendance.profile_id = booking.profile_id
   and attendance.match_kind = 'SOLO'
  where booking.game_id = game_before.id
    and booking.status = 'CONFIRMED';

  if confirmed_count <> game_before.capacity
    or checked_in_count <> confirmed_count
  then
    raise exception
      'Every booked player must be checked in before an admin can start this match early (%/% checked in).',
      checked_in_count,
      confirmed_count;
  end if;

  select exists (
    select 1
    from public.admin_audit_events audit
    where audit.action = 'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'
      and audit.entity_type = 'SOLO_MATCH'
      and audit.entity_id = game_before.id
  ) into already_audited;

  if game_before.teams_assigned_at is null
    or exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = game_before.id
        and booking.status = 'CONFIRMED'
        and booking.team is null
    )
  then
    perform set_config(
      'field.force_open_queue_team_assignment',
      game_before.id::text,
      true
    );
    perform public.assign_open_queue_teams(game_before.id);
  end if;

  select * into game_after
  from public.open_queue_games game
  where game.id = game_before.id;

  if game_after.teams_assigned_at is null
    or exists (
      select 1
      from public.open_queue_bookings booking
      where booking.game_id = game_before.id
        and booking.status = 'CONFIRMED'
        and booking.team is null
    )
  then
    raise exception 'Could not assign both solo teams for the early start.';
  end if;

  if not already_audited then
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
      'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY',
      'SOLO_MATCH',
      game_before.id,
      normalized_reason,
      jsonb_build_object(
        'status', game_before.status,
        'scheduled_starts_at', game_before.starts_at,
        'teams_assigned_at', game_before.teams_assigned_at,
        'checked_in_count', checked_in_count,
        'confirmed_count', confirmed_count,
        'white_average_sr', game_before.white_average_sr,
        'black_average_sr', game_before.black_average_sr
      ),
      jsonb_build_object(
        'status', game_after.status,
        'scheduled_starts_at', game_after.starts_at,
        'teams_assigned_at', game_after.teams_assigned_at,
        'checked_in_count', checked_in_count,
        'confirmed_count', confirmed_count,
        'white_average_sr', game_after.white_average_sr,
        'black_average_sr', game_after.black_average_sr,
        'source', 'REFEREE_CONSOLE_EARLY_START'
      )
    );
  end if;

  return jsonb_build_object(
    'game_id', game_after.id,
    'teams_assigned_at', game_after.teams_assigned_at,
    'checked_in_count', checked_in_count,
    'confirmed_count', confirmed_count,
    'idempotent', already_audited
  );
end;
$$;

revoke all on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) to service_role;

-- The web route is not the security boundary. The database also refuses a
-- future start unless the game carries the immutable audited admin override,
-- and then requires the entire confirmed roster in the submitted lineup.
do $migration$
declare
  function_definition text;
  old_status_guard text := $old$  if game_to_start.status <> 'FULL' then
    raise exception 'A solo game must be full before it can be started.';
  end if;
$old$;
  new_status_guard text := $new$  if game_to_start.status <> 'FULL' then
    raise exception 'A solo game must be full before it can be started.';
  end if;

  if clock_timestamp() < game_to_start.starts_at
    and not exists (
      select 1
      from public.admin_audit_events audit
      where audit.action = 'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'
        and audit.entity_type = 'SOLO_MATCH'
        and audit.entity_id = game_to_start.id
    )
  then
    raise exception 'This match cannot be started before its scheduled kickoff.';
  end if;
$new$;
  old_roster_guard text := $old$  if matched_count <> participant_count then
    raise exception 'Every selected player must have a confirmed booking.';
  end if;
$old$;
  new_roster_guard text := $new$  if matched_count <> participant_count then
    raise exception 'Every selected player must have a confirmed booking.';
  end if;

  if clock_timestamp() < game_to_start.starts_at
    and (
      participant_count <> (
        select count(*)::integer
        from public.open_queue_bookings booking
        where booking.game_id = game_to_start.id
          and booking.status = 'CONFIRMED'
      )
      or exists (
        select 1
        from public.open_queue_bookings booking
        left join public.match_attendance_records attendance
          on attendance.open_queue_game_id = booking.game_id
         and attendance.profile_id = booking.profile_id
         and attendance.match_kind = 'SOLO'
        where booking.game_id = game_to_start.id
          and booking.status = 'CONFIRMED'
          and attendance.checked_in_at is null
      )
    )
  then
    raise exception 'Every booked player must be checked in and selected for an early test start.';
  end if;
$new$;
begin
  select pg_get_functiondef(
    'public.referee_start_open_queue_game(uuid,uuid[],integer)'::regprocedure
  ) into function_definition;

  if position(new_status_guard in function_definition) = 0 then
    if position(old_status_guard in function_definition) = 0 then
      raise exception 'Could not locate the solo start status guard.';
    end if;
    function_definition := replace(
      function_definition,
      old_status_guard,
      new_status_guard
    );
  end if;

  if position(new_roster_guard in function_definition) = 0 then
    if position(old_roster_guard in function_definition) = 0 then
      raise exception 'Could not locate the solo start roster guard.';
    end if;
    function_definition := replace(
      function_definition,
      old_roster_guard,
      new_roster_guard
    );
  end if;

  execute function_definition;
end;
$migration$;

create or replace function public.referee_complete_open_queue_game(
  game_id_to_complete uuid
)
returns public.open_queue_games
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  game_to_complete public.open_queue_games%rowtype;
  completed_game public.open_queue_games%rowtype;
  clock_to_stop public.open_queue_clock_states%rowtype;
  elapsed_seconds integer;
  white_score_to_use integer;
  black_score_to_use integer;
begin
  select *
  into game_to_complete
  from public.open_queue_games
  where id = game_id_to_complete
  for update;

  if game_to_complete.id is null then
    raise exception 'Open Queue game not found.';
  end if;

  if game_to_complete.status = 'FINAL' then
    raise exception 'This Open Queue game is already final.';
  end if;

  if game_to_complete.status <> 'LIVE' then
    raise exception 'Only a live Open Queue game can be finalized.';
  end if;

  -- An ordinary match must wait for its policy-backed cutoff. The only early
  -- completion path is the previously audited admin test start, and every
  -- confirmed player must still be both checked in and in the played lineup.
  if exists (
    select 1
    from public.match_reliability_terms terms
    where terms.match_kind = 'SOLO'
      and terms.open_queue_game_id = game_to_complete.id
      and clock_timestamp() < terms.no_show_cutoff_at
  ) then
    if not exists (
      select 1
      from public.admin_audit_events audit
      where audit.action = 'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY'
        and audit.entity_type = 'SOLO_MATCH'
        and audit.entity_id = game_to_complete.id
    ) then
      raise exception 'This match cannot be completed before its attendance cutoff.';
    end if;

    if exists (
      select 1
      from public.open_queue_bookings booking
      left join public.match_attendance_records attendance
        on attendance.open_queue_game_id = booking.game_id
       and attendance.profile_id = booking.profile_id
       and attendance.match_kind = 'SOLO'
      where booking.game_id = game_to_complete.id
        and booking.status = 'CONFIRMED'
        and (
          not booking.played
          or attendance.checked_in_at is null
        )
    ) then
      raise exception 'Every booked player must remain checked in and in the lineup to complete an early test match.';
    end if;

    perform set_config(
      'field.allow_early_open_queue_finalization',
      game_to_complete.id::text,
      true
    );
  end if;

  select *
  into clock_to_stop
  from public.open_queue_clock_states
  where game_id = game_id_to_complete
  for update;

  if clock_to_stop.game_id is null then
    raise exception 'The Open Queue match clock has not been started.';
  end if;

  elapsed_seconds := least(
    10800,
    greatest(
      0,
      clock_to_stop.accumulated_seconds + case
        when clock_to_stop.status = 'RUNNING' and clock_to_stop.started_at is not null
          then greatest(
            0,
            floor(extract(epoch from (now() - clock_to_stop.started_at)))::integer
          )
        else 0
      end
    )
  );

  if not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_complete
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'WHITE'
  ) or not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = game_id_to_complete
      and booking.status = 'CONFIRMED'
      and booking.played
      and booking.team = 'BLACK'
  ) then
    raise exception 'Confirm at least one participating player on each team.';
  end if;

  select
    (count(*) filter (where goal.team = 'WHITE'))::integer,
    (count(*) filter (where goal.team = 'BLACK'))::integer
  into white_score_to_use, black_score_to_use
  from public.open_queue_goals goal
  where goal.game_id = game_id_to_complete;

  update public.open_queue_clock_states
  set
    status = 'ENDED',
    started_at = null,
    accumulated_seconds = elapsed_seconds
  where game_id = game_id_to_complete;

  if not exists (
    select 1
    from public.open_queue_events event
    where event.game_id = game_id_to_complete
      and event.event_type = 'MATCH_ENDED'
  ) then
    insert into public.open_queue_events (
      game_id,
      event_type,
      minute,
      second,
      occurred_at
    ) values (
      game_id_to_complete,
      'MATCH_ENDED',
      least(180, floor(elapsed_seconds / 60)::integer),
      elapsed_seconds % 60,
      now()
    );
  end if;

  update public.open_queue_blue_cards
  set status = 'CLEARED'
  where game_id = game_id_to_complete
    and status = 'ACTIVE';

  update public.open_queue_games
  set
    status = 'FINAL',
    white_score = coalesce(white_score_to_use, 0),
    black_score = coalesce(black_score_to_use, 0)
  where id = game_id_to_complete
  returning * into completed_game;

  return completed_game;
end;
$$;

-- Keep the finalizer's ordinary cutoff intact. Only the game-specific GUC set
-- above may allow the audited early test transaction through.
do $migration$
declare
  function_definition text;
  old_guard text := $old$  if finalized_at_to_use < terms_to_use.no_show_cutoff_at then
    return 0;
  end if;
$old$;
  new_guard text := $new$  if finalized_at_to_use < terms_to_use.no_show_cutoff_at
    and nullif(
      current_setting('field.allow_early_open_queue_finalization', true),
      ''
    ) is distinct from match_id_to_use::text
  then
    return 0;
  end if;
$new$;
begin
  select pg_get_functiondef(
    'public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure
  ) into function_definition;

  if position(new_guard in function_definition) = 0 then
    if position(old_guard in function_definition) = 0 then
      raise exception 'Could not locate the attendance finalization cutoff guard.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;
end;
$migration$;

create or replace function public.apply_open_queue_player_ratings_on_final()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  policy_id_to_use uuid;
  terms_to_use public.match_reliability_terms%rowtype;
  early_test_override boolean;
begin
  if new.status = 'FINAL' and old.status is distinct from 'FINAL' then
    policy_id_to_use := public.resolve_reliability_policy_id(new.starts_at);
    if policy_id_to_use is not null then
      terms_to_use := public.ensure_match_reliability_terms('SOLO', new.id);
      early_test_override := coalesce(
        nullif(
          current_setting('field.allow_early_open_queue_finalization', true),
          ''
        ) = new.id::text,
        false
      );
      if clock_timestamp() < terms_to_use.no_show_cutoff_at
        and not early_test_override
      then
        raise exception 'A solo match cannot be finalized before its no-show cutoff at %.',
          terms_to_use.no_show_cutoff_at;
      end if;
      perform public.ensure_match_attendance_records('SOLO', new.id);
      perform public.finalize_match_attendance_internal('SOLO', new.id, null);
    end if;

    perform public.apply_open_queue_player_ratings(new.id);
    if policy_id_to_use is not null then
      perform public.apply_open_queue_reliability_rating_adjustments(new.id);
    end if;
  end if;
  return new;
end;
$$;

-- Rating changes happen when the test is actually played, not at its unchanged
-- future booking slot. This also improves normal games whose kickoff drifts.
do $migration$
declare
  function_definition text;
  old_declaration text := $old$  game_to_apply public.open_queue_games%rowtype;
  participant record;
$old$;
  new_declaration text := $new$  game_to_apply public.open_queue_games%rowtype;
  rating_effective_at timestamptz;
  participant record;
$new$;
  old_lock text := $old$  if game_to_apply.status <> 'FINAL' then
    raise exception 'Player SR can only be applied to a final Open Queue game.';
  end if;
$old$;
  new_lock text := $new$  if game_to_apply.status <> 'FINAL' then
    raise exception 'Player SR can only be applied to a final Open Queue game.';
  end if;

  select min(event.occurred_at)
  into rating_effective_at
  from public.open_queue_events event
  where event.game_id = game_to_apply.id
    and event.event_type = 'MATCH_STARTED';
  rating_effective_at := coalesce(rating_effective_at, game_to_apply.starts_at);
$new$;
  old_value text := $old$      game_to_apply.starts_at,
$old$;
  new_value text := $new$      rating_effective_at,
$new$;
begin
  select pg_get_functiondef(
    'public.apply_open_queue_player_ratings(uuid)'::regprocedure
  ) into function_definition;

  if position(new_declaration in function_definition) = 0 then
    if position(old_declaration in function_definition) = 0 then
      raise exception 'Could not locate the Player SR effective-time declaration.';
    end if;
    function_definition := replace(
      function_definition,
      old_declaration,
      new_declaration
    );
  end if;

  if position(new_lock in function_definition) = 0 then
    if position(old_lock in function_definition) = 0 then
      raise exception 'Could not locate the Player SR status guard.';
    end if;
    function_definition := replace(function_definition, old_lock, new_lock);
  end if;

  if position(new_value in function_definition) = 0 then
    if position(old_value in function_definition) = 0 then
      raise exception 'Could not locate the Player SR effective-time value.';
    end if;
    function_definition := replace(function_definition, old_value, new_value);
  end if;

  execute function_definition;
end;
$migration$;

comment on function public.admin_force_assign_open_queue_teams(
  uuid, uuid, text
) is
'Allows an active admin to start a full solo test match early only after every booked player is checked in; team assignment and the exceptional path are permanently audited.';

comment on function public.referee_complete_open_queue_game(uuid) is
'Completes a live solo game. Before the attendance cutoff, only a fully checked-in, previously audited admin test start may complete.';
