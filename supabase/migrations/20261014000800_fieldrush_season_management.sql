-- Season administration is independent of the canonical lifetime role ratings.
-- Dates use Phoenix midnight; played games keep their original season identity.
alter table public.fieldrush_seasons
  add column lifecycle text not null default 'SCHEDULED' check (lifecycle in ('DRAFT','SCHEDULED','ACTIVE','ENDED')),
  add column visible_to_players boolean not null default true,
  add column start_locked_at timestamptz,
  add column transition_state text not null default 'READY' check (transition_state in ('READY','BLOCKED_LIVE')),
  add column blocked_reason text,
  add column transition_requested_at timestamptz;
update public.fieldrush_seasons set lifecycle=case
  when ends_on<(now() at time zone 'America/Phoenix')::date then 'ENDED'
  when starts_on<=(now() at time zone 'America/Phoenix')::date then 'ACTIVE' else 'SCHEDULED' end,
  start_locked_at=case when starts_on<=(now() at time zone 'America/Phoenix')::date
    then starts_on::timestamp at time zone 'America/Phoenix' end;
alter table public.fieldrush_seasons add constraint fieldrush_active_visible check (lifecycle<>'ACTIVE' or visible_to_players);
create unique index fieldrush_one_active_season on public.fieldrush_seasons((lifecycle)) where lifecycle='ACTIVE';
-- Drafts can be prepared alongside the existing schedule. Only committed dates
-- reserve calendar time; promoting a draft validates the entire calendar.
do $$ declare constraint_name text; begin
  select conname into constraint_name from pg_constraint where conrelid='public.fieldrush_seasons'::regclass and contype='x';
  execute format('alter table public.fieldrush_seasons drop constraint %I',constraint_name);
end $$;
alter table public.fieldrush_seasons add constraint fieldrush_season_calendar_no_overlap
  exclude using gist (daterange(starts_on,ends_on,'[]') with &&) where (lifecycle<>'DRAFT') deferrable initially immediate;
alter table public.fieldrush_season_audit_events alter column actor_admin_id drop not null;
alter table public.fieldrush_season_audit_events drop constraint fieldrush_season_audit_events_action_check;
alter table public.fieldrush_season_audit_events add constraint fieldrush_season_audit_events_action_check check (action in
  ('SEASON_CREATED','SEASON_UPDATED','SEASON_RENAMED','SEASON_VISIBILITY_CHANGED','SEASON_SCHEDULED','SEASON_DRAFTED',
   'SEASON_DUPLICATED','SEASON_END_CHANGED','SEASON_TRANSITION_SCHEDULED','SEASON_STARTED','SEASON_ENDED','SEASON_TRANSITION_BLOCKED',
   'REWARD_SAVED','REWARD_PUBLISHED','REWARD_CORRECTED'));

alter table public.open_queue_games add column season_id text references public.fieldrush_seasons(id) on delete restrict,
  add column season_locked_at timestamptz;
alter table public.player_rating_events add column season_id text references public.fieldrush_seasons(id) on delete restrict;
create index open_queue_games_season_idx on public.open_queue_games(season_id,starts_at);
create index player_rating_events_season_idx on public.player_rating_events(season_id,profile_id,rating_track);
update public.open_queue_games g set season_id=s.id,
  season_locked_at=case when g.status in ('LIVE','FINAL','CANCELLED') or exists(select 1 from public.open_queue_clock_states c
    where c.game_id=g.id and (c.started_at is not null or c.accumulated_seconds>0))
    then coalesce((select min(c.started_at) from public.open_queue_clock_states c where c.game_id=g.id),g.starts_at) end
from public.fieldrush_seasons s where (coalesce((select min(e.occurred_at) from public.open_queue_events e
  where e.game_id=g.id and e.event_type='MATCH_STARTED'),g.starts_at) at time zone 'America/Phoenix')::date between s.starts_on and s.ends_on;
update public.player_rating_events e set season_id=g.season_id from public.open_queue_games g
  where e.source_type='OPEN_QUEUE' and e.source_id=g.id;

create function fieldrush_rating_private.season_for_day(day_to_use date)
returns text language sql stable security definer set search_path=public,pg_temp as $$
  select id from public.fieldrush_seasons where lifecycle<>'DRAFT' and day_to_use between starts_on and ends_on;
$$;
create function fieldrush_rating_private.snapshot_game_season()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
begin
  -- Only actual starts serialize with the scheduler. Checkout, cancellations,
  -- scores and price edits keep their existing row-lock order.
  if new.status='LIVE' and (tg_op='INSERT' or (old.status is distinct from 'LIVE' and old.season_locked_at is null)) then
    perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  end if;
  if tg_op='UPDATE' and old.season_locked_at is not null then
    if new.season_id is distinct from old.season_id or new.season_locked_at is distinct from old.season_locked_at then
      raise exception 'A played game must stay in its original season.';
    end if;
  else
    new.season_id:=fieldrush_rating_private.season_for_day((new.starts_at at time zone 'America/Phoenix')::date);
    if new.status in ('LIVE','FINAL','CANCELLED') then new.season_locked_at:=coalesce(new.season_locked_at,new.starts_at); end if;
  end if;
  return new;
end;
$$;
create trigger a_fieldrush_game_season before insert or update on public.open_queue_games
  for each row execute function fieldrush_rating_private.snapshot_game_season();

