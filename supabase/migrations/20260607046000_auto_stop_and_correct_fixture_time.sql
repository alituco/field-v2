create extension if not exists pg_cron;

alter table public.fixture_clock_states
drop constraint if exists fixture_clock_states_accumulated_seconds_check;

update public.fixture_clock_states
set accumulated_seconds = least(accumulated_seconds, 10800)
where accumulated_seconds > 10800;

alter table public.fixture_clock_states
add constraint fixture_clock_states_accumulated_seconds_check
check (accumulated_seconds between 0 and 10800);

create or replace function public.auto_stop_overdue_fixture_clocks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  overdue_clock record;
  stopped_count integer := 0;
begin
  for overdue_clock in
    select clock.fixture_id
    from public.fixture_clock_states clock
    join public.fixtures fixture on fixture.id = clock.fixture_id
    where fixture.status = 'LIVE'
      and (
        (
          clock.status = 'RUNNING'
          and clock.started_at is not null
          and clock.accumulated_seconds
            + greatest(
              0,
              floor(extract(epoch from (now() - clock.started_at)))::integer
            ) >= 10800
        )
        or (
          clock.status = 'PAUSED'
          and clock.accumulated_seconds >= 10800
        )
      )
    for update of clock skip locked
  loop
    begin
      update public.fixture_clock_states
      set
        status = 'ENDED',
        started_at = null,
        accumulated_seconds = 10800
      where fixture_id = overdue_clock.fixture_id;

      if not exists (
        select 1
        from public.fixture_events event
        where event.fixture_id = overdue_clock.fixture_id
          and event.event_type = 'MATCH_ENDED'
      ) then
        insert into public.fixture_events (
          fixture_id,
          event_type,
          minute,
          second,
          note
        ) values (
          overdue_clock.fixture_id,
          'MATCH_ENDED',
          180,
          0,
          'Automatically stopped after 3 hours of playtime.'
        );
      end if;

      perform public.referee_complete_fixture(overdue_clock.fixture_id);

      -- Older versions of referee_complete_fixture clamp to the nominal match
      -- duration. Keep the hard-stop time as the recorded final time.
      update public.fixture_clock_states
      set
        status = 'ENDED',
        started_at = null,
        accumulated_seconds = 10800
      where fixture_id = overdue_clock.fixture_id;

      stopped_count := stopped_count + 1;
    exception
      when others then
        raise warning 'Could not auto-stop fixture %: %', overdue_clock.fixture_id, sqlerrm;
    end;
  end loop;

  return stopped_count;
end;
$$;

revoke execute on function public.auto_stop_overdue_fixture_clocks()
from public, anon, authenticated;
grant execute on function public.auto_stop_overdue_fixture_clocks()
to service_role;

do $$
declare
  existing_job_id bigint;
begin
  select jobid
  into existing_job_id
  from cron.job
  where jobname = 'auto-stop-fixtures-at-three-hours'
  limit 1;

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;
end;
$$;

select cron.schedule(
  'auto-stop-fixtures-at-three-hours',
  '* * * * *',
  'select public.auto_stop_overdue_fixture_clocks()'
);
