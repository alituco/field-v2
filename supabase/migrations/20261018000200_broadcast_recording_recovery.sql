-- Manual recovery is private until an authorized referee explicitly attaches a
-- verified, complete recording. The original replay remains usable meanwhile.
create table public.broadcast_recording_recoveries (
  id uuid primary key default gen_random_uuid(),
  device_key text references public.broadcast_device_credentials(device_key) on delete set null,
  match_kind text not null check (match_kind in ('SOLO','CLAN')),
  match_id uuid not null,
  recording_started_at timestamptz not null,
  file_name text not null,
  file_size bigint not null check (file_size between 1 and 21474836480),
  original_replay jsonb not null,
  status text not null default 'PREPARING' check (status in ('PREPARING','UPLOADING','ATTACHING','ATTACHED','FAILED')),
  provider_video_id text unique,
  upload_url text,
  expires_at timestamptz not null default now()+interval '6 hours',
  created_at timestamptz not null default now(),
  attachment_started_at timestamptz,
  verified_duration double precision,
  publication_replay_url text,
  attached_at timestamptz
);
alter table public.broadcast_recording_recoveries enable row level security;
revoke all on public.broadcast_recording_recoveries from public,anon,authenticated;
grant all on public.broadcast_recording_recoveries to service_role;
create index broadcast_recording_recoveries_device on public.broadcast_recording_recoveries(device_key,created_at desc);
create unique index broadcast_recording_recoveries_publication on public.broadcast_recording_recoveries(match_kind,match_id) where status='ATTACHING';
alter table public.fixture_broadcasts add column recovery_upload_id uuid references public.broadcast_recording_recoveries(id) on delete set null;
alter table public.open_queue_broadcasts add column recovery_upload_id uuid references public.broadcast_recording_recoveries(id) on delete set null;

