-- Rollback-only full application schema regression. Synthetic people, scores,
-- wallet transactions and clock progression only; no provider/network calls.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table reopen_checks(label text);
create function pg_temp.reopen_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Referee reopen: %',label; end if;
  insert into reopen_checks values(label);
end;
$$;
create function pg_temp.reopen_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.reopen_expect(rejected,'rejected: '||expected);
end;
$$;
create sequence pg_temp.reopen_person;
create sequence pg_temp.reopen_game_number;
create function pg_temp.reopen_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.reopen_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555557'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Reopen','last_name','Player',
    'username','reopen_'||n,'date_of_birth','2000-01-01','email','reopen_'||n||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;
-- One fixed transaction anchor keeps sequence-offset fixture kickoffs unique.
create function pg_temp.reopen_game(admin_id uuid,referee_id uuid,players uuid[],paid boolean default false) returns uuid language plpgsql as $$
declare game uuid; i integer; kickoff timestamptz:=date_trunc('minute',transaction_timestamp())-make_interval(mins=>nextval('pg_temp.reopen_game_number')::integer);
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable referee reopen',kickoff,kickoff+interval '1 hour',case when paid then 10000 else 0 end,4,8) returning id into game;
  for i in 1..cardinality(players) loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
      values(game,players[i],case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',
        case when paid then 10000 else 0 end,case when paid then 10000 else 0 end,case when paid then 'MOCK' else 'FREE' end,'PAID');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=referee_id,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=game;
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,referee_id,admin_id);
  perform public.referee_assign_season_zero_teams(referee_id,game,gen_random_uuid());
  return game;
end;
$$;

create function pg_temp.reopen_snapshot(game uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'game',(select to_jsonb(g) from public.open_queue_games g where id=game),
    'match',(select to_jsonb(m) from fieldrush_rating_private.season_zero_matches m where game_id=game),
    'clock',(select to_jsonb(c) from public.open_queue_clock_states c where game_id=game),
    'bookings',(select jsonb_agg(to_jsonb(b) order by id) from public.open_queue_bookings b where game_id=game),
    'requests',(select jsonb_agg(to_jsonb(r) order by request_id) from fieldrush_rating_private.season_zero_action_requests r where game_id=game),
    'audit',(select jsonb_agg(to_jsonb(r) order by revision) from fieldrush_rating_private.season_zero_match_revisions r where game_id=game),
    'settlements',(select jsonb_agg(to_jsonb(r) order by id) from fieldrush_rating_private.season_zero_settlement_revisions r),
    'ratings',(select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) from public.fieldrush_player_rating_tracks t),
    'awards',(select jsonb_agg(to_jsonb(e) order by id) from public.player_rating_events e));
$$;

-- Historical synthetic match facts are inserted once, just as an already-live
-- match would be loaded. No immutable timestamp or built-in clock is modified.
create function pg_temp.record_game(admin_id uuid,referee_id uuid,players uuid[],absent_player uuid default null)
returns uuid language plpgsql as $$
declare game uuid; i integer; started timestamptz:=clock_timestamp()-interval '1 hour'; roster jsonb;
 n integer:=nextval('pg_temp.reopen_game_number');
 kickoff timestamptz:=date_trunc('minute',transaction_timestamp()-interval '1 hour')-make_interval(mins=>n);
