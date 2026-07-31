-- Consequence-free operational review for matches whose result was never
-- recorded. Canonical match status remains unchanged until an administrator
-- makes an audited decision. This prevents silence from becoming an automatic
-- no-show, strike, refund, or SR mutation.

alter table public.fixtures
add column if not exists operational_state text not null default 'NORMAL',
add column if not exists operational_state_updated_at timestamptz
  not null default clock_timestamp(),
add column if not exists operational_reason_code text;

alter table public.fixtures
drop constraint if exists fixtures_operational_state_check;
alter table public.fixtures
add constraint fixtures_operational_state_check check (
  operational_state in ('NORMAL', 'NO_DATA', 'UNDER_REVIEW', 'RESOLVED')
);
alter table public.fixtures
drop constraint if exists fixtures_operational_reason_code_check;
alter table public.fixtures
add constraint fixtures_operational_reason_code_check check (
  operational_reason_code is null
  or operational_reason_code in (
    'NO_ACTIVITY',
    'RESULT_MISSING',
    'REFEREE_REPORT_MISSING',
    'DISPUTED',
    'REFUND_FAILED'
  )
);

alter table public.open_queue_games
add column if not exists operational_state text not null default 'NORMAL',
add column if not exists operational_state_updated_at timestamptz
  not null default clock_timestamp(),
add column if not exists operational_reason_code text;

alter table public.open_queue_games
drop constraint if exists open_queue_games_operational_state_check;
alter table public.open_queue_games
add constraint open_queue_games_operational_state_check check (
  operational_state in ('NORMAL', 'NO_DATA', 'UNDER_REVIEW', 'RESOLVED')
);
alter table public.open_queue_games
drop constraint if exists open_queue_games_operational_reason_code_check;
alter table public.open_queue_games
add constraint open_queue_games_operational_reason_code_check check (
  operational_reason_code is null
  or operational_reason_code in (
    'NO_ACTIVITY',
    'RESULT_MISSING',
    'REFEREE_REPORT_MISSING',
    'DISPUTED',
    'REFUND_FAILED'
  )
);

create table public.match_resolution_cases (
  id uuid primary key default gen_random_uuid(),
  match_kind text not null check (match_kind in ('SOLO', 'CLAN')),
  fixture_id uuid references public.fixtures(id) on delete restrict,
  open_queue_game_id uuid references public.open_queue_games(id)
    on delete restrict,
  state text not null default 'NO_DATA' check (
    state in ('NO_DATA', 'UNDER_REVIEW', 'RESOLVED')
  ),
  reason_code text not null check (
    reason_code in (
      'NO_ACTIVITY',
      'RESULT_MISSING',
      'REFEREE_REPORT_MISSING',
      'DISPUTED',
      'REFUND_FAILED'
    )
  ),
  scheduled_end_at timestamptz not null,
  detected_at timestamptz not null default clock_timestamp(),
  high_priority_at timestamptz not null,
  resolved_at timestamptz,
  resolved_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  current_revision integer not null default 0 check (current_revision >= 0),
  evidence_snapshot jsonb not null default '{}'::jsonb check (
    jsonb_typeof(evidence_snapshot) = 'object'
  ),
  policy_snapshot jsonb not null default '{}'::jsonb check (
    jsonb_typeof(policy_snapshot) = 'object'
  ),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (
    (match_kind = 'CLAN' and fixture_id is not null
      and open_queue_game_id is null)
    or
    (match_kind = 'SOLO' and open_queue_game_id is not null
      and fixture_id is null)
  ),
  check (
    (state = 'RESOLVED' and resolved_at is not null and resolved_by is not null)
    or (state <> 'RESOLVED' and resolved_at is null)
  )
);

create unique index match_resolution_cases_fixture_unique_idx
on public.match_resolution_cases (fixture_id)
where fixture_id is not null;

create unique index match_resolution_cases_solo_unique_idx
on public.match_resolution_cases (open_queue_game_id)
where open_queue_game_id is not null;

create index match_resolution_cases_attention_idx
on public.match_resolution_cases (state, high_priority_at, detected_at)
where state in ('NO_DATA', 'UNDER_REVIEW');

drop trigger if exists set_match_resolution_cases_updated_at
on public.match_resolution_cases;
create trigger set_match_resolution_cases_updated_at
before update on public.match_resolution_cases
for each row execute function public.set_updated_at();

create table public.match_resolution_revisions (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.match_resolution_cases(id)
    on delete restrict,
  revision integer not null check (revision > 0),
  resolution_type text not null check (
    resolution_type in (
      'RECORDED_RESULT',
      'HOME_NO_SHOW',
      'AWAY_NO_SHOW',
      'BOTH_NO_SHOW',
      'FIELD_OR_VENUE_CANCELLATION',
      'MUTUAL_CANCELLATION',
      'BOTH_AT_FAULT',
      'ADMINISTRATIVE_VOID'
    )
  ),
  reason text not null check (char_length(trim(reason)) between 10 and 2000),
  payload jsonb not null default '{}'::jsonb check (
    jsonb_typeof(payload) = 'object'
  ),
  consequence_snapshot jsonb not null default '{}'::jsonb check (
    jsonb_typeof(consequence_snapshot) = 'object'
  ),
  created_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  supersedes_revision_id uuid references public.match_resolution_revisions(id)
    on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (case_id, revision)
);