create function fieldrush_rating_private.serialize_match_start()
returns trigger language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare match_id uuid; actual_start timestamptz; started boolean;
begin
  if tg_table_name in ('open_queue_clock_states','fixture_clock_states') then
    if tg_op='UPDATE' and old.status<>'NOT_STARTED' then return new; end if;
    started:=new.status<>'NOT_STARTED' or new.started_at is not null or new.accumulated_seconds>0;
    actual_start:=coalesce(new.started_at,now());
  elsif tg_table_name in ('open_queue_events','fixture_events') then
    started:=new.event_type='MATCH_STARTED'; actual_start:=new.occurred_at;
  else started:=new.status='LIVE'; actual_start:=new.match_date::timestamp at time zone 'America/Phoenix';
  end if;
  if started then
    if tg_table_name in ('open_queue_clock_states','open_queue_events') then
      if exists(select 1 from public.open_queue_games where id=new.game_id and season_locked_at is not null) then
        return new;
      end if;
    end if;
    perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
    if tg_table_name in ('open_queue_clock_states','open_queue_events') then
      match_id:=new.game_id;
      -- Setting LIVE is handled by the game trigger. The clock/event path also
      -- freezes identity when a referee starts the clock before changing status.
      update public.open_queue_games set season_locked_at=coalesce(season_locked_at,actual_start)
        where id=match_id and season_locked_at is null;
    end if;
  end if;
  return new;
end;
$$;
create trigger a_fieldrush_season_clock before insert or update on public.open_queue_clock_states
  for each row execute function fieldrush_rating_private.serialize_match_start();
create trigger a_fieldrush_season_clock before insert or update on public.fixture_clock_states
  for each row execute function fieldrush_rating_private.serialize_match_start();
create trigger a_fieldrush_season_event before insert on public.open_queue_events
  for each row execute function fieldrush_rating_private.serialize_match_start();
create trigger a_fieldrush_season_event before insert on public.fixture_events
  for each row execute function fieldrush_rating_private.serialize_match_start();
create trigger a_fieldrush_season_live before insert or update of status on public.fixtures
  for each row execute function fieldrush_rating_private.serialize_match_start();

create function fieldrush_rating_private.snapshot_event_season()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='UPDATE' and new.season_id is distinct from old.season_id then raise exception 'A rating event must stay in its original season.'; end if;
  if tg_op='INSERT' and new.source_type='OPEN_QUEUE' then
    select season_id into new.season_id from public.open_queue_games where id=new.source_id;
  end if;
  return new;
end;
$$;
create trigger b_snapshot_fieldrush_event_season before insert or update on public.player_rating_events
  for each row execute function fieldrush_rating_private.snapshot_event_season();
-- Refresh SELECT * after adding season_id; the original eligibility conditions
-- continue to exclude walkovers, no-shows, deleted eras, and unplayed bookings.
create or replace view fieldrush_rating_private.eligible_track_events as
select e.* from public.player_rating_events e
join public.fieldrush_player_rating_tracks r on r.profile_id=e.profile_id and r.rating_track=e.rating_track
join public.open_queue_games g on e.source_type='OPEN_QUEUE' and g.id=e.source_id
left join lateral (select v.resolution_type from public.match_resolution_cases c
  join public.match_resolution_revisions v on v.case_id=c.id where c.open_queue_game_id=g.id order by v.revision desc limit 1) resolution on true
where e.rating_track is not null and e.counted_as_played and g.status='FINAL'
  and coalesce(resolution.resolution_type,'RECORDED_RESULT')='RECORDED_RESULT'
  and not exists(select 1 from public.current_match_attendance_records a where a.match_kind='SOLO'
    and a.open_queue_game_id=g.id and a.profile_id=e.profile_id and a.outcome='NO_SHOW')
  and e.played_at>=r.ratings_reset_at and e.applied_sequence>r.ratings_reset_sequence;
create or replace function fieldrush_rating_private.season_track_events(season_starts_on date,season_ends_on date)
returns setof public.player_rating_events language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  with chosen as (select id from public.fieldrush_seasons where starts_on=season_starts_on and ends_on=season_ends_on and lifecycle<>'DRAFT')
  select e.* from fieldrush_rating_private.eligible_track_events e where
    case when exists(select 1 from chosen) then e.season_id in (select id from chosen)
      else (e.played_at at time zone e.played_timezone)::date between season_starts_on and season_ends_on end;
$$;
create or replace function fieldrush_rating_private.current_season_bounds(day_to_use date default (now() at time zone 'America/Phoenix')::date)
returns table(starts_on date,ends_on date) language sql stable security definer set search_path=public,pg_temp as $$
  select s.starts_on,s.ends_on from public.fieldrush_seasons s where
    case when day_to_use=(now() at time zone 'America/Phoenix')::date then s.lifecycle='ACTIVE'
      else s.lifecycle<>'DRAFT' and day_to_use between s.starts_on and s.ends_on end;
$$;
create or replace function fieldrush_rating_private.track_rating_at(player_to_use uuid,track_to_use text,season_ends_on date)
returns table(skill_rating integer,last_change integer) language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  select case when coalesce(s.lifecycle in ('ACTIVE','SCHEDULED'),season_ends_on>=(now() at time zone 'America/Phoenix')::date) then r.skill_rating else coalesce(e.rating_after,1200) end,
    case when coalesce(s.lifecycle in ('ACTIVE','SCHEDULED'),season_ends_on>=(now() at time zone 'America/Phoenix')::date) then r.last_change else coalesce(e.rating_change,0) end
  from public.fieldrush_player_rating_tracks r
  left join public.fieldrush_seasons s on s.ends_on=season_ends_on and s.lifecycle<>'DRAFT'
  left join lateral (select event.rating_after,event.rating_change from public.player_rating_events event
    left join public.fieldrush_seasons original on original.id=event.season_id
    where event.profile_id=r.profile_id and event.rating_track=r.rating_track and event.played_at>=r.ratings_reset_at
      and event.applied_sequence>r.ratings_reset_sequence
      and coalesce(original.ends_on,(event.played_at at time zone event.played_timezone)::date)<=season_ends_on
    order by event.applied_sequence desc limit 1) e on true
  where r.profile_id=player_to_use and r.rating_track=track_to_use;