begin
 -- Keep planned slots unique without tying the actual starts used for SR replay.
 insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
 values('Disposable record correction '||n,kickoff,kickoff+interval '1 hour',0,4,8) returning id into game;
 for i in 1..cardinality(players) loop
   insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
   values(game,players[i],case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE','PAID');
 end loop;
 perform public.ensure_match_attendance_records('SOLO',game);
 update public.match_attendance_records set checked_in_at=case when profile_id=absent_player then null else check_in_deadline_at-interval '1 minute' end,
   checked_in_by=referee_id,check_in_timing=case when profile_id=absent_player then null else 'EARLY' end where open_queue_game_id=game;
 insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,referee_id,admin_id);
 perform public.referee_assign_season_zero_teams(referee_id,game,gen_random_uuid());
 select jsonb_agg(jsonb_build_object('id',b.profile_id,'booking_id',b.id,'team',case b.team when 'WHITE' then 'A' else 'B' end,
 'rating_track',r.rating_track,'booked_role',b.role,'sr_before',r.skill_rating,'games_before',r.matches_played,
 'initial_active',b.profile_id is distinct from absent_player) order by b.profile_id) into roster
 from public.open_queue_bookings b join public.fieldrush_player_rating_tracks r on r.profile_id=b.profile_id and r.rating_track=public.fieldrush_rating_track(b.role) where b.game_id=game;
 insert into fieldrush_rating_private.season_zero_matches(game_id,started_at,scheduled_seconds,observed_roster,played_seconds)
 values(game,started,3600,roster,3600);
 update public.open_queue_bookings set played=profile_id is distinct from absent_player where game_id=game;
 insert into public.open_queue_clock_states(game_id,status,started_at,accumulated_seconds,duration_seconds)
 values(game,'RUNNING',clock_timestamp(),3600,3600);
 update public.open_queue_games set status='LIVE' where id=game;
 return game;
end $$;


create function pg_temp.record_snapshot(game uuid) returns jsonb language sql as $$
 select jsonb_build_object('match',pg_temp.reopen_snapshot(game),
 'attendance',(select jsonb_agg(to_jsonb(a) order by id) from public.match_attendance_records a),
 'incidents',(select jsonb_agg(to_jsonb(a) order by id) from public.reliability_incidents a),
 'sanctions',(select jsonb_agg(to_jsonb(a) order by id) from public.reliability_sanctions a),
 'notifications',(select jsonb_agg(to_jsonb(a) order by id) from public.notifications a),
 'referrals',(select jsonb_agg(to_jsonb(a) order by referred_profile_id) from fieldrush_referral_private.links a));
$$;

create temporary table record_test_context(admin_id uuid,referee_id uuid,outsider uuid,players uuid[]);
do $$
declare players uuid[]:=array[]::uuid[]; admin_id uuid:=pg_temp.reopen_player(); referee_id uuid:=pg_temp.reopen_player(); outsider uuid:=pg_temp.reopen_player();
 staff uuid; login uuid; i integer; game uuid; absent uuid; original_roster jsonb; result jsonb; preview jsonb; before jsonb;
 input jsonb; request uuid; kickoff timestamptz; later uuid; final_revision integer; snapshot jsonb; updated jsonb; moderation_id uuid;
