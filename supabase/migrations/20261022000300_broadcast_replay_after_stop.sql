-- Cloudflare may finalize a recording segment during a temporary disconnect.
-- A ready segment is not an acknowledgement that the laptop stopped streaming.
create or replace function public.sync_broadcast_replay(kind text,target_id uuid,video_id text,replay_url text,ready_at timestamptz,expected_requested_at timestamptz,recording_started_at timestamptz default null,expected_input_id text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare broadcast jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  if kind='SOLO' then select to_jsonb(b) into broadcast from public.open_queue_broadcasts b where game_id=target_id for update;
  elsif kind='CLAN' then select to_jsonb(b) into broadcast from public.fixture_broadcasts b where fixture_id=target_id for update;
  else raise exception 'Invalid match kind.'; end if;
  if broadcast is null or broadcast->>'stream_stopped_at' is null
    or broadcast->>'recovery_upload_id' is not null
    or exists(select 1 from public.broadcast_recording_recoveries where match_kind=kind and match_id=target_id and status='ATTACHING')
    or (broadcast->>'stream_requested_at')::timestamptz is distinct from expected_requested_at
    or (broadcast->>'active_video_id' is not null and broadcast->>'active_video_id'<>video_id)
    or (recording_started_at is not null and recording_started_at<expected_requested_at-interval '1 minute')
    or (expected_input_id is not null and broadcast->>'live_input_id' is distinct from expected_input_id) then return false; end if;
  if kind='SOLO' then
    update public.open_queue_broadcasts set status='REPLAY_READY',active_video_id=video_id,replay_hls_url=replay_url,recording_ready_at=ready_at,stream_started_at=coalesce(recording_started_at,stream_started_at),error_message=null where game_id=target_id;
    update public.open_queue_games set video_url=replay_url where id=target_id;
  else
    update public.fixture_broadcasts set status='REPLAY_READY',active_video_id=video_id,replay_hls_url=replay_url,recording_ready_at=ready_at,stream_started_at=coalesce(recording_started_at,stream_started_at),error_message=null where fixture_id=target_id;
    update public.fixtures set video_url=replay_url where id=target_id;
  end if;
  return true;
end;
$$;

-- Repair only premature terminal states. Preserve acknowledged stops, manually
-- recovered recordings, pending recovery publication, and unrelated video URLs.
do $$
declare broadcast record;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  for broadcast in select b.* from public.open_queue_broadcasts b
    where b.status='REPLAY_READY' and b.stream_stopped_at is null and b.recovery_upload_id is null
      and not exists(select 1 from public.broadcast_recording_recoveries r where r.match_kind='SOLO' and r.match_id=b.game_id and r.status='ATTACHING')
    for update of b
  loop
    update public.open_queue_games set video_url=null where id=broadcast.game_id and video_url=broadcast.replay_hls_url;
    update public.open_queue_broadcasts set status='STARTING',replay_hls_url=null,recording_ready_at=null where game_id=broadcast.game_id;
  end loop;
  for broadcast in select b.* from public.fixture_broadcasts b
    where b.status='REPLAY_READY' and b.stream_stopped_at is null and b.recovery_upload_id is null
      and not exists(select 1 from public.broadcast_recording_recoveries r where r.match_kind='CLAN' and r.match_id=b.fixture_id and r.status='ATTACHING')
    for update of b
  loop
    update public.fixtures set video_url=null where id=broadcast.fixture_id and video_url=broadcast.replay_hls_url;
    update public.fixture_broadcasts set status='STARTING',replay_hls_url=null,recording_ready_at=null where fixture_id=broadcast.fixture_id;
  end loop;
end;
$$;

revoke all on function public.sync_broadcast_replay(text,uuid,text,text,timestamptz,timestamptz,timestamptz,text) from public,anon,authenticated;
grant execute on function public.sync_broadcast_replay(text,uuid,text,text,timestamptz,timestamptz,timestamptz,text) to service_role;
