-- The approved new rating era retains every historical ledger entry and uses
-- the existing audited reset to preserve pre-reset values and unpaid lineups.
select public.reset_player_rankings('d765cbd2-c25a-4c97-a3fd-a7bdf61ab7d3'::uuid,
  'Start independent Fieldrush Outfield and Goalkeeper placement ladders.');

create table public.fieldrush_player_rating_tracks (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  rating_track text not null check(rating_track in ('OUTFIELD','GOALKEEPER')),
  skill_rating integer not null default 1200 check(skill_rating>=0),
  matches_played integer not null default 0 check(matches_played>=0),
  wins integer not null default 0 check(wins>=0),
  losses integer not null default 0 check(losses>=0),
  draws integer not null default 0 check(draws>=0),
  last_change integer not null default 0,
  ratings_reset_at timestamptz not null default public.current_player_rankings_reset_at(),
  ratings_reset_sequence bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(profile_id,rating_track)
);
alter table public.fieldrush_player_rating_tracks enable row level security;
revoke all on public.fieldrush_player_rating_tracks from public,anon,authenticated;
grant select,insert,update on public.fieldrush_player_rating_tracks to service_role;
insert into public.fieldrush_player_rating_tracks(profile_id,rating_track,ratings_reset_at,ratings_reset_sequence)
select p.id,t.track,r.reset_at,r.last_applied_sequence from public.profiles p
cross join (values('OUTFIELD'),('GOALKEEPER')) t(track)
cross join lateral (select reset_at,last_applied_sequence from fieldrush_rating_private.reset_runs order by reset_at desc limit 1) r;
create trigger set_fieldrush_rating_tracks_updated_at before update on public.fieldrush_player_rating_tracks
  for each row execute function public.set_updated_at();

create function public.fieldrush_rating_track(role_to_use text)
returns text language plpgsql immutable set search_path=public,pg_temp as $$
begin
  if role_to_use='GK' or role_to_use='GOALKEEPER' then return 'GOALKEEPER'; end if;
  if role_to_use in ('DEF','MID','ATT','OUTFIELD') then return 'OUTFIELD'; end if;
  raise exception 'Choose a valid playing position.';
end;
$$;
create function public.ensure_fieldrush_rating_tracks()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  insert into public.fieldrush_player_rating_tracks(profile_id,rating_track,ratings_reset_at,ratings_reset_sequence)
  select new.id,t.track,r.reset_at,r.last_applied_sequence
  from (values('OUTFIELD'),('GOALKEEPER')) t(track)
  cross join lateral (select reset_at,last_applied_sequence from fieldrush_rating_private.reset_runs order by reset_at desc limit 1) r
  on conflict(profile_id,rating_track) do nothing;
  return new;
end;
$$;
create trigger ensure_fieldrush_rating_tracks after insert on public.profiles
  for each row execute function public.ensure_fieldrush_rating_tracks();
revoke all on function public.fieldrush_rating_track(text),public.ensure_fieldrush_rating_tracks() from public,anon,authenticated;
grant execute on function public.fieldrush_rating_track(text) to service_role;

-- Old authenticated consumers keep reading Outfield through player_ratings.
-- It is a projection, never the source of truth for a keeper booking.
create function public.sync_legacy_outfield_rating()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.rating_track='OUTFIELD' then
    update public.player_ratings set skill_rating=new.skill_rating,matches_played=new.matches_played,
      wins=new.wins,losses=new.losses,draws=new.draws,last_change=new.last_change,
      ratings_reset_at=new.ratings_reset_at,ratings_reset_sequence=new.ratings_reset_sequence
    where profile_id=new.profile_id;
  end if;
  return new;
end;
$$;
create trigger sync_legacy_outfield_rating after insert or update on public.fieldrush_player_rating_tracks
  for each row execute function public.sync_legacy_outfield_rating();
revoke all on function public.sync_legacy_outfield_rating() from public,anon,authenticated;

alter table public.player_rating_events
  add column rating_track text check(rating_track in ('OUTFIELD','GOALKEEPER')),
  add column market_city_id text references public.fieldrush_cities(id) on delete restrict,
  add column played_at timestamptz,
  add column played_timezone text,
  add column counted_as_played boolean not null default false;
