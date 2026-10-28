-- Rollback-only full-schema regression: unresolved bookings, actual kickoff,
-- normal referee actions, and placement admission. No hosted/provider calls.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table registration_checks(label text);
create sequence pg_temp.registration_person;
create function pg_temp.reg_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Registration recovery: %',label; end if;
insert into registration_checks values(label); end $$;
create function pg_temp.reg_reject(statement text,expected text,label text) returns void language plpgsql as $$
declare rejected boolean:=false; begin
begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true;
end;
perform pg_temp.reg_expect(rejected,label);
end $$;
create function pg_temp.reg_player() returns uuid language plpgsql as $$
declare p uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.registration_person');
  prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
insert into auth.users(id,phone,phone_confirmed_at) values(p,'1555261'||lpad(n::text,4,'0'),now());
perform set_config('request.jwt.claim.sub',p::text,true);
perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Registration','last_name','Test',
  'username','reg_rules_'||n,'date_of_birth','2000-01-01','email','reg_rules_'||n||'@example.test',
  'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
return p;
end $$;
create function pg_temp.reg_game(actor uuid,players uuid[],kickoff timestamptz,season_zero boolean)
returns uuid language plpgsql as $$
declare game uuid; i integer;
begin
insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,minimum_players,participation_rules_version)
values('Disposable registration regression',kickoff,kickoff+interval '1 hour',0,2,'s0-configurable-v1') returning id into game;
for i in 1..cardinality(players) loop
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
  values(game,players[i],case when i<=2 then 'GK' else 'DEF' end,'CONFIRMED',0,0,'FREE','PAID');
end loop;
perform public.ensure_match_attendance_records('SOLO',game);
update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=actor,
  check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=game;
insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,actor,actor);
if season_zero then
  perform public.referee_assign_season_zero_teams(actor,game,gen_random_uuid());
else
  for i in 1..cardinality(players) loop
    update public.open_queue_bookings set team=case when i%2=1 then 'WHITE' else 'BLACK' end
    where game_id=game and profile_id=players[i];
  end loop;
  update public.open_queue_games set teams_assigned_at=clock_timestamp() where id=game;
end if;
return game;
end $$;

do $$
declare actor uuid:=pg_temp.reg_player(); login uuid:=gen_random_uuid(); players uuid[]:=array[]::uuid[];
  legacy uuid; current_game uuid; next_game uuid; restricted uuid; lower_game uuid; placement uuid;
  i integer; revision integer; kickoff timestamptz; quote jsonb; booking_id uuid; booked public.open_queue_bookings%rowtype;
  before_state jsonb; before_ratings jsonb;
begin
perform pg_temp.reg_expect(not public.player_game_blocks_registration('LIVE',now()-interval '1 second','NORMAL'),
  'expired live deadline releases registration');
perform pg_temp.reg_expect(not public.player_game_blocks_registration('LIVE',now()+interval '1 day','UNDER_REVIEW'),
  'review immediately releases live registration');
perform pg_temp.reg_expect(not public.player_game_blocks_registration('FULL',now()+interval '1 day','UNDER_REVIEW'),
  'review immediately releases pregame registration');
perform pg_temp.reg_expect(not public.player_game_blocks_registration('LIVE',now()+interval '1 day','NO_DATA'),
  'missing-data games do not invisibly block');
perform pg_temp.reg_expect(public.player_game_blocks_registration('LIVE',now()+interval '1 day','RESOLVED'),
  'resolved operational metadata retains ordinary active-game guard');
perform pg_temp.reg_expect(public.player_game_blocks_registration('FULL',now()+interval '1 day','NORMAL'),
  'ordinary future registration still blocks');

insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
values(actor,'Registration regression organizer','+15552619999','admin',true);
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
values(login,login||'@registration.example.test',now(),'{"fieldrush_account_type":"staff"}');
update public.referee_profiles set auth_user_id=login,email=login||'@registration.example.test' where profile_id=actor;
insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
  date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',config,
  'Disposable registration regression policy.',now(),actor from public.reliability_policy_versions order by version limit 1;
