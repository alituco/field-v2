-- One arrival is one entry into play. Corrections retain the original kickoff
-- snapshot and append a reasoned revision; a finished match stays finished.
alter table fieldrush_rating_private.season_zero_matches
  add column initial_active_overrides jsonb not null default '{}'::jsonb
    check(jsonb_typeof(initial_active_overrides)='object'),
  add column ended_at timestamptz,
  add column observed_ended_at timestamptz;
update fieldrush_rating_private.season_zero_matches m set ended_at=coalesce(
  (select max(r.recorded_at) from fieldrush_rating_private.season_zero_match_revisions r
   where r.game_id=m.game_id and r.action='FINISH'),m.updated_at)
where m.lifecycle='FINAL';
update fieldrush_rating_private.season_zero_matches set observed_ended_at=ended_at where ended_at is not null;

create function fieldrush_rating_private.record_solo_finish_wall_time()
returns trigger language plpgsql set search_path=pg_catalog as $$
begin
  if new.lifecycle='FINAL' and old.lifecycle<>'FINAL' then new.ended_at:=clock_timestamp(); new.observed_ended_at:=new.ended_at;
  elsif new.lifecycle='LIVE' and old.lifecycle<>'LIVE' then new.ended_at:=null; new.observed_ended_at:=null; end if;
  return new;
end $$;
create trigger record_solo_finish_wall_time before update of lifecycle
  on fieldrush_rating_private.season_zero_matches for each row
  execute function fieldrush_rating_private.record_solo_finish_wall_time();

create function fieldrush_rating_private.effective_season_zero_roster(game_to_use uuid)
returns jsonb language sql stable set search_path=public,fieldrush_rating_private,pg_temp as $$
 select coalesce(jsonb_agg(p.value||case when m.initial_active_overrides ? (p.value->>'id')
   then jsonb_build_object('initial_active',m.initial_active_overrides->(p.value->>'id')) else '{}'::jsonb end order by p.ordinality),'[]'::jsonb)
 from fieldrush_rating_private.season_zero_matches m,
 jsonb_array_elements(m.observed_roster) with ordinality p(value,ordinality) where m.game_id=game_to_use;
$$;

-- Every calculation and replay uses the corrected entry facts; team, pool,
-- booking, original SR and original observed lineup remain immutable evidence.
do $migration$
declare d text; anchor text;
begin
  d:=pg_get_functiondef('fieldrush_rating_private.season_zero_input(uuid,integer)'::regprocedure);
  anchor:='''roster'',observed_roster,''events'',events';
  if position(anchor in d)=0 then raise exception 'Season 0 input roster changed.'; end if;
  d:=replace(d,anchor,'''roster'',fieldrush_rating_private.effective_season_zero_roster(game_to_use),''events'',events');
  execute d;
  d:=pg_get_functiondef('fieldrush_rating_private.replay_season_zero_ratings(uuid,uuid,text)'::regprocedure);
  anchor:='jsonb_array_elements(state.observed_roster)';
  if position(anchor in d)=0 then raise exception 'Season 0 replay roster changed.'; end if;
  d:=replace(d,anchor,'jsonb_array_elements(fieldrush_rating_private.effective_season_zero_roster(state.game_id))');
  execute d;
end $migration$;

-- Wall arrival is deliberately distinct from the paused playing clock, although
-- the referee enters it only once. The derived JOIN never counts stopped time.
create function fieldrush_rating_private.solo_arrival_playing_second(
  kickoff timestamptz, events_to_use jsonb, arrival timestamptz, played integer)
returns integer language plpgsql immutable set search_path=pg_catalog as $$
declare e jsonb; anchor_at timestamptz:=kickoff; anchor_second integer:=0;
  running boolean:=true; result integer; boundary integer:=played;
begin
  if arrival<=kickoff then return 0; end if;
  for e in select value from jsonb_array_elements(events_to_use) with ordinality clock_event(value,sequence)
    where value->>'type' in ('PAUSE','RESUME') order by (value->>'recorded_at')::timestamptz,(value->>'second')::integer,sequence
  loop
    if (e->>'recorded_at')::timestamptz>arrival then boundary:=least(boundary,(e->>'second')::integer); exit; end if;
    anchor_at:=(e->>'recorded_at')::timestamptz;
    anchor_second:=(e->>'second')::integer;
    running:=e->>'type'='RESUME';
  end loop;
  result:=anchor_second+case when running then greatest(0,floor(extract(epoch from arrival-anchor_at))::integer) else 0 end;
  return greatest(0,least(played,boundary,result));
