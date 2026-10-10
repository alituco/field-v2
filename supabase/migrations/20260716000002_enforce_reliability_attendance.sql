-- Prospective reliability enforcement for solo and clan match attendance.
-- Historical bookings and rating events are never rewritten. All clocks use
-- database time and every derived row snapshots the policy version used.

create extension if not exists pg_cron;

create table public.match_reliability_terms (
  id uuid primary key default gen_random_uuid(),
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  kickoff_at timestamptz not null,
  check_in_opens_at timestamptz not null,
  check_in_deadline_at timestamptz not null,
  no_show_cutoff_at timestamptz not null,
  team_assignment_at timestamptz,
  party_lock_at timestamptz,
  policy_snapshot jsonb not null check (jsonb_typeof(policy_snapshot) = 'object'),
  bound_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  check (
    (match_kind = 'SOLO' and open_queue_game_id is not null and fixture_id is null)
    or (match_kind = 'CLAN' and fixture_id is not null and open_queue_game_id is null)
  ),
  check (check_in_opens_at < check_in_deadline_at),
  check (check_in_deadline_at <= kickoff_at),
  check (no_show_cutoff_at >= kickoff_at)
);

create unique index match_reliability_terms_solo_idx
on public.match_reliability_terms (open_queue_game_id)
where match_kind = 'SOLO';

create unique index match_reliability_terms_clan_idx
on public.match_reliability_terms (fixture_id)
where match_kind = 'CLAN';

create table public.field_wallet_accounts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  balance_fils bigint not null default 0 check (balance_fils >= 0),
  currency text not null default 'BHD' check (currency = 'BHD'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

drop trigger if exists set_field_wallet_accounts_updated_at
on public.field_wallet_accounts;
create trigger set_field_wallet_accounts_updated_at
before update on public.field_wallet_accounts
for each row execute function public.set_updated_at();

create table public.field_wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete restrict,
  direction text not null check (direction in ('CREDIT', 'DEBIT')),
  amount_fils integer not null check (amount_fils > 0),
  transaction_type text not null check (
    transaction_type in (
      'BOOKING_REFUND',
      'FIELD_CANCELLATION_REFUND',
      'RELIABILITY_DEPOSIT_RETURN',
      'SUSPENSION_BOOKING_RELEASE',
      'APPEAL_ADJUSTMENT'
    )
  ),
  balance_after_fils bigint not null check (balance_after_fils >= 0),
  idempotency_key text not null unique check (
    char_length(trim(idempotency_key)) between 8 and 200
  ),
  policy_version_id uuid references public.reliability_policy_versions(id)
    on delete restrict,
  booking_id uuid references public.open_queue_bookings(id) on delete set null,
  incident_id uuid,
  description text not null check (char_length(trim(description)) between 3 and 300),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default clock_timestamp()
);

create index field_wallet_transactions_profile_idx
on public.field_wallet_transactions (profile_id, created_at desc);

create table public.match_attendance_records (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.match_reliability_terms(id)
    on delete cascade,
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete cascade,
  booking_id uuid references public.open_queue_bookings(id) on delete set null,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  clan_id uuid references public.clans(id) on delete set null,
  side text check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  role text,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  check_in_deadline_at timestamptz not null,
  no_show_cutoff_at timestamptz not null,
  checked_in_at timestamptz,
  checked_in_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  cancelled_at timestamptz,
  outcome text check (
    outcome in (
      'ON_TIME',
      'LATE',
      'CANCELLED_EARLY',
      'CANCELLED_LATE',
      'CANCELLED_VERY_LATE',
      'NO_SHOW',
      'EXCUSED',
      'FIELD_CANCELLED'
    )
  ),
  strike_delta integer not null default 0 check (strike_delta between 0 and 20),
  refund_bps integer not null default 0 check (refund_bps between 0 and 10000),
  refund_amount_fils integer not null default 0 check (refund_amount_fils >= 0),
  reliability_deposit_fils integer not null default 0 check (
    reliability_deposit_fils >= 0
  ),
  deposit_resolution text not null default 'NOT_REQUIRED' check (
    deposit_resolution in ('NOT_REQUIRED', 'PENDING', 'RETURNED', 'FORFEITED')
  ),
  positive_sr_multiplier_bps integer not null default 10000 check (
    positive_sr_multiplier_bps between 0 and 30000
  ),
  negative_sr_multiplier_bps integer not null default 10000 check (
    negative_sr_multiplier_bps between 0 and 30000
  ),
  replacement_profile_id uuid references public.profiles(id) on delete set null,
  finalized_at timestamptz,
  appeal_due_at timestamptz,
  consequence_snapshot jsonb not null default '{}'::jsonb check (
    jsonb_typeof(consequence_snapshot) = 'object'
  ),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (
    (match_kind = 'SOLO' and open_queue_game_id is not null and fixture_id is null)
    or (match_kind = 'CLAN' and fixture_id is not null and open_queue_game_id is null)
  ),
  check (
    (outcome is null and finalized_at is null)
    or (outcome is not null and finalized_at is not null)
  )
);

create unique index match_attendance_solo_profile_idx
on public.match_attendance_records (open_queue_game_id, profile_id)
where match_kind = 'SOLO';

create unique index match_attendance_clan_profile_idx
on public.match_attendance_records (fixture_id, profile_id)
where match_kind = 'CLAN';

create index match_attendance_profile_idx
on public.match_attendance_records (profile_id, created_at desc);

create index match_attendance_finalizer_idx
on public.match_attendance_records (no_show_cutoff_at, outcome)
where outcome is null;

drop trigger if exists set_match_attendance_updated_at
on public.match_attendance_records;
create trigger set_match_attendance_updated_at
before update on public.match_attendance_records
for each row execute function public.set_updated_at();

create table public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid not null references public.match_attendance_records(id)
    on delete cascade,
  event_type text not null check (
    event_type in (
      'EXPECTED',
      'CHECKED_IN',
      'CANCELLED',
      'NO_SHOW_FINALIZED',
      'DEPOSIT_RETURNED',
      'DEPOSIT_FORFEITED',
      'REPLACEMENT_ACTIVATED',
      'INJURY_RECORDED',
      'ADMIN_CORRECTION',
      'APPEAL_OVERTURNED'
    )
  ),
  actor_referee_id uuid references public.referee_profiles(profile_id)
    on delete set null,
  event_at timestamptz not null default clock_timestamp(),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  idempotency_key text unique,
  created_at timestamptz not null default clock_timestamp()
);

create index attendance_events_record_idx
on public.attendance_events (attendance_id, event_at);

create table public.reliability_incidents (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('PLAYER', 'CLAN')),
  profile_id uuid references public.profiles(id) on delete restrict,
  clan_id uuid references public.clans(id) on delete restrict,
  attendance_id uuid references public.match_attendance_records(id)
    on delete restrict,
  booking_id uuid references public.open_queue_bookings(id) on delete set null,
  outcome text not null,
  strike_delta integer not null check (strike_delta between -20 and 20),
  occurred_at timestamptz not null,
  expires_at timestamptz,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  reversal_of uuid references public.reliability_incidents(id) on delete restrict,
  active_count_before integer not null check (active_count_before >= 0),
  active_count_after integer not null check (active_count_after >= 0),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  check (
    (subject_type = 'PLAYER' and profile_id is not null and clan_id is null)
    or (subject_type = 'CLAN' and clan_id is not null and profile_id is null)
  )
);

create unique index reliability_incident_attendance_positive_idx
on public.reliability_incidents (attendance_id)
where attendance_id is not null and reversal_of is null;

create unique index reliability_incident_reversal_idx
on public.reliability_incidents (reversal_of)
where reversal_of is not null;

create index reliability_incidents_player_active_idx
on public.reliability_incidents (profile_id, expires_at, occurred_at desc)
where subject_type = 'PLAYER';

create table public.reliability_sanctions (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('PLAYER', 'CLAN')),
  profile_id uuid references public.profiles(id) on delete restrict,
  clan_id uuid references public.clans(id) on delete restrict,
  incident_id uuid not null references public.reliability_incidents(id)
    on delete restrict,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  threshold integer not null check (threshold > 0),
  sanction_kind text not null check (
    sanction_kind in (
      'WARNING',
      'BOOKING_RESTRICTION',
      'PARTICIPATION_SUSPENSION',
      'INDEFINITE_SUSPENSION'
    )
  ),
  starts_at timestamptz not null,
  ends_at timestamptz,
  release_future_bookings boolean not null default false,
  revoked_at timestamptz,
  revoked_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  revocation_reason text,
  created_at timestamptz not null default clock_timestamp(),
  unique (incident_id, threshold),
  check (
    (subject_type = 'PLAYER' and profile_id is not null and clan_id is null)
    or (subject_type = 'CLAN' and clan_id is not null and profile_id is null)
  ),
  check (ends_at is null or ends_at > starts_at),
  check (
    (revoked_at is null and revoked_by is null)
    or (
      revoked_at is not null
      and (
        revoked_by is not null
        or revocation_reason like 'Match cancelled by Field:%'
      )
    )
  )
);

create index reliability_sanctions_player_active_idx
on public.reliability_sanctions (profile_id, sanction_kind, starts_at, ends_at)
where revoked_at is null and subject_type = 'PLAYER';

create table public.reliability_appeals (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid not null references public.match_attendance_records(id)
    on delete restrict,
  incident_id uuid references public.reliability_incidents(id) on delete restrict,
  appellant_profile_id uuid not null references public.profiles(id)
    on delete restrict,
  category text not null,
  message text not null check (char_length(trim(message)) between 10 and 2000),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'REVIEWING', 'UPHELD', 'OVERTURNED')
  ),
  appeal_due_at timestamptz not null,
  reviewed_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  reviewed_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 2000),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (attendance_id, appellant_profile_id),
  check (
    (status in ('UPHELD', 'OVERTURNED') and reviewed_at is not null)
    or (status in ('OPEN', 'REVIEWING') and reviewed_at is null)
  )
);

drop trigger if exists set_reliability_appeals_updated_at
on public.reliability_appeals;
create trigger set_reliability_appeals_updated_at
before update on public.reliability_appeals
for each row execute function public.set_updated_at();

alter table public.open_queue_bookings
add column if not exists base_amount_fils integer,
add column if not exists discount_bps integer not null default 0,
add column if not exists reliability_deposit_fils integer not null default 0,
add column if not exists reliability_deposit_status text not null default 'NOT_REQUIRED',
add column if not exists reliability_policy_version_id uuid
  references public.reliability_policy_versions(id) on delete restrict,
add column if not exists refund_bps integer;

update public.open_queue_bookings
set base_amount_fils = greatest(0, amount_paid_fils - reliability_deposit_fils)
where base_amount_fils is null;

alter table public.open_queue_bookings
alter column base_amount_fils set not null,
drop constraint if exists open_queue_bookings_refund_percent_check;

alter table public.open_queue_bookings
add constraint open_queue_bookings_refund_percent_check
check (refund_percent is null or refund_percent between 0 and 100),
add constraint open_queue_bookings_refund_bps_check
check (refund_bps is null or refund_bps between 0 and 10000),
add constraint open_queue_bookings_discount_bps_check
check (discount_bps between 0 and 10000),
add constraint open_queue_bookings_reliability_deposit_status_check
check (
  reliability_deposit_status in (
    'NOT_REQUIRED', 'HELD', 'RETURNED', 'FORFEITED', 'REFUNDED'
  )
);

alter table public.open_queue_games
add column if not exists replacement_discount_bps integer not null default 0,
add column if not exists replacement_discount_role text,
add column if not exists replacement_source_booking_id uuid
  references public.open_queue_bookings(id) on delete set null,
add column if not exists replacement_offer_expires_at timestamptz;