begin
 insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
 (admin_id,'Record admin','+15555571001','admin',true),(referee_id,'Record referee','+15555571002','referee',true);
 foreach staff in array array[admin_id,referee_id] loop
   login:=gen_random_uuid();
   insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values(login,login||'@record-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
   update public.referee_profiles set auth_user_id=login,email=login||'@record-staff.example.test' where profile_id=staff;
 end loop;
 insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
 select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
 date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',config,
 'Disposable unchanged correction policy.',now(),admin_id from public.reliability_policy_versions order by version limit 1;
 perform public.admin_set_season_zero_policy(admin_id,true,'Disposable referee match record verification.');
 for i in 1..14 loop players:=array_append(players,pg_temp.reopen_player()); end loop;
 insert into record_test_context values(admin_id,referee_id,outsider,players);
 absent:=players[14];
 game:=pg_temp.record_game(admin_id,referee_id,players,absent);
 perform public.referee_mutate_solo_goal(referee_id,game,gen_random_uuid(),jsonb_build_object('action','ADD','team','WHITE',
   'profile_id',(select profile_id from public.open_queue_bookings where game_id=game and team='WHITE' and profile_id<>absent limit 1)));
 select started_at,observed_roster into kickoff,original_roster from fieldrush_rating_private.season_zero_matches where game_id=game;
 input:=jsonb_build_object('reason','The player arrived thirty minutes after kickoff.',
   'arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at',kickoff+interval '30 minutes')));
 request:=gen_random_uuid();
 before:=pg_temp.record_snapshot(game);
 preview:=public.referee_save_solo_match_record(referee_id,game,request,1,input,true);
 perform pg_temp.reopen_expect(pg_temp.record_snapshot(game)=before,'preview does not persist match, clock, ratings, receipts or audit');
 perform pg_temp.reopen_expect(preview->>'preview'='true' and char_length(preview->>'preview_token')=64,'preview binds canonical facts');
 result:=public.referee_save_solo_match_record(referee_id,game,request,1,preview->'record_input',false,preview->>'preview_token');
 perform pg_temp.reopen_expect((result->'state'->'audit'->'players'->absent::text->>'actual_seconds')::integer between 1800 and 1802,'thirty-minute arrival joins automatically without ten-minute cutoff');
 perform pg_temp.reopen_expect((select checked_in_at=kickoff+interval '30 minutes' and finalized_at is null from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'late arrival remains provisional during play');
 perform pg_temp.reopen_expect((select observed_roster=original_roster from fieldrush_rating_private.season_zero_matches where game_id=game),'original kickoff roster remains immutable');
 perform pg_temp.reopen_expect(result=public.referee_save_solo_match_record(referee_id,game,request,999,preview->'record_input',false,preview->>'preview_token'),'retry returns exact response once');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',outsider,game,gen_random_uuid(),input),'not assigned');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,1,%L::jsonb)',referee_id,game,gen_random_uuid(),input),'match changed');
 perform pg_temp.reopen_reject(format('select public.referee_season_zero_action(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),jsonb_build_object('action','JOIN','profile_id',absent)),'Record the player arrival');
 result:=public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),2);
 perform pg_temp.reopen_expect(result->>'settlement_status'='RATED','late entrant game still rates');
 perform pg_temp.reopen_expect((select outcome='LATE' and strike_delta=1 from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'full time records one late strike');
 -- Create a later rated match to exercise chronological correction replay.
 later:=pg_temp.record_game(admin_id,referee_id,players);
 perform public.referee_finish_season_zero_match(referee_id,later,gen_random_uuid(),1);
 input:=jsonb_build_object('reason','The player was actually here before the deadline; the original entry was incorrect.',
   'arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at',(select check_in_deadline_at-interval '1 minute' from public.match_attendance_records where open_queue_game_id=game and profile_id=absent))));
 request:=gen_random_uuid();
 before:=pg_temp.record_snapshot(game);
 preview:=public.referee_save_solo_match_record(referee_id,game,request,3,input,true);
 perform pg_temp.reopen_expect(pg_temp.record_snapshot(game)=before,'finished preview rolls back dependent SR and attendance');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,3,%L::jsonb)',referee_id,game,request,input),'Review the current correction preview');
 result:=public.referee_save_solo_match_record(referee_id,game,request,3,preview->'record_input',false,preview->>'preview_token');
 perform pg_temp.reopen_expect(result->'state'->>'lifecycle'='FINAL' and (select status='FINAL' from public.open_queue_games where id=game),'finished correction never reopens play');
 perform pg_temp.reopen_expect((select outcome='ON_TIME' and strike_delta=0 from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'earlier arrival reverses erroneous late strike');
 perform pg_temp.reopen_expect((result->'state'->'audit'->'players'->absent::text->>'actual_seconds')::integer>=3600,'corrected pregame arrival becomes starter for SR');
 perform pg_temp.reopen_expect((result->'impact'->>'dependent_matches_changed')::integer>=1,'attendance correction replays a later match using corrected SR');
 perform pg_temp.reopen_expect((select count(*)=28 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id in(game,later)),'dependent replay leaves one award per player per match');
 perform pg_temp.reopen_expect((select observed_roster=original_roster from fieldrush_rating_private.season_zero_matches where game_id=game),'correction never overwrites observed kickoff evidence');
 -- Missing player corrected after no-show adjudication, without requiring LIVE.
 game:=pg_temp.record_game(admin_id,referee_id,players,absent);
 select started_at into kickoff from fieldrush_rating_private.season_zero_matches where game_id=game;
 perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),1);
 perform pg_temp.reopen_expect((select outcome='NO_SHOW' and strike_delta=2 from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'absent player gets no-show only at full time');
 input:=jsonb_build_object('reason','The player arrived at thirty minutes but the referee missed the tap.',
   'arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at',kickoff+interval '30 minutes')));
 request:=gen_random_uuid(); preview:=public.referee_save_solo_match_record(referee_id,game,request,2,input,true);
 result:=public.referee_save_solo_match_record(referee_id,game,request,2,preview->'record_input',false,preview->>'preview_token');
 perform pg_temp.reopen_expect((select outcome='LATE' and strike_delta=1 from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'no-show two is replaced by late one');
 perform pg_temp.reopen_expect((select counted_as_played from public.player_rating_events where source_id=game and profile_id=absent),'corrected late attendance restores qualifying counted appearance');
 -- Real five-minute pause: wall arrival30m maps to playing minute25.
 game:=pg_temp.record_game(admin_id,referee_id,players,absent);
 select started_at into kickoff from fieldrush_rating_private.season_zero_matches where game_id=game;
 update fieldrush_rating_private.season_zero_matches set events=jsonb_build_array(
  jsonb_build_object('id',gen_random_uuid(),'type','PAUSE','second',1200,'player_id',null,'recorded_at',kickoff+interval '20 minutes'),
  jsonb_build_object('id',gen_random_uuid(),'type','RESUME','second',1200,'player_id',null,'recorded_at',kickoff+interval '25 minutes')),
  played_seconds=3300 where game_id=game;
 update public.open_queue_clock_states set accumulated_seconds=3300,started_at=clock_timestamp() where game_id=game;
 input:=jsonb_build_object('reason','Arrival entered after the referee finished recording the stoppage.',
 'arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at',kickoff+interval '30 minutes')));
 result:=public.referee_save_solo_match_record(referee_id,game,gen_random_uuid(),1,input);
 perform pg_temp.reopen_expect((select (e->>'second')::integer=1500 from jsonb_array_elements(result->'state'->'events') e where e->>'type'='JOIN'),'arrival time excludes pauses automatically');
 perform pg_temp.reopen_expect((result->'state'->'audit'->'players'->absent::text->>'actual_seconds')::integer between 1800 and 1802,'late entrant actual playing duration excludes pause');
 perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),2);
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,3,%L::jsonb,true)',referee_id,game,gen_random_uuid(),
  jsonb_build_object('reason','Invalid actual arrival after the final whistle.', 'arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at',clock_timestamp()+interval '1 minute')))), 'before the actual final whistle');

 -- Correcting the paused clock re-derives JOIN from the one saved wall arrival.
 input:=jsonb_build_object('reason','The five-minute pause was recorded by mistake; play continued.', 'events','[]'::jsonb,'played_seconds',3600);
 request:=gen_random_uuid();preview:=public.referee_save_solo_match_record(referee_id,game,request,3,input,true);
 result:=public.referee_save_solo_match_record(referee_id,game,request,3,preview->'record_input',false,preview->>'preview_token');
 perform pg_temp.reopen_expect((select (e->>'second')::integer=1800 from jsonb_array_elements(result->'state'->'events') e where e->>'type'='JOIN'),
   'clock correction re-derives entry without changing actual arrival');
 perform pg_temp.reopen_expect((select checked_in_at=kickoff+interval '30 minutes' from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),
   'clock correction preserves one canonical arrival timestamp');
 -- A late full-time tap can be corrected while preserving its observation.
 game:=pg_temp.record_game(admin_id,referee_id,players);
 select started_at into kickoff from fieldrush_rating_private.season_zero_matches where game_id=game;
 perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),1);
 input:=jsonb_build_object('reason','Actual play finished at fifty minutes; the final-time tap was late.','played_seconds',3000);
 request:=gen_random_uuid();preview:=public.referee_save_solo_match_record(referee_id,game,request,2,input,true);
 result:=public.referee_save_solo_match_record(referee_id,game,request,2,preview->'record_input',false,preview->>'preview_token');
 perform pg_temp.reopen_expect((select ended_at=started_at+interval '50 minutes' and observed_ended_at>ended_at and played_seconds=3000
   from fieldrush_rating_private.season_zero_matches where game_id=game),'duration correction records actual whistle and retains original observed finish');
 -- A new moderation decision invalidates a previously approved preview.
 input:=jsonb_build_object('reason','Verify the corrected whistle remained at fifty minutes.','played_seconds',3000);
 request:=gen_random_uuid();preview:=public.referee_save_solo_match_record(referee_id,game,request,3,input,true);
 insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,reason_code,user_message,issued_by)
   values('PLAYER',players[1],'WARNING','NONE','TEST_REVIEW','Synthetic moderation change.',admin_id) returning id into moderation_id;
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,3,%L::jsonb,false,%L)',referee_id,game,request,preview->'record_input',preview->>'preview_token'),
   'Review the current correction preview');
 -- Fresh arrivals stay one tap; an existing arrival needs a real correction reason.
 game:=pg_temp.record_game(admin_id,referee_id,players,absent);
 input:=jsonb_build_object('reason','','arrivals',jsonb_build_array(jsonb_build_object('profile_id',absent,'arrived_at','now')));
 insert into public.moderation_actions(subject_type,subject_profile_id,action_type,restriction_scope,reason_code,user_message,issued_by,ends_at)
   values('PLAYER',absent,'SUSPENSION','PLAY','TEST_RESTRICTION','Synthetic active play restriction.',admin_id,clock_timestamp()+interval '1 day') returning id into moderation_id;
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,1,%L::jsonb)',referee_id,game,gen_random_uuid(),input),'active playing restriction');
 perform pg_temp.reopen_expect((select checked_in_at is null from public.match_attendance_records where open_queue_game_id=game and profile_id=absent),'rejected restricted arrival leaves attendance unchanged');
 update public.moderation_actions set revoked_at=clock_timestamp(),revoked_by=admin_id,revocation_reason='Synthetic test complete.' where id=moderation_id;
 result:=public.referee_save_solo_match_record(referee_id,game,gen_random_uuid(),1,input);
 perform pg_temp.reopen_expect(result->'state'->'audit'->'players'->absent::text->>'final_state'='ACTIVE','fresh arrival now also joins with one tap');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),input),'Explain the correction');
 perform pg_temp.reopen_reject(format('select public.referee_check_in_player(%L,%L,%L,%L)',referee_id,'SOLO',game,absent),'Record arrival and entry together');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),input||'{"sr":9999}'::jsonb),'valid match record');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),
   jsonb_build_object('reason','Impossible duration longer than actual running time.','played_seconds',7200)),'Playing time must match');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),
   jsonb_build_object('reason','Live duration cannot change without real pause facts.','played_seconds',1200)),'Playing time must match');
 perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,2,%L::jsonb)',referee_id,game,gen_random_uuid(),
   jsonb_build_object('reason','Reject a departure with an inconsistent playing minute.','events',jsonb_build_array(jsonb_build_object(
     'id',gen_random_uuid(),'type','EXCUSED_LEAVE','player_id',players[1],'second',1200,
     'recorded_at',(select started_at+interval '30 minutes' from fieldrush_rating_private.season_zero_matches where game_id=game)))))
   ,'playing minute must match');
 perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),2);
 perform pg_temp.reopen_expect(not has_function_privilege('authenticated','public.referee_save_solo_match_record(uuid,uuid,uuid,integer,jsonb,boolean,text)','EXECUTE'),
   'players cannot invoke the referee record writer');