end $$;

create function fieldrush_rating_private.referee_record_player_snapshot(game_to_use uuid)
returns jsonb language sql stable set search_path=public,fieldrush_rating_private,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object('profile_id',p.id,'display_name',p.display_name,
   'rating_track',r.rating_track,'sr',r.skill_rating,'matches',r.matches_played,
   'game_sr_delta',e.rating_change,'arrived_at',a.checked_in_at,
   'attendance_outcome',a.outcome,'strikes',coalesce(a.strike_delta,0),
   'active_strikes',public.active_reliability_strikes(p.id,clock_timestamp()),
   'can_book',not(public.profile_has_active_play_restriction(p.id) or public.profile_has_active_reliability_booking_restriction(p.id))) order by p.id),'[]'::jsonb)
 from fieldrush_rating_private.season_zero_matches m,
 jsonb_array_elements(m.observed_roster) player
 join public.profiles p on p.id=(player->>'id')::uuid
 join public.fieldrush_player_rating_tracks r on r.profile_id=p.id and r.rating_track=player->>'rating_track'
 left join public.match_attendance_records a on a.booking_id=(player->>'booking_id')::uuid and a.is_current
 left join public.player_rating_events e on e.profile_id=p.id and e.source_type='OPEN_QUEUE' and e.source_id=game_to_use
 where m.game_id=game_to_use;
$$;

create table fieldrush_rating_private.referee_record_preview_key (
 singleton boolean primary key default true check(singleton), secret text not null
);
insert into fieldrush_rating_private.referee_record_preview_key(secret) values(gen_random_uuid()::text||gen_random_uuid()::text);
revoke all on fieldrush_rating_private.referee_record_preview_key from public,anon,authenticated,service_role;

-- Preview hashes bind the exact canonical facts and current dependent ratings.
-- The secret is private; preview itself persists no rows or notification work.
create function fieldrush_rating_private.solo_record_preview_token(actor uuid,game uuid,request uuid,revision integer,input jsonb)
returns text language sql stable security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
 select encode(sha256(convert_to(jsonb_build_object('actor',actor,'game',game,'request',request,
   'revision',revision,'input',input,'attendance',fieldrush_rating_private.referee_record_player_snapshot(game),
   'reliability',jsonb_build_object(
     'incidents',(select jsonb_agg(to_jsonb(i) order by i.id) from public.reliability_incidents i where i.profile_id in
       (select (p->>'id')::uuid from fieldrush_rating_private.season_zero_matches m,jsonb_array_elements(m.observed_roster) p where m.game_id=game)),
     'sanctions',(select jsonb_agg(to_jsonb(i) order by i.id) from public.reliability_sanctions i where i.profile_id in
       (select (p->>'id')::uuid from fieldrush_rating_private.season_zero_matches m,jsonb_array_elements(m.observed_roster) p where m.game_id=game)),
     'appeals',(select jsonb_agg(to_jsonb(i) order by i.id) from public.reliability_appeals i where i.appellant_profile_id in
       (select (p->>'id')::uuid from fieldrush_rating_private.season_zero_matches m,jsonb_array_elements(m.observed_roster) p where m.game_id=game)),
     'moderation',(select jsonb_agg(to_jsonb(i) order by i.id) from public.moderation_actions i where i.subject_profile_id in
       (select (p->>'id')::uuid from fieldrush_rating_private.season_zero_matches m,jsonb_array_elements(m.observed_roster) p where m.game_id=game)),
     'moderation_appeals',(select jsonb_agg(to_jsonb(i) order by i.id) from public.moderation_appeals i where i.appellant_profile_id in
       (select (p->>'id')::uuid from fieldrush_rating_private.season_zero_matches m,jsonb_array_elements(m.observed_roster) p where m.game_id=game))),
   'ratings',(select jsonb_agg(jsonb_build_array(profile_id,rating_track,skill_rating,matches_played) order by profile_id,rating_track)
     from public.fieldrush_player_rating_tracks),
   'matches',(select jsonb_agg(jsonb_build_array(game_id,revision,settlement_status) order by game_id)
     from fieldrush_rating_private.season_zero_matches))::text||secret,'UTF8')),'hex')
 from fieldrush_rating_private.referee_record_preview_key where singleton;
$$;