$$;

create function fieldrush_rating_private.live_season_games()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(jsonb_agg(payload order by payload->>'starts_at'),'[]'::jsonb) from (
    select jsonb_build_object('id',g.id,'kind','SOLO','venue',g.venue,'status',g.status,'starts_at',g.starts_at) payload
      from public.open_queue_games g where g.status not in ('FINAL','CANCELLED') and
        not exists(select 1 from public.open_queue_clock_states c where c.game_id=g.id and c.status='ENDED') and
        (g.status='LIVE' or exists(select 1 from public.open_queue_clock_states c where c.game_id=g.id
          and c.status in ('RUNNING','PAUSED'))
          or exists(select 1 from public.open_queue_events e where e.game_id=g.id and e.event_type='MATCH_STARTED'))
    union all select jsonb_build_object('id',f.id,'kind','CLAN','venue',f.venue,'status',f.status,'starts_at',f.match_date)
      from public.fixtures f where f.status not in ('FINAL','CANCELLED') and
        not exists(select 1 from public.fixture_clock_states c where c.fixture_id=f.id and c.status='ENDED') and
        (f.status='LIVE' or exists(select 1 from public.fixture_clock_states c where c.fixture_id=f.id
          and c.status in ('RUNNING','PAUSED'))
          or exists(select 1 from public.fixture_events e where e.fixture_id=f.id and e.event_type='MATCH_STARTED'))
  ) games;
$$;

create or replace function public.list_fieldrush_seasons()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare today date:=(now() at time zone 'America/Phoenix')::date;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  return jsonb_build_object('seasons',coalesce((select jsonb_agg(to_jsonb(s) order by starts_on) from public.fieldrush_seasons s
    where lifecycle in ('ACTIVE','ENDED') and visible_to_players),'[]'::jsonb),
    'current_season_id',(select id from public.fieldrush_seasons where lifecycle='ACTIVE'),'today',today);
end;
$$;

create or replace function public.admin_list_fieldrush_seasons(actor_admin_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare today date:=(now() at time zone 'America/Phoenix')::date;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  return jsonb_build_object('today',today,'current_season_id',(select id from public.fieldrush_seasons where lifecycle='ACTIVE'),
    'seasons',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object(
      'editable',s.lifecycle in ('DRAFT','SCHEDULED') and s.start_locked_at is null and not prize.published,
      'can_hide',s.lifecycle<>'ACTIVE','can_change_end',s.lifecycle<>'ENDED','published_rewards_locked',prize.published,
      'stats',jsonb_build_object('games',(select count(distinct source_id) from fieldrush_rating_private.eligible_track_events where season_id=s.id),
        'players',(select count(distinct profile_id) from fieldrush_rating_private.eligible_track_events where season_id=s.id),
        'ranked_players',(select count(*) from (select profile_id,rating_track from fieldrush_rating_private.eligible_track_events where season_id=s.id
          group by profile_id,rating_track having count(*)>=2) ranked),
        'in_placement',(select count(*) from (select profile_id,rating_track from fieldrush_rating_private.eligible_track_events where season_id=s.id
          group by profile_id,rating_track having count(*)=1) placement),
        'unfinished_games',(select count(*) from public.open_queue_games g where g.season_id=s.id and g.status not in ('FINAL','CANCELLED')
          and g.ends_at<now()),
        'live_games',(select count(*) from jsonb_array_elements(fieldrush_rating_private.live_season_games()) live
          join public.open_queue_games g on g.id::text=live->>'id' where g.season_id=s.id),
        'published_prize_cents',prize.amount),
      'readiness',to_jsonb(array_remove(array[
        case when s.lifecycle='DRAFT' then 'Draft season must be scheduled before it starts.' end,
        case when exists(select 1 from public.fieldrush_cities c cross join (values('OUTFIELD'),('GOALKEEPER')) t(track)
          where c.active and not exists(select 1 from public.fieldrush_season_rewards r where r.season_id=s.id and r.city_id=c.id
            and r.rating_track=t.track and r.status='PUBLISHED')) then 'Some active-city rewards are not published.' end,
        case when s.transition_state='BLOCKED_LIVE' then s.blocked_reason end,
        case when exists(select 1 from public.fieldrush_seasons other where other.id<>s.id and other.lifecycle<>'DRAFT'
          and daterange(other.starts_on,other.ends_on,'[]')&&daterange(s.starts_on,s.ends_on,'[]')) then 'Dates overlap a scheduled season.' end
      ],null))) order by s.starts_on,s.id) from public.fieldrush_seasons s
      cross join lateral (select coalesce(bool_or(r.status='PUBLISHED'),false) published,
        coalesce(sum(r.first_prize_cents+r.second_prize_cents+r.third_prize_cents) filter(where r.status='PUBLISHED'),0) amount
        from public.fieldrush_season_rewards r where r.season_id=s.id) prize),'[]'::jsonb),
    'rewards',coalesce((select jsonb_agg(to_jsonb(r) order by season_id,city_id,rating_track) from public.fieldrush_season_rewards r),'[]'::jsonb),
    'audit',coalesce((select jsonb_agg(to_jsonb(a) order by created_at desc,id) from
      (select * from public.fieldrush_season_audit_events order by created_at desc,id limit 100) a),'[]'::jsonb));
end;
$$;