end $$;
select 'PASS: '||count(*)||' referee match record checks' from reopen_checks;

-- Goal, replay and highlight corrections use the same original-roster fixtures.
-- These exercise the public correction RPC, not a trigger or authorization bypass.
do $$
declare ctx record; players uuid[]:=array[]::uuid[]; player uuid; i integer;
  game uuid; late uuid; scorer uuid; late_team text; original jsonb; clip uuid;
  input jsonb; preview jsonb; saved jsonb; retry jsonb; request uuid; revision integer;
  before jsonb; before_goals jsonb; before_events jsonb; before_notices bigint;
  kickoff timestamptz; goals jsonb; corrected_goal uuid; original_goal uuid; early_goal uuid; corrected_duration integer;
begin
  select * into ctx from record_test_context;
  for i in 1..14 loop players:=array_append(players,pg_temp.reopen_player()); end loop;
  late:=players[14];
  game:=pg_temp.record_game(ctx.admin_id,ctx.referee_id,players,late);
  select started_at into kickoff from fieldrush_rating_private.season_zero_matches where game_id=game;
  select profile_id into scorer from public.open_queue_bookings where game_id=game and team='WHITE' and profile_id<>late limit 1;
  select team into late_team from public.open_queue_bookings where game_id=game and profile_id=late;
  original:=public.referee_mutate_solo_goal(ctx.referee_id,game,gen_random_uuid(),
    jsonb_build_object('action','ADD','team','WHITE','profile_id',scorer));
  original_goal:=(original->>'goal_id')::uuid;
  -- Old writers used transaction-start now(), which could precede the actual
  -- goal observation after a lock wait or a long transaction. Preserve those
  -- existing goals and clips when correcting attendance or other goal rows.
  update public.open_queue_events set occurred_at=occurred_at-interval '15 seconds'
    where id=(original->>'event_id')::uuid;
  insert into public.profile_highlights(profile_id,title,duration,source_type,source_match_id,source_event_id,
    video_url,download_url,download_status,processing_status,is_public)
    values(scorer,'Original credited goal','0:30','SOLO',game,(original->>'event_id')::uuid,
      'https://example.test/original.m3u8','https://example.test/original.mp4','READY','READY',true) returning id into clip;
  perform public.referee_finish_season_zero_match(ctx.referee_id,game,gen_random_uuid(),1);
  set constraints all immediate;
  set constraints all deferred;
  revision:=(public.get_season_zero_match_state(ctx.referee_id,game)->>'revision')::integer;
  before:=pg_temp.reopen_snapshot(game);
  before_goals:=fieldrush_rating_private.solo_recorded_goals(game);
  select jsonb_agg(to_jsonb(e) order by id) into before_events from public.open_queue_events e where game_id=game;
  select count(*) into before_notices from public.notifications;
  input:=jsonb_build_object('reason','Verified video shows the late arrival and a missed goal.',
    'arrivals',jsonb_build_array(jsonb_build_object('profile_id',late,'arrived_at',kickoff+interval '30 minutes')),
    'goals',before_goals||jsonb_build_array(jsonb_build_object('team',late_team,'profile_id',late,'assist_profile_id',null,'second',2700)));
  request:=gen_random_uuid();
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  perform pg_temp.reopen_expect(preview->>'preview'='true' and pg_temp.reopen_snapshot(game)=before
    and fieldrush_rating_private.solo_recorded_goals(game)=before_goals
    and (select jsonb_agg(to_jsonb(e) order by id)=before_events from public.open_queue_events e where game_id=game)
    and (select count(*)=before_notices from public.notifications),
    'goal and arrival preview leaves score, events, ratings, notices and receipts unchanged');
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect(saved#>>'{state,lifecycle}'='FINAL' and (select count(*)=2 from public.open_queue_goals where game_id=game)
    and (select outcome='LATE' and strike_delta=1 from public.match_attendance_records where open_queue_game_id=game and profile_id=late),
    'finished correction saves arrival, late strike and missed goal together without reopening');
  perform pg_temp.reopen_expect((select processing_status='READY' and is_public from public.profile_highlights where id=clip)
    and exists(select 1 from public.open_queue_goals where id=original_goal),
    'unchanged credited goal keeps its ID and saved highlight');
  retry:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect(retry=saved and (select count(*)=2 from public.open_queue_goals where game_id=game),
    'retrying a completed correction returns its receipt without adding another goal');
  revision:=(saved#>>'{state,revision}')::integer;
  select id into corrected_goal from public.open_queue_goals where game_id=game and profile_id=late;
  goals:=fieldrush_rating_private.solo_recorded_goals(game);
  input:=jsonb_build_object('reason','Verify an impossible goal before this player arrived.',
    'goals',(select jsonb_agg(case when v->>'id'=corrected_goal::text then v||'{"second":900}'::jsonb else v end)
      from jsonb_array_elements(goals) v));
  perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,%s,%L::jsonb,true)',
    ctx.referee_id,game,gen_random_uuid(),revision,input),'Scorer and assist must have been playing');
  input:=jsonb_build_object('reason','Verify a correction cannot erase the scorer arrival.',
    'arrivals',jsonb_build_array(jsonb_build_object('profile_id',late,'arrived_at',null)));
  perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,%s,%L::jsonb,true)',
    ctx.referee_id,game,gen_random_uuid(),revision,input),'Scorer and assist must have been playing');
  input:=jsonb_build_object('reason','Reject a goal ID that does not belong to this game.',
    'goals',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'team',late_team,'profile_id',late,'second',2700)));
  perform pg_temp.reopen_reject(format('select public.referee_save_solo_match_record(%L,%L,%L,%s,%L::jsonb,true)',
    ctx.referee_id,game,gen_random_uuid(),revision,input),'does not belong to this match record');
  -- Remove the original goal, leaving the genuinely scored late-player goal.
  input:=jsonb_build_object('reason','Original goal was a duplicate; retain the verified later goal.',
    'goals',(select jsonb_agg(v) from jsonb_array_elements(goals) v where v->>'id'<>original_goal::text));
  request:=gen_random_uuid();
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  perform pg_temp.reopen_expect((select processing_status='READY' and is_public from public.profile_highlights where id=clip),
    'previewing removal does not invalidate the live highlight');
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect((select processing_status='FAILED' and not is_public and video_url is null and download_url is null
      from public.profile_highlights where id=clip)
    and not fieldrush_private.is_credited_replay_goal('SOLO',game,(original->>'event_id')::uuid)
    and exists(select 1 from public.open_queue_events where game_id=game and event_type='CORRECTION' and goal_id=original_goal),
    'published removal retains audit event and revokes replay/highlight credit');
  perform pg_temp.reopen_expect((select count(*)=1 from public.open_queue_goals where game_id=game)
    and (select white_score+black_score=1 and status='FINAL' from public.open_queue_games where id=game)
    and exists(select 1 from public.open_queue_goals where id=corrected_goal),
    'corrected official score, remaining goal and final status agree');
  perform pg_temp.reopen_expect(not exists(select 1 from fieldrush_rating_private.referee_goal_correction_context),
    'private correction capability does not survive the operation');
  perform pg_temp.reopen_reject(format('delete from public.open_queue_goals where id=%L',corrected_goal),
    'Goals require an unlocked running Season 0 match');
  perform pg_temp.reopen_expect(not has_function_privilege('service_role',
    'fieldrush_rating_private.referee_correct_solo_goals(uuid,uuid,jsonb,text,boolean)','EXECUTE')
    and not has_table_privilege('service_role','fieldrush_rating_private.referee_goal_correction_context','INSERT'),
    'only the audited correction writer can use the private goal capability');
  -- Moving only the final whistle does not move an earlier goal's playing
  -- moment. Legacy wall drift must not revoke that unchanged goal's clip.
  update public.open_queue_events set occurred_at=occurred_at-interval '15 seconds'
    where game_id=game and goal_id=corrected_goal and event_type='GOAL';
  insert into public.profile_highlights(profile_id,title,duration,source_type,source_match_id,source_event_id,
    video_url,download_status,processing_status,is_public)
    select late,'Unchanged goal before corrected whistle','0:30','SOLO',game,id,
      'https://example.test/unchanged.m3u8','READY','READY',true
      from public.open_queue_events where game_id=game and goal_id=corrected_goal and event_type='GOAL'
      returning id into clip;
  revision:=(saved#>>'{state,revision}')::integer; request:=gen_random_uuid();
  input:=jsonb_build_object('reason','The actual whistle was at fifty-five minutes; retain the earlier goal.',
    'played_seconds',3300,'goals',fieldrush_rating_private.solo_recorded_goals(game));
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect(exists(select 1 from public.open_queue_goals where id=corrected_goal)
    and (select processing_status='READY' and is_public from public.profile_highlights where id=clip),
    'duration-only correction preserves unchanged legacy goal ID and clip');
  -- A valid goal can precede a pause within the same whole clock second. Its
  -- original wall observation must win over a later PAUSE at that same second.
  revision:=(saved#>>'{state,revision}')::integer;
  goals:=fieldrush_rating_private.solo_recorded_goals(game);
  input:=jsonb_build_object('reason','Verified an earlier goal before the later stoppage.',
    'goals',goals||jsonb_build_array(jsonb_build_object('team','WHITE','profile_id',scorer,'assist_profile_id',null,'second',1200)));
  request:=gen_random_uuid();
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  select id into early_goal from public.open_queue_goals where game_id=game and profile_id=scorer;
  select floor(extract(epoch from ended_at-started_at))::integer-300 into corrected_duration
    from fieldrush_rating_private.season_zero_matches where game_id=game;
  input:=jsonb_build_object('reason','Verified five-minute pause began just after the earlier goal.',
    'played_seconds',corrected_duration,'events',jsonb_build_array(
      jsonb_build_object('id',gen_random_uuid(),'type','PAUSE','second',1200,'player_id',null,
        'recorded_at',kickoff+interval '1200.75 seconds','note','Verified stoppage'),
      jsonb_build_object('id',gen_random_uuid(),'type','RESUME','second',1200,'player_id',null,
        'recorded_at',kickoff+interval '1500.75 seconds','note','Verified restart')));
  revision:=(saved#>>'{state,revision}')::integer; request:=gen_random_uuid();
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect(exists(select 1 from public.open_queue_goals where id=early_goal)
    and exists(select 1 from public.open_queue_events e where e.goal_id=early_goal
      and fieldrush_private.is_credited_replay_goal('SOLO',game,e.id)),
    'goal before same-second pause remains credited with its original ID');
  perform pg_temp.reopen_expect(exists(select 1 from fieldrush_rating_private.season_zero_matches m,
    jsonb_array_elements(m.events) e where m.game_id=game and e->>'type'='JOIN'
      and e->>'player_id'=late::text and (e->>'second')::integer between 1499 and 1500),
    'clock correction rederives late arrival playing minute without changing arrival');
  -- The browser emits Z/millisecond timestamps. Equivalent spellings of the
  -- existing clock history are not a clock correction and must keep clips.
  select id into corrected_goal from public.open_queue_goals where game_id=game and profile_id=late;
  update public.open_queue_events set occurred_at=occurred_at-interval '15 seconds'
    where game_id=game and goal_id=corrected_goal and event_type='GOAL';
  insert into public.profile_highlights(profile_id,title,duration,source_type,source_match_id,source_event_id,
    video_url,download_status,processing_status,is_public)
    select late,'Unchanged goal with browser timestamp spelling','0:30','SOLO',game,id,
      'https://example.test/spelling.m3u8','READY','READY',true
      from public.open_queue_events where game_id=game and goal_id=corrected_goal and event_type='GOAL'
      returning id into clip;
  select jsonb_build_object('reason','The browser normalizes unchanged clock timestamps to UTC milliseconds.',
    'events',jsonb_agg(jsonb_set(v,'{recorded_at}',to_jsonb(to_char(
      date_trunc('milliseconds',(v->>'recorded_at')::timestamptz) at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))) order by n)) into input
    from fieldrush_rating_private.season_zero_matches m,
      jsonb_array_elements(m.events) with ordinality item(v,n)
      where m.game_id=game and v->>'type'<>'JOIN';
  revision:=(saved#>>'{state,revision}')::integer; request:=gen_random_uuid();
  preview:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,input,true);
  saved:=public.referee_save_solo_match_record(ctx.referee_id,game,request,revision,preview->'record_input',false,preview->>'preview_token');
  perform pg_temp.reopen_expect(exists(select 1 from public.open_queue_goals where id=corrected_goal)
    and (select processing_status='READY' and is_public from public.profile_highlights where id=clip),
    'equivalent browser timestamp spelling preserves unchanged goal ID and clip');
end $$;
select count(*) as passed_match_and_goal_checks from reopen_checks;