alter table public.open_queue_games
add constraint open_queue_games_replacement_discount_bps_check
check (replacement_discount_bps between 0 and 10000),
add constraint open_queue_games_replacement_discount_role_check
check (
  replacement_discount_role is null
  or replacement_discount_role in ('GK', 'DEF', 'MID', 'ATT')
);

alter table public.match_reliability_terms enable row level security;
alter table public.field_wallet_accounts enable row level security;
alter table public.field_wallet_transactions enable row level security;
alter table public.match_attendance_records enable row level security;
alter table public.attendance_events enable row level security;
alter table public.reliability_incidents enable row level security;
alter table public.reliability_sanctions enable row level security;
alter table public.reliability_appeals enable row level security;

revoke all on table public.match_reliability_terms from public, anon, authenticated;
revoke all on table public.field_wallet_accounts from public, anon, authenticated;
revoke all on table public.field_wallet_transactions from public, anon, authenticated;
revoke all on table public.match_attendance_records from public, anon, authenticated;
revoke all on table public.attendance_events from public, anon, authenticated;
revoke all on table public.reliability_incidents from public, anon, authenticated;
revoke all on table public.reliability_sanctions from public, anon, authenticated;
revoke all on table public.reliability_appeals from public, anon, authenticated;

grant all on table public.match_reliability_terms to service_role;
grant all on table public.field_wallet_accounts to service_role;
grant all on table public.field_wallet_transactions to service_role;
grant all on table public.match_attendance_records to service_role;
grant all on table public.attendance_events to service_role;
grant all on table public.reliability_incidents to service_role;
grant all on table public.reliability_sanctions to service_role;
grant all on table public.reliability_appeals to service_role;