create or replace function public.admin_save_fieldrush_season(actor_admin_id uuid,season_id_to_use text,values_to_use jsonb,expected_revision_to_use integer default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare previous public.fieldrush_seasons%rowtype; saved public.fieldrush_seasons%rowtype; merged jsonb;
  today date:=(now() at time zone 'America/Phoenix')::date; start_date date; end_date date; state text; locked boolean;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if season_id_to_use is null or season_id_to_use !~ '^[a-z][a-z0-9-]{1,63}$' then raise exception 'Choose a valid lowercase season ID.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' or values_to_use='{}'::jsonb
    or exists(select 1 from jsonb_object_keys(values_to_use) k where k not in ('label','starts_on','ends_on','minimum_rated_games','lifecycle','visible_to_players')) then
    raise exception 'Invalid season settings.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into previous from public.fieldrush_seasons where id=season_id_to_use for update;
  if expected_revision_to_use is distinct from coalesce(previous.revision,0) then raise exception 'Season settings changed. Reload before saving.' using errcode='40001'; end if;
  merged:=jsonb_build_object('minimum_rated_games',2,'lifecycle','DRAFT','visible_to_players',true)
    ||case when previous.id is null then '{}'::jsonb else to_jsonb(previous) end||values_to_use;
  if jsonb_typeof(merged->'label') is distinct from 'string' or char_length(trim(merged->>'label')) not between 1 and 40
    or jsonb_typeof(merged->'starts_on') is distinct from 'string' or (merged->>'starts_on') !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(merged->'ends_on') is distinct from 'string' or (merged->>'ends_on') !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(merged->'minimum_rated_games') is distinct from 'number' or (merged->>'minimum_rated_games') !~ '^\d+$'
    or (merged->>'minimum_rated_games')::numeric not between 2 and 100
    or jsonb_typeof(merged->'visible_to_players') is distinct from 'boolean' then raise exception 'Choose valid season dates, label and a qualification minimum of 2–100 games.'; end if;
  start_date:=(merged->>'starts_on')::date; end_date:=(merged->>'ends_on')::date; state:=merged->>'lifecycle';
  if state not in ('DRAFT','SCHEDULED','ACTIVE','ENDED') or state is null then raise exception 'Choose a valid season state.'; end if;
  if end_date<start_date or end_date-start_date>370 then raise exception 'A season must last 1–371 days.'; end if;
  locked:=previous.start_locked_at is not null or previous.lifecycle in ('ACTIVE','ENDED')
    or exists(select 1 from public.fieldrush_season_rewards where season_id=season_id_to_use and status='PUBLISHED');
  if previous.id is null then
    if start_date<=today or state not in ('DRAFT','SCHEDULED') then raise exception 'Only future draft or scheduled seasons can be created.'; end if;
  else
    if state is distinct from previous.lifecycle then raise exception 'Use the schedule or transition action to change a season state.'; end if;
    if state in ('DRAFT','SCHEDULED') and start_date<=today and start_date is distinct from previous.starts_on then
      raise exception 'A future season start must remain after today.'; end if;
    if locked and (start_date is distinct from previous.starts_on or (merged->>'minimum_rated_games')::integer is distinct from previous.minimum_rated_games)
      then raise exception 'Started seasons and published prizes lock the start date and qualification rules.'; end if;
    if locked and end_date is distinct from previous.ends_on then raise exception 'Use the audited end-date action to change a locked season end.'; end if;
    if previous.lifecycle='ACTIVE' and not (merged->>'visible_to_players')::boolean then raise exception 'The active season must stay visible.'; end if;
  end if;
  if state<>'DRAFT' and exists(select 1 from public.fieldrush_seasons where id<>season_id_to_use and lifecycle<>'DRAFT'
    and daterange(starts_on,ends_on,'[]')&&daterange(start_date,end_date,'[]')) then raise exception 'Season dates must not overlap another scheduled season.'; end if;
  insert into public.fieldrush_seasons(id,label,starts_on,ends_on,minimum_rated_games,lifecycle,visible_to_players,revision)
  values(season_id_to_use,trim(merged->>'label'),start_date,end_date,(merged->>'minimum_rated_games')::integer,state,
    (merged->>'visible_to_players')::boolean,coalesce(previous.revision,0)+1)
  on conflict(id) do update set label=excluded.label,starts_on=excluded.starts_on,ends_on=excluded.ends_on,minimum_rated_games=excluded.minimum_rated_games,
    visible_to_players=excluded.visible_to_players,revision=excluded.revision,updated_at=now() returning * into saved;
  if previous.id is null then
    insert into public.fieldrush_season_rewards(season_id,city_id,rating_track)
      select saved.id,c.id,t.track from public.fieldrush_cities c cross join (values('OUTFIELD'),('GOALKEEPER')) t(track);
  end if;
  insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
    values(saved.id,actor_admin_id,case when previous.id is null then 'SEASON_CREATED' else 'SEASON_UPDATED' end,'Admin saved season settings.',
      case when previous.id is null then '{}'::jsonb else to_jsonb(previous) end,to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;

create function public.admin_update_fieldrush_season(actor_admin_id uuid,season_id_to_use text,action_to_use text,values_to_use jsonb,
  reason_to_use text,expected_revision_to_use integer)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare previous public.fieldrush_seasons%rowtype; saved public.fieldrush_seasons%rowtype; end_date date; audit_action text;
  today date:=(now() at time zone 'America/Phoenix')::date;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if action_to_use is null or action_to_use not in ('RENAME','VISIBILITY','SCHEDULE','MAKE_DRAFT','END_DATE') then raise exception 'Choose a valid season action.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' then raise exception 'Invalid season action values.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into previous from public.fieldrush_seasons where id=season_id_to_use for update;
  if previous.id is null then raise exception 'Choose an available season.'; end if;
  if expected_revision_to_use is distinct from previous.revision then raise exception 'Season settings changed. Reload before saving.' using errcode='40001'; end if;
  saved:=previous;
  if action_to_use='RENAME' then
    if values_to_use - 'label'<>'{}'::jsonb or jsonb_typeof(values_to_use->'label') is distinct from 'string'
      or char_length(trim(values_to_use->>'label')) not between 1 and 40 then raise exception 'Enter a season name of 1–40 characters.'; end if;
    saved.label:=trim(values_to_use->>'label'); audit_action:='SEASON_RENAMED';
  elsif action_to_use='VISIBILITY' then
    if values_to_use - 'visible_to_players'<>'{}'::jsonb or jsonb_typeof(values_to_use->'visible_to_players') is distinct from 'boolean' then raise exception 'Choose whether the season is visible.'; end if;
    saved.visible_to_players:=(values_to_use->>'visible_to_players')::boolean;
    if previous.lifecycle='ACTIVE' and not saved.visible_to_players then raise exception 'The active season must stay visible.'; end if;
    audit_action:='SEASON_VISIBILITY_CHANGED';
  elsif action_to_use in ('SCHEDULE','MAKE_DRAFT') then
    if values_to_use<>'{}'::jsonb then raise exception 'No values are accepted for this season action.'; end if;
    if previous.lifecycle not in ('DRAFT','SCHEDULED') or previous.starts_on<=today or previous.start_locked_at is not null then raise exception 'Only unstarted future seasons can be scheduled or drafted.'; end if;
    if action_to_use='MAKE_DRAFT' and exists(select 1 from public.fieldrush_season_rewards where season_id=previous.id and status='PUBLISHED')
      then raise exception 'A season with published prizes must remain scheduled.'; end if;
    saved.lifecycle:=case when action_to_use='SCHEDULE' then 'SCHEDULED' else 'DRAFT' end;
    audit_action:=case when action_to_use='SCHEDULE' then 'SEASON_SCHEDULED' else 'SEASON_DRAFTED' end;
  else
    if values_to_use - 'ends_on'<>'{}'::jsonb or jsonb_typeof(values_to_use->'ends_on') is distinct from 'string'
      or (values_to_use->>'ends_on') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid end date.'; end if;
    if char_length(trim(coalesce(reason_to_use,''))) not between 10 and 1000 then raise exception 'Explain the end-date change in 10–1000 characters.'; end if;
    end_date:=(values_to_use->>'ends_on')::date;
    if previous.lifecycle='ENDED' or end_date<greatest(previous.starts_on,today) or end_date-previous.starts_on>370 then
      raise exception 'An active season can end no earlier than tonight; ended seasons cannot change dates.'; end if;
    if jsonb_array_length(fieldrush_rating_private.live_season_games())>0 then raise exception 'Finish or cancel live games before changing the season end.'; end if;
    saved.ends_on:=end_date; audit_action:='SEASON_END_CHANGED';
  end if;
  if saved.lifecycle<>'DRAFT' and exists(select 1 from public.fieldrush_seasons where id<>saved.id and lifecycle<>'DRAFT'
    and daterange(starts_on,ends_on,'[]')&&daterange(saved.starts_on,saved.ends_on,'[]')) then raise exception 'Season dates overlap another scheduled season. Draft or reschedule it first.'; end if;
  update public.fieldrush_seasons set label=saved.label,visible_to_players=saved.visible_to_players,lifecycle=saved.lifecycle,
    ends_on=saved.ends_on,revision=revision+1,updated_at=now() where id=previous.id returning * into saved;
  insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
    values(saved.id,actor_admin_id,audit_action,coalesce(nullif(trim(reason_to_use),''),'Admin changed season metadata.'),to_jsonb(previous),to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;

create function public.admin_duplicate_fieldrush_season(actor_admin_id uuid,source_season_id_to_use text,new_season_id_to_use text,
  values_to_use jsonb,expected_source_revision_to_use integer)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.fieldrush_seasons%rowtype; saved jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into source from public.fieldrush_seasons where id=source_season_id_to_use for update;
  if source.id is null then raise exception 'Choose a source season.'; end if;
  if source.revision is distinct from expected_source_revision_to_use then raise exception 'The source season changed. Reload before duplicating.' using errcode='40001'; end if;
  if exists(select 1 from public.fieldrush_seasons where id=new_season_id_to_use) then raise exception 'Use a new season ID.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' or exists(select 1 from jsonb_object_keys(values_to_use) k
    where k not in ('label','starts_on','ends_on','minimum_rated_games')) then raise exception 'Invalid duplicated season settings.'; end if;
  saved:=public.admin_save_fieldrush_season(actor_admin_id,new_season_id_to_use,
    jsonb_build_object('label',left(source.label,35)||' copy',
      'starts_on',greatest(source.ends_on+1,(now() at time zone 'America/Phoenix')::date+1),
      'ends_on',greatest(source.ends_on+1,(now() at time zone 'America/Phoenix')::date+1)+(source.ends_on-source.starts_on),
      'minimum_rated_games',source.minimum_rated_games,'lifecycle','DRAFT')||values_to_use,0);
  update public.fieldrush_season_rewards target set first_prize_cents=original.first_prize_cents,
    second_prize_cents=original.second_prize_cents,third_prize_cents=original.third_prize_cents
    from public.fieldrush_season_rewards original where target.season_id=new_season_id_to_use and original.season_id=source.id
      and target.city_id=original.city_id and target.rating_track=original.rating_track;
  insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
    values(new_season_id_to_use,actor_admin_id,'SEASON_DUPLICATED','Copied season settings and private draft prizes.',
      jsonb_build_object('source_season_id',source.id,'source_revision',source.revision),saved);
  return saved;
end;
$$;

create function public.admin_preview_fieldrush_season_end(actor_admin_id uuid,season_id_to_use text,ends_on_to_use date)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare season public.fieldrush_seasons%rowtype; today date:=(now() at time zone 'America/Phoenix')::date;
  blockers text[]:=array[]::text[]; live jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  select * into season from public.fieldrush_seasons where id=season_id_to_use;
  if season.id is null then blockers:=array_append(blockers,'Choose an available season.'); end if;
  if season.lifecycle='ENDED' then blockers:=array_append(blockers,'An ended season cannot change dates.'); end if;
  if ends_on_to_use is null or ends_on_to_use<greatest(season.starts_on,today) or ends_on_to_use-season.starts_on>370 then
    blockers:=array_append(blockers,'Choose an end date no earlier than tonight and within the season duration limit.'); end if;
  if exists(select 1 from public.fieldrush_seasons other where other.id<>season_id_to_use and other.lifecycle<>'DRAFT'
    and daterange(other.starts_on,other.ends_on,'[]')&&daterange(season.starts_on,ends_on_to_use,'[]')) then
    blockers:=array_append(blockers,'Another scheduled season overlaps this end date.'); end if;
  live:=fieldrush_rating_private.live_season_games();
  if jsonb_array_length(live)>0 then blockers:=array_append(blockers,'Finish or cancel live games before changing the end date.'); end if;
  return jsonb_build_object('current_season',to_jsonb(season),'ends_on',ends_on_to_use,'live_games',live,
    'unfinished_games',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'kind','SOLO','venue',g.venue,'status',g.status,'starts_at',g.starts_at))
      from public.open_queue_games g where g.season_id=season_id_to_use and g.ends_at<now() and g.status not in ('FINAL','CANCELLED')),'[]'::jsonb),
    'affected_future_games',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'kind','SOLO','venue',g.venue,'status',g.status,'starts_at',g.starts_at))
      from public.open_queue_games g where g.season_locked_at is null and g.status in ('OPEN','FULL')
        and (g.starts_at at time zone 'America/Phoenix')::date>least(season.ends_on,ends_on_to_use)
        and (g.starts_at at time zone 'America/Phoenix')::date<=greatest(season.ends_on,ends_on_to_use)),'[]'::jsonb),
    'can_save',cardinality(blockers)=0,'blockers',to_jsonb(blockers));
