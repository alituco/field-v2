-- Field moderation foundation: private reports, discipline, audited match
-- interventions, and server-side enforcement for play restrictions.

create table if not exists public.moderation_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_profile_id uuid references public.profiles(id) on delete set null,
  reporter_referee_id uuid references public.referee_profiles(profile_id)
    on delete set null,
  source text not null check (source in ('MOBILE', 'REFEREE', 'ADMIN')),
  subject_type text not null check (
    subject_type in ('PLAYER', 'CLAN', 'MATCH')
  ),
  subject_profile_id uuid references public.profiles(id) on delete set null,
  subject_clan_id uuid references public.clans(id) on delete set null,
  fixture_id uuid references public.fixtures(id) on delete set null,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete set null,
  category text not null check (
    category in (
      'HARASSMENT',
      'THREATS_OR_VIOLENCE',
      'DISCRIMINATION',
      'DANGEROUS_PLAY',
      'CHEATING',
      'NO_SHOW_OR_MATCH_MANIPULATION',
      'INAPPROPRIATE_CONTENT',
      'SAFETY_OR_VENUE',
      'SCORE_OR_RESULT',
      'REFEREE_ABUSE',
      'OTHER'
    )
  ),
  details text not null default '' check (char_length(details) <= 2000),
  replay_offset_seconds integer check (
    replay_offset_seconds between 0 and 10800
  ),
  priority text not null default 'NORMAL' check (
    priority in ('LOW', 'NORMAL', 'HIGH', 'URGENT')
  ),
  status text not null default 'OPEN' check (
    status in (
      'OPEN',
      'TRIAGED',
      'INVESTIGATING',
      'ACTIONED',
      'RESOLVED',
      'DISMISSED',
      'DUPLICATE'
    )
  ),
  assigned_admin_id uuid references public.referee_profiles(profile_id)
    on delete set null,
  resolution_note text check (char_length(resolution_note) <= 3000),
  resolved_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (reporter_profile_id is not null)::integer
      + (reporter_referee_id is not null)::integer <= 1
  ),
  check (
    (fixture_id is not null)::integer
      + (open_queue_game_id is not null)::integer <= 1
  ),
  check (
    (subject_type = 'PLAYER'
      and subject_profile_id is not null
      and subject_clan_id is null)
    or
    (subject_type = 'CLAN'
      and subject_profile_id is null
      and subject_clan_id is not null)
    or
    (subject_type = 'MATCH'
      and subject_profile_id is null
      and subject_clan_id is null
      and (
        (fixture_id is not null)::integer
          + (open_queue_game_id is not null)::integer = 1
      ))
  ),
  check (category <> 'OTHER' or char_length(trim(details)) >= 10),
  check (
    (status in ('ACTIONED', 'RESOLVED', 'DISMISSED', 'DUPLICATE')
      and resolved_at is not null)
    or
    (status not in ('ACTIONED', 'RESOLVED', 'DISMISSED', 'DUPLICATE')
      and resolved_at is null)
  )
);

drop trigger if exists set_moderation_reports_updated_at
on public.moderation_reports;
create trigger set_moderation_reports_updated_at
before update on public.moderation_reports
for each row execute function public.set_updated_at();

create index if not exists moderation_reports_queue_idx
on public.moderation_reports (status, priority, created_at desc);
create index if not exists moderation_reports_profile_subject_idx
on public.moderation_reports (subject_profile_id, created_at desc)
where subject_profile_id is not null;
create index if not exists moderation_reports_clan_subject_idx
on public.moderation_reports (subject_clan_id, created_at desc)
where subject_clan_id is not null;
create index if not exists moderation_reports_reporter_idx
on public.moderation_reports (reporter_profile_id, created_at desc)
where reporter_profile_id is not null;

create table if not exists public.moderation_report_notes (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.moderation_reports(id)
    on delete cascade,
  author_referee_id uuid not null
    references public.referee_profiles(profile_id) on delete restrict,
  note text not null check (char_length(trim(note)) between 2 and 3000),
  created_at timestamptz not null default now()
);

create table if not exists public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('PLAYER', 'CLAN')),
  subject_profile_id uuid references public.profiles(id) on delete restrict,
  subject_clan_id uuid references public.clans(id) on delete restrict,
  action_type text not null check (
    action_type in ('WARNING', 'SUSPENSION', 'BAN')
  ),
  restriction_scope text not null default 'NONE' check (
    restriction_scope in ('NONE', 'PLAY', 'ACCOUNT', 'SCHEDULING')
  ),
  reason_code text not null check (
    char_length(trim(reason_code)) between 2 and 80
  ),
  user_message text not null check (
    char_length(trim(user_message)) between 2 and 500
  ),
  private_note text not null default '' check (
    char_length(private_note) <= 3000
  ),
  source_report_id uuid references public.moderation_reports(id)
    on delete set null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  issued_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  revoked_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  revoked_at timestamptz,
  revocation_reason text check (char_length(revocation_reason) <= 1000),
  created_at timestamptz not null default now(),
  check (
    (subject_type = 'PLAYER'
      and subject_profile_id is not null
      and subject_clan_id is null)
    or
    (subject_type = 'CLAN'
      and subject_profile_id is null
      and subject_clan_id is not null)
  ),
  check (ends_at is null or ends_at > starts_at),
  check (action_type <> 'SUSPENSION' or ends_at is not null),
  check (
    (action_type = 'WARNING' and restriction_scope = 'NONE')
    or
    (
      subject_type = 'PLAYER'
      and action_type = 'SUSPENSION'
      and restriction_scope in ('PLAY', 'ACCOUNT')
    )
    or
    (
      subject_type = 'PLAYER'
      and action_type = 'BAN'
      and restriction_scope = 'ACCOUNT'
    )
    or
    (
      subject_type = 'CLAN'
      and action_type in ('SUSPENSION', 'BAN')
      and restriction_scope = 'SCHEDULING'
    )
  ),
  check (
    (revoked_at is null and revoked_by is null)
    or (revoked_at is not null and revoked_by is not null)
  )
);

create index if not exists moderation_actions_active_profile_idx
on public.moderation_actions (subject_profile_id, action_type, starts_at, ends_at)
where revoked_at is null and subject_profile_id is not null;
create index if not exists moderation_actions_active_clan_idx
on public.moderation_actions (subject_clan_id, action_type, starts_at, ends_at)
where revoked_at is null and subject_clan_id is not null;

create table if not exists public.moderation_appeals (
  id uuid primary key default gen_random_uuid(),
  action_id uuid not null references public.moderation_actions(id)
    on delete cascade,
  appellant_profile_id uuid not null references public.profiles(id)
    on delete cascade,
  message text not null check (char_length(trim(message)) between 10 and 2000),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'REVIEWING', 'UPHELD', 'OVERTURNED')
  ),
  reviewed_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  reviewed_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (action_id, appellant_profile_id)
);

drop trigger if exists set_moderation_appeals_updated_at
on public.moderation_appeals;
create trigger set_moderation_appeals_updated_at
before update on public.moderation_appeals
for each row execute function public.set_updated_at();

create table if not exists public.match_stoppages (
  id uuid primary key default gen_random_uuid(),
  match_kind text not null check (match_kind in ('CLAN', 'SOLO')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  stopped_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  mode text not null check (mode in ('TEMPORARY', 'ABANDON')),
  reason_code text not null check (
    reason_code in (
      'MEDICAL_EMERGENCY',
      'SERIOUS_INJURY',
      'FIGHTING_OR_VIOLENCE',
      'THREAT_TO_REFEREE',
      'UNSAFE_VENUE_OR_WEATHER',
      'CROWD_OR_SECURITY',
      'EQUIPMENT_OR_TECHNICAL_FAILURE',
      'INSUFFICIENT_PLAYERS',
      'TEAM_WALKOUT',
      'REFEREE_UNABLE_TO_CONTINUE',
      'OTHER'
    )
  ),
  note text not null default '' check (char_length(note) <= 2000),
  elapsed_seconds integer not null default 0 check (
    elapsed_seconds between 0 and 10800
  ),
  state text not null default 'PENDING_REVIEW' check (
    state in ('PENDING_REVIEW', 'RESOLVED')
  ),
  resolved_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  resolved_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 2000),
  created_at timestamptz not null default now(),
  check (
    (fixture_id is not null)::integer
      + (open_queue_game_id is not null)::integer = 1
  ),
  check (
    (match_kind = 'CLAN' and fixture_id is not null)
    or (match_kind = 'SOLO' and open_queue_game_id is not null)
  ),
  check (reason_code <> 'OTHER' or char_length(trim(note)) >= 10)
);

