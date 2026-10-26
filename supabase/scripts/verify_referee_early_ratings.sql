-- Rollback-only, full application schema. No external provider or hosted writes.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table early_rating_checks(label text);
create function pg_temp.early_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Early rating: %',label; end if;
  insert into early_rating_checks values(label); end $$;
create function pg_temp.early_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
  perform pg_temp.early_expect(rejected,'rejected: '||expected);
end $$;

-- Both participation formats use the exact existing rating formula. Only the
-- ordinary minimum playing duration changes for an explicitly versioned result.
do $$
declare input jsonb; result jsonb; legacy jsonb; comparison jsonb; version text; status text;
begin
  input:=jsonb_build_object('policy_id','field-sr-season0-v2','status','completed','winner','A',
    'scheduled_seconds',3600,'played_seconds',129,'team_strengths','{"A":1000,"B":1000}'::jsonb,
    'average_count_difference_a',0,'players',jsonb_build_array(
      jsonb_build_object('id','winner','team','A','sr_before',1000,'games_before',10,'actual_seconds',129,'protected_seconds',0,'exit_reason','NORMAL'),
      jsonb_build_object('id','loser','team','B','sr_before',1000,'games_before',10,'actual_seconds',129,'protected_seconds',0,'exit_reason','NORMAL'),
      jsonb_build_object('id','injured','team','B','sr_before',1000,'games_before',10,'actual_seconds',64,'protected_seconds',0,'exit_reason','EXCUSED'),
      jsonb_build_object('id','late','team','A','sr_before',1000,'games_before',10,'actual_seconds',128,'protected_seconds',0,'exit_reason','NORMAL'),
      jsonb_build_object('id','absent','team','A','sr_before',1000,'games_before',10,'actual_seconds',0,'protected_seconds',0,'exit_reason','NORMAL'),
      jsonb_build_object('id','quit','team','A','sr_before',1000,'games_before',10,'actual_seconds',129,'protected_seconds',0,'exit_reason','QUIT'),
      jsonb_build_object('id','red','team','A','sr_before',1000,'games_before',10,'actual_seconds',129,'protected_seconds',0,'exit_reason','RED_CARD'),
      jsonb_build_object('id','blue','team','B','sr_before',1000,'games_before',10,'actual_seconds',129,'protected_seconds',0,'exit_reason','BLUE_CARD')));
  perform pg_temp.early_reject(format('select fieldrush_rating_private.calculate_season_zero_sr(%L::jsonb)',input),
    'A shortened session is not a normally completed match');
  foreach version in array array['s0-standard-v1','s0-configurable-v1'] loop
    input:=input||jsonb_build_object('participation_rules_version',version,'minimum_players',2,'completion_rules_version','s0-referee-ended-v1');
    result:=fieldrush_rating_private.calculate_season_zero_sr(input);
    perform pg_temp.early_expect(result->>'settlement'='RATED' and result#>>'{players,winner,delta}'='20'
      and result#>>'{players,loser,delta}'='-20' and result#>>'{players,winner,games_after}'='11'
      and result#>>'{players,winner,minimum_played_seconds}'='129','129-second normal win/loss and counted appearance: '||version);
    perform pg_temp.early_expect(result#>>'{players,injured,delta}'='0' and result#>>'{players,injured,counted}'='false'
      and result#>>'{players,late,delta}'='0' and result#>>'{players,late,counted}'='false'
      and result#>>'{players,absent,delta}'='0' and result#>>'{players,absent,counted}'='false','injured early exit, late join and no-play remain uncounted: '||version);
    perform pg_temp.early_expect(result#>>'{players,quit,delta}'='0' and result#>>'{players,quit,counted}'='false'
      and result#>>'{players,red,delta}'='0' and result#>>'{players,red,counted}'='false'
      and result#>>'{players,blue,delta}'='-20' and result#>>'{players,blue,counted}'='false','short quit and card protections unchanged: '||version);
    foreach status in array array['cancelled','no_contest','unranked','forfeit_confirmed','pending_review'] loop
      result:=fieldrush_rating_private.calculate_season_zero_sr(input||jsonb_build_object('status',status));
      legacy:=fieldrush_rating_private.calculate_season_zero_sr((input-'completion_rules_version')||jsonb_build_object('status',status));
      perform pg_temp.early_expect(result=legacy,'non-completion outcome unchanged: '||version||'/'||status);
    end loop;
    -- Exactly the full duration is required below ten minutes. Crossing 600
    -- seconds restores the established ten-minute minimum, without rounding.
    comparison:=jsonb_set(jsonb_set(input,'{players,0,actual_seconds}','599'),'{players,1,actual_seconds}','598');
    result:=fieldrush_rating_private.calculate_season_zero_sr(comparison||'{"played_seconds":599}');
    perform pg_temp.early_expect(result#>>'{players,winner,counted}'='true' and result#>>'{players,winner,delta}'='20'
      and result#>>'{players,loser,counted}'='false' and result#>>'{players,loser,delta}'='0',
      '599-second match counts all 599 seconds, but excludes 598: '||version);
    result:=fieldrush_rating_private.calculate_season_zero_sr(comparison||'{"played_seconds":600}');
    perform pg_temp.early_expect(result#>>'{players,winner,counted}'='false' and result#>>'{players,winner,delta}'='0'
      and result#>>'{players,winner,minimum_played_seconds}'='600','600-second match excludes 599 seconds: '||version);
    comparison:=jsonb_set(jsonb_set(comparison,'{players,0,actual_seconds}','600'),'{players,1,actual_seconds}','600');
    result:=fieldrush_rating_private.calculate_season_zero_sr(comparison||'{"played_seconds":600}');
    perform pg_temp.early_expect(result#>>'{players,winner,counted}'='true' and result#>>'{players,winner,delta}'='20'
      and result#>>'{players,loser,counted}'='true' and result#>>'{players,loser,delta}'='-20',
      'exactly 600 seconds earns normal win and loss SR: '||version);

    -- Eligible long-game participants, a verified departure after 20 minutes,
    -- protected time, and card/quit outcomes retain every numeric old field.
    comparison:=input||jsonb_build_object('played_seconds',3600,'players',(
      select jsonb_agg(p||jsonb_build_object('actual_seconds',case p->>'id' when 'absent' then 0 when 'late' then 599
        when 'injured' then 1200 else 600 end,'protected_seconds',case when p->>'id'='injured' then 600 else 0 end) order by n)
      from jsonb_array_elements(input->'players') with ordinality as p(p,n)));
    foreach status in array array['completed','forfeit_confirmed'] loop
      result:=fieldrush_rating_private.calculate_season_zero_sr(comparison||jsonb_build_object('status',status));
      legacy:=fieldrush_rating_private.calculate_season_zero_sr((comparison-'completion_rules_version')||jsonb_build_object('status',status));
      perform pg_temp.early_expect(not exists(select 1 from jsonb_each(result->'players') p
        where p.value-'minimum_played_seconds' is distinct from legacy->'players'->p.key)
        and result-'players'=legacy-'players','eligible long-game formula and protections unchanged: '||version||'/'||status);
      perform pg_temp.early_expect(result#>>'{players,injured,counted}'='true' and result#>>'{players,injured,delta}'='-17'
        and result#>>'{players,winner,delta}'='20' and result#>>'{players,late,counted}'='false',
        'eligible protected loss and 599-second exclusion remain unchanged: '||version||'/'||status);
    end loop;

    -- Old full-duration completed results and normal ten-minute thresholds stay
    -- numerically identical; only new audit metadata is added to each award.
    result:=fieldrush_rating_private.calculate_season_zero_sr(input||'{"played_seconds":3600}');
    legacy:=fieldrush_rating_private.calculate_season_zero_sr((input-'completion_rules_version')||'{"played_seconds":3600}');
    perform pg_temp.early_expect(not exists(select 1 from jsonb_each(result->'players') p
      where p.value-'minimum_played_seconds' is distinct from legacy->'players'->p.key),'normal full-length eligibility unchanged: '||version);
  end loop;
  perform pg_temp.early_reject(format('select fieldrush_rating_private.calculate_season_zero_sr(%L::jsonb)',input||'{"completion_rules_version":"unknown"}'),
    'Unknown completion rules version');
  perform pg_temp.early_reject(format('select fieldrush_rating_private.normalize_season_zero_sr(%L::jsonb)',input||'{"completion_rules_version":null}'),
    'Unknown completion rules version');
  perform pg_temp.early_reject(format('select fieldrush_rating_private.calculate_season_zero_sr(%L::jsonb)',input||'{"played_seconds":0}'),
    'A completed match requires positive verified playing time');
end $$;

create sequence pg_temp.early_person;
create sequence pg_temp.early_game_number;
create function pg_temp.early_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.early_person'); prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555558'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Early','last_name','Player','username','early_'||n,
    'date_of_birth','2000-01-01','email','early_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
  return player;
end $$;
create function pg_temp.early_game(actor uuid,players uuid[]) returns uuid language plpgsql as $$
declare game uuid; i integer; kickoff timestamptz:=date_trunc('minute',clock_timestamp())-interval '1 minute'*nextval('pg_temp.early_game_number');
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,minimum_players,participation_rules_version)
    values('Disposable early-rating verification',kickoff,kickoff+interval '1 hour',0,2,'s0-configurable-v1') returning id into game;
  for i in 1..cardinality(players) loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
      values(game,players[i],case when i<=2 then 'GK' else 'DEF' end,'CONFIRMED',0,0,'FREE','PAID');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=actor,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=game;
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,actor,actor);
  perform public.referee_assign_season_zero_teams(actor,game,gen_random_uuid());
  return game;
end $$;

do $$
declare actor uuid:=pg_temp.early_player(); login uuid:=gen_random_uuid(); players uuid[]:=array[]::uuid[];
  game uuid; historical uuid; i integer; scorer uuid; nonparticipant uuid; participants jsonb;
  request uuid:=gen_random_uuid(); response jsonb; prior_response jsonb; revision integer; old_settlement bigint;
  before_history jsonb; before_clock jsonb; before_events jsonb; before_roster jsonb; before_booking jsonb; public_state jsonb;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(actor,'Early rating admin','+15555580001','admin',true);
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,login||'@early-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
  update public.referee_profiles set auth_user_id=login,email=login||'@early-staff.example.test' where profile_id=actor;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable early-rating financial policy.',now(),actor
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(actor,true,'Disposable early-rating verification only.');
  for i in 1..4 loop players:=array_append(players,pg_temp.early_player()); end loop;

  -- A pre-existing unranked result retains its old rule during a later replay.
  historical:=pg_temp.early_game(actor,players);
  perform public.referee_season_zero_action(actor,historical,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=historical;
  perform public.admin_resolve_season_zero_match(actor,historical,gen_random_uuid(),1,
    '{"status":"unranked","winner":null,"reason":"Historical early finish remains explicitly unranked."}');
  select to_jsonb(s),a.settlement_id into before_history,old_settlement from fieldrush_rating_private.season_zero_matches s
    join fieldrush_rating_private.season_zero_active_settlements a using(game_id) where s.game_id=historical;
  perform pg_temp.early_expect(before_history->>'completion_rules_version'='s0-full-duration-v1','historical rule remains the default');

  game:=pg_temp.early_game(actor,players);
  select profile_id into nonparticipant from public.open_queue_bookings where game_id=game and role='DEF' order by profile_id limit 1;
  -- Arrival now also means participation. The intentionally absent fixture must
  -- actually be absent, rather than checked in and omitted from the lineup.
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null,
    check_in_timing=null,outcome=null,finalized_at=null
    where open_queue_game_id=game and profile_id=nonparticipant;
  select jsonb_agg(profile_id) into participants from public.open_queue_bookings where game_id=game and profile_id<>nonparticipant;
  perform public.referee_season_zero_action(actor,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',participants));
  select profile_id into scorer from public.open_queue_bookings where game_id=game and team='WHITE' and profile_id<>nonparticipant limit 1;
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=game;
  insert into public.open_queue_goals(game_id,team,profile_id,minute) values(game,'WHITE',scorer,2);
  response:=public.referee_finish_season_zero_match(actor,game,request,1);
  perform pg_temp.early_expect(response->>'settlement_status'='RATED' and response->>'rating_status'='completed'
    and response->>'played_seconds'='129' and response->>'completion_rules_version'='s0-referee-ended-v1','actual 129-second referee finish is rated');
  perform pg_temp.early_expect((select count(*)=3 and bool_and(rating_change<>0) from public.player_rating_events
    where source_type='OPEN_QUEUE' and source_id=game and counted_as_played),'all three actual players receive nonzero normal SR and appearance credit');
  perform pg_temp.early_expect((select not counted_as_played and rating_change=0 from public.player_rating_events
    where source_type='OPEN_QUEUE' and source_id=game and profile_id=nonparticipant),'booked nonparticipant receives no SR or appearance credit');
  public_state:=fieldrush_rating_private.public_player_match_rating_state(game,scorer,public.fieldrush_rating_track((select role from public.open_queue_bookings where game_id=game and profile_id=scorer)));
  perform pg_temp.early_expect(public_state->>'counted_as_played'='true' and public_state->>'actual_played_seconds'='129'
    and position('full recorded playing duration' in public_state->>'rating_explanation')>0,'public explanation describes actual short-game eligibility');
  perform pg_temp.early_expect(public.referee_finish_season_zero_match(actor,game,request,999)=response,'finish retry returns its original receipt');
  perform pg_temp.early_expect((select count(*)=4 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=game),'finish retry creates no duplicate award');
  perform pg_temp.early_expect((select to_jsonb(s)=before_history from fieldrush_rating_private.season_zero_matches s where game_id=historical)
    and (select settlement_id=old_settlement from fieldrush_rating_private.season_zero_active_settlements where game_id=historical)
    and not exists(select 1 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=historical),'unrelated replay does not rewrite or rate historical unranked match');

  -- Explicit organizer correction can opt the requested historical result into
  -- the new rule. The real clock, score, roster and financial records survive.
  select to_jsonb(c) into before_clock from public.open_queue_clock_states c where game_id=historical;
  select s.events,s.observed_roster,s.revision into before_events,before_roster,revision from fieldrush_rating_private.season_zero_matches s where s.game_id=historical;
  select jsonb_agg(to_jsonb(b)-array['rating_change','updated_at'] order by id) into before_booking from public.open_queue_bookings b where game_id=historical;
  perform pg_temp.early_reject(format('select public.admin_resolve_season_zero_match(%L,%L,%L,%s,%L::jsonb)',actor,historical,gen_random_uuid(),revision,
    '{"status":"completed","winner":null,"reason":"Refuse automatic historical policy conversion."}'),'A shortened session is not a normally completed match');
  perform pg_temp.early_reject(format('select public.admin_resolve_season_zero_match(%L,%L,%L,%s,%L::jsonb)',actor,historical,gen_random_uuid(),revision,
    '{"status":"completed","winner":null,"reason":"Reject unknown policy version selection.","completion_rules_version":"unknown"}'),'Completion rule opt-in');
  perform pg_temp.early_reject(format('select public.admin_resolve_season_zero_match(%L,%L,%L,%s,%L::jsonb)',actor,historical,gen_random_uuid(),revision,
    '{"status":"no_contest","winner":null,"reason":"Reject policy selection for excluded result.","completion_rules_version":"s0-referee-ended-v1"}'),'Completion rule opt-in');
  perform pg_temp.early_reject(format('select public.admin_resolve_season_zero_match(%L,%L,%L,%s,%L::jsonb)',actor,historical,gen_random_uuid(),revision,
    '{"status":"completed","winner":null,"played_seconds":0,"reason":"Reject policy selection with no playing time.","completion_rules_version":"s0-referee-ended-v1"}'),'Completion rule opt-in');
  request:=gen_random_uuid();
  response:=public.admin_resolve_season_zero_match(actor,historical,request,revision,
    '{"status":"completed","winner":null,"reason":"Explicitly rate the verified historical early result.","completion_rules_version":"s0-referee-ended-v1"}');
  prior_response:=public.admin_resolve_season_zero_match(actor,historical,request,revision,
    '{"status":"completed","winner":null,"reason":"Explicitly rate the verified historical early result.","completion_rules_version":"s0-referee-ended-v1"}');
  perform pg_temp.early_expect(response=prior_response and response->>'settlement_status'='RATED','explicit historical correction is rated and idempotent');
  perform pg_temp.early_expect((select events=before_events and observed_roster=before_roster and played_seconds=129 and scheduled_seconds=3600
    from fieldrush_rating_private.season_zero_matches where game_id=historical),'audited opt-in retains actual timeline, roster and duration');
  perform pg_temp.early_expect((select to_jsonb(c)=before_clock from public.open_queue_clock_states c where game_id=historical),'audited opt-in leaves ended clock unchanged');
  perform pg_temp.early_expect((select jsonb_agg(to_jsonb(b)-array['rating_change','updated_at'] order by id)=before_booking
    from public.open_queue_bookings b where game_id=historical),'audited opt-in preserves booking finances and attendance-related fields');
  perform pg_temp.early_expect((select count(*)=1 from fieldrush_rating_private.season_zero_match_revisions
    where game_id=historical and action='ADJUDICATE_OR_CORRECT' and evidence#>>'{after,completion_rules_version}'='s0-referee-ended-v1'),
    'historical opt-in records exactly one organizer revision');
  perform pg_temp.early_expect((select count(*)=4 and bool_and(counted_as_played) from public.player_rating_events
    where source_type='OPEN_QUEUE' and source_id=historical),'historical opt-in awards exactly one appearance per actual participant');
end $$;

select pg_temp.early_expect(not has_function_privilege('authenticated',
  'fieldrush_rating_private.calculate_season_zero_sr_referee_ended_standard(jsonb)','EXECUTE')
  and not has_function_privilege('service_role',
  'fieldrush_rating_private.normalize_season_zero_sr_referee_ended_configurable(jsonb)','EXECUTE'),
  'new calculators and normalizers remain private');
select count(*) as passed_checks from early_rating_checks;
