-- Run after the moderation migration. This script wraps the report, discipline,
-- cancellation, and score-revision checks in a rollback-only transaction so no
-- representative-row changes are retained.
\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.verification_player_has_free_game_slot(player_id uuid)
returns boolean language plpgsql as $availability$
begin
  perform public.assert_player_has_one_game(player_id,'SOLO','00000000-0000-0000-0000-000000000000',true);
  return true;
exception when raise_exception then return false;
end;
$availability$;

do $$
declare
  reporter_id uuid;
  target_id uuid;
  admin_id uuid;
  report_id uuid;
  action_id uuid;
  status_payload jsonb;
  duplicate_rejected boolean := false;
  final_fixture record;
  final_solo record;
  future_fixture_id uuid;
  future_solo_id uuid;
  revision_id uuid;
  stoppage_id uuid;
  restriction_game_id uuid;
  restriction_game_starts_at timestamptz;
begin
  select profile.id into reporter_id
  from public.profiles profile
  order by profile.created_at, profile.id
  limit 1;

  select profile.id into target_id
  from public.profiles profile
  where profile.id <> reporter_id
    and pg_temp.verification_player_has_free_game_slot(profile.id)
  order by profile.created_at, profile.id
  limit 1;

  select referee.profile_id into admin_id
  from public.referee_profiles referee
  where referee.role = 'admin' and referee.is_active
  order by referee.created_at, referee.profile_id
  limit 1;

  if reporter_id is null or target_id is null or admin_id is null then
    raise exception 'Moderation verification needs two profiles and one active admin.';
  end if;

  perform set_config('request.jwt.claim.sub', reporter_id::text, true);
  report_id := public.submit_moderation_report(
    'PLAYER',
    target_id,
    'HARASSMENT',
    'Verification-only report that will be rolled back.',
    null,
    null
  );

  if not exists (
    select 1 from public.moderation_reports report
    where report.id = report_id
      and report.reporter_profile_id = reporter_id
      and report.source = 'MOBILE'
      and report.status = 'OPEN'
  ) then
    raise exception 'Player report was not recorded with server-owned identity/state.';
  end if;

  begin
    perform public.submit_moderation_report(
      'PLAYER',
      target_id,
      'HARASSMENT',
      'Duplicate verification-only report.',
      null,
      null
    );
  exception when others then
    if position('already reported' in lower(sqlerrm)) > 0 then
      duplicate_rejected := true;
    else
      raise;
    end if;
  end;
  if not duplicate_rejected then
    raise exception 'Duplicate report protection did not reject the report.';
  end if;

  perform public.admin_update_moderation_report(
    admin_id, report_id, 'TRIAGE', null
  );
  if not exists (
    select 1 from public.moderation_reports report
    where report.id = report_id
      and report.status = 'TRIAGED'
      and report.assigned_admin_id = admin_id
  ) then
    raise exception 'Report triage did not assign the admin.';
  end if;

  select ((candidate.day::date + time '20:30') at time zone 'Asia/Bahrain')
  into restriction_game_starts_at
  from generate_series(
    current_date + interval '365 days',
    current_date + interval '380 days',
    interval '1 day'
  ) candidate(day)
  where extract(isodow from candidate.day) in (2, 5)
  order by candidate.day
  limit 1;

  insert into public.open_queue_games (
    format_version, currency, timezone, capacity,
    goalkeeper_capacity, defender_capacity, midfielder_capacity, attacker_capacity,
    venue,
    starts_at,
    ends_at,
    created_by
  ) values (
    'LEGACY_6V6', 'BHD', 'Asia/Bahrain', 12, 2, 4, 4, 2,
    'Moderation verification pitch',
    restriction_game_starts_at,
    restriction_game_starts_at + interval '1 hour',
    reporter_id
  ) returning id into restriction_game_id;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    base_amount_fils,
    payment_method,
    payment_status
  ) values (
    restriction_game_id,
    target_id,
    'GK',
    coalesce((
      select rating.skill_rating
      from public.player_ratings rating
      where rating.profile_id = target_id
    ), 1200),
    3000,
    3000,
    'MOCK',
    'PAID'
  );

  action_id := public.admin_apply_moderation_action(
    admin_id,
    'PLAYER',
    target_id,
    'SUSPENSION',
    'VERIFICATION',
    'Temporary verification account restriction.',
    'Verification-only evidence; transaction will roll back.',
    now() + interval '1 day',
    report_id,
    'ACCOUNT'
  );

  if not public.profile_has_active_play_restriction(target_id) then
    raise exception 'Active account suspension did not enforce the play restriction.';
  end if;
  if not exists (
    select 1
    from public.open_queue_bookings booking
    where booking.game_id = restriction_game_id
      and booking.profile_id = target_id
      and booking.status = 'CANCELLED'
      and booking.refund_percent = 100
      and booking.payment_status = 'REFUNDED'
  ) then
    raise exception 'Restricted player future booking was not released and refunded.';
  end if;

  perform set_config('request.jwt.claim.sub', target_id::text, true);
  status_payload := public.get_my_moderation_status();
  if status_payload ->> 'state' <> 'SUSPENDED'
    or status_payload ->> 'scope' <> 'ACCOUNT' then
    raise exception 'Moderation status did not expose the account suspension.';
  end if;

  perform public.admin_revoke_moderation_action(
    admin_id,
    action_id,
    'Verification completed successfully.'
  );
  if public.profile_has_active_play_restriction(target_id) then
    raise exception 'Revoked account suspension remained active.';
  end if;

  action_id := public.admin_apply_moderation_action(
    admin_id,
    'PLAYER',
    target_id,
    'WARNING',
    'VERIFICATION_WARNING',
    'Verification warning visible to the affected player.',
    'Verification-only warning evidence.',
    null,
    null,
    'NONE'
  );
  status_payload := public.get_my_moderation_status();
  if status_payload ->> 'state' <> 'WARNING'
    or status_payload ->> 'message'
      <> 'Verification warning visible to the affected player.' then
    raise exception 'Latest warning was not exposed to the affected player.';
  end if;
  perform public.admin_revoke_moderation_action(
    admin_id,
    action_id,
    'Verification warning completed.'
  );

  select fixture.id, fixture.home_score, fixture.away_score
  into final_fixture
  from public.fixtures fixture
  where fixture.status = 'FINAL'
    and fixture.home_score is not null
    and fixture.away_score is not null
  order by fixture.match_date desc, fixture.id
  limit 1;

  if final_fixture.id is not null then
    revision_id := public.admin_override_match_score(
      admin_id,
      'CLAN',
      final_fixture.id,
      case when final_fixture.home_score < 99
        then final_fixture.home_score + 1
        else final_fixture.home_score - 1 end,
      final_fixture.away_score,
      'Verification against the audited score correction path.'
    );
    if not exists (
      select 1 from public.match_score_revisions revision
      where revision.id = revision_id
        and revision.rating_policy = 'PRESERVE_APPLIED_SR'
    ) then
      raise exception 'Clan score revision was not audited.';
    end if;
  end if;

  select game.id, game.white_score, game.black_score
  into final_solo
  from public.open_queue_games game
  where game.status = 'FINAL'
    and game.white_score is not null
    and game.black_score is not null
  order by game.starts_at desc, game.id
  limit 1;

  if final_solo.id is not null then
    revision_id := public.admin_override_match_score(
      admin_id,
      'SOLO',
      final_solo.id,
      case when final_solo.white_score < 99
        then final_solo.white_score + 1
        else final_solo.white_score - 1 end,
      final_solo.black_score,
      'Verification against the audited solo score correction path.'
    );
    if not exists (
      select 1 from public.match_score_revisions revision
      where revision.id = revision_id
        and revision.match_kind = 'SOLO'
    ) then
      raise exception 'Solo score revision was not audited.';
    end if;
  end if;

  select fixture.id into future_fixture_id
  from public.fixtures fixture
  where fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
  order by fixture.match_date, fixture.id
  limit 1;
  if future_fixture_id is not null then
    insert into public.fixture_clock_states (
      fixture_id, status, started_at, accumulated_seconds
    ) values (
      future_fixture_id, 'RUNNING', now() - interval '30 seconds', 0
    ) on conflict (fixture_id) do update set
      status = 'RUNNING',
      started_at = excluded.started_at,
      accumulated_seconds = 0;
    update public.fixtures set status = 'LIVE' where id = future_fixture_id;

    stoppage_id := public.referee_record_match_stoppage(
      admin_id,
      'CLAN',
      future_fixture_id,
      'TEMPORARY',
      'SERIOUS_INJURY',
      'Verification-only safety stoppage.'
    );
    if not exists (
      select 1 from public.match_stoppages stoppage
      where stoppage.id = stoppage_id
        and stoppage.state = 'PENDING_REVIEW'
    ) or not exists (
      select 1 from public.fixture_clock_states clock
      where clock.fixture_id = future_fixture_id
        and clock.status = 'PAUSED'
    ) then
      raise exception 'Clan safety stoppage was not recorded and paused.';
    end if;

    perform public.admin_cancel_match(
      admin_id,
      'CLAN',
      future_fixture_id,
      'ADMIN_DECISION',
      'Verification-only cancellation that will be rolled back.'
    );
    if not exists (
      select 1 from public.fixtures fixture
      where fixture.id = future_fixture_id
        and fixture.status = 'CANCELLED'
        and fixture.cancelled_by = admin_id
    ) then
      raise exception 'Clan match cancellation was not recorded.';
    end if;
  end if;

  select game.id into future_solo_id
  from public.open_queue_games game
  where game.status in ('OPEN', 'FULL', 'LIVE')
  order by game.starts_at, game.id
  limit 1;
  if future_solo_id is not null then
    insert into public.open_queue_clock_states (
      game_id, status, started_at, accumulated_seconds
    ) values (
      future_solo_id, 'RUNNING', now() - interval '30 seconds', 0
    ) on conflict (game_id) do update set
      status = 'RUNNING',
      started_at = excluded.started_at,
      accumulated_seconds = 0;
    update public.open_queue_games set status = 'LIVE' where id = future_solo_id;

    stoppage_id := public.referee_record_match_stoppage(
      admin_id,
      'SOLO',
      future_solo_id,
      'TEMPORARY',
      'SERIOUS_INJURY',
      'Verification-only solo safety stoppage.'
    );
    if not exists (
      select 1 from public.match_stoppages stoppage
      where stoppage.id = stoppage_id
        and stoppage.match_kind = 'SOLO'
    ) or not exists (
      select 1 from public.open_queue_clock_states clock
      where clock.game_id = future_solo_id
        and clock.status = 'PAUSED'
    ) then
      raise exception 'Solo safety stoppage was not recorded and paused.';
    end if;

    perform public.admin_cancel_match(
      admin_id,
      'SOLO',
      future_solo_id,
      'ADMIN_DECISION',
      'Verification-only solo cancellation that will be rolled back.'
    );
    if not exists (
      select 1 from public.open_queue_games game
      where game.id = future_solo_id
        and game.status = 'CANCELLED'
        and game.cancelled_by = admin_id
    ) then
      raise exception 'Solo match cancellation was not recorded.';
    end if;
    if exists (
      select 1 from public.open_queue_bookings booking
      where booking.game_id = future_solo_id
        and booking.status = 'CONFIRMED'
    ) then
      raise exception 'Confirmed bookings remained on an admin-cancelled solo game.';
    end if;
  end if;

  if not exists (
    select 1 from public.admin_audit_events event
    where event.actor_referee_id = admin_id
      and event.created_at >= transaction_timestamp()
  ) then
    raise exception 'Admin actions did not create audit records.';
  end if;
end;
$$;

rollback;
