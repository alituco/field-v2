-- Reviewable referee-awarded clan forfeits.
--
-- The assigned referee can atomically report one of the two clans and abandon
-- the live fixture. The opponent is shown as the provisional 3-0 winner
-- immediately, while the fixture remains CANCELLED and no clan/player SR is
-- applied. An admin must confirm the result before the fixture becomes FINAL.

create table if not exists public.match_forfeit_decisions (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete restrict,
  stoppage_id uuid not null references public.match_stoppages(id)
    on delete restrict,
  source_report_id uuid not null references public.moderation_reports(id)
    on delete restrict,
  stoppage_report_id uuid references public.moderation_reports(id)
    on delete restrict,
  reported_clan_id uuid not null references public.clans(id) on delete restrict,
  awarded_clan_id uuid not null references public.clans(id) on delete restrict,
  provisional_home_score integer not null check (provisional_home_score >= 0),
  provisional_away_score integer not null check (provisional_away_score >= 0),
  previous_home_score integer check (previous_home_score is null or previous_home_score >= 0),
  previous_away_score integer check (previous_away_score is null or previous_away_score >= 0),
  previous_winner_clan_id uuid references public.clans(id) on delete set null,
  previous_home_sr_change integer,
  previous_away_sr_change integer,
  state text not null default 'PENDING_REVIEW' check (
    state in ('PENDING_REVIEW', 'CONFIRMED', 'OVERTURNED')
  ),
  created_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  reviewed_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  reviewed_at timestamptz,
  review_note text check (review_note is null or char_length(review_note) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (fixture_id),
  unique (stoppage_id),
  unique (source_report_id),
  unique (stoppage_report_id),
  check (reported_clan_id <> awarded_clan_id),
  check (
    (provisional_home_score = 3 and provisional_away_score = 0)
    or (provisional_home_score = 0 and provisional_away_score = 3)
  ),
  check (
    (state = 'PENDING_REVIEW'
      and reviewed_by is null
      and reviewed_at is null
      and review_note is null)
    or (state in ('CONFIRMED', 'OVERTURNED')
      and reviewed_by is not null
      and reviewed_at is not null
      and review_note is not null)
  )
);

drop trigger if exists set_match_forfeit_decisions_updated_at
on public.match_forfeit_decisions;
create trigger set_match_forfeit_decisions_updated_at
before update on public.match_forfeit_decisions
for each row execute function public.set_updated_at();

create index if not exists match_forfeit_decisions_review_queue_idx
on public.match_forfeit_decisions (state, created_at desc);

alter table public.match_forfeit_decisions enable row level security;
revoke all on table public.match_forfeit_decisions from anon, authenticated;
grant all on table public.match_forfeit_decisions to service_role;

-- Keep the event trail explicit instead of disguising a forfeit as a goal or
-- score correction. Existing app clients render unknown event labels safely.
alter table public.fixture_events
drop constraint if exists fixture_events_event_type_check;
alter table public.fixture_events
add constraint fixture_events_event_type_check check (
  event_type in (
    'MATCH_STARTED',
    'MATCH_PAUSED',
    'MATCH_RESUMED',
    'MATCH_ENDED',
    'MATCH_STOPPED',
    'GOAL',
    'BLUE_CARD',
    'BLUE_CARD_EXPIRED',
    'CORRECTION',
    'FORFEIT_PROVISIONAL',
    'FORFEIT_CONFIRMED',
    'FORFEIT_OVERTURNED'
  )
);

create or replace function public.referee_report_clan_forfeit(
  actor_referee_id uuid,
  fixture_id_to_stop uuid,
  reported_clan_id_to_use uuid,
  category_to_use text,
  details_to_use text,
  reason_code_to_use text,
  note_to_use text default null,
  replay_offset_seconds_to_use integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_before public.fixtures%rowtype;
  existing_decision public.match_forfeit_decisions%rowtype;
  decision public.match_forfeit_decisions%rowtype;
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  normalized_reason text := upper(trim(coalesce(reason_code_to_use, '')));
  normalized_note text := trim(coalesce(note_to_use, ''));
  awarded_clan_id_to_use uuid;
  provisional_home integer;
  provisional_away integer;
  stoppage_id_to_use uuid;
  report_id_to_use uuid;
  stoppage_report_id_to_use uuid;
  elapsed_seconds_to_use integer := 0;
begin
  if not exists (
    select 1
    from public.referee_profiles referee
    join public.fixture_referee_assignments assignment
      on assignment.referee_id = referee.profile_id
     and assignment.fixture_id = fixture_id_to_stop
    where referee.profile_id = actor_referee_id
      and referee.is_active
  ) then
    raise exception 'Only the active referee assigned to this match can award a provisional forfeit.';
  end if;

  select * into fixture_before
  from public.fixtures fixture
  where fixture.id = fixture_id_to_stop
  for update;

  if fixture_before.id is null then
    raise exception 'Match not found.';
  end if;

  -- A network retry returns the first decision and never inserts another
  -- stoppage/report or applies another result.
  select * into existing_decision
  from public.match_forfeit_decisions forfeit
  where forfeit.fixture_id = fixture_id_to_stop;

  if existing_decision.id is not null then
    if existing_decision.created_by <> actor_referee_id
      or existing_decision.reported_clan_id <> reported_clan_id_to_use then
      raise exception 'This match already has a different forfeit decision.';
    end if;

    return jsonb_build_object(
      'decisionId', existing_decision.id,
      'status', existing_decision.state,
      'fixtureId', existing_decision.fixture_id,
      'stoppageId', existing_decision.stoppage_id,
      'reportId', existing_decision.source_report_id,
      'stoppageReportId', existing_decision.stoppage_report_id,
      'reportedClanId', existing_decision.reported_clan_id,
      'awardedClanId', existing_decision.awarded_clan_id,
      'homeScore', existing_decision.provisional_home_score,
      'awayScore', existing_decision.provisional_away_score,
      'createdAt', existing_decision.created_at,
      'idempotent', true
    );
  end if;

  if fixture_before.status <> 'LIVE' then
    raise exception 'Only a live match can be abandoned with a provisional forfeit.';
  end if;
  if fixture_before.away_clan_id is null then
    raise exception 'A forfeit requires two participating clans.';
  end if;
  if reported_clan_id_to_use not in (
    fixture_before.home_clan_id,
    fixture_before.away_clan_id
  ) then
    raise exception 'The reported clan is not part of this match.';
  end if;
  if exists (
    select 1 from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_stop
  ) then
    raise exception 'A rated fixture cannot be converted into a provisional forfeit.';
  end if;

  if normalized_category not in (
    'HARASSMENT', 'THREATS_OR_VIOLENCE', 'DISCRIMINATION',
    'DANGEROUS_PLAY', 'CHEATING', 'NO_SHOW_OR_MATCH_MANIPULATION',
    'INAPPROPRIATE_CONTENT', 'SAFETY_OR_VENUE', 'SCORE_OR_RESULT',
    'REFEREE_ABUSE', 'OTHER'
  ) then
    raise exception 'Choose a valid report reason.';
  end if;
  if char_length(normalized_details) < 10
    or char_length(normalized_details) > 2000 then
    raise exception 'Explain why this clan caused the match to be abandoned.';
  end if;
  if normalized_reason not in (
    'FIGHTING_OR_VIOLENCE',
    'THREAT_TO_REFEREE',
    'CROWD_OR_SECURITY',
    'INSUFFICIENT_PLAYERS',
    'TEAM_WALKOUT',
    'OTHER'
  ) then
    raise exception 'That stoppage reason cannot automatically award a forfeit.';
  end if;
  if char_length(normalized_note) > 2000
    or (normalized_reason = 'OTHER' and char_length(normalized_note) < 10) then
    raise exception 'Add a short explanation for the forfeit.';
  end if;
  if replay_offset_seconds_to_use is not null
    and replay_offset_seconds_to_use not between 0 and 10800 then
    raise exception 'Replay time must be between 0:00 and 180:00.';
  end if;

  awarded_clan_id_to_use := case
    when reported_clan_id_to_use = fixture_before.home_clan_id
      then fixture_before.away_clan_id
    else fixture_before.home_clan_id
  end;
  provisional_home := case
    when awarded_clan_id_to_use = fixture_before.home_clan_id then 3 else 0
  end;
  provisional_away := case
    when awarded_clan_id_to_use = fixture_before.away_clan_id then 3 else 0
  end;

  stoppage_id_to_use := public.referee_record_match_stoppage(
    actor_referee_id,
    'CLAN',
    fixture_id_to_stop,
    'ABANDON',
    normalized_reason,
    coalesce(nullif(normalized_note, ''), normalized_details)
  );

  select stoppage.elapsed_seconds into elapsed_seconds_to_use
  from public.match_stoppages stoppage
  where stoppage.id = stoppage_id_to_use;

  -- The neutral stoppage RPC always creates a generic MATCH report. Preserve
  -- and link it as supporting evidence, but make the more specific CLAN report
  -- below canonical so admins do not receive two open queue items for one act.
  select report.id into stoppage_report_id_to_use
  from public.moderation_reports report
  where report.reporter_referee_id = actor_referee_id
    and report.source = 'REFEREE'
    and report.subject_type = 'MATCH'
    and report.fixture_id = fixture_id_to_stop
    and report.status = 'OPEN'
    and report.created_at = transaction_timestamp()
  order by report.created_at desc, report.id desc
  limit 1;

  insert into public.moderation_reports (
    reporter_referee_id,
    source,
    subject_type,
    subject_clan_id,
    fixture_id,
    category,
    details,
    replay_offset_seconds,
    priority
  ) values (
    actor_referee_id,
    'REFEREE',
    'CLAN',
    reported_clan_id_to_use,
    fixture_id_to_stop,
    normalized_category,
    normalized_details,
    coalesce(replay_offset_seconds_to_use, elapsed_seconds_to_use),
    'URGENT'
  ) returning id into report_id_to_use;

  if stoppage_report_id_to_use is not null then
    update public.moderation_reports
    set
      status = 'DUPLICATE',
      resolution_note = 'Supporting stoppage evidence linked to clan report '
        || report_id_to_use::text || '.',
      resolved_by = actor_referee_id,
      resolved_at = now()
    where id = stoppage_report_id_to_use;
  end if;

  insert into public.match_forfeit_decisions (
    fixture_id,
    stoppage_id,
    source_report_id,
    stoppage_report_id,
    reported_clan_id,
    awarded_clan_id,
    provisional_home_score,
    provisional_away_score,
    previous_home_score,
    previous_away_score,
    previous_winner_clan_id,
    previous_home_sr_change,
    previous_away_sr_change,
    created_by
  ) values (
    fixture_id_to_stop,
    stoppage_id_to_use,
    report_id_to_use,
    stoppage_report_id_to_use,
    reported_clan_id_to_use,
    awarded_clan_id_to_use,
    provisional_home,
    provisional_away,
    fixture_before.home_score,
    fixture_before.away_score,
    fixture_before.winner_clan_id,
    fixture_before.home_sr_change,
    fixture_before.away_sr_change,
    actor_referee_id
  ) returning * into decision;

  -- CANCELLED prevents every existing FINAL-status rating trigger from firing.
  -- The score/winner are deliberately visible as provisional review metadata.
  update public.fixtures
  set
    home_score = provisional_home,
    away_score = provisional_away,
    winner_clan_id = awarded_clan_id_to_use,
    home_sr_change = null,
    away_sr_change = null,
    cancellation_context = cancellation_context || jsonb_build_object(
      'result_origin', 'REFEREE_FORFEIT',
      'forfeit_decision_id', decision.id,
      'forfeit_review_status', 'PENDING_REVIEW',
      'reported_clan_id', reported_clan_id_to_use,
      'awarded_clan_id', awarded_clan_id_to_use,
      'provisional_home_score', provisional_home,
      'provisional_away_score', provisional_away,
      'source_report_id', report_id_to_use,
      'stoppage_report_id', stoppage_report_id_to_use
    )
  where id = fixture_id_to_stop;

  insert into public.fixture_events (
    fixture_id, event_type, minute, second, clan_id, note
  ) values (
    fixture_id_to_stop,
    'FORFEIT_PROVISIONAL',
    elapsed_seconds_to_use / 60,
    elapsed_seconds_to_use % 60,
    awarded_clan_id_to_use,
    format(
      'Provisional 3-0 forfeit awarded to the opponent; admin review required. Decision %s.',
      decision.id
    )
  );

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
    'PROVISIONAL_FORFEIT_AWARDED',
    'CLAN_MATCH',
    fixture_id_to_stop,
    normalized_details,
    jsonb_build_object(
      'status', fixture_before.status,
      'home_score', fixture_before.home_score,
      'away_score', fixture_before.away_score,
      'winner_clan_id', fixture_before.winner_clan_id
    ),
    jsonb_build_object(
      'status', 'CANCELLED',
      'decision_id', decision.id,
      'review_status', decision.state,
      'reported_clan_id', reported_clan_id_to_use,
      'awarded_clan_id', awarded_clan_id_to_use,
      'home_score', provisional_home,
      'away_score', provisional_away,
      'rating_policy', 'DEFER_UNTIL_ADMIN_CONFIRMATION'
    )
  );

  return jsonb_build_object(
    'decisionId', decision.id,
    'status', decision.state,
    'fixtureId', decision.fixture_id,
    'stoppageId', decision.stoppage_id,
    'reportId', decision.source_report_id,
    'stoppageReportId', decision.stoppage_report_id,
    'reportedClanId', decision.reported_clan_id,
    'awardedClanId', decision.awarded_clan_id,
    'homeScore', decision.provisional_home_score,
    'awayScore', decision.provisional_away_score,
    'createdAt', decision.created_at,
    'idempotent', false
  );
end;
$$;

create or replace function public.admin_review_clan_forfeit(
  actor_admin_id uuid,
  decision_id_to_review uuid,
  action_to_take text,
  review_note_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  decision public.match_forfeit_decisions%rowtype;
  fixture_to_review public.fixtures%rowtype;
  normalized_action text := upper(trim(coalesce(action_to_take, '')));
  normalized_note text := trim(coalesce(review_note_to_use, ''));
  home_rating integer;
  away_rating integer;
  home_delta integer;
  away_delta integer;
  next_state text;
  elapsed_seconds_to_use integer := 0;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_action = 'REJECT' then normalized_action := 'OVERTURN'; end if;
  if normalized_action not in ('CONFIRM', 'OVERTURN') then
    raise exception 'Choose whether to confirm or overturn the provisional forfeit.';
  end if;
  if char_length(normalized_note) < 10 or char_length(normalized_note) > 2000 then
    raise exception 'Add a clear review note (at least 10 characters).';
  end if;

  select * into decision
  from public.match_forfeit_decisions forfeit
  where forfeit.id = decision_id_to_review
  for update;

  if decision.id is null then raise exception 'Forfeit decision not found.'; end if;
  next_state := case
    when normalized_action = 'CONFIRM' then 'CONFIRMED'
    else 'OVERTURNED'
  end;

  -- Network retries after a committed review are safe and do not apply SR or
  -- win/loss counters a second time.
  if decision.state = next_state then
    return jsonb_build_object(
      'decisionId', decision.id,
      'status', decision.state,
      'fixtureId', decision.fixture_id,
      'reportId', decision.source_report_id,
      'stoppageId', decision.stoppage_id,
      'stoppageReportId', decision.stoppage_report_id,
      'homeScore', decision.provisional_home_score,
      'awayScore', decision.provisional_away_score,
      'idempotent', true
    );
  end if;
  if decision.state <> 'PENDING_REVIEW' then
    raise exception 'This provisional forfeit has already been reviewed.';
  end if;

  select * into fixture_to_review
  from public.fixtures fixture
  where fixture.id = decision.fixture_id
  for update;

  if fixture_to_review.id is null then raise exception 'Match not found.'; end if;
  if fixture_to_review.status <> 'CANCELLED'
    or fixture_to_review.cancellation_context ->> 'forfeit_decision_id'
      is distinct from decision.id::text then
    raise exception 'The abandoned match no longer matches this pending forfeit.';
  end if;
  if exists (
    select 1 from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = decision.fixture_id
  ) then
    raise exception 'This fixture already has applied player SR and cannot be reviewed safely.';
  end if;

  select stoppage.elapsed_seconds into elapsed_seconds_to_use
  from public.match_stoppages stoppage
  where stoppage.id = decision.stoppage_id;

  if normalized_action = 'CONFIRM' then
    -- This mirrors normal clan finalization. The fixture status changes to
    -- FINAL exactly once, so the existing player-SR trigger runs exactly once.
    perform clan.id
    from public.clans clan
    where clan.id in (
      fixture_to_review.home_clan_id,
      fixture_to_review.away_clan_id
    )
    order by clan.id
    for update;

    select clan.skill_rating into home_rating
    from public.clans clan
    where clan.id = fixture_to_review.home_clan_id;
    select clan.skill_rating into away_rating
    from public.clans clan
    where clan.id = fixture_to_review.away_clan_id;

    select delta.home_change, delta.away_change
    into home_delta, away_delta
    from public.calculate_fixture_sr_delta(
      home_rating,
      away_rating,
      decision.provisional_home_score,
      decision.provisional_away_score
    ) delta;

    update public.clans
    set
      skill_rating = greatest(0, skill_rating + home_delta),
      wins = wins + case
        when decision.provisional_home_score > decision.provisional_away_score
          then 1 else 0 end,
      losses = losses + case
        when decision.provisional_home_score < decision.provisional_away_score
          then 1 else 0 end
    where id = fixture_to_review.home_clan_id;

    update public.clans
    set
      skill_rating = greatest(0, skill_rating + away_delta),
      wins = wins + case
        when decision.provisional_away_score > decision.provisional_home_score
          then 1 else 0 end,
      losses = losses + case
        when decision.provisional_away_score < decision.provisional_home_score
          then 1 else 0 end
    where id = fixture_to_review.away_clan_id;

    update public.fixtures
    set
      status = 'FINAL',
      home_score = decision.provisional_home_score,
      away_score = decision.provisional_away_score,
      winner_clan_id = decision.awarded_clan_id,
      home_sr_change = home_delta,
      away_sr_change = away_delta,
      cancellation_code = null,
      cancellation_reason = null,
      cancelled_at = null,
      cancelled_by = null,
      cancellation_context = cancellation_context || jsonb_build_object(
        'forfeit_review_status', 'CONFIRMED',
        'forfeit_reviewed_by', actor_admin_id,
        'forfeit_reviewed_at', now(),
        'rating_policy', 'NORMAL_FINALIZATION_ON_CONFIRMATION'
      )
    where id = decision.fixture_id;

    insert into public.fixture_events (
      fixture_id, event_type, minute, second, clan_id, note
    ) values (
      decision.fixture_id,
      'FORFEIT_CONFIRMED',
      elapsed_seconds_to_use / 60,
      elapsed_seconds_to_use % 60,
      decision.awarded_clan_id,
      'Admin confirmed the 3-0 forfeit result. ' || normalized_note
    );

    update public.moderation_reports
    set
      status = 'ACTIONED',
      assigned_admin_id = actor_admin_id,
      resolution_note = normalized_note,
      resolved_by = actor_admin_id,
      resolved_at = now()
    where id = decision.source_report_id
      and status in ('OPEN', 'TRIAGED', 'INVESTIGATING');
  else
    -- Rejecting the provisional result restores the actual score at the stop.
    -- The fixture stays CANCELLED/abandoned and never crosses FINAL, so neither
    -- clan nor player rating ledgers are changed.
    update public.fixtures
    set
      home_score = decision.previous_home_score,
      away_score = decision.previous_away_score,
      winner_clan_id = decision.previous_winner_clan_id,
      home_sr_change = decision.previous_home_sr_change,
      away_sr_change = decision.previous_away_sr_change,
      cancellation_context = cancellation_context || jsonb_build_object(
        'forfeit_review_status', 'OVERTURNED',
        'forfeit_reviewed_by', actor_admin_id,
        'forfeit_reviewed_at', now()
      )
    where id = decision.fixture_id;

    insert into public.fixture_events (
      fixture_id, event_type, minute, second, clan_id, note
    ) values (
      decision.fixture_id,
      'FORFEIT_OVERTURNED',
      elapsed_seconds_to_use / 60,
      elapsed_seconds_to_use % 60,
      decision.reported_clan_id,
      'Admin overturned the provisional forfeit. ' || normalized_note
    );

    -- Overturning the score is not a finding that the underlying report was
    -- false. Keep it in the moderation workflow for a separate evidence review.
    update public.moderation_reports
    set
      status = case when status = 'OPEN' then 'TRIAGED' else status end,
      assigned_admin_id = coalesce(assigned_admin_id, actor_admin_id)
    where id = decision.source_report_id
      and status in ('OPEN', 'TRIAGED', 'INVESTIGATING');
  end if;

  update public.match_stoppages
  set
    state = 'RESOLVED',
    resolved_by = actor_admin_id,
    resolved_at = now(),
    resolution_note = format(
      'Provisional forfeit %s. %s',
      lower(next_state),
      normalized_note
    )
  where id = decision.stoppage_id;

  update public.match_forfeit_decisions
  set
    state = next_state,
    reviewed_by = actor_admin_id,
    reviewed_at = now(),
    review_note = normalized_note
  where id = decision.id
  returning * into decision;

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
    case
      when normalized_action = 'CONFIRM' then 'PROVISIONAL_FORFEIT_CONFIRMED'
      else 'PROVISIONAL_FORFEIT_OVERTURNED'
    end,
    'CLAN_MATCH',
    decision.fixture_id,
    normalized_note,
    jsonb_build_object(
      'decision_id', decision.id,
      'review_status', 'PENDING_REVIEW',
      'fixture_status', 'CANCELLED',
      'rating_policy', 'DEFER_UNTIL_ADMIN_CONFIRMATION'
    ),
    jsonb_build_object(
      'decision_id', decision.id,
      'review_status', decision.state,
      'fixture_status', case
        when decision.state = 'CONFIRMED' then 'FINAL' else 'CANCELLED' end,
      'home_score', case
        when decision.state = 'CONFIRMED' then decision.provisional_home_score
        else decision.previous_home_score end,
      'away_score', case
        when decision.state = 'CONFIRMED' then decision.provisional_away_score
        else decision.previous_away_score end,
      'rating_policy', case
        when decision.state = 'CONFIRMED'
          then 'NORMAL_FINALIZATION_ON_CONFIRMATION'
        else 'NO_RATING_CHANGE' end
    )
  );

  return jsonb_build_object(
    'decisionId', decision.id,
    'status', decision.state,
    'fixtureId', decision.fixture_id,
    'reportId', decision.source_report_id,
    'stoppageId', decision.stoppage_id,
    'stoppageReportId', decision.stoppage_report_id,
    'reportedClanId', decision.reported_clan_id,
    'awardedClanId', decision.awarded_clan_id,
    'homeScore', case
      when decision.state = 'CONFIRMED' then decision.provisional_home_score
      else decision.previous_home_score end,
    'awayScore', case
      when decision.state = 'CONFIRMED' then decision.provisional_away_score
      else decision.previous_away_score end,
    'idempotent', false
  );
end;
$$;

revoke all on function public.referee_report_clan_forfeit(
  uuid, uuid, uuid, text, text, text, text, integer
) from public, anon, authenticated;
grant execute on function public.referee_report_clan_forfeit(
  uuid, uuid, uuid, text, text, text, text, integer
) to service_role;

revoke all on function public.admin_review_clan_forfeit(
  uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.admin_review_clan_forfeit(
  uuid, uuid, text, text
) to service_role;

comment on table public.match_forfeit_decisions is
'A referee-awarded 3-0 clan forfeit is provisional and SR-neutral until an admin confirms it. Review is append-audited and idempotent.';