end;
$$;

create function public.admin_preview_fieldrush_season_transition(actor_admin_id uuid,current_season_id_to_use text,next_season_id_to_use text,starts_on_to_use date)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare current_season public.fieldrush_seasons%rowtype; next_season public.fieldrush_seasons%rowtype;
  today date:=(now() at time zone 'America/Phoenix')::date; blockers text[]:=array[]::text[]; live jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  select * into current_season from public.fieldrush_seasons where id=current_season_id_to_use;
  select * into next_season from public.fieldrush_seasons where id=next_season_id_to_use;
  if current_season.id is null or current_season.lifecycle<>'ACTIVE' then blockers:=array_append(blockers,'Choose the active current season.'); end if;
  if next_season.id is null or next_season.lifecycle not in ('DRAFT','SCHEDULED') then blockers:=array_append(blockers,'Choose an unstarted next season.'); end if;
  if starts_on_to_use is null or starts_on_to_use<=today then blockers:=array_append(blockers,'The next season must start at a future Phoenix midnight.'); end if;
  if starts_on_to_use>next_season.ends_on or starts_on_to_use-current_season.starts_on>371 then blockers:=array_append(blockers,'Choose a start within the next season and the current season duration limit.'); end if;
  if next_season.start_locked_at is not null or (next_season.starts_on is distinct from starts_on_to_use
    and exists(select 1 from public.fieldrush_season_rewards where season_id=next_season.id and status='PUBLISHED')) then
    blockers:=array_append(blockers,'Published next-season prizes lock its start date.'); end if;
  if exists(select 1 from public.fieldrush_seasons other where other.id not in (current_season_id_to_use,next_season_id_to_use)
    and other.lifecycle<>'DRAFT' and (daterange(other.starts_on,other.ends_on,'[]')&&daterange(starts_on_to_use,next_season.ends_on,'[]')
      or daterange(other.starts_on,other.ends_on,'[]')&&daterange(current_season.starts_on,starts_on_to_use-1,'[]'))) then
    blockers:=array_append(blockers,'Another scheduled season overlaps this transition.'); end if;
  live:=fieldrush_rating_private.live_season_games();
  if jsonb_array_length(live)>0 then blockers:=array_append(blockers,'Finish or cancel live games before scheduling the transition.'); end if;
  return jsonb_build_object('current_season',to_jsonb(current_season),'next_season',to_jsonb(next_season),
    'starts_on',starts_on_to_use,'ends_on',starts_on_to_use-1,'live_games',live,
    'unfinished_games',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'kind','SOLO','venue',g.venue,'status',g.status,'starts_at',g.starts_at))
      from public.open_queue_games g where g.season_id=current_season_id_to_use and g.ends_at<now() and g.status not in ('FINAL','CANCELLED')),'[]'::jsonb),
    'affected_future_games',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'kind','SOLO','venue',g.venue,'status',g.status,'starts_at',g.starts_at))
      from public.open_queue_games g where g.season_locked_at is null and g.status in ('OPEN','FULL')
        and (g.starts_at at time zone 'America/Phoenix')::date>=starts_on_to_use
        and (g.starts_at at time zone 'America/Phoenix')::date<=next_season.ends_on),'[]'::jsonb),
    'can_schedule',cardinality(blockers)=0,'blockers',to_jsonb(blockers));