for i in 1..4 loop players:=array_append(players,pg_temp.reg_player()); end loop;

legacy:=pg_temp.reg_game(actor,players,date_trunc('minute',now())-interval '2 hours',false);
insert into public.open_queue_clock_states(game_id,status,started_at,accumulated_seconds,duration_seconds)
values(legacy,'RUNNING',now()-interval '90 minutes',0,3600);
update public.open_queue_games set status='LIVE' where id=legacy;
insert into public.open_queue_events(game_id,event_type,occurred_at)
values(legacy,'MATCH_STARTED',now()-interval '90 minutes');
perform pg_temp.reg_expect((select actual_started_at=now()-interval '90 minutes' from public.open_queue_games where id=legacy),
  'legacy kickoff event pins its observed timestamp');
perform public.assert_player_has_one_game(players[1],'SOLO',gen_random_uuid(),false);
insert into public.open_queue_events(game_id,event_type,occurred_at)
values(legacy,'MATCH_STARTED',now()-interval '10 minutes');
perform pg_temp.reg_expect((select actual_started_at=now()-interval '90 minutes' from public.open_queue_games where id=legacy),
  'later kickoff-like events cannot restart a legacy deadline');

perform public.admin_set_season_zero_policy(actor,true,'Disposable registration regression only.');
current_game:=pg_temp.reg_game(actor,players,date_trunc('minute',now())-interval '1 hour',true);
perform pg_temp.reg_expect((select actual_started_at is null from public.open_queue_games where id=current_game),
  'unstarted Season 0 match has no invented kickoff');
perform pg_temp.reg_reject(format('update public.open_queue_games set actual_started_at=clock_timestamp() where id=%L',current_game),
  'Actual kickoff must come from recorded match evidence','unverified kickoff cannot be supplied before the referee starts');
perform public.referee_season_zero_action(actor,current_game,gen_random_uuid(),0,
  jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
select actual_started_at into kickoff from public.open_queue_games where id=current_game;
perform pg_temp.reg_expect(kickoff=(select started_at from fieldrush_rating_private.season_zero_matches where game_id=current_game),
  'verified Season 0 kickoff is published unchanged');
perform pg_temp.reg_expect((select ends_at<=now() and public.player_game_registration_end_at(g)>now()
  from public.open_queue_games g where id=current_game),'delayed actual kickoff extends registration beyond scheduled finish');
perform pg_temp.reg_reject(format('select public.assert_player_has_one_game(%L,''SOLO'',%L,false)',players[1],gen_random_uuid()),
  'one upcoming or active game','actual live game still prevents a second registration');
perform pg_temp.reg_expect((select not public.player_game_blocks_registration(g.status,public.player_game_registration_end_at(g),
  g.operational_state,kickoff+interval '1 hour') from public.open_queue_games g where id=current_game),
  'registration releases exactly at actual kickoff plus advertised duration');
select s.revision into revision from fieldrush_rating_private.season_zero_matches s where s.game_id=current_game;
perform public.referee_season_zero_action(actor,current_game,gen_random_uuid(),revision,'{"action":"PAUSE"}');
select s.revision into revision from fieldrush_rating_private.season_zero_matches s where s.game_id=current_game;
perform public.referee_season_zero_action(actor,current_game,gen_random_uuid(),revision,'{"action":"RESUME"}');
perform pg_temp.reg_expect((select actual_started_at=kickoff from public.open_queue_games where id=current_game),
  'pause and resume do not replace actual kickoff');
perform pg_temp.reg_reject(format('update public.open_queue_games set actual_started_at=actual_started_at+interval ''1 minute'' where id=%L',current_game),
  'Actual kickoff is immutable','direct kickoff edits cannot extend a registration lease');
select to_jsonb(s) into before_state from fieldrush_rating_private.season_zero_matches s where game_id=current_game;
select jsonb_agg(to_jsonb(t) order by t.profile_id,t.rating_track) into before_ratings from public.fieldrush_player_rating_tracks t;
update public.open_queue_games set operational_state='UNDER_REVIEW',operational_reason_code='RESULT_MISSING',
  operational_state_updated_at=clock_timestamp() where id=current_game;
for i in 1..4 loop perform public.assert_player_has_one_game(players[i],'SOLO',gen_random_uuid(),false); end loop;
perform pg_temp.reg_expect((select status='LIVE' from public.open_queue_games where id=current_game)
  and (select to_jsonb(s)=before_state from fieldrush_rating_private.season_zero_matches s where game_id=current_game)
  and (select jsonb_agg(to_jsonb(t) order by t.profile_id,t.rating_track)=before_ratings from public.fieldrush_player_rating_tracks t)
  and not exists(select 1 from public.player_rating_events where source_id=current_game),
  'review releases all players without finalizing or changing SR evidence');

insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,highest_division,lowest_division)
values('Next regression match',date_trunc('minute',now())+interval '3 days',date_trunc('minute',now())+interval '3 days 1 hour',0,1,1)
returning id into next_game;
perform set_config('request.jwt.claim.sub',players[1]::text,true);
quote:=public.preview_open_queue_booking_cost(next_game,'GK');
perform pg_temp.reg_expect((quote->>'total_fils')::integer=0,'reviewed player can quote a new game');
booking_id:=public.book_open_queue_game_server(next_game,'GK','FREE',null);
select * into booked from public.open_queue_bookings where id=booking_id;
perform pg_temp.reg_expect(booked.game_id=next_game and booked.status='CONFIRMED',
  'reviewed player can confirm another booking through original capacity and payment guards');
