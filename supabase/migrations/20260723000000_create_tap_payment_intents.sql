-- Tap Checkout is intentionally finalized server-side. The mobile client can
-- start the native checkout, but a booking/fixture is only created after the
-- server retrieves the charge from Tap and verifies its amount, currency,
-- merchant, transaction reference, and CAPTURED status.

create table public.tap_payment_intents (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete restrict,
  purpose text not null check (
    purpose in ('SOLO_BOOKING', 'CLAN_CREATE', 'CLAN_JOIN')
  ),
  status text not null default 'PENDING' check (
    status in (
      'PENDING',
      'CAPTURED',
      'FINALIZED',
      'FAILED',
      'CANCELLED',
      'EXPIRED',
      'REQUIRES_REFUND',
      'REFUNDED'
    )
  ),
  currency text not null default 'BHD' check (currency = 'BHD'),
  amount_fils integer not null check (amount_fils > 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  quote_snapshot jsonb not null check (
    jsonb_typeof(quote_snapshot) = 'object'
  ),
  transaction_reference text not null unique,
  tap_charge_id text unique,
  tap_payment_method text,
  tap_status text,
  resource_type text check (
    resource_type is null or resource_type in ('OPEN_QUEUE_BOOKING', 'FIXTURE')
  ),
  resource_id uuid,
  failure_reason text,
  expires_at timestamptz not null default (clock_timestamp() + interval '20 minutes'),
  captured_at timestamptz,
  finalized_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create index tap_payment_intents_profile_created_idx
on public.tap_payment_intents (profile_id, created_at desc);

create index tap_payment_intents_pending_expiry_idx
on public.tap_payment_intents (expires_at)
where status = 'PENDING';

create unique index tap_payment_intents_one_active_checkout_idx
on public.tap_payment_intents (
  profile_id,
  purpose,
  coalesce(payload ->> 'game_id', ''),
  coalesce(payload ->> 'fixture_id', ''),
  coalesce(payload ->> 'clan_id', ''),
  coalesce(payload ->> 'match_date', ''),
  coalesce(payload ->> 'time_slot', '')
)
where status in ('PENDING', 'CAPTURED');

drop trigger if exists set_tap_payment_intents_updated_at
on public.tap_payment_intents;
create trigger set_tap_payment_intents_updated_at
before update on public.tap_payment_intents
for each row execute function public.set_updated_at();

alter table public.tap_payment_intents enable row level security;
revoke all on table public.tap_payment_intents
from public, anon, authenticated;
grant all on table public.tap_payment_intents to service_role;

alter table public.open_queue_bookings
add column if not exists tap_payment_intent_id uuid
  references public.tap_payment_intents(id) on delete restrict;
alter table public.open_queue_bookings
add column if not exists tap_charge_id text;

create unique index if not exists open_queue_bookings_tap_intent_unique_idx
on public.open_queue_bookings (tap_payment_intent_id)
where tap_payment_intent_id is not null;

alter table public.open_queue_bookings
drop constraint if exists open_queue_bookings_payment_method_check;
alter table public.open_queue_bookings
add constraint open_queue_bookings_payment_method_check check (
  payment_method in (
    'APPLE_PAY',
    'BENEFITPAY',
    'VISA',
    'MASTERCARD',
    'CARD',
    'MOCK'
  )
);

alter table public.fixtures
add column if not exists home_tap_payment_intent_id uuid
  references public.tap_payment_intents(id) on delete restrict;
alter table public.fixtures
add column if not exists away_tap_payment_intent_id uuid
  references public.tap_payment_intents(id) on delete restrict;
alter table public.fixtures
add column if not exists home_tap_charge_id text;
alter table public.fixtures
add column if not exists away_tap_charge_id text;

create unique index if not exists fixtures_home_tap_intent_unique_idx
on public.fixtures (home_tap_payment_intent_id)
where home_tap_payment_intent_id is not null;
create unique index if not exists fixtures_away_tap_intent_unique_idx
on public.fixtures (away_tap_payment_intent_id)
where away_tap_payment_intent_id is not null;

comment on table public.tap_payment_intents is
'Server-owned Tap Checkout attempts. A captured charge must be verified against its immutable quote before the related booking or fixture is finalized.';
comment on column public.tap_payment_intents.failure_reason is
'Operational explanation for failed finalization. REQUIRES_REFUND rows must remain visible to administrators until reconciled.';
