-- Playback history belongs to the viewer. Clients can read their own history;
-- the existing playback RPC is the only authenticated write path.
create table public.profile_highlight_view_history (
  viewer_profile_id uuid not null references public.profiles(id) on delete cascade,
  highlight_id uuid not null references public.profile_highlights(id) on delete cascade,
  first_viewed_at timestamptz not null default now(),
  last_viewed_at timestamptz not null default now(),
  playback_starts integer not null default 1 check (playback_starts > 0),
  primary key (viewer_profile_id, highlight_id)
);

alter table public.profile_highlight_view_history enable row level security;
revoke all on public.profile_highlight_view_history from public, anon, authenticated;
grant select on public.profile_highlight_view_history to authenticated;
grant all on public.profile_highlight_view_history to service_role;

create policy "Viewers can read only their own clip history"
on public.profile_highlight_view_history for select to authenticated
using (viewer_profile_id = auth.uid());

create index profile_highlight_view_history_highlight_idx
on public.profile_highlight_view_history (highlight_id);

create index profile_highlights_ready_popular_idx
on public.profile_highlights (views desc, created_at desc, id)
where is_public and processing_status = 'READY' and nullif(btrim(video_url), '') is not null;

create index profile_highlights_ready_owner_idx
on public.profile_highlights (profile_id, views desc, created_at desc, id)
where processing_status = 'READY' and nullif(btrim(video_url), '') is not null;

create or replace function public.record_profile_highlight_view(
  highlight_id_to_use uuid
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  updated_views integer;
begin
  if caller_id is null then
    raise exception 'You need to sign in again.';
  end if;

  update public.profile_highlights highlight
  set views = highlight.views + 1
  where highlight.id = highlight_id_to_use
    and highlight.processing_status = 'READY'
    and (highlight.is_public or highlight.profile_id = caller_id)
  returning highlight.views into updated_views;

  if updated_views is null then
    raise exception 'That clip is not available to watch.';
  end if;

  insert into public.profile_highlight_view_history (
    viewer_profile_id, highlight_id
  ) values (caller_id, highlight_id_to_use)
  on conflict (viewer_profile_id, highlight_id) do update
  set last_viewed_at = now(),
      playback_starts = profile_highlight_view_history.playback_starts + 1;

  return updated_views;
end;
$$;

revoke all on function public.record_profile_highlight_view(uuid)
from public, anon, authenticated;
grant execute on function public.record_profile_highlight_view(uuid) to authenticated;

comment on function public.record_profile_highlight_view(uuid) is
'Atomically records a playback start and the authenticated viewer history used to exclude watched Up next clips.';

create function public.get_profile_clip_recommendations(
  highlight_id_to_use uuid,
  limit_to_use integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  source_owner_id uuid;
  recommendations jsonb;
begin
  if caller_id is null then
    raise exception 'You need to sign in again.';
  end if;
  if limit_to_use is null or limit_to_use < 1 or limit_to_use > 20 then
    raise exception 'Choose between 1 and 20 next clips.';
  end if;

  select highlight.profile_id into source_owner_id
  from public.profile_highlights highlight
  join public.profiles owner on owner.id = highlight.profile_id
  where highlight.id = highlight_id_to_use
    and (highlight.is_public or highlight.profile_id = caller_id)
    and owner.account_deleted_at is null
    and (owner.id = caller_id or public.is_fieldrush_account_active(owner.id));

  if source_owner_id is null then
    raise exception 'That clip is not available to watch.';
  end if;

  select coalesce(jsonb_agg(candidate.payload order by
    candidate.owner_priority, candidate.views desc,
    candidate.created_at desc, candidate.id), '[]'::jsonb)
  into recommendations
  from (
    select highlight.id, highlight.views, highlight.created_at,
      case when highlight.profile_id = source_owner_id then 0 else 1 end as owner_priority,
      jsonb_build_object(
        'profile_id', owner.id,
        'username', owner.username,
        'display_name', owner.display_name,
        'avatar_url', owner.avatar_url,
        'highlight', jsonb_build_object(
          'id', highlight.id,
          'profile_id', highlight.profile_id,
          'title', highlight.title,
          'thumbnail_url', highlight.thumbnail_url,
          'video_url', highlight.video_url,
          'duration', highlight.duration,
          'views', highlight.views,
          'clan_tag', highlight.clan_tag,
          'download_url', highlight.download_url,
          'source_type', highlight.source_type,
          'source_match_id', highlight.source_match_id,
          'source_event_id', highlight.source_event_id,
          'provider_video_id', highlight.provider_video_id,
          'is_public', highlight.is_public,
          'processing_status', highlight.processing_status,
          'created_at', highlight.created_at
        )
      ) as payload
    from public.profile_highlights highlight
    join public.profiles owner on owner.id = highlight.profile_id
    where highlight.id <> highlight_id_to_use
      and highlight.processing_status = 'READY'
      and nullif(btrim(highlight.video_url), '') is not null
      and (
        highlight.is_public
        or (highlight.profile_id = source_owner_id and highlight.profile_id = caller_id)
      )
      and owner.account_deleted_at is null
      and (owner.id = caller_id or public.is_fieldrush_account_active(owner.id))
      and not exists (
        select 1 from public.profile_highlight_view_history history
        where history.viewer_profile_id = caller_id
          and history.highlight_id = highlight.id
      )
    order by owner_priority, highlight.views desc, highlight.created_at desc, highlight.id
    limit limit_to_use
  ) candidate;

  return recommendations;
end;
$$;

revoke all on function public.get_profile_clip_recommendations(uuid, integer)
from public, anon, authenticated;
grant execute on function public.get_profile_clip_recommendations(uuid, integer)
to authenticated;

comment on function public.get_profile_clip_recommendations(uuid, integer) is
'Returns unseen ready clips from the current creator first, then popular public clips, respecting owner-only privacy and completed profile visibility.';
