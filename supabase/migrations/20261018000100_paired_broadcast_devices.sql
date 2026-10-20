-- Device capabilities are scoped to one referee and one match. Only trusted
-- server routes can call these functions or read hashes; clients never receive
-- service credentials or a capability shared by other laptops.
create table public.broadcast_device_credentials (
  device_key text primary key references public.broadcast_devices(device_key) on delete cascade,
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  match_kind text not null check (match_kind in ('SOLO','CLAN')),
  fixture_id uuid references public.fixtures(id) on delete cascade,
  open_queue_game_id uuid references public.open_queue_games(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  pitch_key text not null,
  reservation_active boolean not null default false,
  test_input_id text,
  test_started_at timestamptz,
  created_at timestamptz not null default now(),
  check ((match_kind='CLAN' and fixture_id is not null and open_queue_game_id is null)
    or (match_kind='SOLO' and fixture_id is null and open_queue_game_id is not null))
);
create unique index broadcast_device_one_fixture on public.broadcast_device_credentials(fixture_id)
  where revoked_at is null and fixture_id is not null;
create unique index broadcast_device_one_solo_game on public.broadcast_device_credentials(open_queue_game_id)
  where revoked_at is null and open_queue_game_id is not null;
create unique index broadcast_device_one_pitch_stream on public.broadcast_device_credentials(pitch_key)
  where reservation_active;

create table public.broadcast_pairing_codes (
  code_hash text primary key check (code_hash ~ '^[a-f0-9]{64}$'),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  match_kind text not null check (match_kind in ('SOLO','CLAN')),
  match_id uuid not null,
  expires_at timestamptz not null,
  redeemed_device_key text references public.broadcast_devices(device_key) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.broadcast_device_credentials enable row level security;
alter table public.broadcast_pairing_codes enable row level security;
revoke all on public.broadcast_device_credentials,public.broadcast_pairing_codes from public,anon,authenticated;
grant all on public.broadcast_device_credentials,public.broadcast_pairing_codes to service_role;
alter table public.fixture_broadcasts add column device_key text references public.broadcast_devices(device_key);
alter table public.open_queue_broadcasts add column device_key text references public.broadcast_devices(device_key);

create function public.broadcast_match_context(actor_id uuid,kind text,target_id uuid,allow_finished boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare staff public.referee_profiles%rowtype; game jsonb; result jsonb;
begin
  select * into staff from public.referee_profiles where profile_id=actor_id and is_active;
  if staff.profile_id is null then raise exception 'This account is not an active referee.' using errcode='42501'; end if;
  if kind='SOLO' then
    select to_jsonb(g) into game from public.open_queue_games g where g.id=target_id;
    if staff.role<>'admin' and not exists(select 1 from public.open_queue_referee_assignments where game_id=target_id and referee_id=actor_id) then
      raise exception 'This match is not assigned to you.' using errcode='42501';
    end if;
    result:=jsonb_build_object('matchLabel','White Team vs Black Team','startsAt',game->>'starts_at');
  elsif kind='CLAN' then
    select to_jsonb(f) into game from public.fixtures f where f.id=target_id;
    if staff.role<>'admin' and not exists(select 1 from public.fixture_referee_assignments where fixture_id=target_id and referee_id=actor_id) then
      raise exception 'This match is not assigned to you.' using errcode='42501';
    end if;
    select jsonb_build_object('matchLabel',coalesce(h.name,'Home')||' vs '||coalesce(a.name,'Away'),'startsAt',null)
      into result from public.fixtures f left join public.clans h on h.id=f.home_clan_id
      left join public.clans a on a.id=f.away_clan_id where f.id=target_id;
  else raise exception 'Invalid match kind.'; end if;
  if game is null then raise exception 'Match not found.'; end if;
  if not allow_finished and game->>'status' in ('FINAL','CANCELLED') then raise exception 'This match is already finished.'; end if;
  return result||jsonb_build_object('matchKind',kind,'matchId',target_id,'venue',game->>'venue',
    'matchStatus',game->>'status','refereeName',staff.display_name,
    'pitchKey','venue:'||lower(regexp_replace(trim(game->>'venue'),'\s+',' ','g')));
end;
$$;

create function public.create_broadcast_pairing(actor_id uuid,kind text,target_id uuid,new_code_hash text)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare deadline timestamptz:=now()+interval '10 minutes'; context jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  context:=public.broadcast_match_context(actor_id,kind,target_id,false);
  if exists(select 1 from public.broadcast_device_credentials where test_input_id is not null
    and (pitch_key=context->>'pitchKey' or (match_kind=kind and coalesce(fixture_id,open_queue_game_id)=target_id))) then
    raise exception 'Finish the connection test cleanup before pairing another laptop on this pitch.';
  end if;
  if (kind='SOLO' and exists(select 1 from public.open_queue_broadcasts where game_id=target_id and status in ('STARTING','LIVE','STOPPING')))
    or (kind='CLAN' and exists(select 1 from public.fixture_broadcasts where fixture_id=target_id and status in ('STARTING','LIVE','STOPPING'))) then
    raise exception 'Stop the existing broadcast before pairing another laptop.';
  end if;
  -- Expired inactive credentials can be retired without interrupting a stream.
  update public.broadcast_device_credentials set revoked_at=now() where revoked_at is null
    and expires_at<=now() and not reservation_active and test_input_id is null;
  if exists(select 1 from public.broadcast_device_credentials where revoked_at is null and match_kind=kind
    and coalesce(fixture_id,open_queue_game_id)=target_id) then
    raise exception 'Disconnect the paired laptop before pairing another one.';
  end if;
  delete from public.broadcast_pairing_codes where expires_at<now()
    or (owner_profile_id=actor_id and match_kind=kind and match_id=target_id and redeemed_device_key is null);
  insert into public.broadcast_pairing_codes(code_hash,owner_profile_id,match_kind,match_id,expires_at)
    values(new_code_hash,actor_id,kind,target_id,deadline);
  return deadline;
end;
$$;

create function public.redeem_broadcast_pairing(pair_code_hash text,new_token_hash text,laptop_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare pair public.broadcast_pairing_codes%rowtype; device public.broadcast_device_credentials%rowtype;
  context jsonb; new_key text;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  select * into pair from public.broadcast_pairing_codes where code_hash=pair_code_hash for update;
  if pair.code_hash is null or pair.expires_at<=now() then raise exception 'Pairing code is invalid or expired.' using errcode='42501'; end if;
  context:=public.broadcast_match_context(pair.owner_profile_id,pair.match_kind,pair.match_id,false);
  if pair.redeemed_device_key is not null then
    select * into device from public.broadcast_device_credentials where device_key=pair.redeemed_device_key;
    if device.revoked_at is not null or device.expires_at<=now() or device.token_hash<>new_token_hash then
      raise exception 'Pairing code has already been used.' using errcode='42501';
    end if;
  else
    if exists(select 1 from public.broadcast_device_credentials where test_input_id is not null
      and (pitch_key=context->>'pitchKey' or (match_kind=pair.match_kind and coalesce(fixture_id,open_queue_game_id)=pair.match_id))) then
      raise exception 'Finish the connection test cleanup before pairing another laptop on this pitch.';
    end if;
    if char_length(trim(laptop_name)) not between 2 and 120 then raise exception 'Choose a laptop name between 2 and 120 characters.'; end if;
    if exists(select 1 from public.broadcast_device_credentials where revoked_at is null
      and match_kind=pair.match_kind and coalesce(fixture_id,open_queue_game_id)=pair.match_id) then
      raise exception 'This match already has a paired laptop.';
    end if;
    new_key:='paired-'||gen_random_uuid()::text;
    insert into public.broadcast_devices(device_key,display_name) values(new_key,trim(laptop_name));
    insert into public.broadcast_device_credentials(device_key,owner_profile_id,match_kind,fixture_id,open_queue_game_id,token_hash,expires_at,pitch_key)
      values(new_key,pair.owner_profile_id,pair.match_kind,case when pair.match_kind='CLAN' then pair.match_id end,
        case when pair.match_kind='SOLO' then pair.match_id end,new_token_hash,now()+interval '24 hours',context->>'pitchKey') returning * into device;
    update public.broadcast_pairing_codes set redeemed_device_key=new_key where code_hash=pair_code_hash;
  end if;
  return context||jsonb_build_object('deviceKey',device.device_key,'ownerId',device.owner_profile_id,
    'expiresAt',device.expires_at,'displayName',(select display_name from public.broadcast_devices where device_key=device.device_key),
    'status',(select status from public.broadcast_devices where device_key=device.device_key));
end;
$$;

create function public.broadcast_device_session(credential_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare device public.broadcast_device_credentials%rowtype; context jsonb; camera public.broadcast_devices%rowtype;
begin
  select * into device from public.broadcast_device_credentials where token_hash=credential_hash
    and revoked_at is null and expires_at>now();
  if device.device_key is null then raise exception 'Laptop pairing expired or was disconnected. Pair it again.' using errcode='42501'; end if;
  context:=public.broadcast_match_context(device.owner_profile_id,device.match_kind,coalesce(device.fixture_id,device.open_queue_game_id),true);
  select * into camera from public.broadcast_devices where device_key=device.device_key;
  return context||jsonb_build_object('deviceKey',device.device_key,'ownerId',device.owner_profile_id,
    'expiresAt',device.expires_at,'displayName',camera.display_name,'status',camera.status);
end;
$$;

create function public.reserve_broadcast_start(actor_id uuid,kind text,target_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare device public.broadcast_device_credentials%rowtype; camera public.broadcast_devices%rowtype;
  context jsonb; owner_context jsonb; stream_status text; command_id uuid;
begin
  -- One transaction owns reservation + command + displayed lifecycle. The unique
  -- pitch index also prevents accidental parallel starts from other callers.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  context:=public.broadcast_match_context(actor_id,kind,target_id,false);
  if (kind='SOLO' and context->>'matchStatus' not in ('FULL','LIVE')) or
     (kind='CLAN' and context->>'matchStatus' not in ('SCHEDULED','LIVE')) then raise exception 'This match is not ready to stream.'; end if;
  select * into device from public.broadcast_device_credentials where revoked_at is null and expires_at>now()
    and match_kind=kind and coalesce(fixture_id,open_queue_game_id)=target_id for update;
  if device.device_key is null then raise exception 'Pair a laptop with this match first.'; end if;
  if exists(select 1 from public.broadcast_device_credentials where test_input_id is not null
    and (pitch_key=context->>'pitchKey' or (match_kind=kind and coalesce(fixture_id,open_queue_game_id)=target_id))) then
    raise exception 'Finish the connection test cleanup before starting the match stream.';
  end if;
  owner_context:=public.broadcast_match_context(device.owner_profile_id,kind,target_id,false);
  select * into camera from public.broadcast_devices where device_key=device.device_key for update;
  if not camera.obs_connected or camera.last_seen_at is null or camera.last_seen_at<now()-interval '15 seconds' then
    raise exception 'Camera laptop is offline. Open Fieldrush Broadcaster first.';
  end if;
  if camera.obs_streaming and (camera.current_fixture_id is distinct from device.fixture_id
    or camera.current_open_queue_game_id is distinct from device.open_queue_game_id) then raise exception 'Camera is already streaming another match.'; end if;
  if exists(select 1 from public.broadcast_device_credentials where reservation_active
    and pitch_key=context->>'pitchKey' and device_key<>device.device_key) then raise exception 'This pitch already has an active broadcast.'; end if;
  if kind='SOLO' then select status into stream_status from public.open_queue_broadcasts where game_id=target_id for update;
  else select status into stream_status from public.fixture_broadcasts where fixture_id=target_id for update; end if;
  if stream_status is null then raise exception 'Prepare the match stream before starting the laptop.'; end if;
  if stream_status in ('STOPPING','PROCESSING','REPLAY_READY') then raise exception 'This broadcast has ended or is finishing.'; end if;
  if stream_status in ('STARTING','LIVE') then return device.device_key; end if;
  update public.broadcast_device_credentials set reservation_active=true,pitch_key=context->>'pitchKey' where device_key=device.device_key;
  insert into public.broadcast_commands(fixture_id,open_queue_game_id,device_key,action,requested_by)
    values(device.fixture_id,device.open_queue_game_id,device.device_key,'START_STREAM',actor_id) returning id into command_id;
  if kind='SOLO' then
    update public.open_queue_broadcasts set device_key=device.device_key,status='STARTING',stream_requested_at=now(),
      stream_started_at=null,stream_stopped_at=null,recording_ready_at=null,replay_hls_url=null,active_video_id=null,error_message=null where game_id=target_id;
  else
    update public.fixture_broadcasts set device_key=device.device_key,status='STARTING',stream_requested_at=now(),
      stream_started_at=null,stream_stopped_at=null,recording_ready_at=null,replay_hls_url=null,active_video_id=null,error_message=null where fixture_id=target_id;
  end if;
  return device.device_key;
end;
$$;

create function public.revoke_broadcast_device(actor_id uuid,target_device_key text)
returns void language plpgsql security definer set search_path='' as $$
declare device public.broadcast_device_credentials%rowtype; staff public.referee_profiles%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  select * into staff from public.referee_profiles where profile_id=actor_id and is_active;
  select * into device from public.broadcast_device_credentials where device_key=target_device_key for update;
  if staff.profile_id is null or device.device_key is null or (staff.role<>'admin' and device.owner_profile_id<>actor_id) then
    raise exception 'This laptop is not paired to your account.' using errcode='42501'; end if;
  if device.test_input_id is not null then raise exception 'Finish the connection test before disconnecting the laptop.'; end if;
  if device.reservation_active or exists(select 1 from public.broadcast_devices where device_key=target_device_key and obs_streaming)
    or exists(select 1 from public.broadcast_commands where device_key=target_device_key and status in ('PENDING','CLAIMED')) then
    raise exception 'Stop the broadcast before disconnecting the laptop.'; end if;
  update public.broadcast_device_credentials set revoked_at=coalesce(revoked_at,now()) where device_key=target_device_key;
  update public.broadcast_devices set status='OFFLINE',obs_connected=false where device_key=target_device_key;
end;
$$;

-- Admin recovery revokes command access first and holds the pitch until the
-- server confirms the provider input is disabled. A failed provider request
-- can be retried without allowing another laptop to take over prematurely.
create function public.begin_broadcast_device_revocation(actor_id uuid,target_device_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare device public.broadcast_device_credentials%rowtype; input_id text;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-broadcast-pairing',0));
  if not exists(select 1 from public.referee_profiles where profile_id=actor_id and is_active and role='admin') then
    raise exception 'Admin access required to recover an active laptop.' using errcode='42501'; end if;
  select * into device from public.broadcast_device_credentials where device_key=target_device_key for update;
  if device.device_key is null then raise exception 'Paired laptop not found.'; end if;
  update public.broadcast_device_credentials set revoked_at=coalesce(revoked_at,now()) where device_key=target_device_key;
  update public.broadcast_commands set status='FAILED',completed_at=now(),error_message='Laptop disconnected by an admin.'
    where device_key=target_device_key and status in ('PENDING','CLAIMED');
  if device.match_kind='SOLO' then select live_input_id into input_id from public.open_queue_broadcasts where game_id=device.open_queue_game_id and device_key=target_device_key;
  else select live_input_id into input_id from public.fixture_broadcasts where fixture_id=device.fixture_id and device_key=target_device_key; end if;
  return jsonb_build_object('matchKind',device.match_kind,'matchId',coalesce(device.fixture_id,device.open_queue_game_id),
    'inputId',input_id,'testInputId',device.test_input_id);
end;
$$;

revoke all on function public.broadcast_match_context(uuid,text,uuid,boolean),
  public.create_broadcast_pairing(uuid,text,uuid,text),public.redeem_broadcast_pairing(text,text,text),
  public.broadcast_device_session(text),public.reserve_broadcast_start(uuid,text,uuid),
  public.revoke_broadcast_device(uuid,text),public.begin_broadcast_device_revocation(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_match_context(uuid,text,uuid,boolean),
  public.create_broadcast_pairing(uuid,text,uuid,text),public.redeem_broadcast_pairing(text,text,text),
  public.broadcast_device_session(text),public.reserve_broadcast_start(uuid,text,uuid),
  public.revoke_broadcast_device(uuid,text),public.begin_broadcast_device_revocation(uuid,text) to service_role;