create index if not exists match_stoppages_attention_idx
on public.match_stoppages (state, created_at desc);

create table if not exists public.match_score_revisions (
  id uuid primary key default gen_random_uuid(),
  match_kind text not null check (match_kind in ('CLAN', 'SOLO')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  previous_home_score integer not null check (previous_home_score >= 0),
  previous_away_score integer not null check (previous_away_score >= 0),
  revised_home_score integer not null check (revised_home_score >= 0),
  revised_away_score integer not null check (revised_away_score >= 0),
  reason text not null check (char_length(trim(reason)) between 10 and 2000),
  rating_policy text not null default 'PRESERVE_APPLIED_SR' check (
    rating_policy = 'PRESERVE_APPLIED_SR'
  ),
  revised_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  created_at timestamptz not null default now(),
  check (
    (fixture_id is not null)::integer
      + (open_queue_game_id is not null)::integer = 1
  )
);

create table if not exists public.admin_audit_events (
  id bigint generated by default as identity primary key,
  actor_referee_id uuid not null
    references public.referee_profiles(profile_id) on delete restrict,
  action text not null check (char_length(trim(action)) between 2 and 100),
  entity_type text not null check (
    entity_type in ('REPORT', 'PLAYER', 'CLAN', 'CLAN_MATCH', 'SOLO_MATCH', 'ACTION')
  ),
  entity_id uuid not null,
  reason text not null default '' check (char_length(reason) <= 2000),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_events_created_idx
on public.admin_audit_events (created_at desc);
create index if not exists admin_audit_events_entity_idx
on public.admin_audit_events (entity_type, entity_id, created_at desc);

alter table public.moderation_reports enable row level security;
alter table public.moderation_report_notes enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.moderation_appeals enable row level security;
alter table public.match_stoppages enable row level security;
alter table public.match_score_revisions enable row level security;
alter table public.admin_audit_events enable row level security;

revoke all on table public.moderation_reports from anon, authenticated;
revoke all on table public.moderation_report_notes from anon, authenticated;
revoke all on table public.moderation_actions from anon, authenticated;
revoke all on table public.moderation_appeals from anon, authenticated;
revoke all on table public.match_stoppages from anon, authenticated;
revoke all on table public.match_score_revisions from anon, authenticated;
revoke all on table public.admin_audit_events from anon, authenticated;

grant all on table public.moderation_reports to service_role;
grant all on table public.moderation_report_notes to service_role;
grant all on table public.moderation_actions to service_role;
grant all on table public.moderation_appeals to service_role;
grant all on table public.match_stoppages to service_role;
grant all on table public.match_score_revisions to service_role;
grant all on table public.admin_audit_events to service_role;
grant usage, select on sequence public.admin_audit_events_id_seq to service_role;

-- Solo cancellations need the same operational evidence as clan fixtures and
-- a real full-refund state for platform-initiated cancellations.
alter table public.open_queue_games
add column if not exists cancellation_code text,
add column if not exists cancellation_reason text,
add column if not exists cancelled_at timestamptz,
add column if not exists cancelled_by uuid,
add column if not exists cancellation_context jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'open_queue_games_cancelled_by_fkey'
  ) then
    alter table public.open_queue_games
    add constraint open_queue_games_cancelled_by_fkey
    foreign key (cancelled_by) references public.profiles(id) on delete set null;
  end if;
end;
$$;

alter table public.open_queue_games
drop constraint if exists open_queue_games_cancellation_code_check;
alter table public.open_queue_games
add constraint open_queue_games_cancellation_code_check check (
  cancellation_code is null
  or cancellation_code in (
    'WEATHER_OR_VENUE',
    'SAFETY',
    'NO_REFEREE',
    'INSUFFICIENT_PLAYERS',
    'TECHNICAL',
    'MATCH_ABANDONED',
    'ADMIN_DECISION',
    'OTHER'
  )
);

alter table public.open_queue_games
drop constraint if exists open_queue_games_cancellation_details_check;
alter table public.open_queue_games
add constraint open_queue_games_cancellation_details_check check (
  (
    status = 'CANCELLED'
    and cancellation_code is not null
    and cancellation_reason is not null
    and cancelled_at is not null
  )
  or
  (
    status <> 'CANCELLED'
    and cancellation_code is null
    and cancellation_reason is null
    and cancelled_at is null
    and cancelled_by is null
  )
);

alter table public.open_queue_bookings
drop constraint if exists open_queue_bookings_refund_percent_check;
alter table public.open_queue_bookings
add constraint open_queue_bookings_refund_percent_check
check (refund_percent in (0, 50, 100));

alter table public.open_queue_bookings
drop constraint if exists open_queue_bookings_payment_status_check;
alter table public.open_queue_bookings
add constraint open_queue_bookings_payment_status_check
check (
  payment_status in ('PAID', 'PARTIALLY_REFUNDED', 'REFUNDED', 'NO_REFUND')
);

alter table public.open_queue_bookings
drop constraint if exists open_queue_bookings_refund_status_check;
alter table public.open_queue_bookings
add constraint open_queue_bookings_refund_status_check
check (refund_status in ('NOT_DUE', 'DUE', 'PROCESSING', 'PROCESSED', 'FAILED'));

-- Stoppages and official score corrections are visible in the normal match
-- timeline without exposing the private moderation case.
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
    'CORRECTION'
  )
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
    'CORRECTION'
  )
);

-- Existing cancellation codes are kept; these cover human/admin operations.
alter table public.fixtures
drop constraint if exists fixtures_cancellation_code_check;
alter table public.fixtures
add constraint fixtures_cancellation_code_check check (
  cancellation_code is null
  or cancellation_code in (
    'NO_OPPONENT_24H',
    'CLAN_ARCHIVED',
    'SLOT_CONFLICT_MIGRATION',
    'ADMIN_CANCELLED',
    'WEATHER_OR_VENUE',
    'SAFETY',
    'NO_REFEREE',
    'INSUFFICIENT_PLAYERS',
    'TECHNICAL',
    'MATCH_ABANDONED',
    'ADMIN_DECISION',
    'LEGACY_OTHER'
  )
);

create or replace function public.is_active_moderation_admin(
  profile_id_to_check uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.referee_profiles referee
    where referee.profile_id = profile_id_to_check
      and referee.role = 'admin'
      and referee.is_active
  );
$$;

create or replace function public.profile_has_active_play_restriction(
  profile_id_to_check uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.moderation_actions action
    where action.subject_type = 'PLAYER'
      and action.subject_profile_id = profile_id_to_check
      and action.action_type in ('SUSPENSION', 'BAN')
      and action.restriction_scope in ('PLAY', 'ACCOUNT')
      and action.revoked_at is null
      and action.starts_at <= now()
      and (action.ends_at is null or action.ends_at > now())
  );
$$;

create or replace function public.clan_has_active_play_restriction(
  clan_id_to_check uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.moderation_actions action
    where action.subject_type = 'CLAN'
      and action.subject_clan_id = clan_id_to_check
      and action.action_type in ('SUSPENSION', 'BAN')
      and action.restriction_scope = 'SCHEDULING'
      and action.revoked_at is null
      and action.starts_at <= now()
      and (action.ends_at is null or action.ends_at > now())
  );
$$;

create or replace function public.enforce_profile_play_restriction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'CONFIRMED'
      and public.profile_has_active_play_restriction(new.profile_id)
    then
      raise exception 'This player is currently suspended from Field matches.';
    end if;
  elsif new.status = 'CONFIRMED'
    and (
      old.status is distinct from 'CONFIRMED'
      or (coalesce(new.played, false) and not coalesce(old.played, false))
    )
    and public.profile_has_active_play_restriction(new.profile_id)
  then
    raise exception 'This player is currently suspended from Field matches.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_open_queue_play_restriction
on public.open_queue_bookings;
create trigger enforce_open_queue_play_restriction
before insert or update of status, played
on public.open_queue_bookings
for each row execute function public.enforce_profile_play_restriction();

create or replace function public.enforce_fixture_appearance_restriction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.played
      and public.profile_has_active_play_restriction(new.profile_id)
    then
      raise exception 'This player is currently suspended from Field matches.';
    end if;
  elsif new.played
    and not coalesce(old.played, false)
    and public.profile_has_active_play_restriction(new.profile_id)
  then
    raise exception 'This player is currently suspended from Field matches.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_fixture_appearance_restriction
on public.fixture_player_appearances;
create trigger enforce_fixture_appearance_restriction
before insert or update of played
on public.fixture_player_appearances
for each row execute function public.enforce_fixture_appearance_restriction();

