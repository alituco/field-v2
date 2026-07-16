alter table public.profile_highlights
add column if not exists source_type text;

alter table public.profile_highlights
add column if not exists source_match_id uuid;

alter table public.profile_highlights
add column if not exists source_event_id uuid;

alter table public.profile_highlights
add column if not exists provider_source_video_id text;

alter table public.profile_highlights
add column if not exists provider_source_duration_seconds numeric(12, 3);

alter table public.profile_highlights
add column if not exists provider_video_id text;

alter table public.profile_highlights
add column if not exists provider_request_started_at timestamptz;

alter table public.profile_highlights
add column if not exists clip_start_seconds numeric(12, 3);

alter table public.profile_highlights
add column if not exists clip_end_seconds numeric(12, 3);

alter table public.profile_highlights
add column if not exists processing_status text not null default 'READY';

alter table public.profile_highlights
add column if not exists processing_error text;

alter table public.profile_highlights
add column if not exists download_status text not null default 'UNAVAILABLE';

alter table public.profile_highlights
add column if not exists download_url text;

alter table public.profile_highlights
alter column thumbnail_url drop not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profile_highlights_source_check'
      and conrelid = 'public.profile_highlights'::regclass
  ) then
    alter table public.profile_highlights
    add constraint profile_highlights_source_check
    check (
      (
        source_type is null
        and source_match_id is null
        and source_event_id is null
      )
      or (
        source_type in ('CLAN', 'SOLO')
        and source_match_id is not null
        and source_event_id is not null
      )
    );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profile_highlights_processing_status_check'
      and conrelid = 'public.profile_highlights'::regclass
  ) then
    alter table public.profile_highlights
    add constraint profile_highlights_processing_status_check
    check (processing_status in ('PROCESSING', 'READY', 'FAILED'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profile_highlights_download_status_check'
      and conrelid = 'public.profile_highlights'::regclass
  ) then
    alter table public.profile_highlights
    add constraint profile_highlights_download_status_check
    check (
      download_status in (
        'UNAVAILABLE',
        'NOT_REQUESTED',
        'PROCESSING',
        'READY',
        'FAILED'
      )
    );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profile_highlights_clip_bounds_check'
      and conrelid = 'public.profile_highlights'::regclass
  ) then
    alter table public.profile_highlights
    add constraint profile_highlights_clip_bounds_check
    check (
      (
        clip_start_seconds is null
        and clip_end_seconds is null
      )
      or (
        clip_start_seconds >= 0
        and clip_end_seconds > clip_start_seconds
      )
    );
  end if;
end $$;

create unique index if not exists profile_highlights_source_event_unique_idx
on public.profile_highlights (source_type, source_event_id)
where source_type is not null and source_event_id is not null;

create unique index if not exists profile_highlights_provider_video_unique_idx
on public.profile_highlights (provider_video_id)
where provider_video_id is not null;

create index if not exists profile_highlights_processing_idx
on public.profile_highlights (processing_status, updated_at desc)
where source_type is not null;

drop policy if exists "Users can insert their own highlights"
on public.profile_highlights;

drop policy if exists "Users can update their own highlights"
on public.profile_highlights;

revoke insert, update on public.profile_highlights from anon, authenticated;
grant select, delete on public.profile_highlights to authenticated;

