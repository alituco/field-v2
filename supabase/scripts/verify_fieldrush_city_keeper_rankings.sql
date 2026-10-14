-- Run against a disposable/local database with the complete migration chain.
-- All profiles, cities, fixtures, ratings and settings created here roll back.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);

create function pg_temp.expect(condition boolean,message text) returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'City/keeper verification: %',message; end if; end;
$$;
create function pg_temp.played_game(player uuid,opponent uuid,city text,played_at timestamptz,role text default 'GK')
returns uuid language plpgsql as $$
declare game uuid; player_sr integer; opponent_sr integer;
begin
  select skill_rating into player_sr from public.fieldrush_player_rating_tracks
    where profile_id=player and rating_track=public.fieldrush_rating_track(role);
  select skill_rating into opponent_sr from public.fieldrush_player_rating_tracks
    where profile_id=opponent and rating_track='OUTFIELD';
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,white_score,black_score,market_city_id)
  values('FINAL','Isolated city/keeper verification',played_at,played_at+interval '1 hour',0,3,0,city) returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,team,status,played,player_rating_at_booking,rating_at_team_assignment,rating_at_match_start,amount_paid_fils,base_amount_fils,payment_method)
  values(game,player,role,'WHITE','CONFIRMED',true,player_sr,player_sr,player_sr,0,0,'FREE'),
    (game,opponent,'ATT','BLACK','CONFIRMED',true,opponent_sr,opponent_sr,opponent_sr,0,0,'FREE');
  perform public.apply_open_queue_player_ratings(game);
  return game;
end;
$$;

create function pg_temp.started_game(keeper uuid,admin_id uuid) returns uuid language plpgsql as $$
declare game uuid; player uuid; players uuid[]:=array[keeper]; i integer; role text; started public.open_queue_games;
begin
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
  values('FULL','Real referee kickoff regression',date_trunc('minute',clock_timestamp())+interval '1 hour',
    date_trunc('minute',clock_timestamp())+interval '2 hours',0) returning id into game;
  for i in 1..14 loop
    if i=1 then player:=keeper; else
      player:=gen_random_uuid(); players:=array_append(players,player);
      insert into auth.users(id,phone,phone_confirmed_at) values(player,'15559991'||lpad(i::text,3,'0'),now());
      insert into public.profiles(id,auth_user_id,display_name) values(player,player,'Lineup player '||i)
        on conflict(id) do nothing;
      insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) values(player,'active',now())
        on conflict(user_id) do update set status='active',onboarding_completed_at=now();
    end if;
    role:=case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end;
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
    values(game,player,role,'CONFIRMED',0,0,'FREE');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',check_in_timing='EARLY' where open_queue_game_id=game;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason)
    values(admin_id,'OPEN_QUEUE_TEAMS_ASSIGNED_EARLY','SOLO_MATCH',game,'Isolated audited kickoff regression.');
  perform set_config('field.force_open_queue_team_assignment',game::text,true);
  started:=public.referee_start_open_queue_game(game,players,3600);
  perform pg_temp.expect(started.status='LIVE','actual referee start succeeds with a full balanced lineup');
  return game;
end;
$$;

do $$
declare me uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); booker uuid:=gen_random_uuid();
  g1 uuid; g2 uuid; g3 uuid; g4 uuid; g5 uuid; g6 uuid; old_game uuid; next_season uuid;
  case_id uuid; revision_id uuid; before_sr integer; after_sr integer; payload jsonb; rejected boolean;
  ny_field uuid; ny_game uuid; schedule_to_check uuid; city jsonb; match_start timestamptz:=date_trunc('day',now())+interval '40 days 18 hours';
  season_start date; season_end date; snapshot_before jsonb; free_game uuid; free_booking uuid; live_game uuid;
  attendance_id uuid; appeal_id uuid; adjustment_id uuid; penalty_before integer; penalty_after integer;
  schedule_day date:=(now() at time zone 'America/New_York')::date+4; scheduled_game uuid;
  placed_keeper_game uuid; restricted_game uuid; keeper_division integer; lineup_opponent uuid;