create or replace function public.enforce_clan_play_restriction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('OPEN', 'SCHEDULED', 'LIVE')
    and (
      public.clan_has_active_play_restriction(new.home_clan_id)
      or (
        new.away_clan_id is not null
        and public.clan_has_active_play_restriction(new.away_clan_id)
      )
    )
  then
    raise exception 'A participating clan is currently suspended from matches.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_clan_play_restriction on public.fixtures;
create trigger enforce_clan_play_restriction
before insert or update of status, home_clan_id, away_clan_id
on public.fixtures
for each row execute function public.enforce_clan_play_restriction();

-- Protect competitive fields from broad legacy clan-manager UPDATE grants.
create or replace function public.protect_clan_competitive_fields()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user = 'authenticated'
    and (
      new.skill_rating is distinct from old.skill_rating
      or new.wins is distinct from old.wins
      or new.losses is distinct from old.losses
    )
  then
    raise exception 'Competitive clan records are referee-controlled.';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_clan_competitive_fields on public.clans;
create trigger protect_clan_competitive_fields
before update on public.clans
for each row execute function public.protect_clan_competitive_fields();

-- Old client-authoritative score paths must not remain executable.
revoke all on function public.complete_fixture(uuid, integer, integer)
from public, anon, authenticated;
grant execute on function public.complete_fixture(uuid, integer, integer)
to service_role;
drop policy if exists "Clan owners can insert fixture scorers"
on public.fixture_scorers;
drop policy if exists "Clan owners can update fixture scorers"
on public.fixture_scorers;
drop policy if exists "Clan owners can delete fixture scorers"
on public.fixture_scorers;