create function public.broadcast_recovery_context(credential_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare context jsonb; credential public.broadcast_device_credentials%rowtype; camera public.broadcast_devices%rowtype; target_id uuid; kind text; replay jsonb; game_video text; game_status text;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  context:=public.broadcast_device_session(credential_hash);
  select * into credential from public.broadcast_device_credentials where token_hash=credential_hash for update;
  kind:=credential.match_kind; target_id:=coalesce(credential.fixture_id,credential.open_queue_game_id);
  if context->>'matchStatus'<>'FINAL' then raise exception 'Finish the match before recovering its recording.'; end if;
  select * into camera from public.broadcast_devices where device_key=credential.device_key for update;
  if credential.reservation_active or credential.test_input_id is not null or camera.obs_streaming
    or exists(select 1 from public.broadcast_commands where device_key=credential.device_key and status in ('PENDING','CLAIMED')) then
    raise exception 'Stop the stream and test stream before recovering a recording.';
  end if;
  if kind='SOLO' then
    select jsonb_build_object('activeVideoId',active_video_id,'replayUrl',replay_hls_url,'recordingStartedAt',stream_started_at,'recordingStoppedAt',stream_stopped_at,'streamRequestedAt',stream_requested_at,'liveInputId',live_input_id,'recoveryUploadId',recovery_upload_id)
      into replay from public.open_queue_broadcasts where game_id=target_id for update;
    if exists(select 1 from public.open_queue_broadcasts where game_id=target_id and status in ('STARTING','LIVE','STOPPING')) then raise exception 'Wait for the broadcast to stop before recovery.'; end if;
    select video_url,status into game_video,game_status from public.open_queue_games where id=target_id for update;
  else
    select jsonb_build_object('activeVideoId',active_video_id,'replayUrl',replay_hls_url,'recordingStartedAt',stream_started_at,'recordingStoppedAt',stream_stopped_at,'streamRequestedAt',stream_requested_at,'liveInputId',live_input_id,'recoveryUploadId',recovery_upload_id)
      into replay from public.fixture_broadcasts where fixture_id=target_id for update;
    if exists(select 1 from public.fixture_broadcasts where fixture_id=target_id and status in ('STARTING','LIVE','STOPPING')) then raise exception 'Wait for the broadcast to stop before recovery.'; end if;
    select video_url,status into game_video,game_status from public.fixtures where id=target_id for update;
  end if;
  if game_status is distinct from 'FINAL' then raise exception 'Finish the match before recovering its recording.'; end if;
  if replay is null then raise exception 'This match has no recording session to recover.'; end if;
  return context||jsonb_build_object('originalReplay',replay||jsonb_build_object('gameVideoUrl',game_video));
end;
$$;

create function public.begin_broadcast_recovery(credential_hash text,recorded_started_at timestamptz,input_file_name text,input_size bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare context jsonb; attempt public.broadcast_recording_recoveries%rowtype; paired_at timestamptz;
begin
  context:=public.broadcast_recovery_context(credential_hash);
  select created_at into paired_at from public.broadcast_device_credentials where token_hash=credential_hash;
  if recorded_started_at is null or recorded_started_at>now() or recorded_started_at<paired_at-interval '2 minutes' then raise exception 'Choose the original recording with its saved start time for this pairing.'; end if;
  if input_file_name is null or char_length(input_file_name) not between 1 and 180 or input_file_name ~ '[[:cntrl:]]' or strpos(input_file_name,'/')>0 or strpos(input_file_name,chr(92))>0 or lower(input_file_name) !~ '\.(mkv|mp4|mov)$'
    or input_size is null or input_size not between 1 and 21474836480 then raise exception 'Choose a valid complete recording of at most 20 GiB.'; end if;
  select * into attempt from public.broadcast_recording_recoveries where device_key=context->>'deviceKey'
    and recording_started_at=recorded_started_at and file_name=input_file_name and file_size=input_size
    and status in ('PREPARING','UPLOADING','ATTACHING','ATTACHED') and (expires_at>now() or status='ATTACHING') order by created_at desc limit 1 for update;
  if attempt.id is not null then
    if (attempt.status='PREPARING' and attempt.created_at<now()-interval '2 minutes')
      or (attempt.status='UPLOADING' and attempt.original_replay is distinct from context->'originalReplay') then
      update public.broadcast_recording_recoveries set status='FAILED' where id=attempt.id;
    else
      if attempt.status='PREPARING' then raise exception 'This upload is being prepared. Try again in a moment.'; end if;
      return to_jsonb(attempt);
    end if;
  end if;
  if exists(select 1 from public.broadcast_recording_recoveries where match_kind=context->>'matchKind' and match_id=(context->>'matchId')::uuid and status='ATTACHING') then
    raise exception 'Finish the reserved replay replacement before preparing another recording.';
  end if;
  if (select count(*) from public.broadcast_recording_recoveries where device_key=context->>'deviceKey' and created_at>now()-interval '24 hours')>=3 then
    raise exception 'Three recovery uploads have already been prepared. Ask an organizer for help.';
  end if;
  insert into public.broadcast_recording_recoveries(device_key,match_kind,match_id,recording_started_at,file_name,file_size,original_replay)
    values(context->>'deviceKey',context->>'matchKind',(context->>'matchId')::uuid,recorded_started_at,input_file_name,input_size,context->'originalReplay') returning * into attempt;
  return to_jsonb(attempt);
end;
$$;

create function public.store_broadcast_recovery_upload(credential_hash text,recovery_id uuid,video_id text,upload_destination text)
returns void language plpgsql security definer set search_path='' as $$
declare context jsonb;
begin
  context:=public.broadcast_recovery_context(credential_hash);
  if video_id is null or upload_destination is null or video_id !~ '^[a-f0-9]{32}$' or upload_destination !~ '^https://upload\.videodelivery\.net/' then raise exception 'Invalid recording upload destination.'; end if;
  update public.broadcast_recording_recoveries set provider_video_id=video_id,upload_url=upload_destination,status='UPLOADING'
    where id=recovery_id and device_key=context->>'deviceKey' and status='PREPARING' and expires_at>now();
  if not found then raise exception 'This recovery upload is no longer available.'; end if;
end;
$$;

-- Publication is an external operation: reserve its validated database state
-- first and keep the old replay untouched until the provider confirms. An
-- interrupted publication stays ATTACHING and resumes idempotently; never make
-- its file private after an uncertain database commit.
create function public.reserve_broadcast_recovery_attachment(credential_hash text,recovery_id uuid,recorded_started_at timestamptz,provider_duration double precision,replay_url text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare context jsonb; attempt public.broadcast_recording_recoveries%rowtype; kickoff timestamptz; final_whistle timestamptz; recording_end timestamptz;
begin
  context:=public.broadcast_recovery_context(credential_hash);
  select * into attempt from public.broadcast_recording_recoveries where id=recovery_id and device_key=context->>'deviceKey' for update;
  if attempt.id is null or attempt.recording_started_at is distinct from recorded_started_at then raise exception 'The recording does not belong to this match and saved start time.'; end if;
  if attempt.status='ATTACHED' then return jsonb_build_object('attached',true,'uploadId',attempt.id); end if;
  if attempt.status not in ('UPLOADING','ATTACHING') or (attempt.status='UPLOADING' and attempt.expires_at<=now()) or attempt.provider_video_id is null then raise exception 'This recording upload has expired or is unavailable.'; end if;
  if attempt.original_replay is distinct from context->'originalReplay' then raise exception 'The match replay changed while uploading. Review it before preparing another recovery.'; end if;
  if provider_duration is null or replay_url is null or not (provider_duration>0 and provider_duration<=10800) or replay_url !~ ('^https://customer-[a-z0-9-]+\.cloudflarestream\.com/'||attempt.provider_video_id||'/manifest/video\.m3u8$') then raise exception 'The recording is not ready to attach.'; end if;
  if attempt.status='ATTACHING' and (attempt.verified_duration is distinct from provider_duration or attempt.publication_replay_url is distinct from replay_url) then raise exception 'The reserved recording changed. Ask an organizer for help.'; end if;
  if exists(select 1 from public.broadcast_recording_recoveries where match_kind=attempt.match_kind and match_id=attempt.match_id and status='ATTACHING' and id<>attempt.id) then raise exception 'Finish the reserved replay replacement first.'; end if;
  if attempt.match_kind='SOLO' then
    select min(occurred_at) filter(where event_type='MATCH_STARTED'),max(occurred_at) filter(where event_type='MATCH_ENDED') into kickoff,final_whistle from public.open_queue_events where game_id=attempt.match_id;
  else
    select min(created_at) filter(where event_type='MATCH_STARTED'),max(created_at) filter(where event_type='MATCH_ENDED') into kickoff,final_whistle from public.fixture_events where fixture_id=attempt.match_id;
  end if;
  recording_end:=recorded_started_at+make_interval(secs=>provider_duration);
  if kickoff is null or final_whistle is null or final_whistle<kickoff then raise exception 'Match start and finish timestamps are required to align this recording.'; end if;
  if recorded_started_at>kickoff or recording_end<final_whistle then raise exception 'This file does not cover the complete match. Keep the original replay and ask an organizer for help.'; end if;
  update public.broadcast_recording_recoveries set status='ATTACHING',attachment_started_at=coalesce(attachment_started_at,now()),verified_duration=provider_duration,publication_replay_url=replay_url where id=attempt.id;
  return jsonb_build_object('reserved',true,'attached',false,'uploadId',attempt.id);
end;
$$;

create function public.attach_broadcast_recovery(credential_hash text,recovery_id uuid,recorded_started_at timestamptz,provider_duration double precision,replay_url text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare context jsonb; attempt public.broadcast_recording_recoveries%rowtype; recording_end timestamptz;
begin
  context:=public.broadcast_recovery_context(credential_hash);
  select * into attempt from public.broadcast_recording_recoveries where id=recovery_id and device_key=context->>'deviceKey' for update;
  if attempt.id is null or attempt.recording_started_at is distinct from recorded_started_at then raise exception 'The recording does not belong to this match and saved start time.'; end if;
  if attempt.status='ATTACHED' then return jsonb_build_object('attached',true,'uploadId',attempt.id); end if;
  if attempt.status<>'ATTACHING' then raise exception 'Reserve this recording before publishing and attaching it.'; end if;
  -- Repeat authorization, exact metadata, coverage and original-replay checks
  -- after publication; reserve is idempotent for this exact attempt.
  perform public.reserve_broadcast_recovery_attachment(credential_hash,recovery_id,recorded_started_at,provider_duration,replay_url);
  recording_end:=recorded_started_at+make_interval(secs=>attempt.verified_duration);
  if attempt.match_kind='SOLO' then
    update public.open_queue_broadcasts set status='REPLAY_READY',active_video_id=attempt.provider_video_id,replay_hls_url=replay_url,
      stream_started_at=recorded_started_at,stream_stopped_at=recording_end,recording_ready_at=now(),error_message=null,recovery_upload_id=attempt.id where game_id=attempt.match_id;
    update public.open_queue_games set video_url=replay_url where id=attempt.match_id;
  else
    update public.fixture_broadcasts set status='REPLAY_READY',active_video_id=attempt.provider_video_id,replay_hls_url=replay_url,
      stream_started_at=recorded_started_at,stream_stopped_at=recording_end,recording_ready_at=now(),error_message=null,recovery_upload_id=attempt.id where fixture_id=attempt.match_id;
    update public.fixtures set video_url=replay_url where id=attempt.match_id;
  end if;
  update public.broadcast_recording_recoveries set status='ATTACHED',attached_at=now(),upload_url=null where id=attempt.id;
  return jsonb_build_object('attached',true,'uploadId',attempt.id);
end;
$$;

-- Used by normal polling and webhooks so a late Cloudflare response cannot
-- overwrite a manually recovered replay or a newer source video.
create function public.sync_broadcast_replay(kind text,target_id uuid,video_id text,replay_url text,ready_at timestamptz,expected_requested_at timestamptz,recording_started_at timestamptz default null,expected_input_id text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare broadcast jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  if kind='SOLO' then select to_jsonb(b) into broadcast from public.open_queue_broadcasts b where game_id=target_id for update;
  elsif kind='CLAN' then select to_jsonb(b) into broadcast from public.fixture_broadcasts b where fixture_id=target_id for update;
  else raise exception 'Invalid match kind.'; end if;
  if broadcast is null or broadcast->>'recovery_upload_id' is not null
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

-- Some lifecycle updates predate the atomic replay RPC. Guard their writes as
-- well, so a response already in flight cannot change a reserved source. Row
-- locks serialize this check with reserve/finalize; do not acquire the global
-- advisory lock from a row trigger (that would invert their lock order).
create function public.guard_broadcast_recovery_publication()
returns trigger language plpgsql security definer set search_path='' as $$
declare pending public.broadcast_recording_recoveries%rowtype; kind text; target uuid; new_row jsonb; old_row jsonb; provenance uuid;
begin
  new_row:=to_jsonb(new); old_row:=to_jsonb(old);
  kind:=case when tg_table_name in ('open_queue_broadcasts','open_queue_games') then 'SOLO' else 'CLAN' end;
  target:=coalesce((new_row->>'game_id')::uuid,(new_row->>'fixture_id')::uuid,(new_row->>'id')::uuid);
  select * into pending from public.broadcast_recording_recoveries where match_kind=kind and match_id=target and status='ATTACHING';
  if pending.id is null then return new; end if;
  if tg_table_name in ('open_queue_broadcasts','fixture_broadcasts') then
    if (new_row->>'recovery_upload_id')::uuid=pending.id then return new; end if;
    if (new_row->'active_video_id',new_row->'replay_hls_url',new_row->'stream_started_at',new_row->'stream_stopped_at',new_row->'stream_requested_at',new_row->'live_input_id',new_row->'recovery_upload_id')
      is distinct from (old_row->'active_video_id',old_row->'replay_hls_url',old_row->'stream_started_at',old_row->'stream_stopped_at',old_row->'stream_requested_at',old_row->'live_input_id',old_row->'recovery_upload_id') then
      raise exception 'A replay replacement is reserved. Finish it before changing its recording source.';
    end if;
  elsif new_row->>'video_url' is distinct from old_row->>'video_url' then
    if kind='SOLO' then select recovery_upload_id into provenance from public.open_queue_broadcasts where game_id=target;
    else select recovery_upload_id into provenance from public.fixture_broadcasts where fixture_id=target; end if;
    if provenance is distinct from pending.id or new_row->>'video_url' is distinct from pending.publication_replay_url then
      raise exception 'A replay replacement is reserved. Finish it before changing the match replay.';
    end if;
  end if;
  return new;
end;
$$;
create trigger protect_fixture_recovery_publication before update on public.fixture_broadcasts for each row execute function public.guard_broadcast_recovery_publication();
create trigger protect_solo_recovery_publication before update on public.open_queue_broadcasts for each row execute function public.guard_broadcast_recovery_publication();
create trigger protect_fixture_recovery_game before update of video_url on public.fixtures for each row execute function public.guard_broadcast_recovery_publication();
create trigger protect_solo_recovery_game before update of video_url on public.open_queue_games for each row execute function public.guard_broadcast_recovery_publication();

revoke all on function public.broadcast_recovery_context(text),public.begin_broadcast_recovery(text,timestamptz,text,bigint),
  public.guard_broadcast_recovery_publication(),
  public.reserve_broadcast_recovery_attachment(text,uuid,timestamptz,double precision,text),
  public.store_broadcast_recovery_upload(text,uuid,text,text),public.attach_broadcast_recovery(text,uuid,timestamptz,double precision,text),
  public.sync_broadcast_replay(text,uuid,text,text,timestamptz,timestamptz,timestamptz,text) from public,anon,authenticated;
grant execute on function public.broadcast_recovery_context(text),public.begin_broadcast_recovery(text,timestamptz,text,bigint),
  public.guard_broadcast_recovery_publication(),
  public.reserve_broadcast_recovery_attachment(text,uuid,timestamptz,double precision,text),
  public.store_broadcast_recovery_upload(text,uuid,text,text),public.attach_broadcast_recovery(text,uuid,timestamptz,double precision,text),
  public.sync_broadcast_replay(text,uuid,text,text,timestamptz,timestamptz,timestamptz,text) to service_role;