create or replace function public.ensure_match_reliability_terms(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns public.match_reliability_terms
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  kickoff_to_use timestamptz;
  policy_to_use public.reliability_policy_versions%rowtype;
  existing_terms public.match_reliability_terms%rowtype;
  saved_terms public.match_reliability_terms%rowtype;
  check_in_open_minutes integer;
  check_in_minutes integer;
  no_show_minutes integer;
  team_lead_minutes integer;
  party_lead_minutes integer;
  has_decision boolean;
  has_financial_commitment boolean := false;
begin
  if normalized_kind = 'SOLO' then
    select game.starts_at into kickoff_to_use
    from public.open_queue_games game
    where game.id = match_id_to_use
    for update;
  elsif normalized_kind = 'CLAN' then
    select public.fixture_start_at(fixture.match_date, fixture.time_slot)
    into kickoff_to_use
    from public.fixtures fixture
    where fixture.id = match_id_to_use
    for update;
  else
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;

  if kickoff_to_use is null then
    raise exception 'Match not found.';
  end if;

  select * into policy_to_use
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= kickoff_to_use
  order by policy.effective_from desc, policy.version desc
  limit 1;

  if policy_to_use.id is null then
    raise exception
      'No reliability policy applies to this match kickoff. Legacy matches require admin review and cannot receive new penalties.';
  end if;

  select * into existing_terms
  from public.match_reliability_terms terms
  where (normalized_kind = 'SOLO' and terms.open_queue_game_id = match_id_to_use)
     or (normalized_kind = 'CLAN' and terms.fixture_id = match_id_to_use)
  for update;

  if existing_terms.id is not null then
    select exists (
      select 1
      from public.match_attendance_records attendance
      where attendance.terms_id = existing_terms.id
        and attendance.outcome is not null
    ) into has_decision;

    if normalized_kind = 'SOLO' then
      select exists (
        select 1
        from public.open_queue_bookings booking
        where booking.game_id = match_id_to_use
      ) into has_financial_commitment;
    else
      select fixture.home_paid_by is not null
        or fixture.away_paid_by is not null
      into has_financial_commitment
      from public.fixtures fixture
      where fixture.id = match_id_to_use;
    end if;

    -- Once anybody has paid or an attendance outcome exists, the whole match
    -- keeps the policy that was disclosed at checkout. A later future-dated
    -- policy may update unbooked inventory, but never changes an existing
    -- player's charge, deposit, refund or attendance contract.
    if (has_financial_commitment or has_decision)
      and existing_terms.policy_version_id <> policy_to_use.id
    then
      select * into policy_to_use
      from public.reliability_policy_versions policy
      where policy.id = existing_terms.policy_version_id;
      if policy_to_use.id is null then
        raise exception 'The match''s committed reliability policy is missing.';
      end if;
    end if;

    check_in_open_minutes := (policy_to_use.config #>>
      '{attendance,checkInOpenLeadMinutes}')::integer;
    check_in_minutes := (policy_to_use.config #>>
      '{attendance,checkInLeadMinutes}')::integer;
    no_show_minutes := (policy_to_use.config #>>
      '{attendance,noShowGraceMinutes}')::integer;
    team_lead_minutes := (policy_to_use.config #>>
      '{solo,teamAssignmentLeadMinutes}')::integer;
    party_lead_minutes := (policy_to_use.config #>>
      '{solo,partyLockLeadMinutes}')::integer;

    if has_decision and existing_terms.kickoff_at <> kickoff_to_use then
      raise exception 'A match cannot be rescheduled after an attendance decision has been recorded.';
    end if;

    if not has_decision
      and (
        existing_terms.policy_version_id <> policy_to_use.id
        or existing_terms.kickoff_at <> kickoff_to_use
      )
      and kickoff_to_use > clock_timestamp()
    then
      update public.match_reliability_terms
      set
        policy_version_id = policy_to_use.id,
        kickoff_at = kickoff_to_use,
        check_in_opens_at = kickoff_to_use
          - make_interval(mins => check_in_open_minutes),
        check_in_deadline_at = kickoff_to_use
          - make_interval(mins => check_in_minutes),
        no_show_cutoff_at = kickoff_to_use
          + make_interval(mins => no_show_minutes),
        team_assignment_at = case when normalized_kind = 'SOLO' then
          kickoff_to_use - make_interval(mins => team_lead_minutes)
          else null end,
        party_lock_at = case when normalized_kind = 'SOLO' then
          kickoff_to_use - make_interval(mins => party_lead_minutes)
          else null end,
        policy_snapshot = policy_to_use.config,
        bound_at = clock_timestamp()
      where id = existing_terms.id
      returning * into existing_terms;

      update public.match_attendance_records
      set
        policy_version_id = existing_terms.policy_version_id,
        check_in_deadline_at = existing_terms.check_in_deadline_at,
        no_show_cutoff_at = existing_terms.no_show_cutoff_at
      where terms_id = existing_terms.id
        and outcome is null;
    end if;
    return existing_terms;
  end if;

  check_in_open_minutes := (policy_to_use.config #>>
    '{attendance,checkInOpenLeadMinutes}')::integer;
  check_in_minutes := (policy_to_use.config #>>
    '{attendance,checkInLeadMinutes}')::integer;
  no_show_minutes := (policy_to_use.config #>>
    '{attendance,noShowGraceMinutes}')::integer;
  team_lead_minutes := (policy_to_use.config #>>
    '{solo,teamAssignmentLeadMinutes}')::integer;
  party_lead_minutes := (policy_to_use.config #>>
    '{solo,partyLockLeadMinutes}')::integer;

  insert into public.match_reliability_terms (
    match_kind,
    fixture_id,
    open_queue_game_id,
    policy_version_id,
    kickoff_at,
    check_in_opens_at,
    check_in_deadline_at,
    no_show_cutoff_at,
    team_assignment_at,
    party_lock_at,
    policy_snapshot
  ) values (
    normalized_kind,
    case when normalized_kind = 'CLAN' then match_id_to_use end,
    case when normalized_kind = 'SOLO' then match_id_to_use end,
    policy_to_use.id,
    kickoff_to_use,
    kickoff_to_use - make_interval(mins => check_in_open_minutes),
    kickoff_to_use - make_interval(mins => check_in_minutes),
    kickoff_to_use + make_interval(mins => no_show_minutes),
    case when normalized_kind = 'SOLO' then
      kickoff_to_use - make_interval(mins => team_lead_minutes) end,
    case when normalized_kind = 'SOLO' then
      kickoff_to_use - make_interval(mins => party_lead_minutes) end,
    policy_to_use.config
  ) returning * into saved_terms;

  return saved_terms;
exception
  when unique_violation then
    select * into saved_terms
    from public.match_reliability_terms terms
    where (normalized_kind = 'SOLO' and terms.open_queue_game_id = match_id_to_use)
       or (normalized_kind = 'CLAN' and terms.fixture_id = match_id_to_use);
    return saved_terms;
end;
$$;

create or replace function public.ensure_match_attendance_records(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  terms_to_use public.match_reliability_terms%rowtype;
  inserted_count integer := 0;
begin
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  if normalized_kind = 'SOLO' then
    insert into public.match_attendance_records (
      terms_id,
      match_kind,
      open_queue_game_id,
      booking_id,
      profile_id,
      side,
      role,
      policy_version_id,
      check_in_deadline_at,
      no_show_cutoff_at,
      reliability_deposit_fils,
      deposit_resolution
    )
    select
      terms_to_use.id,
      'SOLO',
      game.id,
      booking.id,
      booking.profile_id,
      booking.team,
      booking.role,
      terms_to_use.policy_version_id,
      terms_to_use.check_in_deadline_at,
      terms_to_use.no_show_cutoff_at,
      booking.reliability_deposit_fils,
      case when booking.reliability_deposit_fils > 0
        then 'PENDING' else 'NOT_REQUIRED' end
    from public.open_queue_games game
    join public.open_queue_bookings booking on booking.game_id = game.id
    where game.id = match_id_to_use
      and booking.status = 'CONFIRMED'
    on conflict (open_queue_game_id, profile_id)
      where match_kind = 'SOLO'
    do update set
      booking_id = excluded.booking_id,
      side = coalesce(excluded.side, match_attendance_records.side),
      role = excluded.role,
      reliability_deposit_fils = excluded.reliability_deposit_fils,
      deposit_resolution = case
        when match_attendance_records.outcome is null
          then excluded.deposit_resolution
        else match_attendance_records.deposit_resolution
      end;
    get diagnostics inserted_count = row_count;
  elsif normalized_kind = 'CLAN' then
    -- Until a captain confirms a dedicated reliability roster, use the played
    -- lineup snapshot when present and otherwise the current active clan
    -- roster. Every later roster workflow writes to these same attendance rows.
    insert into public.match_attendance_records (
      terms_id,
      match_kind,
      fixture_id,
      profile_id,
      clan_id,
      side,
      policy_version_id,
      check_in_deadline_at,
      no_show_cutoff_at
    )
    select distinct on (candidate.profile_id)
      terms_to_use.id,
      'CLAN',
      fixture.id,
      candidate.profile_id,
      candidate.clan_id,
      case when candidate.clan_id = fixture.home_clan_id then 'HOME' else 'AWAY' end,
      terms_to_use.policy_version_id,
      terms_to_use.check_in_deadline_at,
      terms_to_use.no_show_cutoff_at
    from public.fixtures fixture
    join lateral (
      select appearance.profile_id, appearance.clan_id, 0 as source_order
      from public.fixture_player_appearances appearance
      where appearance.fixture_id = fixture.id
      union all
      select member.profile_id, member.clan_id, 1 as source_order
      from public.clan_members member
      where member.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
        and member.left_at is null
    ) candidate on true
    where fixture.id = match_id_to_use
      and candidate.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
    order by candidate.profile_id, candidate.source_order
    on conflict (fixture_id, profile_id)
      where match_kind = 'CLAN'
    do nothing;
    get diagnostics inserted_count = row_count;
  else
    raise exception 'Match kind must be SOLO or CLAN.';
  end if;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    detail,
    idempotency_key
  )
  select
    attendance.id,
    'EXPECTED',
    jsonb_build_object(
      'check_in_opens_at', terms_to_use.check_in_opens_at,
      'check_in_deadline_at', attendance.check_in_deadline_at,
      'no_show_cutoff_at', attendance.no_show_cutoff_at,
      'policy_version_id', attendance.policy_version_id
    ),
    'attendance-expected:' || attendance.id::text
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
  on conflict (idempotency_key) do nothing;

  return inserted_count;
end;
$$;

create or replace function public.referee_can_manage_reliability_match(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.referee_profiles referee
    where referee.profile_id = actor_referee_id
      and referee.is_active
      and (
        referee.role = 'admin'
        or (
          upper(match_kind_to_use) = 'SOLO'
          and exists (
            select 1
            from public.open_queue_referee_assignments assignment
            where assignment.game_id = match_id_to_use
              and assignment.referee_id = actor_referee_id
          )
        )
        or (
          upper(match_kind_to_use) = 'CLAN'
          and exists (
            select 1
            from public.fixture_referee_assignments assignment
            where assignment.fixture_id = match_id_to_use
              and assignment.referee_id = actor_referee_id
          )
        )
      )
  );
$$;

create or replace function public.active_reliability_strikes(
  profile_id_to_use uuid,
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
  where incident.subject_type = 'PLAYER'
    and incident.profile_id = profile_id_to_use
    and incident.occurred_at <= at_to_use
    and (incident.expires_at is null or incident.expires_at > at_to_use);
$$;

create or replace function public.credit_field_wallet(
  profile_id_to_credit uuid,
  amount_fils_to_credit integer,
  transaction_type_to_use text,
  idempotency_key_to_use text,
  description_to_use text,
  policy_version_id_to_use uuid default null,
  booking_id_to_use uuid default null,
  incident_id_to_use uuid default null,
  metadata_to_use jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  existing_transaction uuid;
  next_balance bigint;
  transaction_id uuid;
begin
  if amount_fils_to_credit <= 0 then
    return null;
  end if;

  select id into existing_transaction
  from public.field_wallet_transactions transaction
  where transaction.idempotency_key = idempotency_key_to_use;
  if existing_transaction is not null then
    return existing_transaction;
  end if;

  insert into public.field_wallet_accounts (profile_id)
  values (profile_id_to_credit)
  on conflict (profile_id) do nothing;

  select balance_fils into next_balance
  from public.field_wallet_accounts
  where profile_id = profile_id_to_credit
  for update;

  select id into existing_transaction
  from public.field_wallet_transactions transaction
  where transaction.idempotency_key = idempotency_key_to_use;
  if existing_transaction is not null then
    return existing_transaction;
  end if;

  next_balance := next_balance + amount_fils_to_credit;
  update public.field_wallet_accounts
  set balance_fils = next_balance
  where profile_id = profile_id_to_credit;

  insert into public.field_wallet_transactions (
    profile_id,
    direction,
    amount_fils,
    transaction_type,
    balance_after_fils,
    idempotency_key,
    policy_version_id,
    booking_id,
    incident_id,
    description,
    metadata
  ) values (
    profile_id_to_credit,
    'CREDIT',
    amount_fils_to_credit,
    transaction_type_to_use,
    next_balance,
    idempotency_key_to_use,
    policy_version_id_to_use,
    booking_id_to_use,
    incident_id_to_use,
    trim(description_to_use),
    coalesce(metadata_to_use, '{}'::jsonb)
  ) returning id into transaction_id;

  return transaction_id;
end;
$$;

create or replace function public.profile_has_active_reliability_booking_restriction(
  profile_id_to_check uuid,
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
    where sanction.subject_type = 'PLAYER'
      and sanction.profile_id = profile_id_to_check
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

create or replace function public.record_reliability_incident(
  attendance_id_to_use uuid,
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
  attendance_to_use public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  existing_incident uuid;
  incident_id_to_use uuid;
  active_before integer;
  active_after integer;
  strike_lifetime_days integer;
  sanction_rule jsonb;
  threshold_to_use integer;
  sanction_kind_to_use text;
  duration_days_to_use integer;
  release_future boolean;
  sanction_id_to_use uuid;
  future_booking record;
  refund_bps_to_use integer;
begin
  if strike_delta_to_use <= 0 then
    return null;
  end if;

  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.id = attendance_id_to_use
  for update;
  if attendance_to_use.id is null then
    raise exception 'Attendance record not found.';
  end if;

  select incident.id into existing_incident
  from public.reliability_incidents incident
  where incident.attendance_id = attendance_to_use.id
    and incident.reversal_of is null;
  if existing_incident is not null then
    return existing_incident;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(attendance_to_use.profile_id::text, 9174)
  );

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = attendance_to_use.terms_id;

  active_before := public.active_reliability_strikes(
    attendance_to_use.profile_id,
    occurred_at_to_use
  );
  active_after := active_before + strike_delta_to_use;
  strike_lifetime_days := (terms_to_use.policy_snapshot #>>
    '{attendance,strikeLifetimeDays}')::integer;

  insert into public.reliability_incidents (
    subject_type,
    profile_id,
    attendance_id,
    booking_id,
    outcome,
    strike_delta,
    occurred_at,
    expires_at,
    policy_version_id,
    active_count_before,
    active_count_after,
    detail
  ) values (
    'PLAYER',
    attendance_to_use.profile_id,
    attendance_to_use.id,
    attendance_to_use.booking_id,
    upper(trim(outcome_to_use)),
    strike_delta_to_use,
    occurred_at_to_use,
    occurred_at_to_use + make_interval(days => strike_lifetime_days),
    attendance_to_use.policy_version_id,
    active_before,
    active_after,
    jsonb_build_object(
      'match_kind', attendance_to_use.match_kind,
      'fixture_id', attendance_to_use.fixture_id,
      'open_queue_game_id', attendance_to_use.open_queue_game_id
    )
  ) returning id into incident_id_to_use;

  for sanction_rule in
    select candidate.value
    from jsonb_array_elements(
      terms_to_use.policy_snapshot #> '{solo,sanctions}'
    ) candidate(value)
    where (candidate.value ->> 'threshold')::integer > active_before
      and (candidate.value ->> 'threshold')::integer <= active_after
      and (
        not (terms_to_use.policy_snapshot #>>
          '{solo,highestCrossedOnly}')::boolean
        or (candidate.value ->> 'threshold')::integer = (
          select max((crossed.value ->> 'threshold')::integer)
          from jsonb_array_elements(
            terms_to_use.policy_snapshot #> '{solo,sanctions}'
          ) crossed(value)
          where (crossed.value ->> 'threshold')::integer > active_before
            and (crossed.value ->> 'threshold')::integer <= active_after
        )
      )
    order by (candidate.value ->> 'threshold')::integer
  loop
    threshold_to_use := (sanction_rule ->> 'threshold')::integer;
    sanction_kind_to_use := sanction_rule ->> 'kind';
    duration_days_to_use := case
      when sanction_rule -> 'durationDays' = 'null'::jsonb then null
      else (sanction_rule ->> 'durationDays')::integer
    end;
    release_future := coalesce(
      (sanction_rule ->> 'releaseFutureBookings')::boolean,
      false
    );

    insert into public.reliability_sanctions (
      subject_type,
      profile_id,
      incident_id,
      policy_version_id,
      threshold,
      sanction_kind,
      starts_at,
      ends_at,
      release_future_bookings
    ) values (
      'PLAYER',
      attendance_to_use.profile_id,
      incident_id_to_use,
      attendance_to_use.policy_version_id,
      threshold_to_use,
      sanction_kind_to_use,
      occurred_at_to_use,
      case
        when sanction_kind_to_use in ('WARNING', 'INDEFINITE_SUSPENSION')
          then null
        else occurred_at_to_use + make_interval(days => duration_days_to_use)
      end,
      release_future
    ) returning id into sanction_id_to_use;

    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    ) values (
      attendance_to_use.profile_id,
      'RELIABILITY_SANCTION',
      case sanction_kind_to_use
        when 'WARNING' then 'Reliability warning'
        when 'BOOKING_RESTRICTION' then 'New bookings temporarily restricted'
        when 'PARTICIPATION_SUSPENSION' then 'Participation temporarily suspended'
        else 'Account requires reliability review'
      end,
      'Your attendance outcome added ' || strike_delta_to_use ||
        case when strike_delta_to_use = 1 then ' active strike.' else ' active strikes.' end,
      'RELIABILITY_SANCTION',
      sanction_id_to_use,
      jsonb_build_object(
        'active_strikes', active_after,
        'threshold', threshold_to_use,
        'sanction_kind', sanction_kind_to_use
      )
    );

    if release_future then
      refund_bps_to_use := (terms_to_use.policy_snapshot #>>
        '{solo,releaseFutureBookingsRefundBps}')::integer;

      for future_booking in
        select booking.*
        from public.open_queue_bookings booking
        join public.open_queue_games game on game.id = booking.game_id
        where booking.profile_id = attendance_to_use.profile_id
          and booking.status = 'CONFIRMED'
          and game.status in ('OPEN', 'FULL')
          and game.starts_at > occurred_at_to_use
          and booking.id is distinct from attendance_to_use.booking_id
        order by game.starts_at, booking.id
        for update of booking
      loop
        update public.open_queue_bookings
        set
          status = 'CANCELLED',
          team = null,
          played = false,
          rating_at_team_assignment = null,
          rating_at_match_start = null,
          rating_change = null,
          cancelled_at = occurred_at_to_use,
          refund_bps = refund_bps_to_use,
          refund_percent = round(refund_bps_to_use / 100.0)::integer,
          refund_amount_fils = (
            future_booking.base_amount_fils::bigint
              * refund_bps_to_use / 10000
          )::integer + future_booking.reliability_deposit_fils,
          refund_status = case when (
            future_booking.base_amount_fils::bigint
              * refund_bps_to_use / 10000
          )::integer + future_booking.reliability_deposit_fils > 0
            then 'PROCESSED' else 'NOT_DUE' end,
          payment_status = case
            when (
              future_booking.base_amount_fils::bigint
                * refund_bps_to_use / 10000
            )::integer + future_booking.reliability_deposit_fils
              >= future_booking.amount_paid_fils
              and future_booking.amount_paid_fils > 0 then 'REFUNDED'
            when (
              future_booking.base_amount_fils::bigint
                * refund_bps_to_use / 10000
            )::integer + future_booking.reliability_deposit_fils > 0
              then 'PARTIALLY_REFUNDED'
            else 'NO_REFUND'
          end,
          reliability_deposit_status = case
            when future_booking.reliability_deposit_fils > 0 then 'REFUNDED'
            else future_booking.reliability_deposit_status end
        where id = future_booking.id;

        update public.match_attendance_records attendance
        set
          cancelled_at = occurred_at_to_use,
          outcome = 'EXCUSED',
          strike_delta = 0,
          refund_bps = refund_bps_to_use,
          refund_amount_fils = (
            future_booking.base_amount_fils::bigint
              * refund_bps_to_use / 10000
          )::integer + future_booking.reliability_deposit_fils,
          deposit_resolution = case
            when attendance.reliability_deposit_fils > 0 then 'RETURNED'
            else attendance.deposit_resolution
          end,
          finalized_at = occurred_at_to_use,
          consequence_snapshot = jsonb_build_object(
            'outcome_code', 'EXCUSED',
            'reason', 'FUTURE_BOOKING_RELEASED_BY_SANCTION',
            'sanction_id', sanction_id_to_use,
            'policy_version_id', attendance_to_use.policy_version_id,
            'refund_bps', refund_bps_to_use
          )
        where attendance.booking_id = future_booking.id
          and attendance.outcome is null;

        insert into public.attendance_events (
          attendance_id,
          event_type,
          event_at,
          detail,
          idempotency_key
        )
        select
          attendance.id,
          'CANCELLED',
          occurred_at_to_use,
          attendance.consequence_snapshot,
          'sanction-release:' || attendance.id::text
        from public.match_attendance_records attendance
        where attendance.booking_id = future_booking.id
        on conflict (idempotency_key) do nothing;

        perform public.credit_field_wallet(
          future_booking.profile_id,
          (
            future_booking.base_amount_fils::bigint
              * refund_bps_to_use / 10000
          )::integer + future_booking.reliability_deposit_fils,
          'SUSPENSION_BOOKING_RELEASE',
          'reliability-release:' || future_booking.id::text || ':' || sanction_id_to_use::text,
          'Future booking released after a reliability suspension.',
          attendance_to_use.policy_version_id,
          future_booking.id,
          incident_id_to_use,
          jsonb_build_object('sanction_id', sanction_id_to_use)
        );
      end loop;
    end if;
  end loop;

  return incident_id_to_use;
end;
$$;

create or replace function public.settle_reliability_deposit(
  attendance_id_to_use uuid,
  return_to_wallet boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  attendance_to_use public.match_attendance_records%rowtype;
  booking_to_use public.open_queue_bookings%rowtype;
begin
  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.id = attendance_id_to_use
  for update;
  if attendance_to_use.id is null
    or attendance_to_use.reliability_deposit_fils <= 0
    or attendance_to_use.deposit_resolution in ('RETURNED', 'FORFEITED')
  then
    return;
  end if;

  select * into booking_to_use
  from public.open_queue_bookings booking
  where booking.id = attendance_to_use.booking_id
  for update;

  if return_to_wallet then
    perform public.credit_field_wallet(
      attendance_to_use.profile_id,
      attendance_to_use.reliability_deposit_fils,
      'RELIABILITY_DEPOSIT_RETURN',
      'deposit-return:' || attendance_to_use.id::text,
      'Reliability deposit returned after on-time check-in.',
      attendance_to_use.policy_version_id,
      attendance_to_use.booking_id,
      null,
      jsonb_build_object('attendance_id', attendance_to_use.id)
    );

    update public.match_attendance_records
    set deposit_resolution = 'RETURNED'
    where id = attendance_to_use.id;
    update public.open_queue_bookings
    set reliability_deposit_status = 'RETURNED'
    where id = attendance_to_use.booking_id;

    insert into public.attendance_events (
      attendance_id, event_type, detail, idempotency_key
    ) values (
      attendance_to_use.id,
      'DEPOSIT_RETURNED',
      jsonb_build_object('amount_fils', attendance_to_use.reliability_deposit_fils),
      'deposit-returned:' || attendance_to_use.id::text
    ) on conflict (idempotency_key) do nothing;
  else
    update public.match_attendance_records
    set deposit_resolution = 'FORFEITED'
    where id = attendance_to_use.id;
    update public.open_queue_bookings
    set reliability_deposit_status = 'FORFEITED'
    where id = attendance_to_use.booking_id;

    insert into public.attendance_events (
      attendance_id, event_type, detail, idempotency_key
    ) values (
      attendance_to_use.id,
      'DEPOSIT_FORFEITED',
      jsonb_build_object('amount_fils', attendance_to_use.reliability_deposit_fils),
      'deposit-forfeited:' || attendance_to_use.id::text
    ) on conflict (idempotency_key) do nothing;
  end if;
end;
$$;

create or replace function public.apply_attendance_refund(
  attendance_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  attendance_to_use public.match_attendance_records%rowtype;
  booking_to_use public.open_queue_bookings%rowtype;
  fee_refund_fils integer := 0;
  deposit_refund_fils integer := 0;
  total_refund_fils integer := 0;
begin
  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.id = attendance_id_to_use
  for update;
  if attendance_to_use.id is null
    or attendance_to_use.booking_id is null
  then
    return 0;
  end if;

  select * into booking_to_use
  from public.open_queue_bookings booking
  where booking.id = attendance_to_use.booking_id
  for update;
  if booking_to_use.id is null then
    return 0;
  end if;

  fee_refund_fils := (
    booking_to_use.base_amount_fils::bigint
      * attendance_to_use.refund_bps / 10000
  )::integer;
  deposit_refund_fils := case
    when attendance_to_use.deposit_resolution = 'RETURNED'
      then attendance_to_use.reliability_deposit_fils
    else 0
  end;
  total_refund_fils := fee_refund_fils + deposit_refund_fils;

  if fee_refund_fils > 0 then
    perform public.credit_field_wallet(
      attendance_to_use.profile_id,
      fee_refund_fils,
      'FIELD_CANCELLATION_REFUND',
      'attendance-fee-refund:' || attendance_to_use.id::text,
      'Policy-based attendance refund credited to Field Wallet.',
      attendance_to_use.policy_version_id,
      attendance_to_use.booking_id,
      null,
      jsonb_build_object(
        'attendance_id', attendance_to_use.id,
        'outcome', attendance_to_use.outcome,
        'refund_bps', attendance_to_use.refund_bps
      )
    );
  end if;

  update public.match_attendance_records
  set refund_amount_fils = greatest(refund_amount_fils, total_refund_fils)
  where id = attendance_to_use.id;

  update public.open_queue_bookings booking
  set
    refund_bps = greatest(coalesce(booking.refund_bps, 0),
      attendance_to_use.refund_bps),
    refund_percent = round(greatest(coalesce(booking.refund_bps, 0),
      attendance_to_use.refund_bps) / 100.0)::integer,
    refund_amount_fils = greatest(coalesce(booking.refund_amount_fils, 0),
      total_refund_fils),
    refund_status = case when total_refund_fils > 0
      then 'PROCESSED' else booking.refund_status end,
    payment_status = case
      when total_refund_fils >= booking.amount_paid_fils
        and booking.amount_paid_fils > 0 then 'REFUNDED'
      when total_refund_fils > 0 then 'PARTIALLY_REFUNDED'
      else booking.payment_status
    end
  where booking.id = booking_to_use.id;

  return total_refund_fils;
end;
$$;

create or replace function public.enforce_reliability_booking_restriction()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'CONFIRMED'
    and (
      tg_op = 'INSERT'
      or old.status is distinct from 'CONFIRMED'
    )
    and public.profile_has_active_reliability_booking_restriction(new.profile_id)
  then
    raise exception 'New bookings are unavailable while your reliability restriction is active.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_reliability_booking_restriction
on public.open_queue_bookings;
create trigger enforce_reliability_booking_restriction
before insert or update of status on public.open_queue_bookings
for each row execute function public.enforce_reliability_booking_restriction();

create or replace function public.profile_has_active_play_restriction(
  profile_id_to_check uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.moderation_actions action
    where action.subject_type = 'PLAYER'
      and action.subject_profile_id = profile_id_to_check
      and action.action_type in ('SUSPENSION', 'BAN')
      and action.restriction_scope in ('PLAY', 'ACCOUNT')
      and action.revoked_at is null
      and action.starts_at <= clock_timestamp()
      and (action.ends_at is null or action.ends_at > clock_timestamp())
  ) or exists (
    select 1
    from public.reliability_sanctions sanction
    where sanction.subject_type = 'PLAYER'
      and sanction.profile_id = profile_id_to_check
      and sanction.sanction_kind in (
        'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
      )
      and sanction.revoked_at is null
      and sanction.starts_at <= clock_timestamp()
      and (sanction.ends_at is null or sanction.ends_at > clock_timestamp())
  );
$$;
create or replace function public.book_open_queue_game(
  game_id_to_book uuid,
  role_to_book text,
  payment_method_to_use text,
  payment_reference_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  game_to_book public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  rating_to_use integer;
  booking_id uuid;
  confirmed_count integer;
  active_strikes integer;
  deposit_threshold integer;
  deposit_bps_to_use integer;
  discount_bps_to_use integer := 0;
  base_amount_to_use integer;
  deposit_amount_to_use integer := 0;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if role_to_book not in ('GK', 'DEF', 'MID', 'ATT') then
    raise exception 'Choose a valid position.';
  end if;
  if payment_method_to_use not in ('APPLE_PAY', 'BENEFITPAY', 'MOCK') then
    raise exception 'Choose a valid payment method.';
  end if;

  perform pg_advisory_xact_lock(hashtext(user_id::text)::bigint);

  if public.profile_has_active_reliability_booking_restriction(user_id) then
    raise exception 'New bookings are unavailable while your reliability restriction is active.';
  end if;

  select * into game_to_book
  from public.open_queue_games game
  where game.id = game_id_to_book
  for update;

  if game_to_book.id is null then
    raise exception 'Open Queue game not found.';
  end if;
  if game_to_book.status <> 'OPEN' then
    raise exception 'This Open Queue game is full.';
  end if;
  if clock_timestamp() >= game_to_book.starts_at then
    raise exception 'This Open Queue game has already started.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    where existing.game_id = game_to_book.id
      and existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
  ) then
    raise exception 'You already booked this Open Queue game.';
  end if;

  if exists (
    select 1
    from public.open_queue_bookings existing
    join public.open_queue_games other_game on other_game.id = existing.game_id
    where existing.profile_id = user_id
      and existing.status = 'CONFIRMED'
      and other_game.status in ('OPEN', 'FULL', 'LIVE')
      and tstzrange(other_game.starts_at, other_game.ends_at, '[)') &&
          tstzrange(game_to_book.starts_at, game_to_book.ends_at, '[)')
  ) then
    raise exception 'You already have another game at this time.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms('SOLO', game_to_book.id);
  if clock_timestamp() >= terms_to_use.check_in_deadline_at
    and not coalesce(
      (terms_to_use.policy_snapshot #>>
        '{replacement,postCheckInDeadlineMarketplaceEnabled}')::boolean,
      false
    )
  then
    raise exception 'Registration closed at the match check-in deadline.';
  end if;
  active_strikes := public.active_reliability_strikes(user_id);
  deposit_threshold := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,activeStrikeThreshold}')::integer;
  deposit_bps_to_use := (terms_to_use.policy_snapshot #>>
    '{solo,reliabilityDeposit,depositBps}')::integer;

  if game_to_book.replacement_offer_expires_at > clock_timestamp()
    and game_to_book.replacement_discount_role = role_to_book
  then
    discount_bps_to_use := game_to_book.replacement_discount_bps;
  end if;

  base_amount_to_use := (
    game_to_book.price_fils::bigint * (10000 - discount_bps_to_use) / 10000
  )::integer;
  if active_strikes >= deposit_threshold then
    deposit_amount_to_use := ceiling(
      base_amount_to_use::numeric * deposit_bps_to_use / 10000
    )::integer;
  end if;

  insert into public.player_ratings (profile_id)
  values (user_id)
  on conflict (profile_id) do nothing;

  select skill_rating into rating_to_use
  from public.player_ratings
  where profile_id = user_id
  for update;

  insert into public.open_queue_bookings (
    game_id,
    profile_id,
    role,
    player_rating_at_booking,
    amount_paid_fils,
    base_amount_fils,
    discount_bps,
    reliability_deposit_fils,
    reliability_deposit_status,
    reliability_policy_version_id,
    payment_method,
    payment_reference
  ) values (
    game_to_book.id,
    user_id,
    role_to_book,
    rating_to_use,
    base_amount_to_use + deposit_amount_to_use,
    base_amount_to_use,
    discount_bps_to_use,
    deposit_amount_to_use,
    case when deposit_amount_to_use > 0 then 'HELD' else 'NOT_REQUIRED' end,
    terms_to_use.policy_version_id,
    payment_method_to_use,
    nullif(trim(payment_reference_to_use), '')
  ) returning id into booking_id;

  if discount_bps_to_use > 0 then
    update public.open_queue_games
    set
      replacement_discount_bps = 0,
      replacement_discount_role = null,
      replacement_source_booking_id = null,
      replacement_offer_expires_at = null
    where id = game_to_book.id;
  end if;

  select count(*)::integer into confirmed_count
  from public.open_queue_bookings
  where game_id = game_to_book.id
    and status = 'CONFIRMED';

  if confirmed_count = game_to_book.capacity then
    perform public.assign_open_queue_teams(game_to_book.id);
  end if;

  return booking_id;
end;
$$;

create or replace function public.open_queue_cancellation_quote(
  booking_id_to_preview uuid,
  profile_id_to_use uuid,
  server_now_to_use timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  booking_to_preview public.open_queue_bookings%rowtype;
  game_to_preview public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  rule_to_use jsonb;
  outcome_to_use text;
  band_to_use text;
  early_hours numeric;
  late_hours numeric;
  hours_before numeric;
  refund_bps_to_use integer;
  strike_delta_to_use integer;
  fee_refund_fils integer;
  deposit_refund_fils integer := 0;
  deposit_forfeited boolean := false;
  can_cancel_to_use boolean;
  next_cutoff timestamptz;
  has_rating_events boolean;
  attendance_is_final boolean;
  explanation_to_use text;
begin
  select * into booking_to_preview
  from public.open_queue_bookings booking
  where booking.id = booking_id_to_preview
    and booking.profile_id = profile_id_to_use;
  if booking_to_preview.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into game_to_preview
  from public.open_queue_games game
  where game.id = booking_to_preview.game_id;
  terms_to_use := public.ensure_match_reliability_terms(
    'SOLO',
    game_to_preview.id
  );
  perform public.ensure_match_attendance_records('SOLO', game_to_preview.id);

  select exists (
    select 1
    from public.match_attendance_records attendance
    where attendance.open_queue_game_id = game_to_preview.id
      and attendance.profile_id = profile_id_to_use
      and attendance.outcome is not null
  ) into attendance_is_final;

  select exists (
    select 1
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = game_to_preview.id
  ) into has_rating_events;

  early_hours := (terms_to_use.policy_snapshot #>>
    '{solo,cancellations,early,minimumHoursBeforeKickoff}')::numeric;
  late_hours := (terms_to_use.policy_snapshot #>>
    '{solo,cancellations,late,minimumHoursBeforeKickoff}')::numeric;
  hours_before := extract(epoch from (terms_to_use.kickoff_at - server_now_to_use)) / 3600;

  if server_now_to_use >= terms_to_use.kickoff_at then
    band_to_use := 'afterKickoff';
    outcome_to_use := 'NO_SHOW';
    rule_to_use := terms_to_use.policy_snapshot #>
      '{solo,cancellations,afterKickoff}';
    next_cutoff := terms_to_use.no_show_cutoff_at;
  elsif hours_before >= early_hours then
    band_to_use := 'early';
    outcome_to_use := 'CANCELLED_EARLY';
    rule_to_use := terms_to_use.policy_snapshot #>
      '{solo,cancellations,early}';
    next_cutoff := terms_to_use.kickoff_at
      - make_interval(hours => early_hours::integer);
  elsif hours_before >= late_hours then
    band_to_use := 'late';
    outcome_to_use := 'CANCELLED_LATE';
    rule_to_use := terms_to_use.policy_snapshot #>
      '{solo,cancellations,late}';
    next_cutoff := terms_to_use.kickoff_at
      - make_interval(hours => late_hours::integer);
  else
    band_to_use := 'veryLate';
    outcome_to_use := 'CANCELLED_VERY_LATE';
    rule_to_use := terms_to_use.policy_snapshot #>
      '{solo,cancellations,veryLate}';
    next_cutoff := terms_to_use.kickoff_at;
  end if;

  refund_bps_to_use := (rule_to_use ->> 'refundBps')::integer;
  strike_delta_to_use := (rule_to_use ->> 'strikes')::integer;
  fee_refund_fils := (
    booking_to_preview.base_amount_fils::bigint * refund_bps_to_use / 10000
  )::integer;

  if booking_to_preview.reliability_deposit_fils > 0 then
    select exists (
      select 1
      from jsonb_array_elements_text(
        terms_to_use.policy_snapshot #>
          '{solo,reliabilityDeposit,forfeitOutcomes}'
      ) forfeited(outcome)
      where forfeited.outcome = outcome_to_use
    ) into deposit_forfeited;
    if not deposit_forfeited then
      deposit_refund_fils := booking_to_preview.reliability_deposit_fils;
    end if;
  end if;

  can_cancel_to_use := booking_to_preview.status = 'CONFIRMED'
    and booking_to_preview.cancelled_at is null
    and not attendance_is_final
    and game_to_preview.white_score is null
    and game_to_preview.black_score is null
    and not has_rating_events
    and server_now_to_use < terms_to_use.no_show_cutoff_at
    and game_to_preview.status in ('OPEN', 'FULL', 'LIVE');

  explanation_to_use := case when outcome_to_use = 'NO_SHOW'
      then 'Kickoff has passed. This cancellation is recorded as a no-show. '
      else 'Cancellation outcome: ' || replace(initcap(lower(outcome_to_use)), '_', ' ') || '. '
    end
    || case when strike_delta_to_use = 0
      then 'No reliability strike is added. '
      else strike_delta_to_use || ' reliability ' ||
        case when strike_delta_to_use = 1 then 'strike is' else 'strikes are' end ||
        ' added. '
    end
    || round(refund_bps_to_use / 100.0)::integer ||
      '% of the match fee returns to your Field Wallet.'
    || case
      when booking_to_preview.reliability_deposit_fils <= 0 then ''
      when deposit_forfeited then ' The reliability deposit is forfeited.'
      else ' The reliability deposit returns to your Field Wallet.'
    end;

  return jsonb_build_object(
    'can_cancel', can_cancel_to_use,
    'server_now', server_now_to_use,
    'policy_version_id', terms_to_use.policy_version_id,
    'outcome_code', outcome_to_use,
    'cancellation_band', band_to_use,
    'strike_delta', strike_delta_to_use,
    'refund_bps', refund_bps_to_use,
    'refund_percent', round(refund_bps_to_use / 100.0)::integer,
    'refund_amount_fils', fee_refund_fils + deposit_refund_fils,
    'fee_refund_amount_fils', fee_refund_fils,
    'deposit_refund_amount_fils', deposit_refund_fils,
    'refund_destination', 'FIELD_WALLET',
    'deposit_forfeited', deposit_forfeited,
    'refund_cutoff_at', next_cutoff,
    'kickoff_at', terms_to_use.kickoff_at,
    'check_in_deadline_at', terms_to_use.check_in_deadline_at,
    'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
    'explanation', explanation_to_use
  );
end;
$$;

drop function if exists public.preview_open_queue_cancellation(uuid);
create function public.preview_open_queue_cancellation(
  booking_id_to_preview uuid
)
returns table (
  can_cancel boolean,
  refund_percent integer,
  refund_amount_fils integer,
  refund_cutoff_at timestamptz,
  server_now timestamptz,
  policy_version_id uuid,
  outcome_code text,
  strike_delta integer,
  refund_bps integer,
  refund_destination text,
  deposit_forfeited boolean,
  explanation text,
  check_in_deadline_at timestamptz,
  no_show_cutoff_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  quote jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  quote := public.open_queue_cancellation_quote(
    booking_id_to_preview,
    user_id,
    clock_timestamp()
  );

  return query select
    (quote ->> 'can_cancel')::boolean,
    (quote ->> 'refund_percent')::integer,
    (quote ->> 'refund_amount_fils')::integer,
    (quote ->> 'refund_cutoff_at')::timestamptz,
    (quote ->> 'server_now')::timestamptz,
    (quote ->> 'policy_version_id')::uuid,
    quote ->> 'outcome_code',
    (quote ->> 'strike_delta')::integer,
    (quote ->> 'refund_bps')::integer,
    quote ->> 'refund_destination',
    (quote ->> 'deposit_forfeited')::boolean,
    quote ->> 'explanation',
    (quote ->> 'check_in_deadline_at')::timestamptz,
    (quote ->> 'no_show_cutoff_at')::timestamptz;
end;
$$;

create or replace function public.cancel_open_queue_booking(
  booking_id_to_cancel uuid
)
returns public.open_queue_bookings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  booking_to_cancel public.open_queue_bookings%rowtype;
  game_to_reopen public.open_queue_games%rowtype;
  quote jsonb;
  attendance_to_use public.match_attendance_records%rowtype;
  cancelled_booking public.open_queue_bookings%rowtype;
  outcome_to_use text;
  strike_delta_to_use integer;
  refund_bps_to_use integer;
  refund_amount_to_use integer;
  incident_id_to_use uuid;
  late_rule jsonb;
  offer_expiry timestamptz;
  replacement_marketplace_open boolean := false;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  perform pg_advisory_xact_lock(hashtext(user_id::text)::bigint);

  select game.* into game_to_reopen
  from public.open_queue_bookings booking
  join public.open_queue_games game on game.id = booking.game_id
  where booking.id = booking_id_to_cancel
    and booking.profile_id = user_id
  for update of game;
  if game_to_reopen.id is null then
    raise exception 'Booking not found.';
  end if;

  select * into booking_to_cancel
  from public.open_queue_bookings booking
  where booking.id = booking_id_to_cancel
    and booking.profile_id = user_id
  for update;

  quote := public.open_queue_cancellation_quote(
    booking_to_cancel.id,
    user_id,
    clock_timestamp()
  );
  if not (quote ->> 'can_cancel')::boolean then
    raise exception 'This booking can no longer be cancelled.';
  end if;

  perform public.ensure_match_attendance_records('SOLO', game_to_reopen.id);
  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.open_queue_game_id = game_to_reopen.id
    and attendance.profile_id = user_id
  for update;

  outcome_to_use := quote ->> 'outcome_code';
  strike_delta_to_use := (quote ->> 'strike_delta')::integer;
  refund_bps_to_use := (quote ->> 'refund_bps')::integer;
  refund_amount_to_use := (quote ->> 'refund_amount_fils')::integer;

  update public.match_attendance_records
  set
    cancelled_at = clock_timestamp(),
    outcome = outcome_to_use,
    strike_delta = strike_delta_to_use,
    refund_bps = refund_bps_to_use,
    refund_amount_fils = refund_amount_to_use,
    deposit_resolution = case
      when reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
      when (quote ->> 'deposit_forfeited')::boolean then 'FORFEITED'
      else 'RETURNED'
    end,
    positive_sr_multiplier_bps = 10000,
    negative_sr_multiplier_bps = 10000,
    finalized_at = clock_timestamp(),
    appeal_due_at = clock_timestamp() + make_interval(
      hours => (select (terms.policy_snapshot #>>
        '{attendance,appealWindowHours}')::integer
        from public.match_reliability_terms terms
        where terms.id = attendance_to_use.terms_id)
    ),
    consequence_snapshot = quote
  where id = attendance_to_use.id
  returning * into attendance_to_use;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    event_at,
    detail,
    idempotency_key
  ) values (
    attendance_to_use.id,
    'CANCELLED',
    attendance_to_use.cancelled_at,
    quote,
    'booking-cancelled:' || booking_to_cancel.id::text
  ) on conflict (idempotency_key) do nothing;

  if outcome_to_use = 'NO_SHOW' then
    update public.open_queue_bookings
    set
      played = false,
      cancelled_at = clock_timestamp(),
      refund_bps = refund_bps_to_use,
      refund_percent = round(refund_bps_to_use / 100.0)::integer,
      refund_amount_fils = refund_amount_to_use,
      refund_status = 'NOT_DUE',
      payment_status = 'NO_REFUND',
      reliability_deposit_status = case
        when reliability_deposit_fils > 0 then 'FORFEITED'
        else reliability_deposit_status end
    where id = booking_to_cancel.id
    returning * into cancelled_booking;
  else
    update public.open_queue_bookings
    set
      status = 'CANCELLED',
      team = null,
      cancelled_at = clock_timestamp(),
      refund_bps = refund_bps_to_use,
      refund_percent = round(refund_bps_to_use / 100.0)::integer,
      refund_amount_fils = refund_amount_to_use,
      refund_status = case when refund_amount_to_use > 0
        then 'PROCESSED' else 'NOT_DUE' end,
      payment_status = case
        when refund_amount_to_use = amount_paid_fils then 'REFUNDED'
        when refund_amount_to_use > 0 then 'PARTIALLY_REFUNDED'
        else 'NO_REFUND' end,
      reliability_deposit_status = case
        when reliability_deposit_fils <= 0 then reliability_deposit_status
        when (quote ->> 'deposit_forfeited')::boolean then 'FORFEITED'
        else 'REFUNDED' end
    where id = booking_to_cancel.id
    returning * into cancelled_booking;
  end if;

  if refund_amount_to_use > 0 then
    perform public.credit_field_wallet(
      user_id,
      refund_amount_to_use,
      'BOOKING_REFUND',
      'booking-refund:' || booking_to_cancel.id::text,
      'Solo booking refund credited to Field Wallet.',
      attendance_to_use.policy_version_id,
      booking_to_cancel.id,
      null,
      quote
    );
  end if;

  incident_id_to_use := public.record_reliability_incident(
    attendance_to_use.id,
    outcome_to_use,
    strike_delta_to_use,
    attendance_to_use.finalized_at
  );

  select
    clock_timestamp() < terms.check_in_deadline_at
    or coalesce(
      (terms.policy_snapshot #>>
        '{replacement,postCheckInDeadlineMarketplaceEnabled}')::boolean,
      false
    )
  into replacement_marketplace_open
  from public.match_reliability_terms terms
  where terms.id = attendance_to_use.terms_id;

  if replacement_marketplace_open and outcome_to_use in (
    'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
  ) then
    select terms.policy_snapshot #> array[
      'solo',
      'cancellations',
      quote ->> 'cancellation_band'
    ] into late_rule
    from public.match_reliability_terms terms
    where terms.id = attendance_to_use.terms_id;
    offer_expiry := game_to_reopen.starts_at;

    if coalesce((late_rule ->> 'advertise')::boolean, false) then
      update public.open_queue_games
      set
        replacement_discount_bps = (late_rule ->> 'discountBps')::integer,
        replacement_discount_role = booking_to_cancel.role,
        replacement_source_booking_id = booking_to_cancel.id,
        replacement_offer_expires_at = offer_expiry
      where id = game_to_reopen.id;
    end if;

    if coalesce((late_rule ->> 'notify')::boolean, false) then
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
        profile.id,
        'OPEN_QUEUE_REPLACEMENT_AVAILABLE',
        case
          when (late_rule ->> 'discountBps')::integer > 0
            then 'A discounted solo spot just opened'
          else 'A solo spot just opened'
        end,
        booking_to_cancel.role || ' at ' || game_to_reopen.venue ||
          case
            when (late_rule ->> 'discountBps')::integer > 0
              then ' is now ' ||
                round((late_rule ->> 'discountBps')::integer / 100.0)::integer ||
                '% off.'
            else ' is available now.'
          end,
        'OPEN_QUEUE_GAME',
        game_to_reopen.id,
        jsonb_build_object(
          'game_id', game_to_reopen.id,
          'role', booking_to_cancel.role,
          'discount_bps', (late_rule ->> 'discountBps')::integer,
          'expires_at', offer_expiry
        )
      from public.profiles profile
      where profile.id <> user_id
        and not public.profile_has_active_play_restriction(profile.id)
        and not public.profile_has_active_reliability_booking_restriction(profile.id)
        and not exists (
          select 1
          from public.open_queue_bookings existing
          where existing.game_id = game_to_reopen.id
            and existing.profile_id = profile.id
            and existing.status = 'CONFIRMED'
        );
    end if;
  end if;

  return cancelled_booking;
end;
$$;

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
  terms_to_use public.match_reliability_terms%rowtype;
  server_now_to_use timestamptz := clock_timestamp();
  unresolved_count integer;
  no_show_count integer;
  expected_count_to_use integer;
  checked_in_count_to_use integer;
  on_time_count_to_use integer;
  late_count_to_use integer;
  players_to_use jsonb;
begin
  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  select
    count(*) filter (
      where attendance.outcome is null
    )::integer,
    count(*) filter (
      where attendance.outcome = 'NO_SHOW'
    )::integer,
    count(*)::integer,
    count(*) filter (
      where attendance.checked_in_at is not null
    )::integer,
    count(*) filter (
      where attendance.outcome = 'ON_TIME'
    )::integer,
    count(*) filter (
      where attendance.outcome = 'LATE'
    )::integer
  into
    unresolved_count,
    no_show_count,
    expected_count_to_use,
    checked_in_count_to_use,
    on_time_count_to_use,
    late_count_to_use
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
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
    and coalesce(attendance.outcome, '') not in (
      'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
    );

  return jsonb_build_object(
    'server_now', server_now_to_use,
    'policy_version_id', terms_to_use.policy_version_id,
    'kickoff_at', terms_to_use.kickoff_at,
    'check_in_opens_at', terms_to_use.check_in_opens_at,
    'check_in_deadline_at', terms_to_use.check_in_deadline_at,
    'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
    'can_check_in',
      server_now_to_use >= terms_to_use.check_in_opens_at
      and server_now_to_use < terms_to_use.no_show_cutoff_at,
    'can_finalize_attendance',
      server_now_to_use >= terms_to_use.no_show_cutoff_at
      and unresolved_count > 0,
    'attendance_finalized', unresolved_count = 0,
    'expected_count', expected_count_to_use,
    'checked_in_count', checked_in_count_to_use,
    'on_time_count', on_time_count_to_use,
    'late_count', late_count_to_use,
    'missing_count', case when unresolved_count = 0
      then no_show_count else unresolved_count end,
    'players', players_to_use
  );
end;
$$;

create or replace function public.referee_check_in_player(
  actor_referee_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  profile_id_to_check_in uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  attendance_to_use public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  checked_in_at_to_use timestamptz := clock_timestamp();
  outcome_to_use text;
  rule_to_use jsonb;
  strike_delta_to_use integer;
  positive_multiplier integer := 10000;
  negative_multiplier integer := 10000;
  forfeit_deposit boolean;
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'You are not assigned to manage this match.';
  end if;
  if normalized_kind = 'SOLO' and not exists (
    select 1
    from public.open_queue_games game
    where game.id = match_id_to_use
      and game.status in ('OPEN', 'FULL', 'LIVE')
  ) then
    raise exception 'This solo match is not active.';
  elsif normalized_kind = 'CLAN' and not exists (
    select 1
    from public.fixtures fixture
    where fixture.id = match_id_to_use
      and fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
  ) then
    raise exception 'This clan match is not active.';
  end if;

  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  select * into attendance_to_use
  from public.match_attendance_records attendance
  where attendance.terms_id = terms_to_use.id
    and attendance.profile_id = profile_id_to_check_in
    and (
      normalized_kind <> 'CLAN'
      or attendance.expected_for_match
    )
  for update;
  if attendance_to_use.id is null then
    raise exception 'This player is not on the expected match roster.';
  end if;
  if attendance_to_use.checked_in_at is not null then
    return public.get_match_reliability_context(normalized_kind, match_id_to_use);
  end if;
  if attendance_to_use.outcome is not null then
    raise exception 'This player already has a final attendance outcome.';
  end if;
  if checked_in_at_to_use < terms_to_use.check_in_opens_at then
    raise exception 'Check-in opens at %.', terms_to_use.check_in_opens_at;
  end if;
  if checked_in_at_to_use >= terms_to_use.no_show_cutoff_at then
    raise exception 'The no-show cutoff has passed. Finalize attendance instead.';
  end if;

  if checked_in_at_to_use <= terms_to_use.check_in_deadline_at then
    outcome_to_use := 'ON_TIME';
    rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,onTime}';
  else
    outcome_to_use := 'LATE';
    rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,late}';
    positive_multiplier := (terms_to_use.policy_snapshot #>>
      '{sr,latePositiveMultiplierBps}')::integer;
    negative_multiplier := (terms_to_use.policy_snapshot #>>
      '{sr,lateNegativeMultiplierBps}')::integer;
  end if;
  strike_delta_to_use := (rule_to_use ->> 'strikes')::integer;
  select exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #>
        '{solo,reliabilityDeposit,forfeitOutcomes}'
    ) forfeited(outcome)
    where forfeited.outcome = outcome_to_use
  ) into forfeit_deposit;

  update public.match_attendance_records
  set
    checked_in_at = checked_in_at_to_use,
    checked_in_by = actor_referee_id,
    outcome = outcome_to_use,
    strike_delta = strike_delta_to_use,
    refund_bps = (rule_to_use ->> 'refundBps')::integer,
    positive_sr_multiplier_bps = positive_multiplier,
    negative_sr_multiplier_bps = negative_multiplier,
    finalized_at = checked_in_at_to_use,
    appeal_due_at = checked_in_at_to_use + make_interval(
      hours => (terms_to_use.policy_snapshot #>>
        '{attendance,appealWindowHours}')::integer
    ),
    consequence_snapshot = jsonb_build_object(
      'policy_version_id', terms_to_use.policy_version_id,
      'outcome_code', outcome_to_use,
      'strike_delta', strike_delta_to_use,
      'refund_bps', (rule_to_use ->> 'refundBps')::integer,
      'deposit_forfeited', forfeit_deposit,
      'positive_sr_multiplier_bps', positive_multiplier,
      'negative_sr_multiplier_bps', negative_multiplier,
      'checked_in_at', checked_in_at_to_use,
      'check_in_opens_at', terms_to_use.check_in_opens_at,
      'check_in_deadline_at', terms_to_use.check_in_deadline_at
    )
  where id = attendance_to_use.id
  returning * into attendance_to_use;

  insert into public.attendance_events (
    attendance_id,
    event_type,
    actor_referee_id,
    event_at,
    detail,
    idempotency_key
  ) values (
    attendance_to_use.id,
    'CHECKED_IN',
    actor_referee_id,
    checked_in_at_to_use,
    attendance_to_use.consequence_snapshot,
    'checked-in:' || attendance_to_use.id::text
  ) on conflict (idempotency_key) do nothing;

  perform public.settle_reliability_deposit(
    attendance_to_use.id,
    not forfeit_deposit
  );
  perform public.apply_attendance_refund(attendance_to_use.id);

  perform public.record_reliability_incident(
    attendance_to_use.id,
    outcome_to_use,
    strike_delta_to_use,
    checked_in_at_to_use
  );

  if strike_delta_to_use > 0 then
    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    ) values (
      attendance_to_use.profile_id,
      'RELIABILITY_OUTCOME',
      'Attendance recorded as late',
      'Checked in after the hard deadline. ' || strike_delta_to_use ||
        case when strike_delta_to_use = 1
          then ' reliability strike was added.'
          else ' reliability strikes were added.' end,
      'MATCH_ATTENDANCE',
      attendance_to_use.id,
      attendance_to_use.consequence_snapshot
    );
  end if;

  return public.get_match_reliability_context(normalized_kind, match_id_to_use);