create or replace function public.get_season_zero_match_state(actor_referee_id uuid,game_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare state fieldrush_rating_private.season_zero_matches%rowtype; normalized jsonb; elapsed integer; g public.open_queue_games%rowtype;
begin
 if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
   raise exception 'This match is not assigned to you.' using errcode='42501'; end if;
 select * into state from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use;
 if not found then return null; end if;
 select * into g from public.open_queue_games where id=game_id_to_use;
 elapsed:=case when state.lifecycle='LIVE' then fieldrush_rating_private.season_zero_elapsed(game_id_to_use) else state.played_seconds end;
 normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game_id_to_use,elapsed));
 return to_jsonb(state)||jsonb_build_object('elapsed_seconds',elapsed,'audit',normalized->'audit','server_now',clock_timestamp(),
   'referee_can_reopen',fieldrush_rating_private.season_zero_referee_can_reopen(game_id_to_use),
   'can_correct_record',g.operational_state='NORMAL' and state.adjudicated_by is null and state.lifecycle in ('LIVE','FINAL') and g.status in ('LIVE','FINAL'),
   'white_score',g.white_score,'black_score',g.black_score,
   'arrivals',fieldrush_rating_private.referee_record_player_snapshot(game_id_to_use),
   'goals',(select coalesce(jsonb_agg(jsonb_build_object('id',goal.id,'team',goal.team,'profile_id',goal.profile_id,
     'assist_profile_id',goal.assist_profile_id,'second',coalesce((select e.minute*60+e.second from public.open_queue_events e
        where e.game_id=goal.game_id and e.goal_id=goal.id and e.event_type='GOAL' order by e.occurred_at desc limit 1),goal.minute*60)) order by goal.minute,goal.id),'[]'::jsonb)
      from public.open_queue_goals goal where goal.game_id=game_id_to_use),
   'record_revisions',(select coalesce(jsonb_agg(to_jsonb(r) order by r.revision desc),'[]'::jsonb) from
     (select revision,actor_id,action,reason,recorded_at from fieldrush_rating_private.season_zero_match_revisions
       where game_id=game_id_to_use and action='REFEREE_RECORD_CORRECTION' order by revision desc limit 20) r));
end $$;

create function fieldrush_rating_private.apply_referee_solo_match_record(
 actor uuid,game uuid,request uuid,expected_revision integer,input jsonb)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare s fieldrush_rating_private.season_zero_matches%rowtype; g public.open_queue_games%rowtype;
 c public.open_queue_clock_states%rowtype; before_state jsonb; before_players jsonb; before_tracks jsonb;
 arrivals jsonb:=coalesce(input->'arrivals','[]'::jsonb); events_to_use jsonb; overrides jsonb; arrival jsonb; e jsonb;
 player_id uuid; arrived timestamptz; played integer; join_second integer; old_arrival timestamptz;
 normalized jsonb; reason text:=trim(coalesce(input->>'reason','')); correction boolean:=false;
 attendance_impact jsonb:='[]'::jsonb; snapshot_after jsonb; impact jsonb; response jsonb; replay jsonb;
 white_score integer; black_score integer; old_finalizing text; boundary timestamptz; event_wall timestamptz;
 new_clock text; observed_now timestamptz:=clock_timestamp(); changed_players integer; seen_players uuid[]:=array[]::uuid[];
 clock_wall timestamptz; clock_second integer:=0; clock_running boolean:=true; event_second integer;
 finish_wall timestamptz; finish_second integer; finish_running boolean; original_bound timestamptz; automatic_finish jsonb;
