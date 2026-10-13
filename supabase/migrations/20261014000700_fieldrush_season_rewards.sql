-- Season configuration and advertised cash prizes. This is deliberately not an
-- award, payout, wallet, or end-of-season settlement system.
create table public.fieldrush_seasons (
  id text primary key check (id ~ '^[a-z][a-z0-9-]{1,63}$'),
  label text not null check (char_length(trim(label)) between 1 and 40),
  starts_on date not null,
  ends_on date not null,
  minimum_rated_games integer not null default 2 check (minimum_rated_games between 2 and 100),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on and ends_on - starts_on <= 370),
  exclude using gist (daterange(starts_on, ends_on, '[]') with &&)
);
insert into public.fieldrush_seasons(id,label,starts_on,ends_on)
values ('s0','S0','2026-06-01','2026-09-30');
insert into public.fieldrush_seasons(id,label,starts_on,ends_on)
select 's'||row_number() over(order by d), 'S'||row_number() over(order by d),
  d::date,(d+interval '3 months - 1 day')::date
from generate_series(timestamp '2026-10-01',timestamp '2030-10-01',interval '3 months') d;

create table public.fieldrush_season_rewards (
  season_id text not null references public.fieldrush_seasons(id) on delete restrict,
  city_id text not null references public.fieldrush_cities(id) on delete restrict,
  rating_track text not null check (rating_track in ('OUTFIELD','GOALKEEPER')),
  currency text not null default 'USD' check (currency='USD'),
  first_prize_cents integer not null default 15000 check (first_prize_cents between 0 and 100000000),
  second_prize_cents integer not null default 10000 check (second_prize_cents between 0 and 100000000),
  third_prize_cents integer not null default 5000 check (third_prize_cents between 0 and 100000000),
  status text not null default 'DRAFT' check (status in ('DRAFT','PUBLISHED')),
  revision integer not null default 1 check (revision > 0),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(season_id,city_id,rating_track),
  check ((status='PUBLISHED')=(published_at is not null))
);
-- Defaults remain private drafts until an admin explicitly publishes them.
insert into public.fieldrush_season_rewards(season_id,city_id,rating_track)
select s.id,c.id,t.track from public.fieldrush_seasons s
cross join public.fieldrush_cities c cross join (values ('OUTFIELD'),('GOALKEEPER')) t(track);

create table public.fieldrush_season_audit_events (
  id uuid primary key default gen_random_uuid(),
  season_id text not null references public.fieldrush_seasons(id) on delete restrict,
  city_id text references public.fieldrush_cities(id) on delete restrict,
  rating_track text check (rating_track in ('OUTFIELD','GOALKEEPER')),
  actor_admin_id uuid not null references public.referee_profiles(profile_id) on delete restrict,
  action text not null check (action in ('SEASON_CREATED','SEASON_UPDATED','REWARD_SAVED','REWARD_PUBLISHED','REWARD_CORRECTED')),
  reason text not null,
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null,
  created_at timestamptz not null default now()
);
create index fieldrush_season_audit_recent_idx on public.fieldrush_season_audit_events(created_at desc,id);
alter table public.fieldrush_seasons enable row level security;
alter table public.fieldrush_season_rewards enable row level security;
alter table public.fieldrush_season_audit_events enable row level security;
revoke all on public.fieldrush_seasons,public.fieldrush_season_rewards,public.fieldrush_season_audit_events from public,anon,authenticated,service_role;
grant select on public.fieldrush_seasons,public.fieldrush_season_rewards,public.fieldrush_season_audit_events to service_role;

create or replace function fieldrush_rating_private.current_season_bounds(
  day_to_use date default (now() at time zone 'America/Phoenix')::date)
returns table(starts_on date,ends_on date) language sql stable security definer
set search_path=public,pg_temp as $$
  -- A deliberate gap has no active season: nobody is silently assigned to a
  -- different season, and division eligibility treats them as unplaced.
  select s.starts_on,s.ends_on from public.fieldrush_seasons s
  where day_to_use between s.starts_on and s.ends_on;
$$;

create function public.list_fieldrush_seasons()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare today date:=(now() at time zone 'America/Phoenix')::date;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  return jsonb_build_object('seasons',coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_on) from public.fieldrush_seasons s),'[]'::jsonb),
    'current_season_id',(select id from public.fieldrush_seasons where today between starts_on and ends_on),'today',today);
end;
$$;

