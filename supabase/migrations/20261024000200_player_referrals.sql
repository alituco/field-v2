-- A referral is a permanent player-to-player link, independent of payments and
-- ratings. Qualification follows verified attendance at a completed game.
create schema fieldrush_referral_private;
revoke all on schema fieldrush_referral_private from public,anon,authenticated,service_role;

create table fieldrush_referral_private.launch (
  singleton boolean primary key default true check(singleton),
  launched_at timestamptz not null default clock_timestamp(),
  season_id text not null references public.fieldrush_seasons(id)
);
-- Pin the actual launch season, whose operator-managed label may be S0 even
-- when its internal ID is s1. Never silently move this prize pool next season.
insert into fieldrush_referral_private.launch(singleton,season_id)
select true,id from public.fieldrush_seasons
where visible_to_players and lifecycle in ('ACTIVE','ENDED')
order by (lifecycle='ACTIVE') desc,starts_on desc limit 1;
do $$ begin
  if not exists(select 1 from fieldrush_referral_private.launch) then
    raise exception 'Publish a leaderboard season before launching referrals.'; end if;
end $$;

create table fieldrush_referral_private.links (
  referred_profile_id uuid primary key references public.profiles(id) on delete restrict,
  referrer_profile_id uuid not null references public.profiles(id) on delete restrict,
  claimed_at timestamptz not null default clock_timestamp(),
  check(referred_profile_id<>referrer_profile_id)
);
create index fieldrush_referral_referrer_idx on fieldrush_referral_private.links(referrer_profile_id,claimed_at,referred_profile_id);
create table fieldrush_referral_private.tie_reviews (
  id uuid primary key default gen_random_uuid(),
  season_id text not null references public.fieldrush_seasons(id),
  evidence_token text not null,
  ordered_profile_ids uuid[] not null check(cardinality(ordered_profile_ids)>1),
  review_note text not null check(char_length(btrim(review_note)) between 10 and 2000),
  actor_admin_id uuid not null references public.referee_profiles(profile_id),
  evidence jsonb not null,
  reviewed_at timestamptz not null default clock_timestamp()
);
create unique index fieldrush_referral_tie_review_idx on fieldrush_referral_private.tie_reviews(evidence_token);
create function fieldrush_referral_private.immutable_record()
returns trigger language plpgsql set search_path=pg_catalog as $$
begin raise exception 'Referral links, launch time and review history are permanent.' using errcode='42501'; end $$;
create trigger immutable_referral_links before update or delete on fieldrush_referral_private.links
for each row execute function fieldrush_referral_private.immutable_record();
create trigger immutable_referral_launch before update or delete on fieldrush_referral_private.launch
for each row execute function fieldrush_referral_private.immutable_record();
create trigger immutable_referral_reviews before update or delete on fieldrush_referral_private.tie_reviews
for each row execute function fieldrush_referral_private.immutable_record();
alter table fieldrush_referral_private.launch enable row level security;
alter table fieldrush_referral_private.links enable row level security;
alter table fieldrush_referral_private.tie_reviews enable row level security;

create view fieldrush_referral_private.players as
select p.id,p.display_name,p.username,a.onboarding_completed_at
from public.profiles p join fieldrush_private.accounts a on a.user_id=p.auth_user_id
join auth.users u on u.id=a.user_id
where p.account_deleted_at is null and p.username is not null
  and a.status='active' and a.onboarding_completed_at is not null
  and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now())
  and coalesce(u.raw_app_meta_data->>'fieldrush_account_type','')<>'staff'
  and not exists(select 1 from public.referee_profiles staff where staff.auth_user_id=u.id);

create function fieldrush_referral_private.require_player()
returns uuid language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare user_id uuid:=fieldrush_private.require_user(); player uuid;
begin
  select p.id into player from fieldrush_referral_private.players p
    join public.profiles original on original.id=p.id where original.auth_user_id=user_id;
  if player is null then raise exception 'Complete your player account before using referrals.' using errcode='42501'; end if;
  return player;
end $$;