create table public.match_resolution_refunds (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.match_resolution_cases(id)
    on delete restrict,
  revision_id uuid not null references public.match_resolution_revisions(id)
    on delete restrict,
  recipient_profile_id uuid references public.profiles(id) on delete restrict,
  clan_id uuid references public.clans(id) on delete restrict,
  side text check (side in ('HOME', 'AWAY', 'WHITE', 'BLACK')),
  -- amount_fils is the incremental credit attempted by this revision. The
  -- target and prior total remain separate so correction history can never be
  -- mistaken for money that was paid twice.
  amount_fils integer not null default 0 check (amount_fils >= 0),
  target_amount_fils integer not null default 0 check (
    target_amount_fils >= 0
  ),
  previously_refunded_fils integer not null default 0 check (
    previously_refunded_fils >= 0
  ),
  refund_bps integer not null default 0 check (refund_bps between 0 and 10000),
  destination text not null default 'FIELD_WALLET' check (
    destination in ('FIELD_WALLET', 'ORIGINAL_PAYMENT_METHOD', 'NOT_REQUIRED')
  ),
  status text not null default 'NOT_REQUIRED' check (
    status in ('NOT_REQUIRED', 'PENDING', 'COMPLETED', 'FAILED')
  ),
  failure_reason text check (
    failure_reason is null or char_length(trim(failure_reason)) <= 1000
  ),
  wallet_transaction_id uuid references public.field_wallet_transactions(id)
    on delete set null,
  policy_version_id uuid references public.reliability_policy_versions(id)
    on delete restrict,
  booking_id uuid references public.open_queue_bookings(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (revision_id, recipient_profile_id, side)
);

drop trigger if exists set_match_resolution_refunds_updated_at
on public.match_resolution_refunds;
create trigger set_match_resolution_refunds_updated_at
before update on public.match_resolution_refunds
for each row execute function public.set_updated_at();

create table public.match_resolution_disputes (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.match_resolution_cases(id)
    on delete restrict,
  revision_id uuid references public.match_resolution_revisions(id)
    on delete restrict,
  submitted_by uuid not null references public.profiles(id) on delete restrict,
  clan_id uuid references public.clans(id) on delete set null,
  reason text not null check (char_length(trim(reason)) between 10 and 2000),
  status text not null default 'OPEN' check (
    status in ('OPEN', 'UPHELD', 'OVERTURNED', 'DISMISSED')
  ),
  submitted_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  resolved_by uuid references public.referee_profiles(profile_id)
    on delete set null,
  resolution_note text check (
    resolution_note is null or char_length(trim(resolution_note)) <= 2000
  ),
  check (
    (status = 'OPEN' and resolved_at is null and resolved_by is null)
    or
    (status <> 'OPEN' and resolved_at is not null and resolved_by is not null)
  )
);

create unique index match_resolution_disputes_open_submitter_idx
on public.match_resolution_disputes (case_id, submitted_by)
where status = 'OPEN';

create table public.match_resolution_clan_sr_adjustments (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.match_resolution_cases(id)
    on delete restrict,
  revision_id uuid not null references public.match_resolution_revisions(id)
    on delete restrict,
  clan_id uuid not null references public.clans(id) on delete restrict,
  side text not null check (side in ('HOME', 'AWAY')),
  rating_before integer not null check (rating_before >= 0),
  rating_delta integer not null,
  rating_after integer not null check (rating_after >= 0),
  wins_delta integer not null default 0 check (wins_delta between -1 and 1),
  losses_delta integer not null default 0 check (losses_delta between -1 and 1),
  adjustment_kind text not null default 'RESOLUTION' check (
    adjustment_kind in ('RESOLUTION', 'CORRECTION', 'REVERSAL')
  ),
  created_at timestamptz not null default clock_timestamp(),
  unique (revision_id, clan_id, adjustment_kind)
);

create table public.match_resolution_incident_links (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.match_resolution_cases(id)
    on delete restrict,
  revision_id uuid not null references public.match_resolution_revisions(id)
    on delete restrict,
  incident_id uuid not null references public.reliability_incidents(id)
    on delete restrict,
  effect_kind text not null check (effect_kind in ('APPLIED', 'REVERSAL')),
  created_at timestamptz not null default clock_timestamp(),
  unique (revision_id, incident_id)
);

alter table public.match_resolution_cases enable row level security;
alter table public.match_resolution_revisions enable row level security;
alter table public.match_resolution_refunds enable row level security;
alter table public.match_resolution_disputes enable row level security;
alter table public.match_resolution_clan_sr_adjustments enable row level security;
alter table public.match_resolution_incident_links enable row level security;

revoke all on table public.match_resolution_cases
from public, anon, authenticated;
revoke all on table public.match_resolution_revisions
from public, anon, authenticated;
revoke all on table public.match_resolution_refunds
from public, anon, authenticated;
revoke all on table public.match_resolution_disputes
from public, anon, authenticated;
revoke all on table public.match_resolution_clan_sr_adjustments
from public, anon, authenticated;
revoke all on table public.match_resolution_incident_links
from public, anon, authenticated;

grant all on table public.match_resolution_cases to service_role;
grant all on table public.match_resolution_revisions to service_role;
grant all on table public.match_resolution_refunds to service_role;
grant all on table public.match_resolution_disputes to service_role;
grant all on table public.match_resolution_clan_sr_adjustments to service_role;
grant all on table public.match_resolution_incident_links to service_role;

create or replace function public.fixture_end_at(
  match_date_to_use date,
  time_slot_to_use text
)
returns timestamptz
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.fixture_start_at(match_date_to_use, time_slot_to_use)
    + interval '1 hour';
$$;

create or replace function public.match_resolution_evidence_snapshot(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  clock_started boolean := false;
  event_count integer := 0;
  goal_count integer := 0;
  check_in_count integer := 0;
  stoppage_count integer := 0;
  referee_count integer := 0;
begin
  if normalized_kind = 'CLAN' then
    select exists (
      select 1 from public.fixture_clock_states clock
      where clock.fixture_id = match_id_to_use
        and (
          clock.status <> 'NOT_STARTED'
          or clock.started_at is not null
          or clock.accumulated_seconds > 0
        )
    ) into clock_started;
    select count(*) into event_count
    from public.fixture_events event
    where event.fixture_id = match_id_to_use;
    select count(*) into goal_count
    from public.fixture_scorers goal
    where goal.fixture_id = match_id_to_use;
    select count(*) into check_in_count
    from public.match_attendance_records attendance
    where attendance.fixture_id = match_id_to_use
      and attendance.checked_in_at is not null;
    select count(*) into stoppage_count
    from public.match_stoppages stoppage
    where stoppage.fixture_id = match_id_to_use;
    select count(*) into referee_count
    from public.fixture_referee_assignments assignment
    where assignment.fixture_id = match_id_to_use;
  elsif normalized_kind = 'SOLO' then
    select exists (
      select 1 from public.open_queue_clock_states clock
      where clock.game_id = match_id_to_use
        and (
          clock.status <> 'NOT_STARTED'
          or clock.started_at is not null
          or clock.accumulated_seconds > 0
        )
    ) into clock_started;
    select count(*) into event_count
    from public.open_queue_events event
    where event.game_id = match_id_to_use;
    select count(*) into goal_count
    from public.open_queue_goals goal
    where goal.game_id = match_id_to_use;
    select count(*) into check_in_count
    from public.match_attendance_records attendance
    where attendance.open_queue_game_id = match_id_to_use
      and attendance.checked_in_at is not null;
    select count(*) into stoppage_count
    from public.match_stoppages stoppage
    where stoppage.open_queue_game_id = match_id_to_use;
    select count(*) into referee_count
    from public.open_queue_referee_assignments assignment
    where assignment.game_id = match_id_to_use;
  else
    raise exception 'Choose a clan or solo match.';
  end if;

  return jsonb_build_object(
    'clock_started', clock_started,
    'event_count', event_count,
    'goal_count', goal_count,
    'check_in_count', check_in_count,
    'stoppage_count', stoppage_count,
    'referee_assigned', referee_count > 0,
    'has_activity', (
      clock_started or event_count > 0 or goal_count > 0
      or check_in_count > 0 or stoppage_count > 0
    ),
    'captured_at', statement_timestamp()
  );
end;
$$;

create or replace function public.detect_due_match_resolution_cases()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  evidence_to_use jsonb;
  terms_to_use public.match_reliability_terms%rowtype;
  case_id_to_use uuid;
  inserted_total integer := 0;
begin
  for candidate in
    (
      select
        'CLAN'::text as match_kind,
        fixture.id as match_id,
        public.fixture_end_at(fixture.match_date, fixture.time_slot)
          as scheduled_end_at
      from public.fixtures fixture
      where (
          fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
          or (
            fixture.status = 'FINAL'
            and (
              fixture.home_score is null
              or fixture.away_score is null
            )
          )
        )
        and fixture.away_clan_id is not null
        and public.fixture_end_at(fixture.match_date, fixture.time_slot)
          + interval '30 minutes' <= clock_timestamp()
        and fixture.home_score is null
        and fixture.away_score is null
        and not exists (
          select 1 from public.match_resolution_cases existing_case
          where existing_case.fixture_id = fixture.id
        )
        and not exists (
          select 1 from public.match_forfeit_decisions decision
          where decision.fixture_id = fixture.id
        )
        and not exists (
          select 1 from public.clan_fixture_cancellations cancellation
          where cancellation.fixture_id = fixture.id
        )
      union all
      select
        'SOLO'::text,
        game.id,
        game.ends_at
      from public.open_queue_games game
      where game.status in ('OPEN', 'FULL', 'LIVE')
        and game.ends_at + interval '30 minutes' <= clock_timestamp()
        and game.white_score is null
        and game.black_score is null
        and not exists (
          select 1 from public.match_resolution_cases existing_case
          where existing_case.open_queue_game_id = game.id
        )
    )
    order by scheduled_end_at
    limit 250
  loop
    -- Historical games already settled by the old automatic attendance worker
    -- are never silently rewritten. They need an explicit compensating review.
    if exists (
      select 1
      from public.match_attendance_records attendance
      where (
        (candidate.match_kind = 'CLAN'
          and attendance.fixture_id = candidate.match_id)
        or
        (candidate.match_kind = 'SOLO'
          and attendance.open_queue_game_id = candidate.match_id)
      )
        and attendance.finalized_at is not null
    ) then
      continue;
    end if;

    evidence_to_use := public.match_resolution_evidence_snapshot(
      candidate.match_kind,
      candidate.match_id
    );
    terms_to_use := public.ensure_match_reliability_terms(
      candidate.match_kind,
      candidate.match_id
    );

    insert into public.match_resolution_cases (
      match_kind,
      fixture_id,
      open_queue_game_id,
      state,
      reason_code,
      scheduled_end_at,
      detected_at,
      high_priority_at,
      evidence_snapshot,
      policy_snapshot
    ) values (
      candidate.match_kind,
      case when candidate.match_kind = 'CLAN'
        then candidate.match_id else null end,
      case when candidate.match_kind = 'SOLO'
        then candidate.match_id else null end,
      'NO_DATA',
      case when coalesce(
        (evidence_to_use ->> 'has_activity')::boolean,
        false
      ) then 'RESULT_MISSING' else 'NO_ACTIVITY' end,
      candidate.scheduled_end_at,
      clock_timestamp(),
      clock_timestamp() + interval '24 hours',
      evidence_to_use,
      terms_to_use.policy_snapshot
    )
    on conflict do nothing
    returning id into case_id_to_use;

    if case_id_to_use is null then
      continue;
    end if;

    if candidate.match_kind = 'CLAN' then
      update public.fixtures
      set
        operational_state = 'NO_DATA',
        operational_state_updated_at = clock_timestamp()
      where id = candidate.match_id;
    else
      update public.open_queue_games
      set
        operational_state = 'NO_DATA',
        operational_state_updated_at = clock_timestamp()
      where id = candidate.match_id;
    end if;

    inserted_total := inserted_total + 1;
  end loop;

  return inserted_total;
end;
$$;

-- Automatic jobs may discover a missing record, but they may not decide that
-- a person or clan failed to attend. Attendance consequences now require an
-- explicit referee action or an audited admin resolution.
create or replace function public.finalize_due_match_attendance()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select 0;
$$;

-- The clan deadline worker is also discovery-only now. Even a recorded score
-- does not prove who attended; only referee-recorded attendance or an audited
-- admin resolution may create clan reliability consequences.
create or replace function public.finalize_due_clan_reliability_attendance()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select 0;
$$;

do $$
declare
  existing_job record;
begin
  for existing_job in
    select jobid from cron.job
    where jobname = 'detect-field-match-resolution-cases'
  loop
    perform cron.unschedule(existing_job.jobid);
  end loop;

  perform cron.schedule(
    'detect-field-match-resolution-cases',
    '* * * * *',
    $job$select public.detect_due_match_resolution_cases();$job$
  );
end;
$$;

revoke all on function public.match_resolution_evidence_snapshot(text,uuid)
from public, anon, authenticated;
revoke all on function public.detect_due_match_resolution_cases()
from public, anon, authenticated;
revoke all on function public.finalize_due_match_attendance()
from public, anon, authenticated;
revoke all on function public.finalize_due_clan_reliability_attendance()
from public, anon, authenticated;

grant execute on function public.match_resolution_evidence_snapshot(text,uuid)
to service_role;
grant execute on function public.detect_due_match_resolution_cases()
to service_role;
grant execute on function public.finalize_due_match_attendance()
to service_role;
grant execute on function public.finalize_due_clan_reliability_attendance()
to service_role;

create or replace function public.get_clan_reliability_summary(
  clan_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  is_member_to_use boolean := false;
  active_strikes_to_use integer := 0;
  policy_to_use public.reliability_policy_versions%rowtype;
  deposit_threshold integer := 0;
  active_sanctions_to_use integer := 0;
  incidents_to_use jsonb := '[]'::jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if not exists (
    select 1 from public.clans clan
    where clan.id = clan_id_to_use and clan.archived_at is null
  ) then
    raise exception 'Clan not found.';
  end if;

  select exists (
    select 1 from public.clan_members member
    where member.clan_id = clan_id_to_use
      and member.profile_id = user_id
      and member.left_at is null
  ) into is_member_to_use;

  active_strikes_to_use := public.active_clan_reliability_strikes(
    clan_id_to_use,
    statement_timestamp()
  );

  select * into policy_to_use
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= statement_timestamp()
  order by policy.effective_from desc, policy.version desc
  limit 1;
  deposit_threshold := coalesce(
    (policy_to_use.config #>>
      '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer,
    0
  );

  select count(*)::integer into active_sanctions_to_use
  from public.reliability_sanctions sanction
  where sanction.subject_type = 'CLAN'
    and sanction.clan_id = clan_id_to_use
    and sanction.revoked_at is null
    and sanction.starts_at <= statement_timestamp()
    and (
      sanction.ends_at is null
      or sanction.ends_at > statement_timestamp()
    );

  if is_member_to_use then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', incident.id,
          'outcome', incident.outcome,
          'strike_delta', incident.strike_delta,
          'occurred_at', incident.occurred_at,
          'expires_at', incident.expires_at,
          'reason', coalesce(
            nullif(trim(incident.detail ->> 'reason'), ''),
            case incident.outcome
              when 'NO_SHOW' then 'The clan did not attend a scheduled match.'
              when 'FORFEIT' then 'The clan forfeited a scheduled match.'
              when 'PARTIAL_LATE' then 'The clan did not meet the on-time roster requirement.'
              else initcap(replace(lower(incident.outcome), '_', ' '))
            end
          ),
          'fixture_id', incident.fixture_id,
          'fixture_label', case when fixture.id is null then null else
            to_char(fixture.match_date, 'Mon FMDD, YYYY') || ' · ' ||
              fixture.venue
          end,
          'issuer_label', coalesce(
            nullif(trim(incident.detail ->> 'issuer_label'), ''),
            'Field operations'
          ),
          'is_active', incident.occurred_at <= statement_timestamp()
            and (
              incident.expires_at is null
              or incident.expires_at > statement_timestamp()
            )
        )
        order by incident.occurred_at desc, incident.id
      ),
      '[]'::jsonb
    ) into incidents_to_use
    from public.reliability_incidents incident
    left join public.fixtures fixture on fixture.id = incident.fixture_id
    where incident.subject_type = 'CLAN'
      and incident.clan_id = clan_id_to_use;
  end if;

  return jsonb_build_object(
    'clan_id', clan_id_to_use,
    'active_strikes', active_strikes_to_use,
    'is_member', is_member_to_use,
    'consequence_summary', jsonb_build_object(
      'deposit_required',
        deposit_threshold > 0 and active_strikes_to_use >= deposit_threshold,
      'active_sanctions', active_sanctions_to_use
    ),
    'incidents', incidents_to_use
  );
end;
$$;

revoke all on function public.get_clan_reliability_summary(uuid)
from public, anon, authenticated;
grant execute on function public.get_clan_reliability_summary(uuid)
to authenticated, service_role;

create or replace function public.record_match_resolution_refund(
  case_id_to_use uuid,
  revision_id_to_use uuid,
  recipient_profile_id_to_use uuid,
  clan_id_to_use uuid,
  side_to_use text,
  gross_amount_fils_to_use integer,
  previously_refunded_fils_to_use integer,
  refund_bps_to_use integer,
  policy_version_id_to_use uuid,
  booking_id_to_use uuid,
  description_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_bps integer := greatest(
    0, least(10000, coalesce(refund_bps_to_use, 0))
  );
  target_amount integer := 0;
  missing_amount integer := 0;
  refund_id_to_use uuid;
  wallet_transaction_id_to_use uuid;
  failure_to_use text;
begin
  target_amount := (
    greatest(0, coalesce(gross_amount_fils_to_use, 0))::bigint
      * normalized_bps / 10000
  )::integer;
  missing_amount := greatest(
    0,
    target_amount - greatest(0, coalesce(previously_refunded_fils_to_use, 0))
  );

  insert into public.match_resolution_refunds (
    case_id,
    revision_id,
    recipient_profile_id,
    clan_id,
    side,
    amount_fils,
    refund_bps,
    destination,
    status
  ) values (
    case_id_to_use,
    revision_id_to_use,
    recipient_profile_id_to_use,
    clan_id_to_use,
    upper(trim(side_to_use)),
    target_amount,
    normalized_bps,
    case when target_amount <= 0 or recipient_profile_id_to_use is null
      then 'NOT_REQUIRED' else 'FIELD_WALLET' end,
    case when target_amount <= 0 or recipient_profile_id_to_use is null
      then 'NOT_REQUIRED'
      when missing_amount <= 0 then 'COMPLETED'
      else 'PENDING' end
  )
  returning id into refund_id_to_use;

  if missing_amount <= 0 or recipient_profile_id_to_use is null then
    return refund_id_to_use;
  end if;

  begin
    wallet_transaction_id_to_use := public.credit_field_wallet(
      recipient_profile_id_to_use,
      missing_amount,
      'FIELD_CANCELLATION_REFUND',
      'match-resolution:' || revision_id_to_use::text || ':' ||
        upper(trim(side_to_use)) || ':' ||
        recipient_profile_id_to_use::text,
      left(trim(description_to_use), 300),
      policy_version_id_to_use,
      booking_id_to_use,
      null,
      jsonb_build_object(
        'match_resolution_case_id', case_id_to_use,
        'match_resolution_revision_id', revision_id_to_use,
        'side', upper(trim(side_to_use)),
        'refund_bps', normalized_bps
      )
    );

    update public.match_resolution_refunds
    set
      status = 'COMPLETED',
      wallet_transaction_id = wallet_transaction_id_to_use,
      failure_reason = null
    where id = refund_id_to_use;
  exception when others then
    failure_to_use := left(sqlerrm, 1000);
    update public.match_resolution_refunds
    set status = 'FAILED', failure_reason = failure_to_use
    where id = refund_id_to_use;
  end;

  return refund_id_to_use;
end;
$$;

create or replace function public.apply_match_resolution_clan_sr(
  case_id_to_use uuid,
  revision_id_to_use uuid,
  clan_id_to_use uuid,
  side_to_use text,
  rating_delta_to_use integer,
  adjustment_kind_to_use text default 'RESOLUTION'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  before_to_use integer;
  after_to_use integer;
begin
  select clan.skill_rating into before_to_use
  from public.clans clan
  where clan.id = clan_id_to_use
  for update;
  if before_to_use is null then
    raise exception 'Clan not found.';
  end if;

  after_to_use := greatest(0, before_to_use + rating_delta_to_use);
  update public.clans
  set skill_rating = after_to_use
  where id = clan_id_to_use;

  insert into public.match_resolution_clan_sr_adjustments (
    case_id,
    revision_id,
    clan_id,
    side,
    rating_before,
    rating_delta,
    rating_after,
    adjustment_kind
  ) values (
    case_id_to_use,
    revision_id_to_use,
    clan_id_to_use,
    upper(trim(side_to_use)),
    before_to_use,
    after_to_use - before_to_use,
    after_to_use,
    upper(trim(adjustment_kind_to_use))
  );

  return after_to_use - before_to_use;
end;
$$;

revoke all on function public.record_match_resolution_refund(
  uuid,uuid,uuid,uuid,text,integer,integer,integer,uuid,uuid,text
) from public, anon, authenticated;
revoke all on function public.apply_match_resolution_clan_sr(
  uuid,uuid,uuid,text,integer,text
) from public, anon, authenticated;
grant execute on function public.record_match_resolution_refund(
  uuid,uuid,uuid,uuid,text,integer,integer,integer,uuid,uuid,text
) to service_role;
grant execute on function public.apply_match_resolution_clan_sr(
  uuid,uuid,uuid,text,integer,text
) to service_role;

create or replace function public.reverse_previous_match_resolution_effects(
  case_id_to_use uuid,
  new_revision_id_to_use uuid,
  actor_admin_id uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  linked record;
  prior_adjustment record;
  reversal_incident_id uuid;
  active_before integer;
  active_after integer;
  reversed_incidents integer := 0;
  reversed_sr integer := 0;
begin
  for prior_adjustment in
    select adjustment.*
    from public.match_resolution_clan_sr_adjustments adjustment
    join public.match_resolution_revisions revision
      on revision.id = adjustment.revision_id
    where adjustment.case_id = case_id_to_use
      and adjustment.adjustment_kind in ('RESOLUTION', 'CORRECTION')
      and revision.revision = (
        select max(previous_revision.revision)
        from public.match_resolution_revisions previous_revision
        where previous_revision.case_id = case_id_to_use
          and previous_revision.id <> new_revision_id_to_use
      )
    order by adjustment.clan_id
  loop
    perform public.apply_match_resolution_clan_sr(
      case_id_to_use,
      new_revision_id_to_use,
      prior_adjustment.clan_id,
      prior_adjustment.side,
      -prior_adjustment.rating_delta,
      'REVERSAL'
    );
    reversed_sr := reversed_sr + 1;
  end loop;

  for linked in
    select incident.*
    from public.match_resolution_incident_links link
    join public.reliability_incidents incident
      on incident.id = link.incident_id
    join public.match_resolution_revisions revision
      on revision.id = link.revision_id
    where link.case_id = case_id_to_use
      and link.effect_kind = 'APPLIED'
      and incident.reversal_of is null
      and not exists (
        select 1 from public.reliability_incidents reversal
        where reversal.reversal_of = incident.id
      )
      and revision.revision = (
        select max(previous_revision.revision)
        from public.match_resolution_revisions previous_revision
        where previous_revision.case_id = case_id_to_use
          and previous_revision.id <> new_revision_id_to_use
      )
    order by incident.id
  loop
    active_before := case
      when linked.subject_type = 'CLAN'
        then public.active_clan_reliability_strikes(
          linked.clan_id, clock_timestamp()
        )
      else public.active_reliability_strikes(
        linked.profile_id, clock_timestamp()
      )
    end;
    active_after := greatest(0, active_before - linked.strike_delta);

    insert into public.reliability_incidents (
      subject_type,
      profile_id,
      clan_id,
      attendance_id,
      booking_id,
      fixture_id,
      outcome,
      strike_delta,
      occurred_at,
      expires_at,
      policy_version_id,
      reversal_of,
      active_count_before,
      active_count_after,
      detail
    ) values (
      linked.subject_type,
      linked.profile_id,
      linked.clan_id,
      null,
      linked.booking_id,
      linked.fixture_id,
      'ADMIN_RESOLUTION_CORRECTED',
      -linked.strike_delta,
      clock_timestamp(),
      null,
      linked.policy_version_id,
      linked.id,
      active_before,
      active_after,
      jsonb_build_object(
        'reason', left(trim(reason_to_use), 1000),
        'issuer_label', 'Field administrator',
        'match_resolution_case_id', case_id_to_use,
        'match_resolution_revision_id', new_revision_id_to_use
      )
    ) returning id into reversal_incident_id;

    insert into public.match_resolution_incident_links (
      case_id, revision_id, incident_id, effect_kind
    ) values (
      case_id_to_use,
      new_revision_id_to_use,
      reversal_incident_id,
      'REVERSAL'
    );

    update public.reliability_sanctions
    set
      revoked_at = coalesce(revoked_at, clock_timestamp()),
      revoked_by = coalesce(revoked_by, actor_admin_id),
      revocation_reason = coalesce(
        revocation_reason,
        'Match resolution corrected: ' || left(trim(reason_to_use), 450)
      )
    where incident_id = linked.id and revoked_at is null;

    reversed_incidents := reversed_incidents + 1;
  end loop;

  return jsonb_build_object(
    'reversed_sr_adjustments', reversed_sr,
    'reversed_incidents', reversed_incidents,
    'refunds_reversed', false,
    'refund_note',
      'Completed refunds are never clawed back; corrections use supplemental audited adjustments.'
  );
end;
$$;

revoke all on function public.reverse_previous_match_resolution_effects(
  uuid,uuid,uuid,text
) from public, anon, authenticated;
grant execute on function public.reverse_previous_match_resolution_effects(
  uuid,uuid,uuid,text
) to service_role;

create or replace function public.admin_resolve_match_case(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  expected_revision_to_use integer,
  resolution_type_to_use text,
  reason_to_use text,
  payload_to_use jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_resolution text := upper(trim(coalesce(resolution_type_to_use, '')));
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  safe_payload jsonb := coalesce(payload_to_use, '{}'::jsonb);
  case_to_resolve public.match_resolution_cases%rowtype;
  fixture_to_resolve public.fixtures%rowtype;
  game_to_resolve public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  previous_revision_id uuid;
  revision_id_to_use uuid;
  next_revision integer;
  reversal_summary jsonb := '{}'::jsonb;
  consequence_to_use jsonb := '{}'::jsonb;
  home_score_to_use integer;
  away_score_to_use integer;
  home_refund_bps_to_use integer := 0;
  away_refund_bps_to_use integer := 0;
  home_strikes_to_use integer := 0;
  away_strikes_to_use integer := 0;
  home_sr_delta_to_use integer := 0;
  away_sr_delta_to_use integer := 0;
  home_rating integer := 0;
  away_rating integer := 0;
  home_clan_id_to_use uuid;
  away_clan_id_to_use uuid;
  home_payer_to_use uuid;
  away_payer_to_use uuid;
  home_amount_to_use integer := 0;
  away_amount_to_use integer := 0;
  home_existing_refund integer := 0;
  away_existing_refund integer := 0;
  forfeit_score_to_use integer := 3;
  entire_no_show_strikes integer := 0;
  forfeit_strikes integer := 0;
  partial_strikes integer := 0;
  player_no_show_strikes integer := 0;
  incident_id_to_use uuid;
  attendance_to_use public.match_attendance_records%rowtype;
  attendance_state text;
  booking_to_use public.open_queue_bookings%rowtype;
  entity_type_to_use text;
  resolution_is_final_result boolean := false;
  resolution_is_cancellation boolean := false;
  is_correction boolean := false;
  current_before jsonb;
  home_applied_delta integer := 0;
  away_applied_delta integer := 0;
  home_refund_id uuid;
  away_refund_id uuid;
  result_to_return jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if normalized_resolution not in (
    'RECORDED_RESULT',
    'HOME_NO_SHOW',
    'AWAY_NO_SHOW',
    'BOTH_NO_SHOW',
    'FIELD_OR_VENUE_CANCELLATION',
    'MUTUAL_CANCELLATION',
    'BOTH_AT_FAULT',
    'ADMINISTRATIVE_VOID'
  ) then
    raise exception 'Choose a valid match resolution.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Add a clear resolution reason (at least 10 characters).';
  end if;
  if jsonb_typeof(safe_payload) <> 'object' then
    raise exception 'Resolution details must be an object.';
  end if;

  select * into case_to_resolve
  from public.match_resolution_cases review_case
  where review_case.match_kind = normalized_kind
    and (
      (normalized_kind = 'CLAN' and review_case.fixture_id = match_id_to_use)
      or
      (normalized_kind = 'SOLO'
        and review_case.open_queue_game_id = match_id_to_use)
    )
  for update;
  if case_to_resolve.id is null then
    raise exception 'No Data review case not found for this match.';
  end if;
  if case_to_resolve.state not in ('NO_DATA', 'UNDER_REVIEW', 'RESOLVED') then
    raise exception 'This review case cannot be resolved.';
  end if;
  if case_to_resolve.current_revision <> coalesce(expected_revision_to_use, -1)
  then
    raise exception 'This review changed while you were working. Refresh and try again.';
  end if;

  next_revision := case_to_resolve.current_revision + 1;
  is_correction := case_to_resolve.current_revision > 0;
  select revision.id into previous_revision_id
  from public.match_resolution_revisions revision
  where revision.case_id = case_to_resolve.id
    and revision.revision = case_to_resolve.current_revision;

  terms_to_use := public.ensure_match_reliability_terms(
    normalized_kind,
    match_id_to_use
  );
  forfeit_score_to_use := coalesce(
    (terms_to_use.policy_snapshot #>> '{clan,forfeitScore}')::integer,
    3
  );
  entire_no_show_strikes := coalesce(
    (terms_to_use.policy_snapshot #>>
      '{clan,entireClanNoShowStrikes}')::integer,
    0
  );
  forfeit_strikes := coalesce(
    (terms_to_use.policy_snapshot #>> '{clan,forfeitStrikes}')::integer,
    0
  );
  partial_strikes := coalesce(
    (terms_to_use.policy_snapshot #>>
      '{clan,partialAttendanceStrikes}')::integer,
    0
  );
  player_no_show_strikes := coalesce(
    (terms_to_use.policy_snapshot #>>
      '{solo,outcomes,noShow,strikes}')::integer,
    0
  );

  if normalized_kind = 'CLAN' then
    select * into fixture_to_resolve
    from public.fixtures fixture
    where fixture.id = match_id_to_use
    for update;
    if fixture_to_resolve.id is null
      or fixture_to_resolve.away_clan_id is null
    then
      raise exception 'Clan match not found or has no opponent.';
    end if;
    if fixture_to_resolve.status in ('FINAL', 'CANCELLED')
      and not is_correction
    then
      raise exception 'This match already has an official terminal state.';
    end if;
    current_before := to_jsonb(fixture_to_resolve);
    entity_type_to_use := 'CLAN_MATCH';
    home_clan_id_to_use := fixture_to_resolve.home_clan_id;
    away_clan_id_to_use := fixture_to_resolve.away_clan_id;
    home_payer_to_use := fixture_to_resolve.home_paid_by;
    away_payer_to_use := fixture_to_resolve.away_paid_by;
    home_amount_to_use := coalesce(fixture_to_resolve.home_amount_paid_fils, 0);
    away_amount_to_use := coalesce(fixture_to_resolve.away_amount_paid_fils, 0);
    home_existing_refund := fixture_to_resolve.home_refund_amount_fils;
    away_existing_refund := fixture_to_resolve.away_refund_amount_fils;

    perform clan.id
    from public.clans clan
    where clan.id in (home_clan_id_to_use, away_clan_id_to_use)
    order by clan.id
    for update;
    select clan.skill_rating into home_rating
    from public.clans clan where clan.id = home_clan_id_to_use;
    select clan.skill_rating into away_rating
    from public.clans clan where clan.id = away_clan_id_to_use;
  else
    select * into game_to_resolve
    from public.open_queue_games game
    where game.id = match_id_to_use
    for update;
    if game_to_resolve.id is null then
      raise exception 'Solo match not found.';
    end if;
    if game_to_resolve.status in ('FINAL', 'CANCELLED')
      and not is_correction
    then
      raise exception 'This match already has an official terminal state.';
    end if;
    current_before := to_jsonb(game_to_resolve);
    entity_type_to_use := 'SOLO_MATCH';
  end if;

  -- Safe defaults. Advanced values may only narrow or deliberately override
  -- these values when the admin expands the advanced section.
  case normalized_resolution
    when 'RECORDED_RESULT' then
      resolution_is_final_result := true;
      home_score_to_use := (safe_payload ->> 'home_score')::integer;
      away_score_to_use := (safe_payload ->> 'away_score')::integer;
      if home_score_to_use is null or away_score_to_use is null
        or home_score_to_use < 0 or away_score_to_use < 0
      then
        raise exception 'Enter a valid final score for both teams.';
      end if;
    when 'HOME_NO_SHOW' then
      if normalized_kind = 'CLAN' then
        resolution_is_final_result := true;
        home_score_to_use := 0;
        away_score_to_use := forfeit_score_to_use;
      else
        resolution_is_cancellation := true;
      end if;
      home_refund_bps_to_use := 0;
      away_refund_bps_to_use := 10000;
      home_strikes_to_use := case when normalized_kind = 'CLAN'
        then entire_no_show_strikes else player_no_show_strikes end;
    when 'AWAY_NO_SHOW' then
      if normalized_kind = 'CLAN' then
        resolution_is_final_result := true;
        home_score_to_use := forfeit_score_to_use;
        away_score_to_use := 0;
      else
        resolution_is_cancellation := true;
      end if;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 0;
      away_strikes_to_use := case when normalized_kind = 'CLAN'
        then entire_no_show_strikes else player_no_show_strikes end;
    when 'BOTH_NO_SHOW' then
      resolution_is_cancellation := true;
      home_strikes_to_use := case when normalized_kind = 'CLAN'
        then entire_no_show_strikes else player_no_show_strikes end;
      away_strikes_to_use := home_strikes_to_use;
    when 'FIELD_OR_VENUE_CANCELLATION' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
    when 'MUTUAL_CANCELLATION' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
    when 'BOTH_AT_FAULT' then
      resolution_is_cancellation := true;
      home_strikes_to_use := case when normalized_kind = 'CLAN'
        then forfeit_strikes else player_no_show_strikes end;
      away_strikes_to_use := home_strikes_to_use;
    when 'ADMINISTRATIVE_VOID' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
  end case;

  if safe_payload ->> 'home_refund_bps' is not null then
    home_refund_bps_to_use := (safe_payload ->> 'home_refund_bps')::integer;
  end if;
  if safe_payload ->> 'away_refund_bps' is not null then
    away_refund_bps_to_use := (safe_payload ->> 'away_refund_bps')::integer;
  end if;
  if safe_payload ->> 'home_strikes' is not null then
    home_strikes_to_use := (safe_payload ->> 'home_strikes')::integer;
  end if;
  if safe_payload ->> 'away_strikes' is not null then
    away_strikes_to_use := (safe_payload ->> 'away_strikes')::integer;
  end if;
  if home_refund_bps_to_use not between 0 and 10000
    or away_refund_bps_to_use not between 0 and 10000
  then
    raise exception 'Refund percentages must be between 0 and 100 percent.';
  end if;
  if home_strikes_to_use not between 0 and 20
    or away_strikes_to_use not between 0 and 20
  then
    raise exception 'Strike adjustments must be between 0 and 20.';
  end if;

  if normalized_kind = 'CLAN' then
    if normalized_resolution in (
      'RECORDED_RESULT', 'HOME_NO_SHOW', 'AWAY_NO_SHOW'
    ) then
      select delta.home_change, delta.away_change
      into home_sr_delta_to_use, away_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        home_rating,
        away_rating,
        home_score_to_use,
        away_score_to_use
      ) delta;
    elsif normalized_resolution in ('BOTH_NO_SHOW', 'BOTH_AT_FAULT') then
      select delta.home_change into home_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        home_rating, away_rating, 0, forfeit_score_to_use
      ) delta;
      select delta.home_change into away_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        away_rating, home_rating, 0, forfeit_score_to_use
      ) delta;
    end if;

    if safe_payload ->> 'home_sr_delta' is not null then
      home_sr_delta_to_use := (safe_payload ->> 'home_sr_delta')::integer;
    end if;
    if safe_payload ->> 'away_sr_delta' is not null then
      away_sr_delta_to_use := (safe_payload ->> 'away_sr_delta')::integer;
    end if;

    if upper(coalesce(safe_payload ->> 'home_attendance_state', '')) =
      'SHORT_ROSTER'
    then
      home_strikes_to_use := greatest(
        home_strikes_to_use, partial_strikes
      );
    end if;
    if upper(coalesce(safe_payload ->> 'away_attendance_state', '')) =
      'SHORT_ROSTER'
    then
      away_strikes_to_use := greatest(
        away_strikes_to_use, partial_strikes
      );
    end if;
  end if;

  consequence_to_use := jsonb_build_object(
    'home_score', home_score_to_use,
    'away_score', away_score_to_use,
    'home_refund_bps', home_refund_bps_to_use,
    'away_refund_bps', away_refund_bps_to_use,
    'home_strikes', home_strikes_to_use,
    'away_strikes', away_strikes_to_use,
    'home_sr_delta', home_sr_delta_to_use,
    'away_sr_delta', away_sr_delta_to_use,
    'refund_destination', 'FIELD_WALLET',
    'refunds_continue_during_disputes', true,
    'policy_version_id', terms_to_use.policy_version_id,
    'minimum_at_kickoff', terms_to_use.policy_snapshot #>>
      '{clan,minimumAtKickoffWithoutForfeit}',
    'minimum_on_time', terms_to_use.policy_snapshot #>>
      '{clan,minimumOnTimeWithoutClanStrike}'
  );

  insert into public.match_resolution_revisions (
    case_id,
    revision,
    resolution_type,
    reason,
    payload,
    consequence_snapshot,
    created_by,
    supersedes_revision_id
  ) values (
    case_to_resolve.id,
    next_revision,
    normalized_resolution,
    normalized_reason,
    safe_payload,
    consequence_to_use,
    actor_admin_id,
    previous_revision_id
  ) returning id into revision_id_to_use;

  if is_correction then
    reversal_summary := public.reverse_previous_match_resolution_effects(
      case_to_resolve.id,
      revision_id_to_use,
      actor_admin_id,
      normalized_reason
    );
  end if;

  if normalized_kind = 'CLAN' then
    perform public.initialize_fixture_reliability_roster(match_id_to_use);
    perform public.ensure_match_attendance_records('CLAN', match_id_to_use);

    -- Close individual attendance without inventing individual player blame.
    -- Team-level findings create clan incidents below.
    for attendance_to_use in
      select attendance.*
      from public.match_attendance_records attendance
      where attendance.fixture_id = match_id_to_use
        and attendance.expected_for_match
      order by attendance.id
      for update
    loop
      attendance_state := upper(coalesce((
        select item ->> 'state'
        from jsonb_array_elements(
          coalesce(safe_payload -> 'attendance', '[]'::jsonb)
        ) item
        where item ->> 'profile_id' = attendance_to_use.profile_id::text
        limit 1
      ), ''));
      update public.match_attendance_records
      set
        outcome = case
          when attendance_state = 'NO_SHOW' then 'NO_SHOW'
          when checked_in_at is not null then 'ON_TIME'
          else 'EXCUSED'
        end,
        strike_delta = 0,
        finalized_at = clock_timestamp(),
        appeal_due_at = clock_timestamp() + interval '24 hours',
        consequence_snapshot = consequence_snapshot || jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'case_id', case_to_resolve.id,
          'revision_id', revision_id_to_use,
          'team_level_accountability', true
        )
      where id = attendance_to_use.id;
    end loop;

    if home_strikes_to_use > 0 then
      incident_id_to_use := public.record_clan_reliability_incident(
        match_id_to_use,
        home_clan_id_to_use,
        case when normalized_resolution = 'BOTH_AT_FAULT'
          then 'BOTH_AT_FAULT' else 'NO_SHOW' end,
        home_strikes_to_use,
        clock_timestamp()
      );
      if incident_id_to_use is not null then
        insert into public.match_resolution_incident_links (
          case_id, revision_id, incident_id, effect_kind
        ) values (
          case_to_resolve.id, revision_id_to_use,
          incident_id_to_use, 'APPLIED'
        ) on conflict do nothing;
      end if;
    end if;
    if away_strikes_to_use > 0 then
      incident_id_to_use := public.record_clan_reliability_incident(
        match_id_to_use,
        away_clan_id_to_use,
        case when normalized_resolution = 'BOTH_AT_FAULT'
          then 'BOTH_AT_FAULT' else 'NO_SHOW' end,
        away_strikes_to_use,
        clock_timestamp()
      );
      if incident_id_to_use is not null then
        insert into public.match_resolution_incident_links (
          case_id, revision_id, incident_id, effect_kind
        ) values (
          case_to_resolve.id, revision_id_to_use,
          incident_id_to_use, 'APPLIED'
        ) on conflict do nothing;
      end if;
    end if;

    if home_sr_delta_to_use <> 0 then
      home_applied_delta := public.apply_match_resolution_clan_sr(
        case_to_resolve.id,
        revision_id_to_use,
        home_clan_id_to_use,
        'HOME',
        home_sr_delta_to_use,
        case when is_correction then 'CORRECTION' else 'RESOLUTION' end
      );
    end if;
    if away_sr_delta_to_use <> 0 then
      away_applied_delta := public.apply_match_resolution_clan_sr(
        case_to_resolve.id,
        revision_id_to_use,
        away_clan_id_to_use,
        'AWAY',
        away_sr_delta_to_use,
        case when is_correction then 'CORRECTION' else 'RESOLUTION' end
      );
    end if;

    if resolution_is_final_result then
      update public.clans set
        wins = greatest(0, wins + case
          when home_score_to_use > away_score_to_use then 1 else 0 end),
        losses = greatest(0, losses + case
          when home_score_to_use < away_score_to_use then 1 else 0 end)
      where id = home_clan_id_to_use;
      update public.clans set
        wins = greatest(0, wins + case
          when away_score_to_use > home_score_to_use then 1 else 0 end),
        losses = greatest(0, losses + case
          when away_score_to_use < home_score_to_use then 1 else 0 end)
      where id = away_clan_id_to_use;

      update public.fixtures
      set
        status = 'FINAL',
        home_score = home_score_to_use,
        away_score = away_score_to_use,
        winner_clan_id = case
          when home_score_to_use > away_score_to_use then home_clan_id
          when away_score_to_use > home_score_to_use then away_clan_id
          else null
        end,
        home_sr_change = home_applied_delta,
        away_sr_change = away_applied_delta,
        cancellation_code = null,
        cancellation_reason = null,
        cancelled_at = null,
        cancelled_by = null,
        cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
          || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use,
            'reliability_forfeit_without_play',
              normalized_resolution in ('HOME_NO_SHOW', 'AWAY_NO_SHOW')
          ),
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp()
      where id = match_id_to_use;
    elsif normalized_resolution in (
      'FIELD_OR_VENUE_CANCELLATION', 'ADMINISTRATIVE_VOID'
    ) then
      perform public.admin_cancel_match(
        actor_admin_id,
        'CLAN',
        match_id_to_use,
        case when normalized_resolution = 'FIELD_OR_VENUE_CANCELLATION'
          then 'WEATHER_OR_VENUE' else 'ADMIN_DECISION' end,
        normalized_reason
      );
      update public.fixtures set
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp(),
        cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
          || jsonb_build_object(
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use
          )
      where id = match_id_to_use;
    else
      update public.fixtures
      set
        status = 'CANCELLED',
        home_score = null,
        away_score = null,
        winner_clan_id = null,
        home_sr_change = home_applied_delta,
        away_sr_change = away_applied_delta,
        cancellation_code = 'CLAN_CANCELLED',
        cancellation_reason = normalized_reason,
        cancelled_at = clock_timestamp(),
        cancelled_by = actor_admin_id,
        cancellation_context = jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'resolution_type', normalized_resolution
        ),
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp()
      where id = match_id_to_use;
    end if;

    select * into fixture_to_resolve
    from public.fixtures where id = match_id_to_use;
    home_refund_id := public.record_match_resolution_refund(
      case_to_resolve.id, revision_id_to_use,
      home_payer_to_use, home_clan_id_to_use, 'HOME',
      home_amount_to_use, home_existing_refund, home_refund_bps_to_use,
      terms_to_use.policy_version_id, null,
      'Clan match refund after an administrative match resolution.'
    );
    away_refund_id := public.record_match_resolution_refund(
      case_to_resolve.id, revision_id_to_use,
      away_payer_to_use, away_clan_id_to_use, 'AWAY',
      away_amount_to_use, away_existing_refund, away_refund_bps_to_use,
      terms_to_use.policy_version_id, null,
      'Clan match refund after an administrative match resolution.'
    );
    update public.fixtures set
      home_refund_bps = greatest(home_refund_bps, home_refund_bps_to_use),
      home_refund_amount_fils = greatest(
        home_refund_amount_fils,
        (home_amount_to_use::bigint * home_refund_bps_to_use / 10000)::integer
      ),
      home_deposit_status = case
        when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when home_refund_bps_to_use = 10000 then 'RETURNED'
        when home_strikes_to_use > 0 then 'FORFEITED'
        else home_deposit_status end,
      away_refund_bps = greatest(away_refund_bps, away_refund_bps_to_use),
      away_refund_amount_fils = greatest(
        away_refund_amount_fils,
        (away_amount_to_use::bigint * away_refund_bps_to_use / 10000)::integer
      ),
      away_deposit_status = case
        when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when away_refund_bps_to_use = 10000 then 'RETURNED'
        when away_strikes_to_use > 0 then 'FORFEITED'
        else away_deposit_status end
    where id = match_id_to_use;
  else
    perform public.ensure_match_attendance_records('SOLO', match_id_to_use);

    for attendance_to_use in
      select attendance.*
      from public.match_attendance_records attendance
      where attendance.open_queue_game_id = match_id_to_use
      order by attendance.id
      for update
    loop
      attendance_state := upper(coalesce((
        select item ->> 'state'
        from jsonb_array_elements(
          coalesce(safe_payload -> 'attendance', '[]'::jsonb)
        ) item
        where item ->> 'profile_id' = attendance_to_use.profile_id::text
        limit 1
      ), ''));
      if attendance_state = '' then
        attendance_state := case
          when normalized_resolution = 'HOME_NO_SHOW'
            and attendance_to_use.side = 'WHITE' then 'NO_SHOW'
          when normalized_resolution = 'AWAY_NO_SHOW'
            and attendance_to_use.side = 'BLACK' then 'NO_SHOW'
          when normalized_resolution = 'BOTH_NO_SHOW' then 'NO_SHOW'
          when attendance_to_use.checked_in_at is not null then 'ON_TIME'
          else 'EXCUSED'
        end;
      end if;

      update public.match_attendance_records
      set
        outcome = case
          when attendance_state = 'NO_SHOW' then 'NO_SHOW'
          when attendance_state in ('ON_TIME', 'READY', 'PRESENT')
            and checked_in_at is not null then 'ON_TIME'
          else 'EXCUSED'
        end,
        strike_delta = case when attendance_state = 'NO_SHOW'
          then player_no_show_strikes else 0 end,
        finalized_at = clock_timestamp(),
        appeal_due_at = clock_timestamp() + interval '24 hours',
        consequence_snapshot = consequence_snapshot || jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'case_id', case_to_resolve.id,
          'revision_id', revision_id_to_use
        )
      where id = attendance_to_use.id
      returning * into attendance_to_use;

      if attendance_to_use.outcome = 'NO_SHOW'
        and attendance_to_use.strike_delta > 0
      then
        incident_id_to_use := public.record_reliability_incident(
          attendance_to_use.id,
          'NO_SHOW',
          attendance_to_use.strike_delta,
          attendance_to_use.finalized_at
        );
        if incident_id_to_use is not null then
          insert into public.match_resolution_incident_links (
            case_id, revision_id, incident_id, effect_kind
          ) values (
            case_to_resolve.id, revision_id_to_use,
            incident_id_to_use, 'APPLIED'
          ) on conflict do nothing;
        end if;
      end if;
    end loop;

    if resolution_is_final_result then
      update public.open_queue_bookings booking
      set played = exists (
        select 1
        from public.match_attendance_records attendance
        where attendance.booking_id = booking.id
          and attendance.outcome in ('ON_TIME', 'LATE')
      )
      where booking.game_id = match_id_to_use
        and booking.status = 'CONFIRMED';

      update public.open_queue_bookings booking
      set rating_at_match_start = coalesce(
        booking.rating_at_match_start,
        rating.skill_rating
      )
      from public.player_ratings rating
      where booking.game_id = match_id_to_use
        and booking.profile_id = rating.profile_id
        and booking.status = 'CONFIRMED'
        and booking.played;

      if not exists (
        select 1 from public.open_queue_bookings booking
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED'
          and booking.played and booking.team = 'WHITE'
      ) or not exists (
        select 1 from public.open_queue_bookings booking
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED'
          and booking.played and booking.team = 'BLACK'
      ) then
        raise exception 'Confirm at least one player who took part for each solo team before recording a result.';
      end if;

      update public.open_queue_games
      set
        status = 'FINAL',
        white_score = home_score_to_use,
        black_score = away_score_to_use,
        cancellation_code = null,
        cancellation_reason = null,
        cancelled_at = null,
        cancelled_by = null,
        cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
          || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use
          ),
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp()
      where id = match_id_to_use;
    elsif normalized_resolution in (
      'FIELD_OR_VENUE_CANCELLATION', 'ADMINISTRATIVE_VOID'
    ) then
      perform public.admin_cancel_match(
        actor_admin_id,
        'SOLO',
        match_id_to_use,
        case when normalized_resolution = 'FIELD_OR_VENUE_CANCELLATION'
          then 'WEATHER_OR_VENUE' else 'ADMIN_DECISION' end,
        normalized_reason
      );
      update public.open_queue_games set
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp(),
        cancellation_context = coalesce(cancellation_context, '{}'::jsonb)
          || jsonb_build_object(
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use
          )
      where id = match_id_to_use;
    else
      update public.open_queue_games
      set
        status = 'CANCELLED',
        white_score = null,
        black_score = null,
        cancellation_code = 'ADMIN_DECISION',
        cancellation_reason = normalized_reason,
        cancelled_at = clock_timestamp(),
        cancelled_by = actor_admin_id,
        cancellation_context = jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'resolution_type', normalized_resolution
        ),
        operational_state = 'RESOLVED',
        operational_state_updated_at = clock_timestamp()
      where id = match_id_to_use;
    end if;

    for booking_to_use in
      select booking.*
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
      order by booking.id
      for update
    loop
      select coalesce(booking_to_use.team, attendance.side)
      into attendance_state
      from public.match_attendance_records attendance
      where attendance.booking_id = booking_to_use.id
      limit 1;
      attendance_state := coalesce(
        attendance_state,
        booking_to_use.team,
        'WHITE'
      );
      home_refund_id := public.record_match_resolution_refund(
        case_to_resolve.id,
        revision_id_to_use,
        booking_to_use.profile_id,
        null,
        attendance_state,
        booking_to_use.amount_paid_fils,
        coalesce(booking_to_use.refund_amount_fils, 0),
        case when attendance_state = 'WHITE'
          then home_refund_bps_to_use else away_refund_bps_to_use end,
        terms_to_use.policy_version_id,
        booking_to_use.id,
        'Solo match refund after an administrative match resolution.'
      );

      if resolution_is_cancellation then
        update public.open_queue_bookings booking
        set
          status = 'CANCELLED',
          cancelled_at = coalesce(cancelled_at, clock_timestamp()),
          refund_bps = greatest(
            coalesce(refund_bps, 0),
            case when attendance_state = 'WHITE'
              then home_refund_bps_to_use else away_refund_bps_to_use end
          ),
          refund_percent = round((
            case when attendance_state = 'WHITE'
              then home_refund_bps_to_use else away_refund_bps_to_use end
          ) / 100.0)::integer,
          refund_amount_fils = greatest(
            coalesce(refund_amount_fils, 0),
            (
              amount_paid_fils::bigint *
              case when attendance_state = 'WHITE'
                then home_refund_bps_to_use else away_refund_bps_to_use end
              / 10000
            )::integer
          ),
          refund_status = case
            when exists (
              select 1 from public.match_resolution_refunds refund
              where refund.revision_id = revision_id_to_use
                and refund.recipient_profile_id = booking.profile_id
                and refund.status = 'FAILED'
            ) then 'FAILED'
            when (
              case when attendance_state = 'WHITE'
                then home_refund_bps_to_use else away_refund_bps_to_use end
            ) > 0 then 'PROCESSED'
            else 'NOT_DUE' end,
          payment_status = case
            when (
              case when attendance_state = 'WHITE'
                then home_refund_bps_to_use else away_refund_bps_to_use end
            ) = 10000 then 'REFUNDED'
            when (
              case when attendance_state = 'WHITE'
                then home_refund_bps_to_use else away_refund_bps_to_use end
            ) > 0 then 'PARTIALLY_REFUNDED'
            else 'NO_REFUND' end
        where booking.id = booking_to_use.id;
      end if;
    end loop;
  end if;

  update public.match_resolution_cases
  set
    state = 'RESOLVED',
    resolved_at = clock_timestamp(),
    resolved_by = actor_admin_id,
    current_revision = next_revision,
    evidence_snapshot = evidence_snapshot || jsonb_build_object(
      'resolved_evidence', safe_payload -> 'evidence',
      'resolved_at', clock_timestamp()
    )
  where id = case_to_resolve.id;

  update public.match_resolution_revisions
  set consequence_snapshot = consequence_snapshot || jsonb_build_object(
    'home_sr_delta_applied', home_applied_delta,
    'away_sr_delta_applied', away_applied_delta,
    'home_refund_id', home_refund_id,
    'away_refund_id', away_refund_id,
    'correction_reversals', reversal_summary
  )
  where id = revision_id_to_use;

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
    case when is_correction
      then 'MATCH_RESOLUTION_CORRECTED'
      else 'NO_DATA_MATCH_RESOLVED' end,
    entity_type_to_use,
    match_id_to_use,
    normalized_reason,
    jsonb_build_object(
      'match', current_before,
      'case', to_jsonb(case_to_resolve),
      'previous_revision_id', previous_revision_id
    ),
    jsonb_build_object(
      'case_id', case_to_resolve.id,
      'revision_id', revision_id_to_use,
      'revision', next_revision,
      'resolution_type', normalized_resolution,
      'consequences', consequence_to_use,
      'reversals', reversal_summary
    )
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
  select distinct
    affected.profile_id,
    'MATCH_RESOLUTION_RECORDED',
    'Match record updated',
    left(
      'Field reviewed the missing match record: ' ||
        initcap(replace(lower(normalized_resolution), '_', ' ')) ||
        '. Open the match for SR, strike and refund details.',
      300
    ),
    entity_type_to_use,
    match_id_to_use,
    jsonb_build_object(
      'match_kind', normalized_kind,
      'match_id', match_id_to_use,
      'case_id', case_to_resolve.id,
      'revision_id', revision_id_to_use,
      'resolution_type', normalized_resolution,
      'consequences', consequence_to_use
    )
  from (
    select member.profile_id
    from public.clan_members member
    where normalized_kind = 'CLAN'
      and member.left_at is null
      and member.clan_id in (home_clan_id_to_use, away_clan_id_to_use)
    union
    select booking.profile_id
    from public.open_queue_bookings booking
    where normalized_kind = 'SOLO'
      and booking.game_id = match_id_to_use
  ) affected
  where affected.profile_id is not null;

  select jsonb_build_object(
    'case_id', review_case.id,
    'state', review_case.state,
    'revision', review_case.current_revision,
    'revision_id', revision_id_to_use,
    'resolution_type', normalized_resolution,
    'consequences', revision.consequence_snapshot,
    'refunds', coalesce((
      select jsonb_agg(to_jsonb(refund) order by refund.side, refund.id)
      from public.match_resolution_refunds refund
      where refund.revision_id = revision_id_to_use
    ), '[]'::jsonb)
  ) into result_to_return
  from public.match_resolution_cases review_case
  join public.match_resolution_revisions revision
    on revision.id = revision_id_to_use
  where review_case.id = case_to_resolve.id;

  return result_to_return;
