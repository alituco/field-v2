create or replace function public.ensure_live_fixture_has_started_clock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'LIVE' and old.status is distinct from 'LIVE' then
    if not exists (
      select 1
      from public.fixture_clock_states clock
      where clock.fixture_id = new.id
        and clock.status in ('RUNNING', 'PAUSED')
    ) then
      raise exception 'A match can only go live when the referee starts it.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists ensure_live_fixture_has_started_clock
on public.fixtures;
create trigger ensure_live_fixture_has_started_clock
before update of status
on public.fixtures
for each row
execute function public.ensure_live_fixture_has_started_clock();

update public.fixtures fixture
set status = 'SCHEDULED'
where fixture.status = 'LIVE'
  and fixture.away_clan_id is not null
  and not exists (
    select 1
    from public.fixture_clock_states clock
    where clock.fixture_id = fixture.id
      and clock.status in ('RUNNING', 'PAUSED')
  );