create or replace function public.submit_moderation_report(
  subject_type_to_use text,
  subject_id_to_use uuid,
  category_to_use text,
  details_to_use text default null,
  fixture_id_to_use uuid default null,
  open_queue_game_id_to_use uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  reporter_id uuid := auth.uid();
  normalized_subject text := upper(trim(coalesce(subject_type_to_use, '')));
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  subject_profile uuid;
  subject_clan uuid;
  report_priority text;
  report_id uuid;
  reports_today integer;
  subject_in_context boolean := true;
begin
  if reporter_id is null then
    raise exception 'You need to sign in again.';
  end if;

  if normalized_subject not in ('PLAYER', 'CLAN', 'MATCH') then
    raise exception 'Choose a player, clan, or match to report.';
  end if;

  if normalized_category not in (
    'HARASSMENT',
    'THREATS_OR_VIOLENCE',
    'DISCRIMINATION',
    'DANGEROUS_PLAY',
    'CHEATING',
    'NO_SHOW_OR_MATCH_MANIPULATION',
    'INAPPROPRIATE_CONTENT',
    'SAFETY_OR_VENUE',
    'SCORE_OR_RESULT',
    'OTHER'
  ) then
    raise exception 'Choose a valid report reason.';
  end if;

  if char_length(normalized_details) > 2000
    or (normalized_category = 'OTHER' and char_length(normalized_details) < 10)
  then
    raise exception 'Add a short explanation of what happened.';
  end if;

  if (fixture_id_to_use is not null)::integer
    + (open_queue_game_id_to_use is not null)::integer > 1 then
    raise exception 'A report can reference only one match.';
  end if;

  select count(*)::integer into reports_today
  from public.moderation_reports report
  where report.reporter_profile_id = reporter_id
    and report.created_at >= now() - interval '24 hours';

  if reports_today >= 5 then
    raise exception 'You have reached today''s report limit. Contact support for an urgent safety issue.';
  end if;

  if normalized_subject = 'PLAYER' then
    if subject_id_to_use = reporter_id then
      raise exception 'You cannot report your own profile.';
    end if;
    if not exists (
      select 1 from public.profiles profile where profile.id = subject_id_to_use
    ) then
      raise exception 'That player could not be found.';
    end if;
    subject_profile := subject_id_to_use;
  elsif normalized_subject = 'CLAN' then
    if not exists (
      select 1 from public.clans clan where clan.id = subject_id_to_use
    ) then
      raise exception 'That clan could not be found.';
    end if;
    subject_clan := subject_id_to_use;
  else
    if fixture_id_to_use is null and open_queue_game_id_to_use is null then
      raise exception 'Choose the match where the issue happened.';
    end if;
    if fixture_id_to_use is not null
      and fixture_id_to_use is distinct from subject_id_to_use then
      raise exception 'The reported match does not match its context.';
    end if;
    if open_queue_game_id_to_use is not null
      and open_queue_game_id_to_use is distinct from subject_id_to_use then
      raise exception 'The reported match does not match its context.';
    end if;
  end if;

  if fixture_id_to_use is not null then
    if not exists (
      select 1 from public.fixtures fixture where fixture.id = fixture_id_to_use
    ) then
      raise exception 'That match could not be found.';
    end if;

    if normalized_subject = 'PLAYER' then
      select exists (
        select 1
        from public.fixture_player_appearances appearance
        where appearance.fixture_id = fixture_id_to_use
          and appearance.profile_id = subject_profile
      ) into subject_in_context;
    elsif normalized_subject = 'CLAN' then
      select exists (
        select 1
        from public.fixtures fixture
        where fixture.id = fixture_id_to_use
          and subject_clan in (fixture.home_clan_id, fixture.away_clan_id)
      ) into subject_in_context;
    end if;
  elsif open_queue_game_id_to_use is not null then
    if not exists (
      select 1 from public.open_queue_games game
      where game.id = open_queue_game_id_to_use
    ) then
      raise exception 'That solo match could not be found.';
    end if;

    if normalized_subject = 'CLAN' then
      subject_in_context := false;
    elsif normalized_subject = 'PLAYER' then
      select exists (
        select 1
        from public.open_queue_bookings booking
        where booking.game_id = open_queue_game_id_to_use
          and booking.profile_id = subject_profile
      ) into subject_in_context;
    end if;
  end if;

  if not subject_in_context then
    raise exception 'That player or clan was not part of this match.';
  end if;

  if exists (
    select 1
    from public.moderation_reports report
    where report.reporter_profile_id = reporter_id
      and report.subject_type = normalized_subject
      and report.subject_profile_id is not distinct from subject_profile
      and report.subject_clan_id is not distinct from subject_clan
      and report.fixture_id is not distinct from fixture_id_to_use
      and report.open_queue_game_id is not distinct from open_queue_game_id_to_use
      and report.category = normalized_category
      and report.status not in ('DISMISSED', 'DUPLICATE')
      and report.created_at >= now() - interval '7 days'
  ) then
    raise exception 'You already reported this issue. Our team can see it.';
  end if;

  report_priority := case
    when normalized_category in (
      'THREATS_OR_VIOLENCE',
      'DISCRIMINATION',
      'SAFETY_OR_VENUE'
    ) then 'HIGH'
    else 'NORMAL'
  end;

  insert into public.moderation_reports (
    reporter_profile_id,
    source,
    subject_type,
    subject_profile_id,
    subject_clan_id,
    fixture_id,
    open_queue_game_id,
    category,
    details,
    priority
  ) values (
    reporter_id,
    'MOBILE',
    normalized_subject,
    subject_profile,
    subject_clan,
    fixture_id_to_use,
    open_queue_game_id_to_use,
    normalized_category,
    normalized_details,
    report_priority
  ) returning id into report_id;

  return report_id;
end;
$$;

create or replace function public.get_my_moderation_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  user_id uuid := auth.uid();
  active_action record;
  warning_count integer;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select action.action_type, action.restriction_scope, action.reason_code,
    action.user_message, action.starts_at, action.ends_at
  into active_action
  from public.moderation_actions action
  where action.subject_type = 'PLAYER'
    and action.subject_profile_id = user_id
    and action.action_type in ('SUSPENSION', 'BAN')
    and action.revoked_at is null
    and action.starts_at <= now()
    and (action.ends_at is null or action.ends_at > now())
  order by
    case action.action_type when 'BAN' then 0 else 1 end,
    action.created_at desc
  limit 1;

  select count(*)::integer into warning_count
  from public.moderation_actions action
  where action.subject_type = 'PLAYER'
    and action.subject_profile_id = user_id
    and action.action_type = 'WARNING'
    and action.revoked_at is null;

  return jsonb_build_object(
    'state', case
      when active_action.action_type = 'BAN' then 'BANNED'
      when active_action.action_type = 'SUSPENSION' then 'SUSPENDED'
      when warning_count > 0 then 'WARNING'
      else 'ACTIVE'
    end,
    'scope', active_action.restriction_scope,
    'reason_code', active_action.reason_code,
    'message', active_action.user_message,
    'starts_at', active_action.starts_at,
    'ends_at', active_action.ends_at,
    'warning_count', coalesce(warning_count, 0)
  );
end;
$$;

create or replace function public.submit_referee_moderation_report(
  reporter_referee_id_to_use uuid,
  subject_type_to_use text,
  subject_id_to_use uuid,
  category_to_use text,
  details_to_use text,
  priority_to_use text default 'HIGH',
  fixture_id_to_use uuid default null,
  open_queue_game_id_to_use uuid default null,
  replay_offset_seconds_to_use integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_subject text := upper(trim(coalesce(subject_type_to_use, '')));
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  normalized_priority text := upper(trim(coalesce(priority_to_use, 'HIGH')));
  normalized_details text := trim(coalesce(details_to_use, ''));
  referee_is_admin boolean;
  has_match_access boolean;
  subject_profile uuid;
  subject_clan uuid;
  report_id uuid;
begin
  select referee.role = 'admin'
  into referee_is_admin
  from public.referee_profiles referee
  where referee.profile_id = reporter_referee_id_to_use
    and referee.is_active;

  if referee_is_admin is null then
    raise exception 'This account is not an active referee.';
  end if;

  if (fixture_id_to_use is not null)::integer
    + (open_queue_game_id_to_use is not null)::integer <> 1 then
    raise exception 'A referee report must reference one assigned match.';
  end if;

  select referee_is_admin or exists (
    select 1
    from public.fixture_referee_assignments assignment
    where fixture_id_to_use is not null
      and assignment.fixture_id = fixture_id_to_use
      and assignment.referee_id = reporter_referee_id_to_use
    union all
    select 1
    from public.open_queue_referee_assignments assignment
    where open_queue_game_id_to_use is not null
      and assignment.game_id = open_queue_game_id_to_use
      and assignment.referee_id = reporter_referee_id_to_use
  ) into has_match_access;

  if not has_match_access then
    raise exception 'You can report only an assigned match.';
  end if;

  if normalized_subject not in ('PLAYER', 'CLAN', 'MATCH') then
    raise exception 'Choose a player, clan, or match to report.';
  end if;
  if normalized_category not in (
    'HARASSMENT', 'THREATS_OR_VIOLENCE', 'DISCRIMINATION',
    'DANGEROUS_PLAY', 'CHEATING', 'NO_SHOW_OR_MATCH_MANIPULATION',
    'INAPPROPRIATE_CONTENT', 'SAFETY_OR_VENUE', 'SCORE_OR_RESULT',
    'REFEREE_ABUSE', 'OTHER'
  ) then
    raise exception 'Choose a valid report reason.';
  end if;
  if normalized_priority not in ('LOW', 'NORMAL', 'HIGH', 'URGENT') then
    raise exception 'Choose a valid report priority.';
  end if;
  if char_length(normalized_details) > 2000
    or (normalized_category = 'OTHER' and char_length(normalized_details) < 10)
  then
    raise exception 'Add a short explanation of what happened.';
  end if;

  if normalized_subject = 'PLAYER' then
    subject_profile := subject_id_to_use;
    if fixture_id_to_use is not null and not exists (
      select 1 from public.fixture_player_appearances appearance
      where appearance.fixture_id = fixture_id_to_use
        and appearance.profile_id = subject_profile
    ) then
      raise exception 'That player is not in this match lineup.';
    end if;
    if open_queue_game_id_to_use is not null and not exists (
      select 1 from public.open_queue_bookings booking
      where booking.game_id = open_queue_game_id_to_use
        and booking.profile_id = subject_profile
    ) then
      raise exception 'That player is not in this match lineup.';
    end if;
  elsif normalized_subject = 'CLAN' then
    if open_queue_game_id_to_use is not null then
      raise exception 'Solo teams are not clans.';
    end if;
    subject_clan := subject_id_to_use;
    if not exists (
      select 1 from public.fixtures fixture
      where fixture.id = fixture_id_to_use
        and subject_clan in (fixture.home_clan_id, fixture.away_clan_id)
    ) then
      raise exception 'That clan is not part of this match.';
    end if;
  else
    if subject_id_to_use is distinct from coalesce(
      fixture_id_to_use,
      open_queue_game_id_to_use
    ) then
      raise exception 'The reported match does not match its context.';
    end if;
  end if;

  insert into public.moderation_reports (
    reporter_referee_id,
    source,
    subject_type,
    subject_profile_id,
    subject_clan_id,
    fixture_id,
    open_queue_game_id,
    category,
    details,
    replay_offset_seconds,
    priority
  ) values (
    reporter_referee_id_to_use,
    'REFEREE',
    normalized_subject,
    subject_profile,
    subject_clan,
    fixture_id_to_use,
    open_queue_game_id_to_use,
    normalized_category,
    normalized_details,
    replay_offset_seconds_to_use,
    normalized_priority
  ) returning id into report_id;

  return report_id;
end;
$$;

create or replace function public.admin_update_moderation_report(
  actor_admin_id uuid,
  report_id_to_update uuid,
  action_to_take text,
  resolution_note_to_use text default null
)
returns public.moderation_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_action text := upper(trim(coalesce(action_to_take, '')));
  report_before public.moderation_reports%rowtype;
  report_after public.moderation_reports%rowtype;
  next_status text;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;

  select * into report_before
  from public.moderation_reports report
  where report.id = report_id_to_update
  for update;

  if report_before.id is null then
    raise exception 'Report not found.';
  end if;

  next_status := case normalized_action
    when 'TRIAGE' then 'TRIAGED'
    when 'INVESTIGATE' then 'INVESTIGATING'
    when 'RESOLVE' then 'RESOLVED'
    when 'DISMISS' then 'DISMISSED'
    when 'DUPLICATE' then 'DUPLICATE'
    else null
  end;
  if next_status is null then
    raise exception 'Choose a valid report action.';
  end if;
  if next_status in ('RESOLVED', 'DISMISSED', 'DUPLICATE')
    and char_length(trim(coalesce(resolution_note_to_use, ''))) < 3 then
    raise exception 'Add a short resolution note.';
  end if;

  update public.moderation_reports
  set
    status = next_status,
    assigned_admin_id = case
      when next_status in ('TRIAGED', 'INVESTIGATING') then actor_admin_id
      else assigned_admin_id
    end,
    resolution_note = case
      when next_status in ('RESOLVED', 'DISMISSED', 'DUPLICATE')
        then trim(resolution_note_to_use)
      else resolution_note
    end,
    resolved_by = case
      when next_status in ('RESOLVED', 'DISMISSED', 'DUPLICATE')
        then actor_admin_id
      else null
    end,
    resolved_at = case
      when next_status in ('RESOLVED', 'DISMISSED', 'DUPLICATE') then now()
      else null
    end
  where id = report_id_to_update
  returning * into report_after;

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
    'REPORT_' || normalized_action,
    'REPORT',
    report_id_to_update,
    trim(coalesce(resolution_note_to_use, '')),
    to_jsonb(report_before),
    to_jsonb(report_after)
  );

  return report_after;
end;
$$;

create or replace function public.admin_apply_moderation_action(
  actor_admin_id uuid,
  subject_type_to_use text,
  subject_id_to_use uuid,
  action_type_to_use text,
  reason_code_to_use text,
  user_message_to_use text,
  private_note_to_use text default null,
  ends_at_to_use timestamptz default null,
  report_id_to_use uuid default null,
  restriction_scope_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_subject text := upper(trim(coalesce(subject_type_to_use, '')));
  normalized_action text := upper(trim(coalesce(action_type_to_use, '')));
  normalized_scope text := upper(trim(coalesce(
    restriction_scope_to_use,
    case
      when normalized_action = 'WARNING' then 'NONE'
      when normalized_subject = 'CLAN' then 'SCHEDULING'
      when normalized_action = 'BAN' then 'ACCOUNT'
      else 'PLAY'
    end
  )));
  subject_profile uuid;
  subject_clan uuid;
  action_id uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_subject not in ('PLAYER', 'CLAN') then
    raise exception 'Choose a player or clan.';
  end if;
  if normalized_action not in ('WARNING', 'SUSPENSION', 'BAN') then
    raise exception 'Choose a warning, suspension, or ban.';
  end if;
  if normalized_scope not in ('NONE', 'PLAY', 'ACCOUNT', 'SCHEDULING') then
    raise exception 'Choose a valid restriction scope.';
  end if;
  if normalized_action = 'WARNING' and normalized_scope <> 'NONE' then
    raise exception 'Warnings cannot restrict an account.';
  end if;
  if normalized_subject = 'PLAYER' and (
    (normalized_action = 'SUSPENSION' and normalized_scope not in ('PLAY', 'ACCOUNT'))
    or (normalized_action = 'BAN' and normalized_scope <> 'ACCOUNT')
  ) then
    raise exception 'Choose a valid player restriction.';
  end if;
  if normalized_subject = 'CLAN'
    and normalized_action <> 'WARNING'
    and normalized_scope <> 'SCHEDULING' then
    raise exception 'Clan restrictions apply to scheduling.';
  end if;
  if char_length(trim(coalesce(reason_code_to_use, ''))) < 2
    or char_length(trim(coalesce(user_message_to_use, ''))) < 2 then
    raise exception 'A reason and player-facing message are required.';
  end if;
  if normalized_action = 'SUSPENSION'
    and (ends_at_to_use is null or ends_at_to_use <= now()) then
    raise exception 'Choose when the suspension ends.';
  end if;

  if normalized_subject = 'PLAYER' then
    if not exists (
      select 1 from public.profiles profile where profile.id = subject_id_to_use
    ) then
      raise exception 'Player not found.';
    end if;
    subject_profile := subject_id_to_use;
  else
    if not exists (
      select 1 from public.clans clan where clan.id = subject_id_to_use
    ) then
      raise exception 'Clan not found.';
    end if;
    subject_clan := subject_id_to_use;
  end if;

  if report_id_to_use is not null and not exists (
    select 1 from public.moderation_reports report
    where report.id = report_id_to_use
      and report.subject_type = normalized_subject
      and report.subject_profile_id is not distinct from subject_profile
      and report.subject_clan_id is not distinct from subject_clan
  ) then
    raise exception 'The source report does not match this subject.';
  end if;

  insert into public.moderation_actions (
    subject_type,
    subject_profile_id,
    subject_clan_id,
    action_type,
    restriction_scope,
    reason_code,
    user_message,
    private_note,
    source_report_id,
    ends_at,
    issued_by
  ) values (
    normalized_subject,
    subject_profile,
    subject_clan,
    normalized_action,
    normalized_scope,
    upper(trim(reason_code_to_use)),
    trim(user_message_to_use),
    trim(coalesce(private_note_to_use, '')),
    report_id_to_use,
    case when normalized_action = 'SUSPENSION' then ends_at_to_use else null end,
    actor_admin_id
  ) returning id into action_id;

  if report_id_to_use is not null then
    update public.moderation_reports
    set
      status = 'ACTIONED',
      assigned_admin_id = actor_admin_id,
      resolved_by = actor_admin_id,
      resolved_at = now(),
      resolution_note = coalesce(
        nullif(trim(user_message_to_use), ''),
        'Moderation action applied.'
      )
    where id = report_id_to_use;
  end if;

  insert into public.admin_audit_events (
    actor_referee_id,
    action,
    entity_type,
    entity_id,
    reason,
    after_state
  ) values (
    actor_admin_id,
    'MODERATION_' || normalized_action,
    normalized_subject,
    subject_id_to_use,
    trim(coalesce(private_note_to_use, user_message_to_use)),
    jsonb_build_object(
      'moderation_action_id', action_id,
      'action_type', normalized_action,
      'restriction_scope', normalized_scope,
      'ends_at', ends_at_to_use,
      'source_report_id', report_id_to_use
    )
  );

  return action_id;
end;
$$;

create or replace function public.admin_revoke_moderation_action(
  actor_admin_id uuid,
  action_id_to_revoke uuid,
  reason_to_use text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  action_before public.moderation_actions%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if char_length(trim(coalesce(reason_to_use, ''))) < 3 then
    raise exception 'Add a revocation reason.';
  end if;

  select * into action_before
  from public.moderation_actions action
  where action.id = action_id_to_revoke
  for update;
  if action_before.id is null then
    raise exception 'Moderation action not found.';
  end if;
  if action_before.revoked_at is not null then
    raise exception 'This action is already revoked.';
  end if;

  update public.moderation_actions
  set
    revoked_by = actor_admin_id,
    revoked_at = now(),
    revocation_reason = trim(reason_to_use)
  where id = action_id_to_revoke;

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
    'MODERATION_REVOKED',
    'ACTION',
    action_id_to_revoke,
    trim(reason_to_use),
    to_jsonb(action_before),
    jsonb_build_object('revoked_at', now(), 'revoked_by', actor_admin_id)
  );
end;
$$;

create or replace function public.admin_cancel_match(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_cancel uuid,
  reason_code_to_use text,
  reason_to_use text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_code text := upper(trim(coalesce(reason_code_to_use, '')));
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  fixture_before public.fixtures%rowtype;
  game_before public.open_queue_games%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if char_length(normalized_reason) < 5 then
    raise exception 'Add a clear cancellation reason.';
  end if;
  if normalized_code not in (
    'WEATHER_OR_VENUE', 'SAFETY', 'NO_REFEREE',
    'INSUFFICIENT_PLAYERS', 'TECHNICAL', 'ADMIN_DECISION', 'OTHER'
  ) then
    raise exception 'Choose a valid cancellation reason.';
  end if;

  if normalized_kind = 'CLAN' then
    select * into fixture_before
    from public.fixtures fixture
    where fixture.id = match_id_to_cancel
    for update;
    if fixture_before.id is null then raise exception 'Match not found.'; end if;
    if fixture_before.status = 'FINAL' then
      raise exception 'Final matches cannot be cancelled. Correct the official score instead.';
    end if;
    if fixture_before.status = 'CANCELLED' then
      raise exception 'This match is already cancelled.';
    end if;

    update public.fixtures
    set
      status = 'CANCELLED',
      cancellation_code = case
        when normalized_code = 'OTHER' then 'ADMIN_CANCELLED'
        else normalized_code
      end,
      cancellation_reason = normalized_reason,
      cancelled_at = now(),
      cancelled_by = actor_admin_id,
      cancellation_context = jsonb_build_object(
        'source', 'ADMIN_PANEL',
        'previous_status', fixture_before.status
      )
    where id = match_id_to_cancel;

    update public.fixture_clock_states
    set status = 'ENDED', started_at = null
    where fixture_id = match_id_to_cancel;
    update public.fixture_blue_cards
    set status = 'CLEARED'
    where fixture_id = match_id_to_cancel and status = 'ACTIVE';
  else
    select * into game_before
    from public.open_queue_games game
    where game.id = match_id_to_cancel
    for update;
    if game_before.id is null then raise exception 'Solo match not found.'; end if;
    if game_before.status = 'FINAL' then
      raise exception 'Final matches cannot be cancelled. Correct the official score instead.';
    end if;
    if game_before.status = 'CANCELLED' then
      raise exception 'This match is already cancelled.';
    end if;

    update public.open_queue_games
    set
      status = 'CANCELLED',
      cancellation_code = normalized_code,
      cancellation_reason = normalized_reason,
      cancelled_at = now(),
      cancelled_by = actor_admin_id,
      cancellation_context = jsonb_build_object(
        'source', 'ADMIN_PANEL',
        'previous_status', game_before.status,
        'refund_percent', 100
      )
    where id = match_id_to_cancel;

    update public.open_queue_bookings
    set
      status = 'CANCELLED',
      team = null,
      played = false,
      rating_at_team_assignment = null,
      rating_at_match_start = null,
      rating_change = null,
      cancelled_at = now(),
      refund_percent = 100,
      refund_amount_fils = amount_paid_fils,
      refund_status = 'PROCESSED',
      payment_status = 'REFUNDED'
    where game_id = match_id_to_cancel
      and status = 'CONFIRMED';

    update public.open_queue_clock_states
    set status = 'ENDED', started_at = null
    where game_id = match_id_to_cancel;
    update public.open_queue_blue_cards
    set status = 'CLEARED'
    where game_id = match_id_to_cancel and status = 'ACTIVE';
  end if;

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
    'MATCH_CANCELLED',
    case when normalized_kind = 'CLAN' then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_cancel,
    normalized_reason,
    case
      when normalized_kind = 'CLAN' then to_jsonb(fixture_before)
      else to_jsonb(game_before)
    end,
    jsonb_build_object(
      'status', 'CANCELLED',
      'reason_code', normalized_code,
      'solo_refund_percent', case when normalized_kind = 'SOLO' then 100 else null end
    )
  );
end;
$$;

create or replace function public.referee_record_match_stoppage(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_stop uuid,
  mode_to_use text,
  reason_code_to_use text,
  note_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_mode text := upper(trim(coalesce(mode_to_use, '')));
  normalized_reason text := upper(trim(coalesce(reason_code_to_use, '')));
  normalized_note text := trim(coalesce(note_to_use, ''));
  referee_is_admin boolean;
  has_access boolean;
  clock_started_at timestamptz;
  accumulated integer := 0;
  elapsed integer := 0;
  event_minute integer := 0;
  event_second integer := 0;
  stoppage_id uuid;
begin
  select referee.role = 'admin'
  into referee_is_admin
  from public.referee_profiles referee
  where referee.profile_id = actor_referee_id
    and referee.is_active;
  if referee_is_admin is null then
    raise exception 'This account is not an active referee.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if normalized_mode not in ('TEMPORARY', 'ABANDON') then
    raise exception 'Choose a temporary stop or abandonment.';
  end if;
  if normalized_reason not in (
    'MEDICAL_EMERGENCY', 'SERIOUS_INJURY', 'FIGHTING_OR_VIOLENCE',
    'THREAT_TO_REFEREE', 'UNSAFE_VENUE_OR_WEATHER',
    'CROWD_OR_SECURITY', 'EQUIPMENT_OR_TECHNICAL_FAILURE',
    'INSUFFICIENT_PLAYERS', 'TEAM_WALKOUT',
    'REFEREE_UNABLE_TO_CONTINUE', 'OTHER'
  ) then
    raise exception 'Choose why the game was stopped.';
  end if;
  if normalized_reason = 'OTHER' and char_length(normalized_note) < 10 then
    raise exception 'Explain why the game was stopped.';
  end if;

  if normalized_kind = 'CLAN' then
    select referee_is_admin or exists (
      select 1 from public.fixture_referee_assignments assignment
      where assignment.fixture_id = match_id_to_stop
        and assignment.referee_id = actor_referee_id
    ) into has_access;
    if not has_access then raise exception 'This match is not assigned to you.'; end if;
    if not exists (
      select 1 from public.fixtures fixture
      where fixture.id = match_id_to_stop and fixture.status = 'LIVE'
    ) then
      raise exception 'Only a live match can be stopped.';
    end if;

    select clock.started_at, clock.accumulated_seconds
    into clock_started_at, accumulated
    from public.fixture_clock_states clock
    where clock.fixture_id = match_id_to_stop;
  else
    select referee_is_admin or exists (
      select 1 from public.open_queue_referee_assignments assignment
      where assignment.game_id = match_id_to_stop
        and assignment.referee_id = actor_referee_id
    ) into has_access;
    if not has_access then raise exception 'This match is not assigned to you.'; end if;
    if not exists (
      select 1 from public.open_queue_games game
      where game.id = match_id_to_stop and game.status = 'LIVE'
    ) then
      raise exception 'Only a live match can be stopped.';
    end if;

    select clock.started_at, clock.accumulated_seconds
    into clock_started_at, accumulated
    from public.open_queue_clock_states clock
    where clock.game_id = match_id_to_stop;
  end if;

  elapsed := greatest(
    0,
    least(
      10800,
      coalesce(accumulated, 0) + case
        when clock_started_at is null then 0
        else greatest(0, extract(epoch from (now() - clock_started_at))::integer)
      end
    )
  );
  event_minute := elapsed / 60;
  event_second := elapsed % 60;

  insert into public.match_stoppages (
    match_kind,
    fixture_id,
    open_queue_game_id,
    stopped_by,
    mode,
    reason_code,
    note,
    elapsed_seconds
  ) values (
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_stop end,
    case when normalized_kind = 'SOLO' then match_id_to_stop end,
    actor_referee_id,
    normalized_mode,
    normalized_reason,
    normalized_note,
    elapsed
  ) returning id into stoppage_id;

  if normalized_kind = 'CLAN' then
    update public.fixture_clock_states
    set
      status = case when normalized_mode = 'ABANDON' then 'ENDED' else 'PAUSED' end,
      started_at = null,
      accumulated_seconds = elapsed
    where fixture_id = match_id_to_stop;

    insert into public.fixture_events (
      fixture_id, event_type, minute, second, note
    ) values (
      match_id_to_stop,
      'MATCH_STOPPED',
      event_minute,
      event_second,
      concat(normalized_reason, case when normalized_note = '' then '' else ': ' || normalized_note end)
    );

    if normalized_mode = 'ABANDON' then
      update public.fixtures
      set
        status = 'CANCELLED',
        cancellation_code = 'MATCH_ABANDONED',
        cancellation_reason = coalesce(nullif(normalized_note, ''), normalized_reason),
        cancelled_at = now(),
        cancelled_by = actor_referee_id,
        cancellation_context = jsonb_build_object(
          'stoppage_id', stoppage_id,
          'elapsed_seconds', elapsed
        )
      where id = match_id_to_stop;
      update public.fixture_blue_cards set status = 'CLEARED'
      where fixture_id = match_id_to_stop and status = 'ACTIVE';
    end if;
  else
    update public.open_queue_clock_states
    set
      status = case when normalized_mode = 'ABANDON' then 'ENDED' else 'PAUSED' end,
      started_at = null,
      accumulated_seconds = elapsed
    where game_id = match_id_to_stop;

    insert into public.open_queue_events (
      game_id, event_type, minute, second, note
    ) values (
      match_id_to_stop,
      'MATCH_STOPPED',
      event_minute,
      event_second,
      concat(normalized_reason, case when normalized_note = '' then '' else ': ' || normalized_note end)
    );

    if normalized_mode = 'ABANDON' then
      update public.open_queue_games
      set
        status = 'CANCELLED',
        cancellation_code = 'MATCH_ABANDONED',
        cancellation_reason = coalesce(nullif(normalized_note, ''), normalized_reason),
        cancelled_at = now(),
        cancelled_by = actor_referee_id,
        cancellation_context = jsonb_build_object(
          'stoppage_id', stoppage_id,
          'elapsed_seconds', elapsed
        )
      where id = match_id_to_stop;
      update public.open_queue_blue_cards set status = 'CLEARED'
      where game_id = match_id_to_stop and status = 'ACTIVE';
    end if;
  end if;

  insert into public.moderation_reports (
    reporter_referee_id,
    source,
    subject_type,
    fixture_id,
    open_queue_game_id,
    category,
    details,
    replay_offset_seconds,
    priority
  ) values (
    actor_referee_id,
    'REFEREE',
    'MATCH',
    case when normalized_kind = 'CLAN' then match_id_to_stop end,
    case when normalized_kind = 'SOLO' then match_id_to_stop end,
    case
      when normalized_reason in (
        'FIGHTING_OR_VIOLENCE', 'THREAT_TO_REFEREE', 'CROWD_OR_SECURITY'
      ) then 'THREATS_OR_VIOLENCE'
      else 'SAFETY_OR_VENUE'
    end,
    concat('Game ', lower(normalized_mode), ': ', normalized_reason,
      case when normalized_note = '' then '' else '. ' || normalized_note end),
    elapsed,
    case
      when normalized_reason in (
        'MEDICAL_EMERGENCY', 'FIGHTING_OR_VIOLENCE',
        'THREAT_TO_REFEREE', 'CROWD_OR_SECURITY'
      ) then 'URGENT'
      else 'HIGH'
    end
  );

  return stoppage_id;
end;
$$;

-- Rated match inputs remain immutable except inside the audited score revision
-- RPC below. The transaction-local flag is accepted only while running as a
-- database owner/service role, never from an authenticated client statement.
create or replace function public.protect_rated_fixture_inputs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixture_id_to_check uuid := old.id;
  has_rating_events boolean;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin')
    and current_setting('field.admin_score_override', true) = 'on'
  then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'UPDATE' then
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id in (old.id, new.id)
    ) into has_rating_events;
  else
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = fixture_id_to_check
    ) into has_rating_events;
  end if;

  if tg_op = 'DELETE' then
    if old.status = 'FINAL' and has_rating_events then
      raise exception 'Rated final fixtures cannot be deleted. Delete their rating events first during an authorized reset.';
    end if;
    return old;
  end if;

  if has_rating_events and (
    new.id is distinct from old.id
    or new.status is distinct from old.status
    or new.home_score is distinct from old.home_score
    or new.away_score is distinct from old.away_score
    or new.home_clan_id is distinct from old.home_clan_id
    or new.away_clan_id is distinct from old.away_clan_id
    or new.winner_clan_id is distinct from old.winner_clan_id
    or new.home_sr_change is distinct from old.home_sr_change
    or new.away_sr_change is distinct from old.away_sr_change
    or new.match_date is distinct from old.match_date
    or new.time_slot is distinct from old.time_slot
  ) then
    raise exception 'Rated fixture result, teams, schedule, and SR audit fields are immutable.';
  end if;

  return new;
end;
$$;

create or replace function public.protect_rated_open_queue_game_inputs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  game_id_to_check uuid := old.id;
  has_rating_events boolean;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin')
    and current_setting('field.admin_score_override', true) = 'on'
  then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'UPDATE' then
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id in (old.id, new.id)
    ) into has_rating_events;
  else
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id = game_id_to_check
    ) into has_rating_events;
  end if;

  if tg_op = 'DELETE' then
    if old.status = 'FINAL' and has_rating_events then
      raise exception 'Rated final Open Queue games cannot be deleted. Delete their rating events first during an authorized reset.';
    end if;
    return old;
  end if;

  if has_rating_events and (
    new.id is distinct from old.id
    or new.status is distinct from old.status
    or new.white_score is distinct from old.white_score
    or new.black_score is distinct from old.black_score
    or new.white_average_sr is distinct from old.white_average_sr
    or new.black_average_sr is distinct from old.black_average_sr
    or new.match_average_sr is distinct from old.match_average_sr
    or new.team_sr_spread is distinct from old.team_sr_spread
    or new.teams_assigned_at is distinct from old.teams_assigned_at
    or new.starts_at is distinct from old.starts_at
  ) then
    raise exception 'Rated Open Queue result, schedule, and SR audit fields are immutable.';
  end if;

  return new;
