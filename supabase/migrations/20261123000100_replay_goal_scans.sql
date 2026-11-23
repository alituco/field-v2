-- Each recording has its own media clock. Keep a replacement recording's
-- analysis independent of the previous upload, even if both are for one match.
create table public.replay_goal_scans (
  source_type text not null check (source_type in ('SOLO', 'CLAN')),
  match_id uuid not null,
  video_id text not null check (btrim(video_id) <> ''),
  status text not null default 'scanned' check (status in ('pending', 'scanned', 'unmatched')),
  next_attempt_at timestamptz not null default now(),
  goal_positions jsonb not null default '{}'::jsonb,
  primary key (source_type, match_id, video_id),
  check (status = 'scanned' or goal_positions = '{}'::jsonb),
  check (jsonb_typeof(goal_positions) = 'object' and not jsonb_path_exists(goal_positions,
    '$.keyvalue() ? (!(@.key like_regex "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") || @.value.type() != "number" || @.value < 0)'))
);

create index replay_goal_scans_pending_idx on public.replay_goal_scans (next_attempt_at)
  where status = 'pending';
alter table public.replay_goal_scans enable row level security;
revoke all on public.replay_goal_scans from public, anon, authenticated;
grant select, insert, update, delete on public.replay_goal_scans to service_role;

-- The deployment enables scanning only after the worker is available. A
-- disabled project continues using existing playback behavior for new games.
create table fieldrush_private.replay_scanning_settings (
  singleton boolean primary key check (singleton),
  enabled boolean not null
);
insert into fieldrush_private.replay_scanning_settings values (true, false);
revoke all on fieldrush_private.replay_scanning_settings from public, anon, authenticated, service_role;

create function fieldrush_private.set_replay_scanning_enabled(enable_scanning boolean)
returns void language plpgsql set search_path = '' as $$
begin
  update fieldrush_private.replay_scanning_settings set enabled = enable_scanning where singleton;
  if not enable_scanning then
    delete from public.replay_goal_scans where status = 'pending';
  end if;
end;
$$;
revoke all on function fieldrush_private.set_replay_scanning_enabled(boolean) from public, anon, authenticated, service_role;

-- Queue publication in the same transaction as the replay URL. Repeated
-- ready callbacks must preserve completed scans and any pending retry time.
create function fieldrush_private.enqueue_replay_goal_scan()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  match_id_to_scan uuid;
begin
  if tg_op = 'UPDATE' and old.status = 'REPLAY_READY'
    and old.active_video_id is not distinct from new.active_video_id then
    return null;
  end if;
  -- Serialize enqueue against disabling the worker and clearing its pending rows.
  if not (select enabled from fieldrush_private.replay_scanning_settings where singleton for share) then
    return null;
  end if;
  if tg_argv[0] = 'SOLO' then
    match_id_to_scan := new.game_id;
  else
    match_id_to_scan := new.fixture_id;
  end if;
  insert into public.replay_goal_scans (source_type, match_id, video_id, status)
    values (tg_argv[0], match_id_to_scan, new.active_video_id, 'pending')
    on conflict (source_type, match_id, video_id) do nothing;
  return null;
end;
$$;
revoke all on function fieldrush_private.enqueue_replay_goal_scan() from public, anon, authenticated, service_role;

create trigger queue_solo_replay_goal_scan
after insert or update of status, active_video_id on public.open_queue_broadcasts
for each row when (new.status = 'REPLAY_READY' and new.active_video_id is not null)
execute function fieldrush_private.enqueue_replay_goal_scan('SOLO');

create trigger queue_clan_replay_goal_scan
after insert or update of status, active_video_id on public.fixture_broadcasts
for each row when (new.status = 'REPLAY_READY' and new.active_video_id is not null)
execute function fieldrush_private.enqueue_replay_goal_scan('CLAN');

-- A post-game correction can replace an event UUID after the scanner finishes.
-- Reset the current recording's analysis and lease atomically with that change.
create function fieldrush_private.invalidate_replay_goal_scan()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  match_to_scan uuid;
  active_video text;