end;
$$;

create or replace function public.finalize_match_attendance_internal(
  match_kind_to_use text,
  match_id_to_use uuid,
  actor_referee_id_to_use uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_finalize public.match_attendance_records%rowtype;
  rule_to_use jsonb;
  strike_delta_to_use integer;
  forfeit_deposit boolean;
  finalized_count integer := 0;
  finalized_at_to_use timestamptz := clock_timestamp();
begin
  perform public.ensure_match_attendance_records(normalized_kind, match_id_to_use);
  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );

  if finalized_at_to_use < terms_to_use.no_show_cutoff_at then
    return 0;
  end if;

  rule_to_use := terms_to_use.policy_snapshot #> '{solo,outcomes,noShow}';
  strike_delta_to_use := (rule_to_use ->> 'strikes')::integer;
  select exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #>
        '{solo,reliabilityDeposit,forfeitOutcomes}'
    ) forfeited(outcome)
    where forfeited.outcome = 'NO_SHOW'
  ) into forfeit_deposit;

  for attendance_to_finalize in
    select *
    from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.outcome is null
      and (
        normalized_kind <> 'CLAN'
        or attendance.expected_for_match
      )
    order by attendance.profile_id
    for update
  loop
    update public.match_attendance_records
    set
      outcome = 'NO_SHOW',
      strike_delta = strike_delta_to_use,
      refund_bps = (rule_to_use ->> 'refundBps')::integer,
      refund_amount_fils = 0,
      positive_sr_multiplier_bps = 10000,
      negative_sr_multiplier_bps = 10000,
      finalized_at = finalized_at_to_use,
      appeal_due_at = finalized_at_to_use + make_interval(
        hours => (terms_to_use.policy_snapshot #>>
          '{attendance,appealWindowHours}')::integer
      ),
      consequence_snapshot = jsonb_build_object(
        'policy_version_id', terms_to_use.policy_version_id,
        'outcome_code', 'NO_SHOW',
        'strike_delta', strike_delta_to_use,
        'refund_bps', (rule_to_use ->> 'refundBps')::integer,
        'no_show_cutoff_at', terms_to_use.no_show_cutoff_at,
        'finalized_at', finalized_at_to_use
      )
    where id = attendance_to_finalize.id
    returning * into attendance_to_finalize;

    if attendance_to_finalize.booking_id is not null then
      update public.open_queue_bookings
      set
        played = false,
        reliability_deposit_status = case
          when reliability_deposit_fils > 0 and forfeit_deposit then 'FORFEITED'
          when reliability_deposit_fils > 0 then 'RETURNED'
          else reliability_deposit_status end
      where id = attendance_to_finalize.booking_id
        and not exists (
          select 1
          from public.player_rating_events event
          where event.source_type = 'OPEN_QUEUE'
            and event.source_id = attendance_to_finalize.open_queue_game_id
        );
    end if;

    insert into public.attendance_events (
      attendance_id,
      event_type,
      actor_referee_id,
      event_at,
      detail,
      idempotency_key
    ) values (
      attendance_to_finalize.id,
      'NO_SHOW_FINALIZED',
      actor_referee_id_to_use,
      finalized_at_to_use,
      attendance_to_finalize.consequence_snapshot,
      'no-show:' || attendance_to_finalize.id::text
    ) on conflict (idempotency_key) do nothing;

    perform public.settle_reliability_deposit(
      attendance_to_finalize.id,
      not forfeit_deposit
    );
    perform public.apply_attendance_refund(attendance_to_finalize.id);
    perform public.record_reliability_incident(
      attendance_to_finalize.id,
      'NO_SHOW',
      strike_delta_to_use,
      finalized_at_to_use
    );

    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    ) values (
      attendance_to_finalize.profile_id,
      'RELIABILITY_OUTCOME',
      'Attendance recorded as a no-show',
      'The no-show cutoff passed without a Field Host check-in. ' ||
        strike_delta_to_use || ' reliability strikes were added.',
      'MATCH_ATTENDANCE',
      attendance_to_finalize.id,
      attendance_to_finalize.consequence_snapshot
    );

    finalized_count := finalized_count + 1;
  end loop;

  return finalized_count;
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
begin
  if not public.referee_can_manage_reliability_match(
    actor_referee_id,
    normalized_kind,
    match_id_to_use
  ) then
    raise exception 'You are not assigned to manage this match.';
  end if;
  if normalized_kind = 'SOLO' and not exists (
    select 1 from public.open_queue_games game
    where game.id = match_id_to_use
      and game.status in ('OPEN', 'FULL', 'LIVE')
  ) then
    raise exception 'This solo match is not active.';
  elsif normalized_kind = 'CLAN' and not exists (
    select 1 from public.fixtures fixture
    where fixture.id = match_id_to_use
      and fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
  ) then
    raise exception 'This clan match is not active.';
  end if;

  perform public.finalize_match_attendance_internal(
    normalized_kind,
    match_id_to_use,
    actor_referee_id
  );
  return public.get_match_reliability_context(
    normalized_kind,
    match_id_to_use
  );
