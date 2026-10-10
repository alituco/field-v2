-- Close two release-safety gaps in the reliability rollout:
--   1. fixtures are publicly browsable, so their cancellation context must
--      never retain payer IDs or private reliability-finance amounts; and
--   2. an administrator must not be able to publish a zero-day timed sanction
--      that later violates reliability_sanctions.ends_at > starts_at.

create or replace function public.redact_fixture_cancellation_context()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.cancellation_context is not null then
    new.cancellation_context := new.cancellation_context
      - 'payer_profile_id'
      - 'opponent_payer_profile_id'
      - 'fee_refund_fils'
      - 'deposit_refund_fils'
      - 'refund_amount_fils'
      - 'deposit_forfeited'
      - 'opponent_fee_refund_fils'
      - 'opponent_deposit_refund_fils'
      - 'opponent_refund_amount_fils'
      - 'opponent_total_refunded_fils';
  end if;
  return new;
end;
$$;

drop trigger if exists redact_fixture_cancellation_context
on public.fixtures;
create trigger redact_fixture_cancellation_context
before insert or update of cancellation_context on public.fixtures
for each row execute function public.redact_fixture_cancellation_context();

-- Remove any sensitive cancellation quote written before this guard existed.
update public.fixtures
set cancellation_context = cancellation_context
  - 'payer_profile_id'
  - 'opponent_payer_profile_id'
  - 'fee_refund_fils'
  - 'deposit_refund_fils'
  - 'refund_amount_fils'
  - 'deposit_forfeited'
  - 'opponent_fee_refund_fils'
  - 'opponent_deposit_refund_fils'
  - 'opponent_refund_amount_fils'
  - 'opponent_total_refunded_fils'
where cancellation_context is not null
  and cancellation_context ?| array[
    'payer_profile_id',
    'opponent_payer_profile_id',
    'fee_refund_fils',
    'deposit_refund_fils',
    'refund_amount_fils',
    'deposit_forfeited',
    'opponent_fee_refund_fils',
    'opponent_deposit_refund_fils',
    'opponent_refund_amount_fils',
    'opponent_total_refunded_fils'
  ];

revoke all on function public.redact_fixture_cancellation_context()
from public, anon, authenticated;

-- create_fixture and join_fixture predate the private reliability columns and
-- return the complete fixtures row. Keep their existing return contract for
-- compatibility, but blank every private finance field in the returned row.
-- The persisted fixture remains fully populated by snapshot_clan_fixture_charge.
do $migration$
declare
  function_definition text;
  old_text text := 'return created_fixture;';
  new_text text := $replacement$created_fixture.home_base_amount_fils := null;
  created_fixture.away_base_amount_fils := null;
  created_fixture.home_reliability_deposit_fils := null;
  created_fixture.away_reliability_deposit_fils := null;
  created_fixture.home_amount_paid_fils := null;
  created_fixture.away_amount_paid_fils := null;
  created_fixture.home_charge_policy_version_id := null;
  created_fixture.away_charge_policy_version_id := null;
  created_fixture.home_refund_bps := null;
  created_fixture.away_refund_bps := null;
  created_fixture.home_refund_amount_fils := null;
  created_fixture.away_refund_amount_fils := null;
  created_fixture.home_deposit_status := null;
  created_fixture.away_deposit_status := null;
  return created_fixture;$replacement$;
begin
  select pg_get_functiondef(
    'public.create_fixture(uuid,text,date,text)'::regprocedure
  ) into function_definition;

  if position('created_fixture.home_base_amount_fils := null' in
      lower(function_definition)) = 0
  then
    if position(old_text in lower(function_definition)) = 0 then
      raise exception 'Could not secure the create_fixture return payload.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

do $migration$
declare
  function_definition text;
  old_text text := 'return fixture_to_join;';
  new_text text := $replacement$fixture_to_join.home_base_amount_fils := null;
  fixture_to_join.away_base_amount_fils := null;
  fixture_to_join.home_reliability_deposit_fils := null;
  fixture_to_join.away_reliability_deposit_fils := null;
  fixture_to_join.home_amount_paid_fils := null;
  fixture_to_join.away_amount_paid_fils := null;
  fixture_to_join.home_charge_policy_version_id := null;
  fixture_to_join.away_charge_policy_version_id := null;
  fixture_to_join.home_refund_bps := null;
  fixture_to_join.away_refund_bps := null;
  fixture_to_join.home_refund_amount_fils := null;
  fixture_to_join.away_refund_amount_fils := null;
  fixture_to_join.home_deposit_status := null;
  fixture_to_join.away_deposit_status := null;
  return fixture_to_join;$replacement$;
