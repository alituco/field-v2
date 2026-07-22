-- Simplify matchday cover to one game-wide reserve, and add an atomic admin
-- workflow for reporting a participant with optional reliability strikes.

do $$
declare
  duplicate_reserve record;
  constraint_to_drop record;
begin
  -- Preserve history if a game already received two side-specific reserves.
  for duplicate_reserve in
    select id
    from (
      select id, row_number() over (
        partition by coalesce(fixture_id, open_queue_game_id)
        order by added_at desc, id
      ) as position
      from public.match_reserve_assignments
      where status = 'ACTIVE'
    ) ranked
    where position > 1
  loop
    update public.match_reserve_assignments
    set
      status = 'REMOVED',
      removed_by = added_by,
      removed_at = clock_timestamp(),
      removal_reason = 'Replaced when Field moved to one reserve per game.'
    where id = duplicate_reserve.id;
  end loop;

  -- The original generated constraints couple side to match kind. New reserve
  -- assignments are deliberately game-wide and have no side.
  for constraint_to_drop in
    select constraint_name
    from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'match_reserve_assignments'
      and constraint_type = 'CHECK'
      and constraint_name in (
        select conname
        from pg_constraint
        where conrelid = 'public.match_reserve_assignments'::regclass
          and pg_get_constraintdef(oid) ilike '%side%'
      )
  loop
    execute format(
      'alter table public.match_reserve_assignments drop constraint %I',
      constraint_to_drop.constraint_name
    );
  end loop;
end;
$$;

alter table public.match_reserve_assignments
  alter column side drop not null;

alter table public.match_reserve_assignments
  add constraint match_reserve_assignment_match_check check (
    (match_kind = 'CLAN' and fixture_id is not null
      and open_queue_game_id is null)
    or
    (match_kind = 'SOLO' and open_queue_game_id is not null
      and fixture_id is null)
  );

drop index if exists public.match_reserve_active_fixture_side_idx;
drop index if exists public.match_reserve_active_solo_side_idx;
drop index if exists public.match_reserve_active_fixture_player_idx;
drop index if exists public.match_reserve_active_solo_player_idx;

create unique index match_reserve_one_active_fixture_idx
on public.match_reserve_assignments (fixture_id)
where status = 'ACTIVE' and fixture_id is not null;

create unique index match_reserve_one_active_solo_idx
on public.match_reserve_assignments (open_queue_game_id)
where status = 'ACTIVE' and open_queue_game_id is not null;

drop function if exists public.admin_assign_match_reserve(
  uuid, text, uuid, uuid, text, text
);

create or replace function public.admin_assign_match_reserve(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_use uuid,
  note_to_use text
)
returns public.match_reserve_assignments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  match_status text;
  assignment public.match_reserve_assignments%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(trim(coalesce(note_to_use, ''))) not between 3 and 500 then
    raise exception 'Explain why this player is being added as the reserve.';
  end if;
  if not exists (select 1 from public.profiles where id = profile_id_to_use) then
    raise exception 'Player not found.';
  end if;

  if normalized_kind = 'SOLO' then
    select game.status into match_status
    from public.open_queue_games game
    where game.id = match_id_to_use
    for update;
    if match_status is null then raise exception 'Solo game not found.'; end if;
    if match_status not in ('OPEN', 'FULL') then
      raise exception 'The reserve can only be changed before this game starts.';
    end if;
    if exists (
      select 1 from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.profile_id = profile_id_to_use
        and booking.status = 'CONFIRMED'
    ) then
      raise exception 'This player already has a confirmed place in the game.';
    end if;
  elsif normalized_kind = 'CLAN' then
    select fixture.status into match_status
    from public.fixtures fixture
    where fixture.id = match_id_to_use
    for update;
    if match_status is null then raise exception 'Clan fixture not found.'; end if;
    if match_status not in ('OPEN', 'SCHEDULED') then
      raise exception 'The reserve can only be changed before this game starts.';
    end if;
    if exists (
      select 1
      from public.fixture_reliability_roster_history roster
      where roster.fixture_id = match_id_to_use
        and roster.profile_id = profile_id_to_use
        and roster.status = 'CONFIRMED'
    ) or exists (
      select 1
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = match_id_to_use
        and appearance.profile_id = profile_id_to_use
        and appearance.played
    ) then
      raise exception 'This player is already in the official match roster.';
    end if;
  else
    raise exception 'Game type must be solo or clan.';
  end if;

  if exists (
    select 1 from public.match_reserve_assignments reserve
    where reserve.status = 'ACTIVE'
      and (
        (normalized_kind = 'SOLO'
          and reserve.open_queue_game_id = match_id_to_use)
        or
        (normalized_kind = 'CLAN' and reserve.fixture_id = match_id_to_use)
      )
  ) then
    raise exception 'This game already has a reserve. Remove the current reserve first.';
  end if;

  insert into public.match_reserve_assignments (
    match_kind, fixture_id, open_queue_game_id, profile_id, side, note, added_by
  ) values (
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    profile_id_to_use,
    null,
    trim(note_to_use),
    actor_admin_id
  ) returning * into assignment;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    'MATCH_RESERVE_ASSIGNED',
    case when normalized_kind = 'SOLO'
      then 'SOLO_MATCH' else 'CLAN_MATCH' end,
    match_id_to_use,
    trim(note_to_use),
    '{}'::jsonb,
    jsonb_build_object(
      'reserve_assignment_id', assignment.id,
      'profile_id', profile_id_to_use,
      'scope', 'GAME'
    )
  );

  return assignment;