perform set_config('request.jwt.claim.sub','',true);
perform pg_temp.reg_reject(format('update public.open_queue_games set operational_state=''NORMAL'',operational_reason_code=null where id=%L',current_game),
  'one upcoming or active game','reactivating review cannot bypass the new confirmed commitment');

placement:=pg_temp.reg_player();
restricted:=next_game;
insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,highest_division,lowest_division)
values('Lower division regression',date_trunc('minute',now())+interval '4 days',date_trunc('minute',now())+interval '4 days 1 hour',0,5,5)
returning id into lower_game;
update public.fieldrush_player_rating_tracks set matches_played=1,skill_rating=800 where profile_id=placement and rating_track='OUTFIELD';
update public.fieldrush_player_rating_tracks set matches_played=2,skill_rating=800 where profile_id=placement and rating_track='GOALKEEPER';
perform public.assert_open_queue_division_eligibility(placement,restricted,'DEF');
perform pg_temp.reg_expect(true,'one-appearance outfield placement enters division 1');
perform pg_temp.reg_reject(format('select public.assert_open_queue_division_eligibility(%L,%L,''GK'')',placement,restricted),
  'Your goalkeeper division is','revealed goalkeeper division remains enforced independently');
update public.fieldrush_player_rating_tracks set matches_played=2 where profile_id=placement and rating_track='OUTFIELD';
perform pg_temp.reg_reject(format('select public.assert_open_queue_division_eligibility(%L,%L,''ATT'')',placement,restricted),
  'Your outfield division is','second outfield appearance restores advertised range enforcement');
perform public.assert_open_queue_division_eligibility(placement,lower_game,'ATT');
update public.fieldrush_player_rating_tracks set matches_played=0,skill_rating=1800 where profile_id=placement and rating_track='GOALKEEPER';
perform public.assert_open_queue_division_eligibility(placement,lower_game,'GK');
perform pg_temp.reg_expect(true,'zero-appearance goalkeeper placement enters division 5 regardless of seed SR');
perform pg_temp.reg_expect(has_column_privilege('authenticated','public.open_queue_games','actual_started_at','SELECT')
  and not has_function_privilege('authenticated','public.player_game_registration_end_at(public.open_queue_games)','EXECUTE')
  and not has_function_privilege('authenticated','public.assert_open_queue_division_eligibility_before_staging_bots(uuid,uuid,text)','EXECUTE'),
  'only public kickoff metadata is readable; private guard implementations stay non-callable');
end $$;
select count(*) as passed_checks from registration_checks;