end;
$$;

revoke all on function public.admin_resolve_match_case(
  uuid,text,uuid,integer,text,text,jsonb
) from public, anon, authenticated;
grant execute on function public.admin_resolve_match_case(
  uuid,text,uuid,integer,text,text,jsonb
) to service_role;

create or replace function public.admin_reopen_match_resolution(
  actor_admin_id uuid,
  case_id_to_reopen uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  review_case public.match_resolution_cases%rowtype;
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  match_id_to_use uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Add a clear correction reason (at least 10 characters).';
  end if;

  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.id = case_id_to_reopen
  for update;
  if review_case.id is null then
    raise exception 'Match resolution case not found.';
  end if;
  if review_case.state <> 'RESOLVED' then
    raise exception 'Only a resolved case can be reopened.';
  end if;

  match_id_to_use := coalesce(
    review_case.fixture_id,
    review_case.open_queue_game_id
  );
  update public.match_resolution_cases
  set
    state = 'UNDER_REVIEW',
    reason_code = 'DISPUTED',
    resolved_at = null,
    resolved_by = null
  where id = review_case.id;

  if review_case.match_kind = 'CLAN' then
    update public.fixtures set
      operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = 'DISPUTED'
    where id = review_case.fixture_id;
  else
    update public.open_queue_games set
      operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = 'DISPUTED'
    where id = review_case.open_queue_game_id;
  end if;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    'MATCH_RESOLUTION_REOPENED',
    case when review_case.match_kind = 'CLAN'
      then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_use,
    normalized_reason,
    to_jsonb(review_case),
    jsonb_build_object(
      'state', 'UNDER_REVIEW',
      'refunds_unchanged', true,
      'current_revision', review_case.current_revision
    )
  );

  return jsonb_build_object(
    'case_id', review_case.id,
    'state', 'UNDER_REVIEW',
    'current_revision', review_case.current_revision,
    'refunds_unchanged', true
  );
end;
$$;

create or replace function public.submit_match_resolution_dispute(
  case_id_to_use uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  review_case public.match_resolution_cases%rowtype;
  current_revision_id uuid;
  clan_id_to_use uuid;
  dispute_id_to_use uuid;
  match_id_to_use uuid;
  normalized_reason text := trim(coalesce(reason_to_use, ''));
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Explain what should be reviewed (at least 10 characters).';
  end if;

  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.id = case_id_to_use
  for update;
  if review_case.id is null or review_case.current_revision <= 0 then
    raise exception 'A resolved match record is required.';
  end if;
  if review_case.resolved_at is null
    or clock_timestamp() > review_case.resolved_at + interval '24 hours'
  then
    raise exception 'The 24-hour match dispute window has closed.';
  end if;

  if review_case.match_kind = 'CLAN' then
    select member.clan_id into clan_id_to_use
    from public.clan_members member
    join public.fixtures fixture
      on fixture.id = review_case.fixture_id
    where member.profile_id = user_id
      and member.left_at is null
      and member.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
    limit 1;
    if clan_id_to_use is null then
      raise exception 'Only an affected clan member can dispute this result.';
    end if;
  elsif not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = review_case.open_queue_game_id
      and booking.profile_id = user_id
  ) then
    raise exception 'Only a player from this match can dispute this result.';
  end if;

  select revision.id into current_revision_id
  from public.match_resolution_revisions revision
  where revision.case_id = review_case.id
    and revision.revision = review_case.current_revision;

  insert into public.match_resolution_disputes (
    case_id,
    revision_id,
    submitted_by,
    clan_id,
    reason
  ) values (
    review_case.id,
    current_revision_id,
    user_id,
    clan_id_to_use,
    normalized_reason
  ) returning id into dispute_id_to_use;

  update public.match_resolution_cases
  set
    state = 'UNDER_REVIEW',
    reason_code = 'DISPUTED',
    resolved_at = null,
    resolved_by = null
  where id = review_case.id;

  match_id_to_use := coalesce(
    review_case.fixture_id,
    review_case.open_queue_game_id
  );
  if review_case.match_kind = 'CLAN' then
    update public.fixtures set
      operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp()
    where id = review_case.fixture_id;
  else
    update public.open_queue_games set
      operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp()
    where id = review_case.open_queue_game_id;
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
    admin.profile_id,
    'MATCH_RESOLUTION_DISPUTED',
    'Match resolution disputed',
    'An affected player or clan member disputed an administrative match resolution.',
    case when review_case.match_kind = 'CLAN'
      then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_use,
    jsonb_build_object(
      'case_id', review_case.id,
      'dispute_id', dispute_id_to_use,
      'refunds_continue', true
    )
  from public.referee_profiles admin
  where admin.role = 'admin' and admin.is_active;

  return jsonb_build_object(
    'dispute_id', dispute_id_to_use,
    'case_id', review_case.id,
    'state', 'UNDER_REVIEW',
    'refunds_continue', true
  );
end;
$$;

revoke all on function public.admin_reopen_match_resolution(uuid,uuid,text)
from public, anon, authenticated;
revoke all on function public.submit_match_resolution_dispute(uuid,text)
from public, anon, authenticated;
grant execute on function public.admin_reopen_match_resolution(uuid,uuid,text)
to service_role;
grant execute on function public.submit_match_resolution_dispute(uuid,text)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Canonical control-plane overrides
-- ---------------------------------------------------------------------------
-- The functions below deliberately replace the first-pass definitions above.
-- Keeping the schema creation and the final behavior in one migration makes it
-- possible to deploy safely over the existing reliability system without
-- mutating its append-only legacy rows.

-- Existing clan FINAL/CANCELLED finance triggers remain authoritative for
-- ordinary referee and cancellation flows. A resolution revision settles its
-- own deposits/refunds, so those triggers must stand down only for the
-- transaction-scoped control-plane transition.
do $migration$
declare
  function_definition text;
  old_guard text;
  new_guard text;