end;
$$;

create or replace function public.finalize_due_match_attendance()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  finalized_total integer := 0;
begin
  for candidate in
    select 'SOLO'::text as match_kind, game.id as match_id
    from public.open_queue_games game
    where game.status in ('FULL', 'LIVE')
      and game.starts_at <= clock_timestamp()
      and game.starts_at > clock_timestamp() - interval '1 day'
  loop
    begin
      finalized_total := finalized_total +
        public.finalize_match_attendance_internal(
          candidate.match_kind,
          candidate.match_id,
          null
        );
    exception
      when others then
        raise warning 'Could not finalize % attendance for %: %',
          candidate.match_kind,
          candidate.match_id,
          sqlerrm;
    end;
  end loop;
  return finalized_total;
end;
$$;

create or replace function public.get_my_reliability_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  server_now_to_use timestamptz := statement_timestamp();
  policy_to_use public.reliability_policy_versions%rowtype;
  active_strikes_to_use integer;
  deposit_threshold integer;
  deposit_bps_to_use integer;
  booking_restricted_until timestamptz;
  participation_suspended_until timestamptz;
  indefinite_suspension boolean;
  active_sanction_to_use jsonb;
  wallet_balance_to_use bigint := 0;
  incidents_to_use jsonb;
  appeals_to_use jsonb;
  message_to_use text;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;

  select * into policy_to_use
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= server_now_to_use
  order by policy.effective_from desc, policy.version desc
  limit 1;

  active_strikes_to_use := public.active_reliability_strikes(
    user_id,
    server_now_to_use
  );
  deposit_threshold := (policy_to_use.config #>>
    '{solo,reliabilityDeposit,activeStrikeThreshold}')::integer;
  deposit_bps_to_use := (policy_to_use.config #>>
    '{solo,reliabilityDeposit,depositBps}')::integer;

  select
    max(sanction.ends_at) filter (
      where sanction.sanction_kind = 'BOOKING_RESTRICTION'
    ),
    max(sanction.ends_at) filter (
      where sanction.sanction_kind = 'PARTICIPATION_SUSPENSION'
    ),
    bool_or(
      sanction.sanction_kind = 'INDEFINITE_SUSPENSION'
      and sanction.ends_at is null
    )
  into
    booking_restricted_until,
    participation_suspended_until,
    indefinite_suspension
  from public.reliability_sanctions sanction
  where sanction.subject_type = 'PLAYER'
    and sanction.profile_id = user_id
    and sanction.revoked_at is null
    and sanction.starts_at <= server_now_to_use
    and (sanction.ends_at is null or sanction.ends_at > server_now_to_use);

  select jsonb_build_object(
    'id', sanction.id,
    'kind', sanction.sanction_kind,
    'threshold', sanction.threshold,
    'starts_at', sanction.starts_at,
    'ends_at', sanction.ends_at,
    'release_future_bookings', sanction.release_future_bookings
  ) into active_sanction_to_use
  from public.reliability_sanctions sanction
  where sanction.subject_type = 'PLAYER'
    and sanction.profile_id = user_id
    and sanction.sanction_kind <> 'WARNING'
    and sanction.revoked_at is null
    and sanction.starts_at <= server_now_to_use
    and (sanction.ends_at is null or sanction.ends_at > server_now_to_use)
  order by case sanction.sanction_kind
    when 'INDEFINITE_SUSPENSION' then 0
    when 'PARTICIPATION_SUSPENSION' then 1
    else 2
  end, sanction.created_at desc
  limit 1;

  select coalesce((
    select wallet.balance_fils
    from public.field_wallet_accounts wallet
    where wallet.profile_id = user_id
  ), 0) into wallet_balance_to_use;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', appeal.id,
      'attendance_id', appeal.attendance_id,
      'category', appeal.category,
      'status', appeal.status,
      'appeal_due_at', appeal.appeal_due_at,
      'created_at', appeal.created_at,
      'reviewed_at', appeal.reviewed_at,
      'resolution_note', appeal.resolution_note
    ) order by appeal.created_at desc, appeal.id desc
  ), '[]'::jsonb) into appeals_to_use
  from (
    select appeal.*
    from public.reliability_appeals appeal
    where appeal.appellant_profile_id = user_id
    order by appeal.created_at desc, appeal.id desc
    limit 20
  ) appeal;

  select coalesce(jsonb_agg(
    history.incident_payload
    order by history.finalized_at desc, history.attendance_record_id
  ), '[]'::jsonb) into incidents_to_use
  from (
    select
      attendance.finalized_at,
      attendance.id as attendance_record_id,
      jsonb_build_object(
        'attendance_record_id', attendance.id,
        'outcome', attendance.outcome,
        'strike_delta', attendance.strike_delta,
        'occurred_at', attendance.finalized_at,
        'checked_in_at', attendance.checked_in_at,
        'check_in_deadline_at', attendance.check_in_deadline_at,
        'appeal_deadline_at', attendance.appeal_due_at,
        'strike_expires_at', incident.expires_at,
        'appeal_status', appeal.status,
        'allowed_appeal_categories', coalesce(
          terms.policy_snapshot #> '{appeals,allowedCategories}',
          '[]'::jsonb
        ),
        'can_appeal',
          attendance.strike_delta > 0
          and attendance.appeal_due_at > server_now_to_use
          and appeal.id is null,
        'match_label', case attendance.match_kind
          when 'SOLO' then coalesce(game.venue, 'Solo match')
          else coalesce(
            home_clan.tag || ' vs ' || away_clan.tag,
            'Clan fixture'
          )
        end,
        'policy_version_id', attendance.policy_version_id
      ) as incident_payload
    from public.match_attendance_records attendance
    join public.match_reliability_terms terms
      on terms.id = attendance.terms_id
    left join public.reliability_incidents incident
      on incident.attendance_id = attendance.id
      and incident.reversal_of is null
    left join public.reliability_appeals appeal
      on appeal.attendance_id = attendance.id
      and appeal.appellant_profile_id = user_id
    left join public.open_queue_games game
      on game.id = attendance.open_queue_game_id
    left join public.fixtures fixture on fixture.id = attendance.fixture_id
    left join public.clans home_clan on home_clan.id = fixture.home_clan_id
    left join public.clans away_clan on away_clan.id = fixture.away_clan_id
    where attendance.profile_id = user_id
      and attendance.outcome is not null
    order by attendance.finalized_at desc, attendance.id
    limit 50
  ) history;

  message_to_use := case
    when coalesce(indefinite_suspension, false) then
      'Your participation is suspended pending appeal and manual review.'
    when participation_suspended_until is not null then
      'Future bookings were released with Field Wallet credit. Your existing sanction ends at the time shown.'
    when booking_restricted_until is not null then
      'Existing bookings remain active, but you cannot make a new booking until this restriction ends.'
    when active_strikes_to_use >= deposit_threshold then
      'Future solo bookings include a refundable reliability deposit, returned as Field credit after an on-time check-in.'
    when active_strikes_to_use = 1 then
      'Check in by the hard deadline shown on each booking. This strike expires separately.'
    else 'No active attendance strikes.'
  end;

  return jsonb_build_object(
    'server_now', server_now_to_use,
    'policy_version_id', policy_to_use.id,
    'allowed_appeal_categories', coalesce(
      policy_to_use.config #> '{appeals,allowedCategories}',
      '[]'::jsonb
    ),
    'active_strikes', active_strikes_to_use,
    'standing', case
      when coalesce(indefinite_suspension, false) then 'INDEFINITE_REVIEW'
      when participation_suspended_until is not null then 'SUSPENDED'
      when booking_restricted_until is not null then 'BOOKING_RESTRICTED'
      when active_strikes_to_use >= deposit_threshold then 'DEPOSIT_REQUIRED'
      when active_strikes_to_use > 0 then 'WARNING'
      else 'GOOD_STANDING'
    end,
    'reliability_deposit_required', active_strikes_to_use >= deposit_threshold,
    'reliability_deposit_bps', deposit_bps_to_use,
    'active_sanction', active_sanction_to_use,
    'wallet', jsonb_build_object(
      'currency', 'BHD',
      'balance_fils', coalesce(wallet_balance_to_use, 0)
    ),
    'deposit_required', active_strikes_to_use >= deposit_threshold,
    'deposit_bps', deposit_bps_to_use,
    'booking_restricted_until', booking_restricted_until,
    'participation_suspended_until', participation_suspended_until,
    'indefinite_suspension', coalesce(indefinite_suspension, false),
    'message', message_to_use,
    'incidents', incidents_to_use,
    'appeals', appeals_to_use
  );
