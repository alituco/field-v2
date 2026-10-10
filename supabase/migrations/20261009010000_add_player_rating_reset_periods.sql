-- A reset starts a new rating period; official matches and their SR audit
-- ledger remain intact. Installing this migration does not reset any player.
create schema if not exists fieldrush_rating_private;
revoke all on schema fieldrush_rating_private from public, anon, authenticated;

create table fieldrush_rating_private.reset_runs (
  id uuid primary key,
  reset_at timestamptz not null unique,
  last_applied_sequence bigint not null,
  reason text not null check (char_length(trim(reason)) between 10 and 1000),
  counts jsonb not null default '{}'::jsonb
);
create table fieldrush_rating_private.rating_snapshots (
  reset_id uuid not null references fieldrush_rating_private.reset_runs(id),
  profile_id uuid not null,
  snapshot jsonb not null,
  primary key (reset_id, profile_id)
);
create table fieldrush_rating_private.lineup_snapshots (
  reset_id uuid not null references fieldrush_rating_private.reset_runs(id),
  source_table text not null,
  row_key text not null,
  snapshot jsonb not null,
  primary key (reset_id, source_table, row_key)
);
revoke all on all tables in schema fieldrush_rating_private
  from public, anon, authenticated;

alter table public.player_ratings add column ratings_reset_at timestamptz;
alter table public.player_ratings add column ratings_reset_sequence bigint;
comment on column public.player_ratings.ratings_reset_at is
  'Start of the current rating period. Prior matches remain in history but do not qualify this player for current placement or affect current SR.';

create function public.current_player_rankings_reset_at()
returns timestamptz language sql stable security definer
set search_path = pg_catalog, fieldrush_rating_private as $$
  select max(reset_at) from fieldrush_rating_private.reset_runs;
$$;
revoke all on function public.current_player_rankings_reset_at()
  from public, anon, authenticated;
grant execute on function public.current_player_rankings_reset_at() to service_role;

create function public.player_rating_effective_at_is_current(effective_at_to_use timestamptz)
returns boolean language sql stable security definer
set search_path = pg_catalog, public as $$
  select public.current_player_rankings_reset_at() is null
    or effective_at_to_use >= public.current_player_rankings_reset_at();
$$;
revoke all on function public.player_rating_effective_at_is_current(timestamptz)
  from public, anon, authenticated;
grant execute on function public.player_rating_effective_at_is_current(timestamptz)
  to service_role;

create function public.player_rating_event_is_current(effective_at_to_use timestamptz, sequence_to_use bigint)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, fieldrush_rating_private as $$
  select public.player_rating_effective_at_is_current(effective_at_to_use)
    and sequence_to_use > coalesce((select max(last_applied_sequence)
      from fieldrush_rating_private.reset_runs), -1);
$$;
revoke all on function public.player_rating_event_is_current(timestamptz,bigint)
  from public, anon, authenticated;
grant execute on function public.player_rating_event_is_current(timestamptz,bigint) to service_role;