create index player_rating_events_track_season_idx
  on public.player_rating_events(profile_id,rating_track,played_at desc) where rating_track is not null;
alter table public.open_queue_bookings add column rating_track text
  generated always as (case when role='GK' then 'GOALKEEPER' else 'OUTFIELD' end) stored;
grant select(rating_track) on public.open_queue_bookings to authenticated;

create function public.snapshot_fieldrush_rating_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.open_queue_bookings%rowtype; g public.open_queue_games%rowtype; actual_start timestamptz;
begin
  if tg_op='UPDATE' then
    if row(new.rating_track,new.market_city_id,new.played_at,new.played_timezone,new.counted_as_played)
      is distinct from row(old.rating_track,old.market_city_id,old.played_at,old.played_timezone,old.counted_as_played) then
      raise exception 'The rated position, game city and original participation snapshot cannot change.';
    end if;
    return new;
  end if;
  if new.source_type<>'OPEN_QUEUE' then return new; end if;
  select * into g from public.open_queue_games where id=new.source_id;
  select * into b from public.open_queue_bookings where game_id=new.source_id and profile_id=new.profile_id
    and status='CONFIRMED';
  if g.format_version<>'FIELDRUSH_7V7' or g.starts_at<public.current_player_rankings_reset_at() then return new; end if;
  if b.id is null then raise exception 'A confirmed booked position is required for a rating event.'; end if;
  new.rating_track:=public.fieldrush_rating_track(b.role);
  new.market_city_id:=g.market_city_id;
  select min(occurred_at) into actual_start from public.open_queue_events where game_id=g.id and event_type='MATCH_STARTED';
  new.played_at:=coalesce(actual_start,g.starts_at);
  new.played_timezone:=g.timezone;
  new.counted_as_played:=b.played and not exists(select 1 from public.match_attendance_records a
    where a.booking_id=b.id and a.outcome='NO_SHOW');
  return new;
end;
$$;
create trigger a_snapshot_fieldrush_rating_event before insert or update on public.player_rating_events
  for each row execute function public.snapshot_fieldrush_rating_event();
revoke all on function public.snapshot_fieldrush_rating_event() from public,anon,authenticated;

create function public.snapshot_fieldrush_booking_rating()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' or new.role is distinct from old.role then
    select skill_rating into new.player_rating_at_booking from public.fieldrush_player_rating_tracks
      where profile_id=new.profile_id and rating_track=public.fieldrush_rating_track(new.role);
    new.player_rating_at_booking:=coalesce(new.player_rating_at_booking,1200);
  end if;
  return new;
end;
$$;
create trigger a_snapshot_fieldrush_booking_rating before insert or update of role on public.open_queue_bookings
  for each row execute function public.snapshot_fieldrush_booking_rating();
revoke all on function public.snapshot_fieldrush_booking_rating() from public,anon,authenticated;

-- The current played ledger excludes administrative walkovers/cancellations.
-- Keeping this as a read of the latest resolution also makes a later audited
-- correction update city membership/placement without overwriting SR history.
create view fieldrush_rating_private.eligible_track_events as
select e.* from public.player_rating_events e
join public.fieldrush_player_rating_tracks r on r.profile_id=e.profile_id and r.rating_track=e.rating_track
join public.open_queue_games g on e.source_type='OPEN_QUEUE' and g.id=e.source_id
left join lateral (
  select v.resolution_type from public.match_resolution_cases c
  join public.match_resolution_revisions v on v.case_id=c.id
  where c.open_queue_game_id=g.id order by v.revision desc limit 1
) resolution on true
where e.rating_track is not null and e.counted_as_played and g.status='FINAL'
  and coalesce(resolution.resolution_type,'RECORDED_RESULT')='RECORDED_RESULT'
  and not exists(select 1 from public.current_match_attendance_records attendance
    where attendance.match_kind='SOLO' and attendance.open_queue_game_id=g.id
      and attendance.profile_id=e.profile_id and attendance.outcome='NO_SHOW')
  and e.played_at>=r.ratings_reset_at and e.applied_sequence>r.ratings_reset_sequence;