create function public.admin_list_fieldrush_seasons(actor_admin_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare today date:=(now() at time zone 'America/Phoenix')::date;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  return jsonb_build_object('today',today,
    'seasons',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object(
      'editable',s.starts_on>today and not exists(select 1 from public.fieldrush_season_rewards r where r.season_id=s.id and r.status='PUBLISHED'),
      'published_rewards_locked',exists(select 1 from public.fieldrush_season_rewards r where r.season_id=s.id and r.status='PUBLISHED')) order by s.starts_on)
      from public.fieldrush_seasons s),'[]'::jsonb),
    'rewards',coalesce((select jsonb_agg(to_jsonb(r) order by r.season_id,r.city_id,r.rating_track) from public.fieldrush_season_rewards r),'[]'::jsonb),
    'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id) from
      (select * from public.fieldrush_season_audit_events order by created_at desc,id limit 100) a),'[]'::jsonb));
end;
$$;

create function public.admin_save_fieldrush_season(actor_admin_id uuid,season_id_to_use text,values_to_use jsonb,
  expected_revision_to_use integer default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare previous public.fieldrush_seasons%rowtype; saved public.fieldrush_seasons%rowtype; merged jsonb;
  today date:=(now() at time zone 'America/Phoenix')::date; start_date date; end_date date;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if season_id_to_use is null or season_id_to_use !~ '^[a-z][a-z0-9-]{1,63}$' then raise exception 'Choose a valid lowercase season ID.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' or values_to_use='{}'::jsonb
    or exists(select 1 from jsonb_object_keys(values_to_use) k where k not in ('label','starts_on','ends_on','minimum_rated_games')) then
    raise exception 'Invalid season settings.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into previous from public.fieldrush_seasons where id=season_id_to_use for update;
  if expected_revision_to_use is distinct from coalesce(previous.revision,0) then raise exception 'Season settings changed. Reload before saving.' using errcode='40001'; end if;
  if previous.id is not null and previous.starts_on<=today then raise exception 'A season that has started cannot be edited.'; end if;
  if exists(select 1 from public.fieldrush_season_rewards where season_id=season_id_to_use and status='PUBLISHED') then
    raise exception 'Published prizes lock this season''s dates and qualification rules.';
  end if;
  merged:=jsonb_build_object('minimum_rated_games',2)||case when previous.id is null then '{}'::jsonb else to_jsonb(previous) end||values_to_use;
  if jsonb_typeof(merged->'label') is distinct from 'string' or char_length(trim(merged->>'label')) not between 1 and 40
    or jsonb_typeof(merged->'starts_on') is distinct from 'string' or (merged->>'starts_on') !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(merged->'ends_on') is distinct from 'string' or (merged->>'ends_on') !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(merged->'minimum_rated_games') is distinct from 'number' or (merged->>'minimum_rated_games') !~ '^\d+$'
    or (merged->>'minimum_rated_games')::numeric not between 2 and 100 then raise exception 'Choose valid season dates, label and a qualification minimum of 2–100 games.'; end if;
  start_date:=(merged->>'starts_on')::date; end_date:=(merged->>'ends_on')::date;
  if start_date<=today then raise exception 'Only future seasons can be created or edited.'; end if;
  if end_date<start_date or end_date-start_date>370 then raise exception 'A season must last 1–371 days.'; end if;
  if exists(select 1 from public.fieldrush_seasons where id<>season_id_to_use
    and daterange(starts_on,ends_on,'[]') && daterange(start_date,end_date,'[]')) then raise exception 'Season dates must not overlap another season.'; end if;
  insert into public.fieldrush_seasons(id,label,starts_on,ends_on,minimum_rated_games,revision)
  values(season_id_to_use,trim(merged->>'label'),start_date,end_date,(merged->>'minimum_rated_games')::integer,coalesce(previous.revision,0)+1)
  on conflict(id) do update set label=excluded.label,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    minimum_rated_games=excluded.minimum_rated_games,revision=excluded.revision,updated_at=now() returning * into saved;
  if previous.id is null then
    insert into public.fieldrush_season_rewards(season_id,city_id,rating_track)
    select saved.id,c.id,t.track from public.fieldrush_cities c cross join (values ('OUTFIELD'),('GOALKEEPER')) t(track);
  end if;
  insert into public.fieldrush_season_audit_events(season_id,actor_admin_id,action,reason,before_state,after_state)
  values(saved.id,actor_admin_id,case when previous.id is null then 'SEASON_CREATED' else 'SEASON_UPDATED' end,
    'Admin configured a future season.',case when previous.id is null then '{}'::jsonb else to_jsonb(previous) end,to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;

create function public.admin_save_fieldrush_season_reward(actor_admin_id uuid,season_id_to_use text,city_id_to_use text,
  rating_track_to_use text,values_to_use jsonb,action_to_use text,reason_to_use text default null,
  expected_revision_to_use integer default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare previous public.fieldrush_season_rewards%rowtype; saved public.fieldrush_season_rewards%rowtype; merged jsonb;
  current_season public.fieldrush_seasons%rowtype; key_to_check text;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if action_to_use is null or action_to_use not in ('SAVE','PUBLISH','CORRECT') then raise exception 'Choose save, publish or audited correction.'; end if;
  if rating_track_to_use is null or rating_track_to_use not in ('OUTFIELD','GOALKEEPER') then raise exception 'Choose Outfield or Keeper.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object'
    or exists(select 1 from jsonb_object_keys(values_to_use) k where k not in ('first_prize_cents','second_prize_cents','third_prize_cents')) then
    raise exception 'Invalid prize amounts.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-settings',0));
  select * into current_season from public.fieldrush_seasons where id=season_id_to_use for update;
  if current_season.id is null then raise exception 'Choose an available season.'; end if;
  if current_season.ends_on<(now() at time zone 'America/Phoenix')::date then raise exception 'An ended season''s advertised rewards cannot be changed.'; end if;
  if not exists(select 1 from public.fieldrush_cities where id=city_id_to_use) then raise exception 'Choose an available city.'; end if;
  select * into previous from public.fieldrush_season_rewards where season_id=season_id_to_use and city_id=city_id_to_use and rating_track=rating_track_to_use for update;
  if expected_revision_to_use is distinct from coalesce(previous.revision,0) then raise exception 'Prize settings changed. Reload before saving.' using errcode='40001'; end if;
  if previous.status='PUBLISHED' and action_to_use<>'CORRECT' then raise exception 'Published prizes can only be changed through an audited correction.'; end if;
  if action_to_use='CORRECT' and coalesce(previous.status,'DRAFT')<>'PUBLISHED' then raise exception 'Publish the draft before making a correction.'; end if;
  if action_to_use='CORRECT' and (reason_to_use is null or char_length(trim(reason_to_use)) not between 10 and 1000) then raise exception 'Explain the correction in 10–1000 characters.'; end if;
  merged:=jsonb_build_object('first_prize_cents',15000,'second_prize_cents',10000,'third_prize_cents',5000)
    ||case when previous.season_id is null then '{}'::jsonb else to_jsonb(previous) end||values_to_use;
  foreach key_to_check in array array['first_prize_cents','second_prize_cents','third_prize_cents'] loop
    if jsonb_typeof(merged->key_to_check) is distinct from 'number' or (merged->>key_to_check) !~ '^\d+$'
      or (merged->>key_to_check)::numeric not between 0 and 100000000 then raise exception 'Prizes must be whole USD cents between 0 and 100000000.'; end if;
  end loop;
  insert into public.fieldrush_season_rewards(season_id,city_id,rating_track,first_prize_cents,second_prize_cents,third_prize_cents,status,revision,published_at)
  values(season_id_to_use,city_id_to_use,rating_track_to_use,(merged->>'first_prize_cents')::integer,
    (merged->>'second_prize_cents')::integer,(merged->>'third_prize_cents')::integer,
    case when action_to_use='SAVE' then 'DRAFT' else 'PUBLISHED' end,coalesce(previous.revision,0)+1,
    case when action_to_use='SAVE' then null else coalesce(previous.published_at,now()) end)
  on conflict(season_id,city_id,rating_track) do update set first_prize_cents=excluded.first_prize_cents,
    second_prize_cents=excluded.second_prize_cents,third_prize_cents=excluded.third_prize_cents,
    status=excluded.status,revision=excluded.revision,published_at=excluded.published_at,updated_at=now() returning * into saved;
  insert into public.fieldrush_season_audit_events(season_id,city_id,rating_track,actor_admin_id,action,reason,before_state,after_state)
  values(season_id_to_use,city_id_to_use,rating_track_to_use,actor_admin_id,
    case action_to_use when 'SAVE' then 'REWARD_SAVED' when 'PUBLISH' then 'REWARD_PUBLISHED' else 'REWARD_CORRECTED' end,
    case action_to_use when 'CORRECT' then trim(reason_to_use) when 'SAVE' then 'Admin saved draft season prizes.' else 'Admin published season prizes.' end,
    case when previous.season_id is null then '{}'::jsonb else to_jsonb(previous) end,to_jsonb(saved));
  return to_jsonb(saved);
end;
$$;

-- Exact equal-SR tiebreak: scorer goals, fewer team goals conceded, then name.
-- Source only finalized, eligible played games in this role and season. Goal
-- audit events are not counted: the canonical scorer rows reflect corrections.
create or replace function fieldrush_rating_private.track_rankings(scope_to_use text,city_id_to_use text,rating_track_to_use text,season_starts_on date,season_ends_on date)
returns table(rank bigint,profile_id uuid,display_name text,username text,avatar_url text,skill_rating integer,
  matches_played integer,wins integer,losses integer,draws integer,last_change integer,region text,primary_city_id text,primary_city_name text)
language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
  with events as materialized (
    select * from fieldrush_rating_private.season_track_events(season_starts_on,season_ends_on) where rating_track=rating_track_to_use
  ), stats as (
    select e.profile_id,count(*)::integer matches_played,count(*) filter(where e.result='WIN')::integer wins,
      count(*) filter(where e.result='LOSS')::integer losses,count(*) filter(where e.result='DRAW')::integer draws,
      sum((select count(*) from public.open_queue_goals goal where goal.game_id=e.source_id and goal.profile_id=e.profile_id)) goals_scored,
      sum(case e.side when 'WHITE' then coalesce(g.black_score,0) else coalesce(g.white_score,0) end) goals_conceded
    from events e join public.open_queue_games g on g.id=e.source_id group by e.profile_id having count(*)>=2
  ), ranked as (
    select p.id profile_id,p.display_name,p.username,p.avatar_url,rating.skill_rating,
      s.matches_played,s.wins,s.losses,s.draws,rating.last_change,c.market_city_id,
      catalog.display_name city_name,s.goals_scored,s.goals_conceded
    from stats s join public.profiles p on p.id=s.profile_id and p.account_deleted_at is null
    join fieldrush_rating_private.primary_season_cities(season_starts_on,season_ends_on) c on c.profile_id=p.id
    join public.fieldrush_cities catalog on catalog.id=c.market_city_id
    join fieldrush_rating_private.track_rating_at(p.id,rating_track_to_use,season_ends_on) rating on true
    where scope_to_use='GLOBAL' or c.market_city_id=city_id_to_use
  ) select row_number() over(order by r.skill_rating desc,r.goals_scored desc,r.goals_conceded,lower(r.display_name),r.profile_id),
    r.profile_id,r.display_name,r.username,r.avatar_url,r.skill_rating,r.matches_played,r.wins,r.losses,r.draws,r.last_change,
    r.market_city_id,r.market_city_id,r.city_name from ranked r;
$$;

create function public.get_fieldrush_season_rewards(season_id_to_use text,city_id_to_use text,rating_track_to_use text)
returns jsonb language plpgsql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare season public.fieldrush_seasons%rowtype; reward public.fieldrush_season_rewards%rowtype; result jsonb;
begin
  if auth.uid() is null and coalesce(auth.role(),'')<>'service_role' then raise exception 'You need to sign in again.'; end if;
  select * into season from public.fieldrush_seasons where id=season_id_to_use;
  if season.id is null then raise exception 'Choose an available season.'; end if;
  perform fieldrush_rating_private.validate_ranking_request(season.starts_on,season.ends_on,rating_track_to_use);
  -- Global and unpublished scopes never borrow a city's cash offer.
  if city_id_to_use is null then return null; end if;
  if not exists(select 1 from public.fieldrush_cities where id=city_id_to_use) then raise exception 'Choose an available city.'; end if;
  select * into reward from public.fieldrush_season_rewards where season_id=season_id_to_use and city_id=city_id_to_use
    and rating_track=rating_track_to_use and status='PUBLISHED';
  if reward.season_id is null then return null; end if;
  with rankings as materialized (
    select * from fieldrush_rating_private.track_rankings('CITY',city_id_to_use,rating_track_to_use,season.starts_on,season.ends_on)
    where matches_played>=season.minimum_rated_games
  ), qualified as materialized (
    select row_number() over(order by rank) prize_rank,to_jsonb(r)||jsonb_build_object(
      'leaderboard_rank',r.rank,'rank',row_number() over(order by rank)) payload,profile_id from rankings r
  ), own as (select * from qualified where profile_id=auth.uid())
  select to_jsonb(reward)||jsonb_build_object('season_label',season.label,'season_starts_on',season.starts_on,'season_ends_on',season.ends_on,
    'minimum_rated_games',season.minimum_rated_games,'total_qualified',(select count(*) from qualified),
    'prize_players',coalesce((select jsonb_agg(payload order by prize_rank) from qualified where prize_rank<=3),'[]'::jsonb),
    'current_player',(select payload from own),
    'next_player',(select q.payload from qualified q join own on q.prize_rank=own.prize_rank+1)) into result;
  return result;
end;
$$;

revoke all on function public.list_fieldrush_seasons(),public.get_fieldrush_season_rewards(text,text,text) from public,anon;
grant execute on function public.list_fieldrush_seasons(),public.get_fieldrush_season_rewards(text,text,text) to authenticated,service_role;
revoke all on function public.admin_list_fieldrush_seasons(uuid),public.admin_save_fieldrush_season(uuid,text,jsonb,integer),
  public.admin_save_fieldrush_season_reward(uuid,text,text,text,jsonb,text,text,integer) from public,anon,authenticated;
grant execute on function public.admin_list_fieldrush_seasons(uuid),public.admin_save_fieldrush_season(uuid,text,jsonb,integer),
  public.admin_save_fieldrush_season_reward(uuid,text,text,text,jsonb,text,text,integer) to service_role;
notify pgrst,'reload schema';