begin
 select * into g from public.open_queue_games where id=game for update;
 select * into s from fieldrush_rating_private.season_zero_matches where game_id=game for update;
 if g.rating_policy_id is distinct from 'field-sr-season0-v2' or s.game_id is null then raise exception 'Start this Season 0 match before recording playing arrivals.'; end if;
 if g.operational_state<>'NORMAL' or s.adjudicated_by is not null or s.lifecycle not in ('LIVE','FINAL') or g.status not in ('LIVE','FINAL') then
   raise exception 'This match has an organizer decision or is under review. Ask the organizer to resolve it.'; end if;
 if s.revision is distinct from expected_revision then raise exception 'The match changed. Refresh before saving your correction.' using errcode='40001'; end if;
 select * into c from public.open_queue_clock_states where game_id=game for update;
 if c.game_id is null then raise exception 'The playing clock is missing.'; end if;
 before_state:=to_jsonb(s); before_players:=fieldrush_rating_private.referee_record_player_snapshot(game);
 select jsonb_object_agg(profile_id::text||':'||rating_track,jsonb_build_array(skill_rating,matches_played)) into before_tracks from public.fieldrush_player_rating_tracks;
 played:=case when input ? 'played_seconds' then fieldrush_rating_private.season_zero_sr_integer(input->'played_seconds','played_seconds',0)
   when s.lifecycle='LIVE' then fieldrush_rating_private.season_zero_elapsed(game) else s.played_seconds end;
 if played>10800 then raise exception 'Playing time cannot exceed 180 minutes.'; end if;
 boundary:=case when s.lifecycle='FINAL' then s.ended_at else observed_now end;
 if boundary is null then raise exception 'The actual finish time is missing. Ask the organizer to review this match.'; end if;
 correction:=s.lifecycle='FINAL' or input ?| array['events','played_seconds','goals','white_score','black_score'];
 if jsonb_typeof(arrivals)<>'array' or jsonb_array_length(arrivals)>14 then raise exception 'Choose at most fourteen original booked players.'; end if;
 events_to_use:=case when input ? 'events' then input->'events' else s.events end;
 if jsonb_typeof(events_to_use)<>'array' or jsonb_array_length(events_to_use)>500 then raise exception 'Provide at most 500 playing-time events.'; end if;
 -- JOIN is always derived from arrival. Unchanged historical JOINs are retained
 -- when the editor sends the other events; changed JOINs cannot bypass arrival.
 if input ? 'events' then
   if exists(select 1 from jsonb_array_elements(events_to_use) candidate where candidate->>'type'='JOIN' and not exists(
       select 1 from jsonb_array_elements(s.events) old where row(old->>'id',old->>'type',old->>'player_id',(old->>'second')::integer,(old->>'recorded_at')::timestamptz)
       is not distinct from row(candidate->>'id',candidate->>'type',candidate->>'player_id',(candidate->>'second')::integer,(candidate->>'recorded_at')::timestamptz))) then
     raise exception 'Correct the player arrival to change entry into play.'; end if;
   select coalesce(jsonb_agg(value),'[]') into events_to_use from jsonb_array_elements(events_to_use) where value->>'type'<>'JOIN';
   events_to_use:=events_to_use||coalesce((select jsonb_agg(value) from jsonb_array_elements(s.events) where value->>'type'='JOIN'),'[]'::jsonb);
 end if;
 -- A late full-time tap can be corrected without reopening. Preserve its
 -- observed timestamp, but derive the actual whistle from verified running
 -- segments and the explicitly corrected duration. Only the system-generated
 -- terminal pause moves automatically; other contradictory facts are rejected.
 if s.lifecycle='FINAL' and input ? 'played_seconds' then
   original_bound:=coalesce(s.observed_ended_at,s.ended_at);
   select value into automatic_finish from jsonb_array_elements(s.events) with ordinality
     where value->>'type'='PAUSE' and value->>'note'='Referee ended the match.'
       and abs(extract(epoch from (value->>'recorded_at')::timestamptz-s.ended_at))<=1
     order by ordinality desc limit 1;
   if automatic_finish is not null then
     select coalesce(jsonb_agg(value),'[]') into events_to_use from jsonb_array_elements(events_to_use)
       where value->>'id'<>automatic_finish->>'id';
   end if;
   finish_wall:=s.started_at; finish_second:=0; finish_running:=true;
   for e in select value from jsonb_array_elements(events_to_use) with ordinality
     where value->>'type' in ('PAUSE','RESUME') and (value->>'second')::integer<=played
     order by (value->>'recorded_at')::timestamptz,ordinality loop
     finish_wall:=(e->>'recorded_at')::timestamptz; finish_second:=(e->>'second')::integer;
     finish_running:=e->>'type'='RESUME';
   end loop;
   if finish_running then
     boundary:=finish_wall+make_interval(secs=>played-finish_second);
     if boundary>original_bound+interval '1 second' or boundary>observed_now+interval '1 second' then
       raise exception 'The corrected duration cannot extend beyond the recorded final whistle.'; end if;
     boundary:=least(boundary,original_bound,observed_now);
     events_to_use:=events_to_use||jsonb_build_array(jsonb_build_object('id',coalesce(automatic_finish->>'id',request::text||':finish'),
       'type','PAUSE','second',played,'player_id',null,'recorded_at',boundary,'actor_id',actor,'note','Referee ended the match.'));
   elsif played<>finish_second then
     raise exception 'Correct the pause and resume times before changing a duration that ended while paused.';
   end if;
 elsif s.lifecycle='LIVE' and input ? 'events' and not input ? 'played_seconds' then
   played:=fieldrush_rating_private.solo_arrival_playing_second(s.started_at,events_to_use,boundary,10800);
 end if;
 overrides:=s.initial_active_overrides;
 for arrival in select value from jsonb_array_elements(arrivals) loop
   if jsonb_typeof(arrival)<>'object' or exists(select 1 from jsonb_object_keys(arrival) k where k not in ('profile_id','arrived_at'))
     or not arrival ? 'arrived_at' then raise exception 'An arrival needs an original player and an explicit time or absence.'; end if;
   player_id:=(arrival->>'profile_id')::uuid;
   if player_id is null or player_id=any(seen_players) or not exists(select 1 from jsonb_array_elements(s.observed_roster) p where p->>'id'=player_id::text) then
     raise exception 'Choose each original booked player once.'; end if;
   seen_players:=array_append(seen_players,player_id);
   arrived:=(arrival->>'arrived_at')::timestamptz;
   if arrived is not null and (arrived>boundary or arrived<s.started_at-interval '24 hours') then
     raise exception 'Arrival must be before the actual final whistle and cannot be in the future or more than one day before kickoff.'; end if;
   select checked_in_at into old_arrival from public.match_attendance_records where open_queue_game_id=game and profile_id=player_id and is_current;
   correction:=correction or old_arrival is not null or arrived is null or arrived<observed_now-interval '15 seconds';
   overrides:=jsonb_set(overrides,array[player_id::text],to_jsonb(arrived is not null and arrived<=s.started_at));
   select coalesce(jsonb_agg(value),'[]') into events_to_use from jsonb_array_elements(events_to_use)
     where not(value->>'type'='JOIN' and value->>'player_id'=player_id::text);
   if arrived>s.started_at then
     join_second:=fieldrush_rating_private.solo_arrival_playing_second(s.started_at,events_to_use,arrived,played);
     events_to_use:=events_to_use||jsonb_build_array(jsonb_build_object('id',request::text||':'||player_id::text,
       'type','JOIN','second',join_second,'player_id',player_id,'recorded_at',arrived,'actor_id',actor,
       'note','Arrival recorded as entry into play.'));
   end if;
 end loop;
 -- Clock edits move derived entry seconds, never the saved actual arrival.
 if input ?| array['events','played_seconds'] then
   select coalesce(jsonb_agg(case when value->>'type'='JOIN' then jsonb_set(value,'{second}',
     to_jsonb(fieldrush_rating_private.solo_arrival_playing_second(s.started_at,events_to_use,(value->>'recorded_at')::timestamptz,played))) else value end),'[]')
     into events_to_use from jsonb_array_elements(events_to_use);
 end if;
 if char_length(reason)>2000 or (correction and char_length(reason)<10) then
   raise exception 'Explain the correction in 10–2000 characters.'; end if;
 if reason='' then reason:='Referee recorded arrival and entry into play.'; end if;
 -- Real wall order resolves simultaneous paused-clock events. Original order is
 -- retained for tied timestamps; appended arrivals occur after existing ties.
 select coalesce(jsonb_agg(value order by (value->>'second')::integer,(value->>'recorded_at')::timestamptz,ordinality),'[]')
   into events_to_use from jsonb_array_elements(events_to_use) with ordinality;
 clock_wall:=s.started_at;
 for e in select value from jsonb_array_elements(events_to_use) loop
   if jsonb_typeof(e)<>'object' or exists(select 1 from jsonb_object_keys(e) k where k not in ('id','type','second','player_id','recorded_at','actor_id','note')) then
     raise exception 'Only recorded participation and clock facts can be corrected.'; end if;
   event_wall:=(e->>'recorded_at')::timestamptz;
   if event_wall is null or event_wall<s.started_at or event_wall>boundary then raise exception 'Playing-time events must occur between actual kickoff and the final whistle.'; end if;
   event_second:=(e->>'second')::integer;
   if e->>'type' not in ('PAUSE','RESUME') and abs(event_second-
     fieldrush_rating_private.solo_arrival_playing_second(s.started_at,events_to_use,event_wall,played))>1 then
     raise exception 'The playing minute must match the actual event time after excluding pauses.';
   end if;
   if e->>'type' in ('PAUSE','RESUME') then
     if event_wall<clock_wall or (clock_running and abs(event_second-clock_second-floor(extract(epoch from event_wall-clock_wall)))>1)
       or (not clock_running and event_second<>clock_second) then
       raise exception 'The clock correction must agree with the actual pause and resume times.'; end if;
     clock_wall:=event_wall; clock_second:=event_second; clock_running:=e->>'type'='RESUME';
   end if;
 end loop;
 if abs(played-fieldrush_rating_private.solo_arrival_playing_second(s.started_at,events_to_use,boundary,10800))>1 then
   raise exception 'Playing time must match the actual running intervals. Correct the pause and resume times together with the duration.';
 end if;
 update fieldrush_rating_private.season_zero_matches set events=events_to_use,initial_active_overrides=overrides,
   played_seconds=played,revision=revision+1,updated_at=observed_now,
   ended_at=case when lifecycle='FINAL' then boundary else ended_at end,
   rating_status=case when lifecycle='FINAL' and input ? 'played_seconds' then case when played=0 then 'unranked' else 'completed' end else rating_status end,
   completion_rules_version=case when lifecycle='FINAL' and input ? 'played_seconds' then 's0-referee-ended-v1' else completion_rules_version end
   where game_id=game returning * into s;
 normalized:=fieldrush_rating_private.normalize_season_zero_sr(fieldrush_rating_private.season_zero_input(game));
 -- An arrival correction must retain valid departures/cards and minimums. No
 -- hidden deletion of facts makes an impossible corrected timeline seem valid.
 for arrival in select value from jsonb_array_elements(arrivals) loop
   attendance_impact:=attendance_impact||jsonb_build_array(fieldrush_rating_private.referee_apply_solo_arrival(
     actor,game,(arrival->>'profile_id')::uuid,(arrival->>'arrived_at')::timestamptz,reason));
   if s.lifecycle='LIVE' and arrival->>'arrived_at' is not null
     and not exists(select 1 from jsonb_array_elements(before_players) prior_arrival
       where prior_arrival->>'profile_id'=arrival->>'profile_id' and prior_arrival->>'arrived_at' is not null)
     and normalized->'audit'->'players'->(arrival->>'profile_id')->>'final_state'='ACTIVE'
     and public.profile_has_active_play_restriction((arrival->>'profile_id')::uuid) then
     raise exception 'This player has an active playing restriction. Ask the organizer to review it.';
   end if;
 end loop;
 update public.open_queue_bookings b set played=coalesce((normalized->'audit'->'players'->b.profile_id::text->>'actual_seconds')::integer,0)>0
   or normalized->'audit'->'players'->b.profile_id::text->>'final_state'='ACTIVE'
   where b.game_id=game and b.status='CONFIRMED';
 new_clock:=normalized->'audit'->>'final_clock_state';
 if input ?| array['played_seconds','events'] then
   update public.open_queue_clock_states set status=case when s.lifecycle='FINAL' then 'ENDED' else new_clock end,
     accumulated_seconds=played,started_at=case when s.lifecycle='LIVE' and new_clock='RUNNING' then observed_now end where game_id=game;
 end if;
 -- This helper also checks unchanged goals against the corrected attendance.
 response:=fieldrush_rating_private.referee_correct_solo_goals(actor,game,case when input ? 'events' then coalesce(input->'goals',fieldrush_rating_private.solo_recorded_goals(game)) else input->'goals' end,reason);
 white_score:=(response->>'white_score')::integer; black_score:=(response->>'black_score')::integer;
 if (input ? 'white_score' and (input->>'white_score')::integer is distinct from white_score)
   or (input ? 'black_score' and (input->>'black_score')::integer is distinct from black_score) then
   raise exception 'Correct the recorded goals so the score, scorer statistics and replay all agree.'; end if;
 if s.lifecycle='FINAL' then
   update fieldrush_rating_private.season_zero_matches set winner=case when white_score>black_score then 'A' when black_score>white_score then 'B' end where game_id=game;
 end if;
 insert into fieldrush_rating_private.season_zero_match_revisions(game_id,revision,actor_id,action,reason,evidence)
   select game,revision,actor,'REFEREE_RECORD_CORRECTION',reason,jsonb_build_object('before',before_state,'after',to_jsonb(m),'attendance',attendance_impact)
   from fieldrush_rating_private.season_zero_matches m where game_id=game;
 replay:=fieldrush_rating_private.replay_season_zero_ratings(game,actor,reason);
 snapshot_after:=fieldrush_rating_private.referee_record_player_snapshot(game);
 select coalesce(jsonb_agg(jsonb_build_object('profile_id',b->'profile_id','display_name',b->'display_name','rating_track',b->'rating_track',
   'before',b-array['profile_id','display_name','rating_track'],'after',a-array['profile_id','display_name','rating_track']) order by b->>'profile_id'),'[]')
   into impact from jsonb_array_elements(before_players) b join jsonb_array_elements(snapshot_after) a on a->>'profile_id'=b->>'profile_id';
 select count(*) into changed_players from public.fieldrush_player_rating_tracks r
   where before_tracks->(r.profile_id::text||':'||r.rating_track) is distinct from jsonb_build_array(r.skill_rating,r.matches_played)
     and not exists(select 1 from jsonb_array_elements(s.observed_roster) p where p->>'id'=r.profile_id::text);
 return jsonb_build_object('state',public.get_season_zero_match_state(actor,game),'impact',jsonb_build_object('players',impact,
   'attendance',attendance_impact,'dependent_players_changed',changed_players,'dependent_matches_changed',greatest(0,(replay->>'revised_matches')::integer-1)));