end;
$$;

create function public.admin_schedule_fieldrush_season_transition(actor_admin_id uuid,current_season_id_to_use text,next_season_id_to_use text,
  starts_on_to_use date,reason_to_use text,expected_current_revision_to_use integer,expected_next_revision_to_use integer)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare current_season public.fieldrush_seasons%rowtype; next_season public.fieldrush_seasons%rowtype; preview jsonb; current_saved jsonb; next_saved jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if char_length(trim(coalesce(reason_to_use,''))) not between 10 and 1000 then raise exception 'Explain the season transition in 10–1000 characters.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into current_season from public.fieldrush_seasons where id=current_season_id_to_use for update;
  select * into next_season from public.fieldrush_seasons where id=next_season_id_to_use for update;
  if current_season.revision is distinct from expected_current_revision_to_use or next_season.revision is distinct from expected_next_revision_to_use
    then raise exception 'Season settings changed. Review the transition again.' using errcode='40001'; end if;
  preview:=public.admin_preview_fieldrush_season_transition(actor_admin_id,current_season_id_to_use,next_season_id_to_use,starts_on_to_use);
  if not (preview->>'can_schedule')::boolean then raise exception '%',preview->'blockers'; end if;
  set constraints fieldrush_season_calendar_no_overlap deferred;
  update public.fieldrush_seasons set ends_on=starts_on_to_use-1,revision=revision+1,updated_at=now(),transition_requested_at=now(),
    transition_state='READY',blocked_reason=null where id=current_season.id returning to_jsonb(fieldrush_seasons.*) into current_saved;
  update public.fieldrush_seasons set starts_on=starts_on_to_use,lifecycle='SCHEDULED',visible_to_players=true,revision=revision+1,
    updated_at=now(),transition_requested_at=now(),transition_state='READY',blocked_reason=null where id=next_season.id
    returning to_jsonb(fieldrush_seasons.*) into next_saved;
  set constraints fieldrush_season_calendar_no_overlap immediate;
  insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state) values
    (current_season.id,actor_admin_id,'SEASON_TRANSITION_SCHEDULED',trim(reason_to_use),to_jsonb(current_season),current_saved),
    (next_season.id,actor_admin_id,'SEASON_TRANSITION_SCHEDULED',trim(reason_to_use),to_jsonb(next_season),next_saved);
  return jsonb_build_object('current_season',current_saved,'next_season',next_saved,'starts_on',starts_on_to_use,'scheduled',true);