begin
  select pg_get_functiondef(
    'public.settle_completed_clan_fixture_finance()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if new.status <> ''FINAL''';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if new.status <> ''FINAL''';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to completed clan settlement.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.settle_field_cancelled_clan_fixture()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if new.status <> ''CANCELLED''';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if new.status <> ''CANCELLED''';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to cancelled clan settlement.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.protect_rated_open_queue_booking_inputs()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if tg_op = ''DELETE'' and pg_trigger_depth() > 1 then';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return case when tg_op = ''DELETE'' then old else new end;\n  end if;\n\n  if tg_op = ''DELETE'' and pg_trigger_depth() > 1 then';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to rated solo lineups.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.protect_rated_fixture_appearance_inputs()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if tg_op = ''DELETE'' and pg_trigger_depth() > 1 then';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return case when tg_op = ''DELETE'' then old else new end;\n  end if;\n\n  if tg_op = ''DELETE'' and pg_trigger_depth() > 1 then';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to rated clan lineups.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  -- A correction may need to restore a booking that this control plane
  -- changed from CONFIRMED to CANCELLED after the match had already started.
  -- Normal booking, suspension and check-in guards correctly reject that as a
  -- new booking. The resolver independently limits restoration to booking ids
  -- captured in the superseded revision and to explicit audited attendance.
  select pg_get_functiondef(
    'public.enforce_open_queue_booking_capacity()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if new.status <> ''CONFIRMED'' then';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if new.status <> ''CONFIRMED'' then';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to solo booking capacity.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.enforce_profile_play_restriction()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if tg_op = ''INSERT'' then';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if tg_op = ''INSERT'' then';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to solo play restrictions.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.enforce_fixture_appearance_restriction()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if tg_op = ''INSERT'' then';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if tg_op = ''INSERT'' then';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to clan appearance restrictions.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.enforce_reliability_booking_restriction()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if new.status = ''CONFIRMED''';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if new.status = ''CONFIRMED''';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to reliability booking restrictions.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;

  select pg_get_functiondef(
    'public.require_checked_in_match_participant()'::regprocedure
  ) into function_definition;
  if position('field.match_resolution_control_plane' in function_definition) = 0
  then
    old_guard := E'begin\n  if not coalesce(new.played, false)';
    new_guard := E'begin\n  if coalesce(nullif(current_setting(''field.match_resolution_control_plane'', true), ''''), ''off'') = ''on'' then\n    return new;\n  end if;\n\n  if not coalesce(new.played, false)';
    if position(old_guard in function_definition) = 0 then
      raise exception
        'Could not add the match-resolution guard to audited played lineups.';
    end if;
    execute replace(function_definition, old_guard, new_guard);
  end if;
end;
$migration$;

create or replace function public.match_resolution_attendance_state(
  payload_to_use jsonb,
  profile_id_to_use uuid,
  side_to_use text
)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  payload jsonb := coalesce(payload_to_use, '{}'::jsonb);
  attendance jsonb := coalesce(payload_to_use -> 'attendance', '{}'::jsonb);
  candidate jsonb;
  item jsonb;
  normalized_side text := upper(trim(coalesce(side_to_use, '')));
  result_to_use text;
begin
  if profile_id_to_use is not null and jsonb_typeof(attendance) = 'array' then
    for item in select value from jsonb_array_elements(attendance)
    loop
      if jsonb_typeof(item) = 'object'
        and item ->> 'profile_id' = profile_id_to_use::text
      then
        candidate := item -> 'state';
        exit;
      end if;
    end loop;
  elsif profile_id_to_use is not null
    and jsonb_typeof(attendance) = 'object'
  then
    candidate := attendance -> profile_id_to_use::text;
    if candidate is null and jsonb_typeof(attendance -> 'players') = 'array' then
      for item in
        select value from jsonb_array_elements(attendance -> 'players')
      loop
        if jsonb_typeof(item) = 'object'
          and item ->> 'profile_id' = profile_id_to_use::text
        then
          candidate := item -> 'state';
          exit;
        end if;
      end loop;
    end if;
  end if;

  if candidate is null and normalized_side <> ''
    and jsonb_typeof(attendance) = 'object'
  then
    candidate := attendance -> normalized_side;
  end if;
  if candidate is null and normalized_side in ('HOME', 'WHITE') then
    candidate := payload -> 'home_attendance_state';
  elsif candidate is null and normalized_side in ('AWAY', 'BLACK') then
    candidate := payload -> 'away_attendance_state';
  end if;

  if jsonb_typeof(candidate) = 'object' then
    result_to_use := candidate ->> 'state';
  elsif jsonb_typeof(candidate) = 'string' then
    result_to_use := trim(both '"' from candidate::text);
  end if;
  result_to_use := upper(trim(coalesce(result_to_use, '')));
  if result_to_use not in (
    '', 'PRESENT', 'READY', 'ON_TIME', 'LATE', 'NO_SHOW',
    'EXCUSED', 'SHORT_ROSTER', 'FORFEIT', 'UNKNOWN'
  ) then
    raise exception 'Unsupported attendance state: %.', result_to_use;
  end if;
  return result_to_use;
end;
$$;

create or replace function public.match_resolution_has_explicit_player_attendance(
  payload_to_use jsonb,
  profile_id_to_use uuid
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  attendance jsonb := coalesce(payload_to_use, '{}'::jsonb)
    -> 'attendance';
  candidate jsonb;
  item jsonb;
  explicit_state text := '';
begin
  if profile_id_to_use is null then
    return false;
  end if;
  if jsonb_typeof(attendance) = 'array' then
    for item in select value from jsonb_array_elements(attendance)
    loop
      if jsonb_typeof(item) = 'object'
        and item ->> 'profile_id' = profile_id_to_use::text
      then
        candidate := item -> 'state';
        exit;
      end if;
    end loop;
  elsif jsonb_typeof(attendance) = 'object' then
    candidate := attendance -> profile_id_to_use::text;
    if candidate is null and jsonb_typeof(attendance -> 'players') = 'array' then
      for item in
        select value from jsonb_array_elements(attendance -> 'players')
      loop
        if jsonb_typeof(item) = 'object'
          and item ->> 'profile_id' = profile_id_to_use::text
        then
          candidate := item -> 'state';
          exit;
        end if;
      end loop;
    end if;
  end if;

  if jsonb_typeof(candidate) = 'object' then
    explicit_state := candidate ->> 'state';
  elsif jsonb_typeof(candidate) = 'string' then
    explicit_state := trim(both '"' from candidate::text);
  end if;
  return upper(trim(coalesce(explicit_state, ''))) in (
    'PRESENT', 'READY', 'ON_TIME', 'LATE', 'NO_SHOW',
    'EXCUSED', 'SHORT_ROSTER', 'FORFEIT', 'UNKNOWN'
  );
end;
$$;

create or replace function public.detect_due_match_resolution_cases()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  evidence_to_use jsonb;
  terms_to_use public.match_reliability_terms%rowtype;
  policy_snapshot_to_use jsonb;
  case_id_to_use uuid;
  detection_reason_to_use text;
  inserted_total integer := 0;
begin
  for candidate in
    (
      select
        'CLAN'::text as match_kind,
        fixture.id as match_id,
        public.fixture_end_at(fixture.match_date, fixture.time_slot)
          as scheduled_end_at,
        fixture.home_score as home_score,
        fixture.away_score as away_score
      from public.fixtures fixture
      where (
          fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
          or (
            fixture.status = 'FINAL'
            and (
              fixture.home_score is null
              or fixture.away_score is null
            )
          )
        )
        and fixture.away_clan_id is not null
        and public.fixture_end_at(fixture.match_date, fixture.time_slot)
          + interval '30 minutes' <= clock_timestamp()
        and not exists (
          select 1 from public.match_resolution_cases existing_case
          where existing_case.fixture_id = fixture.id
        )
        and not exists (
          select 1 from public.match_forfeit_decisions decision
          where decision.fixture_id = fixture.id
        )
        and not exists (
          select 1 from public.clan_fixture_cancellations cancellation
          where cancellation.fixture_id = fixture.id
        )
      union all
      select
        'SOLO'::text,
        game.id,
        game.ends_at,
        game.white_score,
        game.black_score
      from public.open_queue_games game
      where (
          game.status in ('OPEN', 'FULL', 'LIVE')
          or (
            game.status = 'FINAL'
            and (
              game.white_score is null
              or game.black_score is null
            )
          )
        )
        and game.ends_at + interval '30 minutes' <= clock_timestamp()
        and not exists (
          select 1 from public.match_resolution_cases existing_case
          where existing_case.open_queue_game_id = game.id
        )
    )
    order by scheduled_end_at, match_id
    limit 250
  loop
    case_id_to_use := null;
    evidence_to_use := public.match_resolution_evidence_snapshot(
      candidate.match_kind,
      candidate.match_id
    ) || jsonb_build_object(
      'captured_home_score', candidate.home_score,
      'captured_away_score', candidate.away_score
    );
    detection_reason_to_use := case
      when coalesce(
        (evidence_to_use ->> 'has_activity')::boolean,
        false
      ) or candidate.home_score is not null or candidate.away_score is not null
        then 'RESULT_MISSING'
      when coalesce(
        (evidence_to_use ->> 'referee_assigned')::boolean,
        false
      ) then 'REFEREE_REPORT_MISSING'
      else 'NO_ACTIVITY'
    end;
    evidence_to_use := evidence_to_use || jsonb_build_object(
      'detection_reason_code', detection_reason_to_use
    );
    terms_to_use := null;
    begin
      terms_to_use := public.ensure_match_reliability_terms(
        candidate.match_kind,
        candidate.match_id
      );
      policy_snapshot_to_use := terms_to_use.policy_snapshot;
    exception when others then
      -- Legacy pre-policy matches are reviewable, but may not receive newly
      -- invented reliability penalties.
      policy_snapshot_to_use := jsonb_build_object(
        'legacy_match', true,
        'penalties_available', false,
        'policy_error', left(sqlerrm, 500)
      );
    end;

    insert into public.match_resolution_cases (
      match_kind,
      fixture_id,
      open_queue_game_id,
      state,
      reason_code,
      scheduled_end_at,
      detected_at,
      high_priority_at,
      evidence_snapshot,
      policy_snapshot
    ) values (
      candidate.match_kind,
      case when candidate.match_kind = 'CLAN'
        then candidate.match_id end,
      case when candidate.match_kind = 'SOLO'
        then candidate.match_id end,
      'NO_DATA',
      detection_reason_to_use,
      candidate.scheduled_end_at,
      clock_timestamp(),
      clock_timestamp() + interval '24 hours',
      evidence_to_use,
      policy_snapshot_to_use
    )
    on conflict do nothing
    returning id into case_id_to_use;

    if case_id_to_use is null then
      continue;
    end if;
    if candidate.match_kind = 'CLAN' then
      update public.fixtures
      set operational_state = 'NO_DATA',
        operational_state_updated_at = clock_timestamp(),
        operational_reason_code = (
          select review_case.reason_code
          from public.match_resolution_cases review_case
          where review_case.id = case_id_to_use
        )
      where id = candidate.match_id;
    else
      update public.open_queue_games
      set operational_state = 'NO_DATA',
        operational_state_updated_at = clock_timestamp(),
        operational_reason_code = (
          select review_case.reason_code
          from public.match_resolution_cases review_case
          where review_case.id = case_id_to_use
        )
      where id = candidate.match_id;
    end if;
    inserted_total := inserted_total + 1;
  end loop;
  return inserted_total;
end;
$$;

create or replace function public.record_match_resolution_refund(
  case_id_to_use uuid,
  revision_id_to_use uuid,
  recipient_profile_id_to_use uuid,
  clan_id_to_use uuid,
  side_to_use text,
  gross_amount_fils_to_use integer,
  previously_refunded_fils_to_use integer,
  refund_bps_to_use integer,
  policy_version_id_to_use uuid,
  booking_id_to_use uuid,
  description_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_bps integer := greatest(
    0, least(10000, coalesce(refund_bps_to_use, 0))
  );
  target_amount integer := greatest(
    -- The retained parameter name preserves PostgreSQL's function identity;
    -- canonical callers pass the already-computed cumulative target here.
    0, coalesce(gross_amount_fils_to_use, 0)
  );
  prior_amount integer := greatest(
    0, coalesce(previously_refunded_fils_to_use, 0)
  );
  missing_amount integer;
  refund_id_to_use uuid;
  wallet_transaction_id_to_use uuid;
begin
  missing_amount := greatest(0, target_amount - prior_amount);
  insert into public.match_resolution_refunds (
    case_id,
    revision_id,
    recipient_profile_id,
    clan_id,
    side,
    amount_fils,
    target_amount_fils,
    previously_refunded_fils,
    refund_bps,
    destination,
    status,
    failure_reason,
    policy_version_id,
    booking_id
  ) values (
    case_id_to_use,
    revision_id_to_use,
    recipient_profile_id_to_use,
    clan_id_to_use,
    upper(trim(side_to_use)),
    missing_amount,
    target_amount,
    prior_amount,
    normalized_bps,
    case when target_amount <= 0 then 'NOT_REQUIRED'
      else 'FIELD_WALLET' end,
    case
      when target_amount <= 0 then 'NOT_REQUIRED'
      when missing_amount <= 0 then 'COMPLETED'
      when recipient_profile_id_to_use is null then 'FAILED'
      else 'PENDING'
    end,
    case when target_amount > 0 and missing_amount > 0
      and recipient_profile_id_to_use is null
      then 'The original payer is missing; an administrator must reconcile this refund.'
      else null end,
    policy_version_id_to_use,
    booking_id_to_use
  ) returning id into refund_id_to_use;

  if target_amount <= 0 or missing_amount <= 0
    or recipient_profile_id_to_use is null
  then
    return refund_id_to_use;
  end if;

  begin
    wallet_transaction_id_to_use := public.credit_field_wallet(
      recipient_profile_id_to_use,
      missing_amount,
      'FIELD_CANCELLATION_REFUND',
      'match-resolution:' || revision_id_to_use::text || ':' ||
        upper(trim(side_to_use)) || ':' ||
        recipient_profile_id_to_use::text,
      left(trim(description_to_use), 300),
      policy_version_id_to_use,
      booking_id_to_use,
      null,
      jsonb_build_object(
        'match_resolution_case_id', case_id_to_use,
        'match_resolution_revision_id', revision_id_to_use,
        'side', upper(trim(side_to_use)),
        'refund_bps', normalized_bps,
        'target_amount_fils', target_amount,
        'previously_refunded_fils', prior_amount
      )
    );
    update public.match_resolution_refunds
    set status = 'COMPLETED',
      wallet_transaction_id = wallet_transaction_id_to_use,
      failure_reason = null
    where id = refund_id_to_use;
  exception when others then
    update public.match_resolution_refunds
    set status = 'FAILED', failure_reason = left(sqlerrm, 1000)
    where id = refund_id_to_use;
  end;
  return refund_id_to_use;
end;
$$;

revoke all on function public.match_resolution_attendance_state(
  jsonb,uuid,text
) from public, anon, authenticated;
grant execute on function public.match_resolution_attendance_state(
  jsonb,uuid,text
) to service_role;
revoke all on function public.match_resolution_has_explicit_player_attendance(
  jsonb,uuid
) from public, anon, authenticated;
grant execute on function public.match_resolution_has_explicit_player_attendance(
  jsonb,uuid
) to service_role;

create or replace function public.record_match_resolution_incident(
  case_id_to_use uuid,
  revision_id_to_use uuid,
  subject_type_to_use text,
  profile_id_to_use uuid,
  clan_id_to_use uuid,
  booking_id_to_use uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  outcome_to_use text,
  strike_delta_to_use integer,
  policy_version_id_to_use uuid,
  policy_snapshot_to_use jsonb,
  actor_admin_id uuid,
  reason_to_use text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_subject text := upper(trim(coalesce(subject_type_to_use, '')));
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  active_before integer;
  active_after integer;
  strike_lifetime_days integer;
  incident_id_to_use uuid;
  sanction_rule jsonb;
  threshold_to_use integer;
  sanction_kind_to_use text;
  duration_days_to_use integer;
  release_future boolean;
  issuer_label_to_use text;
  sanction_id_to_use uuid;
  future_booking public.open_queue_bookings%rowtype;
  release_refund_bps integer;
  release_refund_fils integer;
  release_credit_fils integer;
begin
  if strike_delta_to_use <= 0 then
    return null;
  end if;
  if strike_delta_to_use > 20 then
    raise exception 'A reliability incident cannot add more than 20 strikes.';
  end if;
  if policy_version_id_to_use is null then
    raise exception
      'Legacy matches cannot receive newly invented reliability penalties.';
  end if;
  if normalized_subject = 'CLAN' then
    if clan_id_to_use is null or profile_id_to_use is not null then
      raise exception 'A clan incident requires exactly one clan.';
    end if;
    perform pg_advisory_xact_lock(
      hashtextextended(clan_id_to_use::text, 9175)
    );
    active_before := public.active_clan_reliability_strikes(
      clan_id_to_use, clock_timestamp()
    );
  elsif normalized_subject = 'PLAYER' then
    if profile_id_to_use is null or clan_id_to_use is not null then
      raise exception 'A player incident requires exactly one player.';
    end if;
    perform pg_advisory_xact_lock(
      hashtextextended(profile_id_to_use::text, 9174)
    );
    active_before := public.active_reliability_strikes(
      profile_id_to_use, clock_timestamp()
    );
  else
    raise exception 'A match-resolution incident must target a player or clan.';
  end if;

  select profile.display_name into issuer_label_to_use
  from public.profiles profile
  where profile.id = actor_admin_id;
  issuer_label_to_use := coalesce(
    nullif(trim(issuer_label_to_use), ''),
    'Field administrator'
  );
  strike_lifetime_days := greatest(1, coalesce(
    (policy_snapshot_to_use #>>
      '{attendance,strikeLifetimeDays}')::integer,
    90
  ));
  active_after := active_before + strike_delta_to_use;

  -- Deliberately leave attendance_id/fixture_id NULL. Legacy uniqueness means
  -- “one finding ever per attendance/fixture”; a revision ledger needs a new
  -- immutable finding after a prior one was reversed.
  insert into public.reliability_incidents (
    subject_type,
    profile_id,
    clan_id,
    attendance_id,
    booking_id,
    fixture_id,
    outcome,
    strike_delta,
    occurred_at,
    expires_at,
    policy_version_id,
    reversal_of,
    active_count_before,
    active_count_after,
    detail
  ) values (
    normalized_subject,
    profile_id_to_use,
    clan_id_to_use,
    null,
    booking_id_to_use,
    null,
    upper(trim(outcome_to_use)),
    strike_delta_to_use,
    clock_timestamp(),
    clock_timestamp() + make_interval(days => strike_lifetime_days),
    policy_version_id_to_use,
    null,
    active_before,
    active_after,
    jsonb_build_object(
      'match_kind', normalized_kind,
      'fixture_id', case when normalized_kind = 'CLAN'
        then match_id_to_use end,
      'open_queue_game_id', case when normalized_kind = 'SOLO'
        then match_id_to_use end,
      'match_resolution_case_id', case_id_to_use,
      'match_resolution_revision_id', revision_id_to_use,
      'reason', left(trim(reason_to_use), 1000),
      'issuer_profile_id', actor_admin_id,
      'issuer_label', issuer_label_to_use
    )
  ) returning id into incident_id_to_use;

  insert into public.match_resolution_incident_links (
    case_id, revision_id, incident_id, effect_kind
  ) values (
    case_id_to_use, revision_id_to_use, incident_id_to_use, 'APPLIED'
  );

  for sanction_rule in
    select candidate.value
    from jsonb_array_elements(
      coalesce(
        case when normalized_subject = 'CLAN'
          then policy_snapshot_to_use #> '{clan,sanctions}'
          else policy_snapshot_to_use #> '{solo,sanctions}' end,
        '[]'::jsonb
      )
    ) candidate(value)
    where (candidate.value ->> 'threshold')::integer > active_before
      and (candidate.value ->> 'threshold')::integer <= active_after
      and (
        normalized_subject = 'CLAN'
        or not coalesce(
          (policy_snapshot_to_use #>> '{solo,highestCrossedOnly}')::boolean,
          false
        )
        or (candidate.value ->> 'threshold')::integer = (
          select max((crossed.value ->> 'threshold')::integer)
          from jsonb_array_elements(
            coalesce(
              policy_snapshot_to_use #> '{solo,sanctions}',
              '[]'::jsonb
            )
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
    release_future := case when normalized_subject = 'PLAYER'
      then coalesce(
        (sanction_rule ->> 'releaseFutureBookings')::boolean,
        false
      )
      else false end;

    insert into public.reliability_sanctions (
      subject_type,
      profile_id,
      clan_id,
      incident_id,
      policy_version_id,
      threshold,
      sanction_kind,
      starts_at,
      ends_at,
      release_future_bookings
    ) values (
      normalized_subject,
      profile_id_to_use,
      clan_id_to_use,
      incident_id_to_use,
      policy_version_id_to_use,
      threshold_to_use,
      sanction_kind_to_use,
      clock_timestamp(),
      case
        when sanction_kind_to_use in ('WARNING', 'INDEFINITE_SUSPENSION')
          then null
        else clock_timestamp() + make_interval(days => duration_days_to_use)
      end,
      release_future
    ) on conflict (incident_id, threshold) do update
      set incident_id = excluded.incident_id
    returning id into sanction_id_to_use;

    if normalized_subject = 'PLAYER' then
      insert into public.notifications (
        recipient_profile_id, type, title, body,
        related_entity_type, related_entity_id, data
      ) values (
        profile_id_to_use,
        'RELIABILITY_SANCTION',
        case sanction_kind_to_use
          when 'WARNING' then 'Reliability warning'
          when 'BOOKING_RESTRICTION'
            then 'New bookings temporarily restricted'
          when 'PARTICIPATION_SUSPENSION'
            then 'Participation temporarily suspended'
          else 'Account requires reliability review'
        end,
        'An administrative attendance finding crossed the ' ||
          threshold_to_use::text || '-strike policy threshold.',
        'RELIABILITY_SANCTION',
        sanction_id_to_use,
        jsonb_build_object(
          'active_strikes', active_after,
          'threshold', threshold_to_use,
          'sanction_kind', sanction_kind_to_use,
          'case_id', case_id_to_use,
          'revision_id', revision_id_to_use
        )
      );
    end if;

    if normalized_subject = 'PLAYER' and release_future then
      release_refund_bps := greatest(0, least(10000, coalesce(
        (policy_snapshot_to_use #>>
          '{solo,releaseFutureBookingsRefundBps}')::integer,
        0
      )));
      for future_booking in
        select booking.*
        from public.open_queue_bookings booking
        join public.open_queue_games game on game.id = booking.game_id
        where booking.profile_id = profile_id_to_use
          and booking.status = 'CONFIRMED'
          and game.status in ('OPEN', 'FULL')
          and game.starts_at > clock_timestamp()
          and booking.id is distinct from booking_id_to_use
        order by game.starts_at, booking.id
        for update of booking
      loop
        release_refund_fils := (
          coalesce(
            future_booking.base_amount_fils,
            future_booking.amount_paid_fils
              - future_booking.reliability_deposit_fils,
            0
          )::bigint * release_refund_bps / 10000
        )::integer + coalesce(
          future_booking.reliability_deposit_fils, 0
        );
        release_credit_fils := greatest(
          0,
          release_refund_fils
            - coalesce(future_booking.refund_amount_fils, 0)
        );
        update public.open_queue_bookings
        set status = 'CANCELLED',
          team = null,
          played = false,
          rating_at_team_assignment = null,
          rating_at_match_start = null,
          rating_change = null,
          cancelled_at = clock_timestamp(),
          refund_bps = greatest(
            coalesce(refund_bps, 0), release_refund_bps
          ),
          refund_percent = case
            when greatest(
              coalesce(refund_bps, 0), release_refund_bps
            ) >= 10000 then 100
            when greatest(
              coalesce(refund_bps, 0), release_refund_bps
            ) >= 5000 then 50
            else 0 end,
          refund_amount_fils = greatest(
            coalesce(refund_amount_fils, 0), release_refund_fils
          ),
          refund_status = case when release_refund_fils > 0
            then 'PROCESSED' else 'NOT_DUE' end,
          payment_status = case
            when amount_paid_fils > 0
              and release_refund_fils >= amount_paid_fils then 'REFUNDED'
            when release_refund_fils > 0 then 'PARTIALLY_REFUNDED'
            else 'NO_REFUND' end,
          reliability_deposit_status = case
            when coalesce(reliability_deposit_fils, 0) > 0
              then 'REFUNDED'
            else reliability_deposit_status end
        where id = future_booking.id;

        update public.match_attendance_records attendance
        set cancelled_at = clock_timestamp(),
          outcome = 'EXCUSED',
          strike_delta = 0,
          refund_bps = release_refund_bps,
          refund_amount_fils = release_refund_fils,
          deposit_resolution = case
            when attendance.reliability_deposit_fils > 0
              then 'RETURNED'
            else attendance.deposit_resolution end,
          finalized_at = clock_timestamp(),
          appeal_due_at = null,
          consequence_snapshot = consequence_snapshot ||
            jsonb_build_object(
              'outcome_code', 'EXCUSED',
              'reason', 'FUTURE_BOOKING_RELEASED_BY_SANCTION',
              'sanction_id', sanction_id_to_use,
              'policy_version_id', policy_version_id_to_use,
              'refund_bps', release_refund_bps,
              'case_id', case_id_to_use,
              'revision_id', revision_id_to_use
            )
        where attendance.booking_id = future_booking.id
          and attendance.outcome is null;

        insert into public.attendance_events (
          attendance_id, event_type, event_at, detail, idempotency_key
        )
        select attendance.id,
          'CANCELLED',
          clock_timestamp(),
          attendance.consequence_snapshot,
          'sanction-release:' || attendance.id::text
        from public.match_attendance_records attendance
        where attendance.booking_id = future_booking.id
        on conflict (idempotency_key) do nothing;

        if release_credit_fils > 0 then
          perform public.credit_field_wallet(
            future_booking.profile_id,
            release_credit_fils,
            'SUSPENSION_BOOKING_RELEASE',
            'reliability-release:' || future_booking.id::text || ':' ||
              sanction_id_to_use::text,
            'Future booking released after a reliability suspension.',
            policy_version_id_to_use,
            future_booking.id,
            incident_id_to_use,
            jsonb_build_object(
              'sanction_id', sanction_id_to_use,
              'case_id', case_id_to_use,
              'revision_id', revision_id_to_use,
              'target_refund_fils', release_refund_fils,
              'previously_refunded_fils',
                coalesce(future_booking.refund_amount_fils, 0)
            )
          );
        end if;
      end loop;
    end if;
  end loop;

  if normalized_subject = 'PLAYER' then
    insert into public.notifications (
      recipient_profile_id, type, title, body,
      related_entity_type, related_entity_id, data
    ) values (
      profile_id_to_use,
      'RELIABILITY_OUTCOME',
      'Attendance outcome recorded',
      'An administrative match review added ' || strike_delta_to_use ||
        case when strike_delta_to_use = 1
          then ' reliability strike.' else ' reliability strikes.' end,
      'RELIABILITY_INCIDENT',
      incident_id_to_use,
      jsonb_build_object(
        'case_id', case_id_to_use,
        'revision_id', revision_id_to_use,
        'match_kind', normalized_kind,
        'match_id', match_id_to_use
      )
    );
  else
    insert into public.notifications (
      recipient_profile_id, type, title, body,
      related_entity_type, related_entity_id, data
    )
    select
      member.profile_id,
      'CLAN_RELIABILITY_OUTCOME',
      'Clan attendance outcome recorded',
      'An administrative match review added ' || strike_delta_to_use ||
        case when strike_delta_to_use = 1
          then ' clan strike.' else ' clan strikes.' end,
      'CLAN_RELIABILITY_INCIDENT',
      incident_id_to_use,
      jsonb_build_object(
        'case_id', case_id_to_use,
        'revision_id', revision_id_to_use,
        'fixture_id', match_id_to_use,
        'clan_id', clan_id_to_use
      )
    from public.clan_members member
    where member.clan_id = clan_id_to_use
      and member.left_at is null
      and member.role in ('owner', 'leader');
  end if;
  return incident_id_to_use;
end;
$$;

create or replace function public.apply_match_resolution_clan_effect(
  case_id_to_use uuid,
  revision_id_to_use uuid,
  clan_id_to_use uuid,
  side_to_use text,
  rating_delta_to_use integer,
  wins_delta_to_use integer,
  losses_delta_to_use integer,
  adjustment_kind_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  clan_to_update public.clans%rowtype;
  rating_after_to_use integer;
  wins_after_to_use integer;
  losses_after_to_use integer;
  applied_rating_delta integer;
  applied_wins_delta integer;
  applied_losses_delta integer;
begin
  select * into clan_to_update
  from public.clans clan
  where clan.id = clan_id_to_use
  for update;
  if clan_to_update.id is null then
    raise exception 'Clan not found.';
  end if;

  rating_after_to_use := greatest(
    0, clan_to_update.skill_rating + coalesce(rating_delta_to_use, 0)
  );
  wins_after_to_use := greatest(
    0, clan_to_update.wins + coalesce(wins_delta_to_use, 0)
  );
  losses_after_to_use := greatest(
    0, clan_to_update.losses + coalesce(losses_delta_to_use, 0)
  );
  applied_rating_delta := rating_after_to_use - clan_to_update.skill_rating;
  applied_wins_delta := wins_after_to_use - clan_to_update.wins;
  applied_losses_delta := losses_after_to_use - clan_to_update.losses;

  update public.clans
  set skill_rating = rating_after_to_use,
    wins = wins_after_to_use,
    losses = losses_after_to_use
  where id = clan_id_to_use;

  insert into public.match_resolution_clan_sr_adjustments (
    case_id,
    revision_id,
    clan_id,
    side,
    rating_before,
    rating_delta,
    rating_after,
    wins_delta,
    losses_delta,
    adjustment_kind
  ) values (
    case_id_to_use,
    revision_id_to_use,
    clan_id_to_use,
    upper(trim(side_to_use)),
    clan_to_update.skill_rating,
    applied_rating_delta,
    rating_after_to_use,
    applied_wins_delta,
    applied_losses_delta,
    upper(trim(adjustment_kind_to_use))
  );
  return jsonb_build_object(
    'rating_delta', applied_rating_delta,
    'wins_delta', applied_wins_delta,
    'losses_delta', applied_losses_delta
  );
end;
$$;

create or replace function public.reverse_previous_match_resolution_effects(
  case_id_to_use uuid,
  new_revision_id_to_use uuid,
  actor_admin_id uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  linked record;
  prior_adjustment record;
  reversal_incident_id uuid;
  active_before integer;
  active_after integer;
  original_is_active boolean;
  reversed_incidents integer := 0;
  reversed_clan_effects integer := 0;
begin
  for prior_adjustment in
    select adjustment.*
    from public.match_resolution_clan_sr_adjustments adjustment
    join public.match_resolution_revisions revision
      on revision.id = adjustment.revision_id
    where adjustment.case_id = case_id_to_use
      and adjustment.adjustment_kind in ('RESOLUTION', 'CORRECTION')
      and revision.revision = (
        select max(previous_revision.revision)
        from public.match_resolution_revisions previous_revision
        where previous_revision.case_id = case_id_to_use
          and previous_revision.id <> new_revision_id_to_use
      )
    order by adjustment.clan_id
  loop
    perform public.apply_match_resolution_clan_effect(
      case_id_to_use,
      new_revision_id_to_use,
      prior_adjustment.clan_id,
      prior_adjustment.side,
      -prior_adjustment.rating_delta,
      -prior_adjustment.wins_delta,
      -prior_adjustment.losses_delta,
      'REVERSAL'
    );
    reversed_clan_effects := reversed_clan_effects + 1;
  end loop;

  for linked in
    select incident.*
    from public.match_resolution_incident_links link
    join public.reliability_incidents incident
      on incident.id = link.incident_id
    join public.match_resolution_revisions revision
      on revision.id = link.revision_id
    where link.case_id = case_id_to_use
      and link.effect_kind = 'APPLIED'
      and incident.reversal_of is null
      and not exists (
        select 1 from public.reliability_incidents reversal
        where reversal.reversal_of = incident.id
      )
      and revision.revision = (
        select max(previous_revision.revision)
        from public.match_resolution_revisions previous_revision
        where previous_revision.case_id = case_id_to_use
          and previous_revision.id <> new_revision_id_to_use
      )
    order by incident.id
  loop
    active_before := case when linked.subject_type = 'CLAN'
      then public.active_clan_reliability_strikes(
        linked.clan_id, clock_timestamp()
      )
      else public.active_reliability_strikes(
        linked.profile_id, clock_timestamp()
      ) end;
    original_is_active := linked.occurred_at <= clock_timestamp()
      and (
        linked.expires_at is null
        or linked.expires_at > clock_timestamp()
      );
    active_after := greatest(
      0,
      active_before - case when original_is_active
        then linked.strike_delta else 0 end
    );

    insert into public.reliability_incidents (
      subject_type,
      profile_id,
      clan_id,
      attendance_id,
      booking_id,
      fixture_id,
      outcome,
      strike_delta,
      occurred_at,
      expires_at,
      policy_version_id,
      reversal_of,
      active_count_before,
      active_count_after,
      detail
    ) values (
      linked.subject_type,
      linked.profile_id,
      linked.clan_id,
      null,
      linked.booking_id,
      null,
      'ADMIN_RESOLUTION_CORRECTED',
      -linked.strike_delta,
      clock_timestamp(),
      linked.expires_at,
      linked.policy_version_id,
      linked.id,
      active_before,
      active_after,
      jsonb_build_object(
        'reason', left(trim(reason_to_use), 1000),
        'issuer_profile_id', actor_admin_id,
        'issuer_label', 'Field administrator',
        'match_resolution_case_id', case_id_to_use,
        'match_resolution_revision_id', new_revision_id_to_use
      )
    ) returning id into reversal_incident_id;

    insert into public.match_resolution_incident_links (
      case_id, revision_id, incident_id, effect_kind
    ) values (
      case_id_to_use,
      new_revision_id_to_use,
      reversal_incident_id,
      'REVERSAL'
    );
    update public.reliability_sanctions
    set revoked_at = coalesce(revoked_at, clock_timestamp()),
      revoked_by = coalesce(revoked_by, actor_admin_id),
      revocation_reason = coalesce(
        revocation_reason,
        'Match resolution corrected: ' || left(trim(reason_to_use), 450)
      )
    where incident_id = linked.id and revoked_at is null;
    reversed_incidents := reversed_incidents + 1;
  end loop;

  return jsonb_build_object(
    'reversed_clan_effects', reversed_clan_effects,
    'reversed_incidents', reversed_incidents,
    'player_sr_policy', 'PRESERVE_APPLIED_SR',
    'refunds_reversed', false,
    'refund_note',
      'Completed refunds are never clawed back; later revisions only add a missing amount.'
  );
end;
$$;

revoke all on function public.record_match_resolution_incident(
  uuid,uuid,text,uuid,uuid,uuid,text,uuid,text,integer,uuid,jsonb,uuid,text
) from public, anon, authenticated;
revoke all on function public.apply_match_resolution_clan_effect(
  uuid,uuid,uuid,text,integer,integer,integer,text
) from public, anon, authenticated;
grant execute on function public.record_match_resolution_incident(
  uuid,uuid,text,uuid,uuid,uuid,text,uuid,text,integer,uuid,jsonb,uuid,text
) to service_role;
grant execute on function public.apply_match_resolution_clan_effect(
  uuid,uuid,uuid,text,integer,integer,integer,text
) to service_role;

create or replace function public.preserve_player_sr_for_resolution_score(
  match_kind_to_use text,
  match_id_to_use uuid,
  home_score_to_use integer,
  away_score_to_use integer
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  source_type_to_use text;
  home_side text;
  away_side text;
  adjusted_count integer := 0;
begin
  source_type_to_use := case when normalized_kind = 'CLAN'
    then 'CLAN_FIXTURE' else 'OPEN_QUEUE' end;
  home_side := case when normalized_kind = 'CLAN' then 'HOME' else 'WHITE' end;
  away_side := case when normalized_kind = 'CLAN' then 'AWAY' else 'BLACK' end;

  update public.player_ratings rating
  set wins = greatest(
        0,
        rating.wins
          - case when event.result = 'WIN' then 1 else 0 end
          + case
            when home_score_to_use = away_score_to_use then 0
            when (event.side = home_side
              and home_score_to_use > away_score_to_use)
              or (event.side = away_side
                and away_score_to_use > home_score_to_use)
              then 1 else 0 end
      ),
      losses = greatest(
        0,
        rating.losses
          - case when event.result = 'LOSS' then 1 else 0 end
          + case
            when home_score_to_use = away_score_to_use then 0
            when (event.side = home_side
              and home_score_to_use < away_score_to_use)
              or (event.side = away_side
                and away_score_to_use < home_score_to_use)
              then 1 else 0 end
      ),
      draws = greatest(
        0,
        rating.draws
          - case when event.result = 'DRAW' then 1 else 0 end
          + case when home_score_to_use = away_score_to_use
            then 1 else 0 end
      )
  from public.player_rating_events event
  where event.profile_id = rating.profile_id
    and event.source_type = source_type_to_use
    and event.source_id = match_id_to_use;
  get diagnostics adjusted_count = row_count;

  update public.player_rating_events event
  set result = case
        when home_score_to_use = away_score_to_use then 'DRAW'
        when (event.side = home_side
          and home_score_to_use > away_score_to_use)
          or (event.side = away_side
            and away_score_to_use > home_score_to_use)
          then 'WIN'
        else 'LOSS'
      end,
      actual_score = case
        when home_score_to_use = away_score_to_use then 0.5
        when (event.side = home_side
          and home_score_to_use > away_score_to_use)
          or (event.side = away_side
            and away_score_to_use > home_score_to_use)
          then 1 else 0
      end,
      calculation_version = 'ADMIN_MATCH_RESOLUTION_PRESERVE_SR'
  where event.source_type = source_type_to_use
    and event.source_id = match_id_to_use;
  return adjusted_count;
end;
$$;

revoke all on function public.preserve_player_sr_for_resolution_score(
  text,uuid,integer,integer
) from public, anon, authenticated;
grant execute on function public.preserve_player_sr_for_resolution_score(
  text,uuid,integer,integer
) to service_role;

create or replace function public.admin_resolve_match_case(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  expected_revision_to_use integer,
  resolution_type_to_use text,
  reason_to_use text,
  payload_to_use jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  normalized_resolution text := upper(
    trim(coalesce(resolution_type_to_use, ''))
  );
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  safe_payload jsonb := coalesce(payload_to_use, '{}'::jsonb);
  case_to_resolve public.match_resolution_cases%rowtype;
  fixture_to_resolve public.fixtures%rowtype;
  game_to_resolve public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  policy_snapshot_to_use jsonb := '{}'::jsonb;
  policy_version_id_to_use uuid;
  previous_revision public.match_resolution_revisions%rowtype;
  revision_id_to_use uuid;
  next_revision integer;
  is_correction boolean;
  reversal_summary jsonb := '{}'::jsonb;
  current_before jsonb;
  entity_type_to_use text;
  home_score_to_use integer;
  away_score_to_use integer;
  resolution_is_final_result boolean := false;
  resolution_is_cancellation boolean := false;
  home_refund_bps_to_use integer := 0;
  away_refund_bps_to_use integer := 0;
  home_strikes_to_use integer := 0;
  away_strikes_to_use integer := 0;
  home_sr_delta_to_use integer := 0;
  away_sr_delta_to_use integer := 0;
  home_wins_delta integer := 0;
  away_wins_delta integer := 0;
  home_losses_delta integer := 0;
  away_losses_delta integer := 0;
  home_rating integer := 0;
  away_rating integer := 0;
  home_effect jsonb := '{}'::jsonb;
  away_effect jsonb := '{}'::jsonb;
  home_applied_delta integer := 0;
  away_applied_delta integer := 0;
  home_clan_id_to_use uuid;
  away_clan_id_to_use uuid;
  home_side_state text := '';
  away_side_state text := '';
  home_outcome_to_use text := 'READY';
  away_outcome_to_use text := 'READY';
  forfeit_score_to_use integer := 3;
  entire_no_show_strikes integer := 0;
  forfeit_strikes integer := 0;
  partial_strikes integer := 0;
  player_no_show_strikes integer := 0;
  attendance_before public.match_attendance_records%rowtype;
  attendance_after public.match_attendance_records%rowtype;
  attendance_state text;
  attendance_outcome text;
  attendance_is_explicit boolean := false;
  attendance_strikes integer;
  booking_to_use public.open_queue_bookings%rowtype;
  booking_side text;
  administratively_cancelled_booking_ids jsonb := '[]'::jsonb;
  solo_booking_ids_to_restore jsonb := '[]'::jsonb;
  restored_booking_ids jsonb := '[]'::jsonb;
  player_sr_lineup_profile_ids jsonb := '[]'::jsonb;
  incident_id_to_use uuid;
  home_payer_to_use uuid;
  away_payer_to_use uuid;
  home_base_amount integer := 0;
  away_base_amount integer := 0;
  home_deposit_amount integer := 0;
  away_deposit_amount integer := 0;
  home_existing_refund integer := 0;
  away_existing_refund integer := 0;
  home_deposit_forfeited boolean := false;
  away_deposit_forfeited boolean := false;
  home_target_refund integer := 0;
  away_target_refund integer := 0;
  booking_deposit_forfeited boolean;
  booking_target_refund integer;
  booking_existing_refund integer;
  refund_id_to_use uuid;
  refund_status_to_use text;
  refund_failure_exists boolean := false;
  replay_initial_player_sr_pipeline boolean := false;
  player_sr_events_exist boolean := false;
  result_to_return jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  if normalized_resolution not in (
    'RECORDED_RESULT',
    'HOME_NO_SHOW',
    'AWAY_NO_SHOW',
    'BOTH_NO_SHOW',
    'FIELD_OR_VENUE_CANCELLATION',
    'MUTUAL_CANCELLATION',
    'BOTH_AT_FAULT',
    'ADMINISTRATIVE_VOID'
  ) then
    raise exception 'Choose a valid match resolution.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Add a clear resolution reason (at least 10 characters).';
  end if;
  if jsonb_typeof(safe_payload) <> 'object' then
    raise exception 'Resolution details must be an object.';
  end if;

  select * into case_to_resolve
  from public.match_resolution_cases review_case
  where review_case.match_kind = normalized_kind
    and (
      (normalized_kind = 'CLAN' and review_case.fixture_id = match_id_to_use)
      or
      (normalized_kind = 'SOLO'
        and review_case.open_queue_game_id = match_id_to_use)
    )
  for update;
  if case_to_resolve.id is null then
    raise exception 'No Data review case not found for this match.';
  end if;
  if case_to_resolve.current_revision <> coalesce(
    expected_revision_to_use, -1
  ) then
    raise exception
      'This review changed while you were working. Refresh and try again.';
  end if;
  next_revision := case_to_resolve.current_revision + 1;
  is_correction := case_to_resolve.current_revision > 0;
  if is_correction then
    select * into previous_revision
    from public.match_resolution_revisions revision
    where revision.case_id = case_to_resolve.id
      and revision.revision = case_to_resolve.current_revision;
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where (
    normalized_kind = 'CLAN'
    and terms.match_kind = 'CLAN'
    and terms.fixture_id = match_id_to_use
  ) or (
    normalized_kind = 'SOLO'
    and terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = match_id_to_use
  )
  limit 1;
  if terms_to_use.id is null then
    begin
      terms_to_use := public.ensure_match_reliability_terms(
        normalized_kind, match_id_to_use
      );
    exception when others then
      terms_to_use := null;
    end;
  end if;
  policy_snapshot_to_use := case when terms_to_use.id is null
    then case_to_resolve.policy_snapshot
    else terms_to_use.policy_snapshot end;
  policy_version_id_to_use := terms_to_use.policy_version_id;

  forfeit_score_to_use := coalesce(
    (policy_snapshot_to_use #>> '{clan,forfeitScore}')::integer, 3
  );
  entire_no_show_strikes := coalesce(
    (policy_snapshot_to_use #>>
      '{clan,entireClanNoShowStrikes}')::integer, 0
  );
  forfeit_strikes := coalesce(
    (policy_snapshot_to_use #>> '{clan,forfeitStrikes}')::integer, 0
  );
  partial_strikes := coalesce(
    (policy_snapshot_to_use #>>
      '{clan,partialAttendanceStrikes}')::integer, 0
  );
  player_no_show_strikes := coalesce(
    (policy_snapshot_to_use #>>
      '{solo,outcomes,noShow,strikes}')::integer, 0
  );

  if normalized_kind = 'CLAN' then
    select * into fixture_to_resolve
    from public.fixtures fixture
    where fixture.id = match_id_to_use
    for update;
    if fixture_to_resolve.id is null
      or fixture_to_resolve.away_clan_id is null
    then
      raise exception 'Clan match not found or has no opponent.';
    end if;
    current_before := to_jsonb(fixture_to_resolve);
    entity_type_to_use := 'CLAN_MATCH';
    home_clan_id_to_use := fixture_to_resolve.home_clan_id;
    away_clan_id_to_use := fixture_to_resolve.away_clan_id;
    home_payer_to_use := fixture_to_resolve.home_paid_by;
    away_payer_to_use := fixture_to_resolve.away_paid_by;
    home_deposit_amount := coalesce(
      fixture_to_resolve.home_reliability_deposit_fils, 0
    );
    away_deposit_amount := coalesce(
      fixture_to_resolve.away_reliability_deposit_fils, 0
    );
    home_base_amount := greatest(0, coalesce(
      fixture_to_resolve.home_base_amount_fils,
      fixture_to_resolve.home_amount_paid_fils - home_deposit_amount,
      0
    ));
    away_base_amount := greatest(0, coalesce(
      fixture_to_resolve.away_base_amount_fils,
      fixture_to_resolve.away_amount_paid_fils - away_deposit_amount,
      0
    ));
    home_existing_refund := coalesce(
      fixture_to_resolve.home_refund_amount_fils, 0
    );
    away_existing_refund := coalesce(
      fixture_to_resolve.away_refund_amount_fils, 0
    );
    perform clan.id
    from public.clans clan
    where clan.id in (home_clan_id_to_use, away_clan_id_to_use)
    order by clan.id
    for update;
  else
    select * into game_to_resolve
    from public.open_queue_games game
    where game.id = match_id_to_use
    for update;
    if game_to_resolve.id is null then
      raise exception 'Solo match not found.';
    end if;
    current_before := to_jsonb(game_to_resolve);
    entity_type_to_use := 'SOLO_MATCH';
  end if;

  home_side_state := public.match_resolution_attendance_state(
    safe_payload, null,
    case when normalized_kind = 'CLAN' then 'HOME' else 'WHITE' end
  );
  away_side_state := public.match_resolution_attendance_state(
    safe_payload, null,
    case when normalized_kind = 'CLAN' then 'AWAY' else 'BLACK' end
  );

  case normalized_resolution
    when 'RECORDED_RESULT' then
      resolution_is_final_result := true;
      home_score_to_use := (safe_payload ->> 'home_score')::integer;
      away_score_to_use := (safe_payload ->> 'away_score')::integer;
      if home_score_to_use is null or away_score_to_use is null
        or home_score_to_use < 0 or away_score_to_use < 0
      then
        raise exception 'Enter a valid final score for both teams.';
      end if;
    when 'HOME_NO_SHOW' then
      home_side_state := coalesce(nullif(home_side_state, ''), 'NO_SHOW');
      away_side_state := coalesce(nullif(away_side_state, ''), 'PRESENT');
      home_refund_bps_to_use := 0;
      away_refund_bps_to_use := 10000;
      if normalized_kind = 'CLAN' then
        resolution_is_final_result := true;
        home_score_to_use := 0;
        away_score_to_use := forfeit_score_to_use;
      else
        resolution_is_cancellation := true;
      end if;
    when 'AWAY_NO_SHOW' then
      home_side_state := coalesce(nullif(home_side_state, ''), 'PRESENT');
      away_side_state := coalesce(nullif(away_side_state, ''), 'NO_SHOW');
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 0;
      if normalized_kind = 'CLAN' then
        resolution_is_final_result := true;
        home_score_to_use := forfeit_score_to_use;
        away_score_to_use := 0;
      else
        resolution_is_cancellation := true;
      end if;
    when 'BOTH_NO_SHOW' then
      resolution_is_cancellation := true;
      home_side_state := coalesce(nullif(home_side_state, ''), 'NO_SHOW');
      away_side_state := coalesce(nullif(away_side_state, ''), 'NO_SHOW');
    when 'FIELD_OR_VENUE_CANCELLATION' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
      home_side_state := coalesce(nullif(home_side_state, ''), 'EXCUSED');
      away_side_state := coalesce(nullif(away_side_state, ''), 'EXCUSED');
    when 'MUTUAL_CANCELLATION' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
      home_side_state := coalesce(nullif(home_side_state, ''), 'EXCUSED');
      away_side_state := coalesce(nullif(away_side_state, ''), 'EXCUSED');
    when 'BOTH_AT_FAULT' then
      resolution_is_cancellation := true;
      home_side_state := coalesce(nullif(home_side_state, ''), 'FORFEIT');
      away_side_state := coalesce(nullif(away_side_state, ''), 'FORFEIT');
    when 'ADMINISTRATIVE_VOID' then
      resolution_is_cancellation := true;
      home_refund_bps_to_use := 10000;
      away_refund_bps_to_use := 10000;
      home_side_state := coalesce(nullif(home_side_state, ''), 'EXCUSED');
      away_side_state := coalesce(nullif(away_side_state, ''), 'EXCUSED');
  end case;

  home_outcome_to_use := case home_side_state
    when 'SHORT_ROSTER' then 'PARTIAL_LATE'
    when 'FORFEIT' then 'FORFEIT'
    when 'NO_SHOW' then 'ENTIRE_CLAN_NO_SHOW'
    else 'READY' end;
  away_outcome_to_use := case away_side_state
    when 'SHORT_ROSTER' then 'PARTIAL_LATE'
    when 'FORFEIT' then 'FORFEIT'
    when 'NO_SHOW' then 'ENTIRE_CLAN_NO_SHOW'
    else 'READY' end;

  if normalized_kind = 'CLAN' then
    home_strikes_to_use := case home_outcome_to_use
      when 'PARTIAL_LATE' then partial_strikes
      when 'FORFEIT' then forfeit_strikes
      when 'ENTIRE_CLAN_NO_SHOW' then entire_no_show_strikes
      else 0 end;
    away_strikes_to_use := case away_outcome_to_use
      when 'PARTIAL_LATE' then partial_strikes
      when 'FORFEIT' then forfeit_strikes
      when 'ENTIRE_CLAN_NO_SHOW' then entire_no_show_strikes
      else 0 end;
  else
    home_strikes_to_use := case when home_side_state in ('NO_SHOW', 'FORFEIT')
      then player_no_show_strikes else 0 end;
    away_strikes_to_use := case when away_side_state in ('NO_SHOW', 'FORFEIT')
      then player_no_show_strikes else 0 end;
  end if;

  if safe_payload ->> 'home_refund_bps' is not null then
    home_refund_bps_to_use := (safe_payload ->> 'home_refund_bps')::integer;
  end if;
  if safe_payload ->> 'away_refund_bps' is not null then
    away_refund_bps_to_use := (safe_payload ->> 'away_refund_bps')::integer;
  end if;
  if safe_payload ->> 'home_strikes' is not null then
    home_strikes_to_use := (safe_payload ->> 'home_strikes')::integer;
  end if;
  if safe_payload ->> 'away_strikes' is not null then
    away_strikes_to_use := (safe_payload ->> 'away_strikes')::integer;
  end if;
  if home_refund_bps_to_use not between 0 and 10000
    or away_refund_bps_to_use not between 0 and 10000
  then
    raise exception 'Refund percentages must be between 0 and 100 percent.';
  end if;
  if home_strikes_to_use not between 0 and 20
    or away_strikes_to_use not between 0 and 20
  then
    raise exception 'Strike adjustments must be between 0 and 20.';
  end if;
  if policy_version_id_to_use is null
    and (home_strikes_to_use > 0 or away_strikes_to_use > 0)
  then
    raise exception
      'This legacy match has no applicable reliability policy. Record the result or refund, but do not invent new strikes.';
  end if;
  if normalized_kind = 'SOLO' and (
    coalesce((safe_payload ->> 'home_sr_delta')::integer, 0) <> 0
    or coalesce((safe_payload ->> 'away_sr_delta')::integer, 0) <> 0
  ) then
    raise exception
      'Solo team SR overrides are not supported. Player SR is applied only by the normal final-result ledger and is preserved on corrections.';
  end if;

  if normalized_kind = 'SOLO' and resolution_is_cancellation then
    -- Capture only bookings that this resolution actually transitions away
    -- from CONFIRMED. A later correction may restore this audited set, but
    -- never a booking the player had already cancelled. Carry the set through
    -- consecutive cancellation revisions so provenance is not lost.
    select coalesce(
      jsonb_agg(candidate.booking_id order by candidate.booking_id),
      '[]'::jsonb
    )
    into administratively_cancelled_booking_ids
    from (
      select booking.id::text as booking_id
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.status = 'CONFIRMED'
      union
      select prior_booking_id.value
      from jsonb_array_elements_text(
        case
          when previous_revision.id is not null
          then coalesce(
            previous_revision.consequence_snapshot
              -> 'administratively_cancelled_booking_ids',
            '[]'::jsonb
          )
          else '[]'::jsonb
        end
      ) prior_booking_id(value)
    ) candidate;
  elsif normalized_kind = 'SOLO'
    and resolution_is_final_result
    and previous_revision.id is not null
  then
    solo_booking_ids_to_restore := coalesce(
      previous_revision.consequence_snapshot
        -> 'administratively_cancelled_booking_ids',
      '[]'::jsonb
    );
  end if;

  insert into public.match_resolution_revisions (
    case_id, revision, resolution_type, reason, payload,
    consequence_snapshot, created_by, supersedes_revision_id
  ) values (
    case_to_resolve.id,
    next_revision,
    normalized_resolution,
    normalized_reason,
    safe_payload,
    jsonb_build_object(
      'home_score', home_score_to_use,
      'away_score', away_score_to_use,
      'home_refund_bps', home_refund_bps_to_use,
      'away_refund_bps', away_refund_bps_to_use,
      'home_strikes', home_strikes_to_use,
      'away_strikes', away_strikes_to_use,
      'home_attendance_state', home_side_state,
      'away_attendance_state', away_side_state,
      'policy_version_id', policy_version_id_to_use,
      'minimum_at_kickoff', policy_snapshot_to_use #>>
        '{clan,minimumAtKickoffWithoutForfeit}',
      'minimum_on_time', policy_snapshot_to_use #>>
        '{clan,minimumOnTimeWithoutClanStrike}',
      'player_sr_policy', 'PRESERVE_APPLIED_SR',
      'refund_destination', 'FIELD_WALLET',
      'refunds_continue_during_disputes', true,
      'administratively_cancelled_booking_ids',
        administratively_cancelled_booking_ids
    ),
    actor_admin_id,
    previous_revision.id
  ) returning id into revision_id_to_use;

  if is_correction then
    reversal_summary := public.reverse_previous_match_resolution_effects(
      case_to_resolve.id,
      revision_id_to_use,
      actor_admin_id,
      normalized_reason
    );
  end if;

  -- The existing immutable-result trigger explicitly recognizes this audited,
  -- transaction-local setting. Player SR remains append-only and is never
  -- applied twice by a correction.
  perform set_config('field.admin_score_override', 'on', true);
  perform set_config('field.match_resolution_control_plane', 'on', true);

  if normalized_kind = 'CLAN' then
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'CLAN_FIXTURE'
        and event.source_id = match_id_to_use
    ) into player_sr_events_exist;
    if resolution_is_final_result
      and (
        fixture_to_resolve.home_score is distinct from home_score_to_use
        or fixture_to_resolve.away_score is distinct from away_score_to_use
      )
    then
      if player_sr_events_exist then
        perform public.preserve_player_sr_for_resolution_score(
          'CLAN', match_id_to_use, home_score_to_use, away_score_to_use
        );
      end if;
    end if;
    -- A no-show is already represented as FINAL. Correcting that finding to
    -- a played result must cross the normal Player SR trigger boundary even
    -- when the authoritative score happens to equal the prior forfeit score.
    if normalized_resolution = 'RECORDED_RESULT'
      and fixture_to_resolve.status = 'FINAL'
      and not player_sr_events_exist
    then
      replay_initial_player_sr_pipeline := true;
    end if;
    select skill_rating into home_rating
    from public.clans where id = home_clan_id_to_use;
    select skill_rating into away_rating
    from public.clans where id = away_clan_id_to_use;
    if normalized_resolution in (
      'RECORDED_RESULT', 'HOME_NO_SHOW', 'AWAY_NO_SHOW'
    ) then
      select delta.home_change, delta.away_change
      into home_sr_delta_to_use, away_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        home_rating, away_rating, home_score_to_use, away_score_to_use
      ) delta;
    elsif normalized_resolution in ('BOTH_NO_SHOW', 'BOTH_AT_FAULT') then
      select delta.home_change into home_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        home_rating, away_rating, 0, forfeit_score_to_use
      ) delta;
      select delta.home_change into away_sr_delta_to_use
      from public.calculate_fixture_sr_delta(
        away_rating, home_rating, 0, forfeit_score_to_use
      ) delta;
    end if;
    if safe_payload ->> 'home_sr_delta' is not null then
      home_sr_delta_to_use := (safe_payload ->> 'home_sr_delta')::integer;
    end if;
    if safe_payload ->> 'away_sr_delta' is not null then
      away_sr_delta_to_use := (safe_payload ->> 'away_sr_delta')::integer;
    end if;
    if resolution_is_final_result then
      home_wins_delta := case when home_score_to_use > away_score_to_use
        then 1 else 0 end;
      away_wins_delta := case when away_score_to_use > home_score_to_use
        then 1 else 0 end;
      home_losses_delta := case when home_score_to_use < away_score_to_use
        then 1 else 0 end;
      away_losses_delta := case when away_score_to_use < home_score_to_use
        then 1 else 0 end;
    end if;

    home_effect := public.apply_match_resolution_clan_effect(
      case_to_resolve.id, revision_id_to_use,
      home_clan_id_to_use, 'HOME',
      home_sr_delta_to_use, home_wins_delta, home_losses_delta,
      case when is_correction then 'CORRECTION' else 'RESOLUTION' end
    );
    away_effect := public.apply_match_resolution_clan_effect(
      case_to_resolve.id, revision_id_to_use,
      away_clan_id_to_use, 'AWAY',
      away_sr_delta_to_use, away_wins_delta, away_losses_delta,
      case when is_correction then 'CORRECTION' else 'RESOLUTION' end
    );
    home_applied_delta := coalesce(
      (home_effect ->> 'rating_delta')::integer, 0
    );
    away_applied_delta := coalesce(
      (away_effect ->> 'rating_delta')::integer, 0
    );

    if terms_to_use.id is not null then
      perform public.initialize_fixture_reliability_roster(match_id_to_use);
      perform public.ensure_match_attendance_records('CLAN', match_id_to_use);
      for attendance_before in
        select attendance.*
        from public.match_attendance_records attendance
        where attendance.fixture_id = match_id_to_use
          and (
            attendance.expected_for_match
            or public.match_resolution_has_explicit_player_attendance(
              safe_payload, attendance.profile_id
            )
          )
        order by attendance.id
        for update
      loop
        -- A player cancellation is a separate, already-audited action. Team
        -- resolution must not rewrite it into presence or a no-show.
        if attendance_before.outcome in (
          'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
        ) then
          continue;
        end if;
        attendance_is_explicit :=
          public.match_resolution_has_explicit_player_attendance(
            safe_payload, attendance_before.profile_id
          );
        attendance_state := public.match_resolution_attendance_state(
          safe_payload, attendance_before.profile_id, attendance_before.side
        );
        if attendance_state = '' then
          attendance_state := case
            when attendance_before.side = 'HOME'
              and home_side_state = 'NO_SHOW' then 'NO_SHOW'
            when attendance_before.side = 'AWAY'
              and away_side_state = 'NO_SHOW' then 'NO_SHOW'
            when attendance_before.checked_in_at is not null
              and attendance_before.checked_in_at <=
                attendance_before.check_in_deadline_at then 'ON_TIME'
            when attendance_before.checked_in_at is not null then 'LATE'
            else 'EXCUSED'
          end;
        end if;
        attendance_outcome := case
          when attendance_state = 'NO_SHOW' then 'NO_SHOW'
          when attendance_state in ('PRESENT', 'READY', 'ON_TIME') then 'ON_TIME'
          when attendance_state = 'LATE' then 'LATE'
          else 'EXCUSED'
        end;
        update public.match_attendance_records
        set outcome = attendance_outcome,
          strike_delta = 0,
          finalized_at = clock_timestamp(),
          appeal_due_at = clock_timestamp() + interval '24 hours',
          consequence_snapshot = consequence_snapshot || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'case_id', case_to_resolve.id,
            'revision_id', revision_id_to_use,
            'team_level_accountability', true,
            'explicit_player_attendance', attendance_is_explicit
          )
        where id = attendance_before.id
        returning * into attendance_after;
        insert into public.attendance_events (
          attendance_id, event_type, actor_referee_id, event_at,
          detail, idempotency_key
        ) values (
          attendance_before.id,
          'ADMIN_CORRECTION',
          actor_admin_id,
          clock_timestamp(),
          jsonb_build_object(
            'case_id', case_to_resolve.id,
            'revision_id', revision_id_to_use,
            'reason', normalized_reason,
            'before', jsonb_build_object(
              'outcome', attendance_before.outcome,
              'strike_delta', attendance_before.strike_delta,
              'finalized_at', attendance_before.finalized_at
            ),
            'after', jsonb_build_object(
              'outcome', attendance_after.outcome,
              'strike_delta', attendance_after.strike_delta,
              'finalized_at', attendance_after.finalized_at
            )
          ),
          'match-resolution:' || revision_id_to_use::text ||
            ':attendance:' || attendance_before.id::text
        ) on conflict (idempotency_key) do nothing;
      end loop;
    end if;

    if home_strikes_to_use > 0 then
      incident_id_to_use := public.record_match_resolution_incident(
        case_to_resolve.id, revision_id_to_use, 'CLAN',
        null, home_clan_id_to_use, null, 'CLAN', match_id_to_use,
        case when normalized_resolution = 'BOTH_AT_FAULT'
          then 'BOTH_AT_FAULT' else home_outcome_to_use end,
        home_strikes_to_use, policy_version_id_to_use,
        policy_snapshot_to_use, actor_admin_id, normalized_reason
      );
    end if;
    if away_strikes_to_use > 0 then
      incident_id_to_use := public.record_match_resolution_incident(
        case_to_resolve.id, revision_id_to_use, 'CLAN',
        null, away_clan_id_to_use, null, 'CLAN', match_id_to_use,
        case when normalized_resolution = 'BOTH_AT_FAULT'
          then 'BOTH_AT_FAULT' else away_outcome_to_use end,
        away_strikes_to_use, policy_version_id_to_use,
        policy_snapshot_to_use, actor_admin_id, normalized_reason
      );
    end if;

    if resolution_is_final_result
      and normalized_resolution = 'RECORDED_RESULT'
      and not player_sr_events_exist
    then
      -- A prior no-play/no-show revision deliberately cleared the lineup.
      -- Rebuild it only from a referee check-in or an explicit per-player
      -- attendance entry in this revision; a side-level PRESENT value alone
      -- is not evidence that every roster member played.
      perform public.snapshot_fixture_player_appearances(match_id_to_use);
      insert into public.player_ratings (profile_id)
      select attendance.profile_id
      from public.match_attendance_records attendance
      where attendance.fixture_id = match_id_to_use
        and attendance.clan_id is not null
        and attendance.outcome in ('ON_TIME', 'LATE')
        and (
          attendance.checked_in_at is not null
          or (
            attendance.consequence_snapshot
              ->> 'source' = 'ADMIN_MATCH_RESOLUTION'
            and attendance.consequence_snapshot
              ->> 'case_id' = case_to_resolve.id::text
            and attendance.consequence_snapshot
              ->> 'revision_id' = revision_id_to_use::text
            and coalesce((
              attendance.consequence_snapshot
                ->> 'explicit_player_attendance'
            )::boolean, false)
          )
        )
      on conflict (profile_id) do nothing;
      insert into public.fixture_player_appearances (
        fixture_id, profile_id, clan_id, side, played, rating_at_start
      )
      select
        match_id_to_use,
        attendance.profile_id,
        attendance.clan_id,
        attendance.side,
        false,
        rating.skill_rating
      from public.match_attendance_records attendance
      join public.player_ratings rating
        on rating.profile_id = attendance.profile_id
      where attendance.fixture_id = match_id_to_use
        and attendance.clan_id is not null
        and attendance.outcome in ('ON_TIME', 'LATE')
        and (
          attendance.checked_in_at is not null
          or (
            attendance.consequence_snapshot
              ->> 'source' = 'ADMIN_MATCH_RESOLUTION'
            and attendance.consequence_snapshot
              ->> 'case_id' = case_to_resolve.id::text
            and attendance.consequence_snapshot
              ->> 'revision_id' = revision_id_to_use::text
            and coalesce((
              attendance.consequence_snapshot
                ->> 'explicit_player_attendance'
            )::boolean, false)
          )
        )
      on conflict (fixture_id, profile_id) do nothing;
      with updated_lineup as (
        update public.fixture_player_appearances appearance
        set played = exists (
            select 1
            from public.match_attendance_records attendance
            where attendance.fixture_id = match_id_to_use
              and attendance.profile_id = appearance.profile_id
              and attendance.outcome in ('ON_TIME', 'LATE')
              and (
                attendance.checked_in_at is not null
                or (
                  attendance.consequence_snapshot
                    ->> 'source' = 'ADMIN_MATCH_RESOLUTION'
                  and attendance.consequence_snapshot
                    ->> 'case_id' = case_to_resolve.id::text
                  and attendance.consequence_snapshot
                    ->> 'revision_id' = revision_id_to_use::text
                  and coalesce((
                    attendance.consequence_snapshot
                      ->> 'explicit_player_attendance'
                  )::boolean, false)
                )
              )
          ) or (
            terms_to_use.id is null
            and public.match_resolution_has_explicit_player_attendance(
              safe_payload, appearance.profile_id
            )
            and public.match_resolution_attendance_state(
              safe_payload, appearance.profile_id, appearance.side
            ) in ('PRESENT', 'READY', 'ON_TIME', 'LATE')
          ),
          rating_change = null
        where appearance.fixture_id = match_id_to_use
        returning appearance.profile_id, appearance.played
      )
      select coalesce(
        jsonb_agg(
          updated_lineup.profile_id::text
          order by updated_lineup.profile_id
        ) filter (where updated_lineup.played),
        '[]'::jsonb
      )
      into player_sr_lineup_profile_ids
      from updated_lineup;
      if not exists (
        select 1
        from public.fixture_player_appearances appearance
        where appearance.fixture_id = match_id_to_use
          and appearance.played
          and appearance.side = 'HOME'
      ) or not exists (
        select 1
        from public.fixture_player_appearances appearance
        where appearance.fixture_id = match_id_to_use
          and appearance.played
          and appearance.side = 'AWAY'
      ) then
        raise exception
          'Confirm at least one explicitly attended player for each clan before recording a result.';
      end if;
    elsif not resolution_is_final_result then
      update public.fixture_player_appearances
      set played = false, rating_change = null
      where fixture_id = match_id_to_use;
    elsif normalized_resolution in ('HOME_NO_SHOW', 'AWAY_NO_SHOW') then
      update public.fixture_player_appearances
      set played = false, rating_change = null
      where fixture_id = match_id_to_use;
    end if;

    if resolution_is_final_result then
      if replay_initial_player_sr_pipeline then
        -- Legacy FINAL rows with a missing score never crossed the normal
        -- non-FINAL -> FINAL trigger boundary. CANCELLED is excluded from the
        -- active-slot uniqueness index, so use it as a transaction-local
        -- neutral boundary after audited attendance has been written.
        update public.fixtures
        set status = 'CANCELLED',
          home_score = null,
          away_score = null,
          winner_clan_id = null,
          cancellation_code = 'ADMIN_DECISION',
          cancellation_reason =
            'Temporary boundary for audited match-result correction.',
          cancelled_at = clock_timestamp(),
          cancelled_by = actor_admin_id,
          cancellation_context = coalesce(
            cancellation_context, '{}'::jsonb
          ) || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use,
            'temporary_player_sr_replay_boundary', true
          )
        where id = match_id_to_use and status = 'FINAL';
      end if;
      update public.fixtures
      set status = 'FINAL',
        home_score = home_score_to_use,
        away_score = away_score_to_use,
        winner_clan_id = case
          when home_score_to_use > away_score_to_use then home_clan_id
          when away_score_to_use > home_score_to_use then away_clan_id
          else null end,
        home_sr_change = home_applied_delta,
        away_sr_change = away_applied_delta,
        cancellation_code = null,
        cancellation_reason = null,
        cancelled_at = null,
        cancelled_by = null,
        cancellation_context = coalesce(
          cancellation_context, '{}'::jsonb
        ) || jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'player_sr_policy', 'PRESERVE_APPLIED_SR',
          'reliability_forfeit_without_play',
            normalized_resolution in ('HOME_NO_SHOW', 'AWAY_NO_SHOW')
        )
      where id = match_id_to_use;
    else
      update public.fixtures
      set status = 'CANCELLED',
        home_score = null,
        away_score = null,
        winner_clan_id = null,
        home_sr_change = home_applied_delta,
        away_sr_change = away_applied_delta,
        cancellation_code = case
          when normalized_resolution = 'FIELD_OR_VENUE_CANCELLATION'
            then 'WEATHER_OR_VENUE'
          when normalized_resolution = 'MUTUAL_CANCELLATION'
            then 'CLAN_CANCELLED'
          else 'ADMIN_DECISION' end,
        cancellation_reason = normalized_reason,
        cancelled_at = clock_timestamp(),
        cancelled_by = actor_admin_id,
        cancellation_context = jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'resolution_type', normalized_resolution,
          'player_sr_policy', 'PRESERVE_APPLIED_SR'
        )
      where id = match_id_to_use;
    end if;
    update public.fixture_clock_states
    set accumulated_seconds = least(
        10800,
        accumulated_seconds + case
          when status = 'RUNNING' and started_at is not null
            then greatest(
              0, extract(epoch from (
                clock_timestamp() - started_at
              ))::integer
            )
          else 0 end
      ),
      status = 'ENDED',
      started_at = null
    where fixture_id = match_id_to_use;
    update public.fixture_blue_cards
    set status = 'CLEARED'
    where fixture_id = match_id_to_use and status = 'ACTIVE';

    home_deposit_forfeited :=
      normalized_resolution in ('BOTH_NO_SHOW', 'BOTH_AT_FAULT')
      or exists (
        select 1
        from jsonb_array_elements_text(coalesce(
          policy_snapshot_to_use #>
            '{clan,reliabilityDeposit,forfeitOutcomes}',
          '[]'::jsonb
        )) forfeited(value)
        where forfeited.value = home_outcome_to_use
      );
    away_deposit_forfeited :=
      normalized_resolution in ('BOTH_NO_SHOW', 'BOTH_AT_FAULT')
      or exists (
        select 1
        from jsonb_array_elements_text(coalesce(
          policy_snapshot_to_use #>
            '{clan,reliabilityDeposit,forfeitOutcomes}',
          '[]'::jsonb
        )) forfeited(value)
        where forfeited.value = away_outcome_to_use
      );
    if normalized_resolution in (
      'FIELD_OR_VENUE_CANCELLATION',
      'MUTUAL_CANCELLATION',
      'ADMINISTRATIVE_VOID'
    ) then
      home_deposit_forfeited := false;
      away_deposit_forfeited := false;
    end if;
    if fixture_to_resolve.home_deposit_status = 'RETURNED' then
      home_deposit_forfeited := false;
    end if;
    if fixture_to_resolve.away_deposit_status = 'RETURNED' then
      away_deposit_forfeited := false;
    end if;
    home_target_refund := (
      home_base_amount::bigint * home_refund_bps_to_use / 10000
    )::integer + case when home_deposit_forfeited
      then 0 else home_deposit_amount end;
    away_target_refund := (
      away_base_amount::bigint * away_refund_bps_to_use / 10000
    )::integer + case when away_deposit_forfeited
      then 0 else away_deposit_amount end;

    refund_id_to_use := public.record_match_resolution_refund(
      case_to_resolve.id, revision_id_to_use,
      home_payer_to_use, home_clan_id_to_use, 'HOME',
      home_target_refund, home_existing_refund, home_refund_bps_to_use,
      policy_version_id_to_use, null,
      'Clan match refund after an administrative match resolution.'
    );
    select status into refund_status_to_use
    from public.match_resolution_refunds where id = refund_id_to_use;
    update public.fixtures
    set home_refund_bps = greatest(home_refund_bps, home_refund_bps_to_use),
      home_refund_amount_fils = case when refund_status_to_use = 'COMPLETED'
        then greatest(home_refund_amount_fils, home_target_refund)
        else home_refund_amount_fils end,
      home_deposit_status = case
        when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when home_deposit_status = 'RETURNED' then 'RETURNED'
        when home_deposit_forfeited then 'FORFEITED'
        when refund_status_to_use = 'COMPLETED' then 'RETURNED'
        else home_deposit_status end
    where id = match_id_to_use;

    refund_id_to_use := public.record_match_resolution_refund(
      case_to_resolve.id, revision_id_to_use,
      away_payer_to_use, away_clan_id_to_use, 'AWAY',
      away_target_refund, away_existing_refund, away_refund_bps_to_use,
      policy_version_id_to_use, null,
      'Clan match refund after an administrative match resolution.'
    );
    select status into refund_status_to_use
    from public.match_resolution_refunds where id = refund_id_to_use;
    update public.fixtures
    set away_refund_bps = greatest(away_refund_bps, away_refund_bps_to_use),
      away_refund_amount_fils = case when refund_status_to_use = 'COMPLETED'
        then greatest(away_refund_amount_fils, away_target_refund)
        else away_refund_amount_fils end,
      away_deposit_status = case
        when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when away_deposit_status = 'RETURNED' then 'RETURNED'
        when away_deposit_forfeited then 'FORFEITED'
        when refund_status_to_use = 'COMPLETED' then 'RETURNED'
        else away_deposit_status end
    where id = match_id_to_use;
  else
    select exists (
      select 1
      from public.player_rating_events event
      where event.source_type = 'OPEN_QUEUE'
        and event.source_id = match_id_to_use
    ) into player_sr_events_exist;
    if resolution_is_final_result
      and (
        game_to_resolve.white_score is distinct from home_score_to_use
        or game_to_resolve.black_score is distinct from away_score_to_use
      )
    then
      if player_sr_events_exist then
        perform public.preserve_player_sr_for_resolution_score(
          'SOLO', match_id_to_use, home_score_to_use, away_score_to_use
        );
      end if;
    end if;
    if normalized_resolution = 'RECORDED_RESULT'
      and game_to_resolve.status = 'FINAL'
      and not player_sr_events_exist
    then
      replay_initial_player_sr_pipeline := true;
    end if;
    if terms_to_use.id is not null then
      perform public.ensure_match_attendance_records('SOLO', match_id_to_use);
      for attendance_before in
        select attendance.*
        from public.match_attendance_records attendance
        where attendance.open_queue_game_id = match_id_to_use
          and attendance.expected_for_match
        order by attendance.id
        for update
      loop
        -- Never convert a player's own cancellation into an admin-authored
        -- presence/no-show finding, and never make that booking restorable.
        if attendance_before.outcome in (
          'CANCELLED_EARLY', 'CANCELLED_LATE', 'CANCELLED_VERY_LATE'
        ) then
          continue;
        end if;
        attendance_is_explicit :=
          public.match_resolution_has_explicit_player_attendance(
            safe_payload, attendance_before.profile_id
          );
        attendance_state := public.match_resolution_attendance_state(
          safe_payload, attendance_before.profile_id, attendance_before.side
        );
        if attendance_state = '' then
          attendance_state := case
            when attendance_before.side = 'WHITE'
              and home_side_state in ('NO_SHOW', 'FORFEIT') then 'NO_SHOW'
            when attendance_before.side = 'BLACK'
              and away_side_state in ('NO_SHOW', 'FORFEIT') then 'NO_SHOW'
            when attendance_before.checked_in_at is not null
              and attendance_before.checked_in_at <=
                attendance_before.check_in_deadline_at then 'ON_TIME'
            when attendance_before.checked_in_at is not null then 'LATE'
            else 'EXCUSED'
          end;
        end if;
        attendance_outcome := case
          when attendance_state = 'NO_SHOW' then 'NO_SHOW'
          when attendance_state in ('PRESENT', 'READY', 'ON_TIME') then 'ON_TIME'
          when attendance_state = 'LATE' then 'LATE'
          else 'EXCUSED'
        end;
        attendance_strikes := case
          when attendance_outcome <> 'NO_SHOW' then 0
          when attendance_before.side = 'WHITE' then home_strikes_to_use
          else away_strikes_to_use end;
        update public.match_attendance_records
        set outcome = attendance_outcome,
          strike_delta = attendance_strikes,
          finalized_at = clock_timestamp(),
          appeal_due_at = clock_timestamp() + interval '24 hours',
          consequence_snapshot = consequence_snapshot || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'case_id', case_to_resolve.id,
            'revision_id', revision_id_to_use,
            'explicit_player_attendance', attendance_is_explicit
          )
        where id = attendance_before.id
        returning * into attendance_after;
        insert into public.attendance_events (
          attendance_id, event_type, actor_referee_id, event_at,
          detail, idempotency_key
        ) values (
          attendance_before.id,
          'ADMIN_CORRECTION',
          actor_admin_id,
          clock_timestamp(),
          jsonb_build_object(
            'case_id', case_to_resolve.id,
            'revision_id', revision_id_to_use,
            'reason', normalized_reason,
            'before', jsonb_build_object(
              'outcome', attendance_before.outcome,
              'strike_delta', attendance_before.strike_delta,
              'finalized_at', attendance_before.finalized_at
            ),
            'after', jsonb_build_object(
              'outcome', attendance_after.outcome,
              'strike_delta', attendance_after.strike_delta,
              'finalized_at', attendance_after.finalized_at
            )
          ),
          'match-resolution:' || revision_id_to_use::text ||
            ':attendance:' || attendance_before.id::text
        ) on conflict (idempotency_key) do nothing;
        if attendance_strikes > 0 then
          incident_id_to_use := public.record_match_resolution_incident(
            case_to_resolve.id, revision_id_to_use, 'PLAYER',
            attendance_before.profile_id, null, attendance_before.booking_id,
            'SOLO', match_id_to_use,
            case when normalized_resolution = 'BOTH_AT_FAULT'
              then 'BOTH_AT_FAULT' else 'NO_SHOW' end,
            attendance_strikes, policy_version_id_to_use,
            policy_snapshot_to_use, actor_admin_id, normalized_reason
          );
        end if;
      end loop;
    end if;

    if resolution_is_final_result then
      -- Restore booking status/team only for rows captured as CONFIRMED by the
      -- superseded admin cancellation. The played lineup below is narrower:
      -- it requires immutable Player SR, a real check-in, or this revision's
      -- explicit per-player finding. User-cancelled bookings are absent from
      -- the provenance list and cannot be resurrected.
      with restored as (
        update public.open_queue_bookings booking
        set status = 'CONFIRMED',
          team = coalesce((
            select event.side
            from public.player_rating_events event
            where event.source_type = 'OPEN_QUEUE'
              and event.source_id = match_id_to_use
              and event.profile_id = booking.profile_id
            limit 1
          ), booking.team, (
            select attendance.side
            from public.match_attendance_records attendance
            where attendance.booking_id = booking.id
            limit 1
          )),
          played = false,
          cancelled_at = null,
          rating_at_match_start = coalesce(
            booking.rating_at_match_start,
            (
              select event.rating_at_match_start
              from public.player_rating_events event
              where event.source_type = 'OPEN_QUEUE'
                and event.source_id = match_id_to_use
                and event.profile_id = booking.profile_id
              limit 1
            )
          )
        where booking.game_id = match_id_to_use
          and booking.status = 'CANCELLED'
          and solo_booking_ids_to_restore ? booking.id::text
          and not exists (
            select 1
            from public.match_attendance_records attendance
            where attendance.booking_id = booking.id
              and attendance.outcome in (
                'CANCELLED_EARLY',
                'CANCELLED_LATE',
                'CANCELLED_VERY_LATE'
              )
          )
          and coalesce(
            (
              select event.side
              from public.player_rating_events event
              where event.source_type = 'OPEN_QUEUE'
                and event.source_id = match_id_to_use
                and event.profile_id = booking.profile_id
              limit 1
            ),
            booking.team,
            (
              select attendance.side
              from public.match_attendance_records attendance
              where attendance.booking_id = booking.id
              limit 1
            )
          ) is not null
        returning booking.id
      )
      select coalesce(
        jsonb_agg(restored.id::text order by restored.id),
        '[]'::jsonb
      )
      into restored_booking_ids
      from restored;

      if player_sr_events_exist then
        -- Existing Player SR is immutable. Restore the exact rated lineup
        -- instead of deriving a different one from corrected attendance.
        update public.open_queue_bookings booking
        set played = exists (
            select 1
            from public.player_rating_events event
            where event.source_type = 'OPEN_QUEUE'
              and event.source_id = match_id_to_use
              and event.profile_id = booking.profile_id
          ),
          team = coalesce((
            select event.side
            from public.player_rating_events event
            where event.source_type = 'OPEN_QUEUE'
              and event.source_id = match_id_to_use
              and event.profile_id = booking.profile_id
            limit 1
          ), booking.team)
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED';
      else
        update public.open_queue_bookings booking
        set played = exists (
          select 1 from public.match_attendance_records attendance
          where attendance.booking_id = booking.id
            and attendance.outcome in ('ON_TIME', 'LATE')
            and (
              attendance.checked_in_at is not null
              or (
                attendance.consequence_snapshot
                  ->> 'source' = 'ADMIN_MATCH_RESOLUTION'
                and attendance.consequence_snapshot
                  ->> 'case_id' = case_to_resolve.id::text
                and attendance.consequence_snapshot
                  ->> 'revision_id' = revision_id_to_use::text
                and coalesce((
                  attendance.consequence_snapshot
                    ->> 'explicit_player_attendance'
                )::boolean, false)
              )
            )
        ) or (
          terms_to_use.id is null
          and booking.team in ('WHITE', 'BLACK')
          and public.match_resolution_has_explicit_player_attendance(
            safe_payload, booking.profile_id
          )
          and public.match_resolution_attendance_state(
            safe_payload, booking.profile_id, booking.team
          ) in ('PRESENT', 'READY', 'ON_TIME', 'LATE')
        )
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED';
      end if;
      update public.open_queue_bookings booking
      set rating_at_match_start = coalesce(
        booking.rating_at_match_start,
        booking.player_rating_at_booking,
        rating.skill_rating
      )
      from public.player_ratings rating
      where booking.game_id = match_id_to_use
        and booking.profile_id = rating.profile_id
        and booking.status = 'CONFIRMED'
        and booking.played;
      select coalesce(
        jsonb_agg(booking.profile_id::text order by booking.profile_id),
        '[]'::jsonb
      )
      into player_sr_lineup_profile_ids
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and booking.status = 'CONFIRMED'
        and booking.played;
      if not exists (
        select 1 from public.open_queue_bookings booking
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED'
          and booking.played and booking.team = 'WHITE'
      ) or not exists (
        select 1 from public.open_queue_bookings booking
        where booking.game_id = match_id_to_use
          and booking.status = 'CONFIRMED'
          and booking.played and booking.team = 'BLACK'
      ) then
        raise exception
          'Confirm at least one player who took part for each solo team before recording a result.';
      end if;
      if replay_initial_player_sr_pipeline then
        update public.open_queue_games
        -- CANCELLED is excluded from the active schedule uniqueness rules and
        -- is used only as a transaction-local Player SR trigger boundary.
        set status = 'CANCELLED',
          white_score = null,
          black_score = null,
          cancellation_code = 'ADMIN_DECISION',
          cancellation_reason =
            'Temporary boundary for audited match-result correction.',
          cancelled_at = clock_timestamp(),
          cancelled_by = actor_admin_id,
          cancellation_context = coalesce(
            cancellation_context, '{}'::jsonb
          ) || jsonb_build_object(
            'source', 'ADMIN_MATCH_RESOLUTION',
            'match_resolution_case_id', case_to_resolve.id,
            'match_resolution_revision_id', revision_id_to_use,
            'temporary_player_sr_replay_boundary', true
          )
        where id = match_id_to_use and status = 'FINAL';
      end if;
      update public.open_queue_games
      set status = 'FINAL',
        white_score = home_score_to_use,
        black_score = away_score_to_use,
        cancellation_code = null,
        cancellation_reason = null,
        cancelled_at = null,
        cancelled_by = null,
        cancellation_context = coalesce(
          cancellation_context, '{}'::jsonb
        ) || jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'player_sr_policy', 'PRESERVE_APPLIED_SR'
        )
      where id = match_id_to_use;
    else
      update public.open_queue_games
      set status = 'CANCELLED',
        white_score = null,
        black_score = null,
        cancellation_code = case
          when normalized_resolution = 'FIELD_OR_VENUE_CANCELLATION'
            then 'WEATHER_OR_VENUE'
          else 'ADMIN_DECISION' end,
        cancellation_reason = normalized_reason,
        cancelled_at = clock_timestamp(),
        cancelled_by = actor_admin_id,
        cancellation_context = jsonb_build_object(
          'source', 'ADMIN_MATCH_RESOLUTION',
          'match_resolution_case_id', case_to_resolve.id,
          'match_resolution_revision_id', revision_id_to_use,
          'resolution_type', normalized_resolution,
          'player_sr_policy', 'PRESERVE_APPLIED_SR'
        )
      where id = match_id_to_use;
    end if;
    update public.open_queue_clock_states
    set accumulated_seconds = least(
        10800,
        accumulated_seconds + case
          when status = 'RUNNING' and started_at is not null
            then greatest(
              0, extract(epoch from (
                clock_timestamp() - started_at
              ))::integer
            )
          else 0 end
      ),
      status = 'ENDED',
      started_at = null
    where game_id = match_id_to_use;
    update public.open_queue_blue_cards
    set status = 'CLEARED'
    where game_id = match_id_to_use and status = 'ACTIVE';

    for booking_to_use in
      select booking.*
      from public.open_queue_bookings booking
      where booking.game_id = match_id_to_use
        and (
          booking.status = 'CONFIRMED'
          or exists (
            select 1 from public.match_attendance_records attendance
            where attendance.booking_id = booking.id
              and attendance.expected_for_match
          )
        )
      order by booking.id
      for update
    loop
      select attendance.side into booking_side
      from public.match_attendance_records attendance
      where attendance.booking_id = booking_to_use.id
      limit 1;
      booking_side := coalesce(
        booking_side, booking_to_use.team, 'WHITE'
      );
      booking_existing_refund := coalesce(
        booking_to_use.refund_amount_fils, 0
      );
      booking_deposit_forfeited := case
        when normalized_resolution in (
          'FIELD_OR_VENUE_CANCELLATION',
          'MUTUAL_CANCELLATION',
          'ADMINISTRATIVE_VOID'
        ) then false
        when normalized_resolution in ('BOTH_NO_SHOW', 'BOTH_AT_FAULT')
          then true
        when booking_side = 'WHITE'
          then home_side_state in ('NO_SHOW', 'FORFEIT')
        else away_side_state in ('NO_SHOW', 'FORFEIT') end;
      if booking_to_use.reliability_deposit_status in (
        'RETURNED', 'REFUNDED'
      ) then
        booking_deposit_forfeited := false;
      end if;
      booking_target_refund := (
        coalesce(
          booking_to_use.base_amount_fils,
          booking_to_use.amount_paid_fils -
            booking_to_use.reliability_deposit_fils,
          0
        )::bigint *
        case when booking_side = 'WHITE'
          then home_refund_bps_to_use else away_refund_bps_to_use end /
        10000
      )::integer + case when booking_deposit_forfeited then 0
        else coalesce(booking_to_use.reliability_deposit_fils, 0) end;
      refund_id_to_use := public.record_match_resolution_refund(
        case_to_resolve.id, revision_id_to_use,
        booking_to_use.profile_id, null, booking_side,
        booking_target_refund, booking_existing_refund,
        case when booking_side = 'WHITE'
          then home_refund_bps_to_use else away_refund_bps_to_use end,
        policy_version_id_to_use, booking_to_use.id,
        'Solo match refund after an administrative match resolution.'
      );
      select status into refund_status_to_use
      from public.match_resolution_refunds where id = refund_id_to_use;
      update public.open_queue_bookings
      set status = case when resolution_is_cancellation
          then 'CANCELLED' else status end,
        played = case when resolution_is_cancellation
            and booking_to_use.status = 'CONFIRMED' then false else played end,
        cancelled_at = case when resolution_is_cancellation
            and booking_to_use.status = 'CONFIRMED'
          then coalesce(cancelled_at, clock_timestamp()) else cancelled_at end,
        refund_bps = greatest(
          coalesce(refund_bps, 0),
          case when booking_side = 'WHITE'
            then home_refund_bps_to_use else away_refund_bps_to_use end
        ),
        -- refund_percent is a legacy coarse field constrained to 0/50/100;
        -- refund_bps remains the exact financial percentage.
        refund_percent = case
          when greatest(
            coalesce(refund_bps, 0),
            case when booking_side = 'WHITE'
              then home_refund_bps_to_use else away_refund_bps_to_use end
          ) >= 10000 then 100
          when greatest(
            coalesce(refund_bps, 0),
            case when booking_side = 'WHITE'
              then home_refund_bps_to_use else away_refund_bps_to_use end
          ) >= 5000 then 50
          else 0 end,
        refund_amount_fils = case when refund_status_to_use = 'COMPLETED'
          then greatest(
            coalesce(refund_amount_fils, 0), booking_target_refund
          )
          else coalesce(refund_amount_fils, 0) end,
        refund_status = case
          when refund_status_to_use = 'FAILED' then 'FAILED'
          when booking_target_refund > 0 then 'PROCESSED'
          else 'NOT_DUE' end,
        payment_status = case
          when refund_status_to_use = 'FAILED' then payment_status
          when booking_to_use.amount_paid_fils > 0
            and greatest(
              booking_existing_refund,
              case when refund_status_to_use = 'COMPLETED'
                then booking_target_refund else booking_existing_refund end
            ) >= booking_to_use.amount_paid_fils then 'REFUNDED'
          when greatest(
            booking_existing_refund,
            case when refund_status_to_use = 'COMPLETED'
              then booking_target_refund else booking_existing_refund end
          ) > 0 then 'PARTIALLY_REFUNDED'
          else 'NO_REFUND' end,
        reliability_deposit_status = case
          when coalesce(reliability_deposit_fils, 0) <= 0
            then reliability_deposit_status
          when reliability_deposit_status in ('RETURNED', 'REFUNDED')
            then reliability_deposit_status
          when booking_deposit_forfeited then 'FORFEITED'
          when refund_status_to_use = 'COMPLETED' then 'RETURNED'
          else reliability_deposit_status end
      where id = booking_to_use.id;
    end loop;
  end if;

  select exists (
    select 1 from public.match_resolution_refunds refund
    where refund.revision_id = revision_id_to_use
      and refund.status = 'FAILED'
  ) into refund_failure_exists;

  update public.match_resolution_revisions
  set consequence_snapshot = consequence_snapshot || jsonb_build_object(
    'home_sr_delta_applied', home_applied_delta,
    'away_sr_delta_applied', away_applied_delta,
    'home_wins_delta', home_wins_delta,
    'away_wins_delta', away_wins_delta,
    'home_losses_delta', home_losses_delta,
    'away_losses_delta', away_losses_delta,
    'home_refund_target_fils', case when normalized_kind = 'CLAN'
      then home_target_refund end,
    'away_refund_target_fils', case when normalized_kind = 'CLAN'
      then away_target_refund end,
    'home_deposit_forfeited', case when normalized_kind = 'CLAN'
      then home_deposit_forfeited end,
    'away_deposit_forfeited', case when normalized_kind = 'CLAN'
      then away_deposit_forfeited end,
    'correction_reversals', reversal_summary,
    'initial_player_sr_pipeline_replayed',
      replay_initial_player_sr_pipeline,
    'restored_booking_ids', restored_booking_ids,
    'player_sr_lineup_profile_ids', player_sr_lineup_profile_ids,
    'refund_needs_attention', refund_failure_exists
  )
  where id = revision_id_to_use;

  update public.match_resolution_disputes
  set status = case
      when previous_revision.id is null then 'DISMISSED'
      when previous_revision.resolution_type = normalized_resolution
        and previous_revision.payload = safe_payload then 'UPHELD'
      else 'OVERTURNED' end,
    resolved_at = clock_timestamp(),
    resolved_by = actor_admin_id,
    resolution_note = left(
      'Superseded by resolution revision ' || next_revision::text ||
        ': ' || normalized_reason,
      2000
    )
  where case_id = case_to_resolve.id and status = 'OPEN';

  update public.match_resolution_cases
  set state = case when refund_failure_exists
      then 'UNDER_REVIEW' else 'RESOLVED' end,
    reason_code = case when refund_failure_exists
      then 'REFUND_FAILED'
      else coalesce(
        nullif(evidence_snapshot ->> 'detection_reason_code', ''),
        case when reason_code in (
          'NO_ACTIVITY',
          'RESULT_MISSING',
          'REFEREE_REPORT_MISSING'
        ) then reason_code else 'NO_ACTIVITY' end
      )
      end,
    resolved_at = case when refund_failure_exists
      then null else clock_timestamp() end,
    resolved_by = case when refund_failure_exists
      then null else actor_admin_id end,
    current_revision = next_revision,
    evidence_snapshot = evidence_snapshot || jsonb_build_object(
      'resolved_evidence', safe_payload -> 'evidence',
      'last_resolution_at', clock_timestamp(),
      'refund_needs_attention', refund_failure_exists
    )
  where id = case_to_resolve.id;

  if normalized_kind = 'CLAN' then
    update public.fixtures
    set operational_state = case when refund_failure_exists
        then 'UNDER_REVIEW' else 'RESOLVED' end,
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = case when refund_failure_exists
        then 'REFUND_FAILED' else null end
    where id = match_id_to_use;
  else
    update public.open_queue_games
    set operational_state = case when refund_failure_exists
        then 'UNDER_REVIEW' else 'RESOLVED' end,
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = case when refund_failure_exists
        then 'REFUND_FAILED' else null end
    where id = match_id_to_use;
  end if;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    case when is_correction
      then 'MATCH_RESOLUTION_CORRECTED'
      else 'NO_DATA_MATCH_RESOLVED' end,
    entity_type_to_use,
    match_id_to_use,
    normalized_reason,
    jsonb_build_object(
      'match', current_before,
      'case', to_jsonb(case_to_resolve),
      'previous_revision_id', previous_revision.id
    ),
    jsonb_build_object(
      'case_id', case_to_resolve.id,
      'revision_id', revision_id_to_use,
      'revision', next_revision,
      'resolution_type', normalized_resolution,
      'refund_needs_attention', refund_failure_exists,
      'reversals', reversal_summary,
      'player_sr_policy', 'PRESERVE_APPLIED_SR'
    )
  );

  insert into public.notifications (
    recipient_profile_id, type, title, body,
    related_entity_type, related_entity_id, data
  )
  select distinct
    affected.profile_id,
    'MATCH_RESOLUTION_RECORDED',
    'Match record updated',
    left(
      'Field reviewed the missing match record: ' ||
        initcap(replace(lower(normalized_resolution), '_', ' ')) ||
        '. Open the match for strike and refund details.',
      300
    ),
    entity_type_to_use,
    match_id_to_use,
    jsonb_build_object(
      'match_kind', normalized_kind,
      'match_id', match_id_to_use,
      'case_id', case_to_resolve.id,
      'revision_id', revision_id_to_use,
      'resolution_type', normalized_resolution,
      'refund_needs_attention', refund_failure_exists
    )
  from (
    select member.profile_id
    from public.clan_members member
    where normalized_kind = 'CLAN'
      and member.left_at is null
      and member.clan_id in (home_clan_id_to_use, away_clan_id_to_use)
    union
    select booking.profile_id
    from public.open_queue_bookings booking
    where normalized_kind = 'SOLO'
      and booking.game_id = match_id_to_use
  ) affected
  where affected.profile_id is not null;

  select jsonb_build_object(
    'case_id', review_case.id,
    'state', review_case.state,
    'revision', review_case.current_revision,
    'revision_id', revision_id_to_use,
    'resolution_type', normalized_resolution,
    'consequences', revision.consequence_snapshot,
    'refunds', coalesce((
      select jsonb_agg(to_jsonb(refund) order by refund.side, refund.id)
      from public.match_resolution_refunds refund
      where refund.revision_id = revision_id_to_use
    ), '[]'::jsonb)
  ) into result_to_return
  from public.match_resolution_cases review_case
  join public.match_resolution_revisions revision
    on revision.id = revision_id_to_use
  where review_case.id = case_to_resolve.id;

  perform set_config('field.match_resolution_control_plane', 'off', true);
  perform set_config('field.admin_score_override', 'off', true);
  return result_to_return;
end;
$$;

revoke all on function public.admin_resolve_match_case(
  uuid,text,uuid,integer,text,text,jsonb
) from public, anon, authenticated;
grant execute on function public.admin_resolve_match_case(
  uuid,text,uuid,integer,text,text,jsonb
) to service_role;

-- Execute the canonical resolver inside a rolled-back subtransaction so the
-- preview cannot drift from the actual consequence engine. PostgreSQL rolls
-- back every wallet, rating, attendance, audit and notification write made in
-- the inner block while retaining the computed JSON in the local variable.
create or replace function public.admin_preview_match_case_resolution(
  actor_admin_id uuid,
  match_kind_to_use text,
  match_id_to_use uuid,
  expected_revision_to_use integer,
  resolution_type_to_use text,
  reason_to_use text,
  payload_to_use jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  simulated_result jsonb;
  sanitized_refunds jsonb := '[]'::jsonb;
begin
  begin
    simulated_result := public.admin_resolve_match_case(
      actor_admin_id,
      match_kind_to_use,
      match_id_to_use,
      expected_revision_to_use,
      resolution_type_to_use,
      reason_to_use,
      payload_to_use
    );
    raise sqlstate 'P7001'
      using message = 'match-resolution-preview-rollback';
  exception when sqlstate 'P7001' then
    -- Do not hide an unrelated nested error that happens to use this code.
    if simulated_result is null then
      raise;
    end if;
  end;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'side', refund.value ->> 'side',
        'recipient_profile_id', refund.value ->> 'recipient_profile_id',
        'clan_id', refund.value ->> 'clan_id',
        'booking_id', refund.value ->> 'booking_id',
        'amount_fils', coalesce(
          (refund.value ->> 'amount_fils')::integer, 0
        ),
        'target_amount_fils', coalesce(
          (refund.value ->> 'target_amount_fils')::integer, 0
        ),
        'previously_refunded_fils', coalesce(
          (refund.value ->> 'previously_refunded_fils')::integer, 0
        ),
        'refund_bps', coalesce(
          (refund.value ->> 'refund_bps')::integer, 0
        ),
        'destination', refund.value ->> 'destination',
        'status', refund.value ->> 'status',
        'failure_reason', refund.value ->> 'failure_reason'
      )
      order by refund.value ->> 'side',
        refund.value ->> 'recipient_profile_id'
    ),
    '[]'::jsonb
  ) into sanitized_refunds
  from jsonb_array_elements(
    coalesce(simulated_result -> 'refunds', '[]'::jsonb)
  ) refund(value);

  return jsonb_build_object(
    'preview', true,
    'case_id', simulated_result -> 'case_id',
    'current_revision', expected_revision_to_use,
    'next_revision', simulated_result -> 'revision',
    'is_correction', coalesce(expected_revision_to_use, 0) > 0,
    'resolution_type', simulated_result -> 'resolution_type',
    'would_set_case_state', simulated_result -> 'state',
    'consequences', coalesce(
      simulated_result -> 'consequences', '{}'::jsonb
    ),
    'refunds', sanitized_refunds
  );
end;
$$;

revoke all on function public.admin_preview_match_case_resolution(
  uuid,text,uuid,integer,text,text,jsonb
) from public, anon, authenticated;
grant execute on function public.admin_preview_match_case_resolution(
  uuid,text,uuid,integer,text,text,jsonb
) to service_role;

create or replace function public.get_clan_reliability_summary(
  clan_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  is_member_to_use boolean := false;
  active_strikes_to_use integer := 0;
  policy_to_use public.reliability_policy_versions%rowtype;
  deposit_threshold integer := 0;
  active_sanctions_to_use integer := 0;
  incidents_to_use jsonb := '[]'::jsonb;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if not exists (
    select 1 from public.clans clan
    where clan.id = clan_id_to_use and clan.archived_at is null
  ) then
    raise exception 'Clan not found.';
  end if;
  select exists (
    select 1 from public.clan_members member
    where member.clan_id = clan_id_to_use
      and member.profile_id = user_id
      and member.left_at is null
  ) into is_member_to_use;
  active_strikes_to_use := public.active_clan_reliability_strikes(
    clan_id_to_use, statement_timestamp()
  );

  if is_member_to_use then
    select * into policy_to_use
    from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from <= statement_timestamp()
    order by policy.effective_from desc, policy.version desc
    limit 1;
    deposit_threshold := coalesce(
      (policy_to_use.config #>>
        '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer,
      0
    );
    select count(*)::integer into active_sanctions_to_use
    from public.reliability_sanctions sanction
    where sanction.subject_type = 'CLAN'
      and sanction.clan_id = clan_id_to_use
      and sanction.revoked_at is null
      and sanction.starts_at <= statement_timestamp()
      and (
        sanction.ends_at is null
        or sanction.ends_at > statement_timestamp()
      );

    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', incident.id,
        'outcome', incident.outcome,
        'strike_delta', incident.strike_delta,
        'occurred_at', incident.occurred_at,
        'expires_at', incident.expires_at,
        'reason', coalesce(
          nullif(trim(resolution.reason), ''),
          nullif(trim(incident.detail ->> 'reason'), ''),
          case incident.outcome
            when 'NO_SHOW' then 'The clan did not attend a scheduled match.'
            when 'ENTIRE_CLAN_NO_SHOW'
              then 'The clan did not attend a scheduled match.'
            when 'FORFEIT' then 'The clan forfeited a scheduled match.'
            when 'PARTIAL_LATE'
              then 'The clan did not meet the policy roster requirement.'
            else initcap(replace(lower(incident.outcome), '_', ' '))
          end
        ),
        'fixture_id', fixture.id,
        'fixture_label', case when fixture.id is null then null else
          to_char(fixture.match_date, 'Mon FMDD, YYYY') || ' · ' ||
            fixture.venue
        end,
        'issuer_label', coalesce(
          nullif(trim(issuer.display_name), ''),
          nullif(trim(legacy_issuer.display_name), ''),
          nullif(trim(incident.detail ->> 'issuer_label'), ''),
          'Field operations'
        ),
        'is_active', incident.strike_delta > 0
          and incident.occurred_at <= statement_timestamp()
          and (
            incident.expires_at is null
            or incident.expires_at > statement_timestamp()
          )
          and not exists (
            select 1 from public.reliability_incidents reversal
            where reversal.reversal_of = incident.id
          ),
        'reversal_of', incident.reversal_of,
        'revision_id', resolution.revision_id
      )
      order by incident.occurred_at desc, incident.id
    ), '[]'::jsonb) into incidents_to_use
    from public.reliability_incidents incident
    left join lateral (
      select
        revision.id as revision_id,
        revision.reason,
        revision.created_by,
        review_case.fixture_id
      from public.match_resolution_incident_links link
      join public.match_resolution_revisions revision
        on revision.id = link.revision_id
      join public.match_resolution_cases review_case
        on review_case.id = link.case_id
      where link.incident_id = incident.id
      order by revision.revision desc
      limit 1
    ) resolution on true
    left join public.clan_match_reliability_outcomes legacy_outcome
      on legacy_outcome.fixture_id = incident.fixture_id
      and legacy_outcome.clan_id = incident.clan_id
    left join public.profiles issuer
      on issuer.id = resolution.created_by
    left join public.profiles legacy_issuer
      on legacy_issuer.id = legacy_outcome.finalized_by
    left join public.fixtures fixture
      on fixture.id = coalesce(incident.fixture_id, resolution.fixture_id)
    where incident.subject_type = 'CLAN'
      and incident.clan_id = clan_id_to_use;
  end if;

  return jsonb_build_object(
    'clan_id', clan_id_to_use,
    'active_strikes', active_strikes_to_use,
    'is_member', is_member_to_use,
    'consequence_summary', jsonb_build_object(
      'deposit_required', case when is_member_to_use
        then deposit_threshold > 0
          and active_strikes_to_use >= deposit_threshold
        else null end,
      'active_sanctions', case when is_member_to_use
        then active_sanctions_to_use else null end
    ),
    'incidents', incidents_to_use
  );
end;
$$;

create or replace function public.submit_match_resolution_dispute(
  case_id_to_use uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  review_case public.match_resolution_cases%rowtype;
  current_revision public.match_resolution_revisions%rowtype;
  clan_id_to_use uuid;
  dispute_id_to_use uuid;
  match_id_to_use uuid;
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  dispute_due_at timestamptz;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Explain what should be reviewed (at least 10 characters).';
  end if;
  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.id = case_id_to_use
  for update;
  if review_case.id is null or review_case.current_revision <= 0 then
    raise exception 'A resolved match record is required.';
  end if;
  select * into current_revision
  from public.match_resolution_revisions revision
  where revision.case_id = review_case.id
    and revision.revision = review_case.current_revision;
  if current_revision.id is null then
    raise exception 'The current resolution revision is missing.';
  end if;
  dispute_due_at := current_revision.created_at + interval '24 hours';
  if clock_timestamp() > dispute_due_at then
    raise exception 'The 24-hour match dispute window has closed.';
  end if;

  if review_case.match_kind = 'CLAN' then
    select member.clan_id into clan_id_to_use
    from public.clan_members member
    join public.fixtures fixture
      on fixture.id = review_case.fixture_id
    where member.profile_id = user_id
      and member.left_at is null
      and member.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
    limit 1;
    if clan_id_to_use is null then
      raise exception 'Only an affected clan member can dispute this result.';
    end if;
  elsif not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = review_case.open_queue_game_id
      and booking.profile_id = user_id
  ) then
    raise exception 'Only a player from this match can dispute this result.';
  end if;

  insert into public.match_resolution_disputes (
    case_id, revision_id, submitted_by, clan_id, reason
  ) values (
    review_case.id, current_revision.id, user_id, clan_id_to_use,
    normalized_reason
  ) returning id into dispute_id_to_use;

  update public.match_resolution_cases
  set state = 'UNDER_REVIEW',
    reason_code = 'DISPUTED',
    resolved_at = null,
    resolved_by = null
  where id = review_case.id;
  match_id_to_use := coalesce(
    review_case.fixture_id, review_case.open_queue_game_id
  );
  if review_case.match_kind = 'CLAN' then
    update public.fixtures
    set operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = 'DISPUTED'
    where id = review_case.fixture_id;
  else
    update public.open_queue_games
    set operational_state = 'UNDER_REVIEW',
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = 'DISPUTED'
    where id = review_case.open_queue_game_id;
  end if;

  insert into public.notifications (
    recipient_profile_id, type, title, body,
    related_entity_type, related_entity_id, data
  )
  select
    admin.profile_id,
    'MATCH_RESOLUTION_DISPUTED',
    'Match resolution disputed',
    'An affected player or clan member disputed an administrative match resolution.',
    case when review_case.match_kind = 'CLAN'
      then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_use,
    jsonb_build_object(
      'case_id', review_case.id,
      'revision_id', current_revision.id,
      'dispute_id', dispute_id_to_use,
      'refunds_continue', true
    )
  from public.referee_profiles admin
  where admin.role = 'admin' and admin.is_active;

  return jsonb_build_object(
    'dispute_id', dispute_id_to_use,
    'case_id', review_case.id,
    'revision_id', current_revision.id,
    'state', 'UNDER_REVIEW',
    'dispute_due_at', dispute_due_at,
    'refunds_continue', true
  );
exception
  when unique_violation then
    raise exception 'You already have an open dispute for this match.';
end;
$$;

create or replace function public.get_match_resolution_case(
  match_kind_to_use text,
  match_id_to_use uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  normalized_kind text := upper(trim(coalesce(match_kind_to_use, '')));
  review_case public.match_resolution_cases%rowtype;
  current_revision public.match_resolution_revisions%rowtype;
  viewer_clan_id uuid;
  visible_consequences jsonb := '{}'::jsonb;
  dispute_due_at timestamptz;
  can_dispute boolean := false;
begin
  if user_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if normalized_kind not in ('CLAN', 'SOLO') then
    raise exception 'Choose a clan or solo match.';
  end if;
  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.match_kind = normalized_kind
    and (
      (normalized_kind = 'CLAN' and candidate.fixture_id = match_id_to_use)
      or
      (normalized_kind = 'SOLO'
        and candidate.open_queue_game_id = match_id_to_use)
    );
  if review_case.id is null then
    return null;
  end if;
  if normalized_kind = 'CLAN' then
    select member.clan_id into viewer_clan_id
    from public.clan_members member
    join public.fixtures fixture on fixture.id = review_case.fixture_id
    where member.profile_id = user_id
      and member.left_at is null
      and member.clan_id in (fixture.home_clan_id, fixture.away_clan_id)
    limit 1;
    if viewer_clan_id is null then
      raise exception 'Only an affected clan member can view this review.';
    end if;
  elsif not exists (
    select 1 from public.open_queue_bookings booking
    where booking.game_id = review_case.open_queue_game_id
      and booking.profile_id = user_id
  ) then
    raise exception 'Only a player from this match can view this review.';
  end if;

  if review_case.current_revision > 0 then
    select * into current_revision
    from public.match_resolution_revisions revision
    where revision.case_id = review_case.id
      and revision.revision = review_case.current_revision;
    dispute_due_at := current_revision.created_at + interval '24 hours';
    -- Booking/profile identifiers are internal correction provenance. A
    -- participant sees their own filtered refund rows below, never another
    -- player's booking id or the complete rated lineup.
    visible_consequences := current_revision.consequence_snapshot
      - 'administratively_cancelled_booking_ids'
      - 'restored_booking_ids'
      - 'player_sr_lineup_profile_ids';
    if normalized_kind = 'CLAN' then
      -- Exact payer/refund details are returned from the viewer-filtered
      -- refund rows below. Do not leak the opponent's financial outcome
      -- through the shared consequence snapshot.
      visible_consequences := visible_consequences
        - 'home_refund_target_fils'
        - 'away_refund_target_fils'
        - 'home_deposit_forfeited'
        - 'away_deposit_forfeited';
    end if;
    can_dispute := clock_timestamp() <= dispute_due_at
      and not exists (
        select 1 from public.match_resolution_disputes dispute
        where dispute.case_id = review_case.id
          and dispute.submitted_by = user_id
          and dispute.status = 'OPEN'
      );
  end if;

  return jsonb_build_object(
    'id', review_case.id,
    'match_kind', review_case.match_kind,
    'match_id', match_id_to_use,
    'state', review_case.state,
    'reason_code', review_case.reason_code,
    'detected_at', review_case.detected_at,
    'high_priority_at', review_case.high_priority_at,
    'current_revision', review_case.current_revision,
    'resolution', case when current_revision.id is null then null
      else jsonb_build_object(
        'id', current_revision.id,
        'revision', current_revision.revision,
        'resolution_type', current_revision.resolution_type,
        'reason', current_revision.reason,
        'consequences', visible_consequences,
        'created_at', current_revision.created_at
      ) end,
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', refund.id,
        'side', refund.side,
        'amount_fils', refund.amount_fils,
        'target_amount_fils', refund.target_amount_fils,
        'refund_bps', refund.refund_bps,
        'destination', refund.destination,
        'status', refund.status,
        'failure_reason', case when refund.status = 'FAILED'
          then 'Refund needs administrator attention.'
          else null end,
        'created_at', refund.created_at
      ) order by refund.side, refund.created_at)
      from public.match_resolution_refunds refund
      where refund.case_id = review_case.id
        and (
          (normalized_kind = 'CLAN' and refund.clan_id = viewer_clan_id)
          or
          (normalized_kind = 'SOLO'
            and refund.recipient_profile_id = user_id)
        )
    ), '[]'::jsonb),
    'my_disputes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', dispute.id,
        'revision_id', dispute.revision_id,
        'reason', dispute.reason,
        'status', dispute.status,
        'submitted_at', dispute.submitted_at,
        'resolved_at', dispute.resolved_at,
        'resolution_note', dispute.resolution_note
      ) order by dispute.submitted_at desc)
      from public.match_resolution_disputes dispute
      where dispute.case_id = review_case.id
        and dispute.submitted_by = user_id
    ), '[]'::jsonb),
    'dispute_due_at', dispute_due_at,
    'can_dispute', can_dispute,
    'refunds_continue_during_dispute', true
  );