end $$;

create function public.referee_save_solo_match_record(actor_referee_id uuid,game_id_to_use uuid,request_id_to_use uuid,
 expected_revision integer,record_input jsonb,preview_only boolean default false,preview_token_to_use text default null)
returns jsonb language plpgsql security definer set search_path=public,fieldrush_rating_private,pg_temp as $$
declare s fieldrush_rating_private.season_zero_matches%rowtype; canonical jsonb:=record_input;
 response jsonb; token text; prior fieldrush_rating_private.season_zero_action_requests%rowtype; request_input jsonb;
 now_to_use timestamptz; resolved jsonb; arrival jsonb; affected uuid;
begin
 if not public.referee_can_manage_reliability_match(actor_referee_id,'SOLO',game_id_to_use) then
   raise exception 'This match is not assigned to you.' using errcode='42501'; end if;
 if request_id_to_use is null or expected_revision is null or expected_revision<1 or preview_only is null
   or jsonb_typeof(record_input) is distinct from 'object'
   or exists(select 1 from jsonb_object_keys(record_input) k where k not in ('reason','arrivals','events','played_seconds','white_score','black_score','goals'))
   or not record_input ?| array['arrivals','events','played_seconds','goals'] then raise exception 'Provide a valid match record change.'; end if;
 perform fieldrush_rating_private.lock_season_zero_sr();
 request_input:=jsonb_build_object('action','SAVE_RECORD','record',record_input);
 select * into prior from fieldrush_rating_private.season_zero_action_requests where request_id=request_id_to_use;
 if found then
   if row(prior.game_id,prior.actor_id,prior.input) is distinct from row(game_id_to_use,actor_referee_id,request_input) then
     raise exception 'This request ID belongs to another action.'; end if;
   return prior.response;
 end if;
 perform 1 from public.open_queue_games where id=game_id_to_use for update;
 select * into s from fieldrush_rating_private.season_zero_matches where game_id=game_id_to_use for update;
 if s.game_id is null then raise exception 'Start this Season 0 match before recording playing arrivals.'; end if;
 if s.revision is distinct from expected_revision then raise exception 'The match changed. Refresh before saving your correction.' using errcode='40001'; end if;
 now_to_use:=clock_timestamp();
 if trim(coalesce(record_input->>'reason',''))='' and not record_input ?| array['events','played_seconds','goals','white_score','black_score']
   and jsonb_typeof(record_input->'arrivals')='array' and jsonb_array_length(record_input->'arrivals')>0
   and not exists(select 1 from jsonb_array_elements(record_input->'arrivals') a where a->>'arrived_at' is distinct from 'now')
   and not exists(select 1 from jsonb_array_elements(record_input->'arrivals') p join public.match_attendance_records a
     on a.profile_id=(p->>'profile_id')::uuid where a.open_queue_game_id=game_id_to_use and a.is_current and a.checked_in_at is not null) then
   canonical:=canonical||jsonb_build_object('reason','Referee recorded arrival and entry into play.');
 end if;
 if record_input ? 'arrivals' then
   if jsonb_typeof(record_input->'arrivals') is distinct from 'array' then raise exception 'Arrivals must be a list.'; end if;
   resolved:='[]';
   for arrival in select value from jsonb_array_elements(record_input->'arrivals') loop
     if arrival->>'arrived_at'='now' then
       if s.lifecycle='FINAL' then raise exception 'For a finished game, record when the player actually arrived before the final whistle.'; end if;
       arrival:=jsonb_set(arrival,'{arrived_at}',to_jsonb(now_to_use));
     end if;
     resolved:=resolved||jsonb_build_array(arrival);
   end loop;
   canonical:=jsonb_set(canonical,'{arrivals}',resolved);
 end if;
 if preview_only or s.lifecycle='FINAL' or preview_token_to_use is not null then
   perform 1 from public.match_attendance_records where open_queue_game_id=game_id_to_use and is_current order by profile_id for update;
   for affected in select (p->>'id')::uuid from jsonb_array_elements(s.observed_roster) p order by p->>'id' loop
     perform pg_advisory_xact_lock(hashtextextended(affected::text,9174));
   end loop;
   token:=fieldrush_rating_private.solo_record_preview_token(actor_referee_id,game_id_to_use,request_id_to_use,expected_revision,canonical);
 end if;
 if not preview_only and (s.lifecycle='FINAL' or preview_token_to_use is not null) and preview_token_to_use is distinct from token then
   raise exception 'Review the current correction preview before saving. The record or affected ratings changed.' using errcode='40001'; end if;
 if preview_only then
   begin
     response:=fieldrush_rating_private.apply_referee_solo_match_record(actor_referee_id,game_id_to_use,request_id_to_use,expected_revision,canonical);
     -- A subtransaction rolls back every evidence, strike, referral, SR and
     -- deferred notification write. The PL/pgSQL response survives rollback.
     raise exception 'Rollback the read-only match record preview.' using errcode='FRP01';
   exception when sqlstate 'FRP01' then null;
   end;
   return response||jsonb_build_object('preview',true,'preview_token',token,'record_input',canonical);
 end if;
 response:=fieldrush_rating_private.apply_referee_solo_match_record(actor_referee_id,game_id_to_use,request_id_to_use,expected_revision,canonical)
   ||jsonb_build_object('preview',false,'record_input',canonical);
 insert into fieldrush_rating_private.season_zero_action_requests(request_id,game_id,actor_id,input,response)
   values(request_id_to_use,game_id_to_use,actor_referee_id,request_input,response);
 return response;