create function public.player_rating_source_is_current(source_type_to_use text, source_id_to_use uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, public as $$
  select not exists (select 1 from public.player_rating_events e
    where e.source_type = source_type_to_use and e.source_id = source_id_to_use
      and not public.player_rating_event_is_current(e.effective_at, e.applied_sequence));
$$;
revoke all on function public.player_rating_source_is_current(text,uuid)
  from public, anon, authenticated;
grant execute on function public.player_rating_source_is_current(text,uuid) to service_role;

create function public.open_queue_rating_is_in_current_period(game_id_to_use uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, public as $$
  select public.player_rating_effective_at_is_current(g.starts_at)
    and public.player_rating_source_is_current('OPEN_QUEUE', g.id)
    and public.player_rating_effective_at_is_current(coalesce(
      (select min(e.occurred_at) from public.open_queue_events e
        where e.game_id = g.id and e.event_type = 'MATCH_STARTED'), g.starts_at))
  from public.open_queue_games g where g.id = game_id_to_use;
$$;
revoke all on function public.open_queue_rating_is_in_current_period(uuid)
  from public, anon, authenticated;
grant execute on function public.open_queue_rating_is_in_current_period(uuid) to service_role;

create function public.inherit_player_rating_reset_period()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public as $$
begin
  new.ratings_reset_at := public.current_player_rankings_reset_at();
  select max(last_applied_sequence) into new.ratings_reset_sequence
    from fieldrush_rating_private.reset_runs;
  return new;
end;
$$;
revoke all on function public.inherit_player_rating_reset_period()
  from public, anon, authenticated;
create trigger inherit_player_rating_reset_period before insert on public.player_ratings
  for each row execute function public.inherit_player_rating_reset_period();

create function public.reset_player_rankings(request_id_to_use uuid, reason_to_use text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, fieldrush_rating_private as $$
declare
  previous_run fieldrush_rating_private.reset_runs%rowtype;
  cutoff timestamptz;
  sequence_cutoff bigint;
  player_count integer;
  solo_booking_count integer;
  solo_game_count integer;
  clan_appearance_count integer;
  result jsonb;
begin
  if request_id_to_use is null then
    raise exception 'A unique reset request ID is required.';
  end if;
  if char_length(trim(coalesce(reason_to_use, ''))) not between 10 and 1000 then
    raise exception 'Explain the ranking reset in 10 to 1000 characters.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('field-player-ranking-reset', 0));
  select * into previous_run from fieldrush_rating_private.reset_runs
    where id = request_id_to_use;
  if previous_run.id is not null then
    return previous_run.counts || jsonb_build_object('already_applied', true);
  end if;

  -- Freeze gameplay and rating writers while validating and taking recovery
  -- snapshots. This is a deliberately short administrative transaction.
  lock table public.open_queue_games, public.fixtures,
    public.open_queue_clock_states, public.fixture_clock_states,
    public.open_queue_events, public.fixture_events,
    public.open_queue_bookings, public.fixture_player_appearances,
    public.player_ratings, public.player_rating_events in access exclusive mode;
  if exists (select 1 from public.open_queue_games g where g.status = 'LIVE')
    or exists (select 1 from public.fixtures f where f.status = 'LIVE')
    or exists (
      select 1 from public.open_queue_clock_states c
      join public.open_queue_games g on g.id = c.game_id
      where g.status not in ('FINAL', 'CANCELLED')
        and (c.status <> 'NOT_STARTED' or c.started_at is not null or c.accumulated_seconds > 0)
    ) or exists (
      select 1 from public.fixture_clock_states c
      join public.fixtures f on f.id = c.fixture_id
      where f.status not in ('FINAL', 'CANCELLED')
        and (c.status <> 'NOT_STARTED' or c.started_at is not null or c.accumulated_seconds > 0)
    ) or exists (
      select 1 from public.open_queue_events e join public.open_queue_games g on g.id = e.game_id
      where g.status not in ('FINAL', 'CANCELLED') and e.event_type = 'MATCH_STARTED'
    ) or exists (
      select 1 from public.fixture_events e join public.fixtures f on f.id = e.fixture_id
      where f.status not in ('FINAL', 'CANCELLED') and e.event_type = 'MATCH_STARTED'
    ) then
    raise exception 'Finish or cancel every started match before resetting player rankings.';
  end if;

  cutoff := clock_timestamp();
  select coalesce(max(applied_sequence), 0) into sequence_cutoff from public.player_rating_events;
  insert into fieldrush_rating_private.reset_runs(id, reset_at, last_applied_sequence, reason)
    values (request_id_to_use, cutoff, sequence_cutoff, trim(reason_to_use));
  insert into fieldrush_rating_private.rating_snapshots(reset_id, profile_id, snapshot)
    select request_id_to_use, r.profile_id, to_jsonb(r) from public.player_ratings r;

  -- Future unstarted lineups may already have been assigned or booked using
  -- old ratings. Rebase only their SR snapshots; keep teams and booking data.
  insert into fieldrush_rating_private.lineup_snapshots(reset_id, source_table, row_key, snapshot)
    select request_id_to_use, 'open_queue_bookings', b.id::text, to_jsonb(b)
    from public.open_queue_bookings b join public.open_queue_games g on g.id = b.game_id
    where g.status in ('OPEN', 'FULL') and g.starts_at >= cutoff and b.status = 'CONFIRMED';
  insert into fieldrush_rating_private.lineup_snapshots(reset_id, source_table, row_key, snapshot)
    select request_id_to_use, 'open_queue_games', g.id::text, to_jsonb(g)
    from public.open_queue_games g
    where g.status in ('OPEN', 'FULL') and g.starts_at >= cutoff and g.teams_assigned_at is not null;
  insert into fieldrush_rating_private.lineup_snapshots(reset_id, source_table, row_key, snapshot)
    select request_id_to_use, 'fixture_player_appearances', a.fixture_id::text || ':' || a.profile_id::text, to_jsonb(a)
    from public.fixture_player_appearances a join public.fixtures f on f.id = a.fixture_id
    where f.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(f.match_date, f.time_slot) >= cutoff;

  update public.player_ratings set skill_rating = 1200, matches_played = 0,
    wins = 0, losses = 0, draws = 0, last_change = 0,
    ratings_reset_at = cutoff, ratings_reset_sequence = sequence_cutoff;
  get diagnostics player_count = row_count;
  update public.open_queue_bookings b set player_rating_at_booking = 1200,
    rating_at_team_assignment = case when b.rating_at_team_assignment is not null then 1200 else null end,
    rating_at_match_start = null, rating_change = null
    from public.open_queue_games g where g.id = b.game_id
      and g.status in ('OPEN', 'FULL') and g.starts_at >= cutoff and b.status = 'CONFIRMED';
  get diagnostics solo_booking_count = row_count;
  update public.open_queue_games g set white_average_sr = 1200, black_average_sr = 1200,
    match_average_sr = 1200, team_sr_spread = 0
    where g.status in ('OPEN', 'FULL') and g.starts_at >= cutoff and g.teams_assigned_at is not null;
  get diagnostics solo_game_count = row_count;
  update public.fixture_player_appearances a set rating_at_start = 1200, rating_change = null
    from public.fixtures f where f.id = a.fixture_id
      and f.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(f.match_date, f.time_slot) >= cutoff;
  get diagnostics clan_appearance_count = row_count;
  result := jsonb_build_object('reset_id', request_id_to_use, 'reset_at', cutoff,
    'reset_sequence', sequence_cutoff,
    'players_reset', player_count, 'solo_bookings_rebased', solo_booking_count,
    'solo_games_rebased', solo_game_count, 'clan_appearances_rebased', clan_appearance_count,
    'already_applied', false);
  update fieldrush_rating_private.reset_runs set counts = result where id = request_id_to_use;
  return result;
end;
$$;
revoke all on function public.reset_player_rankings(uuid, text) from public, anon, authenticated;
grant execute on function public.reset_player_rankings(uuid, text) to service_role;

-- Keep later operational/reliability safeguards intact. Every replacement is
-- checked against the installed definition, so drift aborts the migration.
create function fieldrush_rating_private.patch_function(
  signature text, old_text text, new_text text, expected_count integer default 1
) returns void language plpgsql set search_path = pg_catalog as $$
declare definition text; occurrence_count integer;
begin
  definition := pg_get_functiondef(signature::regprocedure);
  occurrence_count := (length(definition) - length(replace(definition, old_text, ''))) / length(old_text);
  if occurrence_count <> expected_count then
    raise exception 'Rating reset migration contract changed for % (found %, expected %).',
      signature, occurrence_count, expected_count;
  end if;
  execute replace(definition, old_text, new_text);
end;
$$;

do $migration$
begin
  perform fieldrush_rating_private.patch_function(
    'public.season_player_rating_rankings(text,date,date)',
    $old$      and lower(region_rating.region) = lower(trim(region_to_use))$old$,
    $new$      and lower(region_rating.region) = lower(trim(region_to_use))
      and (region_rating.ratings_reset_at is null
        or season_ends_on < (region_rating.ratings_reset_at at time zone
          (case lower(trim(region_to_use)) when 'phoenix' then 'America/Phoenix' else 'Asia/Bahrain' end))::date
        or (event.effective_at >= region_rating.ratings_reset_at
          and event.applied_sequence > coalesce(region_rating.ratings_reset_sequence, -1)))$new$);
  perform fieldrush_rating_private.patch_function(
    'public.get_my_season_player_rating(text,date,date)',
    $old$    where event.profile_id = user_id
      and (event.effective_at at time zone 'Asia/Bahrain')::date$old$,
    $new$    where event.profile_id = user_id
      and exists (select 1 from public.player_ratings current_rating
        where current_rating.profile_id = user_id
          and (current_rating.ratings_reset_at is null
            or season_ends_on < (current_rating.ratings_reset_at at time zone
              (case lower(trim(region_to_use)) when 'phoenix' then 'America/Phoenix' else 'Asia/Bahrain' end))::date
            or (event.effective_at >= current_rating.ratings_reset_at
              and event.applied_sequence > coalesce(current_rating.ratings_reset_sequence, -1))))
      and (event.effective_at at time zone 'Asia/Bahrain')::date$new$);
  perform fieldrush_rating_private.patch_function(
    'public.get_player_rating_history(uuid,integer)',
    $old$    'last_change', coalesce(rating.last_change, 0),$old$,
    $new$    'last_change', coalesce(rating.last_change, 0),
    'ratings_reset_at', rating.ratings_reset_at,
    'ratings_reset_sequence', rating.ratings_reset_sequence,$new$);

  perform fieldrush_rating_private.patch_function(
    'public.apply_open_queue_player_ratings(uuid)',
    $old$  rating_effective_at := coalesce(rating_effective_at, game_to_apply.starts_at);$old$,
    $new$  rating_effective_at := coalesce(rating_effective_at, game_to_apply.starts_at);
  if not public.player_rating_effective_at_is_current(game_to_apply.starts_at)
    or not public.player_rating_effective_at_is_current(rating_effective_at)
    or not public.player_rating_source_is_current('OPEN_QUEUE', game_id_to_apply) then
    return 0;
  end if;$new$);
  perform fieldrush_rating_private.patch_function(
    'public.apply_clan_fixture_player_ratings()',
    $old$  perform public.snapshot_fixture_player_appearances(new.id);$old$,
    $new$  if not public.player_rating_effective_at_is_current(
    public.fixture_start_at(new.match_date, new.time_slot)
  ) or not public.player_rating_source_is_current('CLAN_FIXTURE', new.id) then return new; end if;
  perform public.snapshot_fixture_player_appearances(new.id);$new$);
  perform fieldrush_rating_private.patch_function(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)',
    $old$  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
  ) then$old$,
    $new$  if public.open_queue_rating_is_in_current_period(game_id_to_apply) and not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
  ) then$new$);
  -- This function also owns verified-injury refunds. Historical matches must
  -- still run its financial path, even though no new-period SR can be applied.
  perform fieldrush_rating_private.patch_function(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)',
    $old$  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
      and event.reliability_policy_version_id is null
  ) then$old$,
    $new$  if public.open_queue_rating_is_in_current_period(game_id_to_apply) and not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
      and event.reliability_policy_version_id is null
  ) then$new$);
  perform fieldrush_rating_private.patch_function(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)',
    $old$      and event.reliability_policy_version_id is null
    order by event.profile_id$old$,
    $new$      and event.reliability_policy_version_id is null
      and public.open_queue_rating_is_in_current_period(game_id_to_apply)
      and public.player_rating_event_is_current(event.effective_at, event.applied_sequence)
    order by event.profile_id$new$);
  perform fieldrush_rating_private.patch_function(
    'public.apply_clan_reliability_rating_adjustments(uuid)',
    $old$  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_apply
  ) then$old$,
    $new$  if not public.player_rating_effective_at_is_current(
    public.fixture_start_at(fixture_to_apply.match_date, fixture_to_apply.time_slot)
  ) or not public.player_rating_source_is_current('CLAN_FIXTURE', fixture_id_to_apply) then return 0; end if;
  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_apply
  ) then$new$);
  perform fieldrush_rating_private.patch_function(
    'public.apply_late_appeal_sr_correction(uuid,uuid,uuid)',
    $old$  if event_to_correct.id is null
    or event_to_correct.attendance_outcome <> 'LATE'$old$,
    $new$  if event_to_correct.id is null
    or not public.player_rating_event_is_current(event_to_correct.effective_at, event_to_correct.applied_sequence)
    or event_to_correct.attendance_outcome <> 'LATE'$new$);
  -- Only the current counters are protected. Historical result/event edits
  -- still execute, so an admin can correct an archived match's official score.
  perform fieldrush_rating_private.patch_function(
    'public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer)',
    $old$  where event.profile_id = rating.profile_id
    and event.source_type = source_type_to_use$old$,
    $new$  where event.profile_id = rating.profile_id
    and (rating.ratings_reset_at is null or (event.effective_at >= rating.ratings_reset_at
      and event.applied_sequence > coalesce(rating.ratings_reset_sequence, -1)))
    and event.source_type = source_type_to_use$new$);
  perform fieldrush_rating_private.patch_function(
    'public.admin_override_match_score(uuid,text,uuid,integer,integer,text)',
    $old$    where event.profile_id = rating.profile_id
      and event.source_type =$old$,
    $new$    where event.profile_id = rating.profile_id
      and (rating.ratings_reset_at is null or (event.effective_at >= rating.ratings_reset_at
        and event.applied_sequence > coalesce(rating.ratings_reset_sequence, -1)))
      and event.source_type =$new$, 2);
end;
$migration$;
drop function fieldrush_rating_private.patch_function(text,text,text,integer);

comment on function public.reset_player_rankings(uuid,text) is
  'Service-only, idempotent new rating period: snapshots previous ratings, resets SR to 1200 and placement to 0/2, preserves history, and rebases only future unstarted lineup SR. Refuses started unfinished matches.';