end;
$$;

create or replace function public.admin_override_match_score(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_update uuid,
  home_score_to_use integer,
  away_score_to_use integer,
  reason_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  fixture_before public.fixtures%rowtype;
  game_before public.open_queue_games%rowtype;
  previous_home integer;
  previous_away integer;
  new_winner uuid;
  revision_id uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if home_score_to_use is null or away_score_to_use is null
    or home_score_to_use < 0 or away_score_to_use < 0
    or home_score_to_use > 99 or away_score_to_use > 99 then
    raise exception 'Scores must be between 0 and 99.';
  end if;
  if char_length(normalized_reason) < 10 then
    raise exception 'Explain why the official score is changing.';
  end if;

  perform set_config('field.admin_score_override', 'on', true);

  if normalized_kind = 'CLAN' then
    select * into fixture_before
    from public.fixtures fixture
    where fixture.id = match_id_to_update
    for update;
    if fixture_before.id is null then raise exception 'Match not found.'; end if;
    if fixture_before.status <> 'FINAL' then
      raise exception 'Only a final match score can be corrected.';
    end if;
    previous_home := fixture_before.home_score;
    previous_away := fixture_before.away_score;
    if previous_home is null or previous_away is null then
      raise exception 'The current official score is missing.';
    end if;
    if previous_home = home_score_to_use and previous_away = away_score_to_use then
      raise exception 'Enter a different official score.';
    end if;

    -- Keep the sequential SR ledger immutable, but make W/L/D records match
    -- the corrected official result. The revision explicitly records this
    -- PRESERVE_APPLIED_SR policy for later rebuilds if required.
    update public.player_ratings rating
    set
      wins = greatest(0, rating.wins
        - case when event.result = 'WIN' then 1 else 0 end
        + case
          when home_score_to_use = away_score_to_use then 0
          when (event.side = 'HOME' and home_score_to_use > away_score_to_use)
            or (event.side = 'AWAY' and away_score_to_use > home_score_to_use)
            then 1 else 0 end),
      losses = greatest(0, rating.losses
        - case when event.result = 'LOSS' then 1 else 0 end
        + case
          when home_score_to_use = away_score_to_use then 0
          when (event.side = 'HOME' and home_score_to_use < away_score_to_use)
            or (event.side = 'AWAY' and away_score_to_use < home_score_to_use)
            then 1 else 0 end),
      draws = greatest(0, rating.draws
        - case when event.result = 'DRAW' then 1 else 0 end
        + case when home_score_to_use = away_score_to_use then 1 else 0 end)
    from public.player_rating_events event
    where event.profile_id = rating.profile_id
      and event.source_type = 'CLAN_FIXTURE'
      and event.source_id = match_id_to_update;

    update public.player_rating_events event
    set
      result = case
        when home_score_to_use = away_score_to_use then 'DRAW'
        when (event.side = 'HOME' and home_score_to_use > away_score_to_use)
          or (event.side = 'AWAY' and away_score_to_use > home_score_to_use)
          then 'WIN'
        else 'LOSS'
      end,
      actual_score = case
        when home_score_to_use = away_score_to_use then 0.5
        when (event.side = 'HOME' and home_score_to_use > away_score_to_use)
          or (event.side = 'AWAY' and away_score_to_use > home_score_to_use)
          then 1 else 0
      end,
      calculation_version = 'ADMIN_SCORE_CORRECTION_PRESERVE_SR'
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = match_id_to_update;

    update public.clans
    set
      wins = greatest(0, wins
        - case when previous_home > previous_away then 1 else 0 end
        + case when home_score_to_use > away_score_to_use then 1 else 0 end),
      losses = greatest(0, losses
        - case when previous_home < previous_away then 1 else 0 end
        + case when home_score_to_use < away_score_to_use then 1 else 0 end)
    where id = fixture_before.home_clan_id;

    update public.clans
    set
      wins = greatest(0, wins
        - case when previous_away > previous_home then 1 else 0 end
        + case when away_score_to_use > home_score_to_use then 1 else 0 end),
      losses = greatest(0, losses
        - case when previous_away < previous_home then 1 else 0 end
        + case when away_score_to_use < home_score_to_use then 1 else 0 end)
    where id = fixture_before.away_clan_id;

    new_winner := case
      when home_score_to_use > away_score_to_use then fixture_before.home_clan_id
      when away_score_to_use > home_score_to_use then fixture_before.away_clan_id
      else null
    end;

    update public.fixtures
    set
      home_score = home_score_to_use,
      away_score = away_score_to_use,
      winner_clan_id = new_winner
    where id = match_id_to_update;

    insert into public.fixture_events (
      fixture_id, event_type, minute, second, note
    ) values (
      match_id_to_update,
      'CORRECTION',
      coalesce((select accumulated_seconds / 60 from public.fixture_clock_states
        where fixture_id = match_id_to_update), 0),
      coalesce((select accumulated_seconds % 60 from public.fixture_clock_states
        where fixture_id = match_id_to_update), 0),
      format(
        'Official score corrected from %s-%s to %s-%s. %s',
        previous_home, previous_away, home_score_to_use, away_score_to_use,
        normalized_reason
      )
    );
  else
    select * into game_before
    from public.open_queue_games game
    where game.id = match_id_to_update
    for update;
    if game_before.id is null then raise exception 'Solo match not found.'; end if;
    if game_before.status <> 'FINAL' then
      raise exception 'Only a final match score can be corrected.';
    end if;
    previous_home := game_before.white_score;
    previous_away := game_before.black_score;
    if previous_home is null or previous_away is null then
      raise exception 'The current official score is missing.';
    end if;
    if previous_home = home_score_to_use and previous_away = away_score_to_use then
      raise exception 'Enter a different official score.';
    end if;

    update public.player_ratings rating
    set
      wins = greatest(0, rating.wins
        - case when event.result = 'WIN' then 1 else 0 end
        + case
          when home_score_to_use = away_score_to_use then 0
          when (event.side = 'WHITE' and home_score_to_use > away_score_to_use)
            or (event.side = 'BLACK' and away_score_to_use > home_score_to_use)
            then 1 else 0 end),
      losses = greatest(0, rating.losses
        - case when event.result = 'LOSS' then 1 else 0 end
        + case
          when home_score_to_use = away_score_to_use then 0
          when (event.side = 'WHITE' and home_score_to_use < away_score_to_use)
            or (event.side = 'BLACK' and away_score_to_use < home_score_to_use)
            then 1 else 0 end),
      draws = greatest(0, rating.draws
        - case when event.result = 'DRAW' then 1 else 0 end
        + case when home_score_to_use = away_score_to_use then 1 else 0 end)
    from public.player_rating_events event
    where event.profile_id = rating.profile_id
      and event.source_type = 'OPEN_QUEUE'
      and event.source_id = match_id_to_update;

    update public.player_rating_events event
    set
      result = case
        when home_score_to_use = away_score_to_use then 'DRAW'
        when (event.side = 'WHITE' and home_score_to_use > away_score_to_use)
          or (event.side = 'BLACK' and away_score_to_use > home_score_to_use)
          then 'WIN'
        else 'LOSS'
      end,
      actual_score = case
        when home_score_to_use = away_score_to_use then 0.5
        when (event.side = 'WHITE' and home_score_to_use > away_score_to_use)
          or (event.side = 'BLACK' and away_score_to_use > home_score_to_use)
          then 1 else 0
      end,
      calculation_version = 'ADMIN_SCORE_CORRECTION_PRESERVE_SR'
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = match_id_to_update;

    update public.open_queue_games
    set white_score = home_score_to_use, black_score = away_score_to_use
    where id = match_id_to_update;

    insert into public.open_queue_events (
      game_id, event_type, minute, second, note
    ) values (
      match_id_to_update,
      'CORRECTION',
      coalesce((select accumulated_seconds / 60 from public.open_queue_clock_states
        where game_id = match_id_to_update), 0),
      coalesce((select accumulated_seconds % 60 from public.open_queue_clock_states
        where game_id = match_id_to_update), 0),
      format(
        'Official score corrected from %s-%s to %s-%s. %s',
        previous_home, previous_away, home_score_to_use, away_score_to_use,
        normalized_reason
      )
    );
  end if;

  insert into public.match_score_revisions (
    match_kind,
    fixture_id,
    open_queue_game_id,
    previous_home_score,
    previous_away_score,
    revised_home_score,
    revised_away_score,
    reason,
    revised_by
  ) values (
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_update end,
    case when normalized_kind = 'SOLO' then match_id_to_update end,
    previous_home,
    previous_away,
    home_score_to_use,
    away_score_to_use,
    normalized_reason,
    actor_admin_id
  ) returning id into revision_id;

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
    'OFFICIAL_SCORE_CORRECTED',
    case when normalized_kind = 'CLAN' then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_update,
    normalized_reason,
    jsonb_build_object('home_score', previous_home, 'away_score', previous_away),
    jsonb_build_object(
      'home_score', home_score_to_use,
      'away_score', away_score_to_use,
      'score_revision_id', revision_id,
      'rating_policy', 'PRESERVE_APPLIED_SR'
    )
  );

  perform set_config('field.admin_score_override', 'off', true);
  return revision_id;
