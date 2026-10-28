-- Optional alerts come from committed authoritative events, not UI reads or
-- arbitrary profile edits. Receipts consume suppressed events too: opting in
-- later never replays a backlog, and cron/provider retries cannot duplicate it.
create table fieldrush_private.notification_event_receipts(
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  notification_type text not null,
  event_key text not null check(char_length(event_key) between 1 and 512),
  notification_id uuid references public.notifications(id) on delete set null,
  recorded_at timestamptz not null default clock_timestamp(),
  primary key(recipient_id,notification_type,event_key)
);
create table fieldrush_private.notification_event_activation(
  singleton boolean primary key default true check(singleton),
  activated_at timestamptz not null default clock_timestamp()
);
insert into fieldrush_private.notification_event_activation(singleton) values(true);
create table fieldrush_private.notification_ladder_snapshots(
  season_id text not null references public.fieldrush_seasons(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  rating_track text not null check(rating_track in ('OUTFIELD','GOALKEEPER')),
  city_id text not null references public.fieldrush_cities(id),
  city_rank bigint not null check(city_rank>0),
  revision bigint not null default 1 check(revision>0),
  observed_at timestamptz not null default clock_timestamp(),
  primary key(season_id,profile_id,rating_track)
);
create table fieldrush_private.notification_news_publications(
  id uuid primary key,
  actor_admin_id uuid not null references public.referee_profiles(profile_id),
  title text not null,
  body text not null,
  reason text not null,
  expires_at timestamptz not null,
  recipient_count integer not null default 0,
  created_at timestamptz not null default clock_timestamp()
);
revoke all on fieldrush_private.notification_event_receipts,
  fieldrush_private.notification_event_activation,fieldrush_private.notification_ladder_snapshots,
  fieldrush_private.notification_news_publications from public,anon,authenticated,service_role;
alter table fieldrush_private.notification_event_receipts enable row level security;
alter table fieldrush_private.notification_event_activation enable row level security;
alter table fieldrush_private.notification_ladder_snapshots enable row level security;
alter table fieldrush_private.notification_news_publications enable row level security;

create function fieldrush_private.emit_notification_event(recipient uuid,event_type text,event_key_to_use text,
  title_to_use text,body_to_use text,entity_type text,entity_id uuid,event_data jsonb)
returns boolean language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare receipt_created boolean; saved_id uuid;
begin
  if event_type is null or event_type not in ('GAME_REMINDER','CLAN_CALLUP','LADDER_MOVE','REPLAY_READY','NEWS_AND_OFFERS')
    or char_length(coalesce(event_key_to_use,'')) not between 1 and 512
    or jsonb_typeof(event_data) is distinct from 'object' then
    raise exception 'Invalid optional notification event.' using errcode='22023';
  end if;
  if public.is_fieldrush_account_active(recipient) is distinct from true then return false; end if;
  insert into fieldrush_private.notification_event_receipts(recipient_id,notification_type,event_key)
  values(recipient,event_type,event_key_to_use) on conflict do nothing returning true into receipt_created;
  if receipt_created is distinct from true then return false; end if;
  insert into public.notifications(recipient_profile_id,type,title,body,related_entity_type,related_entity_id,data)
  values(recipient,event_type,title_to_use,body_to_use,entity_type,entity_id,
    event_data||jsonb_build_object('fieldrush_event_key',event_key_to_use)) returning id into saved_id;
  update fieldrush_private.notification_event_receipts set notification_id=saved_id
    where recipient_id=recipient and notification_type=event_type and event_key=event_key_to_use;
  return saved_id is not null;
end;
$$;
revoke all on function fieldrush_private.emit_notification_event(uuid,text,text,text,text,text,uuid,jsonb)
  from public,anon,authenticated,service_role;

-- Automatic initial rosters also carry a confirmed_by value. Wrap the actual
-- captain confirmation action instead of treating raw roster inserts as calls.
alter function public.set_fixture_reliability_roster(uuid,uuid,uuid[],text)
  rename to set_fixture_reliability_roster_before_notifications;
revoke all on function public.set_fixture_reliability_roster_before_notifications(uuid,uuid,uuid[],text)
  from public,anon,authenticated,service_role;
create function public.set_fixture_reliability_roster(fixture_id_to_manage uuid,clan_id_to_manage uuid,
  profile_ids_to_confirm uuid[],note_to_use text default null)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare kickoff timestamptz; result jsonb; selected record;
begin
  -- Original server action still validates captain identity, clan membership,
  -- exact side size, suspensions and the deadline before touching the roster.
  result:=public.set_fixture_reliability_roster_before_notifications(
    fixture_id_to_manage,clan_id_to_manage,profile_ids_to_confirm,note_to_use);
  select public.fixture_start_at(f.match_date,f.time_slot) into kickoff from public.fixtures f
    where f.id=fixture_id_to_manage and f.status in ('OPEN','SCHEDULED')
      and clan_id_to_manage in (f.home_clan_id,f.away_clan_id);
  if kickoff is null or kickoff<=clock_timestamp() then return result; end if;
  for selected in select r.id,r.profile_id from public.fixture_reliability_roster_history r
    where r.fixture_id=fixture_id_to_manage and r.clan_id=clan_id_to_manage
      and r.status='CONFIRMED' and r.profile_id=any(profile_ids_to_confirm)
  loop
    perform fieldrush_private.emit_notification_event(selected.profile_id,'CLAN_CALLUP','roster:'||selected.id::text,
      'You’re in the lineup','Your clan selected you for an upcoming match. Open the fixture for details.',
      'FIXTURE',fixture_id_to_manage,jsonb_build_object('fixture_id',fixture_id_to_manage,'roster_entry_id',selected.id,
        'clan_id',clan_id_to_manage,'expires_at',kickoff));
  end loop;
  return result;
end;
$$;
revoke all on function public.set_fixture_reliability_roster(uuid,uuid,uuid[],text) from public,anon;
grant execute on function public.set_fixture_reliability_roster(uuid,uuid,uuid[],text) to authenticated,service_role;

create function fieldrush_private.emit_ready_replay(match_kind_to_use text,match_id_to_use uuid)
returns integer language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare ready_at timestamptz; video_id text; participant record; sent integer:=0; activated timestamptz;
begin
  select activated_at into activated from fieldrush_private.notification_event_activation where singleton;
  if match_kind_to_use='SOLO' then
    select b.recording_ready_at,b.active_video_id into ready_at,video_id
    from public.open_queue_broadcasts b join public.open_queue_games g on g.id=b.game_id
    where b.game_id=match_id_to_use and g.status='FINAL' and b.provider='cloudflare' and b.status='REPLAY_READY'
      and nullif(trim(b.replay_hls_url),'') is not null and nullif(trim(b.active_video_id),'') is not null;
  elsif match_kind_to_use='CLAN' then
    select b.recording_ready_at,b.active_video_id into ready_at,video_id
    from public.fixture_broadcasts b join public.fixtures f on f.id=b.fixture_id
    where b.fixture_id=match_id_to_use and f.status='FINAL' and b.provider='cloudflare' and b.status='REPLAY_READY'
      and nullif(trim(b.replay_hls_url),'') is not null and nullif(trim(b.active_video_id),'') is not null;
  else return 0;
  end if;
  if ready_at is null or ready_at<greatest(activated,clock_timestamp()-interval '24 hours') then return 0; end if;
  for participant in select distinct a.profile_id from public.current_match_attendance_records a
    where a.match_kind=match_kind_to_use and case when match_kind_to_use='SOLO' then a.open_queue_game_id=match_id_to_use else a.fixture_id=match_id_to_use end
      and a.checked_in_at is not null and a.cancelled_at is null and coalesce(a.outcome,'') not in
        ('NO_SHOW','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE','FIELD_CANCELLED')
  loop
    if fieldrush_private.emit_notification_event(participant.profile_id,'REPLAY_READY',
      'replay:'||match_kind_to_use||':'||match_id_to_use::text||':'||video_id,'Your replay is ready',
      'Watch the replay from your match.',case when match_kind_to_use='SOLO' then 'OPEN_QUEUE_GAME' else 'FIXTURE' end,
      match_id_to_use,jsonb_build_object('match_kind',match_kind_to_use,'match_id',match_id_to_use,'video_id',video_id,
        'expires_at',ready_at+interval '24 hours')) then sent:=sent+1; end if;
  end loop;
  return sent;
end;
$$;
revoke all on function fieldrush_private.emit_ready_replay(text,uuid) from public,anon,authenticated,service_role;
create function fieldrush_private.notify_ready_replay()
returns trigger language plpgsql security definer set search_path=pg_catalog,fieldrush_private,pg_temp as $$
begin
  if new.status='REPLAY_READY' then
    if tg_table_name='open_queue_broadcasts' then perform fieldrush_private.emit_ready_replay('SOLO',new.game_id);
    else perform fieldrush_private.emit_ready_replay('CLAN',new.fixture_id); end if;
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.notify_ready_replay() from public,anon,authenticated,service_role;
create trigger notify_ready_replay after insert or update of status,recording_ready_at on public.open_queue_broadcasts
  for each row execute function fieldrush_private.notify_ready_replay();
create trigger notify_ready_replay after insert or update of status,recording_ready_at on public.fixture_broadcasts
  for each row execute function fieldrush_private.notify_ready_replay();

-- One committed snapshot per sweep, never per-player update triggers inside a
-- multi-player settlement. The first observation and a city change are silent.
create function fieldrush_private.observe_notification_ladder()
returns integer language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,fieldrush_rating_private,pg_temp as $$
declare season public.fieldrush_seasons%rowtype; player record; sent integer:=0; next_revision bigint;
begin
  select * into season from public.fieldrush_seasons where lifecycle='ACTIVE' and visible_to_players;
  if season.id is null then return 0; end if;
  for player in with canonical as materialized (
    select t.track,r.profile_id,r.primary_city_id,row_number() over(partition by t.track,r.primary_city_id order by r.rank) city_rank
    from (values('OUTFIELD'),('GOALKEEPER')) t(track)
    cross join lateral fieldrush_rating_private.track_rankings('GLOBAL',null,t.track,season.starts_on,season.ends_on) r
    where r.matches_played>=season.minimum_rated_games
  ) select c.*,s.city_id previous_city,s.city_rank previous_rank,s.revision previous_revision
    from canonical c join public.fieldrush_player_rating_tracks lifetime on lifetime.profile_id=c.profile_id
      and lifetime.rating_track=c.track and lifetime.matches_played>=2
    left join fieldrush_private.notification_ladder_snapshots s on s.season_id=season.id
      and s.profile_id=c.profile_id and s.rating_track=c.track
    where public.is_fieldrush_account_active(c.profile_id)
  loop
    if player.previous_city=player.primary_city_id and player.previous_rank=player.city_rank then continue; end if;
    next_revision:=coalesce(player.previous_revision,0)+1;
    if player.previous_city=player.primary_city_id and player.previous_rank is distinct from player.city_rank then
      if fieldrush_private.emit_notification_event(player.profile_id,'LADDER_MOVE',
        'ladder:'||season.id||':'||player.track||':'||player.profile_id::text||':'||next_revision::text,
        'Your city rank changed',format('Your %s city rank moved from #%s to #%s.',
          case player.track when 'GOALKEEPER' then 'Keeper' else 'Outfield' end,player.previous_rank,player.city_rank),
        null,null,jsonb_build_object('season_id',season.id,'city_id',player.primary_city_id,'rating_track',player.track,
          'previous_rank',player.previous_rank,'rank',player.city_rank)) then sent:=sent+1; end if;
    end if;
    insert into fieldrush_private.notification_ladder_snapshots(season_id,profile_id,rating_track,city_id,city_rank,revision)
    values(season.id,player.profile_id,player.track,player.primary_city_id,player.city_rank,next_revision)
    on conflict(season_id,profile_id,rating_track) do update set city_id=excluded.city_id,city_rank=excluded.city_rank,
      revision=excluded.revision,observed_at=clock_timestamp();
  end loop;
  return sent;
end;
$$;
revoke all on function fieldrush_private.observe_notification_ladder() from public,anon,authenticated,service_role;

-- Recheck event sources at dispatch, not merely at generation. An old queued
-- reminder cannot outlive a cancellation, removed call-up or withdrawn replay.
create or replace function fieldrush_private.notification_source_is_current(notification_id_to_use uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select coalesce((select case n.type
    when 'OPEN_QUEUE_PARTY_INVITE' then exists(select 1 from public.open_queue_party_members m
      join public.open_queue_parties p on p.id=m.party_id and p.status='ACTIVE'
      join public.open_queue_games g on g.id=m.game_id and g.status in ('OPEN','FULL') and g.starts_at>clock_timestamp()
      where m.id=n.related_entity_id and n.related_entity_type='OPEN_QUEUE_PARTY_MEMBERSHIP'
        and m.profile_id=n.recipient_profile_id and m.status='INVITED')
    when 'GAME_REMINDER' then case n.related_entity_type
      when 'OPEN_QUEUE_GAME' then exists(select 1 from public.open_queue_games g
        join public.open_queue_bookings b on b.game_id=g.id and b.profile_id=n.recipient_profile_id and b.status='CONFIRMED'
        where g.id=n.related_entity_id and g.status in ('OPEN','FULL') and g.starts_at>clock_timestamp()
          and extract(epoch from g.starts_at)::text=n.data->>'starts_at_epoch')
      when 'FIXTURE' then exists(select 1 from public.fixtures f
        join public.fixture_reliability_roster_history r on r.fixture_id=f.id and r.profile_id=n.recipient_profile_id
          and r.status='CONFIRMED' and r.clan_id in (f.home_clan_id,f.away_clan_id)
        join public.clan_members m on m.clan_id=r.clan_id and m.profile_id=r.profile_id and m.left_at is null
        where f.id=n.related_entity_id and f.status in ('OPEN','SCHEDULED')
          and public.fixture_start_at(f.match_date,f.time_slot)>clock_timestamp()
          and extract(epoch from public.fixture_start_at(f.match_date,f.time_slot))::text=n.data->>'starts_at_epoch')
      else false end
    when 'CLAN_CALLUP' then exists(select 1 from public.fixture_reliability_roster_history r
      join public.fixtures f on f.id=r.fixture_id
      join public.clan_members m on m.clan_id=r.clan_id and m.profile_id=r.profile_id and m.left_at is null
      where r.id::text=n.data->>'roster_entry_id' and r.profile_id=n.recipient_profile_id
        and r.fixture_id=n.related_entity_id and n.related_entity_type='FIXTURE'
        and r.status='CONFIRMED' and r.clan_id in (f.home_clan_id,f.away_clan_id)
        and f.status in ('OPEN','SCHEDULED') and public.fixture_start_at(f.match_date,f.time_slot)>clock_timestamp())
    when 'REPLAY_READY' then exists(select 1 from public.current_match_attendance_records a
      where a.profile_id=n.recipient_profile_id and a.checked_in_at is not null and a.cancelled_at is null
        and coalesce(a.outcome,'') not in ('NO_SHOW','CANCELLED_EARLY','CANCELLED_LATE','CANCELLED_VERY_LATE','FIELD_CANCELLED')
        and case n.related_entity_type
          when 'OPEN_QUEUE_GAME' then a.match_kind='SOLO' and a.open_queue_game_id=n.related_entity_id
            and exists(select 1 from public.open_queue_games g join public.open_queue_broadcasts b on b.game_id=g.id
              where g.id=n.related_entity_id and g.status='FINAL' and b.status='REPLAY_READY' and b.provider='cloudflare'
                and b.active_video_id=n.data->>'video_id' and nullif(trim(b.replay_hls_url),'') is not null)
          when 'FIXTURE' then a.match_kind='CLAN' and a.fixture_id=n.related_entity_id
            and exists(select 1 from public.fixtures f join public.fixture_broadcasts b on b.fixture_id=f.id
              where f.id=n.related_entity_id and f.status='FINAL' and b.status='REPLAY_READY' and b.provider='cloudflare'
                and b.active_video_id=n.data->>'video_id' and nullif(trim(b.replay_hls_url),'') is not null)
          else false end)
    when 'LADDER_MOVE' then exists(select 1 from public.fieldrush_seasons s
      join fieldrush_private.notification_ladder_snapshots snapshot on snapshot.season_id=s.id
      join public.fieldrush_player_rating_tracks lifetime on lifetime.profile_id=snapshot.profile_id
        and lifetime.rating_track=snapshot.rating_track and lifetime.matches_played>=2
      where s.id=n.data->>'season_id' and s.lifecycle='ACTIVE' and s.visible_to_players
        and snapshot.profile_id=n.recipient_profile_id and snapshot.rating_track=n.data->>'rating_track'
        and snapshot.city_id=n.data->>'city_id')
    when 'NEWS_AND_OFFERS' then exists(select 1 from fieldrush_private.notification_news_publications p
      where p.id::text=n.data->>'publication_id' and p.expires_at>clock_timestamp())
    else true end from public.notifications n where n.id=notification_id_to_use),false);
$$;
revoke all on function fieldrush_private.notification_source_is_current(uuid) from public,anon,authenticated,service_role;

create function fieldrush_private.process_notification_events()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare event record; reminders integer:=0; replays integer:=0; ladders integer:=0; at_time timestamptz:=clock_timestamp();
begin
  if not pg_try_advisory_xact_lock(hashtextextended('fieldrush-notification-events',0)) then
    return jsonb_build_object('skipped',true); end if;
  update public.notifications n set resolved_at=at_time
    where n.resolved_at is null and n.data?'fieldrush_event_key'
      and n.type in ('GAME_REMINDER','CLAN_CALLUP','REPLAY_READY','NEWS_AND_OFFERS')
      and not fieldrush_private.notification_source_is_current(n.id);
  -- Bounded overlap tolerates scheduler jitter; receipts make repeat sweeps
  -- idempotent. Only recent 24h/2h boundaries for still-future matches qualify.
  for event in
    with upcoming as (
      select 'SOLO'::text kind,g.id match_id,g.starts_at kickoff,b.profile_id
      from public.open_queue_games g join public.open_queue_bookings b on b.game_id=g.id and b.status='CONFIRMED'
      where g.status in ('OPEN','FULL') and g.starts_at>at_time
      union all
      select 'CLAN',f.id,public.fixture_start_at(f.match_date,f.time_slot),r.profile_id
      from public.fixtures f join public.fixture_reliability_roster_history r on r.fixture_id=f.id and r.status='CONFIRMED'
      join public.clan_members m on m.clan_id=r.clan_id and m.profile_id=r.profile_id and m.left_at is null
      where f.status in ('OPEN','SCHEDULED') and r.clan_id in (f.home_clan_id,f.away_clan_id)
        and public.fixture_start_at(f.match_date,f.time_slot)>at_time
    ) select u.*,threshold.hours from upcoming u cross join (values(24),(2)) threshold(hours)
      where u.kickoff-make_interval(hours=>threshold.hours)<=at_time
        and u.kickoff-make_interval(hours=>threshold.hours)>at_time-interval '10 minutes'
  loop
    if fieldrush_private.emit_notification_event(event.profile_id,'GAME_REMINDER',
      'reminder:'||event.kind||':'||event.match_id::text||':'||extract(epoch from event.kickoff)::text||':'||event.hours::text,
      'Your match is coming up',format('Your confirmed match starts in about %s hours. Open the fixture for details.',event.hours),
      case when event.kind='SOLO' then 'OPEN_QUEUE_GAME' else 'FIXTURE' end,event.match_id,
      jsonb_build_object('match_kind',event.kind,'match_id',event.match_id,'starts_at',event.kickoff,
        'starts_at_epoch',extract(epoch from event.kickoff),
        'hours_before',event.hours,'expires_at',event.kickoff)) then reminders:=reminders+1; end if;
  end loop;
  -- A provider may finish processing before the referee finalizes the match.
  -- This catches that order without publishing an unfinished game's replay.
  for event in select 'SOLO'::text kind,game_id match_id from public.open_queue_broadcasts
      where status='REPLAY_READY' and recording_ready_at>=at_time-interval '24 hours'
    union all select 'CLAN',fixture_id from public.fixture_broadcasts
      where status='REPLAY_READY' and recording_ready_at>=at_time-interval '24 hours'
  loop replays:=replays+fieldrush_private.emit_ready_replay(event.kind,event.match_id); end loop;
  ladders:=fieldrush_private.observe_notification_ladder();
  return jsonb_build_object('reminders',reminders,'replays',replays,'ladder_moves',ladders);
end;
$$;
revoke all on function fieldrush_private.process_notification_events() from public,anon,authenticated,service_role;

create function public.process_fieldrush_notification_events()
returns jsonb language plpgsql security definer set search_path=pg_catalog,auth,fieldrush_private,pg_temp as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Only the notification service can process events.' using errcode='42501'; end if;
  return fieldrush_private.process_notification_events();
end;
$$;
revoke all on function public.process_fieldrush_notification_events() from public,anon,authenticated;
grant execute on function public.process_fieldrush_notification_events() to service_role;

-- Deliberately no automatic marketing trigger or player-callable publisher.
-- A stable publication ID, explicit approval and audited reason are mandatory.
create function public.admin_publish_fieldrush_news(actor_admin_id uuid,publication_id_to_use uuid,
  title_to_use text,body_to_use text,reason_to_use text,expires_at_to_use timestamptz,confirmed_to_use boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare existing fieldrush_private.notification_news_publications%rowtype; recipient record; sent integer:=0;
begin
  if auth.role() is distinct from 'service_role' or public.is_active_moderation_admin(actor_admin_id) is distinct from true then
    raise exception 'Active admin access required.' using errcode='42501'; end if;
  if confirmed_to_use is distinct from true or publication_id_to_use is null
    or char_length(trim(coalesce(title_to_use,''))) not between 2 and 120
    or char_length(trim(coalesce(body_to_use,''))) not between 2 and 300
    or char_length(trim(coalesce(reason_to_use,''))) not between 10 and 1000
    or expires_at_to_use is null or expires_at_to_use<=clock_timestamp()
    or expires_at_to_use>clock_timestamp()+interval '30 days' then
    raise exception 'Confirm the publication, expiry and an audited reason.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-news:'||publication_id_to_use::text,0));
  select * into existing from fieldrush_private.notification_news_publications where id=publication_id_to_use;
  if existing.id is not null then
    if existing.actor_admin_id<>actor_admin_id or existing.title<>trim(title_to_use) or existing.body<>trim(body_to_use)
      or existing.reason<>trim(reason_to_use) or existing.expires_at<>expires_at_to_use then
      raise exception 'That publication ID already has different content.' using errcode='22023'; end if;
    return jsonb_build_object('id',existing.id,'recipients',existing.recipient_count,'already_published',true);
  end if;
  insert into fieldrush_private.notification_news_publications(id,actor_admin_id,title,body,reason,expires_at)
  values(publication_id_to_use,actor_admin_id,trim(title_to_use),trim(body_to_use),trim(reason_to_use),expires_at_to_use);
  for recipient in select s.profile_id from public.profile_settings s where s.news_and_offers
    and public.is_fieldrush_account_active(s.profile_id)
  loop
    if fieldrush_private.emit_notification_event(recipient.profile_id,'NEWS_AND_OFFERS','news:'||publication_id_to_use::text,
      trim(title_to_use),trim(body_to_use),null,null,jsonb_build_object('publication_id',publication_id_to_use,
        'expires_at',expires_at_to_use)) then sent:=sent+1; end if;
  end loop;
  update fieldrush_private.notification_news_publications set recipient_count=sent where id=publication_id_to_use;
  return jsonb_build_object('id',publication_id_to_use,'recipients',sent,'already_published',false);
end;
$$;
revoke all on function public.admin_publish_fieldrush_news(uuid,uuid,text,text,text,timestamptz,boolean)
  from public,anon,authenticated;
grant execute on function public.admin_publish_fieldrush_news(uuid,uuid,text,text,text,timestamptz,boolean) to service_role;

do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('fieldrush-notification-events','*/5 * * * *','select fieldrush_private.process_notification_events();');
  end if;
end $$;
notify pgrst,'reload schema';
