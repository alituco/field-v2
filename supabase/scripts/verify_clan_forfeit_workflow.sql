-- Run after 20260715000005_create_reviewable_clan_forfeits.sql inside a
-- transaction that is rolled back by this script. This exercises both admin
-- outcomes and verifies retry/idempotency, Clan SR deferral, and the policy
-- rule that an abandoned match does not award Player SR.
\set ON_ERROR_STOP on

begin;

do $$
declare
  admin_id uuid;
  confirm_fixture record;
  overturn_fixture record;
  confirm_payload jsonb;
  retry_payload jsonb;
  overturn_payload jsonb;
  confirm_decision_id uuid;
  overturn_decision_id uuid;
  confirm_home_rating_before integer;
  confirm_away_rating_before integer;
  confirm_home_rating_after integer;
  confirm_away_rating_after integer;
  confirm_home_wins_after integer;
  confirm_away_wins_after integer;
  confirmed_player_events integer;
  overturn_home_rating_before integer;
  overturn_away_rating_before integer;
  previous_home_score integer;
  previous_away_score integer;
  confirm_participants uuid[];
  overturn_participants uuid[];
begin
  select referee.profile_id into admin_id
  from public.referee_profiles referee
  where referee.role = 'admin' and referee.is_active
  order by referee.created_at, referee.profile_id
  limit 1;

  select fixture.id, fixture.home_clan_id, fixture.away_clan_id,
    fixture.home_score, fixture.away_score
  into confirm_fixture
  from public.fixtures fixture
  where fixture.status in ('OPEN', 'SCHEDULED')
    and fixture.away_clan_id is not null
    and not exists (
      select 1 from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture.id
    )
  order by fixture.match_date, fixture.id
  limit 1;

  select fixture.id, fixture.home_clan_id, fixture.away_clan_id,
    fixture.home_score, fixture.away_score
  into overturn_fixture
  from public.fixtures fixture
  where fixture.status in ('OPEN', 'SCHEDULED')
    and fixture.away_clan_id is not null
    and fixture.id <> confirm_fixture.id
    and not exists (
      select 1 from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture.id
    )
  order by fixture.match_date, fixture.id
  limit 1;

  if admin_id is null or confirm_fixture.id is null or overturn_fixture.id is null then
    raise exception 'Forfeit verification needs one active admin and two unplayed clan fixtures.';
  end if;

  insert into public.fixture_referee_assignments (
    fixture_id, referee_id, assigned_by
  ) values (
    confirm_fixture.id, admin_id, admin_id
  ) on conflict (fixture_id) do update set
    referee_id = excluded.referee_id,
    assigned_by = excluded.assigned_by;

  perform public.ensure_match_attendance_records('CLAN', confirm_fixture.id);
  perform public.initialize_fixture_reliability_roster(confirm_fixture.id);
  update public.match_attendance_records attendance
  set
    checked_in_at = attendance.check_in_deadline_at - interval '1 minute',
    checked_in_by = admin_id
  where attendance.fixture_id = confirm_fixture.id
    and attendance.expected_for_match
    and attendance.outcome is null;
  select array_agg(attendance.profile_id order by attendance.profile_id)
  into confirm_participants
  from public.match_attendance_records attendance
  where attendance.fixture_id = confirm_fixture.id
    and attendance.expected_for_match
    and attendance.checked_in_at is not null;
  perform public.referee_start_fixture_atomic(
    confirm_fixture.id,
    confirm_participants,
    3600
  );
  update public.fixture_clock_states
  set started_at = clock_timestamp() - interval '5 minutes'
  where fixture_id = confirm_fixture.id;

  select skill_rating into confirm_home_rating_before
  from public.clans where id = confirm_fixture.home_clan_id;
  select skill_rating into confirm_away_rating_before
  from public.clans where id = confirm_fixture.away_clan_id;

  confirm_payload := public.referee_report_clan_forfeit(
    admin_id,
    confirm_fixture.id,
    confirm_fixture.home_clan_id,
    'NO_SHOW_OR_MATCH_MANIPULATION',
    'Verification: the home clan walked off and refused to continue.',
    'TEAM_WALKOUT',
    'Home clan explicitly refused the referee instruction to continue.',
    240
  );
  confirm_decision_id := (confirm_payload ->> 'decisionId')::uuid;

  if not exists (
    select 1 from public.fixtures fixture
    where fixture.id = confirm_fixture.id
      and fixture.status = 'CANCELLED'
      and fixture.home_score = 0
      and fixture.away_score = 3
      and fixture.winner_clan_id = confirm_fixture.away_clan_id
      and fixture.cancellation_context ->> 'forfeit_review_status'
        = 'PENDING_REVIEW'
  ) then
    raise exception 'Provisional forfeit was not displayed as a pending 0-3 result.';
  end if;
  if exists (
    select 1 from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = confirm_fixture.id
  ) then
    raise exception 'Player SR was applied before admin confirmation.';
  end if;
  if (select skill_rating from public.clans where id = confirm_fixture.home_clan_id)
      <> confirm_home_rating_before
    or (select skill_rating from public.clans where id = confirm_fixture.away_clan_id)
      <> confirm_away_rating_before then
    raise exception 'Clan SR changed before admin confirmation.';
  end if;
  if not exists (
    select 1
    from public.match_forfeit_decisions decision
    join public.moderation_reports report on report.id = decision.source_report_id
    left join public.moderation_reports generic
      on generic.id = decision.stoppage_report_id
    where decision.id = confirm_decision_id
      and decision.state = 'PENDING_REVIEW'
      and report.subject_type = 'CLAN'
      and report.status = 'OPEN'
      and (generic.id is null or generic.status = 'DUPLICATE')
  ) then
    raise exception 'Canonical clan report or linked duplicate stoppage report is wrong.';
  end if;

  retry_payload := public.referee_report_clan_forfeit(
    admin_id,
    confirm_fixture.id,
    confirm_fixture.home_clan_id,
    'NO_SHOW_OR_MATCH_MANIPULATION',
    'Verification retry of the same home clan forfeit workflow.',
    'TEAM_WALKOUT',
    'Verification retry must return the existing decision safely.',
    240
  );
  if (retry_payload ->> 'decisionId')::uuid <> confirm_decision_id
    or retry_payload ->> 'idempotent' <> 'true' then
    raise exception 'Referee retry did not return the existing decision.';
  end if;

  perform public.admin_review_clan_forfeit(
    admin_id,
    confirm_decision_id,
    'CONFIRM',
    'Verification replay and referee evidence support the forfeit.'
  );
  select skill_rating, wins into confirm_home_rating_after, confirm_home_wins_after
  from public.clans where id = confirm_fixture.home_clan_id;
  select skill_rating, wins into confirm_away_rating_after, confirm_away_wins_after
  from public.clans where id = confirm_fixture.away_clan_id;
  select count(*)::integer into confirmed_player_events
  from public.player_rating_events event
  where event.source_type = 'CLAN_FIXTURE'
    and event.source_id = confirm_fixture.id;

  if not exists (
    select 1 from public.fixtures fixture
    where fixture.id = confirm_fixture.id
      and fixture.status = 'FINAL'
      and fixture.home_score = 0
      and fixture.away_score = 3
      and fixture.home_sr_change is not null
      and fixture.away_sr_change is not null
      and fixture.cancellation_context ->> 'rating_policy'
        = 'CLAN_SR_ONLY_NO_PLAYER_SR'
  ) or not exists (
    select 1 from public.match_forfeit_decisions decision
    where decision.id = confirm_decision_id and decision.state = 'CONFIRMED'
  ) then
    raise exception 'Admin confirmation did not finalize the 0-3 result.';
  end if;
  if confirmed_player_events <> 0 then
    raise exception 'A confirmed abandonment incorrectly awarded Player SR.';
  end if;

  retry_payload := public.admin_review_clan_forfeit(
    admin_id,
    confirm_decision_id,
    'CONFIRM',
    'Verification retry must not apply the result a second time.'
  );
  if retry_payload ->> 'idempotent' <> 'true'
    or (select skill_rating from public.clans where id = confirm_fixture.home_clan_id)
      <> confirm_home_rating_after
    or (select skill_rating from public.clans where id = confirm_fixture.away_clan_id)
      <> confirm_away_rating_after
    or (select wins from public.clans where id = confirm_fixture.home_clan_id)
      <> confirm_home_wins_after
    or (select wins from public.clans where id = confirm_fixture.away_clan_id)
      <> confirm_away_wins_after
    or (select count(*) from public.player_rating_events event
        where event.source_type = 'CLAN_FIXTURE'
          and event.source_id = confirm_fixture.id)
      <> confirmed_player_events then
    raise exception 'Admin confirmation retry changed clan standings or SR.';
  end if;

  insert into public.fixture_referee_assignments (
    fixture_id, referee_id, assigned_by
  ) values (
    overturn_fixture.id, admin_id, admin_id
  ) on conflict (fixture_id) do update set
    referee_id = excluded.referee_id,
    assigned_by = excluded.assigned_by;

  perform public.ensure_match_attendance_records('CLAN', overturn_fixture.id);
  perform public.initialize_fixture_reliability_roster(overturn_fixture.id);
  update public.match_attendance_records attendance
  set
    checked_in_at = attendance.check_in_deadline_at - interval '1 minute',
    checked_in_by = admin_id
  where attendance.fixture_id = overturn_fixture.id
    and attendance.expected_for_match
    and attendance.outcome is null;
  select array_agg(attendance.profile_id order by attendance.profile_id)
  into overturn_participants
  from public.match_attendance_records attendance
  where attendance.fixture_id = overturn_fixture.id
    and attendance.expected_for_match
    and attendance.checked_in_at is not null;
  perform public.referee_start_fixture_atomic(
    overturn_fixture.id,
    overturn_participants,
    3600
  );
  update public.fixture_clock_states
  set started_at = clock_timestamp() - interval '3 minutes'
  where fixture_id = overturn_fixture.id;

  previous_home_score := overturn_fixture.home_score;
  previous_away_score := overturn_fixture.away_score;
  select skill_rating into overturn_home_rating_before
  from public.clans where id = overturn_fixture.home_clan_id;
  select skill_rating into overturn_away_rating_before
  from public.clans where id = overturn_fixture.away_clan_id;

  overturn_payload := public.referee_report_clan_forfeit(
    admin_id,
    overturn_fixture.id,
    overturn_fixture.away_clan_id,
    'THREATS_OR_VIOLENCE',
    'Verification: the away clan incident caused the abandonment.',
    'FIGHTING_OR_VIOLENCE',
    'Verification-only incident evidence for the overturn path.',
    120
  );
  overturn_decision_id := (overturn_payload ->> 'decisionId')::uuid;
  perform public.admin_review_clan_forfeit(
    admin_id,
    overturn_decision_id,
    'OVERTURN',
    'Verification evidence does not support the provisional result.'
  );

  if not exists (
    select 1 from public.fixtures fixture
    where fixture.id = overturn_fixture.id
      and fixture.status = 'CANCELLED'
      and fixture.home_score is not distinct from previous_home_score
      and fixture.away_score is not distinct from previous_away_score
      and fixture.cancellation_context ->> 'forfeit_review_status' = 'OVERTURNED'
  ) or not exists (
    select 1 from public.match_forfeit_decisions decision
    where decision.id = overturn_decision_id and decision.state = 'OVERTURNED'
  ) then
    raise exception 'Overturn did not restore the abandoned pre-forfeit state.';
  end if;
  if exists (
    select 1 from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = overturn_fixture.id
  ) or (select skill_rating from public.clans where id = overturn_fixture.home_clan_id)
      <> overturn_home_rating_before
    or (select skill_rating from public.clans where id = overturn_fixture.away_clan_id)
      <> overturn_away_rating_before then
    raise exception 'Overturn changed a clan/player rating ledger.';
  end if;
end;
$$;

rollback;