end $$;

-- A checked-in pregame player is a starter. JOIN is no longer a second step
-- which could silently disagree with the player's attendance time.
do $migration$
declare d text; anchor text;
begin
 d:=pg_get_functiondef('public.referee_season_zero_action(uuid,uuid,uuid,integer,jsonb)'::regprocedure);
 anchor:='  if action_name=''JOIN'' and not exists';
 if position(anchor in d)=0 then raise exception 'Referee JOIN validation changed.'; end if;
 d:=replace(d,anchor,E'  if action_name=''JOIN'' then raise exception ''Record the player arrival; arrival also records entry into play.''; end if;\n'||anchor);
 anchor:='select array_agg(value::uuid),count(*) into initial_ids,selected_count from jsonb_array_elements_text(action_input->''participant_ids'');';
 if position(anchor in d)=0 then raise exception 'Referee starting roster changed.'; end if;
 d:=replace(d,anchor,$new$select array_agg(b.profile_id order by b.profile_id),count(*) into initial_ids,selected_count
   from public.open_queue_bookings b join public.match_attendance_records a on a.booking_id=b.id and a.is_current
   where b.game_id=g.id and b.status='CONFIRMED' and a.checked_in_at is not null;$new$);
 execute d;
end $migration$;

revoke all on function fieldrush_rating_private.record_solo_finish_wall_time(),
 fieldrush_rating_private.effective_season_zero_roster(uuid),
 fieldrush_rating_private.solo_arrival_playing_second(timestamptz,jsonb,timestamptz,integer),
 fieldrush_rating_private.referee_record_player_snapshot(uuid),
 fieldrush_rating_private.solo_record_preview_token(uuid,uuid,uuid,integer,jsonb),
 fieldrush_rating_private.apply_referee_solo_match_record(uuid,uuid,uuid,integer,jsonb)
 from public,anon,authenticated,service_role;
revoke all on function public.referee_save_solo_match_record(uuid,uuid,uuid,integer,jsonb,boolean,text) from public,anon,authenticated;
grant execute on function public.referee_save_solo_match_record(uuid,uuid,uuid,integer,jsonb,boolean,text) to service_role;
notify pgrst,'reload schema';
