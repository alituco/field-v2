-- Match-level reliability effects that require actual play context.
--
-- Attendance/refund decisions live in the preceding reliability migration.
-- This migration adds the referee-authored evidence needed for verified
-- injuries and genuine shorthanded play, applies the snapshotted policy to
-- the shared solo/clan Player SR ledger, and derives clan-level attendance
-- consequences separately
-- from each rostered player's personal outcome.

create table public.match_shorthanded_periods (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.match_reliability_terms(id)
    on delete cascade,
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  side text not null check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  reason text not null check (
    reason in ('LATE_ARRIVAL', 'NO_SHOW', 'INJURY', 'OTHER')
  ),
  caused_by_profile_id uuid references public.profiles(id) on delete set null,
  replacement_profile_id uuid references public.profiles(id) on delete set null,
  started_match_second integer not null check (
    started_match_second between 0 and 10800
  ),
  ended_match_second integer check (
    ended_match_second between 0 and 10800
  ),
  recorded_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  ended_by uuid references public.referee_profiles(profile_id)
    on delete restrict,
  note text check (note is null or char_length(trim(note)) <= 1000),
  created_at timestamptz not null default clock_timestamp(),
  ended_at timestamptz,
  check (
    (match_kind = 'SOLO' and open_queue_game_id is not null and fixture_id is null
      and side in ('WHITE', 'BLACK'))
    or
    (match_kind = 'CLAN' and fixture_id is not null and open_queue_game_id is null
      and side in ('HOME', 'AWAY'))
  ),
  check (
    (ended_match_second is null and ended_at is null and ended_by is null)
    or
    (ended_match_second is not null and ended_at is not null and ended_by is not null)
  ),
  check (
    ended_match_second is null
    or ended_match_second >= started_match_second
  )
);

create unique index match_shorthanded_one_open_side_idx
on public.match_shorthanded_periods (terms_id, side)
where ended_match_second is null;

create index match_shorthanded_match_idx
on public.match_shorthanded_periods (terms_id, started_match_second);

create table public.match_verified_injuries (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.match_reliability_terms(id)
    on delete cascade,
  attendance_id uuid not null references public.match_attendance_records(id)
    on delete restrict,
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  side text not null check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  match_second integer not null check (match_second between 0 and 10800),
  unable_to_continue boolean not null,
  replacement_available boolean not null,
  match_continued boolean not null,
  recorded_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  note text check (note is null or char_length(trim(note)) <= 1000),
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (terms_id, profile_id),
  check (
    (match_kind = 'SOLO' and open_queue_game_id is not null and fixture_id is null
      and side in ('WHITE', 'BLACK'))
    or
    (match_kind = 'CLAN' and fixture_id is not null and open_queue_game_id is null
      and side in ('HOME', 'AWAY'))
  )
);

create index match_verified_injuries_match_idx
on public.match_verified_injuries (terms_id, match_second);

create table public.clan_match_reliability_outcomes (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.match_reliability_terms(id)
    on delete cascade,
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  clan_id uuid not null references public.clans(id) on delete restrict,
  side text not null check (side in ('HOME', 'AWAY')),
  expected_count integer not null check (expected_count >= 0),
  on_time_count integer not null check (on_time_count >= 0),
  kickoff_count integer not null check (kickoff_count >= 0),
  cutoff_count integer not null check (cutoff_count >= 0),
  outcome text not null check (
    outcome in ('READY', 'PARTIAL_LATE', 'FORFEIT', 'ENTIRE_CLAN_NO_SHOW')
  ),
  strike_delta integer not null check (strike_delta between 0 and 20),
  official_forfeit boolean not null default false,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  finalized_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  finalized_at timestamptz not null default clock_timestamp(),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  unique (fixture_id, clan_id),
  check (
    on_time_count <= kickoff_count
    and kickoff_count <= cutoff_count
    and cutoff_count <= expected_count
  ),
  check (
    official_forfeit = (outcome in ('FORFEIT', 'ENTIRE_CLAN_NO_SHOW'))
  )
);