end;
$$;

create or replace view public.moderation_subject_summary
with (security_invoker = true)
as
with subject_reports as (
  select
    report.subject_type,
    coalesce(report.subject_profile_id, report.subject_clan_id) as subject_id,
    report.id,
    report.reporter_profile_id,
    report.reporter_referee_id,
    report.priority,
    report.status,
    report.created_at
  from public.moderation_reports report
  where report.subject_type in ('PLAYER', 'CLAN')
),
aggregated as (
  select
    report.subject_type,
    report.subject_id,
    count(*)::integer as total_reports,
    count(distinct coalesce(
      report.reporter_profile_id::text,
      'REF:' || report.reporter_referee_id::text
    )) filter (
      where report.created_at >= now() - interval '30 days'
        and report.status not in ('DISMISSED', 'DUPLICATE')
    )::integer as distinct_reporters_30d,
    count(*) filter (
      where report.created_at >= now() - interval '30 days'
        and report.status not in ('DISMISSED', 'DUPLICATE')
    )::integer as reports_30d,
    count(*) filter (
      where report.status in ('OPEN', 'TRIAGED', 'INVESTIGATING')
    )::integer as open_reports,
    count(*) filter (
      where report.priority in ('HIGH', 'URGENT')
        and report.status in ('OPEN', 'TRIAGED', 'INVESTIGATING')
    )::integer as high_priority_open_reports,
    count(*) filter (where report.status = 'ACTIONED')::integer
      as actioned_reports,
    count(*) filter (where report.status = 'DISMISSED')::integer
      as dismissed_reports,
    count(*) filter (where report.reporter_referee_id is not null)::integer
      as referee_reports,
    max(report.created_at) as last_reported_at
  from subject_reports report
  group by report.subject_type, report.subject_id
)
select
  aggregate.subject_type,
  aggregate.subject_id,
  case
    when aggregate.subject_type = 'PLAYER' then profile.display_name
    else clan.name
  end as display_name,
  case
    when aggregate.subject_type = 'PLAYER' then profile.username
    else clan.tag
  end as secondary_label,
  case
    when aggregate.subject_type = 'PLAYER' then profile.avatar_url
    else clan.emblem
  end as avatar_or_emblem,
  aggregate.total_reports,
  aggregate.reports_30d,
  aggregate.distinct_reporters_30d,
  aggregate.open_reports,
  aggregate.high_priority_open_reports,
  aggregate.actioned_reports,
  aggregate.dismissed_reports,
  aggregate.referee_reports,
  aggregate.last_reported_at,
  active_action.action_type as active_action_type,
  active_action.restriction_scope as active_action_scope,
  active_action.ends_at as active_action_ends_at,
  (
    aggregate.high_priority_open_reports * 20
    + aggregate.actioned_reports * 12
    + aggregate.distinct_reporters_30d * 5
    + aggregate.open_reports * 2
  )::integer as attention_score