revoke all on fieldrush_rating_private.eligible_track_events from public,anon,authenticated;

create function fieldrush_rating_private.current_season_bounds(day_to_use date default (now() at time zone 'America/Phoenix')::date)
returns table(starts_on date,ends_on date) language sql immutable as $$
  select case when day_to_use<'2026-10-01' then date '2026-06-01' else date_trunc('quarter',day_to_use)::date end,
    case when day_to_use<'2026-10-01' then date '2026-09-30' else (date_trunc('quarter',day_to_use)+interval '3 months - 1 day')::date end;
$$;
revoke all on function fieldrush_rating_private.current_season_bounds(date) from public,anon,authenticated;

create function public.assert_open_queue_division_eligibility(player_id_to_check uuid,game_id_to_check uuid,role_to_use text)
returns void language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare game public.open_queue_games%rowtype; rating integer; played integer; division integer; track text:=public.fieldrush_rating_track(role_to_use);
begin
  select * into game from public.open_queue_games where id=game_id_to_check for share;
  if game.id is null then raise exception 'Game not found.'; end if;
  if game.status not in ('OPEN','FULL','LIVE') then return; end if;
  select skill_rating into rating from public.fieldrush_player_rating_tracks where profile_id=player_id_to_check and rating_track=track;
  select count(*) into played from fieldrush_rating_private.eligible_track_events e
    cross join fieldrush_rating_private.current_season_bounds() season
    where e.profile_id=player_id_to_check and e.rating_track=track
      and (e.played_at at time zone e.played_timezone)::date between season.starts_on and season.ends_on;
  if coalesce(played,0)<2 then
    if game.highest_division<>1 or game.lowest_division<>5 then
      raise exception 'Placement players can only join DIV 1–5 games until their % division is revealed.',lower(track);
    end if;
    return;
  end if;
  division:=public.fieldrush_division_for_rating(coalesce(rating,1200));
  if division<game.highest_division or division>game.lowest_division then
    raise exception 'This game is for DIV %–%. Your % division is %.',game.highest_division,game.lowest_division,lower(track),division;
  end if;
