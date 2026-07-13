alter table public.fixture_events
add column if not exists occurred_at timestamptz;

update public.fixture_events
set occurred_at = created_at
where occurred_at is null;

alter table public.fixture_events
alter column occurred_at set default now();

alter table public.fixture_events
alter column occurred_at set not null;
