create table public.season_zero_waitlist (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (
    char_length(trim(full_name)) between 2 and 100
  ),
  email text not null check (
    char_length(email) between 5 and 254
    and email = lower(trim(email))
    and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  phone text check (
    phone is null
    or char_length(trim(phone)) between 7 and 30
  ),
  interest text not null check (
    interest in ('SOLO_PLAYER', 'CLAN_PLAYER', 'CLAN_LEADER')
  ),
  source text not null default 'FIELD_BH' check (
    source in ('FIELD_BH')
  ),
  status text not null default 'WAITING' check (
    status in ('WAITING', 'CONTACTED', 'SELECTED', 'DECLINED', 'ONBOARDED')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index season_zero_waitlist_email_unique_idx
on public.season_zero_waitlist (lower(email));

create index season_zero_waitlist_queue_idx
on public.season_zero_waitlist (status, created_at asc, id);

drop trigger if exists set_season_zero_waitlist_updated_at
on public.season_zero_waitlist;
create trigger set_season_zero_waitlist_updated_at
before update on public.season_zero_waitlist
for each row execute function public.set_updated_at();

alter table public.season_zero_waitlist enable row level security;

-- Waitlist entries contain private contact details. Public clients never receive
-- table privileges; the field.bh server validates and inserts with its service
-- role, and future admin tooling can read the queue through the same boundary.
revoke all on table public.season_zero_waitlist
from public, anon, authenticated;
grant select, insert, update on table public.season_zero_waitlist
to service_role;

comment on table public.season_zero_waitlist is
  'Private Season Zero interest queue submitted through field.bh.';