create table public.fixture_reliability_roster_history (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  clan_id uuid not null references public.clans(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'CONFIRMED' check (
    status in ('CONFIRMED', 'REMOVED', 'REPLACED')
  ),
  confirmed_by uuid references public.profiles(id) on delete set null,
  confirmed_at timestamptz not null default clock_timestamp(),
  ended_by uuid references public.profiles(id) on delete set null,
  ended_at timestamptz,
  replacement_entry_id uuid references public.fixture_reliability_roster_history(id)
    on delete set null,
  note text check (note is null or char_length(trim(note)) <= 500),
  check (
    (status = 'CONFIRMED' and ended_at is null)
    or (status in ('REMOVED', 'REPLACED') and ended_at is not null)
  )
);

create unique index fixture_reliability_roster_active_profile_idx
on public.fixture_reliability_roster_history (fixture_id, profile_id)
where status = 'CONFIRMED';

create index fixture_reliability_roster_fixture_idx
on public.fixture_reliability_roster_history (
  fixture_id,
  clan_id,
  confirmed_at,
  id
);

create or replace function public.validate_reliability_match_effect_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'match_shorthanded_periods' then
    if not exists (
      select 1
      from public.match_reliability_terms terms
      where terms.id = new.terms_id
        and terms.match_kind = new.match_kind
        and terms.fixture_id is not distinct from new.fixture_id
        and terms.open_queue_game_id is not distinct from new.open_queue_game_id
    ) then
      raise exception 'Shorthanded evidence does not match its reliability terms.';
    end if;
  elsif tg_table_name = 'match_verified_injuries' then
    if not exists (
      select 1
      from public.match_reliability_terms terms
      join public.match_attendance_records attendance
        on attendance.id = new.attendance_id
        and attendance.terms_id = terms.id
      where terms.id = new.terms_id
        and terms.match_kind = new.match_kind
        and terms.fixture_id is not distinct from new.fixture_id
        and terms.open_queue_game_id is not distinct from new.open_queue_game_id
        and terms.policy_version_id = new.policy_version_id
        and attendance.profile_id = new.profile_id
        and attendance.side = new.side
        and attendance.expected_for_match
        and attendance.checked_in_at is not null
    ) then
      raise exception 'Verified injury evidence does not match a checked-in expected player.';
    end if;
  elsif tg_table_name = 'clan_match_reliability_outcomes' then
    if not exists (
      select 1
      from public.match_reliability_terms terms
      join public.fixtures fixture on fixture.id = new.fixture_id
      where terms.id = new.terms_id
        and terms.match_kind = 'CLAN'
        and terms.fixture_id = new.fixture_id
        and terms.policy_version_id = new.policy_version_id
        and (
          (new.side = 'HOME' and new.clan_id = fixture.home_clan_id)
          or (new.side = 'AWAY' and new.clan_id = fixture.away_clan_id)
        )
    ) then
      raise exception 'Clan attendance outcome does not match its policy-bound fixture.';
    end if;
  elsif tg_table_name = 'fixture_reliability_roster_history' then
    if not exists (
      select 1
      from public.fixtures fixture
      where fixture.id = new.fixture_id
        and new.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
    ) then
      raise exception 'Reliability roster clan is not part of this fixture.';
    end if;
    if not exists (
      select 1
      from public.clan_members member
      where member.clan_id = new.clan_id
        and member.profile_id = new.profile_id
        and member.left_at is null
      union all
      select 1
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = new.fixture_id
        and appearance.clan_id = new.clan_id
        and appearance.profile_id = new.profile_id
        and appearance.played
    ) then
      raise exception 'Reliability roster player is not eligible for this clan fixture.';
    end if;
  end if;
  return new;
end;
$$;

create trigger validate_match_shorthanded_period
before insert on public.match_shorthanded_periods
for each row execute function public.validate_reliability_match_effect_row();

create trigger validate_match_verified_injury
before insert on public.match_verified_injuries
for each row execute function public.validate_reliability_match_effect_row();

create trigger validate_clan_match_reliability_outcome
before insert on public.clan_match_reliability_outcomes
for each row execute function public.validate_reliability_match_effect_row();

create trigger validate_fixture_reliability_roster_entry
before insert on public.fixture_reliability_roster_history
for each row execute function public.validate_reliability_match_effect_row();

alter table public.match_attendance_records
add column if not exists expected_for_match boolean not null default true;

alter table public.reliability_incidents
add column if not exists fixture_id uuid references public.fixtures(id)
  on delete restrict;

create unique index reliability_incident_clan_fixture_idx
on public.reliability_incidents (fixture_id, clan_id)
where subject_type = 'CLAN' and reversal_of is null and fixture_id is not null;

alter table public.player_rating_events
add column if not exists reliability_policy_version_id uuid
  references public.reliability_policy_versions(id) on delete restrict,
add column if not exists attendance_outcome text,
add column if not exists reliability_multiplier_bps integer,
add column if not exists sr_protection_applied boolean not null default false,
add column if not exists sr_protection_reason text;

alter table public.player_rating_events
drop constraint if exists player_rating_events_reliability_multiplier_check;
alter table public.player_rating_events
add constraint player_rating_events_reliability_multiplier_check check (
  reliability_multiplier_bps is null
  or reliability_multiplier_bps between 0 and 30000
);

alter table public.player_rating_events
drop constraint if exists player_rating_events_attendance_outcome_check;
alter table public.player_rating_events
add constraint player_rating_events_attendance_outcome_check check (
  attendance_outcome is null
  or attendance_outcome in ('ON_TIME', 'LATE')
);

alter table public.player_rating_events
drop constraint if exists player_rating_events_sr_protection_reason_check;
alter table public.player_rating_events
add constraint player_rating_events_sr_protection_reason_check check (
  (
    not sr_protection_applied
    and sr_protection_reason is null
  )
  or (
    sr_protection_applied
    and sr_protection_reason in (
      'VERIFIED_INJURY',
      'SHORTHANDED_OPPONENT',
      'SHORTHANDED_TEAM',
      'SHORTHANDED_TEAM_WIN'
    )
  )
);

alter table public.match_shorthanded_periods enable row level security;
alter table public.match_verified_injuries enable row level security;
alter table public.clan_match_reliability_outcomes enable row level security;
alter table public.fixture_reliability_roster_history enable row level security;

revoke all on table public.match_shorthanded_periods
from public, anon, authenticated;
revoke all on table public.match_verified_injuries
from public, anon, authenticated;
revoke all on table public.clan_match_reliability_outcomes
from public, anon, authenticated;
revoke all on table public.fixture_reliability_roster_history
from public, anon, authenticated;

grant all on table public.match_shorthanded_periods to service_role;
grant all on table public.match_verified_injuries to service_role;
grant all on table public.clan_match_reliability_outcomes to service_role;
grant all on table public.fixture_reliability_roster_history to service_role;

create or replace function public.reliability_fixture_forfeit_score(
  fixture_id_to_use uuid
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (
      select (terms.policy_snapshot #>> '{clan,forfeitScore}')::integer
      from public.match_reliability_terms terms
      where terms.match_kind = 'CLAN'
        and terms.fixture_id = fixture_id_to_use
    ),
    (
      select (policy.config #>> '{clan,forfeitScore}')::integer
      from public.fixtures fixture
      join public.reliability_policy_versions policy
        on policy.state = 'PUBLISHED'
        and policy.effective_from <= public.fixture_start_at(
          fixture.match_date,
          fixture.time_slot
        )
      where fixture.id = fixture_id_to_use
      order by policy.effective_from desc, policy.version desc
      limit 1
    ),
    3
  );
$$;

do $migration$
declare
  constraint_to_drop record;
  function_definition text;
  old_home text := $old$
  provisional_home := case
    when awarded_clan_id_to_use = fixture_before.home_clan_id then 3 else 0
  end;
$old$;
  new_home text := $new$
  provisional_home := case
    when awarded_clan_id_to_use = fixture_before.home_clan_id
      then public.reliability_fixture_forfeit_score(fixture_before.id)
    else 0
  end;
$new$;
  old_away text := $old$
  provisional_away := case
    when awarded_clan_id_to_use = fixture_before.away_clan_id then 3 else 0
  end;
$old$;
  new_away text := $new$
  provisional_away := case
    when awarded_clan_id_to_use = fixture_before.away_clan_id
      then public.reliability_fixture_forfeit_score(fixture_before.id)
    else 0
  end;
$new$;
begin
  for constraint_to_drop in
    select constraint_row.conname
    from pg_constraint constraint_row
    join pg_class table_row on table_row.oid = constraint_row.conrelid
    join pg_namespace namespace_row on namespace_row.oid = table_row.relnamespace
    where namespace_row.nspname = 'public'
      and table_row.relname = 'match_forfeit_decisions'
      and constraint_row.contype = 'c'
      and pg_get_constraintdef(constraint_row.oid) like '%provisional_home_score = 3%'
  loop
    execute format(
      'alter table public.match_forfeit_decisions drop constraint %I',
      constraint_to_drop.conname
    );
  end loop;

  if not exists (
    select 1 from pg_constraint
    where conname = 'match_forfeit_decisions_configured_score_check'
      and conrelid = 'public.match_forfeit_decisions'::regclass
  ) then
    alter table public.match_forfeit_decisions
    add constraint match_forfeit_decisions_configured_score_check check (
      -- forfeitScore is admin-configurable from 0 through 99. A zero-score
      -- policy therefore produces 0-0 while the awarded clan remains explicit
      -- in awarded_clan_id; every positive configured score still has one zero
      -- side.
      provisional_home_score = 0 or provisional_away_score = 0
    );
  end if;

  select pg_get_functiondef(
    'public.referee_report_clan_forfeit(uuid,uuid,uuid,text,text,text,text,integer)'::regprocedure
  ) into function_definition;
  if position('reliability_fixture_forfeit_score' in function_definition) = 0 then
    if position(old_home in function_definition) = 0
      or position(old_away in function_definition) = 0
    then
      raise exception 'Could not make clan forfeit scoring policy-driven.';
    end if;
    function_definition := replace(function_definition, old_home, new_home);
    function_definition := replace(function_definition, old_away, new_away);
    function_definition := replace(
      function_definition,
      'provisional 3-0 forfeit',
      'provisional configured-score forfeit'
    );
    function_definition := replace(
      function_definition,
      '3-0 forfeit result',
      'configured forfeit result'
    );
    execute function_definition;
  end if;
end;
$migration$;

-- A policy-awarded clan forfeit may become FINAL without any football being
-- played. Keep that official result in the clan ledger, but never manufacture
-- Player SR appearances from it. The cancellation workflow writes this flag
-- in the same UPDATE that transitions the fixture to FINAL.
create or replace function public.enforce_clan_reliability_final_cutoff()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  kickoff_at_to_use timestamptz;
begin
  if new.status <> 'FINAL'
    or old.status = 'FINAL'
    or new.away_clan_id is null
  then
    return new;
  end if;

  -- A server-authored cancellation forfeit deliberately has no attendance or
  -- Player-SR result. Its workflow resolves the expected roster before this
  -- transition and marks the same row update with this immutable audit flag.
  if coalesce(
    (new.cancellation_context ->>
      'reliability_forfeit_without_play')::boolean,
    false
  ) then
    return new;
  end if;

  kickoff_at_to_use := public.fixture_start_at(new.match_date, new.time_slot);
  if not exists (
    select 1
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from <= kickoff_at_to_use
  ) then
    return new;
  end if;

  terms_to_use := public.ensure_match_reliability_terms('CLAN', new.id);
  if clock_timestamp() < terms_to_use.no_show_cutoff_at then
    raise exception
      'This clan match cannot be finalized before its attendance cutoff at %.',
      terms_to_use.no_show_cutoff_at;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_clan_reliability_final_cutoff
on public.fixtures;
create trigger enforce_clan_reliability_final_cutoff
before update of status on public.fixtures
for each row execute function public.enforce_clan_reliability_final_cutoff();

do $migration$
declare
  function_definition text;
  old_text text := $old$  if new.home_score is null or new.away_score is null then
    return new;
  end if;

  perform public.snapshot_fixture_player_appearances(new.id);$old$;
  new_text text := $new$  if new.home_score is null or new.away_score is null then
    return new;
  end if;

  if coalesce(
    (new.cancellation_context ->> 'reliability_forfeit_without_play')::boolean,
    false
  ) then
    return new;
  end if;

  perform public.snapshot_fixture_player_appearances(new.id);$new$;
begin
  select pg_get_functiondef(
    'public.apply_clan_fixture_player_ratings()'::regprocedure
  ) into function_definition;
  if position('reliability_forfeit_without_play' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not protect Player SR from an unplayed clan forfeit.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

create or replace function public.reliability_match_elapsed_seconds(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  clock_status text;
  clock_started_at timestamptz;
  accumulated_to_use integer;
begin
  if normalized_kind = 'SOLO' then
    select clock.status, clock.started_at, clock.accumulated_seconds
    into clock_status, clock_started_at, accumulated_to_use
    from public.open_queue_clock_states clock
    where clock.game_id = match_id_to_use;
  elsif normalized_kind = 'CLAN' then
    select clock.status, clock.started_at, clock.accumulated_seconds
    into clock_status, clock_started_at, accumulated_to_use
    from public.fixture_clock_states clock
    where clock.fixture_id = match_id_to_use;
  else
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;

  return least(
    10800,
    greatest(
      0,
      coalesce(accumulated_to_use, 0) + case
        when clock_status = 'RUNNING' and clock_started_at is not null then
          floor(extract(epoch from (clock_timestamp() - clock_started_at)))::integer
        else 0
      end
    )
  );
end;
$$;

create or replace function public.referee_start_shorthanded_period(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  side_to_use text,
  reason_to_use text,
  caused_by_profile_id_to_use uuid default null,
  note_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_side text := upper(trim(coalesce(side_to_use, '')));
  normalized_reason text := upper(trim(coalesce(reason_to_use, '')));
  normalized_note text := nullif(trim(coalesce(note_to_use, '')), '');
  terms_to_use public.match_reliability_terms%rowtype;
  started_second integer;
  period_id_to_use uuid;
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'This match is not assigned to you.';
  end if;
  if not (
    (normalized_kind = 'SOLO' and exists (
      select 1 from public.open_queue_games game
      where game.id = match_id_to_use and game.status = 'LIVE'
    ))
    or (normalized_kind = 'CLAN' and exists (
      select 1 from public.fixtures fixture
      where fixture.id = match_id_to_use and fixture.status = 'LIVE'
    ))
  ) then
    raise exception 'Shorthanded play can only be recorded during a live match.';
  end if;
  if normalized_reason not in ('LATE_ARRIVAL', 'NO_SHOW', 'INJURY', 'OTHER') then
    raise exception 'Choose a supported shorthanded reason.';
  end if;
  if char_length(coalesce(normalized_note, '')) > 1000 then
    raise exception 'Keep the match note under 1,000 characters.';
  end if;
  if (normalized_kind = 'SOLO' and normalized_side not in ('WHITE', 'BLACK'))
    or (normalized_kind = 'CLAN' and normalized_side not in ('HOME', 'AWAY'))
  then
    raise exception 'Choose a team from this match.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );
  if terms_to_use.policy_version_id is distinct from
    public.resolve_reliability_policy_id(terms_to_use.kickoff_at)
  then
    raise exception 'Reliability match effects are not active for this kickoff.';
  end if;
  if clock_timestamp() < terms_to_use.kickoff_at then
    raise exception 'Shorthanded play can only be recorded from kickoff.';
  end if;
  if caused_by_profile_id_to_use is not null and not exists (
    select 1
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.profile_id = caused_by_profile_id_to_use
      and attendance.side = normalized_side
      and attendance.expected_for_match
  ) then
    raise exception 'That player is not on this team.';
  end if;

  started_second := public.reliability_match_elapsed_seconds(
    normalized_kind,
    match_id_to_use
  );

  select period.id into period_id_to_use
  from public.match_shorthanded_periods period
  where period.terms_id = terms_to_use.id
    and period.side = normalized_side
    and period.ended_match_second is null;
  if period_id_to_use is not null then
    return period_id_to_use;
  end if;

  insert into public.match_shorthanded_periods (
    terms_id,
    match_kind,
    fixture_id,
    open_queue_game_id,
    side,
    reason,
    caused_by_profile_id,
    started_match_second,
    recorded_by,
    note
  ) values (
    terms_to_use.id,
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    normalized_side,
    normalized_reason,
    caused_by_profile_id_to_use,
    started_second,
    actor_referee_id,
    normalized_note
  ) returning id into period_id_to_use;

  return period_id_to_use;
end;
$$;

create or replace function public.referee_end_shorthanded_period(
  actor_referee_id uuid,
  period_id_to_end uuid,
  replacement_profile_id_to_use uuid default null,
  note_to_use text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  period_to_end public.match_shorthanded_periods%rowtype;
  match_id_to_use uuid;
  ended_second integer;
  normalized_note text := nullif(trim(coalesce(note_to_use, '')), '');
begin
  select * into period_to_end
  from public.match_shorthanded_periods period
  where period.id = period_id_to_end
  for update;
  if period_to_end.id is null then
    raise exception 'Shorthanded period not found.';
  end if;

  match_id_to_use := coalesce(
    period_to_end.open_queue_game_id,
    period_to_end.fixture_id
  );
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    period_to_end.match_kind,
    match_id_to_use
  ) then
    raise exception 'This match is not assigned to you.';
  end if;
  if char_length(coalesce(normalized_note, '')) > 1000 then
    raise exception 'Keep the match note under 1,000 characters.';
  end if;
  if period_to_end.ended_match_second is not null then
    return jsonb_build_object(
      'period_id', period_to_end.id,
      'started_match_second', period_to_end.started_match_second,
      'ended_match_second', period_to_end.ended_match_second,
      'idempotent', true
    );
  end if;

  if replacement_profile_id_to_use is not null and not exists (
    select 1
    from public.match_attendance_records attendance
    where attendance.terms_id = period_to_end.terms_id
      and attendance.profile_id = replacement_profile_id_to_use
      and attendance.side = period_to_end.side
      and attendance.checked_in_at is not null
  ) then
    raise exception 'The replacement must be a checked-in player on this team.';
  end if;

  ended_second := greatest(
    period_to_end.started_match_second,
    public.reliability_match_elapsed_seconds(
      period_to_end.match_kind,
      match_id_to_use
    )
  );

  update public.match_shorthanded_periods
  set
    ended_match_second = ended_second,
    replacement_profile_id = replacement_profile_id_to_use,
    ended_by = actor_referee_id,
    ended_at = clock_timestamp(),
    note = case
      when normalized_note is null then note
      when note is null then normalized_note
      else note || E'\n' || normalized_note
    end
  where id = period_to_end.id
  returning * into period_to_end;

  return jsonb_build_object(
    'period_id', period_to_end.id,
    'started_match_second', period_to_end.started_match_second,
    'ended_match_second', period_to_end.ended_match_second,
    'replacement_profile_id', period_to_end.replacement_profile_id,
    'idempotent', false
  );
end;
$$;

create or replace function public.referee_record_verified_injury(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  injured_profile_id_to_use uuid,
  unable_to_continue_to_use boolean,
  replacement_available_to_use boolean,
  match_continued_to_use boolean,
  note_to_use text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_note text := nullif(trim(coalesce(note_to_use, '')), '');
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_use public.match_attendance_records%rowtype;
  injury_to_use public.match_verified_injuries%rowtype;
  injury_second integer;
  shorthanded_period_id uuid;
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'This match is not assigned to you.';
  end if;
  if not (
    (normalized_kind = 'SOLO' and exists (
      select 1 from public.open_queue_games game
      where game.id = match_id_to_use and game.status = 'LIVE'
    ))
    or (normalized_kind = 'CLAN' and exists (
      select 1 from public.fixtures fixture
      where fixture.id = match_id_to_use and fixture.status = 'LIVE'
    ))
  ) then
    raise exception 'Injuries can only be recorded during a live match.';
  end if;
  if char_length(coalesce(normalized_note, '')) > 1000 then
    raise exception 'Keep the injury note under 1,000 characters.';
  end if;
  if unable_to_continue_to_use and not match_continued_to_use
    and replacement_available_to_use
  then
    raise exception 'Choose whether the available replacement allowed play to continue.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );
  if terms_to_use.policy_version_id is distinct from
    public.resolve_reliability_policy_id(terms_to_use.kickoff_at)
  then
    raise exception 'Reliability match effects are not active for this kickoff.';
  end if;
  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);

  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
    and attendance.profile_id = injured_profile_id_to_use
    and attendance.expected_for_match
  for update;
  if attendance_to_use.id is null then
    raise exception 'The injured player is not on this match roster.';
  end if;
  if attendance_to_use.checked_in_at is null then
    raise exception 'Check the player in before recording an in-match injury.';
  end if;

  select * into injury_to_use
  from public.match_verified_injuries injury
  where injury.terms_id = terms_to_use.id
    and injury.profile_id = injured_profile_id_to_use;
  if injury_to_use.id is not null then
    return jsonb_build_object(
      'injury_id', injury_to_use.id,
      'profile_id', injury_to_use.profile_id,
      'match_second', injury_to_use.match_second,
      'shorthanded_period_id', null,
      'idempotent', true
    );
  end if;

  injury_second := public.reliability_match_elapsed_seconds(
    normalized_kind,
    match_id_to_use
  );

  insert into public.match_verified_injuries (
    terms_id,
    attendance_id,
    match_kind,
    fixture_id,
    open_queue_game_id,
    profile_id,
    side,
    match_second,
    unable_to_continue,
    replacement_available,
    match_continued,
    recorded_by,
    note,
    policy_version_id
  ) values (
    terms_to_use.id,
    attendance_to_use.id,
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    attendance_to_use.profile_id,
    attendance_to_use.side,
    injury_second,
    unable_to_continue_to_use,
    replacement_available_to_use,
    match_continued_to_use,
    actor_referee_id,
    normalized_note,
    terms_to_use.policy_version_id
  ) returning * into injury_to_use;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    actor_referee_id,
    event_at,
    detail,
    idempotency_key
  ) values (
    attendance_to_use.id,
    'INJURY_RECORDED',
    actor_referee_id,
    clock_timestamp(),
    jsonb_build_object(
      'injury_id', injury_to_use.id,
      'match_second', injury_second,
      'unable_to_continue', unable_to_continue_to_use,
      'replacement_available', replacement_available_to_use,
      'match_continued', match_continued_to_use,
      'strike_delta', 0
    ),
    'verified-injury:' || injury_to_use.id::text
  );

  if unable_to_continue_to_use and not replacement_available_to_use
    and match_continued_to_use
  then
    shorthanded_period_id := public.referee_start_shorthanded_period(
      actor_referee_id,
      normalized_kind,
      match_id_to_use,
      attendance_to_use.side,
      'INJURY',
      attendance_to_use.profile_id,
      normalized_note
    );
  end if;

  return jsonb_build_object(
    'injury_id', injury_to_use.id,
    'profile_id', injury_to_use.profile_id,
    'match_second', injury_to_use.match_second,
    'shorthanded_period_id', shorthanded_period_id,
    'strike_delta', 0,
    'idempotent', false
  );
end;
$$;

create or replace function public.sync_fixture_reliability_expected_roster(
  fixture_id_to_sync uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_id_to_use uuid;
  updated_count integer;
begin
  select terms.id into terms_id_to_use
  from public.match_reliability_terms terms
  where terms.match_kind = 'CLAN'
    and terms.fixture_id = fixture_id_to_sync;
  if terms_id_to_use is null then
    return 0;
  end if;

  update public.match_attendance_records attendance
  set expected_for_match = exists (
    select 1
    from public.fixture_reliability_roster_history roster
    where roster.fixture_id = fixture_id_to_sync
      and roster.profile_id = attendance.profile_id
      and roster.status = 'CONFIRMED'
  )
  where attendance.terms_id = terms_id_to_use
    and attendance.match_kind = 'CLAN';
  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

create or replace function public.initialize_fixture_reliability_roster(
  fixture_id_to_initialize uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  side_clan_id uuid;
  side_name text;
  required_count integer;
  inserted_count integer := 0;
  active_count integer;
  history_count integer;
begin
  select * into fixture_to_use
  from public.fixtures fixture
  where fixture.id = fixture_id_to_initialize
  for update;
  if fixture_to_use.id is null or fixture_to_use.away_clan_id is null then
    return 0;
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_id_to_initialize
  );
  perform public.ensure_match_attendance_records(
    'CLAN',
    fixture_id_to_initialize
  );
  required_count := (terms_to_use.policy_snapshot #>>
    '{clan,playersPerSide}')::integer;

  foreach side_clan_id in array array[
    fixture_to_use.home_clan_id,
    fixture_to_use.away_clan_id
  ]
  loop
    side_name := case
      when side_clan_id = fixture_to_use.home_clan_id then 'HOME'
      else 'AWAY'
    end;
    select count(*)::integer into active_count
    from public.fixture_reliability_roster_history roster
    where roster.fixture_id = fixture_id_to_initialize
      and roster.clan_id = side_clan_id
      and roster.status = 'CONFIRMED';

    select count(*)::integer into history_count
    from public.fixture_reliability_roster_history roster
    where roster.fixture_id = fixture_id_to_initialize
      and roster.clan_id = side_clan_id;

    -- Fill a never-edited initial snapshot, including a clan that initially
    -- has fewer than the policy side size. Once any roster entry is removed,
    -- leave the vacancy for a captain to confirm instead of silently choosing
    -- a replacement.
    if active_count < required_count and history_count = active_count then
      insert into public.fixture_reliability_roster_history (
        fixture_id,
        clan_id,
        profile_id,
        confirmed_by,
        note
      )
      select
        fixture_id_to_initialize,
        side_clan_id,
        candidate.profile_id,
        fixture_to_use.created_by,
        'Initial expected roster snapshot'
      from (
        select distinct on (source.profile_id)
          source.profile_id,
          source.priority,
          source.member_order
        from (
          select
            appearance.profile_id,
            0 as priority,
            appearance.profile_id::text as member_order
          from public.fixture_player_appearances appearance
          where appearance.fixture_id = fixture_id_to_initialize
            and appearance.clan_id = side_clan_id
            and appearance.played
          union all
          select
            member.profile_id,
            1 as priority,
            lpad(case member.role
              when 'owner' then '0'
              when 'leader' then '1'
              else '2'
            end, 2, '0') || ':' || member.created_at::text || ':' || member.profile_id::text
          from public.clan_members member
          where member.clan_id = side_clan_id
            and member.left_at is null
        ) source
        order by source.profile_id, source.priority, source.member_order
      ) candidate
      where not exists (
        select 1
        from public.fixture_reliability_roster_history existing_roster
        where existing_roster.fixture_id = fixture_id_to_initialize
          and existing_roster.profile_id = candidate.profile_id
      )
        and not public.profile_has_active_play_restriction(candidate.profile_id)
      order by candidate.priority, candidate.member_order, candidate.profile_id
      limit required_count - active_count;
      get diagnostics active_count = row_count;
      inserted_count := inserted_count + active_count;
    end if;

    if (
      select count(*)
      from public.fixture_reliability_roster_history roster
      where roster.fixture_id = fixture_id_to_initialize
        and roster.clan_id = side_clan_id
        and roster.status = 'CONFIRMED'
    ) > required_count then
      raise exception '% reliability roster exceeds the policy side size.',
        side_name;
    end if;
  end loop;

  perform public.sync_fixture_reliability_expected_roster(
    fixture_id_to_initialize
  );
  return inserted_count;
end;
$$;

create or replace function public.set_fixture_reliability_roster(
  fixture_id_to_manage uuid,
  clan_id_to_manage uuid,
  profile_ids_to_confirm uuid[],
  note_to_use text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  required_count integer;
  distinct_count integer;
  saved_profile_id uuid;
  new_entry_id uuid;
  normalized_note text := nullif(trim(coalesce(note_to_use, '')), '');
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if not exists (
    select 1
    from public.clan_members manager
    where manager.clan_id = clan_id_to_manage
      and manager.profile_id = user_id
      and manager.role in ('owner', 'leader')
      and manager.left_at is null
  ) then
    raise exception 'Only a clan owner or leader can confirm this roster.';
  end if;
  if char_length(coalesce(normalized_note, '')) > 500 then
    raise exception 'Keep the roster note under 500 characters.';
  end if;

  select * into fixture_to_use
  from public.fixtures fixture
  where fixture.id = fixture_id_to_manage
  for update;
  if fixture_to_use.id is null
    or clan_id_to_manage not in (
      fixture_to_use.home_clan_id,
      fixture_to_use.away_clan_id
    )
  then
    raise exception 'This clan is not part of that fixture.';
  end if;
  if fixture_to_use.status not in ('OPEN', 'SCHEDULED') then
    raise exception 'The expected roster is locked once the match starts.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_id_to_manage
  );
  if clock_timestamp() >= terms_to_use.check_in_deadline_at then
    raise exception 'The expected roster locks at the hard check-in deadline.';
  end if;
  required_count := (terms_to_use.policy_snapshot #>>
    '{clan,playersPerSide}')::integer;

  select count(distinct profile_id)::integer into distinct_count
  from unnest(profile_ids_to_confirm) selected(profile_id)
  where profile_id is not null;
  if coalesce(cardinality(profile_ids_to_confirm), 0) <> required_count
    or distinct_count <> required_count
  then
    raise exception 'Confirm exactly % different players.', required_count;
  end if;
  if exists (
    select 1
    from unnest(profile_ids_to_confirm) selected(profile_id)
    where not exists (
      select 1
      from public.clan_members member
      where member.clan_id = clan_id_to_manage
        and member.profile_id = selected.profile_id
        and member.left_at is null
    )
  ) then
    raise exception 'Every confirmed player must be an active clan member.';
  end if;
  if exists (
    select 1
    from unnest(profile_ids_to_confirm) selected(profile_id)
    where public.profile_has_active_play_restriction(selected.profile_id)
  ) then
    raise exception 'A suspended player cannot be added to a future fixture roster.';
  end if;

  perform public.ensure_match_attendance_records('CLAN', fixture_id_to_manage);

  update public.fixture_reliability_roster_history roster
  set
    status = 'REMOVED',
    ended_by = user_id,
    ended_at = clock_timestamp(),
    note = concat_ws(
      E'\n',
      roster.note,
      coalesce(normalized_note, 'Removed from expected roster')
    )
  where roster.fixture_id = fixture_id_to_manage
    and roster.clan_id = clan_id_to_manage
    and roster.status = 'CONFIRMED'
    and not (roster.profile_id = any(profile_ids_to_confirm));

  foreach saved_profile_id in array profile_ids_to_confirm
  loop
    if not exists (
      select 1
      from public.fixture_reliability_roster_history roster
      where roster.fixture_id = fixture_id_to_manage
        and roster.profile_id = saved_profile_id
        and roster.status = 'CONFIRMED'
    ) then
      insert into public.fixture_reliability_roster_history (
        fixture_id,
        clan_id,
        profile_id,
        confirmed_by,
        note
      ) values (
        fixture_id_to_manage,
        clan_id_to_manage,
        saved_profile_id,
        user_id,
        normalized_note
      ) returning id into new_entry_id;

      update public.fixture_reliability_roster_history previous
      set
        status = 'REPLACED',
        replacement_entry_id = new_entry_id
      where previous.id = (
        select old.id
        from public.fixture_reliability_roster_history old
        where old.fixture_id = fixture_id_to_manage
          and old.clan_id = clan_id_to_manage
          and old.status = 'REMOVED'
          and old.replacement_entry_id is null
        order by old.ended_at desc, old.id
        limit 1
      );
    end if;
  end loop;

  perform public.sync_fixture_reliability_expected_roster(
    fixture_id_to_manage
  );

  return jsonb_build_object(
    'fixture_id', fixture_id_to_manage,
    'clan_id', clan_id_to_manage,
    'confirmed_count', required_count,
    'locks_at', terms_to_use.check_in_deadline_at,
    'policy_version_id', terms_to_use.policy_version_id
  );
end;
$$;

create or replace function public.protect_fixture_reliability_roster_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Fixture reliability roster history cannot be deleted.';
  end if;

  if new.id is distinct from old.id
    or new.fixture_id is distinct from old.fixture_id
    or new.clan_id is distinct from old.clan_id
    or new.profile_id is distinct from old.profile_id
    or new.confirmed_by is distinct from old.confirmed_by
    or new.confirmed_at is distinct from old.confirmed_at
  then
    raise exception 'Confirmed fixture roster facts cannot be rewritten.';
  end if;

  if old.status = 'CONFIRMED' then
    if new.status <> 'REMOVED'
      or new.ended_at is null
      or new.replacement_entry_id is not null
      or (
        new.ended_by is null
        and position('[SYSTEM] Reliability suspension' in coalesce(new.note, '')) = 0
      )
    then
      raise exception 'A confirmed roster entry can only be closed as removed.';
    end if;
  elsif old.status = 'REMOVED' then
    if new.status <> 'REPLACED'
      or new.replacement_entry_id is null
      or new.ended_by is distinct from old.ended_by
      or new.ended_at is distinct from old.ended_at
      or new.note is distinct from old.note
    then
      raise exception 'A removed roster entry can only be linked to its replacement.';
    end if;
    if not exists (
      select 1
      from public.fixture_reliability_roster_history replacement
      where replacement.id = new.replacement_entry_id
        and replacement.fixture_id = new.fixture_id
        and replacement.clan_id = new.clan_id
        and replacement.status = 'CONFIRMED'
    ) then
      raise exception 'The replacement entry must be active for this clan and fixture.';
    end if;
  else
    raise exception 'Closed fixture roster history is immutable.';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_fixture_reliability_roster_history
on public.fixture_reliability_roster_history;
create trigger protect_fixture_reliability_roster_history
before update or delete on public.fixture_reliability_roster_history
for each row execute function public.protect_fixture_reliability_roster_history();

-- Capture a default expected roster while the fixture is still well ahead of
-- kickoff. Captains can replace that exact policy-sized snapshot until the
-- hard check-in deadline, and every replacement remains in the history above.
create or replace function public.initialize_scheduled_fixture_reliability_roster()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.away_clan_id is not null
    and new.status in ('OPEN', 'SCHEDULED')
    and public.fixture_start_at(new.match_date, new.time_slot)
      > clock_timestamp()
  then
    perform public.initialize_fixture_reliability_roster(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists initialize_scheduled_fixture_reliability_roster
on public.fixtures;
create trigger initialize_scheduled_fixture_reliability_roster
after insert or update of
  home_clan_id,
  away_clan_id,
  match_date,
  time_slot,
  status
on public.fixtures
for each row execute function public.initialize_scheduled_fixture_reliability_roster();

create or replace function public.protect_fixture_teams_after_roster_snapshot()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.home_clan_id is distinct from old.home_clan_id
    or new.away_clan_id is distinct from old.away_clan_id
  ) and exists (
    select 1
    from public.fixture_reliability_roster_history roster
    where roster.fixture_id = old.id
  ) then
    raise exception 'Fixture clans are locked after the reliability roster is snapshotted. Cancel and create a new fixture instead.';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_fixture_teams_after_roster_snapshot
on public.fixtures;
create trigger protect_fixture_teams_after_roster_snapshot
before update of home_clan_id, away_clan_id on public.fixtures
for each row execute function public.protect_fixture_teams_after_roster_snapshot();

do $$
declare
  fixture_id_to_initialize uuid;
begin
  for fixture_id_to_initialize in
    select fixture.id
    from public.fixtures fixture
    where fixture.away_clan_id is not null
      and fixture.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(fixture.match_date, fixture.time_slot)
        > clock_timestamp()
    order by fixture.match_date, fixture.time_slot, fixture.id
  loop
    perform public.initialize_fixture_reliability_roster(
      fixture_id_to_initialize
    );
  end loop;
end;
$$;

create or replace function public.release_suspended_player_future_clan_rosters(
  profile_id_to_release uuid,
  sanction_id_to_use uuid,
  release_at_to_use timestamptz default clock_timestamp()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  roster_to_release record;
  released_count integer := 0;
begin
  if not exists (
    select 1
    from public.reliability_sanctions sanction
    where sanction.id = sanction_id_to_use
      and sanction.subject_type = 'PLAYER'
      and sanction.profile_id = profile_id_to_release
      and sanction.sanction_kind in (
        'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
      )
      and sanction.release_future_bookings
      and sanction.revoked_at is null
      and sanction.starts_at <= clock_timestamp()
  ) then
    return 0;
  end if;

  for roster_to_release in
    select
      roster.id,
      roster.fixture_id,
      roster.clan_id,
      roster.note,
      terms.policy_version_id,
      terms.check_in_deadline_at
    from public.fixture_reliability_roster_history roster
    join public.fixtures fixture on fixture.id = roster.fixture_id
    join public.match_reliability_terms terms
      on terms.fixture_id = fixture.id
      and terms.match_kind = 'CLAN'
    where roster.profile_id = profile_id_to_release
      and roster.status = 'CONFIRMED'
      and fixture.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(fixture.match_date, fixture.time_slot)
        > release_at_to_use
      and terms.check_in_deadline_at > clock_timestamp()
      and terms.check_in_deadline_at > release_at_to_use
    order by terms.kickoff_at, roster.fixture_id, roster.id
    for update of roster
  loop
    update public.fixture_reliability_roster_history roster
    set
      status = 'REMOVED',
      ended_by = null,
      ended_at = clock_timestamp(),
      note = concat_ws(
        E'\n',
        roster.note,
        '[SYSTEM] Reliability suspension released this future roster place. Sanction ' ||
          sanction_id_to_use::text
      )
    where roster.id = roster_to_release.id;

    perform public.sync_fixture_reliability_expected_roster(
      roster_to_release.fixture_id
    );

    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    )
    select
      manager.profile_id,
      'CLAN_ROSTER_PLACE_RELEASED',
      'A future roster place needs attention',
      'A suspended player was removed before the check-in deadline. Confirm an eligible replacement.',
      'FIXTURE',
      roster_to_release.fixture_id,
      jsonb_build_object(
        'fixture_id', roster_to_release.fixture_id,
        'clan_id', roster_to_release.clan_id,
        'released_profile_id', profile_id_to_release,
        'sanction_id', sanction_id_to_use,
        'policy_version_id', roster_to_release.policy_version_id,
        'check_in_deadline_at', roster_to_release.check_in_deadline_at
      )
    from public.clan_members manager
    where manager.clan_id = roster_to_release.clan_id
      and manager.left_at is null
      and manager.role in ('owner', 'leader');

    released_count := released_count + 1;
  end loop;

  return released_count;
end;
$$;

create or replace function public.release_clan_rosters_on_player_suspension()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.subject_type = 'PLAYER'
    and new.sanction_kind in (
      'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
    )
    and new.release_future_bookings
    and new.starts_at <= clock_timestamp()
  then
    perform public.release_suspended_player_future_clan_rosters(
      new.profile_id,
      new.id,
      new.starts_at
    );
  end if;
  return new;
end;
$$;

drop trigger if exists release_clan_rosters_on_player_suspension
on public.reliability_sanctions;
create trigger release_clan_rosters_on_player_suspension
after insert on public.reliability_sanctions
for each row execute function public.release_clan_rosters_on_player_suspension();

-- Ensure clan check-in/finalization sees only the immutable expected roster,
-- while solo attendance remains unchanged. The source functions were created
-- by the immediately preceding migration, so failing closed here is safer than
-- silently leaving surplus clan members exposed to no-show strikes.
do $migration$
declare
  target_function regprocedure;
  function_definition text;
  old_text text;
  new_text text;
begin
  target_function := 'public.get_match_reliability_context(text,uuid)'::regprocedure;
  select pg_get_functiondef(target_function) into function_definition;
  old_text := 'perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);';
  new_text := old_text || E'\n  if normalized_kind = ''CLAN'' then\n    perform public.initialize_fixture_reliability_roster(match_id_to_use);\n  end if;';
  if position('initialize_fixture_reliability_roster' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not add clan roster initialization to reliability context.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  old_text := E'where attendance.terms_id = terms_to_use.id\n    and coalesce(attendance.outcome, '''') not in (';
  new_text := E'where attendance.terms_id = terms_to_use.id\n    and attendance.expected_for_match\n    and coalesce(attendance.outcome, '''') not in (';
  if position('attendance.expected_for_match' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not scope reliability context to the expected roster.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  execute function_definition;

  target_function := 'public.referee_check_in_player(uuid,text,uuid,uuid)'::regprocedure;
  select pg_get_functiondef(target_function) into function_definition;
  old_text := 'perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);';
  new_text := old_text || E'\n  if normalized_kind = ''CLAN'' then\n    perform public.initialize_fixture_reliability_roster(match_id_to_use);\n  end if;';
  if position('initialize_fixture_reliability_roster' in function_definition) = 0 then
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  old_text := E'where attendance.terms_id = terms_to_use.id\n    and attendance.profile_id = profile_id_to_check_in';
  new_text := E'where attendance.terms_id = terms_to_use.id\n    and attendance.expected_for_match\n    and attendance.profile_id = profile_id_to_check_in';
  if position('attendance.expected_for_match' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not protect clan check-in roster membership.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  execute function_definition;

  target_function := 'public.finalize_match_attendance_internal(text,uuid,uuid)'::regprocedure;
  select pg_get_functiondef(target_function) into function_definition;
  old_text := 'perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);';
  new_text := old_text || E'\n  if normalized_kind = ''CLAN'' then\n    perform public.initialize_fixture_reliability_roster(match_id_to_use);\n  end if;';
  if position('initialize_fixture_reliability_roster' in function_definition) = 0 then
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  old_text := E'where attendance.terms_id = terms_to_use.id\n      and attendance.outcome is null';
  new_text := E'where attendance.terms_id = terms_to_use.id\n      and attendance.expected_for_match\n      and attendance.outcome is null';
  if position('attendance.expected_for_match' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not protect non-rostered clan members from no-show finalization.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
  end if;
  execute function_definition;
end;
$migration$;

create or replace function public.active_clan_reliability_strikes(
  clan_id_to_use uuid,
  at_to_use timestamptz default clock_timestamp()
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select greatest(0, coalesce(sum(incident.strike_delta), 0))::integer
  from public.reliability_incidents incident
  where incident.subject_type = 'CLAN'
    and incident.clan_id = clan_id_to_use
    and incident.occurred_at <= at_to_use
    and (incident.expires_at is null or incident.expires_at > at_to_use);
$$;

create or replace function public.record_clan_reliability_incident(
  fixture_id_to_use uuid,
  clan_id_to_use uuid,
  outcome_to_use text,
  strike_delta_to_use integer,
  occurred_at_to_use timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  existing_incident_id uuid;
  incident_id_to_use uuid;
  active_before integer;
  active_after integer;
  strike_lifetime_days integer;
  sanction_rule jsonb;
  threshold_to_use integer;
  sanction_kind_to_use text;
  duration_days_to_use integer;
  sanction_id_to_use uuid;
  deposit_threshold integer;
begin
  if strike_delta_to_use <= 0 then
    return null;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(clan_id_to_use::text, 9175)
  );

  select incident.id into existing_incident_id
  from public.reliability_incidents incident
  where incident.subject_type = 'CLAN'
    and incident.fixture_id = fixture_id_to_use
    and incident.clan_id = clan_id_to_use
    and incident.reversal_of is null;
  if existing_incident_id is not null then
    return existing_incident_id;
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.match_kind = 'CLAN'
    and terms.fixture_id = fixture_id_to_use;
  if terms_to_use.id is null then
    terms_to_use := public.ensure_match_reliability_terms(
      'CLAN',
      fixture_id_to_use
    );
  end if;

  active_before := public.active_clan_reliability_strikes(
    clan_id_to_use,
    occurred_at_to_use
  );
  active_after := active_before + strike_delta_to_use;
  strike_lifetime_days := (terms_to_use.policy_snapshot #>>
    '{attendance,strikeLifetimeDays}')::integer;
  deposit_threshold := (terms_to_use.policy_snapshot #>>
    '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer;

  insert into public.reliability_incidents (
    subject_type,
    clan_id,
    fixture_id,
    outcome,
    strike_delta,
    occurred_at,
    expires_at,
    policy_version_id,
    active_count_before,
    active_count_after,
    detail
  ) values (
    'CLAN',
    clan_id_to_use,
    fixture_id_to_use,
    upper(trim(outcome_to_use)),
    strike_delta_to_use,
    occurred_at_to_use,
    occurred_at_to_use + make_interval(days => strike_lifetime_days),
    terms_to_use.policy_version_id,
    active_before,
    active_after,
    jsonb_build_object(
      'fixture_id', fixture_id_to_use,
      'deposit_required', active_after >= deposit_threshold,
      'deposit_bps', (terms_to_use.policy_snapshot #>>
        '{clan,reliabilityDeposit,depositBps}')::integer
    )
  ) returning id into incident_id_to_use;

  select value into sanction_rule
  from jsonb_array_elements(
    terms_to_use.policy_snapshot #> '{clan,sanctions}'
  )
  where (value ->> 'threshold')::integer > active_before
    and (value ->> 'threshold')::integer <= active_after
  order by (value ->> 'threshold')::integer desc
  limit 1;

  if sanction_rule is not null then
    threshold_to_use := (sanction_rule ->> 'threshold')::integer;
    sanction_kind_to_use := sanction_rule ->> 'kind';
    duration_days_to_use := case
      when sanction_rule -> 'durationDays' = 'null'::jsonb then null
      else (sanction_rule ->> 'durationDays')::integer
    end;

    insert into public.reliability_sanctions (
      subject_type,
      clan_id,
      incident_id,
      policy_version_id,
      threshold,
      sanction_kind,
      starts_at,
      ends_at,
      release_future_bookings
    ) values (
      'CLAN',
      clan_id_to_use,
      incident_id_to_use,
      terms_to_use.policy_version_id,
      threshold_to_use,
      sanction_kind_to_use,
      occurred_at_to_use,
      case
        when sanction_kind_to_use in ('WARNING', 'INDEFINITE_SUSPENSION')
          then null
        else occurred_at_to_use + make_interval(days => duration_days_to_use)
      end,
      false
    ) returning id into sanction_id_to_use;
  end if;

  insert into public.notifications (
    recipient_profile_id,
    type,
    title,
    body,
    related_entity_type,
    related_entity_id,
    data
  )
  select
    member.profile_id,
    'CLAN_RELIABILITY_OUTCOME',
    case
      when sanction_kind_to_use = 'BOOKING_RESTRICTION'
        then 'Clan fixture booking restricted'
      when sanction_kind_to_use in (
        'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
      ) then 'Clan participation restricted'
      else 'Clan attendance outcome recorded'
    end,
    'This fixture added ' || strike_delta_to_use ||
      case when strike_delta_to_use = 1
        then ' active clan strike.' else ' active clan strikes.' end,
    'CLAN_RELIABILITY_INCIDENT',
    incident_id_to_use,
    jsonb_build_object(
      'fixture_id', fixture_id_to_use,
      'clan_id', clan_id_to_use,
      'active_strikes', active_after,
      'deposit_required', active_after >= deposit_threshold,
      'sanction_id', sanction_id_to_use
    )
  from public.clan_members member
  where member.clan_id = clan_id_to_use
    and member.left_at is null
    and member.role in ('owner', 'leader');

  return incident_id_to_use;
end;
$$;

create or replace function public.clan_has_active_reliability_restriction(
  clan_id_to_check uuid,
  at_to_use timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.reliability_sanctions sanction
    where sanction.subject_type = 'CLAN'
      and sanction.clan_id = clan_id_to_check
      and sanction.sanction_kind in (
        'BOOKING_RESTRICTION',
        'PARTICIPATION_SUSPENSION',
        'INDEFINITE_SUSPENSION'
      )
      and sanction.revoked_at is null
      and sanction.starts_at <= at_to_use
      and (sanction.ends_at is null or sanction.ends_at > at_to_use)
  );
$$;

create or replace function public.enforce_clan_reliability_fixture_restriction()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (
    tg_op = 'INSERT'
    or new.home_clan_id is distinct from old.home_clan_id
  ) and public.clan_has_active_reliability_restriction(
    new.home_clan_id,
    clock_timestamp()
  ) then
    raise exception 'This clan cannot schedule a new fixture while its reliability restriction is active.';
  end if;

  if new.away_clan_id is not null
    and (
      tg_op = 'INSERT'
      or new.away_clan_id is distinct from old.away_clan_id
    )
    and public.clan_has_active_reliability_restriction(
      new.away_clan_id,
      clock_timestamp()
    )
  then
    raise exception 'This clan cannot join a new fixture while its reliability restriction is active.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_clan_reliability_fixture_restriction
on public.fixtures;
create trigger enforce_clan_reliability_fixture_restriction
before insert or update of home_clan_id, away_clan_id on public.fixtures
for each row execute function public.enforce_clan_reliability_fixture_restriction();

create or replace function public.finalize_clan_reliability_outcomes(
  fixture_id_to_finalize uuid,
  actor_referee_id_to_use uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  clan_id_to_use uuid;
  side_to_use text;
  expected_count_to_use integer;
  on_time_count_to_use integer;
  kickoff_count_to_use integer;
  cutoff_count_to_use integer;
  minimum_on_time integer;
  minimum_at_kickoff integer;
  required_count integer;
  policy_effective_from timestamptz;
  outcome_to_use text;
  strikes_to_use integer;
  forfeit_to_use boolean;
  outcome_id_to_use uuid;
  inserted_count integer := 0;
  forfeit_count integer;
  forfeiting_clan_id uuid;
  awarded_clan_id uuid;
  details_to_use text;
begin
  select * into fixture_to_use
  from public.fixtures fixture
  where fixture.id = fixture_id_to_finalize
  for update;
  if fixture_to_use.id is null or fixture_to_use.away_clan_id is null then
    return jsonb_build_object('finalized_count', 0, 'forfeit_count', 0);
  end if;
  if actor_referee_id_to_use is not null and not
    public.referee_can_manage_reliability_match(
      actor_referee_id_to_use,
      'CLAN',
      fixture_id_to_finalize
    )
  then
    raise exception 'This match is not assigned to you.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_id_to_finalize
  );
  select policy.effective_from into policy_effective_from
  from public.reliability_policy_versions policy
  where policy.id = terms_to_use.policy_version_id;
  if policy_effective_from is null
    or policy_effective_from > terms_to_use.kickoff_at
  then
    return jsonb_build_object(
      'finalized_count', 0,
      'forfeit_count', 0,
      'policy_applies', false
    );
  end if;
  if clock_timestamp() < terms_to_use.no_show_cutoff_at then
    return jsonb_build_object('finalized_count', 0, 'forfeit_count', 0);
  end if;
  perform public.initialize_fixture_reliability_roster(
    fixture_id_to_finalize
  );
  minimum_on_time := (terms_to_use.policy_snapshot #>>
    '{clan,minimumOnTimeWithoutClanStrike}')::integer;
  minimum_at_kickoff := (terms_to_use.policy_snapshot #>>
    '{clan,minimumAtKickoffWithoutForfeit}')::integer;
  required_count := (terms_to_use.policy_snapshot #>>
    '{clan,playersPerSide}')::integer;

  foreach clan_id_to_use in array array[
    fixture_to_use.home_clan_id,
    fixture_to_use.away_clan_id
  ]
  loop
    side_to_use := case
      when clan_id_to_use = fixture_to_use.home_clan_id then 'HOME'
      else 'AWAY'
    end;
    select
      count(*)::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.check_in_deadline_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at <= terms_to_use.kickoff_at
      )::integer,
      count(*) filter (
        where attendance.checked_in_at < terms_to_use.no_show_cutoff_at
      )::integer
    into
      expected_count_to_use,
      on_time_count_to_use,
      kickoff_count_to_use,
      cutoff_count_to_use
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.clan_id = clan_id_to_use
      and attendance.expected_for_match;

    if expected_count_to_use > required_count then
      raise exception '% expected roster has % players; policy permits %.',
        side_to_use,
        expected_count_to_use,
        required_count;
    end if;

    if cutoff_count_to_use = 0 then
      outcome_to_use := 'ENTIRE_CLAN_NO_SHOW';
      strikes_to_use := (terms_to_use.policy_snapshot #>>
        '{clan,entireClanNoShowStrikes}')::integer;
      forfeit_to_use := true;
    elsif kickoff_count_to_use < minimum_at_kickoff then
      outcome_to_use := 'FORFEIT';
      strikes_to_use := (terms_to_use.policy_snapshot #>>
        '{clan,forfeitStrikes}')::integer;
      forfeit_to_use := true;
    elsif on_time_count_to_use < minimum_on_time then
      outcome_to_use := 'PARTIAL_LATE';
      strikes_to_use := (terms_to_use.policy_snapshot #>>
        '{clan,partialAttendanceStrikes}')::integer;
      forfeit_to_use := false;
    else
      outcome_to_use := 'READY';
      strikes_to_use := 0;
      forfeit_to_use := false;
    end if;

    insert into public.clan_match_reliability_outcomes (
      terms_id,
      fixture_id,
      clan_id,
      side,
      expected_count,
      on_time_count,
      kickoff_count,
      cutoff_count,
      outcome,
      strike_delta,
      official_forfeit,
      policy_version_id,
      finalized_by,
      detail
    ) values (
      terms_to_use.id,
      fixture_id_to_finalize,
      clan_id_to_use,
      side_to_use,
      expected_count_to_use,
      on_time_count_to_use,
      kickoff_count_to_use,
      cutoff_count_to_use,
      outcome_to_use,
      strikes_to_use,
      forfeit_to_use,
      terms_to_use.policy_version_id,
      actor_referee_id_to_use,
      jsonb_build_object(
        'check_in_deadline_at', terms_to_use.check_in_deadline_at,
        'kickoff_at', terms_to_use.kickoff_at,
        'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
        'minimum_on_time', minimum_on_time,
        'minimum_at_kickoff', minimum_at_kickoff
      )
    )
    on conflict (fixture_id, clan_id) do nothing
    returning id into outcome_id_to_use;

    if outcome_id_to_use is not null then
      inserted_count := inserted_count + 1;
      perform public.record_clan_reliability_incident(
        fixture_id_to_finalize,
        clan_id_to_use,
        outcome_to_use,
        strikes_to_use,
        terms_to_use.no_show_cutoff_at
      );
    end if;
    outcome_id_to_use := null;
  end loop;

  select
    count(*)::integer,
    (array_agg(outcome.clan_id order by outcome.clan_id))[1]
  into forfeit_count, forfeiting_clan_id
  from public.clan_match_reliability_outcomes outcome
  where outcome.fixture_id = fixture_id_to_finalize
    and outcome.official_forfeit;

  if forfeit_count = 1 then
    awarded_clan_id := case
      when forfeiting_clan_id = fixture_to_use.home_clan_id
        then fixture_to_use.away_clan_id
      else fixture_to_use.home_clan_id
    end;
    update public.fixtures
    set cancellation_context = coalesce(cancellation_context, '{}'::jsonb) || jsonb_build_object(
      'reliability_forfeit_required', true,
      'reliability_policy_version_id', terms_to_use.policy_version_id,
      'reported_clan_id', forfeiting_clan_id,
      'awarded_clan_id', awarded_clan_id,
      'forfeit_score', (terms_to_use.policy_snapshot #>>
        '{clan,forfeitScore}')::integer,
      'recorded_at', clock_timestamp()
    )
    where id = fixture_id_to_finalize;

    if actor_referee_id_to_use is not null
      and fixture_to_use.status = 'LIVE'
      and not exists (
        select 1 from public.match_forfeit_decisions decision
        where decision.fixture_id = fixture_id_to_finalize
      )
    then
      details_to_use := format(
        'The expected roster had fewer than %s players available at kickoff. Reliability policy %s requires an official forfeit.',
        minimum_at_kickoff,
        terms_to_use.policy_version_id
      );
      begin
        perform public.referee_report_clan_forfeit(
          actor_referee_id_to_use,
          fixture_id_to_finalize,
          forfeiting_clan_id,
          'NO_SHOW_OR_MATCH_MANIPULATION',
          details_to_use,
          'INSUFFICIENT_PLAYERS',
          details_to_use,
          null
        );
      exception when others then
        raise warning 'Clan attendance forfeit needs admin attention for %: %',
          fixture_id_to_finalize,
          sqlerrm;
      end;
    end if;
  elsif forfeit_count > 1 then
    update public.fixtures
    set cancellation_context = coalesce(cancellation_context, '{}'::jsonb) || jsonb_build_object(
      'reliability_forfeit_required', true,
      'both_clans_forfeited', true,
      'reliability_policy_version_id', terms_to_use.policy_version_id,
      'recorded_at', clock_timestamp()
    )
    where id = fixture_id_to_finalize;
  end if;

  return jsonb_build_object(
    'finalized_count', inserted_count,
    'forfeit_count', coalesce(forfeit_count, 0),
    'forfeiting_clan_id', forfeiting_clan_id,
    'awarded_clan_id', awarded_clan_id,
    'policy_version_id', terms_to_use.policy_version_id
  );
end;
$$;

create or replace function public.referee_finalize_match_attendance(
  actor_referee_id uuid,
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
  clan_outcome jsonb;
  context_to_return jsonb;
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'You are not assigned to manage this match.';
  end if;

  if normalized_kind = 'CLAN' then
    perform public.initialize_fixture_reliability_roster(match_id_to_use);
  end if;
  perform public.finalize_match_attendance_internal(
    normalized_kind,
    match_id_to_use,
    actor_referee_id
  );
  if normalized_kind = 'CLAN' then
    clan_outcome := public.finalize_clan_reliability_outcomes(
      match_id_to_use,
      actor_referee_id
    );
  end if;

  context_to_return := public.get_match_reliability_context(
    normalized_kind,
    match_id_to_use
  );
  return context_to_return || jsonb_build_object(
    'clan_reliability', clan_outcome
  );
end;
$$;

create or replace function public.finalize_due_clan_reliability_attendance()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  finalized_total integer := 0;
  result_to_use jsonb;
begin
  for candidate in
    select fixture.id
    from public.fixtures fixture
    join public.match_reliability_terms terms
      on terms.fixture_id = fixture.id
      and terms.match_kind = 'CLAN'
    join public.reliability_policy_versions policy
      on policy.id = terms.policy_version_id
      and policy.effective_from <= terms.kickoff_at
    where fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
      and fixture.away_clan_id is not null
      and terms.no_show_cutoff_at <= clock_timestamp()
      and not exists (
        select 1
        from public.clan_match_reliability_outcomes outcome
        where outcome.fixture_id = fixture.id
      )
    order by terms.no_show_cutoff_at, fixture.id
    limit 100
  loop
    begin
      perform public.initialize_fixture_reliability_roster(candidate.id);
      perform public.finalize_match_attendance_internal(
        'CLAN',
        candidate.id,
        null
      );
      result_to_use := public.finalize_clan_reliability_outcomes(
        candidate.id,
        null
      );
      finalized_total := finalized_total + coalesce(
        (result_to_use ->> 'finalized_count')::integer,
        0
      );
    exception when others then
      raise warning 'Could not finalize clan reliability attendance for %: %',
        candidate.id,
        sqlerrm;
    end;
  end loop;
  return finalized_total;
end;
$$;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid from cron.job
    where jobname = 'finalize-field-clan-reliability-attendance'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'finalize-field-clan-reliability-attendance',
  '* * * * *',
  'select public.finalize_due_clan_reliability_attendance()'
);

alter table public.open_queue_events
drop constraint if exists open_queue_events_event_type_check;
alter table public.open_queue_events
add constraint open_queue_events_event_type_check check (
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
    'INJURY_RECORDED',
    'SR_PROTECTION_APPLIED'
  )
);

create or replace function public.apply_open_queue_reliability_rating_adjustments(
  game_id_to_apply uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  game_to_apply public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  event_to_adjust record;
  losing_side text;
  winning_side text;
  match_seconds integer;
  nominal_seconds integer;
  qualifying_seconds integer;
  shorthanded_qualifies boolean := false;
  disadvantaged_winner_qualifies boolean := false;
  shorthanded_side text;
  shorthanded_side_count integer := 0;
  injury_to_use public.match_verified_injuries%rowtype;
  losing_injury_to_use public.match_verified_injuries%rowtype;
  injury_before_threshold boolean := false;
  injury_applies boolean := false;
  losing_injury_before_threshold boolean := false;
  injury_affects_result boolean := false;
  threshold_bps integer;
  policy_effective_from timestamptz;
  losing_multiplier_bps integer := 10000;
  winner_multiplier_bps integer := 10000;
  attendance_positive_bps integer;
  attendance_negative_bps integer;
  reliability_multiplier integer;
  original_change integer;
  adjusted_change integer;
  adjusted_after integer;
  rating_delta integer;
  reason_to_use text;
  adjusted_count integer := 0;
  refund_booking record;
  refund_difference integer;
  injury_refund_bps integer;
  target_refund_fils integer;
begin
  select * into game_to_apply
  from public.open_queue_games game
  where game.id = game_id_to_apply
  for update;
  if game_to_apply.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_to_apply.status <> 'FINAL'
    or game_to_apply.white_score is null
    or game_to_apply.black_score is null
  then
    raise exception 'Reliability SR can only be applied to a final scored game.';
  end if;

  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
  ) then
    return 0;
  end if;
  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
      and event.reliability_policy_version_id is null
  ) then
    return 0;
  end if;

  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO',
    game_id_to_apply
  );
  select policy.effective_from into policy_effective_from
  from public.reliability_policy_versions policy
  where policy.id = terms_to_use.policy_version_id;
  if policy_effective_from is null
    or policy_effective_from > game_to_apply.starts_at
  then
    -- ensure_match_reliability_terms deliberately has an inspection-only
    -- fallback for pre-rollout matches. Never use that fallback to rewrite a
    -- historical SR ledger.
    return 0;
  end if;
  match_seconds := public.reliability_match_elapsed_seconds(
    'SOLO',
    game_id_to_apply
  );
  nominal_seconds := greatest(
    1,
    floor(extract(epoch from (game_to_apply.ends_at - game_to_apply.starts_at)))::integer
  );
  qualifying_seconds := (terms_to_use.policy_snapshot #>>
    '{sr,shorthandedQualifyingActualMinutes}')::integer * 60;

  if game_to_apply.white_score > game_to_apply.black_score then
    winning_side := 'WHITE';
    losing_side := 'BLACK';
  elsif game_to_apply.black_score > game_to_apply.white_score then
    winning_side := 'BLACK';
    losing_side := 'WHITE';
  end if;

  select
    count(distinct period.side)::integer,
    min(period.side)
  into shorthanded_side_count, shorthanded_side
  from public.match_shorthanded_periods period
  where period.terms_id = terms_to_use.id
    and period.reason in ('LATE_ARRIVAL', 'NO_SHOW')
    -- Hosts record this immediately after starting the match clock. Allow a
    -- small evidence-capture tolerance while still rejecting mid-match gaps.
    and period.started_match_second between 0 and 30
    and greatest(
      0,
      coalesce(period.ended_match_second, match_seconds)
        - period.started_match_second
    ) >= qualifying_seconds;

  -- Protection only applies when exactly one side began and remained short.
  -- If both teams began short, neither has a relative numerical disadvantage.
  if shorthanded_side_count = 1 then
    shorthanded_qualifies := shorthanded_side = losing_side;
    disadvantaged_winner_qualifies := shorthanded_side = winning_side;
  else
    shorthanded_side := null;
  end if;

  if losing_side is not null then

    select * into losing_injury_to_use
    from public.match_verified_injuries injury
    where injury.terms_id = terms_to_use.id
      and injury.side = losing_side
      and injury.unable_to_continue
      and not injury.replacement_available
    order by injury.match_second, injury.id
    limit 1;
  end if;

  -- Refund eligibility follows the verified injury itself, not the final
  -- result. This deliberately also covers a draw or a win by the injured side.
  select * into injury_to_use
  from public.match_verified_injuries injury
  where injury.terms_id = terms_to_use.id
    and injury.unable_to_continue
    and not injury.replacement_available
  order by injury.match_second, injury.id
  limit 1;

  if injury_to_use.id is not null then
    threshold_bps := (terms_to_use.policy_snapshot #>>
      '{injury,halfMatchThresholdBps}')::integer;
    injury_before_threshold :=
      injury_to_use.match_second::bigint * 10000
        < nominal_seconds::bigint * threshold_bps;
    injury_applies := true;
  end if;

  if losing_injury_to_use.id is not null then
    injury_affects_result := true;
    losing_injury_before_threshold :=
      losing_injury_to_use.match_second::bigint * 10000
        < nominal_seconds::bigint * threshold_bps;
    if losing_injury_before_threshold then
      losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,incompleteLosingMultiplierBps}')::integer;
      winner_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,incompleteWinningMultiplierBps}')::integer;
    else
      losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,completedLossMultiplierBps}')::integer;
      winner_multiplier_bps := 10000;
    end if;
  elsif shorthanded_qualifies then
    losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
      '{sr,protectedLosingOnTimeMultiplierBps}')::integer;
    winner_multiplier_bps := (terms_to_use.policy_snapshot #>>
      '{sr,protectedWinnerMultiplierBps}')::integer;
  end if;

  for event_to_adjust in
    select
      event.id as event_id,
      event.profile_id,
      event.side,
      event.result,
      event.rating_before,
      event.rating_change,
      event.rating_after,
      attendance.outcome as attendance_outcome,
      coalesce(attendance.positive_sr_multiplier_bps, 10000)
        as positive_sr_multiplier_bps,
      coalesce(attendance.negative_sr_multiplier_bps, 10000)
        as negative_sr_multiplier_bps
    from public.player_rating_events event
    left join public.match_attendance_records attendance
      on attendance.open_queue_game_id = event.source_id
      and attendance.profile_id = event.profile_id
      and attendance.match_kind = 'SOLO'
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_id_to_apply
      and event.reliability_policy_version_id is null
    order by event.profile_id
    for update of event
  loop
    original_change := event_to_adjust.rating_change;
    attendance_positive_bps := event_to_adjust.positive_sr_multiplier_bps;
    attendance_negative_bps := event_to_adjust.negative_sr_multiplier_bps;
    reliability_multiplier := 10000;
    reason_to_use := null;

    if original_change > 0 then
      reliability_multiplier := attendance_positive_bps;
      if event_to_adjust.side = winning_side
        and (injury_affects_result or shorthanded_qualifies)
      then
        reliability_multiplier := round(
          reliability_multiplier::numeric * winner_multiplier_bps / 10000
        )::integer;
        reason_to_use := case
          when injury_affects_result then 'VERIFIED_INJURY'
          else 'SHORTHANDED_OPPONENT'
        end;
      elsif disadvantaged_winner_qualifies
        and event_to_adjust.side = winning_side
      then
        reliability_multiplier := round(
          reliability_multiplier::numeric *
            (terms_to_use.policy_snapshot #>>
            '{sr,disadvantagedWinnerMultiplierBps}')::integer / 10000
        )::integer;
        reason_to_use := 'SHORTHANDED_TEAM_WIN';
      end if;
    elsif original_change < 0 then
      reliability_multiplier := attendance_negative_bps;
      if event_to_adjust.side = losing_side
        and injury_affects_result
      then
        reliability_multiplier := round(
          reliability_multiplier::numeric * losing_multiplier_bps / 10000
        )::integer;
        reason_to_use := 'VERIFIED_INJURY';
      elsif event_to_adjust.side = losing_side
        and shorthanded_qualifies
        and (
          event_to_adjust.attendance_outcome = 'ON_TIME'
          or (terms_to_use.policy_snapshot #>>
            '{sr,latePlayerGetsTeamProtection}')::boolean
        )
      then
        -- Team protection replaces the normal negative result for responsible
        -- players. A late player keeps their configured negative multiplier.
        reliability_multiplier := losing_multiplier_bps;
        reason_to_use := 'SHORTHANDED_TEAM';
      end if;
    end if;

    adjusted_after := greatest(
      0,
      event_to_adjust.rating_before + round(
        original_change::numeric * reliability_multiplier / 10000
      )::integer
    );
    adjusted_change := adjusted_after - event_to_adjust.rating_before;
    rating_delta := adjusted_change - original_change;

    perform rating.profile_id
    from public.player_ratings rating
    where rating.profile_id = event_to_adjust.profile_id
    for update;
    if not found then
      raise exception 'Player SR row is missing for reliability adjustment.';
    end if;
    if (
      select rating.skill_rating
      from public.player_ratings rating
      where rating.profile_id = event_to_adjust.profile_id
    ) <> event_to_adjust.rating_after then
      raise exception 'Player SR changed before reliability adjustment could be applied.';
    end if;

    update public.player_rating_events
    set
      rating_change = adjusted_change,
      rating_after = adjusted_after,
      calculation_version = calculation_version || '_RELIABILITY_V1',
      reliability_policy_version_id = terms_to_use.policy_version_id,
      attendance_outcome = event_to_adjust.attendance_outcome,
      reliability_multiplier_bps = reliability_multiplier,
      sr_protection_applied = reason_to_use is not null,
      sr_protection_reason = reason_to_use
    where id = event_to_adjust.event_id;

    update public.player_ratings
    set
      skill_rating = skill_rating + rating_delta,
      last_change = adjusted_change
    where profile_id = event_to_adjust.profile_id;

    update public.open_queue_bookings
    set rating_change = adjusted_change
    where game_id = game_id_to_apply
      and profile_id = event_to_adjust.profile_id;

    if adjusted_change is distinct from original_change then
      adjusted_count := adjusted_count + 1;
    end if;
  end loop;

  if injury_applies and injury_before_threshold then
    injury_refund_bps := (terms_to_use.policy_snapshot #>>
      '{injury,incompleteRefundBps}')::integer;
    for refund_booking in
      select booking.*
      from public.open_queue_bookings booking
      where booking.game_id = game_id_to_apply
        and booking.status = 'CONFIRMED'
        and booking.played
      order by booking.profile_id
      for update
    loop
      target_refund_fils := (
        refund_booking.base_amount_fils::bigint * injury_refund_bps / 10000
      )::integer;
      refund_difference := greatest(
        0,
        target_refund_fils
          - coalesce(refund_booking.refund_amount_fils, 0)
      );
      if refund_difference > 0 then
        perform public.credit_field_wallet(
          refund_booking.profile_id,
          refund_difference,
          'FIELD_CANCELLATION_REFUND',
          'verified-injury-refund:' || game_id_to_apply::text || ':' ||
            refund_booking.profile_id::text,
          'Full Field Wallet refund after a verified early-match injury.',
          terms_to_use.policy_version_id,
          refund_booking.id,
          null,
          jsonb_build_object(
            'injury_id', injury_to_use.id,
            'match_second', injury_to_use.match_second,
            'refund_bps', injury_refund_bps
          )
        );
      end if;

      update public.open_queue_bookings
      set
        refund_bps = injury_refund_bps,
        refund_percent = round(injury_refund_bps / 100.0)::integer,
        refund_amount_fils = greatest(
          coalesce(refund_amount_fils, 0),
          target_refund_fils
        ),
        refund_status = 'PROCESSED',
        payment_status = case
          when target_refund_fils >= amount_paid_fils
            and amount_paid_fils > 0 then 'REFUNDED'
          when target_refund_fils > 0 then 'PARTIALLY_REFUNDED'
          else payment_status
        end
      where id = refund_booking.id;

      update public.match_attendance_records attendance
      set
        refund_bps = injury_refund_bps,
        refund_amount_fils = greatest(
          attendance.refund_amount_fils,
          target_refund_fils
        ),
        consequence_snapshot = attendance.consequence_snapshot ||
          jsonb_build_object(
            'verified_injury_refund_bps', injury_refund_bps,
            'verified_injury_refund_fils', target_refund_fils,
            'verified_injury_id', injury_to_use.id
          )
      where attendance.booking_id = refund_booking.id;
    end loop;
  end if;

  if injury_applies and not exists (
    select 1 from public.open_queue_events event
    where event.game_id = game_id_to_apply
      and event.event_type = 'INJURY_RECORDED'
      and event.profile_id = injury_to_use.profile_id
  ) then
    insert into public.open_queue_events (
      game_id,
      event_type,
      team,
      profile_id,
      minute,
      second,
      note
    ) values (
      game_id_to_apply,
      'INJURY_RECORDED',
      injury_to_use.side,
      injury_to_use.profile_id,
      injury_to_use.match_second / 60,
      injury_to_use.match_second % 60,
      'Verified injury recorded by the Field Host.'
    );
  end if;

  if (
    injury_affects_result
    or shorthanded_qualifies
    or disadvantaged_winner_qualifies
  ) and not exists (
    select 1 from public.open_queue_events event
    where event.game_id = game_id_to_apply
      and event.event_type = 'SR_PROTECTION_APPLIED'
  ) then
    insert into public.open_queue_events (
      game_id,
      event_type,
      team,
      minute,
      second,
      note
    ) values (
      game_id_to_apply,
      'SR_PROTECTION_APPLIED',
      case
        when disadvantaged_winner_qualifies then winning_side
        else losing_side
      end,
      match_seconds / 60,
      match_seconds % 60,
      case
        when injury_affects_result then 'SR protection applied after a verified injury.'
        when disadvantaged_winner_qualifies
          then 'Shorthanded winner SR adjustment applied.'
        else 'SR protection applied after qualifying shorthanded play.'
      end
    );
  end if;

  return adjusted_count;
end;
$$;

create or replace function public.apply_open_queue_player_ratings_on_final()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  policy_id_to_use uuid;
  terms_to_use public.match_reliability_terms%rowtype;
begin
  if new.status = 'FINAL' and old.status is distinct from 'FINAL' then
    policy_id_to_use := public.resolve_reliability_policy_id(new.starts_at);
    if policy_id_to_use is not null then
      terms_to_use := public.ensure_match_reliability_terms('SOLO', new.id);
      if clock_timestamp() < terms_to_use.no_show_cutoff_at then
        raise exception 'A solo match cannot be finalized before its no-show cutoff at %.',
          terms_to_use.no_show_cutoff_at;
      end if;
      perform public.ensure_match_attendance_records('SOLO', new.id);
      perform public.finalize_match_attendance_internal('SOLO', new.id, null);
    end if;

    -- Attendance finalization marks unchecked no-shows as not played before
    -- the base SR function selects participants. This prevents an absent
    -- confirmed booking from ever receiving an SR event or appearance.
    perform public.apply_open_queue_player_ratings(new.id);
    if policy_id_to_use is not null then
      perform public.apply_open_queue_reliability_rating_adjustments(new.id);
    end if;
  end if;
  return new;
end;
$$;

-- Clan fixtures write the same Player SR ledger as solo matches. Apply the
-- same per-player attendance multiplier and referee-evidenced team protection
-- after the established clan rating trigger has written its base events.
create or replace function public.apply_clan_reliability_rating_adjustments(
  fixture_id_to_apply uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_apply public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  event_to_adjust record;
  kickoff_to_use timestamptz;
  policy_effective_from timestamptz;
  winning_side text;
  losing_side text;
  match_seconds integer;
  nominal_seconds integer;
  qualifying_seconds integer;
  shorthanded_side text;
  shorthanded_side_count integer := 0;
  shorthanded_qualifies boolean := false;
  disadvantaged_winner_qualifies boolean := false;
  losing_injury_to_use public.match_verified_injuries%rowtype;
  injury_affects_result boolean := false;
  injury_before_threshold boolean := false;
  threshold_bps integer;
  losing_multiplier_bps integer := 10000;
  winner_multiplier_bps integer := 10000;
  reliability_multiplier integer;
  original_change integer;
  adjusted_change integer;
  adjusted_after integer;
  rating_delta integer;
  reason_to_use text;
  adjusted_count integer := 0;
begin
  select * into fixture_to_apply
  from public.fixtures fixture
  where fixture.id = fixture_id_to_apply
  for update;
  if fixture_to_apply.id is null then
    raise exception 'Fixture not found.';
  end if;
  if fixture_to_apply.status <> 'FINAL'
    or fixture_to_apply.home_score is null
    or fixture_to_apply.away_score is null
  then
    raise exception 'Reliability SR can only be applied to a final scored fixture.';
  end if;
  if coalesce(
    (fixture_to_apply.cancellation_context ->>
      'reliability_forfeit_without_play')::boolean,
    false
  ) then
    return 0;
  end if;

  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_apply
  ) then
    return 0;
  end if;
  if not exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_apply
      and event.reliability_policy_version_id is null
  ) then
    return 0;
  end if;

  kickoff_to_use := public.fixture_start_at(
    fixture_to_apply.match_date,
    fixture_to_apply.time_slot
  );
  terms_to_use := public.ensure_match_reliability_terms(
    'CLAN',
    fixture_id_to_apply
  );
  select policy.effective_from into policy_effective_from
  from public.reliability_policy_versions policy
  where policy.id = terms_to_use.policy_version_id;
  if policy_effective_from is null
    or policy_effective_from > kickoff_to_use
  then
    return 0;
  end if;

  match_seconds := public.reliability_match_elapsed_seconds(
    'CLAN',
    fixture_id_to_apply
  );
  select coalesce(
    (
      select clock.duration_seconds
      from public.fixture_clock_states clock
      where clock.fixture_id = fixture_id_to_apply
    ),
    3600
  ) into nominal_seconds;
  nominal_seconds := greatest(1, coalesce(nominal_seconds, 3600));
  qualifying_seconds := (terms_to_use.policy_snapshot #>>
    '{sr,shorthandedQualifyingActualMinutes}')::integer * 60;

  if fixture_to_apply.home_score > fixture_to_apply.away_score then
    winning_side := 'HOME';
    losing_side := 'AWAY';
  elsif fixture_to_apply.away_score > fixture_to_apply.home_score then
    winning_side := 'AWAY';
    losing_side := 'HOME';
  end if;

  select
    count(distinct period.side)::integer,
    min(period.side)
  into shorthanded_side_count, shorthanded_side
  from public.match_shorthanded_periods period
  where period.terms_id = terms_to_use.id
    and period.reason in ('LATE_ARRIVAL', 'NO_SHOW')
    and period.started_match_second between 0 and 30
    and greatest(
      0,
      coalesce(period.ended_match_second, match_seconds)
        - period.started_match_second
    ) >= qualifying_seconds;

  if shorthanded_side_count = 1 then
    shorthanded_qualifies := shorthanded_side = losing_side;
    disadvantaged_winner_qualifies := shorthanded_side = winning_side;
  else
    shorthanded_side := null;
  end if;

  if losing_side is not null then
    select * into losing_injury_to_use
    from public.match_verified_injuries injury
    where injury.terms_id = terms_to_use.id
      and injury.side = losing_side
      and injury.unable_to_continue
      and not injury.replacement_available
    order by injury.match_second, injury.id
    limit 1;
  end if;

  if losing_injury_to_use.id is not null then
    injury_affects_result := true;
    threshold_bps := (terms_to_use.policy_snapshot #>>
      '{injury,halfMatchThresholdBps}')::integer;
    injury_before_threshold :=
      losing_injury_to_use.match_second::bigint * 10000
        < nominal_seconds::bigint * threshold_bps;
    if injury_before_threshold then
      losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,incompleteLosingMultiplierBps}')::integer;
      winner_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,incompleteWinningMultiplierBps}')::integer;
    else
      losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{injury,completedLossMultiplierBps}')::integer;
    end if;
  elsif shorthanded_qualifies then
    losing_multiplier_bps := (terms_to_use.policy_snapshot #>>
      '{sr,protectedLosingOnTimeMultiplierBps}')::integer;
    winner_multiplier_bps := (terms_to_use.policy_snapshot #>>
      '{sr,protectedWinnerMultiplierBps}')::integer;
  end if;

  for event_to_adjust in
    select
      event.id as event_id,
      event.profile_id,
      event.side,
      event.result,
      event.rating_before,
      event.rating_change,
      event.rating_after,
      attendance.outcome as attendance_outcome,
      coalesce(attendance.positive_sr_multiplier_bps, 10000)
        as positive_sr_multiplier_bps,
      coalesce(attendance.negative_sr_multiplier_bps, 10000)
        as negative_sr_multiplier_bps
    from public.player_rating_events event
    left join public.match_attendance_records attendance
      on attendance.fixture_id = event.source_id
      and attendance.profile_id = event.profile_id
      and attendance.match_kind = 'CLAN'
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = fixture_id_to_apply
      and event.reliability_policy_version_id is null
    order by event.profile_id
    for update of event
  loop
    original_change := event_to_adjust.rating_change;
    reliability_multiplier := case
      when original_change > 0
        then event_to_adjust.positive_sr_multiplier_bps
      when original_change < 0
        then event_to_adjust.negative_sr_multiplier_bps
      else 10000
    end;
    reason_to_use := null;

    if original_change > 0 then
      if event_to_adjust.side = winning_side
        and (injury_affects_result or shorthanded_qualifies)
      then
        reliability_multiplier := round(
          reliability_multiplier::numeric * winner_multiplier_bps / 10000
        )::integer;
        reason_to_use := case
          when injury_affects_result then 'VERIFIED_INJURY'
          else 'SHORTHANDED_OPPONENT'
        end;
      elsif disadvantaged_winner_qualifies
        and event_to_adjust.side = winning_side
      then
        reliability_multiplier := round(
          reliability_multiplier::numeric *
            (terms_to_use.policy_snapshot #>>
              '{sr,disadvantagedWinnerMultiplierBps}')::integer / 10000
        )::integer;
        reason_to_use := 'SHORTHANDED_TEAM_WIN';
      end if;
    elsif original_change < 0 then
      if event_to_adjust.side = losing_side and injury_affects_result then
        reliability_multiplier := round(
          reliability_multiplier::numeric * losing_multiplier_bps / 10000
        )::integer;
        reason_to_use := 'VERIFIED_INJURY';
      elsif event_to_adjust.side = losing_side
        and shorthanded_qualifies
        and (
          event_to_adjust.attendance_outcome = 'ON_TIME'
          or (terms_to_use.policy_snapshot #>>
            '{sr,latePlayerGetsTeamProtection}')::boolean
        )
      then
        reliability_multiplier := losing_multiplier_bps;
        reason_to_use := 'SHORTHANDED_TEAM';
      end if;
    end if;

    adjusted_after := greatest(
      0,
      event_to_adjust.rating_before + round(
        original_change::numeric * reliability_multiplier / 10000
      )::integer
    );
    adjusted_change := adjusted_after - event_to_adjust.rating_before;
    rating_delta := adjusted_change - original_change;

    perform rating.profile_id
    from public.player_ratings rating
    where rating.profile_id = event_to_adjust.profile_id
    for update;
    if not found then
      raise exception 'Player SR row is missing for clan reliability adjustment.';
    end if;
    if (
      select rating.skill_rating
      from public.player_ratings rating
      where rating.profile_id = event_to_adjust.profile_id
    ) <> event_to_adjust.rating_after then
      raise exception 'Player SR changed before clan reliability adjustment could be applied.';
    end if;

    update public.player_rating_events
    set
      rating_change = adjusted_change,
      rating_after = adjusted_after,
      calculation_version = calculation_version || '_RELIABILITY_V1',
      reliability_policy_version_id = terms_to_use.policy_version_id,
      attendance_outcome = event_to_adjust.attendance_outcome,
      reliability_multiplier_bps = reliability_multiplier,
      sr_protection_applied = reason_to_use is not null,
      sr_protection_reason = reason_to_use
    where id = event_to_adjust.event_id;

    update public.player_ratings
    set
      skill_rating = skill_rating + rating_delta,
      last_change = adjusted_change
    where profile_id = event_to_adjust.profile_id;

    update public.fixture_player_appearances
    set rating_change = adjusted_change
    where fixture_id = fixture_id_to_apply
      and profile_id = event_to_adjust.profile_id;

    if adjusted_change is distinct from original_change then
      adjusted_count := adjusted_count + 1;
    end if;
  end loop;

  return adjusted_count;
end;
$$;

create or replace function public.apply_clan_reliability_ratings_on_final()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'FINAL' and old.status is distinct from 'FINAL' then
    perform public.apply_clan_reliability_rating_adjustments(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists apply_clan_reliability_ratings_on_final
on public.fixtures;
create trigger apply_clan_reliability_ratings_on_final
after update of status on public.fixtures
for each row execute function public.apply_clan_reliability_ratings_on_final();

do $migration$
declare
  function_definition text;
  old_text text := $old$'calculation_version', event.calculation_version,$old$;
  new_text text := $new$'calculation_version', event.calculation_version,
        'reliability_policy_version_id', event.reliability_policy_version_id,
        'attendance_outcome', event.attendance_outcome,
        'reliability_multiplier_bps', event.reliability_multiplier_bps,
        'sr_protection_applied', event.sr_protection_applied,
        'sr_protection_reason', event.sr_protection_reason,$new$;
begin
  select pg_get_functiondef(
    'public.get_player_rating_history(uuid,integer)'::regprocedure
  ) into function_definition;
  if position('reliability_multiplier_bps' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not expose reliability metadata in Player SR history.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

create or replace function public.protect_shorthanded_period_evidence()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Shorthanded evidence cannot be deleted.';
  end if;
  if old.ended_match_second is not null then
    raise exception 'Completed shorthanded evidence is immutable.';
  end if;
  if new.id is distinct from old.id
    or new.terms_id is distinct from old.terms_id
    or new.match_kind is distinct from old.match_kind
    or new.fixture_id is distinct from old.fixture_id
    or new.open_queue_game_id is distinct from old.open_queue_game_id
    or new.side is distinct from old.side
    or new.reason is distinct from old.reason
    or new.caused_by_profile_id is distinct from old.caused_by_profile_id
    or new.started_match_second is distinct from old.started_match_second
    or new.recorded_by is distinct from old.recorded_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'Recorded shorthanded evidence cannot be rewritten.';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_shorthanded_period_evidence
on public.match_shorthanded_periods;
create trigger protect_shorthanded_period_evidence
before update or delete on public.match_shorthanded_periods
for each row execute function public.protect_shorthanded_period_evidence();

drop trigger if exists protect_verified_injuries_append_only
on public.match_verified_injuries;
create trigger protect_verified_injuries_append_only
before update or delete on public.match_verified_injuries
for each row execute function public.protect_append_only_reliability_rows();

drop trigger if exists protect_clan_reliability_outcomes_append_only
on public.clan_match_reliability_outcomes;
create trigger protect_clan_reliability_outcomes_append_only
before update or delete on public.clan_match_reliability_outcomes
for each row execute function public.protect_append_only_reliability_rows();

revoke all on function public.reliability_match_elapsed_seconds(text,uuid)
from public, anon, authenticated;
revoke all on function public.reliability_fixture_forfeit_score(uuid)
from public, anon, authenticated;
revoke all on function public.enforce_clan_reliability_final_cutoff()
from public, anon, authenticated;
revoke all on function public.validate_reliability_match_effect_row()
from public, anon, authenticated;
revoke all on function public.referee_start_shorthanded_period(
  uuid,text,uuid,text,text,uuid,text
) from public, anon, authenticated;
revoke all on function public.referee_end_shorthanded_period(
  uuid,uuid,uuid,text
) from public, anon, authenticated;
revoke all on function public.referee_record_verified_injury(
  uuid,text,uuid,uuid,boolean,boolean,boolean,text
) from public, anon, authenticated;
revoke all on function public.sync_fixture_reliability_expected_roster(uuid)
from public, anon, authenticated;
revoke all on function public.initialize_fixture_reliability_roster(uuid)
from public, anon, authenticated;
revoke all on function public.protect_fixture_reliability_roster_history()
from public, anon, authenticated;
revoke all on function public.initialize_scheduled_fixture_reliability_roster()
from public, anon, authenticated;
revoke all on function public.protect_fixture_teams_after_roster_snapshot()
from public, anon, authenticated;
revoke all on function public.release_suspended_player_future_clan_rosters(
  uuid,uuid,timestamptz
) from public, anon, authenticated;
revoke all on function public.release_clan_rosters_on_player_suspension()
from public, anon, authenticated;
revoke all on function public.set_fixture_reliability_roster(
  uuid,uuid,uuid[],text
) from public, anon;
revoke all on function public.active_clan_reliability_strikes(uuid,timestamptz)
from public, anon, authenticated;
revoke all on function public.record_clan_reliability_incident(
  uuid,uuid,text,integer,timestamptz
) from public, anon, authenticated;
revoke all on function public.clan_has_active_reliability_restriction(
  uuid,timestamptz
) from public, anon, authenticated;
revoke all on function public.enforce_clan_reliability_fixture_restriction()
from public, anon, authenticated;
revoke all on function public.finalize_clan_reliability_outcomes(uuid,uuid)
from public, anon, authenticated;
revoke all on function public.finalize_due_clan_reliability_attendance()
from public, anon, authenticated;
revoke all on function public.apply_open_queue_reliability_rating_adjustments(uuid)
from public, anon, authenticated;
revoke all on function public.apply_clan_reliability_rating_adjustments(uuid)
from public, anon, authenticated;
revoke all on function public.apply_clan_reliability_ratings_on_final()
from public, anon, authenticated;
revoke all on function public.protect_shorthanded_period_evidence()
from public, anon, authenticated;

grant execute on function public.referee_start_shorthanded_period(
  uuid,text,uuid,text,text,uuid,text
) to service_role;
grant execute on function public.referee_end_shorthanded_period(
  uuid,uuid,uuid,text
) to service_role;
grant execute on function public.referee_record_verified_injury(
  uuid,text,uuid,uuid,boolean,boolean,boolean,text
) to service_role;
grant execute on function public.set_fixture_reliability_roster(
  uuid,uuid,uuid[],text
) to authenticated, service_role;
grant execute on function public.finalize_due_clan_reliability_attendance()
to service_role;

comment on function public.set_fixture_reliability_roster(
  uuid,uuid,uuid[],text
) is
'Confirms the exact policy-sized clan roster before the hard check-in deadline and preserves every removal/replacement as history.';

comment on function public.apply_open_queue_reliability_rating_adjustments(uuid)
is
'Applies the kickoff policy snapshot to late-player SR, verified-injury outcomes, and referee-recorded qualifying shorthanded play after the base Player SR ledger is written.';

comment on function public.apply_clan_reliability_rating_adjustments(uuid)
is
'Applies the kickoff policy snapshot to clan participants in the shared Player SR ledger, including late-player multipliers and referee-recorded injury/shorthanded protection; Clan SR itself remains governed by the clan rating model.';