create or replace function public.request_profile_goal_clip(
  source_type_to_use text,
  source_match_id_to_use uuid,
  source_event_id_to_use uuid,
  title_to_use text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  normalized_source_type text := upper(trim(coalesce(source_type_to_use, '')));
  normalized_title text := trim(coalesce(title_to_use, ''));
  goal_occurred_at timestamptz;
  stream_started_at timestamptz;
  stream_stopped_at timestamptz;
  source_video_id text;
  source_clan_tag text;
  goal_timestamps jsonb := '[]'::jsonb;
  highlight public.profile_highlights%rowtype;
begin
  if caller_id is null then
    raise exception 'You need to sign in again.';
  end if;

  if normalized_source_type not in ('CLAN', 'SOLO') then
    raise exception 'Choose a valid match type.';
  end if;

  if char_length(normalized_title) not between 2 and 80 then
    raise exception 'Clip title must be between 2 and 80 characters.';
  end if;

  if normalized_source_type = 'CLAN' then
    select
      event.occurred_at,
      broadcast.stream_started_at,
      broadcast.stream_stopped_at,
      broadcast.active_video_id,
      clan.tag
    into
      goal_occurred_at,
      stream_started_at,
      stream_stopped_at,
      source_video_id,
      source_clan_tag
    from public.fixture_events event
    join public.fixtures fixture
      on fixture.id = event.fixture_id
    join public.fixture_broadcasts broadcast
      on broadcast.fixture_id = fixture.id
    left join public.clans clan
      on clan.id = event.clan_id
    where event.id = source_event_id_to_use
      and event.fixture_id = source_match_id_to_use
      and event.event_type = 'GOAL'
      and event.profile_id = caller_id
      and coalesce(lower(trim(event.note)), '') <> 'admin correction'
      and fixture.status = 'FINAL'
      and broadcast.status = 'REPLAY_READY'
      and broadcast.stream_started_at is not null
      and nullif(trim(broadcast.active_video_id), '') is not null;

    if goal_occurred_at is null then
      raise exception 'That goal is not available to add to your profile.';
    end if;

    select coalesce(
      jsonb_agg(to_jsonb(event.occurred_at) order by event.occurred_at, event.id),
      '[]'::jsonb
    )
    into goal_timestamps
    from public.fixture_events event
    where event.fixture_id = source_match_id_to_use
      and event.event_type = 'GOAL'
      and coalesce(lower(trim(event.note)), '') <> 'admin correction';
  else
    select
      event.occurred_at,
      broadcast.stream_started_at,
      broadcast.stream_stopped_at,
      broadcast.active_video_id
    into
      goal_occurred_at,
      stream_started_at,
      stream_stopped_at,
      source_video_id
    from public.open_queue_events event
    join public.open_queue_games game
      on game.id = event.game_id
    join public.open_queue_broadcasts broadcast
      on broadcast.game_id = game.id
    where event.id = source_event_id_to_use
      and event.game_id = source_match_id_to_use
      and event.event_type = 'GOAL'
      and event.profile_id = caller_id
      and coalesce(lower(trim(event.note)), '') <> 'admin correction'
      and game.status = 'FINAL'
      and broadcast.status = 'REPLAY_READY'
      and broadcast.stream_started_at is not null
      and nullif(trim(broadcast.active_video_id), '') is not null;

    if goal_occurred_at is null then
      raise exception 'That goal is not available to add to your profile.';
    end if;

    select coalesce(
      jsonb_agg(to_jsonb(event.occurred_at) order by event.occurred_at, event.id),
      '[]'::jsonb
    )
    into goal_timestamps
    from public.open_queue_events event
    where event.game_id = source_match_id_to_use
      and event.event_type = 'GOAL'
      and coalesce(lower(trim(event.note)), '') <> 'admin correction';
  end if;

  select existing.*
  into highlight
  from public.profile_highlights existing
  where existing.source_type = normalized_source_type
    and existing.source_event_id = source_event_id_to_use
  limit 1;

  if highlight.id is null then
    insert into public.profile_highlights (
      profile_id,
      title,
      thumbnail_url,
      video_url,
      duration,
      views,
      clan_tag,
      sort_order,
      source_type,
      source_match_id,
      source_event_id,
      provider_source_video_id,
      processing_status,
      processing_error,
      download_status,
      download_url
    )
    select
      caller_id,
      normalized_title,
      null,
      null,
      '0:30',
      0,
      source_clan_tag,
      coalesce(max(existing.sort_order), -1) + 1,
      normalized_source_type,
      source_match_id_to_use,
      source_event_id_to_use,
      source_video_id,
      'PROCESSING',
      null,
      'NOT_REQUESTED',
      null
    from public.profile_highlights existing
    where existing.profile_id = caller_id
    on conflict do nothing
    returning * into highlight;

    if highlight.id is null then
      select existing.*
      into highlight
      from public.profile_highlights existing
      where existing.source_type = normalized_source_type
        and existing.source_event_id = source_event_id_to_use
      limit 1;
    end if;
  end if;

  if highlight.profile_id <> caller_id then
    raise exception 'That goal has already been added by its scorer.';
  end if;

  return jsonb_build_object(
    'highlight', to_jsonb(highlight),
    'source_video_id', source_video_id,
    'goal_occurred_at', goal_occurred_at,
    'goal_timestamps', goal_timestamps,
    'stream_started_at', stream_started_at,
    'stream_stopped_at', stream_stopped_at
  );
end;
$$;

revoke all on function public.request_profile_goal_clip(text, uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.request_profile_goal_clip(text, uuid, uuid, text)
to authenticated;

create or replace function public.claim_profile_goal_clip_provider_request(
  highlight_id_to_use uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  claimed_id uuid;
begin
  update public.profile_highlights highlight
  set provider_request_started_at = now()
  where highlight.id = highlight_id_to_use
    and highlight.source_type is not null
    and highlight.processing_status = 'PROCESSING'
    and highlight.provider_video_id is null
    and (
      highlight.provider_request_started_at is null
      or highlight.provider_request_started_at < now() - interval '2 minutes'
    )
  returning highlight.id into claimed_id;

  return claimed_id is not null;
end;
$$;

revoke all on function public.claim_profile_goal_clip_provider_request(uuid)
from public, anon, authenticated;
grant execute on function public.claim_profile_goal_clip_provider_request(uuid)
to service_role;

create or replace function public.record_profile_highlight_view(
  highlight_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  updated_views integer;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in again.';
  end if;

  update public.profile_highlights highlight
  set views = highlight.views + 1
  where highlight.id = highlight_id_to_use
    and highlight.processing_status = 'READY'
  returning highlight.views into updated_views;

  if updated_views is null then
    raise exception 'That clip is not ready to watch.';
  end if;

  return updated_views;
end;
$$;

revoke all on function public.record_profile_highlight_view(uuid)
from public, anon, authenticated;
grant execute on function public.record_profile_highlight_view(uuid)
to authenticated;

comment on function public.request_profile_goal_clip(text, uuid, uuid, text) is
'Validates a scorer-owned goal from a final recorded match and creates one pending profile clip.';

comment on function public.record_profile_highlight_view(uuid) is
'Atomically records one authenticated playback start for a ready profile clip.';
