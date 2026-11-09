-- One checkout-sheet load, independent of payment intent, charge, or booking.
create table fieldrush_private.checkout_load_attempts (
  attempt_key bytea primary key,
  first_received_at timestamptz not null default statement_timestamp(),
  platform text not null,
  app_version text not null,
  outcome text not null,
  reason text,
  elapsed_ms integer not null
);
create index checkout_load_attempts_received_idx
  on fieldrush_private.checkout_load_attempts (first_received_at);

-- Rate-limit new attempts without storing an account identifier on an attempt.
-- The counter key changes each UTC hour. It cannot be joined to the attempts.
create table fieldrush_private.checkout_load_hourly_quota (
  bucket_key bytea primary key,
  hour_started_at timestamptz not null,
  attempt_count integer not null
);

revoke all on fieldrush_private.checkout_load_attempts, fieldrush_private.checkout_load_hourly_quota
  from public, anon, authenticated, service_role;
alter table fieldrush_private.checkout_load_attempts enable row level security;
alter table fieldrush_private.checkout_load_hourly_quota enable row level security;

create function public.record_checkout_load_event(
  attempt_id_to_use uuid,
  outcome_to_use text,
  platform_to_use text,
  app_version_to_use text,
  elapsed_ms_to_use integer,
  reason_to_use text default null
) returns void
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare
  actor uuid := auth.uid();
  event_key bytea;
  current_outcome text;
  bucket_hour timestamptz := date_trunc('hour', statement_timestamp(), 'UTC');
begin
  if actor is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;
  if attempt_id_to_use is null
    or outcome_to_use is null or outcome_to_use not in ('started','ready','failed','timed_out','closed')
    or platform_to_use is null or platform_to_use not in ('ios','android','other')
    or app_version_to_use is null or length(app_version_to_use) > 40
    or (app_version_to_use <> 'unknown' and app_version_to_use !~ '^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$')
    or elapsed_ms_to_use is null or elapsed_ms_to_use < 0
    or (case outcome_to_use
      when 'failed' then coalesce(reason_to_use in
        ('invalid_total','checkout_busy','configuration_failed','selector_failed'), false)
      when 'timed_out' then coalesce(reason_to_use in ('configuration_timeout','selector_timeout'), false)
      else reason_to_use is null
    end) is not true then
    raise exception using errcode = '22023', message = 'Invalid checkout load event.';
  end if;

  -- The same client UUID from two accounts describes two independent attempts.
  event_key := sha256(uuid_send(actor) || uuid_send(attempt_id_to_use));
  perform pg_advisory_xact_lock(hashtextextended('checkout-load:' || actor::text, 0));
  select outcome into current_outcome
    from fieldrush_private.checkout_load_attempts where attempt_key = event_key;
  if found then
    -- A terminal event can arrive before its start. Never reopen it, replace its
    -- first terminal outcome, or let a retry inflate the number of attempts.
    if current_outcome = 'started' and outcome_to_use <> 'started' then
      update fieldrush_private.checkout_load_attempts
        set outcome = outcome_to_use, reason = reason_to_use, elapsed_ms = elapsed_ms_to_use
        where attempt_key = event_key;
    end if;
    return;
  end if;

  insert into fieldrush_private.checkout_load_hourly_quota as quota (bucket_key, hour_started_at, attempt_count)
    values (sha256(uuid_send(actor) || timestamptz_send(bucket_hour)), bucket_hour, 1)
    on conflict (bucket_key) do update set attempt_count = quota.attempt_count + 1
      where quota.attempt_count < 120;
  if found then
    insert into fieldrush_private.checkout_load_attempts
      (attempt_key, platform, app_version, outcome, reason, elapsed_ms)
      values (event_key, platform_to_use, app_version_to_use, outcome_to_use, reason_to_use, elapsed_ms_to_use);
  end if;
end;
$$;
revoke all on function public.record_checkout_load_event(uuid,text,text,text,integer,text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_checkout_load_event(uuid,text,text,text,integer,text) to authenticated;

-- For the operator in the SQL Editor. A missing terminal signal is counted
-- separately from confirmed timeouts, failures and explicit dismissals.
create view fieldrush_private.checkout_load_health_daily as
  select (first_received_at at time zone 'UTC')::date as utc_day, platform, app_version,
    case
      when outcome = 'started' and first_received_at <= statement_timestamp() - interval '5 minutes' then 'unconfirmed'
      when outcome = 'started' then 'loading'
      else outcome
    end as load_status, reason, count(*) as attempts,
    percentile_disc(0.5) within group (order by elapsed_ms)
      filter (where outcome <> 'started') as median_elapsed_ms
  from fieldrush_private.checkout_load_attempts
  group by 1, 2, 3, 4, 5;
revoke all on fieldrush_private.checkout_load_health_daily from public, anon, authenticated, service_role;

-- pg_cron is already part of the migration chain. Both expirations share one job.
select cron.schedule('checkout-load-retention', '17 * * * *', $job$
  delete from fieldrush_private.checkout_load_attempts where first_received_at < now() - interval '30 days';
  delete from fieldrush_private.checkout_load_hourly_quota where hour_started_at < date_trunc('hour', now(), 'UTC');
$job$);