end;
$$;

create or replace function public.submit_reliability_appeal(
  attendance_record_id_to_appeal uuid,
  category_to_use text,
  message_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  attendance_to_appeal public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  incident_id_to_use uuid;
  normalized_category text := upper(trim(coalesce(category_to_use, '')));
  appeal_id_to_use uuid;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if char_length(trim(coalesce(message_to_use, ''))) not between 10 and 2000 then
    raise exception 'Explain what happened in at least 10 characters.';
  end if;

  select * into attendance_to_appeal
  from public.match_attendance_records attendance
  where attendance.id = attendance_record_id_to_appeal
    and attendance.profile_id = user_id
  for update;
  if attendance_to_appeal.id is null then
    raise exception 'Attendance outcome not found.';
  end if;
  if attendance_to_appeal.outcome is null
    or attendance_to_appeal.strike_delta <= 0
  then
    raise exception 'This attendance outcome is not eligible for appeal.';
  end if;
  if attendance_to_appeal.appeal_due_at is null
    or clock_timestamp() > attendance_to_appeal.appeal_due_at
  then
    raise exception 'The 48-hour appeal window has closed.';
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = attendance_to_appeal.terms_id;
  if not exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #> '{appeals,allowedCategories}'
    ) category
    where category = normalized_category
  ) then
    raise exception 'Choose a supported appeal category.';
  end if;

  select incident.id into incident_id_to_use
  from public.reliability_incidents incident
  where incident.attendance_id = attendance_to_appeal.id
    and incident.reversal_of is null;

  insert into public.reliability_appeals (
    attendance_id,
    incident_id,
    appellant_profile_id,
    category,
    message,
    appeal_due_at
  ) values (
    attendance_to_appeal.id,
    incident_id_to_use,
    user_id,
    normalized_category,
    trim(message_to_use),
    attendance_to_appeal.appeal_due_at
  ) returning id into appeal_id_to_use;

  return appeal_id_to_use;
