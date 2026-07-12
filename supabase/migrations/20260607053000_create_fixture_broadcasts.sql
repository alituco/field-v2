create table if not exists public.broadcast_devices (
  device_key text primary key check (char_length(trim(device_key)) between 2 and 80),
  display_name text not null check (char_length(trim(display_name)) between 2 and 120),
  status text not null default 'OFFLINE' check (
    status in ('OFFLINE', 'READY', 'STREAMING', 'ERROR')
  ),
  obs_connected boolean not null default false,
  obs_streaming boolean not null default false,
  current_fixture_id uuid references public.fixtures(id) on delete set null,
  last_seen_at timestamptz,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fixture_broadcasts (
  fixture_id uuid primary key references public.fixtures(id) on delete cascade,
  provider text not null default 'cloudflare' check (provider = 'cloudflare'),
  live_input_id text unique,
  active_video_id text,
  status text not null default 'NOT_CONFIGURED' check (
    status in (
      'NOT_CONFIGURED',
      'READY',
      'STARTING',
      'LIVE',
      'STOPPING',
      'PROCESSING',
      'REPLAY_READY',
      'ERROR'
    )
  ),
  hls_url text,
  replay_hls_url text,
  stream_requested_at timestamptz,
  stream_started_at timestamptz,
  stream_stopped_at timestamptz,
  recording_ready_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists fixture_broadcasts_status_idx
on public.fixture_broadcasts (status, updated_at desc);

create table if not exists public.broadcast_commands (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures(id) on delete cascade,
  device_key text not null references public.broadcast_devices(device_key) on delete restrict,
  action text not null check (action in ('START_STREAM', 'STOP_STREAM')),
  status text not null default 'PENDING' check (
    status in ('PENDING', 'CLAIMED', 'ACKNOWLEDGED', 'FAILED')
  ),
  requested_by uuid references public.profiles(id) on delete set null,
  available_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists broadcast_commands_device_queue_idx
on public.broadcast_commands (device_key, status, available_at, created_at);

create unique index if not exists broadcast_commands_active_action_idx
on public.broadcast_commands (fixture_id, action)
where status in ('PENDING', 'CLAIMED');

drop trigger if exists set_broadcast_devices_updated_at
on public.broadcast_devices;
create trigger set_broadcast_devices_updated_at
before update on public.broadcast_devices
for each row
execute function public.set_updated_at();

drop trigger if exists set_fixture_broadcasts_updated_at
on public.fixture_broadcasts;
create trigger set_fixture_broadcasts_updated_at
before update on public.fixture_broadcasts
for each row
execute function public.set_updated_at();

drop trigger if exists set_broadcast_commands_updated_at
on public.broadcast_commands;
create trigger set_broadcast_commands_updated_at
before update on public.broadcast_commands
for each row
execute function public.set_updated_at();

alter table public.broadcast_devices enable row level security;
alter table public.fixture_broadcasts enable row level security;
alter table public.broadcast_commands enable row level security;

drop policy if exists "Fixture broadcasts are readable by authenticated users"
on public.fixture_broadcasts;
create policy "Fixture broadcasts are readable by authenticated users"
on public.fixture_broadcasts
for select
to authenticated
using (true);

revoke all on public.broadcast_devices from anon, authenticated;
revoke all on public.broadcast_commands from anon, authenticated;
revoke insert, update, delete on public.fixture_broadcasts from anon, authenticated;
grant select on public.fixture_broadcasts to authenticated;