begin
  season_start:=(match_start at time zone 'UTC')::date;
  season_end:=season_start+20;
  insert into auth.users(id,phone,phone_confirmed_at) values(me,'15559990002',now()),(other,'15559990003',now()),(admin_id,'15559990001',now());
  insert into public.profiles(id,auth_user_id,display_name,username) values(me,me,'Keeper Alpha','keeper_alpha'),(other,other,'Outfield Beta','outfield_beta'),(admin_id,admin_id,'City Admin','city_admin')
    on conflict(id) do update set display_name=excluded.display_name,username=excluded.username;
  insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) values(me,'active',now()),(other,'active',now()),(admin_id,'active',now())
    on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values(admin_id,'City Admin','+15559990001','admin',true);
  perform pg_temp.expect((select count(*)=6 from public.fieldrush_player_rating_tracks where profile_id in(me,other,admin_id)), 'two tracks created per profile');
  perform pg_temp.expect((select bool_and(skill_rating=1200 and matches_played=0) from public.fieldrush_player_rating_tracks where profile_id in(me,other)), 'both tracks start fresh');
  payload:=public.search_fieldrush_players('@keeper_alpha');
  perform pg_temp.expect(jsonb_array_length(payload)=1 and payload#>>'{0,id}'=me::text,'search finds a literal public username');
  perform pg_temp.expect(payload#>>'{0,skill_rating}' is null and payload#>>'{0,matches_played}'='0','search keeps placement SR unrevealed');
  perform pg_temp.expect(not ((payload->0) ?| array['phone','email','date_of_birth','preferred_city_id']),'search does not expose private identity or city preferences');
  perform pg_temp.expect(jsonb_array_length(public.search_fieldrush_players('Keeper Alpha'))=1,'search also finds display names');
  perform pg_temp.expect(jsonb_array_length(public.search_fieldrush_players('keeper_%'))=0,'search treats wildcard characters literally');
  perform pg_temp.expect(not has_function_privilege('anon','public.search_fieldrush_players(text)','EXECUTE'),'anonymous search denied');
  insert into auth.users(id,phone,phone_confirmed_at) values(booker,'15559990004',now());
  insert into public.profiles(id,auth_user_id,display_name) values(booker,booker,'Actual booking regression') on conflict(id) do nothing;
  insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) values(booker,'active',now()) on conflict(user_id) do update set status='active';
  city:=public.admin_save_fieldrush_city(admin_id,'new-york',jsonb_build_object('display_name','New York','state','NY','country_code','US','timezone','America/New_York','active',true));
  perform pg_temp.expect(city->>'timezone'='America/New_York','canonical city timezone');
  rejected:=false;
  begin perform public.admin_save_fieldrush_city(other,'bad-city','{"display_name":"Bad City","state":"X","country_code":"US","timezone":"UTC","active":true}');
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'non-admin city writes rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_city(admin_id,'bad-city','{"display_name":"Bad City","state":"X","country_code":"US","timezone":"Not/AZone","active":true}');
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'invalid timezone rejected');

  payload:=public.admin_save_field(admin_id,null,'{"name":"Brooklyn Test Pitch","address":"10 Test Street","city":"Brooklyn","state":"NY","country_code":"US","latitude":40.6,"longitude":-73.9,"market_city_id":"new-york","is_active":true}');
  ny_field:=(payload->>'id')::uuid;
  ny_game:=public.admin_create_open_queue_game(admin_id,ny_field,match_start+interval '30 days',13000,'18+',60,1,5);
  perform pg_temp.expect((select timezone='America/New_York' and market_city_id='new-york' and location_city='Brooklyn' from public.open_queue_games where id=ny_game),'field city distinct from market, game inherits timezone');
  rejected:=false;
  begin update public.open_queue_games set market_city_id='phoenix' where id=ny_game;
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'game city snapshot cannot be changed');
  rejected:=false;
  begin update public.open_queue_games set timezone='America/Phoenix' where id=ny_game;
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'game timezone snapshot cannot be changed');

  payload:=public.admin_save_game_schedule(admin_id,null,jsonb_build_object('name','City snapshot regression','field_id',ny_field,
    'weekdays',jsonb_build_array(1,2,3,4,5,6,7),'kickoff_time','20:30','starts_on',schedule_day,'ends_on',schedule_day,
    'duration_minutes',60,'booking_window_days',28,'price_fils',13000,'age_label','18+','is_active',true));
  schedule_to_check:=(payload->>'id')::uuid;
  select o.game_id into scheduled_game from public.game_schedule_occurrences o where o.schedule_id=schedule_to_check;
  perform pg_temp.expect(scheduled_game is not null,'real schedule writer creates its first occurrence');
  perform public.admin_save_field(admin_id,ny_field,jsonb_build_object('market_city_id','phoenix'));
  perform public.admin_save_game_schedule(admin_id,schedule_to_check,jsonb_build_object('ends_on',schedule_day+1));
  perform pg_temp.expect((select o.status='CONFLICT' and o.error_message like '%field city or timezone changed%' from public.game_schedule_occurrences o where o.schedule_id=schedule_to_check and o.match_date=schedule_day+1),'field reassignment blocks old-zone occurrence generation');
  perform pg_temp.expect((select market_city_id='new-york' and timezone='America/New_York' from public.open_queue_games where id=scheduled_game),'already created game retains its city and timezone snapshot');
  perform public.admin_save_game_schedule(admin_id,schedule_to_check,jsonb_build_object('field_id',ny_field));
  perform pg_temp.expect((select market_city_id='phoenix' and timezone='America/Phoenix' from public.game_schedules where id=schedule_to_check),'explicit selected-field save reconfirms schedule market and timezone');
  perform pg_temp.expect((select g.market_city_id='phoenix' and g.starts_at at time zone g.timezone=(schedule_day+1)+time '20:30'
    from public.game_schedule_occurrences o join public.open_queue_games g on g.id=o.game_id where o.schedule_id=schedule_to_check and o.match_date=schedule_day+1),'reconfirmed occurrence preserves chosen local kickoff');
  perform public.admin_save_fieldrush_city(admin_id,'phoenix','{"timezone":"America/Denver"}');
  perform public.admin_save_game_schedule(admin_id,schedule_to_check,jsonb_build_object('ends_on',schedule_day+2));
  perform pg_temp.expect((select o.status='CONFLICT' from public.game_schedule_occurrences o where o.schedule_id=schedule_to_check and o.match_date=schedule_day+2),'catalog timezone change cannot silently retime a recurring game');
  perform public.admin_save_fieldrush_city(admin_id,'phoenix','{"timezone":"America/Phoenix"}');
  perform public.admin_save_game_schedule(admin_id,schedule_to_check,jsonb_build_object('is_active',false));
  perform public.admin_save_field(admin_id,ny_field,jsonb_build_object('market_city_id','new-york'));
  perform pg_temp.expect(not fieldrush_private.schedule_kickoff_is_unambiguous('2026-11-01 01:30','America/New_York'),'DST repeated kickoff rejected');
  perform pg_temp.expect(not fieldrush_private.schedule_kickoff_is_unambiguous('2026-03-08 02:30','America/New_York'),'DST missing kickoff rejected');
  perform pg_temp.expect(fieldrush_private.schedule_kickoff_is_unambiguous('2026-11-01 03:30','America/New_York'),'normal post-DST kickoff accepted');

  -- Invoke the actual checkout fulfillment RPC. A helper-only test would not
  -- detect an undeclared role variable in the production booking writer.
  update public.fieldrush_player_rating_tracks set skill_rating=case when rating_track='GOALKEEPER' then 1100 else 1700 end where profile_id=booker;
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
    values('OPEN','Free checkout regression',date_trunc('minute',now())+interval '3 days',date_trunc('minute',now())+interval '3 days 1 hour',0) returning id into free_game;
  perform set_config('request.jwt.claim.sub',booker::text,true);
  perform set_config('field.match_resolution_control_plane','off',true);
  payload:=public.finalize_free_checkout(booker,'SOLO_BOOKING',jsonb_build_object('game_id',free_game,'role','GK'));
  free_booking:=(payload->>'resource_id')::uuid;
  perform pg_temp.expect((select rating_track='GOALKEEPER' and player_rating_at_booking=1100 from public.open_queue_bookings where id=free_booking),'actual booking snapshots Keeper rather than Outfield SR');
  perform pg_temp.expect((public.finalize_free_checkout(booker,'SOLO_BOOKING',jsonb_build_object('game_id',free_game,'role','GK'))->>'resource_id')::uuid=free_booking,'free checkout retry is idempotent');
  perform set_config('field.match_resolution_control_plane','on',true);
  update public.open_queue_games set status='CANCELLED',cancellation_code='ADMIN_DECISION',
    cancellation_reason='Isolated regression cancels its zero-cost booking.',cancelled_at=now() where id=free_game;
  perform set_config('field.match_resolution_control_plane','on',true);
  live_game:=pg_temp.started_game(booker,admin_id);
  perform pg_temp.expect((select rating_at_team_assignment=1100 and rating_at_match_start=1100 from public.open_queue_bookings where game_id=live_game and profile_id=booker),'real balancing and kickoff use booked Keeper SR');
  perform public.ensure_match_attendance_records('SOLO',live_game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',check_in_timing='EARLY' where open_queue_game_id=live_game;
  perform set_config('field.allow_early_open_queue_finalization',live_game::text,true);
  update public.open_queue_games set status='FINAL',white_score=3,black_score=0 where id=live_game;
  perform public.apply_open_queue_player_ratings(live_game);
  perform pg_temp.expect((select rating_before=1100 and rating_at_match_start=1100 and rating_track='GOALKEEPER' from public.player_rating_events where source_id=live_game and profile_id=booker),'actual started match rates the independent Keeper snapshot');
  perform pg_temp.expect((select skill_rating=1700 and matches_played=0 from public.fieldrush_player_rating_tracks where profile_id=booker and rating_track='OUTFIELD'),'Keeper start and finalization never change Outfield');
  select profile_id into lineup_opponent from public.open_queue_bookings where game_id=live_game and profile_id<>booker order by id limit 1;
  placed_keeper_game:=pg_temp.played_game(booker,lineup_opponent,'phoenix',date_trunc('minute',clock_timestamp())+interval '1 minute','GK');
  select public.fieldrush_division_for_rating(skill_rating) into keeper_division from public.fieldrush_player_rating_tracks where profile_id=booker and rating_track='GOALKEEPER';
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,highest_division,lowest_division)
    values('OPEN','Role-gated checkout regression',date_trunc('minute',now())+interval '6 days',date_trunc('minute',now())+interval '6 days 1 hour',0,keeper_division,keeper_division) returning id into restricted_game;
  perform set_config('field.match_resolution_control_plane','off',true);
  payload:=public.preview_open_queue_booking_cost(restricted_game,'GK');
  perform pg_temp.expect((payload->>'total_fils')::integer=0,'placed Keeper can quote its restricted division');
  rejected:=false;
  begin perform public.preview_open_queue_booking_cost(restricted_game,'ATT');
  exception when raise_exception then rejected:=sqlerrm like '%Placement players%'; end;
  perform pg_temp.expect(rejected,'Outfield placement is not bypassed by high Outfield SR or completed Keeper placements');
  perform set_config('field.match_resolution_control_plane','on',true);
  perform set_config('request.jwt.claim.sub','',true);

  g1:=pg_temp.played_game(me,other,'phoenix',match_start,'GK');
  payload:=public.list_fieldrush_placement_page('CITY','phoenix','GOALKEEPER',season_start,season_end);
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(payload->'players') p
    where p->>'profile_id'=me::text and p->>'matches_played'='1'),'one played Keeper game appears in placement');
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p
    where p ?| array['skill_rating','last_change','rank','phone','email','date_of_birth','preferred_city_id']),
    'placement does not expose provisional SR, rank or private identity');
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p
    where p->>'profile_id'=other::text),'zero Keeper games never borrow Outfield placement');
  payload:=public.list_fieldrush_placement_page('CITY','new-york','GOALKEEPER',season_start,season_end);
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p
    where p->>'profile_id'=me::text),'placement respects shared earned city');
  payload:=public.list_fieldrush_placement_page('GLOBAL',null,'OUTFIELD',season_start,season_end,0,1);
  perform pg_temp.expect(jsonb_array_length(payload->'players')<=1,'placement page is bounded');
  perform set_config('request.jwt.claim.sub',me::text,true);
  payload:=public.list_fieldrush_placement_page('GLOBAL',null,'GOALKEEPER',season_start,season_end);
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p
    where p->>'profile_id'=me::text),'own placement is excluded so UI can pin it once');
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.expect((select skill_rating=1213 from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER'),'GK uses existing result and three-goal margin formula');
  perform pg_temp.expect((select skill_rating=1200 and matches_played=0 from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='OUTFIELD'),'GK match leaves Outfield untouched');
  perform pg_temp.expect((select rating_track='GOALKEEPER' and market_city_id='phoenix' and counted_as_played from public.player_rating_events where source_id=g1 and profile_id=me),'position/city/attendance snapshot');
  select to_jsonb(r) into snapshot_before from public.fieldrush_player_rating_tracks r where profile_id=me and rating_track='GOALKEEPER';
  perform public.apply_open_queue_player_ratings(g1);
  perform pg_temp.expect((select to_jsonb(r)=snapshot_before from public.fieldrush_player_rating_tracks r where profile_id=me and rating_track='GOALKEEPER'),'finalization retry idempotent');
  payload:=public.get_fieldrush_player_ratings(me,season_start,season_end);
  perform pg_temp.expect(payload#>>'{ratings,GOALKEEPER,matches_played}'='1' and payload#>>'{ratings,GOALKEEPER,city_rank}' is null,'keeper independent placement');
  g2:=pg_temp.played_game(me,other,'phoenix',match_start+interval '1 day','GK');
  payload:=public.list_fieldrush_placement_page('GLOBAL',null,'GOALKEEPER',season_start,season_end);
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p
    where p->>'profile_id'=me::text),'second role game moves player out of placement');
  select skill_rating into penalty_before from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER';
  perform public.ensure_match_attendance_records('SOLO',g2);
  update public.match_attendance_records set outcome='LATE',finalized_at=now(),positive_sr_multiplier_bps=5000,negative_sr_multiplier_bps=15000
    where open_queue_game_id=g2 and profile_id=me returning id into attendance_id;
  perform public.apply_open_queue_reliability_rating_adjustments(g2);
  select skill_rating into penalty_after from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER';
  perform pg_temp.expect(penalty_after<penalty_before,'real late attendance multiplier reduces Keeper SR');
  perform pg_temp.expect((select skill_rating=1200 from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='OUTFIELD'),'late penalty cannot affect the other track');
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,skill_rating}')::integer=penalty_after,'profile shows actual attendance-adjusted Keeper SR');
  perform pg_temp.expect((public.list_fieldrush_rating_page('GLOBAL',null,'GOALKEEPER',season_start,season_end)#>>'{players,0,skill_rating}')::integer=penalty_after,'placed leaderboard shows actual attendance-adjusted Keeper SR');
  insert into public.reliability_appeals(attendance_id,appellant_profile_id,category,message,status,appeal_due_at,reviewed_by,reviewed_at,resolution_note)
    values(attendance_id,me,'OTHER','Regression: documented referee timing correction.','OVERTURNED',now()+interval '2 days',admin_id,now(),'Attendance evidence accepted.') returning id into appeal_id;
  adjustment_id:=public.apply_late_appeal_sr_correction(admin_id,appeal_id,attendance_id);
  perform pg_temp.expect(adjustment_id is not null and (select skill_rating=penalty_before from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER'),'approved late appeal restores only Keeper SR');
  perform pg_temp.expect(public.apply_late_appeal_sr_correction(admin_id,appeal_id,attendance_id)=adjustment_id,'late appeal correction retry is idempotent');
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,events,0,rating_after}')::integer=penalty_before,'per-track history includes audited appeal adjustment');
  g3:=pg_temp.played_game(me,other,'phoenix',match_start+interval '2 days','ATT');
  g4:=pg_temp.played_game(me,other,'new-york',match_start+interval '3 days','ATT');
  g5:=pg_temp.played_game(me,other,'new-york',match_start+interval '4 days','GK');
  payload:=public.get_fieldrush_player_ratings(me,season_start,season_end);
  perform pg_temp.expect(payload->>'primary_city_id'='phoenix','three Phoenix games beat two New York');
  perform pg_temp.expect(payload#>>'{ratings,OUTFIELD,matches_played}'='2' and payload#>>'{ratings,GOALKEEPER,matches_played}'='3','independent role counts');
  g6:=pg_temp.played_game(me,other,'new-york',match_start+interval '5 days','GK');
  payload:=public.get_fieldrush_player_ratings(me,season_start,season_end);
  perform pg_temp.expect(payload->>'primary_city_id'='new-york','tied game counts select last actual game city');
  perform pg_temp.expect(payload#>>'{ratings,OUTFIELD,primary_city_id}'='new-york' and payload#>>'{ratings,GOALKEEPER,primary_city_id}'='new-york','primary city shared across disciplines');
  perform pg_temp.expect((public.list_fieldrush_rating_page('CITY','phoenix','GOALKEEPER',season_start,season_end)->>'total_count')::integer=0,'player appears on only primary-city ladder');
  perform pg_temp.expect((public.list_fieldrush_rating_page('GLOBAL',null,'GOALKEEPER',season_start,season_end)->>'total_count')::integer=1,'global keeper ladder counts placed keeper');
  perform pg_temp.expect((public.list_fieldrush_rating_page('GLOBAL',null,'OUTFIELD',season_start,season_end)->>'total_count')::integer=2,'global Outfield ladder has both placed players');
  payload:=public.list_fieldrush_rating_page('GLOBAL',null,'OUTFIELD',season_start,season_end,0,1);
  perform pg_temp.expect(jsonb_array_length(payload->'players')=1 and (payload->>'next_offset')::integer=1,'pagination is bounded and has continuation');
  perform set_config('request.jwt.claim.sub',me::text,true);
  payload:=public.set_my_fieldrush_city('phoenix');
  perform pg_temp.expect(payload->>'preferred_city_id'='phoenix','own discovery preference can be changed');
  perform pg_temp.expect(public.get_fieldrush_player_ratings(me,season_start,season_end)->>'primary_city_id'='new-york','discovery preference cannot move earned primary city');
  perform pg_temp.expect(not exists(select 1 from public.list_open_queue_games_for_city('phoenix') game where game.id=ny_game),'city discovery excludes another market');
  perform public.admin_save_fieldrush_city(admin_id,'new-york','{"active":false}');
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(public.list_fieldrush_cities()) catalog where catalog->>'id'='new-york' and catalog->>'active'='false'),'inactive catalog city remains visible for historical ladders');
  rejected:=false;
  begin perform public.admin_save_fieldrush_city(admin_id,'phoenix','{"active":false}');
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'last active city cannot be deactivated');
  rejected:=false;
  begin perform public.set_my_fieldrush_city('new-york');
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'settings cannot select an inactive discovery city');
  perform public.admin_save_fieldrush_city(admin_id,'new-york','{"active":true}');
  perform set_config('request.jwt.claim.sub','',true);

  -- Finalization order is unrelated to played order: an older Phoenix game
  -- finalized now must not win a 3:3 recency tiebreak against New York.
  update public.player_rating_events set created_at=clock_timestamp()+interval '2 days' where source_id=g3;
  perform pg_temp.expect(public.get_fieldrush_player_ratings(me,season_start,season_end)->>'primary_city_id'='new-york','admin finalization timestamp does not determine city');
  next_season:=pg_temp.played_game(me,other,'phoenix',match_start+interval '60 days','ATT');
  perform pg_temp.expect(public.get_fieldrush_player_ratings(me,season_start,season_end)->>'primary_city_id'='new-york','other-season participation excluded');

  -- A later resolution changes membership and eligibility, but preserves the
  -- already applied SR audit per the established admin correction contract.
  select skill_rating into before_sr from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER';
  insert into public.match_resolution_cases(match_kind,open_queue_game_id,state,reason_code,scheduled_end_at,detected_at,high_priority_at)
    values('SOLO',g6,'UNDER_REVIEW','DISPUTED',match_start+interval '5 days 1 hour',now(),now()) returning id into case_id;
  insert into public.match_resolution_revisions(case_id,revision,resolution_type,reason,created_by)
    values(case_id,1,'ADMINISTRATIVE_VOID','Isolated correction verification.',admin_id) returning id into revision_id;
  perform pg_temp.expect(public.get_fieldrush_player_ratings(me,season_start,season_end)->>'primary_city_id'='phoenix','void no longer counts toward primary city');
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,matches_played}')::integer=3,'void excluded from played counts');
  perform pg_temp.expect((select skill_rating=before_sr from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER'),'void keeps established applied-SR semantics');
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,skill_rating}')::integer=before_sr,'profile displays canonical SR even when newest match is void');
  perform pg_temp.expect((public.list_fieldrush_rating_page('GLOBAL',null,'GOALKEEPER',season_start,season_end)#>>'{players,0,skill_rating}')::integer=before_sr,'leaderboard uses canonical SR independently from played count');
  perform public.ensure_match_attendance_records('SOLO',g5);
  update public.match_attendance_records set outcome='NO_SHOW',finalized_at=now() where open_queue_game_id=g5 and profile_id=me;
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,matches_played}')::integer=2,'audited no-show correction never qualifies a played match');
  perform pg_temp.expect((public.get_fieldrush_player_ratings(me,season_start,season_end)#>>'{ratings,GOALKEEPER,skill_rating}')::integer=before_sr,'no-show correction does not hide preserved canonical SR');

  -- Correct the actual solo result through the same RPC used by the admin UI.
  perform public.admin_override_match_score(admin_id,'SOLO',g1,0,3,'Regression: correct the recorded winning side.');
  perform pg_temp.expect((select result='LOSS' from public.player_rating_events where source_id=g1 and profile_id=me),'score correction updates the role event');
  perform pg_temp.expect((select wins=3 and losses=1 from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER'),'score correction updates Keeper W/L counters');
  perform pg_temp.expect((select wins=3 and losses=0 from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='OUTFIELD'),'Keeper correction leaves Outfield counters alone');
  perform pg_temp.expect((select skill_rating=before_sr from public.fieldrush_player_rating_tracks where profile_id=me and rating_track='GOALKEEPER'),'score correction preserves applied Keeper SR');
  perform set_config('field.match_resolution_control_plane','on',true);

  payload:=public.get_fieldrush_player_ratings(me,date '2027-04-01',date '2027-06-30');
  perform pg_temp.expect(payload->>'primary_city_id' is null and payload#>>'{ratings,GOALKEEPER,city_rank}' is null
    and payload#>>'{ratings,GOALKEEPER,matches_played}'='0','new season has no primary city, rank or qualifying games');
  perform pg_temp.expect((payload#>>'{ratings,GOALKEEPER,skill_rating}')::integer=before_sr,'new season retains global track SR');
  perform pg_temp.expect((select starts_on=date '2027-01-01' and ends_on=date '2027-03-31' from fieldrush_rating_private.current_season_bounds('2027-02-02')),'current-season gate follows quarterly rollover');

  rejected:=false;
  begin update public.player_rating_events set rating_track='OUTFIELD' where source_id=g1 and profile_id=me;
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'official rated role snapshot immutable');
  perform pg_temp.expect(not has_table_privilege('anon','public.fieldrush_player_rating_tracks','SELECT')
    and not has_table_privilege('authenticated','public.fieldrush_player_rating_tracks','UPDATE'),'track table private and cannot be self-rated');
  perform pg_temp.expect(not has_function_privilege('anon','public.get_fieldrush_player_ratings(uuid,date,date)','EXECUTE'),'anonymous ranking reads denied');
  perform pg_temp.expect(not has_function_privilege('anon','public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)','EXECUTE'),'anonymous placement reads denied');
  perform set_config('request.jwt.claim.role','',true);
  rejected:=false;
  begin perform public.list_fieldrush_placement_page('GLOBAL',null,'OUTFIELD',season_start,season_end);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'placement requires an authenticated session');
  rejected:=false;
  begin perform public.get_fieldrush_player_ratings(me,season_start,season_end);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'missing session denied even in security-definer RPC');
  perform set_config('request.jwt.claim.role','service_role',true);

  -- Reset blocks historical game finalization from leaking into the fresh era.
  perform public.reset_player_rankings(gen_random_uuid(),'Isolated verification of independent rating reset.');
  perform pg_temp.expect((select bool_and(skill_rating=1200 and matches_played=0) from public.fieldrush_player_rating_tracks where profile_id=me),'reset clears both ladders');
  perform pg_temp.expect(public.apply_open_queue_player_ratings(g1)=0,'old rated game cannot pollute new era');
  perform pg_temp.expect((select count(*)=2 from public.player_rating_events where source_id=g1),'old rating audit preserved');
end;
$$;
rollback;