end;
$$;

-- Private day parameter makes cutoff behavior testable without changing the
-- server clock. Only the scheduler's no-argument service RPC is exposed.
create function fieldrush_rating_private.process_season_transitions(day_to_use date)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare current_season public.fieldrush_seasons%rowtype; next_season public.fieldrush_seasons%rowtype; successor public.fieldrush_seasons%rowtype;
  live jsonb; saved jsonb; result jsonb:='[]'::jsonb; boundary date;
begin
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into current_season from public.fieldrush_seasons where lifecycle='ACTIVE' for update;
  if current_season.id is not null and current_season.ends_on>=day_to_use then return jsonb_build_object('changed',false,'transitions',result); end if;
  select * into next_season from public.fieldrush_seasons where lifecycle='SCHEDULED' and starts_on<=day_to_use order by starts_on limit 1 for update;
  live:=fieldrush_rating_private.live_season_games();
  if jsonb_array_length(live)>0 and (current_season.id is not null or next_season.id is not null) then
    set constraints fieldrush_season_calendar_no_overlap deferred;
    if current_season.id is not null then
      update public.fieldrush_seasons set ends_on=least(day_to_use,starts_on+370),transition_state='BLOCKED_LIVE',
        blocked_reason='Live games blocked the transition. The next attempt is at the following Phoenix midnight.',revision=revision+1,updated_at=now()
        where id=current_season.id returning to_jsonb(fieldrush_seasons.*) into saved;
      insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
        values(current_season.id,null,'SEASON_TRANSITION_BLOCKED','Scheduler delayed the transition because a game was live.',to_jsonb(current_season),saved);
    end if;
    if next_season.id is not null then
      -- A one-day season can still start the following midnight. Preserve its
      -- duration when its start is delayed beyond its advertised end.
      update public.fieldrush_seasons set starts_on=day_to_use+1,ends_on=greatest(ends_on,day_to_use+1),transition_state='BLOCKED_LIVE',
        blocked_reason='Waiting for live games; start delayed to the following Phoenix midnight.',revision=revision+1,updated_at=now()
        where id=next_season.id returning to_jsonb(fieldrush_seasons.*) into saved;
      insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
        values(next_season.id,null,'SEASON_TRANSITION_BLOCKED','Scheduler delayed the transition because a game was live.',to_jsonb(next_season),saved);
      boundary:=(saved->>'ends_on')::date;
      -- If the delayed next season was a one-day season, slide only colliding
      -- successors. Every delay is visible and audited, including published
      -- dates; a live match must not force overlapping or half-day seasons.
      for successor in select * from public.fieldrush_seasons where lifecycle='SCHEDULED' and id<>next_season.id
        and starts_on>=next_season.starts_on order by starts_on for update loop
        exit when successor.starts_on>boundary;
        update public.fieldrush_seasons set starts_on=boundary+1,
          ends_on=boundary+1+(successor.ends_on-successor.starts_on),transition_state='BLOCKED_LIVE',
          blocked_reason='Start delayed by a preceding season waiting for live games.',revision=revision+1,updated_at=now()
          where id=successor.id returning to_jsonb(fieldrush_seasons.*) into saved;
        boundary:=(saved->>'ends_on')::date;
        insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
          values(successor.id,null,'SEASON_TRANSITION_BLOCKED','Scheduler moved this successor to keep the calendar non-overlapping.',to_jsonb(successor),saved);
      end loop;
    end if;
    set constraints fieldrush_season_calendar_no_overlap immediate;
    return jsonb_build_object('changed',true,'blocked',true,'retry_on',day_to_use+1,'live_games',live);
  end if;
  -- Recover an interrupted scheduler in one transaction. Expired scheduled
  -- periods become historical; they must never be selected as today's season.
  for successor in select * from public.fieldrush_seasons where lifecycle='SCHEDULED' and ends_on<day_to_use order by starts_on for update loop
    update public.fieldrush_seasons set lifecycle='ENDED',start_locked_at=coalesce(start_locked_at,starts_on::timestamp at time zone 'America/Phoenix'),
      revision=revision+1,updated_at=now() where id=successor.id returning to_jsonb(fieldrush_seasons.*) into saved;
    insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
      values(successor.id,null,'SEASON_ENDED','Scheduler recovered an elapsed scheduled season after a missed cutoff.',to_jsonb(successor),saved);
    result:=result||jsonb_build_array(saved);
  end loop;
  select * into next_season from public.fieldrush_seasons where lifecycle='SCHEDULED' and starts_on<=day_to_use and ends_on>=day_to_use
    order by starts_on limit 1 for update;
  if current_season.id is not null then
    update public.fieldrush_seasons set lifecycle='ENDED',transition_state='READY',blocked_reason=null,revision=revision+1,updated_at=now()
      where id=current_season.id returning to_jsonb(fieldrush_seasons.*) into saved;
    insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
      values(current_season.id,null,'SEASON_ENDED','Scheduler finished the season at Phoenix midnight.',to_jsonb(current_season),saved);
    result:=result||jsonb_build_array(saved);
  end if;
  if next_season.id is not null then
    update public.fieldrush_seasons set lifecycle='ACTIVE',visible_to_players=true,start_locked_at=coalesce(start_locked_at,starts_on::timestamp at time zone 'America/Phoenix'),
      transition_state='READY',blocked_reason=null,revision=revision+1,updated_at=now() where id=next_season.id returning to_jsonb(fieldrush_seasons.*) into saved;
    insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
      values(next_season.id,null,'SEASON_STARTED','Scheduler started the season at Phoenix midnight; role SR carries forward.',to_jsonb(next_season),saved);
    result:=result||jsonb_build_array(saved);
  end if;
  return jsonb_build_object('changed',jsonb_array_length(result)>0,'blocked',false,'transitions',result);
