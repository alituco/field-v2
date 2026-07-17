-- Make the beta clan checkout amount authoritative before allowing admins to
-- change clan cancellation refunds or reliability deposits. Payments remain
-- explicitly test payments in the client, but every charge, refund and wallet
-- movement is now calculated and snapshotted by the server.

create or replace function public.reliability_policy_release_controls_are_valid(
  config_to_check jsonb
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return
    (config_to_check #>> '{solo,playersPerSide}')::integer = 6
    and (config_to_check #>> '{clan,playersPerSide}')::integer = 7
    and (config_to_check #>> '{solo,outcomes,fieldCancelled,strikes}')::integer = 0
    and (config_to_check #>> '{injury,strikeDelta}')::integer = 0
    and (config_to_check #>> '{injury,requiresRefereeVerification}')::boolean
      is true
    and not (config_to_check #>>
      '{appeals,routineTrafficAutomaticallyExcused}')::boolean;
exception
  when others then
    return false;
end;
$$;

alter table public.fixtures
add column if not exists home_base_amount_fils integer,
add column if not exists away_base_amount_fils integer,
add column if not exists home_reliability_deposit_fils integer not null default 0,
add column if not exists away_reliability_deposit_fils integer not null default 0,
add column if not exists home_amount_paid_fils integer,
add column if not exists away_amount_paid_fils integer,
add column if not exists home_charge_policy_version_id uuid
  references public.reliability_policy_versions(id) on delete restrict,
add column if not exists away_charge_policy_version_id uuid
  references public.reliability_policy_versions(id) on delete restrict,
add column if not exists home_refund_bps integer not null default 0,
add column if not exists away_refund_bps integer not null default 0,
add column if not exists home_refund_amount_fils integer not null default 0,
add column if not exists away_refund_amount_fils integer not null default 0,
add column if not exists home_deposit_status text not null default 'NOT_REQUIRED',
add column if not exists away_deposit_status text not null default 'NOT_REQUIRED';

update public.fixtures
set
  home_base_amount_fils = 20000,
  home_amount_paid_fils = 20000,
  home_reliability_deposit_fils = 0,
  home_deposit_status = 'NOT_REQUIRED'
where home_paid_by is not null
  and home_amount_paid_fils is null;

update public.fixtures
set
  away_base_amount_fils = 20000,
  away_amount_paid_fils = 20000,
  away_reliability_deposit_fils = 0,
  away_deposit_status = 'NOT_REQUIRED'
where away_clan_id is not null
  and away_paid_by is not null
  and away_amount_paid_fils is null;

alter table public.fixtures
drop constraint if exists fixtures_reliability_finance_check;
alter table public.fixtures
add constraint fixtures_reliability_finance_check check (
  coalesce(home_base_amount_fils, 0) >= 0
  and coalesce(away_base_amount_fils, 0) >= 0
  and home_reliability_deposit_fils >= 0
  and away_reliability_deposit_fils >= 0
  and coalesce(home_amount_paid_fils, 0) >= 0
  and coalesce(away_amount_paid_fils, 0) >= 0
  and home_refund_bps between 0 and 10000
  and away_refund_bps between 0 and 10000
  and home_refund_amount_fils >= 0
  and away_refund_amount_fils >= 0
  and home_deposit_status in (
    'NOT_REQUIRED', 'HELD', 'RETURNED', 'FORFEITED'
  )
  and away_deposit_status in (
    'NOT_REQUIRED', 'HELD', 'RETURNED', 'FORFEITED'
  )
  and (
    home_amount_paid_fils is null
    or home_amount_paid_fils =
      home_base_amount_fils + home_reliability_deposit_fils
  )
  and (
    away_amount_paid_fils is null
    or away_amount_paid_fils =
      away_base_amount_fils + away_reliability_deposit_fils
  )
);

create table public.clan_fixture_cancellations (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null unique
    references public.fixtures(id) on delete restrict,
  cancelling_clan_id uuid not null references public.clans(id) on delete restrict,
  cancelled_by uuid not null references public.profiles(id) on delete restrict,
  cancellation_band text not null check (
    cancellation_band in ('early', 'late', 'veryLate', 'afterKickoff')
  ),
  outcome text not null check (
    outcome in (
      'CANCELLED_EARLY', 'CANCELLED_LATE',
      'CANCELLED_VERY_LATE', 'NO_SHOW'
    )
  ),
  strike_delta integer not null check (strike_delta between 0 and 20),
  refund_bps integer not null check (refund_bps between 0 and 10000),
  refund_amount_fils integer not null check (refund_amount_fils >= 0),
  deposit_forfeited boolean not null,
  opponent_refund_amount_fils integer not null default 0 check (
    opponent_refund_amount_fils >= 0
  ),
  creates_forfeit boolean not null,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  policy_snapshot jsonb not null check (jsonb_typeof(policy_snapshot) = 'object'),
  reason text not null check (char_length(trim(reason)) between 5 and 1000),
  created_at timestamptz not null default clock_timestamp()
);

alter table public.clan_fixture_cancellations enable row level security;
revoke all on table public.clan_fixture_cancellations
from public, anon, authenticated;
grant all on table public.clan_fixture_cancellations to service_role;

drop trigger if exists protect_clan_fixture_cancellations_append_only
on public.clan_fixture_cancellations;
create trigger protect_clan_fixture_cancellations_append_only
before update or delete on public.clan_fixture_cancellations
for each row execute function public.protect_append_only_reliability_rows();

create or replace function public.clan_fixture_charge_quote_from_snapshot(
  clan_id_to_use uuid,
  policy_version_id_to_use uuid,
  policy_snapshot_to_use jsonb,
  server_now_to_use timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  active_strikes integer;
  deposit_threshold integer;
  deposit_bps integer;
  base_amount_fils constant integer := 20000;
  deposit_amount_fils integer := 0;
begin
  if clan_id_to_use is null or policy_version_id_to_use is null
    or policy_snapshot_to_use is null
  then
    raise exception 'Clan and frozen reliability policy are required.';
  end if;
  if not public.reliability_policy_config_is_valid(policy_snapshot_to_use) then
    raise exception 'The frozen reliability policy snapshot is invalid.';
  end if;

  active_strikes := public.active_clan_reliability_strikes(
    clan_id_to_use,
    server_now_to_use
  );
  deposit_threshold := (policy_snapshot_to_use #>>
    '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer;
  deposit_bps := (policy_snapshot_to_use #>>
    '{clan,reliabilityDeposit,depositBps}')::integer;
  if active_strikes >= deposit_threshold then
    deposit_amount_fils := ceiling(
      base_amount_fils::numeric * deposit_bps / 10000
    )::integer;
  end if;

  return jsonb_build_object(
    'server_now', server_now_to_use,
    'policy_version_id', policy_version_id_to_use,
    'currency', 'BHD',
    'active_clan_strikes', active_strikes,
    'base_amount_fils', base_amount_fils,
    'reliability_deposit_required', active_strikes >= deposit_threshold,
    'reliability_deposit_bps', deposit_bps,
    'reliability_deposit_fils', deposit_amount_fils,
    'total_fils', base_amount_fils + deposit_amount_fils,
    'deposit_return_destination', 'FIELD_WALLET'
  );
end;
$$;

create or replace function public.clan_fixture_charge_quote(
  clan_id_to_use uuid,
  kickoff_at_to_use timestamptz,
  server_now_to_use timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  policy_to_use public.reliability_policy_versions%rowtype;
begin
  if clan_id_to_use is null or kickoff_at_to_use is null then
    raise exception 'Clan and kickoff are required.';
  end if;

  select * into policy_to_use
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
    and policy.effective_from <= kickoff_at_to_use
  order by policy.effective_from desc, policy.version desc
  limit 1;
  if policy_to_use.id is null then
    raise exception 'No reliability policy is published for this kickoff.';
  end if;

  return public.clan_fixture_charge_quote_from_snapshot(
    clan_id_to_use,
    policy_to_use.id,
    policy_to_use.config,
    server_now_to_use
  );
end;
$$;

create or replace function public.preview_create_clan_fixture_charge(
  clan_id_to_use uuid,
  match_date_to_use date,
  time_slot_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  if not public.is_clan_manager(clan_id_to_use, auth.uid()) then
    raise exception 'Only clan owners and leaders can schedule this match.';
  end if;
  return public.clan_fixture_charge_quote(
    clan_id_to_use,
    public.fixture_start_at(match_date_to_use, time_slot_to_use)
  );
end;
$$;

create or replace function public.preview_join_clan_fixture_charge(
  fixture_id_to_use uuid,
  clan_id_to_use uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  if not public.is_clan_manager(clan_id_to_use, auth.uid()) then
    raise exception 'Only clan owners and leaders can join this match.';
  end if;
  select * into fixture_to_use from public.fixtures
  where id = fixture_id_to_use;
  if fixture_to_use.id is null
    or fixture_to_use.status <> 'OPEN'
    or fixture_to_use.away_clan_id is not null
  then
    raise exception 'This clan match is no longer open.';
  end if;
  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.match_kind = 'CLAN'
    and terms.fixture_id = fixture_to_use.id;
  if terms_to_use.id is null then
    raise exception 'This fixture has no frozen reliability contract. Refresh or contact Field support.';
  end if;
  if fixture_to_use.home_charge_policy_version_id is distinct from
    terms_to_use.policy_version_id
  then
    raise exception 'This fixture has inconsistent payment terms. Field must review it before another clan can join.';
  end if;
  return public.clan_fixture_charge_quote_from_snapshot(
    clan_id_to_use,
    terms_to_use.policy_version_id,
    terms_to_use.policy_snapshot
  );
end;
$$;

create or replace function public.snapshot_clan_fixture_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  quote jsonb;
  kickoff_at_to_use timestamptz;
  policy_to_use public.reliability_policy_versions%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
begin
  kickoff_at_to_use := public.fixture_start_at(new.match_date, new.time_slot);
  if tg_op = 'INSERT'
    or new.home_clan_id is distinct from old.home_clan_id
    or new.home_amount_paid_fils is null
  then
    quote := public.clan_fixture_charge_quote(new.home_clan_id, kickoff_at_to_use);
    new.home_base_amount_fils := (quote ->> 'base_amount_fils')::integer;
    new.home_reliability_deposit_fils :=
      (quote ->> 'reliability_deposit_fils')::integer;
    new.home_amount_paid_fils := (quote ->> 'total_fils')::integer;
    new.home_charge_policy_version_id := (quote ->> 'policy_version_id')::uuid;
    new.home_deposit_status := case
      when new.home_reliability_deposit_fils > 0 then 'HELD'
      else 'NOT_REQUIRED'
    end;
  end if;

  if new.away_clan_id is not null and (
    tg_op = 'INSERT'
    or new.away_clan_id is distinct from old.away_clan_id
    or new.away_amount_paid_fils is null
  ) then
    if tg_op = 'INSERT' then
      -- A fixture created with both clans has no AFTER-trigger terms row yet.
      -- Reuse the HOME charge policy chosen earlier in this same row operation.
      select * into policy_to_use
      from public.reliability_policy_versions policy
      where policy.id = new.home_charge_policy_version_id;
      if policy_to_use.id is null then
        raise exception 'The home clan reliability contract is missing.';
      end if;
      quote := public.clan_fixture_charge_quote_from_snapshot(
        new.away_clan_id,
        policy_to_use.id,
        policy_to_use.config
      );
    else
      select * into terms_to_use
      from public.match_reliability_terms terms
      where terms.match_kind = 'CLAN'
        and terms.fixture_id = new.id;
      if terms_to_use.id is null then
        raise exception 'This fixture has no frozen reliability contract. Retry after refreshing.';
      end if;
      if new.home_charge_policy_version_id is distinct from
        terms_to_use.policy_version_id
      then
        raise exception 'This fixture has inconsistent payment terms and cannot accept another clan.';
      end if;
      quote := public.clan_fixture_charge_quote_from_snapshot(
        new.away_clan_id,
        terms_to_use.policy_version_id,
        terms_to_use.policy_snapshot
      );
    end if;
    new.away_base_amount_fils := (quote ->> 'base_amount_fils')::integer;
    new.away_reliability_deposit_fils :=
      (quote ->> 'reliability_deposit_fils')::integer;
    new.away_amount_paid_fils := (quote ->> 'total_fils')::integer;
    new.away_charge_policy_version_id := (quote ->> 'policy_version_id')::uuid;
    new.away_deposit_status := case
      when new.away_reliability_deposit_fils > 0 then 'HELD'
      else 'NOT_REQUIRED'
    end;
  end if;
  return new;
end;
$$;

-- Legacy paid fixtures keep their original zero-deposit amount, but attach the
-- already-bound match policy so any later AWAY checkout uses the same contract.
update public.fixtures fixture
set
  home_charge_policy_version_id = case
    when fixture.home_paid_by is not null
      then terms.policy_version_id
    else fixture.home_charge_policy_version_id
  end,
  away_charge_policy_version_id = case
    when fixture.away_paid_by is not null
      then terms.policy_version_id
    else fixture.away_charge_policy_version_id
  end
from public.match_reliability_terms terms
where terms.match_kind = 'CLAN'
  and terms.fixture_id = fixture.id
  and (
    (fixture.home_paid_by is not null and fixture.home_charge_policy_version_id is null)
    or (fixture.away_paid_by is not null and fixture.away_charge_policy_version_id is null)
  );

alter table public.fixtures
drop constraint if exists fixtures_clan_charge_policy_consistency_check;
alter table public.fixtures
add constraint fixtures_clan_charge_policy_consistency_check check (
  away_charge_policy_version_id is null
  or (
    home_charge_policy_version_id is not null
    and away_charge_policy_version_id = home_charge_policy_version_id
  )
);

drop trigger if exists snapshot_clan_fixture_charge on public.fixtures;
create trigger snapshot_clan_fixture_charge
before insert or update of home_clan_id, away_clan_id, match_date, time_slot
on public.fixtures
for each row execute function public.snapshot_clan_fixture_charge();

alter table public.fixtures
drop constraint if exists fixtures_cancellation_code_check;
alter table public.fixtures
add constraint fixtures_cancellation_code_check check (
  cancellation_code is null
  or cancellation_code in (
    'NO_OPPONENT_24H', 'CLAN_ARCHIVED', 'SLOT_CONFLICT_MIGRATION',
    'CLAN_CANCELLED', 'ADMIN_CANCELLED', 'WEATHER_OR_VENUE',
    'SAFETY', 'NO_REFEREE', 'INSUFFICIENT_PLAYERS', 'TECHNICAL',
    'MATCH_ABANDONED', 'ADMIN_DECISION', 'LEGACY_OTHER'
  )
);

create or replace function public.clan_fixture_cancellation_quote(
  fixture_id_to_use uuid,
  actor_profile_id_to_use uuid,
  server_now_to_use timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_use public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  cancelling_clan_id uuid;
  cancelling_side text;
  payer_id uuid;
  opponent_payer_id uuid;
  base_amount_fils integer;
  deposit_amount_fils integer;
  opponent_base_amount_fils integer;
  opponent_deposit_amount_fils integer;
  opponent_deposit_status text;
  opponent_existing_refund_fils integer;
  opponent_fee_refund_fils integer;
  opponent_deposit_refund_fils integer;
  opponent_total_refund_fils integer;
  early_hours numeric;
  late_hours numeric;
  hours_before numeric;
  band_to_use text;
  outcome_to_use text;
  rule_to_use jsonb;
  refund_bps_to_use integer;
  strike_delta_to_use integer;
  deposit_forfeited boolean;
  fee_refund_fils integer;
  deposit_refund_fils integer;
  creates_forfeit boolean;
begin
  select * into fixture_to_use from public.fixtures
  where id = fixture_id_to_use;
  if fixture_to_use.id is null then raise exception 'Clan match not found.'; end if;

  if public.is_clan_manager(fixture_to_use.home_clan_id, actor_profile_id_to_use) then
    cancelling_clan_id := fixture_to_use.home_clan_id;
    cancelling_side := 'HOME';
    payer_id := fixture_to_use.home_paid_by;
    opponent_payer_id := fixture_to_use.away_paid_by;
    base_amount_fils := fixture_to_use.home_base_amount_fils;
    deposit_amount_fils := fixture_to_use.home_reliability_deposit_fils;
    opponent_base_amount_fils := coalesce(
      fixture_to_use.away_base_amount_fils, 0
    );
    opponent_deposit_amount_fils :=
      fixture_to_use.away_reliability_deposit_fils;
    opponent_deposit_status := fixture_to_use.away_deposit_status;
    opponent_existing_refund_fils := fixture_to_use.away_refund_amount_fils;
  elsif fixture_to_use.away_clan_id is not null
    and public.is_clan_manager(fixture_to_use.away_clan_id, actor_profile_id_to_use)
  then
    cancelling_clan_id := fixture_to_use.away_clan_id;
    cancelling_side := 'AWAY';
    payer_id := fixture_to_use.away_paid_by;
    opponent_payer_id := fixture_to_use.home_paid_by;
    base_amount_fils := fixture_to_use.away_base_amount_fils;
    deposit_amount_fils := fixture_to_use.away_reliability_deposit_fils;
    opponent_base_amount_fils := coalesce(
      fixture_to_use.home_base_amount_fils, 0
    );
    opponent_deposit_amount_fils :=
      fixture_to_use.home_reliability_deposit_fils;
    opponent_deposit_status := fixture_to_use.home_deposit_status;
    opponent_existing_refund_fils := fixture_to_use.home_refund_amount_fils;
  else
    raise exception 'Only a participating clan owner or leader can cancel this match.';
  end if;

  terms_to_use := public.ensure_match_reliability_terms('CLAN', fixture_to_use.id);
  early_hours := (terms_to_use.policy_snapshot #>>
    '{clan,cancellations,early,minimumHoursBeforeKickoff}')::numeric;
  late_hours := (terms_to_use.policy_snapshot #>>
    '{clan,cancellations,late,minimumHoursBeforeKickoff}')::numeric;
  hours_before := extract(epoch from (terms_to_use.kickoff_at - server_now_to_use)) / 3600;

  if server_now_to_use >= terms_to_use.kickoff_at then
    band_to_use := 'afterKickoff';
    outcome_to_use := 'NO_SHOW';
  elsif hours_before >= early_hours then
    band_to_use := 'early';
    outcome_to_use := 'CANCELLED_EARLY';
  elsif hours_before >= late_hours then
    band_to_use := 'late';
    outcome_to_use := 'CANCELLED_LATE';
  else
    band_to_use := 'veryLate';
    outcome_to_use := 'CANCELLED_VERY_LATE';
  end if;
  rule_to_use := terms_to_use.policy_snapshot #>
    array['clan', 'cancellations', band_to_use];
  refund_bps_to_use := (rule_to_use ->> 'refundBps')::integer;
  strike_delta_to_use := (rule_to_use ->> 'strikes')::integer;
  select exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #>
        '{clan,reliabilityDeposit,forfeitOutcomes}'
    ) forfeited(outcome)
    where forfeited.outcome = outcome_to_use
  ) into deposit_forfeited;
  deposit_forfeited := deposit_amount_fils > 0 and deposit_forfeited;
  fee_refund_fils := (
    coalesce(base_amount_fils, 20000)::bigint * refund_bps_to_use / 10000
  )::integer;
  deposit_refund_fils := case when deposit_forfeited then 0
    else coalesce(deposit_amount_fils, 0) end;
  creates_forfeit := band_to_use = 'afterKickoff'
    and coalesce((rule_to_use ->> 'forfeit')::boolean, false)
    and fixture_to_use.away_clan_id is not null;
  opponent_fee_refund_fils := greatest(
    0,
    opponent_base_amount_fils - least(
      opponent_base_amount_fils,
      coalesce(opponent_existing_refund_fils, 0)
    )
  );
  opponent_deposit_refund_fils := case
    when opponent_deposit_status = 'RETURNED' then 0
    else coalesce(opponent_deposit_amount_fils, 0)
  end;
  opponent_total_refund_fils := opponent_fee_refund_fils +
    opponent_deposit_refund_fils;

  return jsonb_build_object(
    'can_cancel', fixture_to_use.status in ('OPEN', 'SCHEDULED', 'LIVE')
      and not exists (
        select 1 from public.clan_fixture_cancellations cancellation
        where cancellation.fixture_id = fixture_to_use.id
      ),
    'attendance_finalized', exists (
      select 1 from public.clan_match_reliability_outcomes outcome
      where outcome.fixture_id = fixture_to_use.id
    ),
    'cannot_cancel_reason', case
      when fixture_to_use.status not in ('OPEN', 'SCHEDULED', 'LIVE') then
        'This clan match can no longer be cancelled.'
      else null
    end,
    'server_now', server_now_to_use,
    'policy_version_id', terms_to_use.policy_version_id,
    'cancelling_clan_id', cancelling_clan_id,
    'cancelling_side', cancelling_side,
    'payer_profile_id', payer_id,
    'opponent_payer_profile_id', opponent_payer_id,
    'cancellation_band', band_to_use,
    'outcome_code', outcome_to_use,
    'strike_delta', strike_delta_to_use,
    'refund_bps', refund_bps_to_use,
    'fee_refund_fils', fee_refund_fils,
    'deposit_refund_fils', deposit_refund_fils,
    'refund_amount_fils', fee_refund_fils + deposit_refund_fils,
    'deposit_forfeited', deposit_forfeited,
    'opponent_fee_refund_fils', opponent_fee_refund_fils,
    'opponent_deposit_refund_fils', opponent_deposit_refund_fils,
    'opponent_refund_amount_fils', opponent_total_refund_fils,
    'opponent_total_refunded_fils', opponent_base_amount_fils +
      opponent_deposit_amount_fils,
    'creates_forfeit', creates_forfeit,
    'forfeit_score', (terms_to_use.policy_snapshot #>>
      '{clan,forfeitScore}')::integer,
    'kickoff_at', terms_to_use.kickoff_at,
    'currency', 'BHD'
  );
end;
$$;

create or replace function public.preview_clan_fixture_cancellation(
  fixture_id_to_use uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  return public.clan_fixture_cancellation_quote(
    fixture_id_to_use,
    auth.uid(),
    clock_timestamp()
  ) - 'payer_profile_id' - 'opponent_payer_profile_id';
end;
$$;

create or replace function public.resolve_clan_cancellation_attendance(
  fixture_id_to_use uuid,
  cancelling_clan_id_to_use uuid,
  after_kickoff_to_use boolean,
  actor_profile_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  attendance_to_use public.match_attendance_records%rowtype;
  no_show_rule jsonb;
  outcome_to_use text;
  strike_delta_to_use integer;
  resolved_count integer := 0;
begin
  terms_to_use := public.ensure_match_reliability_terms('CLAN', fixture_id_to_use);
  perform public.initialize_fixture_reliability_roster(fixture_id_to_use);
  perform public.ensure_match_attendance_records('CLAN', fixture_id_to_use);
  no_show_rule := terms_to_use.policy_snapshot #> '{solo,outcomes,noShow}';

  for attendance_to_use in
    select * from public.match_attendance_records attendance
    where attendance.terms_id = terms_to_use.id
      and attendance.expected_for_match
      and attendance.outcome is null
    order by attendance.id
    for update
  loop
    outcome_to_use := case
      when after_kickoff_to_use
        and attendance_to_use.clan_id = cancelling_clan_id_to_use
        then 'NO_SHOW'
      else 'EXCUSED'
    end;
    strike_delta_to_use := case when outcome_to_use = 'NO_SHOW'
      then (no_show_rule ->> 'strikes')::integer else 0 end;

    update public.match_attendance_records set
      cancelled_at = clock_timestamp(),
      outcome = outcome_to_use,
      strike_delta = strike_delta_to_use,
      refund_bps = 0,
      refund_amount_fils = 0,
      positive_sr_multiplier_bps = 10000,
      negative_sr_multiplier_bps = 10000,
      finalized_at = clock_timestamp(),
      appeal_due_at = case when strike_delta_to_use > 0 then
        clock_timestamp() + make_interval(hours =>
          (terms_to_use.policy_snapshot #>>
            '{attendance,appealWindowHours}')::integer)
        else null end,
      consequence_snapshot = jsonb_build_object(
        'outcome_code', outcome_to_use,
        'strike_delta', strike_delta_to_use,
        'source', 'CLAN_CANCELLATION',
        'cancelled_by', actor_profile_id_to_use,
        'policy_version_id', terms_to_use.policy_version_id
      )
    where id = attendance_to_use.id
    returning * into attendance_to_use;

    insert into public.attendance_events (
      attendance_id, event_type, event_at, detail, idempotency_key
    ) values (
      attendance_to_use.id, 'CANCELLED', clock_timestamp(),
      attendance_to_use.consequence_snapshot,
      'clan-cancelled:' || attendance_to_use.id::text
    ) on conflict (idempotency_key) do nothing;

    if strike_delta_to_use > 0 then
      perform public.record_reliability_incident(
        attendance_to_use.id,
        outcome_to_use,
        strike_delta_to_use,
        attendance_to_use.finalized_at
      );
    end if;
    resolved_count := resolved_count + 1;
  end loop;
  return resolved_count;
end;
$$;

-- A clan attendance outcome may already have recorded one strike before a
-- later whole-clan cancellation requires a two-strike total. Reliability
-- incidents are append-only, so add only the missing delta instead of mutating
-- the original evidence row. A null fixture_id avoids the legacy one-row-per-
-- fixture index; the immutable cancellation id in detail is the idempotency
-- key and retains the exact fixture relationship.
create or replace function public.record_clan_cancellation_reliability_incident(
  fixture_id_to_use uuid,
  clan_id_to_use uuid,
  outcome_to_use text,
  target_strike_delta_to_use integer,
  cancellation_id_to_use uuid,
  occurred_at_to_use timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  primary_incident_id uuid;
  supplemental_incident_id uuid;
  strikes_already_recorded integer;
  supplemental_delta integer;
  active_before integer;
  active_after integer;
  strike_lifetime_days integer;
  deposit_threshold integer;
  sanction_rule jsonb;
  threshold_to_use integer;
  sanction_kind_to_use text;
  duration_days_to_use integer;
  sanction_id_to_use uuid;
begin
  if target_strike_delta_to_use <= 0 then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended(clan_id_to_use::text, 9175));

  select incident.id into supplemental_incident_id
  from public.reliability_incidents incident
  where incident.subject_type = 'CLAN'
    and incident.clan_id = clan_id_to_use
    and incident.reversal_of is null
    and incident.detail ->> 'clan_cancellation_id' =
      cancellation_id_to_use::text;
  if supplemental_incident_id is not null then
    return supplemental_incident_id;
  end if;

  primary_incident_id := public.record_clan_reliability_incident(
    fixture_id_to_use,
    clan_id_to_use,
    outcome_to_use,
    target_strike_delta_to_use,
    occurred_at_to_use
  );
  select coalesce(sum(incident.strike_delta), 0)::integer
  into strikes_already_recorded
  from public.reliability_incidents incident
  where incident.subject_type = 'CLAN'
    and incident.clan_id = clan_id_to_use
    and incident.reversal_of is null
    and (
      incident.fixture_id = fixture_id_to_use
      or incident.detail ->> 'fixture_id' = fixture_id_to_use::text
    );
  supplemental_delta := greatest(
    0,
    target_strike_delta_to_use - strikes_already_recorded
  );
  if supplemental_delta = 0 then return primary_incident_id; end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.match_kind = 'CLAN' and terms.fixture_id = fixture_id_to_use;
  active_before := public.active_clan_reliability_strikes(
    clan_id_to_use,
    occurred_at_to_use
  );
  active_after := active_before + supplemental_delta;
  strike_lifetime_days := (terms_to_use.policy_snapshot #>>
    '{attendance,strikeLifetimeDays}')::integer;
  deposit_threshold := (terms_to_use.policy_snapshot #>>
    '{clan,reliabilityDeposit,activeStrikeThreshold}')::integer;

  insert into public.reliability_incidents (
    subject_type, clan_id, fixture_id, outcome, strike_delta, occurred_at,
    expires_at, policy_version_id, active_count_before, active_count_after,
    detail
  ) values (
    'CLAN', clan_id_to_use, null, upper(trim(outcome_to_use)) || '_TOP_UP',
    supplemental_delta, occurred_at_to_use,
    occurred_at_to_use + make_interval(days => strike_lifetime_days),
    terms_to_use.policy_version_id, active_before, active_after,
    jsonb_build_object(
      'source', 'CLAN_CANCELLATION_TOP_UP',
      'fixture_id', fixture_id_to_use,
      'clan_cancellation_id', cancellation_id_to_use,
      'target_fixture_strikes', target_strike_delta_to_use,
      'strikes_before_top_up', strikes_already_recorded,
      'deposit_required', active_after >= deposit_threshold,
      'deposit_bps', (terms_to_use.policy_snapshot #>>
        '{clan,reliabilityDeposit,depositBps}')::integer
    )
  ) returning id into supplemental_incident_id;

  select value into sanction_rule
  from jsonb_array_elements(terms_to_use.policy_snapshot #> '{clan,sanctions}')
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
      subject_type, clan_id, incident_id, policy_version_id, threshold,
      sanction_kind, starts_at, ends_at, release_future_bookings
    ) values (
      'CLAN', clan_id_to_use, supplemental_incident_id,
      terms_to_use.policy_version_id, threshold_to_use,
      sanction_kind_to_use, occurred_at_to_use,
      case when sanction_kind_to_use in ('WARNING', 'INDEFINITE_SUSPENSION')
        then null
        else occurred_at_to_use + make_interval(days => duration_days_to_use)
      end,
      false
    ) returning id into sanction_id_to_use;
  end if;

  insert into public.notifications (
    recipient_profile_id, type, title, body, related_entity_type,
    related_entity_id, data
  )
  select member.profile_id, 'CLAN_RELIABILITY_OUTCOME',
    'Clan cancellation reliability outcome updated',
    'This cancellation added ' || supplemental_delta ||
      case when supplemental_delta = 1 then ' additional clan strike.'
        else ' additional clan strikes.' end,
    'CLAN_RELIABILITY_INCIDENT', supplemental_incident_id,
    jsonb_build_object(
      'fixture_id', fixture_id_to_use,
      'clan_id', clan_id_to_use,
      'active_strikes', active_after,
      'target_fixture_strikes', target_strike_delta_to_use,
      'sanction_id', sanction_id_to_use
    )
  from public.clan_members member
  where member.clan_id = clan_id_to_use
    and member.left_at is null
    and member.role in ('owner', 'leader');
  return supplemental_incident_id;
end;
$$;

create or replace function public.cancel_clan_fixture_booking(
  fixture_id_to_cancel uuid,
  reason_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  fixture_to_cancel public.fixtures%rowtype;
  quote jsonb;
  terms_to_use public.match_reliability_terms%rowtype;
  cancelling_clan_id uuid;
  cancelling_side text;
  opponent_clan_id uuid;
  payer_id uuid;
  opponent_payer_id uuid;
  refund_amount integer;
  fee_refund integer;
  deposit_refund integer;
  opponent_refund integer;
  opponent_fee_refund integer;
  opponent_deposit_refund integer;
  opponent_total_refunded integer;
  strike_delta integer;
  cancellation_id uuid;
  forfeit_score integer;
  home_delta integer;
  away_delta integer;
  winner_id uuid;
  incident_id uuid;
begin
  if user_id is null then raise exception 'You need to sign in again.'; end if;
  if char_length(trim(coalesce(reason_to_use, ''))) not between 5 and 1000 then
    raise exception 'Add a short reason for cancelling this match.';
  end if;

  select * into fixture_to_cancel from public.fixtures
  where id = fixture_id_to_cancel
  for update;
  if fixture_to_cancel.id is null then raise exception 'Clan match not found.'; end if;

  quote := public.clan_fixture_cancellation_quote(
    fixture_to_cancel.id,
    user_id,
    clock_timestamp()
  );
  if not (quote ->> 'can_cancel')::boolean then
    raise exception '%', coalesce(
      quote ->> 'cannot_cancel_reason',
      'This clan match can no longer be cancelled.'
    );
  end if;

  terms_to_use := public.ensure_match_reliability_terms('CLAN', fixture_to_cancel.id);
  cancelling_clan_id := (quote ->> 'cancelling_clan_id')::uuid;
  cancelling_side := quote ->> 'cancelling_side';
  opponent_clan_id := case when cancelling_side = 'HOME'
    then fixture_to_cancel.away_clan_id else fixture_to_cancel.home_clan_id end;
  payer_id := nullif(quote ->> 'payer_profile_id', '')::uuid;
  opponent_payer_id := nullif(quote ->> 'opponent_payer_profile_id', '')::uuid;
  refund_amount := (quote ->> 'refund_amount_fils')::integer;
  fee_refund := (quote ->> 'fee_refund_fils')::integer;
  deposit_refund := (quote ->> 'deposit_refund_fils')::integer;
  opponent_refund := (quote ->> 'opponent_refund_amount_fils')::integer;
  opponent_fee_refund := (quote ->> 'opponent_fee_refund_fils')::integer;
  opponent_deposit_refund :=
    (quote ->> 'opponent_deposit_refund_fils')::integer;
  opponent_total_refunded :=
    (quote ->> 'opponent_total_refunded_fils')::integer;
  strike_delta := (quote ->> 'strike_delta')::integer;

  insert into public.clan_fixture_cancellations (
    fixture_id, cancelling_clan_id, cancelled_by, cancellation_band,
    outcome, strike_delta, refund_bps, refund_amount_fils,
    deposit_forfeited, opponent_refund_amount_fils, creates_forfeit,
    policy_version_id, policy_snapshot, reason
  ) values (
    fixture_to_cancel.id, cancelling_clan_id, user_id,
    quote ->> 'cancellation_band', quote ->> 'outcome_code', strike_delta,
    (quote ->> 'refund_bps')::integer, refund_amount,
    (quote ->> 'deposit_forfeited')::boolean, opponent_refund,
    (quote ->> 'creates_forfeit')::boolean, terms_to_use.policy_version_id,
    terms_to_use.policy_snapshot, trim(reason_to_use)
  ) returning id into cancellation_id;

  if fee_refund > 0 and payer_id is not null then
    perform public.credit_field_wallet(
      payer_id, fee_refund, 'BOOKING_REFUND',
      'clan-cancel-fee-refund:' || fixture_to_cancel.id::text || ':' ||
        cancelling_clan_id::text,
      'Clan fixture fee refund credited to Field Wallet.',
      terms_to_use.policy_version_id, null, null, quote
    );
  end if;
  if deposit_refund > 0 and payer_id is not null then
    perform public.credit_field_wallet(
      payer_id, deposit_refund, 'RELIABILITY_DEPOSIT_RETURN',
      'clan-cancel-deposit-return:' || fixture_to_cancel.id::text || ':' ||
        cancelling_clan_id::text,
      'Clan reliability deposit returned after an eligible cancellation.',
      terms_to_use.policy_version_id, null, null, quote
    );
  end if;
  if opponent_fee_refund > 0 and opponent_payer_id is not null then
    perform public.credit_field_wallet(
      opponent_payer_id, opponent_fee_refund, 'FIELD_CANCELLATION_REFUND',
      'clan-opponent-fee-refund:' || fixture_to_cancel.id::text || ':' ||
        opponent_clan_id::text,
      'Clan match fee returned because the opposing clan cancelled.',
      terms_to_use.policy_version_id, null, null, quote
    );
  end if;
  if opponent_deposit_refund > 0 and opponent_payer_id is not null then
    perform public.credit_field_wallet(
      opponent_payer_id, opponent_deposit_refund,
      'RELIABILITY_DEPOSIT_RETURN',
      'clan-opponent-deposit-return:' || fixture_to_cancel.id::text || ':' ||
        opponent_clan_id::text,
      'Clan reliability deposit returned because the opponent cancelled.',
      terms_to_use.policy_version_id, null, null, quote
    );
  end if;

  if cancelling_side = 'HOME' then
    update public.fixtures set
      home_refund_bps = (quote ->> 'refund_bps')::integer,
      home_refund_amount_fils = refund_amount,
      home_deposit_status = case
        when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when (quote ->> 'deposit_forfeited')::boolean then 'FORFEITED'
        else 'RETURNED' end,
      away_refund_bps = case when away_clan_id is null then 0 else 10000 end,
      away_refund_amount_fils = opponent_total_refunded,
      away_deposit_status = case
        when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        else 'RETURNED' end
    where id = fixture_to_cancel.id;
  else
    update public.fixtures set
      away_refund_bps = (quote ->> 'refund_bps')::integer,
      away_refund_amount_fils = refund_amount,
      away_deposit_status = case
        when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        when (quote ->> 'deposit_forfeited')::boolean then 'FORFEITED'
        else 'RETURNED' end,
      home_refund_bps = 10000,
      home_refund_amount_fils = opponent_total_refunded,
      home_deposit_status = case
        when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
        else 'RETURNED' end
    where id = fixture_to_cancel.id;
  end if;

  incident_id := public.record_clan_cancellation_reliability_incident(
    fixture_to_cancel.id,
    cancelling_clan_id,
    quote ->> 'outcome_code',
    strike_delta,
    cancellation_id,
    clock_timestamp()
  );

  perform public.resolve_clan_cancellation_attendance(
    fixture_to_cancel.id,
    cancelling_clan_id,
    (quote ->> 'cancellation_band') = 'afterKickoff',
    user_id
  );

  if (quote ->> 'creates_forfeit')::boolean then
    forfeit_score := (quote ->> 'forfeit_score')::integer;
    select delta.home_change, delta.away_change into home_delta, away_delta
    from public.calculate_fixture_sr_delta(
      (select skill_rating from public.clans where id = fixture_to_cancel.home_clan_id),
      (select skill_rating from public.clans where id = fixture_to_cancel.away_clan_id),
      case when cancelling_side = 'HOME' then 0 else forfeit_score end,
      case when cancelling_side = 'AWAY' then 0 else forfeit_score end
    ) delta;
    winner_id := opponent_clan_id;

    -- A cancellation forfeit is an official clan result, but nobody earns or
    -- loses Player SR for a game that did not take place.
    update public.fixture_player_appearances
    set played = false, rating_change = null
    where fixture_id = fixture_to_cancel.id;

    update public.clans set
      skill_rating = greatest(0, skill_rating + home_delta),
      wins = wins + case when id = winner_id then 1 else 0 end,
      losses = losses + case when id = cancelling_clan_id then 1 else 0 end
    where id = fixture_to_cancel.home_clan_id;
    update public.clans set
      skill_rating = greatest(0, skill_rating + away_delta),
      wins = wins + case when id = winner_id then 1 else 0 end,
      losses = losses + case when id = cancelling_clan_id then 1 else 0 end
    where id = fixture_to_cancel.away_clan_id;

    update public.fixtures set
      status = 'FINAL',
      home_score = case when cancelling_side = 'HOME' then 0 else forfeit_score end,
      away_score = case when cancelling_side = 'AWAY' then 0 else forfeit_score end,
      winner_clan_id = winner_id,
      home_sr_change = home_delta,
      away_sr_change = away_delta,
      cancellation_context = coalesce(cancellation_context, '{}'::jsonb) ||
        jsonb_build_object(
          'reliability_forfeit_without_play', true,
          'clan_cancellation_id', cancellation_id,
          'reliability_policy_version_id', terms_to_use.policy_version_id,
          'cancelled_by', user_id,
          'cancelling_clan_id', cancelling_clan_id
        )
    where id = fixture_to_cancel.id;

    update public.fixture_clock_states
    set
      accumulated_seconds = least(
        10800,
        accumulated_seconds + case when started_at is null then 0 else
          greatest(0, extract(epoch from (
            clock_timestamp() - started_at
          ))::integer) end
      ),
      status = 'ENDED',
      started_at = null
    where fixture_id = fixture_to_cancel.id;
    update public.fixture_blue_cards
    set status = 'CLEARED'
    where fixture_id = fixture_to_cancel.id and status = 'ACTIVE';

    update public.broadcast_commands
    set
      status = 'FAILED',
      completed_at = clock_timestamp(),
      error_message = 'Match ended by an official cancellation forfeit.'
    where fixture_id = fixture_to_cancel.id
      and action = 'START_STREAM'
      and status in ('PENDING', 'CLAIMED');
    insert into public.broadcast_commands (
      fixture_id, device_key, action, requested_by, available_at
    )
    select fixture_to_cancel.id, device.device_key, 'STOP_STREAM', user_id,
      clock_timestamp()
    from public.broadcast_devices device
    where device.current_fixture_id = fixture_to_cancel.id
    on conflict do nothing;
    update public.fixture_broadcasts
    set status = 'STOPPING', stream_stopped_at = clock_timestamp()
    where fixture_id = fixture_to_cancel.id
      and status in ('STARTING', 'LIVE');

    insert into public.fixture_events (
      fixture_id, event_type, clan_id, note, occurred_at
    ) values (
      fixture_to_cancel.id, 'CORRECTION', winner_id,
      'Official ' || forfeit_score || '-0 forfeit after the opposing clan cancelled at or after kickoff.',
      clock_timestamp()
    );
  else
    update public.fixtures set
      status = 'CANCELLED',
      cancellation_code = 'CLAN_CANCELLED',
      cancellation_reason = trim(reason_to_use),
      cancelled_at = clock_timestamp(),
      cancelled_by = user_id,
      cancellation_context = quote
    where id = fixture_to_cancel.id;
  end if;

  insert into public.notifications (
    recipient_profile_id, type, title, body,
    related_entity_type, related_entity_id, data
  )
  select member.profile_id,
    'CLAN_FIXTURE_CANCELLED',
    case when member.clan_id = cancelling_clan_id
      then 'Clan match cancellation recorded'
      else 'Opponent cancelled the clan match' end,
    case when member.clan_id = cancelling_clan_id
      then 'The policy result, strikes and Field Wallet refund are ready to review.'
      else 'The original payer received a full Field Wallet refund.' end,
    'CLAN_MATCH', fixture_to_cancel.id, quote
  from public.clan_members member
  where member.left_at is null
    and member.role in ('owner', 'leader')
    and member.clan_id in (cancelling_clan_id, opponent_clan_id);

  return (quote - 'payer_profile_id' - 'opponent_payer_profile_id') ||
    jsonb_build_object(
    'final_status', case when (quote ->> 'creates_forfeit')::boolean
      then 'FINAL' else 'CANCELLED' end,
    'incident_id', incident_id
  );
end;
$$;

revoke all on function public.clan_fixture_charge_quote(uuid, timestamptz, timestamptz)
from public, anon, authenticated;
revoke all on function public.clan_fixture_charge_quote_from_snapshot(
  uuid, uuid, jsonb, timestamptz
) from public, anon, authenticated;
revoke all on function public.clan_fixture_cancellation_quote(uuid, uuid, timestamptz)
from public, anon, authenticated;
revoke all on function public.snapshot_clan_fixture_charge()
from public, anon, authenticated;
revoke all on function public.preview_create_clan_fixture_charge(uuid, date, text)
from public, anon, authenticated;
revoke all on function public.preview_join_clan_fixture_charge(uuid, uuid)
from public, anon, authenticated;
revoke all on function public.preview_clan_fixture_cancellation(uuid)
from public, anon, authenticated;
revoke all on function public.cancel_clan_fixture_booking(uuid, text)
from public, anon, authenticated;

grant execute on function public.preview_create_clan_fixture_charge(uuid, date, text)
to authenticated;
grant execute on function public.preview_join_clan_fixture_charge(uuid, uuid)
to authenticated;
grant execute on function public.preview_clan_fixture_cancellation(uuid)
to authenticated;
grant execute on function public.cancel_clan_fixture_booking(uuid, text)
to authenticated;
grant execute on function public.clan_fixture_charge_quote(uuid, timestamptz, timestamptz)
to service_role;
grant execute on function public.clan_fixture_charge_quote_from_snapshot(
  uuid, uuid, jsonb, timestamptz
) to service_role;
grant execute on function public.clan_fixture_cancellation_quote(uuid, uuid, timestamptz)
to service_role;

comment on function public.cancel_clan_fixture_booking(uuid, text) is
'Cancels a participating clan booking with a server-timed policy outcome, clan strike, exact Field Wallet settlement, and configured post-kickoff forfeit.';

-- A clan reliability deposit is attendance security, not extra revenue. The
-- snapshotted policy explicitly lists which authoritative outcomes forfeit it.
-- Any other outcome, including READY, keeps it
-- held until the official match is FINAL, then returns it as Field Wallet
-- credit. This prevents a later LIVE cancellation from trying to claw back a
-- deposit that was already credited. The idempotency key also protects retries.
create or replace function public.settle_clan_reliability_deposit_from_outcome()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fixture_to_settle public.fixtures%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  payer_id uuid;
  deposit_amount integer;
  deposit_status text;
  deposit_forfeited boolean;
begin
  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = new.fixture_id
  for update;

  if new.side = 'HOME' then
    payer_id := fixture_to_settle.home_paid_by;
    deposit_amount := fixture_to_settle.home_reliability_deposit_fils;
    deposit_status := fixture_to_settle.home_deposit_status;
  else
    payer_id := fixture_to_settle.away_paid_by;
    deposit_amount := fixture_to_settle.away_reliability_deposit_fils;
    deposit_status := fixture_to_settle.away_deposit_status;
  end if;

  if deposit_amount <= 0 or deposit_status <> 'HELD' then
    return new;
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = new.terms_id;
  if terms_to_use.id is null then
    raise exception 'The clan reliability policy snapshot is missing.';
  end if;
  select exists (
    select 1
    from jsonb_array_elements_text(
      terms_to_use.policy_snapshot #>
        '{clan,reliabilityDeposit,forfeitOutcomes}'
    ) forfeited(outcome)
    where forfeited.outcome = new.outcome
  ) into deposit_forfeited;

  -- READY proves attendance, but keep the deposit held until the official
  -- fixture is FINAL. A clan may still cancel a LIVE match later, in which case
  -- the held deposit must remain available to forfeit. Outcomes selected in the
  -- snapshotted forfeit list settle immediately.
  if not deposit_forfeited and fixture_to_settle.status <> 'FINAL' then
    return new;
  end if;

  if not deposit_forfeited then
    if payer_id is null then
      raise exception 'The % clan reliability deposit has no original payer.',
        lower(new.side);
    end if;
    perform public.credit_field_wallet(
      payer_id,
      deposit_amount,
      'RELIABILITY_DEPOSIT_RETURN',
      'clan-deposit-return:' || new.fixture_id::text || ':' || new.side,
      'Clan reliability deposit returned after attendance was confirmed.',
      new.policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', new.fixture_id,
        'clan_id', new.clan_id,
        'side', new.side,
        'attendance_outcome', new.outcome,
        'clan_reliability_outcome_id', new.id
      )
    );
  end if;

  if new.side = 'HOME' then
    update public.fixtures set home_deposit_status = case
      when deposit_forfeited then 'FORFEITED' else 'RETURNED' end
    where id = new.fixture_id and home_deposit_status = 'HELD';
  else
    update public.fixtures set away_deposit_status = case
      when deposit_forfeited then 'FORFEITED' else 'RETURNED' end
    where id = new.fixture_id and away_deposit_status = 'HELD';
  end if;
  return new;
end;
$$;

drop trigger if exists settle_clan_reliability_deposit_from_outcome
on public.clan_match_reliability_outcomes;
create trigger settle_clan_reliability_deposit_from_outcome
after insert on public.clan_match_reliability_outcomes
for each row execute function public.settle_clan_reliability_deposit_from_outcome();

-- Administrative, venue, safety and automatic underfilled cancellations are
-- Field-caused. Both original payers receive the complete captured amount,
-- including any reliability deposit, and unresolved expected attendance is
-- closed without strikes. Clan-initiated cancellations use the policy-specific
-- RPC above and are intentionally excluded.
create or replace function public.settle_field_cancelled_clan_fixture()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  fixture_to_settle public.fixtures%rowtype;
  attendance_to_close public.match_attendance_records%rowtype;
  kickoff_at_to_use timestamptz;
  missing_home_fee_refund integer := 0;
  missing_away_fee_refund integer := 0;
  missing_home_deposit_refund integer := 0;
  missing_away_deposit_refund integer := 0;
begin
  if new.status <> 'CANCELLED'
    or old.status = 'CANCELLED'
    or new.cancellation_code = 'CLAN_CANCELLED'
  then
    return new;
  end if;

  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = new.id
  for update;

  missing_home_fee_refund := greatest(
    0,
    coalesce(fixture_to_settle.home_base_amount_fils, 0) - least(
      coalesce(fixture_to_settle.home_base_amount_fils, 0),
      coalesce(fixture_to_settle.home_refund_amount_fils, 0)
    )
  );
  missing_away_fee_refund := greatest(
    0,
    coalesce(fixture_to_settle.away_base_amount_fils, 0) - least(
      coalesce(fixture_to_settle.away_base_amount_fils, 0),
      coalesce(fixture_to_settle.away_refund_amount_fils, 0)
    )
  );
  missing_home_deposit_refund := case
    when fixture_to_settle.home_deposit_status = 'RETURNED' then 0
    else fixture_to_settle.home_reliability_deposit_fils
  end;
  missing_away_deposit_refund := case
    when fixture_to_settle.away_deposit_status = 'RETURNED' then 0
    else fixture_to_settle.away_reliability_deposit_fils
  end;

  if fixture_to_settle.home_paid_by is not null
    and missing_home_fee_refund > 0
  then
    perform public.credit_field_wallet(
      fixture_to_settle.home_paid_by,
      missing_home_fee_refund,
      'FIELD_CANCELLATION_REFUND',
      'field-clan-cancel-fee:' || new.id::text || ':HOME',
      'Remaining clan match fee returned because Field cancelled the match.',
      fixture_to_settle.home_charge_policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', new.id,
        'side', 'HOME',
        'cancellation_code', new.cancellation_code
      )
    );
  end if;
  if fixture_to_settle.home_paid_by is not null
    and missing_home_deposit_refund > 0
  then
    perform public.credit_field_wallet(
      fixture_to_settle.home_paid_by,
      missing_home_deposit_refund,
      'RELIABILITY_DEPOSIT_RETURN',
      'field-clan-cancel-deposit:' || new.id::text || ':HOME',
      'Clan reliability deposit returned because Field cancelled the match.',
      fixture_to_settle.home_charge_policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', new.id,
        'side', 'HOME',
        'cancellation_code', new.cancellation_code
      )
    );
  end if;
  if fixture_to_settle.away_paid_by is not null
    and missing_away_fee_refund > 0
  then
    perform public.credit_field_wallet(
      fixture_to_settle.away_paid_by,
      missing_away_fee_refund,
      'FIELD_CANCELLATION_REFUND',
      'field-clan-cancel-fee:' || new.id::text || ':AWAY',
      'Remaining clan match fee returned because Field cancelled the match.',
      fixture_to_settle.away_charge_policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', new.id,
        'side', 'AWAY',
        'cancellation_code', new.cancellation_code
      )
    );
  end if;
  if fixture_to_settle.away_paid_by is not null
    and missing_away_deposit_refund > 0
  then
    perform public.credit_field_wallet(
      fixture_to_settle.away_paid_by,
      missing_away_deposit_refund,
      'RELIABILITY_DEPOSIT_RETURN',
      'field-clan-cancel-deposit:' || new.id::text || ':AWAY',
      'Clan reliability deposit returned because Field cancelled the match.',
      fixture_to_settle.away_charge_policy_version_id,
      null,
      null,
      jsonb_build_object(
        'fixture_id', new.id,
        'side', 'AWAY',
        'cancellation_code', new.cancellation_code
      )
    );
  end if;

  update public.fixtures set
    home_refund_bps = case when home_paid_by is null then home_refund_bps
      else 10000 end,
    home_refund_amount_fils = case when home_paid_by is null
      then home_refund_amount_fils else coalesce(home_amount_paid_fils, 0) end,
    home_deposit_status = case
      when home_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
      else 'RETURNED' end,
    away_refund_bps = case when away_paid_by is null then away_refund_bps
      else 10000 end,
    away_refund_amount_fils = case when away_paid_by is null
      then away_refund_amount_fils else coalesce(away_amount_paid_fils, 0) end,
    away_deposit_status = case
      when away_reliability_deposit_fils <= 0 then 'NOT_REQUIRED'
      else 'RETURNED' end
  where id = new.id;

  update public.fixture_player_appearances
  set played = false, rating_change = null
  where fixture_id = new.id;

  kickoff_at_to_use := public.fixture_start_at(new.match_date, new.time_slot);
  if exists (
    select 1 from public.reliability_policy_versions policy
    where policy.state = 'PUBLISHED'
      and policy.effective_from <= kickoff_at_to_use
  ) then
    terms_to_use := public.ensure_match_reliability_terms('CLAN', new.id);
    perform public.initialize_fixture_reliability_roster(new.id);
    perform public.ensure_match_attendance_records('CLAN', new.id);
    perform public.reverse_match_reliability_incidents_for_field_cancel(
      null,
      'CLAN',
      new.id,
      coalesce(
        nullif(trim(new.cancellation_reason), ''),
        'Field cancelled this clan match.'
      )
    );

    for attendance_to_close in
      select attendance.*
      from public.match_attendance_records attendance
      where attendance.terms_id = terms_to_use.id
        and attendance.expected_for_match
      order by attendance.id
      for update
    loop
      update public.match_attendance_records set
        cancelled_at = coalesce(new.cancelled_at, clock_timestamp()),
        outcome = 'FIELD_CANCELLED',
        strike_delta = 0,
        refund_bps = 0,
        refund_amount_fils = 0,
        positive_sr_multiplier_bps = 10000,
        negative_sr_multiplier_bps = 10000,
        finalized_at = coalesce(new.cancelled_at, clock_timestamp()),
        appeal_due_at = null,
        consequence_snapshot = consequence_snapshot || jsonb_build_object(
          'outcome_code', 'FIELD_CANCELLED',
          'source', 'FIELD_CLAN_CANCELLATION_SETTLEMENT',
          'policy_version_id', terms_to_use.policy_version_id,
          'cancellation_code', new.cancellation_code
        )
      where id = attendance_to_close.id
      returning * into attendance_to_close;

      insert into public.attendance_events (
        attendance_id, event_type, event_at, detail, idempotency_key
      ) values (
        attendance_to_close.id,
        'ADMIN_CORRECTION',
        coalesce(new.cancelled_at, clock_timestamp()),
        attendance_to_close.consequence_snapshot,
        'field-clan-cancelled:' || attendance_to_close.id::text
      ) on conflict (idempotency_key) do nothing;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists settle_field_cancelled_clan_fixture on public.fixtures;
create trigger settle_field_cancelled_clan_fixture
after update of status on public.fixtures
for each row execute function public.settle_field_cancelled_clan_fixture();

-- Return any still-held deposit on a normally completed clan match. The
-- attendance-outcome trigger above normally resolves these first; this is an
-- idempotent safety net for historical or operator-finalized paths. The same
-- FINAL transition also pays the configured base-fee refund to both original
-- payers when a verified, unreplaced injury happened before the configured
-- fraction of match duration.
create or replace function public.settle_completed_clan_fixture_finance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  terms_to_use public.match_reliability_terms%rowtype;
  fixture_to_settle public.fixtures%rowtype;
  duration_seconds_to_use integer;
  injury_refund_bps integer := 0;
  home_injury_refund integer := 0;
  away_injury_refund integer := 0;
begin
  if new.status <> 'FINAL'
    or old.status = 'FINAL'
    or new.away_clan_id is null
    or exists (
      select 1 from public.clan_fixture_cancellations cancellation
      where cancellation.fixture_id = new.id
    )
  then
    return new;
  end if;

  terms_to_use := public.ensure_match_reliability_terms('CLAN', new.id);
  if clock_timestamp() >= terms_to_use.no_show_cutoff_at
    and not exists (
      select 1 from public.clan_match_reliability_outcomes outcome
      where outcome.fixture_id = new.id
    )
  then
    perform public.initialize_fixture_reliability_roster(new.id);
    perform public.finalize_match_attendance_internal('CLAN', new.id, null);
    perform public.finalize_clan_reliability_outcomes(new.id, null);
  end if;

  -- NEW is the row image from before the outcome trigger settled either side.
  -- Re-read it so the FINAL safety net respects the snapshotted forfeit list.
  select * into fixture_to_settle
  from public.fixtures fixture
  where fixture.id = new.id
  for update;

  -- Never infer attendance from FINAL alone. A referee can end a short match
  -- before the no-show cutoff, so a deposit returns only with an authoritative
  -- clan outcome that is not selected for forfeiture. The due-attendance worker
  -- below will resolve early FINAL matches once their cutoff arrives.
  if fixture_to_settle.home_deposit_status = 'HELD'
    and fixture_to_settle.home_reliability_deposit_fils > 0
    and exists (
      select 1 from public.clan_match_reliability_outcomes outcome
      where outcome.fixture_id = new.id
        and outcome.side = 'HOME'
        and not exists (
          select 1
          from jsonb_array_elements_text(
            terms_to_use.policy_snapshot #>
              '{clan,reliabilityDeposit,forfeitOutcomes}'
          ) forfeited(value)
          where forfeited.value = outcome.outcome
        )
    )
  then
    if fixture_to_settle.home_paid_by is null then
      raise exception 'The home clan reliability deposit has no original payer.';
    end if;
    perform public.credit_field_wallet(
      fixture_to_settle.home_paid_by,
      fixture_to_settle.home_reliability_deposit_fils,
      'RELIABILITY_DEPOSIT_RETURN',
      'clan-deposit-return:' || new.id::text || ':HOME',
      'Clan reliability deposit returned after the match was completed.',
      fixture_to_settle.home_charge_policy_version_id,
      null,
      null,
      jsonb_build_object('fixture_id', new.id, 'side', 'HOME')
    );
    update public.fixtures set home_deposit_status = 'RETURNED'
    where id = new.id and home_deposit_status = 'HELD';
  end if;
  if fixture_to_settle.away_deposit_status = 'HELD'
    and fixture_to_settle.away_reliability_deposit_fils > 0
    and exists (
      select 1 from public.clan_match_reliability_outcomes outcome
      where outcome.fixture_id = new.id
        and outcome.side = 'AWAY'
        and not exists (
          select 1
          from jsonb_array_elements_text(
            terms_to_use.policy_snapshot #>
              '{clan,reliabilityDeposit,forfeitOutcomes}'
          ) forfeited(value)
          where forfeited.value = outcome.outcome
        )
    )
  then
    if fixture_to_settle.away_paid_by is null then
      raise exception 'The away clan reliability deposit has no original payer.';
    end if;
    perform public.credit_field_wallet(
      fixture_to_settle.away_paid_by,
      fixture_to_settle.away_reliability_deposit_fils,
      'RELIABILITY_DEPOSIT_RETURN',
      'clan-deposit-return:' || new.id::text || ':AWAY',
      'Clan reliability deposit returned after the match was completed.',
      fixture_to_settle.away_charge_policy_version_id,
      null,
      null,
      jsonb_build_object('fixture_id', new.id, 'side', 'AWAY')
    );
    update public.fixtures set away_deposit_status = 'RETURNED'
    where id = new.id and away_deposit_status = 'HELD';
  end if;

  select coalesce(clock.duration_seconds, 3600)
  into duration_seconds_to_use
  from public.fixture_clock_states clock
  where clock.fixture_id = new.id;
  duration_seconds_to_use := greatest(1, coalesce(duration_seconds_to_use, 3600));

  if exists (
    select 1
    from public.match_verified_injuries injury
    where injury.terms_id = terms_to_use.id
      and injury.match_kind = 'CLAN'
      and injury.unable_to_continue
      and not injury.replacement_available
      and injury.match_second::bigint * 10000 <
        duration_seconds_to_use::bigint *
          (terms_to_use.policy_snapshot #>>
            '{injury,halfMatchThresholdBps}')::integer
  ) then
    injury_refund_bps := (terms_to_use.policy_snapshot #>>
      '{injury,incompleteRefundBps}')::integer;
    home_injury_refund := (
      coalesce(new.home_base_amount_fils, 0)::bigint *
        injury_refund_bps / 10000
    )::integer;
    away_injury_refund := (
      coalesce(new.away_base_amount_fils, 0)::bigint *
        injury_refund_bps / 10000
    )::integer;

    if home_injury_refund > 0 and new.home_paid_by is not null then
      perform public.credit_field_wallet(
        new.home_paid_by,
        home_injury_refund,
        'FIELD_CANCELLATION_REFUND',
        'clan-injury-refund:' || new.id::text || ':HOME',
        'Clan match fee returned after a verified early-match injury.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', new.id,
          'side', 'HOME',
          'refund_bps', injury_refund_bps
        )
      );
    end if;
    if away_injury_refund > 0 and new.away_paid_by is not null then
      perform public.credit_field_wallet(
        new.away_paid_by,
        away_injury_refund,
        'FIELD_CANCELLATION_REFUND',
        'clan-injury-refund:' || new.id::text || ':AWAY',
        'Clan match fee returned after a verified early-match injury.',
        terms_to_use.policy_version_id,
        null,
        null,
        jsonb_build_object(
          'fixture_id', new.id,
          'side', 'AWAY',
          'refund_bps', injury_refund_bps
        )
      );
    end if;

    update public.fixtures set
      home_refund_bps = greatest(home_refund_bps, injury_refund_bps),
      home_refund_amount_fils = greatest(
        home_refund_amount_fils, home_injury_refund
      ),
      away_refund_bps = greatest(away_refund_bps, injury_refund_bps),
      away_refund_amount_fils = greatest(
        away_refund_amount_fils, away_injury_refund
      )
    where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists settle_completed_clan_fixture_finance
on public.fixtures;
drop trigger if exists a_settle_completed_clan_fixture_finance
on public.fixtures;
create trigger a_settle_completed_clan_fixture_finance
after update of status on public.fixtures
for each row execute function public.settle_completed_clan_fixture_finance();

-- A match can be marked FINAL before kickoff + noShowMinutesAfterKickoff. Keep
-- those normal fixtures in the due-attendance worker so their authoritative
-- outcomes and deposits settle at the cutoff. Cancellation forfeits already
-- have explicit attendance evidence and must not be reclassified by this job.
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
    where fixture.status in ('OPEN', 'SCHEDULED', 'LIVE', 'FINAL')
      and fixture.away_clan_id is not null
      and terms.no_show_cutoff_at <= clock_timestamp()
      and not coalesce(
        (fixture.cancellation_context ->>
          'reliability_forfeit_without_play')::boolean,
        false
      )
      and not exists (
        select 1 from public.clan_fixture_cancellations cancellation
        where cancellation.fixture_id = fixture.id
      )
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
        'CLAN', candidate.id, null
      );
      result_to_use := public.finalize_clan_reliability_outcomes(
        candidate.id, null
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

-- Deleting a clan must not be an alternate full-refund cancellation button.
-- Owners first resolve every active fixture through the policy-backed match
-- action, then may archive the empty clan record.
create or replace function public.archive_clan(clan_id_to_archive uuid)
returns public.clans
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  archived_clan public.clans%rowtype;
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  perform pg_advisory_xact_lock(hashtext(clan_id_to_archive::text)::bigint);

  select * into archived_clan
  from public.clans clan
  where clan.id = clan_id_to_archive
  for update;
  if archived_clan.id is null or archived_clan.archived_at is not null then
    raise exception 'This clan has already been deleted.';
  end if;
  if not public.is_clan_owner(clan_id_to_archive, auth.uid()) then
    raise exception 'Only the clan owner can delete this clan.';
  end if;
  if exists (
    select 1 from public.fixtures fixture
    where fixture.status in ('OPEN', 'SCHEDULED', 'LIVE')
      and clan_id_to_archive in (
        fixture.home_clan_id,
        fixture.away_clan_id
      )
  ) then
    raise exception 'Cancel every active clan match from Match Details before deleting this clan. Live matches must be resolved by the referee or Field admin.';
  end if;

  update public.clan_join_requests set
    status = 'CANCELLED',
    reviewed_at = clock_timestamp(),
    reviewed_by = auth.uid(),
    cancellation_code = 'CLAN_ARCHIVED',
    cancellation_reason = format(
      'Request cancelled because %s was deleted.', archived_clan.name
    ),
    cancelled_at = clock_timestamp(),
    cancelled_by = auth.uid(),
    cancellation_context = jsonb_build_object(
      'archived_clan_id', archived_clan.id,
      'archived_clan_name', archived_clan.name
    )
  where clan_id = clan_id_to_archive and status = 'PENDING';

  update public.clan_members set
    left_at = clock_timestamp(),
    removed_by = auth.uid(),
    removal_reason = 'CLAN_ARCHIVED'
  where clan_id = clan_id_to_archive and left_at is null;

  update public.clans set
    archived_at = clock_timestamp(),
    archived_by = auth.uid()
  where id = clan_id_to_archive and archived_at is null
  returning * into archived_clan;
  return archived_clan;
end;
$$;

revoke all on function public.resolve_clan_cancellation_attendance(
  uuid, uuid, boolean, uuid
) from public, anon, authenticated;
revoke all on function public.record_clan_cancellation_reliability_incident(
  uuid, uuid, text, integer, uuid, timestamptz
) from public, anon, authenticated;
revoke all on function public.settle_clan_reliability_deposit_from_outcome()
from public, anon, authenticated;
revoke all on function public.settle_field_cancelled_clan_fixture()
from public, anon, authenticated;
revoke all on function public.settle_completed_clan_fixture_finance()
from public, anon, authenticated;