end;
$$;
-- A stale caller must not silently validate Outfield while booking Keeper.
create or replace function public.assert_open_queue_division_eligibility(player_id_to_check uuid,game_id_to_check uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin raise exception 'Choose a playing position before checking division eligibility.'; end;
$$;
revoke all on function public.assert_open_queue_division_eligibility(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.assert_open_queue_division_eligibility(uuid,uuid,text) to service_role;

-- Changes to established financial, attendance and correction functions are
-- guarded against their installed definitions; unrelated safeguards survive.
create function fieldrush_rating_private.replace_required(definition text,needle text,replacement text)
returns text language plpgsql as $$
begin
  if position(needle in definition)=0 then raise exception 'Rating migration contract changed: %',left(needle,180); end if;
  return replace(definition,needle,replacement);
end;
$$;
do $migration$
declare d text; f text;
begin
  d:=pg_get_functiondef('public.preview_open_queue_booking_cost(uuid,text)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'public.assert_open_queue_division_eligibility(user_id, game_to_book.id)',
    'public.assert_open_queue_division_eligibility(user_id, game_to_book.id, normalized_role)'); execute d;
  d:=pg_get_functiondef('public.book_open_queue_game_server(uuid,text,text,text)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'public.assert_open_queue_division_eligibility(user_id, game_id_to_book)',
    'public.assert_open_queue_division_eligibility(user_id, game_id_to_book, role_to_book)');
  d:=fieldrush_rating_private.replace_required(d,'insert into public.player_ratings (profile_id)'||E'\n  values (user_id)',
    'insert into public.fieldrush_player_rating_tracks (profile_id,rating_track)'||E'\n  values (user_id,public.fieldrush_rating_track(role_to_book))');
  d:=replace(d,'on conflict (profile_id)','on conflict (profile_id,rating_track)');
  d:=fieldrush_rating_private.replace_required(d,'from public.player_ratings'||E'\n  where profile_id = user_id',
    'from public.fieldrush_player_rating_tracks'||E'\n  where profile_id = user_id and rating_track=public.fieldrush_rating_track(role_to_book)'); execute d;
  d:=pg_get_functiondef('public.enforce_open_queue_booking_capacity()'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'public.assert_open_queue_division_eligibility(new.profile_id, new.game_id)',
    'public.assert_open_queue_division_eligibility(new.profile_id, new.game_id, new.role)');
  d:=fieldrush_rating_private.replace_required(d,'(new.game_id,new.profile_id,new.status) is distinct from (old.game_id,old.profile_id,old.status)',
    '(new.game_id,new.profile_id,new.status,new.role) is distinct from (old.game_id,old.profile_id,old.status,old.role)'); execute d;

  foreach f in array array['public.find_open_queue_white_assignment(uuid,boolean)','public.assign_open_queue_teams(uuid)'] loop
    d:=pg_get_functiondef(f::regprocedure);
    d:=replace(d,'public.player_ratings','public.fieldrush_player_rating_tracks');
    d:=replace(d,'r.profile_id = b.profile_id','r.profile_id = b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)');
    d:=replace(d,'b.profile_id = r.profile_id','b.profile_id = r.profile_id and r.rating_track=public.fieldrush_rating_track(b.role)');
    if f='public.assign_open_queue_teams(uuid)' then
      d:=fieldrush_rating_private.replace_required(d,'(profile_id)'||E'\n    select profile_id',
        '(profile_id,rating_track)'||E'\n    select profile_id,public.fieldrush_rating_track(role)');
      d:=replace(d,'on conflict (profile_id)','on conflict (profile_id,rating_track)');
    end if;
    execute d;
  end loop;

  d:=pg_get_functiondef('public.snapshot_open_queue_ratings_when_live()'::regprocedure);
  d:=replace(d,'public.player_ratings','public.fieldrush_player_rating_tracks');
  d:=fieldrush_rating_private.replace_required(d,'(profile_id)'||E'\n  select booking.profile_id',
    '(profile_id,rating_track)'||E'\n  select booking.profile_id,public.fieldrush_rating_track(booking.role)');
  d:=replace(d,'on conflict (profile_id)','on conflict (profile_id,rating_track)');
  d:=fieldrush_rating_private.replace_required(d,'rating.profile_id = booking.profile_id',
    'rating.profile_id = booking.profile_id and rating.rating_track=public.fieldrush_rating_track(booking.role)');
  execute d;

  d:=pg_get_functiondef('public.referee_start_open_queue_game(uuid,uuid[],integer)'::regprocedure);
  d:=replace(d,'public.player_ratings','public.fieldrush_player_rating_tracks');
  d:=fieldrush_rating_private.replace_required(d,
    'insert into public.fieldrush_player_rating_tracks (profile_id)'||E'\n  select participant.profile_id\n  from unnest(participant_ids_to_use) participant(profile_id)',
    'insert into public.fieldrush_player_rating_tracks (profile_id,rating_track)'||E'\n  select booking.profile_id,public.fieldrush_rating_track(booking.role)\n  from public.open_queue_bookings booking\n  where booking.game_id=game_id_to_start and booking.status=''CONFIRMED'' and booking.profile_id=any(participant_ids_to_use)');
  d:=replace(d,'on conflict (profile_id)','on conflict (profile_id,rating_track)');
  d:=fieldrush_rating_private.replace_required(d,'rating.profile_id = booking.profile_id;',
    'rating.profile_id = booking.profile_id and rating.rating_track=public.fieldrush_rating_track(booking.role);'); execute d;

  d:=pg_get_functiondef('public.apply_open_queue_player_ratings(uuid)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'  if game_to_apply.status <> ''FINAL'' then',
    E'  if game_to_apply.format_version <> ''FIELDRUSH_7V7'' then return 0; end if;\n  if game_to_apply.status <> ''FINAL'' then');
  d:=replace(d,'public.player_ratings','public.fieldrush_player_rating_tracks');
  d:=fieldrush_rating_private.replace_required(d,'(profile_id)'||E'\n  select booking.profile_id',
    '(profile_id,rating_track)'||E'\n  select booking.profile_id,public.fieldrush_rating_track(booking.role)');
  d:=replace(d,'on conflict (profile_id)','on conflict (profile_id,rating_track)');
  d:=fieldrush_rating_private.replace_required(d,'booking.profile_id = rating.profile_id',
    'booking.profile_id = rating.profile_id and rating.rating_track=public.fieldrush_rating_track(booking.role)');
  d:=fieldrush_rating_private.replace_required(d,'where profile_id = participant.profile_id;',
    'where profile_id = participant.profile_id and rating_track=public.fieldrush_rating_track(participant.role);');
  execute d;

  d:=pg_get_functiondef('public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure);
  d:=replace(d,'public.player_ratings','public.fieldrush_player_rating_tracks');
  d:=fieldrush_rating_private.replace_required(d,'event.rating_change,','event.rating_change, event.rating_track,');
  d:=fieldrush_rating_private.replace_required(d,'rating.profile_id = event_to_adjust.profile_id',
    'rating.profile_id = event_to_adjust.profile_id and rating.rating_track=event_to_adjust.rating_track');
  d:=fieldrush_rating_private.replace_required(d,'where profile_id = event_to_adjust.profile_id;',
    'where profile_id = event_to_adjust.profile_id and rating_track=event_to_adjust.rating_track;'); execute d;

  d:=pg_get_functiondef('public.apply_late_appeal_sr_correction(uuid,uuid,uuid)'::regprocedure);
  execute replace(d,'public.apply_late_appeal_sr_correction(','public.apply_late_appeal_sr_correction_before_tracks(');
  d:=replace(d,'public.player_ratings rating','public.fieldrush_player_rating_tracks rating');
  d:=fieldrush_rating_private.replace_required(d,'  select rating.skill_rating into current_rating',
    E'  if event_to_correct.rating_track is null then\n    return public.apply_late_appeal_sr_correction_before_tracks(actor_admin_id,appeal_id_to_correct,attendance_id_to_correct);\n  end if;\n  select rating.skill_rating into current_rating');
  d:=fieldrush_rating_private.replace_required(d,'rating.profile_id = attendance_to_correct.profile_id',
    'rating.profile_id = attendance_to_correct.profile_id and rating.rating_track=event_to_correct.rating_track');
  d:=fieldrush_rating_private.replace_required(d,'later_event.profile_id = event_to_correct.profile_id',
    'later_event.profile_id = event_to_correct.profile_id and later_event.rating_track=event_to_correct.rating_track'); execute d;

  -- Existing correction semantics preserve earned SR but adjust result stats.
  d:=pg_get_functiondef('public.preserve_player_sr_for_resolution_score(text,uuid,integer,integer)'::regprocedure);
  execute replace(d,'public.preserve_player_sr_for_resolution_score(','public.preserve_player_sr_for_resolution_score_before_tracks(');
  d:=replace(d,'public.player_ratings rating','public.fieldrush_player_rating_tracks rating');
  d:=fieldrush_rating_private.replace_required(d,'  update public.fieldrush_player_rating_tracks rating',
    E'  if normalized_kind=''CLAN'' or not exists(select 1 from public.player_rating_events where source_type=source_type_to_use and source_id=match_id_to_use and rating_track is not null) then\n    return public.preserve_player_sr_for_resolution_score_before_tracks(match_kind_to_use,match_id_to_use,home_score_to_use,away_score_to_use);\n  end if;\n  update public.fieldrush_player_rating_tracks rating');
  d:=fieldrush_rating_private.replace_required(d,'event.profile_id = rating.profile_id',
    'event.profile_id = rating.profile_id and event.rating_track=rating.rating_track'); execute d;

  d:=pg_get_functiondef('public.admin_override_match_score(uuid,text,uuid,integer,integer,text)'::regprocedure);
  execute replace(d,'public.admin_override_match_score(','public.admin_override_match_score_before_tracks(');
  d:=fieldrush_rating_private.replace_required(d,'  if not public.is_active_moderation_admin(actor_admin_id) then',
    E'  if normalized_kind=''CLAN'' or not exists(select 1 from public.player_rating_events where source_type=''OPEN_QUEUE'' and source_id=match_id_to_update and rating_track is not null) then\n    return public.admin_override_match_score_before_tracks(actor_admin_id,match_kind_to_use,match_id_to_update,home_score_to_use,away_score_to_use,reason_to_use);\n  end if;\n  if not public.is_active_moderation_admin(actor_admin_id) then');
  d:=replace(d,'public.player_ratings rating','public.fieldrush_player_rating_tracks rating');
  d:=fieldrush_rating_private.replace_required(d,'event.profile_id = rating.profile_id',
    'event.profile_id = rating.profile_id and event.rating_track=rating.rating_track'); execute d;

  d:=pg_get_functiondef('public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'from public.player_ratings rating'||E'\n      where booking.game_id = match_id_to_use',
    'from public.fieldrush_player_rating_tracks rating'||E'\n      where rating.rating_track=public.fieldrush_rating_track(booking.role) and booking.game_id = match_id_to_use'); execute d;

  d:=pg_get_functiondef('public.list_profile_previous_games(uuid)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'  ) previous'||E'\n  order by',
    '  ) previous'||E'\n  where previous.played_at >= public.current_player_rankings_reset_at()\n  order by'); execute d;
  d:=pg_get_functiondef('public.get_player_rating_history(uuid,integer)'::regprocedure);
  d:=fieldrush_rating_private.replace_required(d,'    where event.profile_id = profile_id_to_use',
    '    where event.profile_id = profile_id_to_use and event.rating_track is not null and public.player_rating_event_is_current(event.effective_at,event.applied_sequence)');
  d:=fieldrush_rating_private.replace_required(d,'''source_type'', event.source_type,',
    '''rating_track'', event.rating_track, ''market_city_id'', event.market_city_id, ''counted_as_played'', event.counted_as_played, ''source_type'', event.source_type,'); execute d;
end;
$migration$;
revoke all on function public.preserve_player_sr_for_resolution_score_before_tracks(text,uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.apply_late_appeal_sr_correction_before_tracks(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.admin_override_match_score_before_tracks(uuid,text,uuid,integer,integer,text) from public,anon,authenticated,service_role;

create table fieldrush_rating_private.track_reset_snapshots (
  reset_id uuid not null references fieldrush_rating_private.reset_runs(id),
  profile_id uuid not null,rating_track text not null,snapshot jsonb not null,
  primary key(reset_id,profile_id,rating_track)
);
revoke all on fieldrush_rating_private.track_reset_snapshots from public,anon,authenticated;
alter function public.reset_player_rankings(uuid,text) rename to reset_player_rankings_before_tracks;
revoke all on function public.reset_player_rankings_before_tracks(uuid,text) from public,anon,authenticated,service_role;
create function public.reset_player_rankings(request_id_to_use uuid,reason_to_use text)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare result jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('field-player-ranking-reset',0));
  lock table public.fieldrush_player_rating_tracks in access exclusive mode;
  result:=public.reset_player_rankings_before_tracks(request_id_to_use,reason_to_use);
  if (result->>'already_applied')::boolean then return result; end if;
  insert into fieldrush_rating_private.track_reset_snapshots(reset_id,profile_id,rating_track,snapshot)
    select request_id_to_use,profile_id,rating_track,to_jsonb(r) from public.fieldrush_player_rating_tracks r;
  update public.fieldrush_player_rating_tracks set skill_rating=1200,matches_played=0,wins=0,losses=0,draws=0,last_change=0,
    ratings_reset_at=(result->>'reset_at')::timestamptz,ratings_reset_sequence=(result->>'reset_sequence')::bigint;
  return result;
end;
$$;
revoke all on function public.reset_player_rankings(uuid,text) from public,anon,authenticated;
grant execute on function public.reset_player_rankings(uuid,text) to service_role;
notify pgrst,'reload schema';