end;
$$;
create function public.process_fieldrush_season_transitions()
returns jsonb language sql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  select fieldrush_rating_private.process_season_transitions((now() at time zone 'America/Phoenix')::date);
$$;
-- At 00:00 Phoenix (07:00 UTC) every day. The blocked branch extends through
-- the day, so repeated invocation never starts a season halfway through a day.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('fieldrush-season-transitions','0 7 * * *','select public.process_fieldrush_season_transitions();');
  end if;
end $$;

-- Referee start RPCs explicitly lock the game before their first UPDATE. Take
-- the season lock first there as well. Calendar mutations never UPDATE game
-- rows: unstarted attribution is refreshed lazily by the game snapshot trigger.
do $$ declare signature text; definition text; begin
  foreach signature in array array['public.referee_start_open_queue_game(uuid,uuid[],integer)',
    'public.referee_start_fixture_atomic(uuid,uuid[],integer)'] loop
    definition:=pg_get_functiondef(signature::regprocedure);
    if position(E'\nbegin\n' in lower(definition))=0 then raise exception 'Referee start body changed: %',signature; end if;
    definition:=regexp_replace(definition,E'\n[Bb][Ee][Gg][Ii][Nn]\n',
      E'\nbegin\n  perform pg_advisory_xact_lock(hashtextextended(''fieldrush-season-settings'',0));\n');
    execute definition;
  end loop;
end $$;

-- Hidden seasons retain history and date-range statistics, but do not advertise
-- cash prizes through a stale picker selection.
do $$ declare definition text; begin
  definition:=pg_get_functiondef('public.get_fieldrush_season_rewards(text,text,text)'::regprocedure);
  if position('if season.id is null then' in definition)=0 then raise exception 'Reward season guard changed.'; end if;
  definition:=replace(definition,'  perform fieldrush_rating_private.validate_ranking_request',
    E'  if not season.visible_to_players or season.lifecycle=''DRAFT'' then return null; end if;\n  perform fieldrush_rating_private.validate_ranking_request');
  execute definition;
end $$;
revoke all on function fieldrush_rating_private.process_season_transitions(date),fieldrush_rating_private.season_for_day(date),
  fieldrush_rating_private.snapshot_game_season(),fieldrush_rating_private.serialize_match_start(),fieldrush_rating_private.snapshot_event_season(),
  fieldrush_rating_private.live_season_games() from public,anon,authenticated;
revoke all on function fieldrush_rating_private.process_season_transitions(date),fieldrush_rating_private.season_for_day(date),
  fieldrush_rating_private.snapshot_game_season(),fieldrush_rating_private.serialize_match_start(),fieldrush_rating_private.snapshot_event_season(),
  fieldrush_rating_private.live_season_games() from service_role;
revoke all on function public.admin_update_fieldrush_season(uuid,text,text,jsonb,text,integer),
  public.admin_duplicate_fieldrush_season(uuid,text,text,jsonb,integer),public.admin_preview_fieldrush_season_transition(uuid,text,text,date),
  public.admin_preview_fieldrush_season_end(uuid,text,date),public.admin_schedule_fieldrush_season_transition(uuid,text,text,date,text,integer,integer),public.process_fieldrush_season_transitions() from public,anon,authenticated;
grant execute on function public.admin_update_fieldrush_season(uuid,text,text,jsonb,text,integer),
  public.admin_duplicate_fieldrush_season(uuid,text,text,jsonb,integer),public.admin_preview_fieldrush_season_transition(uuid,text,text,date),
  public.admin_preview_fieldrush_season_end(uuid,text,date),public.admin_schedule_fieldrush_season_transition(uuid,text,text,date,text,integer,integer),public.process_fieldrush_season_transitions() to service_role;
notify pgrst,'reload schema';