from aggregated aggregate
left join public.profiles profile
  on aggregate.subject_type = 'PLAYER' and profile.id = aggregate.subject_id
left join public.clans clan
  on aggregate.subject_type = 'CLAN' and clan.id = aggregate.subject_id
left join lateral (
  select action.action_type, action.restriction_scope, action.ends_at
  from public.moderation_actions action
  where action.subject_type = aggregate.subject_type
    and coalesce(action.subject_profile_id, action.subject_clan_id)
      = aggregate.subject_id
    and action.action_type in ('SUSPENSION', 'BAN')
    and action.revoked_at is null
    and action.starts_at <= now()
    and (action.ends_at is null or action.ends_at > now())
  order by case action.action_type when 'BAN' then 0 else 1 end,
    action.created_at desc
  limit 1
) active_action on true;

revoke all on table public.moderation_subject_summary from anon, authenticated;
grant select on table public.moderation_subject_summary to service_role;

drop policy if exists "Clan owners can update fixture records"
on public.fixtures;

revoke all on function public.is_active_moderation_admin(uuid)
from public, anon, authenticated;
grant execute on function public.is_active_moderation_admin(uuid)
to service_role;

revoke all on function public.profile_has_active_play_restriction(uuid)
from public, anon, authenticated;
grant execute on function public.profile_has_active_play_restriction(uuid)
to service_role;