create function fieldrush_referral_private.person(profile_to_use uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('id',p.id,'name',p.display_name,'username',p.username,
    'division',case when coalesce(r.matches_played,0)>=2 then case
      when r.skill_rating>=1650 then 1 when r.skill_rating>=1500 then 2
      when r.skill_rating>=1300 then 3 when r.skill_rating>=1100 then 4 else 5 end end,
    'rating_visible',coalesce(r.matches_played,0)>=2)
  from fieldrush_referral_private.players p left join public.fieldrush_player_rating_tracks r
    on r.profile_id=p.id and r.rating_track='OUTFIELD' where p.id=profile_to_use;
$$;

-- Current official evidence, not booking defaults, client flags, payment status,
-- or the SR ledger's minimum-duration/reset-era filters. Reopening or voiding a
-- result removes it until a valid completion is recorded again. One row per
-- person/game prevents duplicate credit across rating tracks or attendance rows.
create view fieldrush_referral_private.attended_games as
with solo_evidence as (
  select a.profile_id,a.open_queue_game_id game_id
  from public.current_match_attendance_records a
  where a.match_kind='SOLO' and a.checked_in_at is not null and a.checked_in_by is not null
  union
  select (p.value->>'id')::uuid,m.game_id
  from fieldrush_rating_private.season_zero_matches m
  left join fieldrush_rating_private.season_zero_active_settlements a on a.game_id=m.game_id
  left join fieldrush_rating_private.season_zero_settlement_revisions r on r.id=a.settlement_id and r.match_revision=m.revision
  -- An earlier reopened game may hold SR for this still-finished game. The
  -- authoritative playing timeline still proves attendance independently.
  cross join lateral jsonb_array_elements(coalesce(r.normalization,
    fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(m.game_id)))#>'{core,players}') p(value)
  where m.lifecycle='FINAL' and m.rating_status in ('completed','unranked','forfeit_confirmed') and m.played_seconds>0
    and coalesce((p.value->>'actual_seconds')::integer,0)>0
  union
  select e.profile_id,e.source_id from public.player_rating_events e
  join public.open_queue_games g on g.id=e.source_id
  where e.source_type='OPEN_QUEUE' and e.counted_as_played
    and g.rating_policy_id is distinct from 'field-sr-season0-v2'
), solo as (
  select distinct e.profile_id,'SOLO'::text match_kind,g.id game_id,g.season_id,
    coalesce(ended.occurred_at,c.updated_at,g.ends_at) completed_at,
    coalesce(m.started_at,c.created_at,g.starts_at) played_at
  from solo_evidence e join public.open_queue_games g on g.id=e.game_id
  left join public.open_queue_clock_states c on c.game_id=g.id
  left join fieldrush_rating_private.season_zero_matches m on m.game_id=g.id
  left join lateral(select max(v.occurred_at) occurred_at from public.open_queue_events v
    where v.game_id=g.id and v.event_type='MATCH_ENDED') ended on true
  left join lateral(select v.resolution_type from public.match_resolution_cases r
    join public.match_resolution_revisions v on v.case_id=r.id where r.open_queue_game_id=g.id
    order by v.revision desc limit 1) resolution on true
  where g.status='FINAL'
    and (m.game_id is null or (m.lifecycle='FINAL' and m.rating_status in ('completed','unranked','forfeit_confirmed')))
    and coalesce(resolution.resolution_type,'RECORDED_RESULT') in ('RECORDED_RESULT','HOME_NO_SHOW','AWAY_NO_SHOW')
    and coalesce(m.played_seconds,c.accumulated_seconds,
      case when exists(select 1 from public.player_rating_events re where re.source_type='OPEN_QUEUE'
        and re.source_id=g.id and re.counted_as_played) then 1 else 0 end)>0
    and not exists(select 1 from public.current_match_attendance_records a
      where a.match_kind='SOLO' and a.open_queue_game_id=g.id and a.profile_id=e.profile_id
        and (a.outcome='NO_SHOW' or a.cancelled_at is not null))
), clan as (
  select distinct a.profile_id,'CLAN'::text match_kind,f.id game_id,null::text season_id,
    coalesce(ended.occurred_at,c.updated_at) completed_at,
    f.match_date::timestamp at time zone 'America/Phoenix' played_at
  from public.current_match_attendance_records a join public.fixtures f on f.id=a.fixture_id
  join public.fixture_clock_states c on c.fixture_id=f.id
  left join lateral(select max(v.occurred_at) occurred_at from public.fixture_events v
    where v.fixture_id=f.id and v.event_type='MATCH_ENDED') ended on true
  left join lateral(select v.resolution_type from public.match_resolution_cases r
    join public.match_resolution_revisions v on v.case_id=r.id where r.fixture_id=f.id
    order by v.revision desc limit 1) resolution on true
  where a.match_kind='CLAN' and f.status='FINAL' and c.status='ENDED' and c.accumulated_seconds>0
    and a.checked_in_at is not null and a.checked_in_by is not null
    and a.outcome is distinct from 'NO_SHOW' and a.cancelled_at is null
    and coalesce(resolution.resolution_type,'RECORDED_RESULT') in ('RECORDED_RESULT','HOME_NO_SHOW','AWAY_NO_SHOW')
)
select * from solo union all select * from clan;

create view fieldrush_referral_private.competition as
select s.id,s.label,s.starts_on,s.ends_on,l.launched_at,
  s.starts_on::timestamp at time zone 'America/Phoenix' starts_at,
  (s.ends_on+1)::timestamp at time zone 'America/Phoenix' ends_at,
  s.lifecycle='ENDED' or now()>=(s.ends_on+1)::timestamp at time zone 'America/Phoenix' ended
from fieldrush_referral_private.launch l join public.fieldrush_seasons s on s.id=l.season_id;

create view fieldrush_referral_private.season_attendance as
select g.* from fieldrush_referral_private.attended_games g
cross join fieldrush_referral_private.competition c
where (g.season_id=c.id or (g.season_id is null and g.played_at>=c.starts_at and g.played_at<c.ends_at))
  and g.completed_at<c.ends_at;

-- First attendance is a lifetime fact. A legacy player can enter a code in
-- the launch grace window and immediately earn the referrer one current-season
-- point. Only the tiebreak game totals are limited to the competition season.
create view fieldrush_referral_private.link_credits as
with first_games as (
  select profile_id,min(completed_at) first_completed_at
  from fieldrush_referral_private.attended_games group by profile_id
), earned as (
  select l.*,case when f.first_completed_at is not null
    then greatest(l.claimed_at,f.first_completed_at) end earned_at
  from fieldrush_referral_private.links l left join first_games f on f.profile_id=l.referred_profile_id
)
select e.*,coalesce(e.earned_at>=c.starts_at and e.earned_at<c.ends_at,false) qualified
from earned e cross join fieldrush_referral_private.competition c;

create view fieldrush_referral_private.scores as
with appearances as (select profile_id,count(*)::integer games_played
  from fieldrush_referral_private.season_attendance group by profile_id),
credits as (
  select l.referrer_profile_id,l.referred_profile_id,coalesce(a.games_played,0) games_played,l.qualified
  from fieldrush_referral_private.link_credits l
  left join appearances a on a.profile_id=l.referred_profile_id
), totals as (
  select referrer_profile_id,count(*) filter(where qualified)::integer referral_count,
    count(*) filter(where not qualified)::integer waiting_count,
    coalesce(sum(games_played) filter(where qualified),0)::integer referred_games_played
  from credits group by referrer_profile_id
)
select p.id,coalesce(t.referral_count,0) referral_count,coalesce(t.waiting_count,0) waiting_count,
  coalesce(a.games_played,0) games_played,coalesce(t.referred_games_played,0) referred_games_played
from fieldrush_referral_private.players p left join totals t on t.referrer_profile_id=p.id
left join appearances a on a.profile_id=p.id;

create view fieldrush_referral_private.tie_groups as
with groups as (
  select s.referral_count,s.games_played,s.referred_games_played,
    array_agg(s.id order by s.id) member_ids,count(*)::integer member_count
  from fieldrush_referral_private.scores s where s.referral_count>=2
  group by s.referral_count,s.games_played,s.referred_games_played
)
select g.*,md5(jsonb_build_object('season_id',c.id,'starts_on',c.starts_on,'ends_on',c.ends_on,
  'referral_count',g.referral_count,'games_played',g.games_played,
  'referred_games_played',g.referred_games_played,'member_ids',g.member_ids)::text) evidence_token
from groups g cross join fieldrush_referral_private.competition c;

create view fieldrush_referral_private.ranked as
with ranks as (
  select s.*,rank() over(order by s.referral_count desc,s.games_played desc,s.referred_games_played desc)::integer base_rank,
    t.member_count,t.evidence_token,r.ordered_profile_ids,r.review_note,r.reviewed_at,
    array_position(r.ordered_profile_ids,s.id) reviewed_position
  from fieldrush_referral_private.scores s join fieldrush_referral_private.tie_groups t
    using(referral_count,games_played,referred_games_played)
  left join lateral(select * from fieldrush_referral_private.tie_reviews r
    where r.evidence_token=t.evidence_token order by reviewed_at desc,id desc limit 1) r on true
  where s.referral_count>=2
)
select r.*,base_rank+coalesce(reviewed_position-1,0) rank,
  member_count>1 and reviewed_position is null needs_review,
  case when reviewed_position is not null then base_rank+reviewed_position-1<=5
    else base_rank+member_count-1<=5 end prize_eligible
from ranks r;

create function fieldrush_referral_private.season_json()
returns jsonb language sql stable security definer set search_path=pg_catalog as $$
  select jsonb_build_object('id',id,'label',label,'ended',ended,'starts_on',starts_on,'ends_on',ends_on)
  from fieldrush_referral_private.competition;
$$;
create function fieldrush_referral_private.row_payload(row_to_use jsonb)
returns jsonb language sql stable security definer set search_path=pg_catalog as $$
  select fieldrush_referral_private.person((row_to_use->>'id')::uuid)||jsonb_build_object(
    'rank',row_to_use->'rank','referral_count',row_to_use->'referral_count',
    'games_played',row_to_use->'games_played','referred_games_played',row_to_use->'referred_games_played',
    'needs_review',coalesce((row_to_use->>'needs_review')::boolean,false),
    'prize_eligible',coalesce((row_to_use->>'prize_eligible')::boolean,false));
$$;
create function fieldrush_referral_private.row_json(profile_to_use uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog as $$
  select fieldrush_referral_private.person(s.id)||jsonb_build_object('rank',r.rank,'referral_count',s.referral_count,
    'games_played',s.games_played,'referred_games_played',s.referred_games_played,
    'needs_review',coalesce(r.needs_review,false),'prize_eligible',coalesce(r.prize_eligible,false))
  from fieldrush_referral_private.scores s left join fieldrush_referral_private.ranked r using(id)
  where s.id=profile_to_use;
$$;

create function fieldrush_referral_private.referred_page(player_to_use uuid,offset_to_use integer,limit_to_use integer)
returns jsonb language sql stable security definer set search_path=pg_catalog as $$
  with appearances as (select profile_id,count(*)::integer games_played
    from fieldrush_referral_private.season_attendance group by profile_id), rows as (
    select l.referred_profile_id,l.claimed_at,coalesce(s.games_played,0) games_played,l.qualified
    from fieldrush_referral_private.link_credits l
    left join appearances s on s.profile_id=l.referred_profile_id
    where l.referrer_profile_id=player_to_use
  ), page as (select * from rows order by claimed_at desc,referred_profile_id offset offset_to_use limit limit_to_use)
  select jsonb_build_object('entries',coalesce((select jsonb_agg(coalesce(fieldrush_referral_private.person(referred_profile_id),
      jsonb_build_object('id',referred_profile_id,'name','Deleted player','username',null,'division',null,'rating_visible',false))
    ||jsonb_build_object('qualified',qualified,'games_played',games_played) order by claimed_at desc,referred_profile_id) from page),'[]'::jsonb),
    'total',(select count(*) from rows),'next_offset',case when (select count(*) from rows)>offset_to_use+limit_to_use
      then offset_to_use+limit_to_use end);
$$;

create function public.get_fieldrush_referred_players(offset_to_use integer default 0,limit_to_use integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare player uuid:=fieldrush_referral_private.require_player();
begin
  if offset_to_use is null or offset_to_use<0 or limit_to_use is null or limit_to_use not between 1 and 100 then
    raise exception 'Choose a valid referral page.' using errcode='22023'; end if;
  return fieldrush_referral_private.referred_page(player,offset_to_use,limit_to_use);
end $$;

create function public.get_fieldrush_referrals()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare player uuid:=fieldrush_referral_private.require_player(); expires timestamptz; code text;
  linked fieldrush_referral_private.links%rowtype; summary jsonb; friends jsonb; server_time timestamptz:=statement_timestamp();
begin
  select greatest(p.onboarding_completed_at,l.launched_at)+interval '7 days',upper(p.username) into expires,code
    from fieldrush_referral_private.players p cross join fieldrush_referral_private.launch l where p.id=player;
  select * into linked from fieldrush_referral_private.links where referred_profile_id=player;
  select fieldrush_referral_private.row_json(player)||jsonb_build_object('waiting_count',s.waiting_count) into summary
    from fieldrush_referral_private.scores s where s.id=player;
  friends:=fieldrush_referral_private.referred_page(player,0,50);
  return summary||jsonb_build_object('server_now',server_time,'entry_expires_at',expires,
    'can_add_code',linked.referred_profile_id is null and server_time<expires,'own_code',code,
    'referrer',case when linked.referrer_profile_id is null then null else
      coalesce(fieldrush_referral_private.person(linked.referrer_profile_id),jsonb_build_object(
        'id',linked.referrer_profile_id,'name','Deleted player','username',null,'division',null,'rating_visible',false)) end,
    'referrer_credited',exists(select 1 from fieldrush_referral_private.link_credits c
      where c.referred_profile_id=player and c.qualified),
    'season',fieldrush_referral_private.season_json(),'prize_pool_minor',25000,'prize_each_minor',5000,
    'minimum_referrals',2,'prize_places',5,'referrals',friends->'entries','referrals_total',friends->'total',
    'referrals_next_offset',friends->'next_offset');
end $$;

create function public.check_fieldrush_referral_code(code_to_use text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare player uuid:=fieldrush_referral_private.require_player(); code text:=lower(btrim(code_to_use));
  candidate uuid; expires timestamptz;
begin
  if exists(select 1 from fieldrush_referral_private.links where referred_profile_id=player) then
    raise exception 'Your referral is already linked and cannot be changed.' using errcode='22023'; end if;
  select greatest(p.onboarding_completed_at,l.launched_at)+interval '7 days' into expires
    from fieldrush_referral_private.players p cross join fieldrush_referral_private.launch l where p.id=player;
  if statement_timestamp()>=expires then raise exception 'Your referral window has closed.' using errcode='22023'; end if;
  if code is null or code !~ '^[a-z0-9._]{3,20}$' then
    raise exception 'We couldn’t find that code. Check the spelling.' using errcode='22023'; end if;
  select id into candidate from fieldrush_referral_private.players where username=code;
  if candidate=player then raise exception 'That’s your own code.' using errcode='22023'; end if;
  if candidate is null then raise exception 'We couldn’t find that code. Check the spelling.' using errcode='22023'; end if;
  return fieldrush_referral_private.person(candidate);
end $$;

create function public.claim_fieldrush_referral_code(code_to_use text,expected_referrer_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare player uuid:=fieldrush_referral_private.require_player(); code text:=lower(btrim(code_to_use));
  existing fieldrush_referral_private.links%rowtype; candidate uuid; expires timestamptz; server_time timestamptz;
begin
  if expected_referrer_id is null or code is null or code !~ '^[a-z0-9._]{3,20}$' then
    raise exception 'Check your friend’s code again.' using errcode='22023'; end if;
  if expected_referrer_id=player then raise exception 'That’s your own code.' using errcode='22023'; end if;
  -- Deterministic ordering also handles simultaneous A->B and B->A requests.
  -- Both checked identities stay fixed through the deadline check and insert.
  perform 1 from public.profiles where id in (player,expected_referrer_id) order by id for update;
  select * into existing from fieldrush_referral_private.links where referred_profile_id=player;
  if existing.referred_profile_id is not null then
    if existing.referrer_profile_id=expected_referrer_id then
      return public.get_fieldrush_referrals(); end if;
    raise exception 'Your referral is already linked and cannot be changed.' using errcode='22023';
  end if;
  server_time:=clock_timestamp();
  select greatest(p.onboarding_completed_at,l.launched_at)+interval '7 days' into expires
    from fieldrush_referral_private.players p cross join fieldrush_referral_private.launch l where p.id=player;
  if expires is null or server_time>=expires then
    raise exception 'Your referral window has closed.' using errcode='22023'; end if;
  -- Match the exact checked identity, including punctuation, after any rename
  -- transaction has released its lock.
  select id into candidate from fieldrush_referral_private.players where id=expected_referrer_id and username=code;
  if candidate is null then raise exception 'That code has changed. Check your friend’s code again.' using errcode='22023'; end if;
  -- Recheck real time immediately before saving, never a pre-lock timestamp.
  server_time:=clock_timestamp();
  if server_time>=expires then raise exception 'Your referral window has closed.' using errcode='22023'; end if;
  insert into fieldrush_referral_private.links(referred_profile_id,referrer_profile_id,claimed_at)
    values(player,candidate,server_time);
  return public.get_fieldrush_referrals();
end $$;

create function public.get_fieldrush_referral_leaderboard(offset_to_use integer default 0,limit_to_use integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare player uuid:=fieldrush_referral_private.require_player(); result jsonb;
begin
  if offset_to_use is null or offset_to_use<0 or limit_to_use is null or limit_to_use not between 1 and 100 then
    raise exception 'Choose a valid referral leaderboard page.' using errcode='22023'; end if;
  with rest as (select * from fieldrush_referral_private.ranked where not prize_eligible),
  page as (select * from rest order by rank,id offset offset_to_use limit limit_to_use)
  select jsonb_build_object('season',fieldrush_referral_private.season_json(),
    'prize_entries',coalesce((select jsonb_agg(fieldrush_referral_private.row_payload(to_jsonb(r)) order by rank,id)
      from fieldrush_referral_private.ranked r where prize_eligible),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(fieldrush_referral_private.row_payload(to_jsonb(page)) order by rank,id) from page),'[]'::jsonb),
    'me',fieldrush_referral_private.row_json(player),'qualified_total',(select count(*) from fieldrush_referral_private.ranked),
    'next_offset',case when (select count(*) from rest)>offset_to_use+limit_to_use then offset_to_use+limit_to_use end)
    into result;
  return result;
end $$;

create function public.admin_get_fieldrush_referrals(actor_admin_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access required.' using errcode='42501'; end if;
  return jsonb_build_object('season',fieldrush_referral_private.season_json(),
    'qualified_total',(select count(*) from fieldrush_referral_private.ranked),
    'entries',coalesce((select jsonb_agg(fieldrush_referral_private.row_payload(to_jsonb(p)) order by rank,id)
      from (select * from fieldrush_referral_private.ranked order by rank,id limit 100) p),'[]'::jsonb),
    'tie_groups',coalesce((select jsonb_agg(jsonb_build_object('evidence_token',t.evidence_token,
      'rank',(select min(base_rank) from fieldrush_referral_private.ranked r where r.evidence_token=t.evidence_token),
      'referral_count',t.referral_count,'games_played',t.games_played,'referred_games_played',t.referred_games_played,
      'entries',(select jsonb_agg(fieldrush_referral_private.row_payload(to_jsonb(r)) order by r.rank,r.id)
        from fieldrush_referral_private.ranked r where r.evidence_token=t.evidence_token),
      'resolved',v.id is not null,'review_note',v.review_note,'reviewed_at',v.reviewed_at,
      'ordered_profile_ids',coalesce(to_jsonb(v.ordered_profile_ids),'[]'::jsonb))
      order by t.referral_count desc,t.games_played desc,t.referred_games_played desc)
      from fieldrush_referral_private.tie_groups t left join lateral(select * from fieldrush_referral_private.tie_reviews r
        where r.evidence_token=t.evidence_token order by reviewed_at desc,id desc limit 1) v on true
      where t.member_count>1),'[]'::jsonb));
end $$;

create function public.admin_review_fieldrush_referral_tie(actor_admin_id uuid,evidence_token_to_use text,
  ordered_profile_ids uuid[],review_note text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare tied fieldrush_referral_private.tie_groups%rowtype; review_id uuid; previous_order uuid[];
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access required.' using errcode='42501'; end if;
  if review_note is null or char_length(btrim(review_note)) not between 10 and 2000 then
    raise exception 'Give a review reason between 10 and 2000 characters.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-referral-review',0));
  select * into tied from fieldrush_referral_private.tie_groups where evidence_token=evidence_token_to_use and member_count>1;
  if tied.evidence_token is null then raise exception 'The standings changed. Reload and review the current tie.' using errcode='40001'; end if;
  if ordered_profile_ids is null or cardinality(ordered_profile_ids)<>tied.member_count
    or exists(select 1 from unnest(ordered_profile_ids) x where x is null)
    or (select array_agg(x order by x) from unnest(ordered_profile_ids) x) is distinct from tied.member_ids then
    raise exception 'Rank every tied player exactly once.' using errcode='22023'; end if;
  select r.ordered_profile_ids into previous_order from fieldrush_referral_private.tie_reviews r
    where r.evidence_token=evidence_token_to_use;
  if previous_order is not null then
    if previous_order=ordered_profile_ids then return public.admin_get_fieldrush_referrals(actor_admin_id); end if;
    raise exception 'This tie was already reviewed. Reload the current standings.' using errcode='40001';
  end if;
  insert into fieldrush_referral_private.tie_reviews(season_id,evidence_token,ordered_profile_ids,review_note,actor_admin_id,evidence)
    select id,evidence_token_to_use,ordered_profile_ids,btrim(review_note),actor_admin_id,to_jsonb(tied)
    from fieldrush_referral_private.competition returning id into review_id;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'REFERRAL_TIE_REVIEWED','ACTION',review_id,btrim(review_note),
      jsonb_build_object('tie',to_jsonb(tied)),jsonb_build_object('ordered_profile_ids',ordered_profile_ids,'evidence_token',evidence_token_to_use));
  return public.admin_get_fieldrush_referrals(actor_admin_id);
end $$;

revoke all on all tables in schema fieldrush_referral_private from public,anon,authenticated,service_role;
revoke all on all functions in schema fieldrush_referral_private from public,anon,authenticated,service_role;
revoke all on function public.get_fieldrush_referrals(),public.get_fieldrush_referred_players(integer,integer),
  public.check_fieldrush_referral_code(text),public.claim_fieldrush_referral_code(text,uuid),
  public.get_fieldrush_referral_leaderboard(integer,integer),public.admin_get_fieldrush_referrals(uuid),
  public.admin_review_fieldrush_referral_tie(uuid,text,uuid[],text) from public,anon,authenticated,service_role;
grant execute on function public.get_fieldrush_referrals(),public.get_fieldrush_referred_players(integer,integer),
  public.check_fieldrush_referral_code(text),public.claim_fieldrush_referral_code(text,uuid),
  public.get_fieldrush_referral_leaderboard(integer,integer) to authenticated;
grant execute on function public.admin_get_fieldrush_referrals(uuid),public.admin_review_fieldrush_referral_tie(uuid,text,uuid[],text) to service_role;
notify pgrst,'reload schema';