end;
$$;

revoke all on function public.admin_assign_match_reserve(
  uuid, text, uuid, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_assign_match_reserve(
  uuid, text, uuid, uuid, text
) to service_role;

comment on table public.match_reserve_assignments is
'Audited one-per-game standby assignments. Any app player may be selected, but a confirmed participant cannot also be the reserve.';

create or replace function public.admin_report_game_player(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_use uuid,
  category_to_use text,
  priority_to_use text,
  details_to_use text,
  strike_count_to_use integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_priority text := upper(trim(coalesce(priority_to_use, '')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  report_id_to_use uuid;
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_use public.match_attendance_records%rowtype;
  incident_id_to_use uuid;
  match_found boolean := false;
  player_is_participant boolean := false;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if normalized_kind not in ('SOLO', 'CLAN') then
    raise exception 'Game type must be solo or clan.';
  end if;
  if normalized_category not in (
    'HARASSMENT', 'THREATS_OR_VIOLENCE', 'DISCRIMINATION',
    'DANGEROUS_PLAY', 'CHEATING', 'NO_SHOW_OR_MATCH_MANIPULATION',
    'INAPPROPRIATE_CONTENT', 'SAFETY_OR_VENUE', 'SCORE_OR_RESULT',
    'REFEREE_ABUSE', 'OTHER'
  ) then
    raise exception 'Choose a valid report category.';
  end if;
  if normalized_priority not in ('LOW', 'NORMAL', 'HIGH', 'URGENT') then
    raise exception 'Choose a valid report priority.';
  end if;
  if char_length(normalized_details) not between 10 and 2000 then
    raise exception 'Record a clear reason between 10 and 2000 characters.';
  end if;
  if strike_count_to_use not between 0 and 3 then
    raise exception 'Issue between zero and three strikes.';
  end if;
  if not exists (select 1 from public.profiles where id = profile_id_to_use) then
    raise exception 'Player not found.';
  end if;

  if normalized_kind = 'SOLO' then
    select exists (
      select 1 from public.open_queue_games where id = match_id_to_use
    ) into match_found;
    select exists (
      select 1 from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.profile_id = profile_id_to_use
    ) or exists (
      select 1 from public.match_attendance_records attendance
      where attendance.open_queue_game_id = match_id_to_use
        and attendance.profile_id = profile_id_to_use
    ) into player_is_participant;
  else
    select exists (
      select 1 from public.fixtures where id = match_id_to_use
    ) into match_found;
    select exists (
      select 1 from public.fixture_reliability_roster_history roster
      where roster.fixture_id = match_id_to_use
        and roster.profile_id = profile_id_to_use
    ) or exists (
      select 1 from public.fixture_player_appearances appearance
      where appearance.fixture_id = match_id_to_use
        and appearance.profile_id = profile_id_to_use
    ) or exists (
      select 1 from public.match_attendance_records attendance
      where attendance.fixture_id = match_id_to_use
        and attendance.profile_id = profile_id_to_use
    ) into player_is_participant;
  end if;
  if not match_found then raise exception 'Game not found.'; end if;
  if not player_is_participant then
    raise exception 'Only a player connected to this game can be reported here.';
  end if;

  if strike_count_to_use > 0 then
    terms_to_use := public.ensure_match_reliability_terms(
      normalized_kind,
      match_id_to_use
    );
    if normalized_kind = 'CLAN' then
      perform public.initialize_fixture_reliability_roster(match_id_to_use);
    end if;
    perform public.ensure_match_attendance_records(
      normalized_kind,
      match_id_to_use
    );
    select * into attendance_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.profile_id = profile_id_to_use
    order by attendance.expected_for_match desc, attendance.created_at
    limit 1
    for update;
    if attendance_to_use.id is null then
      raise exception 'This player has no reliability attendance record for the game.';
    end if;
    if exists (
      select 1 from public.reliability_incidents incident
      where incident.attendance_id = attendance_to_use.id
        and incident.reversal_of is null
    ) then
      raise exception 'This player already has a reliability incident for this game.';
    end if;
  end if;

  insert into public.moderation_reports (
    reporter_referee_id, source, subject_type, subject_profile_id,
    fixture_id, open_queue_game_id, category, details, priority, status,
    assigned_admin_id, resolution_note, resolved_by, resolved_at
  ) values (
    actor_admin_id,
    'ADMIN',
    case when normalized_kind = 'SOLO'
      then 'SOLO_MATCH' else 'CLAN_MATCH' end,
    match_id_to_use,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    normalized_category,
    normalized_details,
    normalized_priority,
    case when strike_count_to_use > 0 then 'ACTIONED' else 'OPEN' end,
    case when strike_count_to_use > 0 then actor_admin_id end,
    case when strike_count_to_use > 0
      then strike_count_to_use::text || ' reliability strike(s) issued by an administrator.' end,
    case when strike_count_to_use > 0 then actor_admin_id end,
    case when strike_count_to_use > 0 then clock_timestamp() end
  ) returning id into report_id_to_use;

  if strike_count_to_use > 0 then
    incident_id_to_use := public.record_reliability_incident(
      attendance_to_use.id,
      'ADMIN_REPORTED',
      strike_count_to_use,
      clock_timestamp()
    );
    insert into public.notifications (
      recipient_profile_id, type, title, body,
      related_entity_type, related_entity_id, data
    ) values (
      profile_id_to_use,
      'RELIABILITY_OUTCOME',
      'Field reliability decision',
      strike_count_to_use::text || case when strike_count_to_use = 1
        then ' reliability strike was added after an administrator reviewed your match.'
        else ' reliability strikes were added after an administrator reviewed your match.' end,
      'MODERATION_REPORT',
      report_id_to_use,
      jsonb_build_object(
        'strike_count', strike_count_to_use,
        'incident_id', incident_id_to_use,
        'match_kind', normalized_kind,
        'match_id', match_id_to_use
      )
    );
  end if;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason, after_state
  ) values (
    actor_admin_id,
    case when strike_count_to_use > 0
      then 'PLAYER_REPORTED_AND_STRUCK' else 'PLAYER_REPORTED' end,
    'PLAYER',
    profile_id_to_use,
    normalized_details,
    jsonb_build_object(
      'report_id', report_id_to_use,
      'profile_id', profile_id_to_use,
      'match_kind', normalized_kind,
      'match_id', match_id_to_use,
      'category', normalized_category,
      'priority', normalized_priority,
      'strike_count', strike_count_to_use,
      'incident_id', incident_id_to_use
    )
  );

  return jsonb_build_object(
    'report_id', report_id_to_use,
    'incident_id', incident_id_to_use,
    'strike_count', strike_count_to_use
  );
end;
$$;

revoke all on function public.admin_report_game_player(
  uuid, text, uuid, uuid, text, text, text, integer
) from public, anon, authenticated;
grant execute on function public.admin_report_game_player(
  uuid, text, uuid, uuid, text, text, text, integer
) to service_role;

comment on function public.admin_report_game_player(
  uuid, text, uuid, uuid, text, text, text, integer
) is
'Atomically creates an admin player report for a game and optionally issues policy-backed reliability strikes.';