revoke all on function public.clan_has_active_play_restriction(uuid)
from public, anon, authenticated;
grant execute on function public.clan_has_active_play_restriction(uuid)
to service_role;

revoke all on function public.submit_moderation_report(
  text, uuid, text, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.submit_moderation_report(
  text, uuid, text, text, uuid, uuid
) to authenticated;

revoke all on function public.get_my_moderation_status()
from public, anon, authenticated;
grant execute on function public.get_my_moderation_status()
to authenticated;

revoke all on function public.submit_referee_moderation_report(
  uuid, text, uuid, text, text, text, uuid, uuid, integer
) from public, anon, authenticated;
grant execute on function public.submit_referee_moderation_report(
  uuid, text, uuid, text, text, text, uuid, uuid, integer
) to service_role;

revoke all on function public.admin_update_moderation_report(
  uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.admin_update_moderation_report(
  uuid, uuid, text, text
) to service_role;

revoke all on function public.admin_apply_moderation_action(
  uuid, text, uuid, text, text, text, text, timestamptz, uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_apply_moderation_action(
  uuid, text, uuid, text, text, text, text, timestamptz, uuid, text
) to service_role;

revoke all on function public.admin_revoke_moderation_action(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.admin_revoke_moderation_action(uuid, uuid, text)
to service_role;

revoke all on function public.admin_cancel_match(uuid, text, uuid, text, text)
from public, anon, authenticated;
grant execute on function public.admin_cancel_match(uuid, text, uuid, text, text)
to service_role;

revoke all on function public.referee_record_match_stoppage(
  uuid, text, uuid, text, text, text
) from public, anon, authenticated;
grant execute on function public.referee_record_match_stoppage(
  uuid, text, uuid, text, text, text
) to service_role;

revoke all on function public.admin_override_match_score(
  uuid, text, uuid, integer, integer, text
) from public, anon, authenticated;
grant execute on function public.admin_override_match_score(
  uuid, text, uuid, integer, integer, text
) to service_role;

revoke all on function public.enforce_profile_play_restriction()
from public, anon, authenticated;
revoke all on function public.enforce_fixture_appearance_restriction()
from public, anon, authenticated;
revoke all on function public.enforce_clan_play_restriction()
from public, anon, authenticated;
revoke all on function public.protect_clan_competitive_fields()
from public, anon, authenticated;

comment on table public.moderation_reports is
'Private allegations from players and referees. Reports never trigger automatic discipline.';
comment on table public.moderation_actions is
'Append-only warning, suspension, and ban history. Revocation preserves the original record.';
comment on table public.match_score_revisions is
'Audited official-score corrections. Applied SR stays immutable to preserve the sequential ledger.';