begin
  select pg_get_functiondef(
    'public.join_fixture(uuid,uuid)'::regprocedure
  ) into function_definition;

  if position('fixture_to_join.home_base_amount_fils := null' in
      lower(function_definition)) = 0
  then
    if position(old_text in lower(function_definition)) = 0 then
      raise exception 'Could not secure the join_fixture return payload.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

create or replace function public.reliability_sanction_durations_are_valid(
  config_to_check jsonb
)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  sanction jsonb;
  sanction_kind text;
  duration_days integer;
begin
  if jsonb_typeof(config_to_check #> '{solo,sanctions}') <> 'array'
    or jsonb_typeof(config_to_check #> '{clan,sanctions}') <> 'array'
  then
    return false;
  end if;

  for sanction in
    select value
    from jsonb_array_elements(config_to_check #> '{solo,sanctions}')
    union all
    select value
    from jsonb_array_elements(config_to_check #> '{clan,sanctions}')
  loop
    sanction_kind := sanction ->> 'kind';
    if sanction_kind = 'INDEFINITE_SUSPENSION' then
      if jsonb_typeof(sanction -> 'durationDays') <> 'null' then
        return false;
      end if;
    elsif jsonb_typeof(sanction -> 'durationDays') <> 'number'
      or (sanction ->> 'durationDays')::numeric <>
        trunc((sanction ->> 'durationDays')::numeric)
    then
      return false;
    else
      duration_days := (sanction ->> 'durationDays')::integer;
      if sanction_kind = 'WARNING' and duration_days <> 0 then
        return false;
      elsif sanction_kind in (
        'BOOKING_RESTRICTION', 'PARTICIPATION_SUSPENSION'
      ) and duration_days not between 1 and 3650 then
        return false;
      end if;
    end if;
  end loop;

  return true;
exception
  when others then
    return false;
end;
$$;

alter table public.reliability_policy_versions
drop constraint if exists reliability_policy_sanction_duration_semantics_check;
alter table public.reliability_policy_versions
add constraint reliability_policy_sanction_duration_semantics_check
check (public.reliability_sanction_durations_are_valid(config)) not valid;
alter table public.reliability_policy_versions
validate constraint reliability_policy_sanction_duration_semantics_check;

revoke all on function public.reliability_sanction_durations_are_valid(jsonb)
from public, anon, authenticated;
grant execute on function public.reliability_sanction_durations_are_valid(jsonb)
to service_role;

-- Fail deployment if either hardening measure is accidentally ineffective.
do $$
declare
  policy_config jsonb;
begin
  select policy.config into policy_config
  from public.reliability_policy_versions policy
  where policy.state = 'PUBLISHED'
  order by policy.effective_from desc, policy.version desc
  limit 1;

  if policy_config is null then
    raise exception 'A published reliability policy is required.';
  end if;
  if public.reliability_sanction_durations_are_valid(
    jsonb_set(policy_config, '{solo,sanctions,1,durationDays}', '0'::jsonb)
  ) then
    raise exception 'Zero-day timed player sanctions must be rejected.';
  end if;
  if public.reliability_sanction_durations_are_valid(
    jsonb_set(policy_config, '{clan,sanctions,0,durationDays}', '1'::jsonb)
  ) then
    raise exception 'Warning duration must remain normalized to zero.';
  end if;
  if position('home_base_amount_fils := null' in lower(pg_get_functiondef(
    'public.create_fixture(uuid,text,date,text)'::regprocedure
  ))) = 0 then
    raise exception 'create_fixture still exposes private clan finance.';
  end if;
  if position('home_base_amount_fils := null' in lower(pg_get_functiondef(
    'public.join_fixture(uuid,uuid)'::regprocedure
  ))) = 0 then
    raise exception 'join_fixture still exposes private clan finance.';
  end if;
end;
$$;

comment on function public.redact_fixture_cancellation_context() is
'Removes payer IDs, deposit standing and wallet amounts before a fixture cancellation context reaches its authenticated-readable row.';
comment on function public.reliability_sanction_durations_are_valid(jsonb) is
'Requires warnings to use the normalized zero-day history marker and every timed reliability restriction or suspension to last at least one day.';