end;
$$;

revoke all on function public.get_match_resolution_case(text,uuid)
from public, anon, authenticated;
grant execute on function public.get_match_resolution_case(text,uuid)
to authenticated, service_role;

create or replace function public.admin_retry_match_resolution_refund(
  actor_admin_id uuid,
  refund_id_to_retry uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  refund_case_id uuid;
  refund_to_retry public.match_resolution_refunds%rowtype;
  review_case public.match_resolution_cases%rowtype;
  revision_to_use public.match_resolution_revisions%rowtype;
  normalized_reason text := trim(coalesce(reason_to_use, ''));
  wallet_transaction_id_to_use uuid;
  authoritative_refund_fils integer := 0;
  retry_amount_fils integer := 0;
  retry_failed boolean := false;
  retry_failure_reason text;
  remaining_failure boolean;
  has_open_dispute boolean;
  final_case_state text;
  final_reason_code text;
  match_id_to_use uuid;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;
  if char_length(normalized_reason) < 10
    or char_length(normalized_reason) > 2000
  then
    raise exception 'Add a clear refund retry reason.';
  end if;
  select refund.case_id into refund_case_id
  from public.match_resolution_refunds refund
  where refund.id = refund_id_to_retry;
  if refund_case_id is null then
    raise exception 'Match resolution refund not found.';
  end if;

  -- Keep the same case-first lock order used by admin_resolve_match_case so a
  -- correction and refund retry cannot deadlock or race one another.
  select * into review_case
  from public.match_resolution_cases candidate
  where candidate.id = refund_case_id
  for update;
  select * into refund_to_retry
  from public.match_resolution_refunds refund
  where refund.id = refund_id_to_retry
  for update;
  select * into revision_to_use
  from public.match_resolution_revisions revision
  where revision.id = refund_to_retry.revision_id;
  if revision_to_use.id is null
    or revision_to_use.case_id <> review_case.id
  then
    raise exception 'The refund revision is missing or invalid.';
  end if;
  if revision_to_use.revision <> review_case.current_revision then
    raise exception
      'This refund belongs to a superseded resolution. Retry the current revision instead.';
  end if;
  if refund_to_retry.status <> 'FAILED' then
    return jsonb_build_object(
      'refund_id', refund_to_retry.id,
      'status', refund_to_retry.status,
      'already_settled', true,
      'case_state', review_case.state
    );
  end if;
  if refund_to_retry.recipient_profile_id is null then
    raise exception
      'This refund has no original payer. Reconcile the payer before retrying.';
  end if;
  match_id_to_use := coalesce(
    review_case.fixture_id, review_case.open_queue_game_id
  );
  if review_case.match_kind = 'CLAN' then
    if refund_to_retry.side = 'HOME' then
      select coalesce(fixture.home_refund_amount_fils, 0)
      into authoritative_refund_fils
      from public.fixtures fixture
      where fixture.id = review_case.fixture_id
      for update;
    elsif refund_to_retry.side = 'AWAY' then
      select coalesce(fixture.away_refund_amount_fils, 0)
      into authoritative_refund_fils
      from public.fixtures fixture
      where fixture.id = review_case.fixture_id
      for update;
    else
      raise exception 'Clan refund side must be HOME or AWAY.';
    end if;
  elsif refund_to_retry.booking_id is not null then
    select coalesce(booking.refund_amount_fils, 0)
    into authoritative_refund_fils
    from public.open_queue_bookings booking
    where booking.id = refund_to_retry.booking_id
      and booking.game_id = review_case.open_queue_game_id
    for update;
    if not found then
      raise exception 'The solo refund booking is missing.';
    end if;
  else
    raise exception 'The solo refund booking is missing.';
  end if;
  retry_amount_fils := greatest(
    0,
    refund_to_retry.target_amount_fils - authoritative_refund_fils
  );

  if retry_amount_fils <= 0 then
    update public.match_resolution_refunds
    set amount_fils = 0,
      previously_refunded_fils = authoritative_refund_fils,
      status = 'COMPLETED',
      failure_reason = null
    where id = refund_to_retry.id;
  else
    begin
      wallet_transaction_id_to_use := public.credit_field_wallet(
        refund_to_retry.recipient_profile_id,
        retry_amount_fils,
        'FIELD_CANCELLATION_REFUND',
        'match-resolution:' || refund_to_retry.revision_id::text || ':' ||
          refund_to_retry.side || ':' ||
          refund_to_retry.recipient_profile_id::text,
        'Retried administrative match-resolution refund: ' ||
          left(normalized_reason, 240),
        refund_to_retry.policy_version_id,
        refund_to_retry.booking_id,
        null,
        jsonb_build_object(
          'match_resolution_case_id', refund_to_retry.case_id,
          'match_resolution_revision_id', refund_to_retry.revision_id,
          'refund_retry', true,
          'target_amount_fils', refund_to_retry.target_amount_fils,
          'previously_refunded_fils', authoritative_refund_fils,
          'reason', normalized_reason
        )
      );
      update public.match_resolution_refunds
      set amount_fils = retry_amount_fils,
        previously_refunded_fils = authoritative_refund_fils,
        status = 'COMPLETED',
        wallet_transaction_id = wallet_transaction_id_to_use,
        failure_reason = null
      where id = refund_to_retry.id;
    exception when others then
      retry_failed := true;
      retry_failure_reason := left(sqlerrm, 1000);
      update public.match_resolution_refunds
      set amount_fils = retry_amount_fils,
        previously_refunded_fils = authoritative_refund_fils,
        status = 'FAILED',
        failure_reason = retry_failure_reason
      where id = refund_to_retry.id;
    end;
  end if;

  if not retry_failed and review_case.match_kind = 'CLAN' then
    if refund_to_retry.side = 'HOME' then
      update public.fixtures
      set home_refund_amount_fils = greatest(
            coalesce(home_refund_amount_fils, 0),
            refund_to_retry.target_amount_fils
          ),
          home_refund_bps = greatest(
            coalesce(home_refund_bps, 0), refund_to_retry.refund_bps
          ),
          home_deposit_status = case
            when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
            when coalesce(
              (revision_to_use.consequence_snapshot ->>
                'home_deposit_forfeited')::boolean,
              false
            ) then home_deposit_status
            else 'RETURNED' end
      where id = review_case.fixture_id;
    else
      update public.fixtures
      set away_refund_amount_fils = greatest(
            coalesce(away_refund_amount_fils, 0),
            refund_to_retry.target_amount_fils
          ),
          away_refund_bps = greatest(
            coalesce(away_refund_bps, 0), refund_to_retry.refund_bps
          ),
          away_deposit_status = case
            when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
            when coalesce(
              (revision_to_use.consequence_snapshot ->>
                'away_deposit_forfeited')::boolean,
              false
            ) then away_deposit_status
            else 'RETURNED' end
      where id = review_case.fixture_id;
    end if;
  elsif not retry_failed and refund_to_retry.booking_id is not null then
    update public.open_queue_bookings
    set refund_amount_fils = greatest(
          coalesce(refund_amount_fils, 0),
          refund_to_retry.target_amount_fils
        ),
        refund_bps = greatest(
          coalesce(refund_bps, 0), refund_to_retry.refund_bps
        ),
        refund_percent = case
          when greatest(
            coalesce(refund_bps, 0), refund_to_retry.refund_bps
          ) >= 10000 then 100
          when greatest(
            coalesce(refund_bps, 0), refund_to_retry.refund_bps
          ) >= 5000 then 50
          else 0 end,
        refund_status = 'PROCESSED',
        payment_status = case
          when amount_paid_fils > 0
            and refund_to_retry.target_amount_fils >= amount_paid_fils
            then 'REFUNDED'
          else 'PARTIALLY_REFUNDED' end
    where id = refund_to_retry.booking_id;
  end if;

  select exists (
    select 1 from public.match_resolution_refunds refund
    join public.match_resolution_revisions revision
      on revision.id = refund.revision_id
    where refund.case_id = review_case.id
      and revision.revision = review_case.current_revision
      and refund.status = 'FAILED'
  ) into remaining_failure;
  select exists (
    select 1
    from public.match_resolution_disputes dispute
    where dispute.case_id = review_case.id
      and dispute.status = 'OPEN'
  ) into has_open_dispute;
  final_case_state := case
    when remaining_failure or has_open_dispute then 'UNDER_REVIEW'
    else 'RESOLVED'
  end;
  final_reason_code := case
    when remaining_failure then 'REFUND_FAILED'
    when has_open_dispute then 'DISPUTED'
    else coalesce(
      nullif(review_case.evidence_snapshot ->> 'detection_reason_code', ''),
      case when review_case.reason_code in (
        'NO_ACTIVITY',
        'RESULT_MISSING',
        'REFEREE_REPORT_MISSING'
      ) then review_case.reason_code else 'NO_ACTIVITY' end
    )
  end;
  update public.match_resolution_cases
  set state = final_case_state,
    reason_code = final_reason_code,
    resolved_at = case when final_case_state = 'RESOLVED'
      then clock_timestamp() else null end,
    resolved_by = case when final_case_state = 'RESOLVED'
      then actor_admin_id else null end
  where id = review_case.id;
  if review_case.match_kind = 'CLAN' then
    update public.fixtures
    set operational_state = final_case_state,
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = case when final_case_state = 'RESOLVED'
        then null else final_reason_code end
    where id = review_case.fixture_id;
  else
    update public.open_queue_games
    set operational_state = final_case_state,
      operational_state_updated_at = clock_timestamp(),
      operational_reason_code = case when final_case_state = 'RESOLVED'
        then null else final_reason_code end
    where id = review_case.open_queue_game_id;
  end if;

  insert into public.admin_audit_events (
    actor_referee_id, action, entity_type, entity_id, reason,
    before_state, after_state
  ) values (
    actor_admin_id,
    'MATCH_RESOLUTION_REFUND_RETRIED',
    case when review_case.match_kind = 'CLAN'
      then 'CLAN_MATCH' else 'SOLO_MATCH' end,
    match_id_to_use,
    normalized_reason,
    to_jsonb(refund_to_retry),
    jsonb_build_object(
      'refund_id', refund_to_retry.id,
      'status', case when retry_failed then 'FAILED' else 'COMPLETED' end,
      'amount_fils', retry_amount_fils,
      'wallet_transaction_id', wallet_transaction_id_to_use,
      'remaining_failure', remaining_failure,
      'open_dispute', has_open_dispute,
      'failure_reason', retry_failure_reason
    )
  );
  return jsonb_build_object(
    'refund_id', refund_to_retry.id,
    'status', case when retry_failed then 'FAILED' else 'COMPLETED' end,
    'amount_fils', retry_amount_fils,
    'wallet_transaction_id', wallet_transaction_id_to_use,
    'failure_reason', retry_failure_reason,
    'case_state', final_case_state,
    'case_reason_code', final_reason_code
  );
end;
$$;

revoke all on function public.admin_retry_match_resolution_refund(
  uuid,uuid,text
) from public, anon, authenticated;
grant execute on function public.admin_retry_match_resolution_refund(
  uuid,uuid,text
) to service_role;

-- Mobile consumes these three RPCs rather than selecting every solo game
-- directly. Preserve their current bodies (including the later cancelled-game
-- history fix) while extending the named return contract.
do $migration$
declare
  function_definition text;
  changed_definition text;
begin
  select pg_get_functiondef(
    'public.list_open_queue_games()'::regprocedure
  ) into function_definition;
  if position('operational_state text' in function_definition) = 0 then
    changed_definition := replace(
      function_definition,
      'status text, venue text',
      'status text, operational_state text, operational_state_updated_at timestamp with time zone, operational_reason_code text, venue text'
    );
    changed_definition := replace(
      changed_definition,
      E'    game.status,\n    game.venue,',
      E'    game.status,\n    game.operational_state,\n    game.operational_state_updated_at,\n    game.operational_reason_code,\n    game.venue,'
    );
    if changed_definition = function_definition
      or position('game.operational_state' in changed_definition) = 0
    then
      raise exception
        'Could not expose operational state in list_open_queue_games().';
    end if;
    execute 'drop function public.list_open_queue_games()';
    execute changed_definition;
  end if;

  select pg_get_functiondef(
    'public.list_open_queue_fixture_games()'::regprocedure
  ) into function_definition;
  if position('operational_state text' in function_definition) = 0 then
    changed_definition := replace(
      function_definition,
      'status text, venue text',
      'status text, operational_state text, operational_state_updated_at timestamp with time zone, operational_reason_code text, venue text'
    );
    changed_definition := replace(
      changed_definition,
      E'    game.status,\n    game.venue,',
      E'    game.status,\n    game.operational_state,\n    game.operational_state_updated_at,\n    game.operational_reason_code,\n    game.venue,'
    );
    if changed_definition = function_definition
      or position('game.operational_state' in changed_definition) = 0
    then
      raise exception
        'Could not expose operational state in list_open_queue_fixture_games().';
    end if;
    execute 'drop function public.list_open_queue_fixture_games()';
    execute changed_definition;
  end if;

  select pg_get_functiondef(
    'public.get_open_queue_match_detail(uuid)'::regprocedure
  ) into function_definition;
  if position('operational_state' in function_definition) = 0 then
    changed_definition := replace(
      function_definition,
      E'    ''status'', game.status,\n    ''venue'', game.venue,',
      E'    ''status'', game.status,\n    ''operational_state'', game.operational_state,\n    ''operational_state_updated_at'', game.operational_state_updated_at,\n    ''operational_reason_code'', game.operational_reason_code,\n    ''venue'', game.venue,'
    );
    if changed_definition = function_definition then
      raise exception
        'Could not expose operational state in get_open_queue_match_detail().';
    end if;
    execute changed_definition;
  end if;
end;
$migration$;

revoke all on function public.list_open_queue_games()
from public, anon, authenticated;
revoke all on function public.list_open_queue_fixture_games()
from public, anon, authenticated;
revoke all on function public.get_open_queue_match_detail(uuid)
from public, anon, authenticated;
grant execute on function public.list_open_queue_games()
to authenticated, service_role;
grant execute on function public.list_open_queue_fixture_games()
to authenticated, service_role;
grant execute on function public.get_open_queue_match_detail(uuid)
to authenticated, service_role;

-- Backfill every genuinely unresolved historical match. Complete FINAL scores
-- and explicit forfeit/cancellation decisions remain authoritative; partial
-- FINAL scores and finalized attendance without a result still require review.
do $$
declare
  inserted_count integer;
  pass integer := 0;
begin
  loop
    inserted_count := public.detect_due_match_resolution_cases();
    pass := pass + 1;
    exit when inserted_count = 0 or pass >= 100;
  end loop;
end;
$$;
