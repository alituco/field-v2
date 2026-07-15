drop index if exists public.profile_highlights_source_event_unique_idx;

drop index if exists public.profile_highlights_profile_source_event_unique_idx;
create unique index profile_highlights_profile_source_event_unique_idx
on public.profile_highlights (profile_id, source_type, source_event_id)
where source_type is not null and source_event_id is not null;

alter table public.profile_highlights
drop constraint if exists profile_highlights_source_check;

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
  )
);

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
      and caller_id in (event.profile_id, event.assist_profile_id)
      and coalesce(lower(trim(event.note)), '') <> 'admin correction'
      and fixture.status = 'FINAL'
      and broadcast.status = 'REPLAY_READY'
      and broadcast.stream_started_at is not null
      and nullif(trim(broadcast.active_video_id), '') is not null;

    if goal_occurred_at is null then
      raise exception 'Only the scorer or assisting player can add that goal to their profile.';
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
      and caller_id in (event.profile_id, event.assist_profile_id)
      and coalesce(lower(trim(event.note)), '') <> 'admin correction'
      and game.status = 'FINAL'
      and broadcast.status = 'REPLAY_READY'
      and broadcast.stream_started_at is not null
      and nullif(trim(broadcast.active_video_id), '') is not null;

    if goal_occurred_at is null then
      raise exception 'Only the scorer or assisting player can add that goal to their profile.';
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
  where existing.profile_id = caller_id
    and existing.source_type = normalized_source_type
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
      where existing.profile_id = caller_id
        and existing.source_type = normalized_source_type
        and existing.source_event_id = source_event_id_to_use
      limit 1;
    end if;
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

comment on function public.request_profile_goal_clip(text, uuid, uuid, text) is
'Validates a scorer- or assister-owned goal from a final recorded match and creates one profile clip per credited player.';

comment on constraint profile_highlights_source_check
on public.profile_highlights is
'Goal clips identify a source event; custom match clips identify only the trusted source match.';
