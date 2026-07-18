-- Complete the effective-dated reliability contract without rewriting history.
--
-- * A future scheduled policy can be corrected at the same Bahrain effective
--   date by publishing an immutable successor. The highest version wins.
-- * Publication is serialized so concurrent admins cannot create two leaves.
-- * The configured reserve workflow is exposed as a manual Field-host plan.
--   This migration does not claim to automate reserve assignment.

drop index if exists public.reliability_policy_published_effective_idx;

create index reliability_policy_published_effective_idx
on public.reliability_policy_versions (effective_from, version desc)
where state = 'PUBLISHED';

create unique index reliability_policy_published_supersession_idx
on public.reliability_policy_versions (supersedes_id, effective_from)
where state = 'PUBLISHED' and supersedes_id is not null;

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
  source_policy public.reliability_policy_versions%rowtype;
  current_same_time public.reliability_policy_versions%rowtype;
  audit_action text := 'RELIABILITY_POLICY_PUBLISHED';
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if char_length(trim(coalesce(reason_to_use, ''))) not between 5 and 2000 then
    raise exception 'Explain why this policy version is being published.';
  end if;

  -- A single transaction at a time may choose the leaf for an effective date.
  -- Row locks alone are insufficient when no published row exists yet.
  perform pg_advisory_xact_lock(
    hashtext('field-reliability-policy-publication')::bigint
  );

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
  if not public.reliability_policy_config_is_valid(draft.config)
    or not public.reliability_policy_release_controls_are_valid(draft.config)
  then
    raise exception 'Reliability policy settings are incomplete or invalid.';
  end if;

  select * into source_policy
  from public.reliability_policy_versions policy
  where policy.id = draft.supersedes_id;
  if source_policy.id is null or source_policy.state <> 'PUBLISHED' then
    raise exception 'A published source policy is required before this draft can be published.';
  end if;

  select * into current_same_time
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from = draft.effective_from
    and policy.id <> draft.id
  order by policy.version desc
  limit 1
  for update;

  if current_same_time.id is not null then
    if draft.supersedes_id is distinct from current_same_time.id then
      raise exception using
        errcode = '40001',
        message = 'This scheduled policy has a newer version. Refresh and replace the current scheduled version.';
    end if;
    audit_action := 'RELIABILITY_POLICY_SCHEDULED_REPLACED';
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
    audit_action,
    'POLICY',
    published.id,
    trim(reason_to_use),
    jsonb_build_object(
      'state', 'DRAFT',
      'replaced_policy_id', current_same_time.id,
      'replaced_policy_version', current_same_time.version
    ),
    jsonb_build_object(
      'state', 'PUBLISHED',
      'version', published.version,
      'effective_from', published.effective_from,
      'config', published.config,
      'summary', published.summary,
      'supersedes_id', published.supersedes_id
    )
  );

  return published;
end;
$$;

revoke all on function public.admin_publish_reliability_policy(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_publish_reliability_policy(
  uuid, uuid, text
) to service_role;

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
    -- Clan attendance is derived from the immutable confirmed-roster snapshot.
    -- Create that source before materializing attendance rows.
    if normalized_kind = 'CLAN' then
      perform public.initialize_fixture_reliability_roster(match_id_to_use);
    end if;
    perform public.ensure_match_attendance_records(
      normalized_kind,
      match_id_to_use
    );

    select
      count(*) filter (where attendance.outcome is null)::integer,
      count(*) filter (where attendance.outcome = 'NO_SHOW')::integer,
      count(*)::integer,
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
      and attendance.expected_for_match
      and coalesce(attendance.outcome, '') not in (
        'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
      );

    select coalesce(jsonb_agg(
      jsonb_build_object(
        'attendance_record_id', attendance.id,
        'profile_id', attendance.profile_id,
        'display_name', profile.display_name,
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
      ) order by attendance.side, profile.display_name, attendance.profile_id
    ), '[]'::jsonb) into players_to_use
    from public.match_attendance_records attendance
    join public.profiles profile on profile.id = attendance.profile_id
    left join public.clans clan on clan.id = attendance.clan_id
    where attendance.terms_id = terms_to_use.id
      and attendance.expected_for_match
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
      server_now_to_use >= terms_to_use.check_in_opens_at
      and server_now_to_use < terms_to_use.no_show_cutoff_at,
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

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

comment on function public.admin_publish_reliability_policy(uuid,uuid,text) is
'Publishes an immutable reliability policy and permits only a current-leaf successor to replace a future policy at the same effective date.';

comment on function public.get_match_reliability_context(text,uuid) is
'Returns snapshotted reliability timing and private official attendance context, including the explicitly manual Field-host reserve plan.';