begin
  if tg_argv[0] = 'SOLO' then
    match_to_scan := new.game_id;
    select active_video_id into active_video from public.open_queue_broadcasts
      where game_id = match_to_scan and status = 'REPLAY_READY';
  else
    match_to_scan := new.fixture_id;
    select active_video_id into active_video from public.fixture_broadcasts
      where fixture_id = match_to_scan and status = 'REPLAY_READY';
  end if;
  if active_video is null then return null; end if;

  -- Updating existing rows only leaves unscanned historical games alone.
  if (select enabled from fieldrush_private.replay_scanning_settings where singleton for share) then
    update public.replay_goal_scans
      set status = 'pending', goal_positions = '{}'::jsonb, next_attempt_at = clock_timestamp()
      where source_type = tg_argv[0] and match_id = match_to_scan and video_id = active_video;
  else
    -- A completed scan can still be used while the worker is off, until the
    -- underlying goal record changes and makes its positions stale.
    delete from public.replay_goal_scans
      where source_type = tg_argv[0] and match_id = match_to_scan and video_id = active_video;
  end if;
  return null;
end;
$$;
revoke all on function fieldrush_private.invalidate_replay_goal_scan() from public, anon, authenticated, service_role;

create trigger invalidate_solo_replay_goal_scan after insert on public.open_queue_events
for each row when (new.event_type in ('GOAL', 'CORRECTION'))
execute function fieldrush_private.invalidate_replay_goal_scan('SOLO');

create trigger invalidate_clan_replay_goal_scan after insert on public.fixture_events
for each row when (new.event_type in ('GOAL', 'CORRECTION'))
execute function fieldrush_private.invalidate_replay_goal_scan('CLAN');

-- Clan detail embeds fixture_broadcasts directly through PostgREST. Resolve
-- the computed field against the actual current broadcast row, including when
-- a caller supplies a constructed row rather than selecting from the table.
create function public.replay_goal_positions(public.fixture_broadcasts)
returns jsonb language sql stable security definer set search_path = '' as $$
  select scan.goal_positions
  from public.fixture_broadcasts as broadcast
  join public.replay_goal_scans as scan
    on scan.source_type = 'CLAN' and scan.match_id = broadcast.fixture_id
      and scan.video_id = broadcast.active_video_id
  where broadcast.fixture_id = ($1).fixture_id and broadcast.active_video_id = ($1).active_video_id
    and broadcast.status = 'REPLAY_READY' and broadcast.replay_hls_url is not null;
$$;
revoke all on function public.replay_goal_positions(public.fixture_broadcasts) from public, anon;
grant execute on function public.replay_goal_positions(public.fixture_broadcasts) to authenticated, service_role;

-- Preserve authorization, rating/identity masking, and prior response fields.
-- A missing scan keeps historical clients' legacy timestamps. An empty map
-- explicitly suppresses estimated highlights while awaiting a trusted result.
alter function public.get_open_queue_match_detail(uuid)
  rename to get_open_queue_match_detail_before_replay_scan;
revoke all on function public.get_open_queue_match_detail_before_replay_scan(uuid)
  from public, anon, authenticated, service_role;

create function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  detail jsonb;
  positions jsonb;
begin
  detail := public.get_open_queue_match_detail_before_replay_scan(game_id_to_use);
  if detail #>> '{broadcast,status}' = 'REPLAY_READY' then
    select scan.goal_positions into positions
    from public.open_queue_broadcasts as broadcast
    join public.replay_goal_scans as scan
      on scan.source_type = 'SOLO' and scan.match_id = broadcast.game_id
        and scan.video_id = broadcast.active_video_id
    where broadcast.game_id = game_id_to_use and broadcast.status = 'REPLAY_READY'
      and broadcast.replay_hls_url = detail #>> '{broadcast,replay_hls_url}';
    if positions is not null then
      return jsonb_set(detail, '{broadcast,replay_goal_positions}', positions);
    end if;
  end if;
  return detail;
end;
$$;
revoke all on function public.get_open_queue_match_detail(uuid) from public, anon;
grant execute on function public.get_open_queue_match_detail(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