exception
  when unique_violation then
    raise exception 'You already submitted an appeal for this attendance outcome.';
end;
$$;

create or replace function public.protect_append_only_reliability_rows()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '% is append-only.', tg_table_name;
end;
$$;

drop trigger if exists protect_attendance_events_append_only
on public.attendance_events;
create trigger protect_attendance_events_append_only
before update or delete on public.attendance_events
for each row execute function public.protect_append_only_reliability_rows();

drop trigger if exists protect_reliability_incidents_append_only
on public.reliability_incidents;
create trigger protect_reliability_incidents_append_only
before update or delete on public.reliability_incidents
for each row execute function public.protect_append_only_reliability_rows();

drop trigger if exists protect_wallet_transactions_append_only
on public.field_wallet_transactions;
create trigger protect_wallet_transactions_append_only
before update or delete on public.field_wallet_transactions
for each row execute function public.protect_append_only_reliability_rows();

create or replace function public.bind_reliability_terms_on_match_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'open_queue_games' then
    if new.status in ('OPEN', 'FULL', 'LIVE')
      and new.starts_at > clock_timestamp()
    then
      perform public.ensure_match_reliability_terms('SOLO', new.id);
    end if;
  elsif new.status in ('OPEN', 'SCHEDULED', 'LIVE')
    and public.fixture_start_at(new.match_date, new.time_slot)
      > clock_timestamp()
  then
    perform public.ensure_match_reliability_terms('CLAN', new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists bind_reliability_terms_on_open_queue_game
on public.open_queue_games;
create trigger bind_reliability_terms_on_open_queue_game
after insert or update of starts_at, status on public.open_queue_games
for each row execute function public.bind_reliability_terms_on_match_change();

drop trigger if exists bind_reliability_terms_on_fixture
on public.fixtures;
create trigger bind_reliability_terms_on_fixture
after insert or update of match_date, time_slot, status on public.fixtures
for each row execute function public.bind_reliability_terms_on_match_change();

create or replace function public.sync_solo_attendance_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'CONFIRMED' and exists (
    select 1
    from public.open_queue_games game
    where game.id = new.game_id
      and game.status in ('OPEN', 'FULL', 'LIVE')
      and game.starts_at > clock_timestamp()
  ) then
    perform public.ensure_match_reliability_terms('SOLO', new.game_id);
    perform public.ensure_match_attendance_records('SOLO', new.game_id);
  end if;
  return new;
end;
$$;

drop trigger if exists sync_solo_attendance_on_booking_change
on public.open_queue_bookings;
create trigger sync_solo_attendance_on_booking_change
after insert or update of status, team, role on public.open_queue_bookings
for each row execute function public.sync_solo_attendance_on_booking_change();

create or replace function public.require_checked_in_match_participant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  reliability_terms_exist boolean;
  checked_in_participant boolean;
begin
  if not coalesce(new.played, false)
    or (tg_op = 'UPDATE' and coalesce(old.played, false))
  then
    return new;
  end if;

  if tg_table_name = 'open_queue_bookings' then
    select
      exists (
        select 1
        from public.match_reliability_terms terms
        where terms.match_kind = 'SOLO'
          and terms.open_queue_game_id = new.game_id
      ),
      exists (
        select 1
        from public.match_attendance_records attendance
        where attendance.match_kind = 'SOLO'
          and attendance.open_queue_game_id = new.game_id
          and attendance.profile_id = new.profile_id
          and attendance.checked_in_at is not null
          and attendance.outcome in ('ON_TIME', 'LATE')
      )
    into reliability_terms_exist, checked_in_participant;
  else
    select
      exists (
        select 1
        from public.match_reliability_terms terms
        where terms.match_kind = 'CLAN'
          and terms.fixture_id = new.fixture_id
      ),
      exists (
        select 1
        from public.match_attendance_records attendance
        where attendance.match_kind = 'CLAN'
          and attendance.fixture_id = new.fixture_id
          and attendance.profile_id = new.profile_id
          and attendance.checked_in_at is not null
          and attendance.outcome in ('ON_TIME', 'LATE')
      )
    into reliability_terms_exist, checked_in_participant;
  end if;

  -- Legacy matches without prospective reliability terms keep their existing
  -- rating workflow. Once terms are bound, only a host-checked-in player can
  -- be marked as having played or receive an appearance/SR event.
  if reliability_terms_exist and not checked_in_participant then
    raise exception 'Check this player in with the Field Host before adding them to the played lineup.';
  end if;
  return new;
end;
$$;

drop trigger if exists require_checked_in_solo_participant
on public.open_queue_bookings;
create trigger require_checked_in_solo_participant
before insert or update of played on public.open_queue_bookings
for each row execute function public.require_checked_in_match_participant();

drop trigger if exists require_checked_in_clan_participant
on public.fixture_player_appearances;
create trigger require_checked_in_clan_participant
before insert or update of played on public.fixture_player_appearances
for each row execute function public.require_checked_in_match_participant();

-- Bind prospective matches only. Historical, final, and rated rows are never
-- rewritten by this rollout.
do $$
declare
  candidate record;
begin
  for candidate in
    select game.id
    from public.open_queue_games game
    where game.status in ('OPEN', 'FULL')
      and game.starts_at > clock_timestamp()
    order by game.starts_at, game.id
  loop
    perform public.ensure_match_reliability_terms('SOLO', candidate.id);
    perform public.ensure_match_attendance_records('SOLO', candidate.id);
  end loop;

  for candidate in
    select fixture.id
    from public.fixtures fixture
    where fixture.status in ('OPEN', 'SCHEDULED')
      and public.fixture_start_at(fixture.match_date, fixture.time_slot)
        > clock_timestamp()
    order by fixture.match_date, fixture.time_slot, fixture.id
  loop
    perform public.ensure_match_reliability_terms('CLAN', candidate.id);
  end loop;
end;
$$;

revoke all on function public.ensure_match_reliability_terms(text,uuid)
from public, anon, authenticated;
revoke all on function public.ensure_match_attendance_records(text,uuid)
from public, anon, authenticated;
revoke all on function public.referee_can_manage_reliability_match(uuid,text,uuid)
from public, anon, authenticated;
revoke all on function public.active_reliability_strikes(uuid,timestamptz)
from public, anon, authenticated;
revoke all on function public.credit_field_wallet(
  uuid,integer,text,text,text,uuid,uuid,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.record_reliability_incident(uuid,text,integer,timestamptz)
from public, anon, authenticated;
revoke all on function public.settle_reliability_deposit(uuid,boolean)
from public, anon, authenticated;
revoke all on function public.apply_attendance_refund(uuid)
from public, anon, authenticated;
revoke all on function public.profile_has_active_reliability_booking_restriction(uuid,timestamptz)
from public, anon, authenticated;
revoke all on function public.open_queue_cancellation_quote(uuid,uuid,timestamptz)
from public, anon, authenticated;
revoke all on function public.finalize_match_attendance_internal(text,uuid,uuid)
from public, anon, authenticated;
revoke all on function public.finalize_due_match_attendance()
from public, anon, authenticated;
revoke all on function public.protect_append_only_reliability_rows()
from public, anon, authenticated;
revoke all on function public.bind_reliability_terms_on_match_change()
from public, anon, authenticated;
revoke all on function public.sync_solo_attendance_on_booking_change()
from public, anon, authenticated;
revoke all on function public.require_checked_in_match_participant()
from public, anon, authenticated;

revoke all on function public.book_open_queue_game(uuid,text,text,text)
from public, anon, authenticated;
grant execute on function public.book_open_queue_game(uuid,text,text,text)
to authenticated, service_role;

revoke all on function public.preview_open_queue_cancellation(uuid)
from public, anon, authenticated;
grant execute on function public.preview_open_queue_cancellation(uuid)
to authenticated, service_role;

revoke all on function public.cancel_open_queue_booking(uuid)
from public, anon, authenticated;
grant execute on function public.cancel_open_queue_booking(uuid)
to authenticated, service_role;

revoke all on function public.get_match_reliability_context(text,uuid)
from public, anon;
grant execute on function public.get_match_reliability_context(text,uuid)
to authenticated, service_role;

revoke all on function public.referee_check_in_player(uuid,text,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.referee_check_in_player(uuid,text,uuid,uuid)
to service_role;

revoke all on function public.referee_finalize_match_attendance(uuid,text,uuid)
from public, anon, authenticated;
grant execute on function public.referee_finalize_match_attendance(uuid,text,uuid)
to service_role;

revoke all on function public.get_my_reliability_status()
from public, anon;
grant execute on function public.get_my_reliability_status()
to authenticated, service_role;

revoke all on function public.submit_reliability_appeal(uuid,text,text)
from public, anon;
grant execute on function public.submit_reliability_appeal(uuid,text,text)
to authenticated, service_role;

grant execute on function public.finalize_due_match_attendance()
to service_role;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid from cron.job
    where jobname = 'finalize-field-reliability-attendance'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'finalize-field-reliability-attendance',
  '* * * * *',
  'select public.finalize_due_match_attendance()'
);

comment on function public.referee_check_in_player(uuid,text,uuid,uuid) is
'Records the Field Host check-in using database time and atomically derives the attendance outcome, deposit result, strikes, and sanctions.';

comment on function public.cancel_open_queue_booking(uuid) is
'Applies the effective kickoff policy cancellation band, credits Field Wallet idempotently, records attendance/strikes, and reopens the position.';
