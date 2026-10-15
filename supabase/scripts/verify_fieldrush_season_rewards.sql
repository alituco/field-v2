-- Disposable/local database only. Real profile, match, scorer and rating rows
-- are exercised inside a transaction and all changes are rolled back.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);

create function pg_temp.expect(condition boolean,message text) returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'Season rewards verification: %',message; end if; end;
$$;
create function pg_temp.play_reward_game(player uuid,opponent uuid,played_at timestamptz,role text,scored integer,conceded integer)
returns uuid language plpgsql as $$
declare game uuid; player_sr integer; opponent_sr integer; opposite_role text:=case when role='GK' then 'ATT' else 'GK' end; i integer;
begin
  select skill_rating into player_sr from public.fieldrush_player_rating_tracks where profile_id=player and rating_track=public.fieldrush_rating_track(role);
  select skill_rating into opponent_sr from public.fieldrush_player_rating_tracks where profile_id=opponent and rating_track=public.fieldrush_rating_track(opposite_role);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,white_score,black_score,market_city_id)
  values('OPEN','Isolated season reward regression',played_at,played_at+interval '1 hour',0,scored,conceded,'phoenix') returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,team,status,played,player_rating_at_booking,rating_at_team_assignment,rating_at_match_start,amount_paid_fils,base_amount_fils,payment_method)
  values(game,player,role,'WHITE','CONFIRMED',true,player_sr,player_sr,player_sr,0,0,'FREE'),
    (game,opponent,opposite_role,'BLACK','CONFIRMED',true,opponent_sr,opponent_sr,opponent_sr,0,0,'FREE');
  insert into public.open_queue_clock_states(game_id,status,started_at) values(game,'RUNNING',played_at)
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.open_queue_games set status='LIVE' where id=game;
  -- Normal booking/team-assignment triggers may have drawn the two seed
  -- players onto different sides. Pin this isolated scorer scenario explicitly.
  update public.open_queue_bookings set team=case when profile_id=player then 'WHITE' else 'BLACK' end,played=true
    where game_id=game;
  for i in 1..scored loop
    insert into public.open_queue_goals(game_id,team,profile_id,minute) values(game,'WHITE',player,i);
  end loop;
  for i in 1..conceded loop
    insert into public.open_queue_goals(game_id,team,profile_id,minute) values(game,'BLACK',opponent,i);
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',check_in_timing='EARLY'
    where open_queue_game_id=game;
  perform set_config('field.allow_early_open_queue_finalization',game::text,true);
  update public.open_queue_games set status='FINAL' where id=game;
  perform public.apply_open_queue_player_ratings(game);
  return game;
end;
$$;

do $$
declare admin_id uuid:=gen_random_uuid(); alpha uuid:=gen_random_uuid(); beta uuid:=gen_random_uuid();
  gamma uuid:=gen_random_uuid(); delta uuid:=gen_random_uuid(); two_games uuid:=gen_random_uuid(); opponent uuid:=gen_random_uuid();
  member uuid; members uuid[]; names text[]:=array['Zulu Scorer','Alpha Clean','Beta Clean','Aaron Leaky','Placement High','Keeper Opponent','Season Admin'];
  i integer; j integer; day_one date; payload jsonb; season jsonb; reward jsonb; rejected boolean;
  season_id text:='reward-regression'; second_season text:='reward-second'; first_game uuid; goal uuid;
begin
  members:=array[alpha,beta,gamma,delta,two_games,opponent,admin_id];
  for i in 1..array_length(members,1) loop
    member:=members[i];
    insert into auth.users(id,phone,phone_confirmed_at) values(member,'15559992'||lpad(i::text,3,'0'),now());
    -- Preserve the legacy seed/history in these rollback-only reward fixtures.
    -- Prospective assessment behavior has its own initialization suite.
    delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=member;
    insert into public.profiles(id,auth_user_id,display_name,username) values(member,member,names[i],'reward_regression_'||i)
      on conflict(id) do update set display_name=excluded.display_name,username=excluded.username;
    insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) values(member,'active',now())
      on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values(admin_id,'Season Admin','+15559992007','admin',true);
  perform set_config('request.jwt.claim.sub',alpha::text,true);
  perform pg_temp.expect(not has_table_privilege('authenticated','public.fieldrush_season_rewards','SELECT'),'players cannot read unpublished drafts directly');
  perform pg_temp.expect(not has_table_privilege('service_role','public.fieldrush_season_rewards','UPDATE'),'even service-role writes use audited RPCs');
  perform pg_temp.expect(not has_table_privilege('service_role','public.fieldrush_season_audit_events','DELETE'),'audit entries cannot be deleted through service API');
  perform pg_temp.expect(not has_function_privilege('authenticated','public.admin_list_fieldrush_seasons(uuid)','EXECUTE'),'admin read RPC not executable by players');
  perform pg_temp.expect(not has_function_privilege('anon','public.list_fieldrush_seasons()','EXECUTE'),'anonymous season reads denied');
  payload:=public.list_fieldrush_seasons();
  perform pg_temp.expect(jsonb_array_length(payload->'seasons')>=2
    and not exists(select 1 from jsonb_array_elements(payload->'seasons') s where s->>'lifecycle' in ('DRAFT','SCHEDULED')),
    'public catalog includes visible started seasons and omits unstarted drafts/schedules');
  perform pg_temp.expect(payload->>'current_season_id'=(select id from public.fieldrush_seasons where (now() at time zone 'America/Phoenix')::date between starts_on and ends_on),'active season comes from catalog');

  day_one:=(select greatest(max(ends_on)+1,(now() at time zone 'America/Phoenix')::date+400) from public.fieldrush_seasons);
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(alpha,season_id,jsonb_build_object('label','Test','starts_on',day_one,'ends_on',day_one+89),0);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'non-admin cannot configure season');
  season:=public.admin_save_fieldrush_season(admin_id,season_id,jsonb_build_object('label','TEST','starts_on',day_one,'ends_on',day_one+89,'lifecycle','SCHEDULED'),0);
  perform pg_temp.expect(season->>'minimum_rated_games'='2' and season->>'revision'='1','new season defaults to two prize-qualification games');
  season:=public.admin_save_fieldrush_season(admin_id,season_id,'{"minimum_rated_games":3}',1);
  perform pg_temp.expect(season->>'revision'='2' and season->>'minimum_rated_games'='3','future season minimum configurable independently');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,season_id,'{"minimum_rated_games":4}',1);
  exception when serialization_failure then rejected:=true; end;
  perform pg_temp.expect(rejected,'stale season revision rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,second_season,jsonb_build_object('label','Overlap','starts_on',day_one+89,'ends_on',day_one+100,'lifecycle','SCHEDULED'),0);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'inclusive boundary overlapping dates rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,season_id,'{"minimum_rated_games":1}',2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'qualification cannot reveal placement players');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,season_id,'{"minimum_rated_games":2.5}',2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'fractional qualification rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,season_id,'{"label":"Injected","unexpected":true}',2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'unknown season settings rejected');
  season:=public.admin_save_fieldrush_season(admin_id,'s0','{"label":"Changed"}',1);
  perform pg_temp.expect(season->>'label'='Changed' and season->>'revision'='2','past season display names may be changed without changing ranking dates or qualification');
  perform pg_temp.expect(public.get_fieldrush_season_rewards(season_id,'phoenix','OUTFIELD') is null,'private drafts never advertised');
  payload:=public.admin_list_fieldrush_seasons(admin_id);
  perform pg_temp.expect(payload->>'today'=(now() at time zone 'America/Phoenix')::date::text,'admin date boundary supplied by database');
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(payload->'seasons') s where s->>'id'=season_id and (s->>'editable')::boolean),'draft future season editable');

  reward:=public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','OUTFIELD','{}','PUBLISH',null,1);
  perform pg_temp.expect(reward->>'status'='PUBLISHED' and reward->>'first_prize_cents'='15000' and reward->>'second_prize_cents'='10000' and reward->>'third_prize_cents'='5000','explicit publish uses full USD default prize amounts');
  payload:=public.get_fieldrush_season_rewards(season_id,'phoenix','OUTFIELD');
  perform pg_temp.expect(payload->>'minimum_rated_games'='3' and jsonb_array_length(payload->'prize_players')=0 and payload->>'total_qualified'='0','zero-ranked prize rows have zero fake winners');
  perform pg_temp.expect(public.get_fieldrush_season_rewards(season_id,null,'OUTFIELD') is null,'global does not borrow city cash prizes');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,season_id,'{"minimum_rated_games":4}',2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'published prizes lock promised qualification and dates');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','OUTFIELD','{"first_prize_cents":100}','SAVE',null,2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'published prizes cannot be silently overwritten');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','OUTFIELD','{"first_prize_cents":20000}','CORRECT','short',2);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'published correction requires meaningful reason');
  reward:=public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','OUTFIELD','{"first_prize_cents":20000}','CORRECT','Correct approved first-place cash amount.',2);
  perform pg_temp.expect(reward->>'revision'='3' and reward->>'status'='PUBLISHED','audited correction stays published and advances revision');
  perform pg_temp.expect(exists(select 1 from public.fieldrush_season_audit_events a where a.season_id='reward-regression' and a.action='REWARD_CORRECTED'
    and a.before_state->>'first_prize_cents'='15000' and a.after_state->>'first_prize_cents'='20000'
    and a.reason='Correct approved first-place cash amount.' and a.actor_admin_id=admin_id),'correction records actor, reason and full before/after amounts');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','OUTFIELD','{}','CORRECT','Concurrent stale save must fail.',2);
  exception when serialization_failure then rejected:=true; end;
  perform pg_temp.expect(rejected,'stale prize revision rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(alpha,season_id,'phoenix','GOALKEEPER','{}','PUBLISH',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'non-admin cannot publish prizes');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{"currency":"BHD"}','SAVE',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'USD cannot be changed or unknown keys accepted');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{"first_prize_cents":-1}','SAVE',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'negative prize amounts rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{"first_prize_cents":1.5}','SAVE',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'fractional cents rejected');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{"first_prize_cents":"15000"}','SAVE',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'string amounts rejected rather than coerced');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{"first_prize_cents":100000001}','SAVE',null,1);
  exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'unbounded prize amounts rejected');

  -- Individual goals trump conceded goals/name, conceded goals trump name,
  -- and name breaks the final tie. Lifetime calibration remains two games,
  -- while this season's ranking and prizes both require its configured three.
  for i in 1..5 loop
    member:=members[i];
    for j in 1..case when i=5 then 2 else 3 end loop
      goal:=pg_temp.play_reward_game(member,opponent,(day_one+i*4+j)+time '18:00','ATT',
        case when j<>1 then 0 when i=1 then 2 when i=5 then 3 else 1 end,
        case when j<>1 then 0 when i=1 then 5 when i=4 then 2 else 0 end);
      if i=1 and j=1 then first_game:=goal; end if;
    end loop;
  end loop;
  update public.fieldrush_player_rating_tracks set skill_rating=1500 where profile_id=any(members[1:5]) and rating_track='OUTFIELD';
  payload:=public.list_fieldrush_rating_page('CITY','phoenix','OUTFIELD',day_one,day_one+89,0,20);
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'players') p where p->>'profile_id'=two_games::text),
    'season ranking honors its configured three-game minimum');
  perform pg_temp.expect(payload#>>'{players,0,profile_id}'=alpha::text,'more individual goals beats lower conceded/name');
  perform pg_temp.expect(payload#>>'{players,1,profile_id}'=beta::text and payload#>>'{players,2,profile_id}'=gamma::text,'name resolves equal SR, goals scored and conceded');
  perform pg_temp.expect(payload#>>'{players,3,profile_id}'=delta::text,'fewer goals conceded beats alphabetical name');
  perform pg_temp.expect(fieldrush_rating_private.public_rating_state(two_games,'OUTFIELD')->>'rating_visible'='true',
    'a calibrated two-game player keeps visible SR despite not qualifying this season');
  payload:=public.get_fieldrush_season_rewards(season_id,'phoenix','OUTFIELD');
  perform pg_temp.expect(payload->>'total_qualified'='4' and jsonb_array_length(payload->'prize_players')=3,'prize qualification filtered on server with three winners maximum');
  perform pg_temp.expect(payload#>>'{prize_players,0,profile_id}'=alpha::text and payload#>>'{prize_players,0,rank}'='1'
    and payload#>>'{prize_players,0,leaderboard_rank}'='1','prize and season ranking share the configured qualification minimum');
  perform pg_temp.expect(payload#>>'{current_player,profile_id}'=alpha::text and payload#>>'{next_player,profile_id}'=beta::text,'real current/next qualifiers returned for honest SR-gap copy');
  perform set_config('request.jwt.claim.sub',two_games::text,true);
  payload:=public.get_fieldrush_season_rewards(season_id,'phoenix','OUTFIELD');
  perform pg_temp.expect(payload->'current_player'='null'::jsonb and payload->'next_player'='null'::jsonb,'calibrated but season-unqualified user never represented as a winner');
  perform set_config('request.jwt.claim.sub',alpha::text,true);
  -- Audit events must not add a second scorer count for the same real goal.
  insert into public.open_queue_events(game_id,event_type,team,profile_id,minute) values(first_game,'GOAL','WHITE',beta,5);
  payload:=public.list_fieldrush_rating_page('CITY','phoenix','OUTFIELD',day_one,day_one+89,0,20);
  perform pg_temp.expect(payload#>>'{players,1,profile_id}'=beta::text,'goal event log is not counted as a scored goal');

  -- The same person can lead both roles. Keeper pool has exactly two eligible
  -- players, so its third place stays empty and the first/second amounts do not
  -- get redistributed or prorated.
  for j in 1..3 loop
    perform pg_temp.play_reward_game(alpha,opponent,(day_one+40+j)+time '18:00','GK',1,0);
  end loop;
  update public.fieldrush_player_rating_tracks set skill_rating=1600 where profile_id=alpha and rating_track='GOALKEEPER';
  update public.fieldrush_player_rating_tracks set skill_rating=1100 where profile_id=opponent;
  reward:=public.admin_save_fieldrush_season_reward(admin_id,season_id,'phoenix','GOALKEEPER','{}','PUBLISH',null,1);
  payload:=public.get_fieldrush_season_rewards(season_id,'phoenix','GOALKEEPER');
  perform pg_temp.expect(jsonb_array_length(payload->'prize_players')=2 and payload->>'total_qualified'='2','two qualifiers leave third cash place open');
  perform pg_temp.expect(payload->>'first_prize_cents'='15000' and payload->>'second_prize_cents'='10000' and payload->>'third_prize_cents'='5000','unfilled third place does not change full first/second prizes');
  perform pg_temp.expect(payload#>>'{prize_players,0,profile_id}'=alpha::text,'same player eligible to win both role pools');
  payload:=public.get_fieldrush_season_rewards(season_id,'phoenix','OUTFIELD');
  perform pg_temp.expect(payload#>>'{prize_players,0,profile_id}'=alpha::text,'keeper qualification does not remove outfield prize eligibility');

  -- Date edits are authoritative and permit intentional gaps, not overlaps.
  season:=public.admin_save_fieldrush_season(admin_id,second_season,jsonb_build_object('label','NEXT','starts_on',day_one+100,'ends_on',day_one+189,'lifecycle','SCHEDULED'),0);
  season:=public.admin_save_fieldrush_season(admin_id,second_season,jsonb_build_object('starts_on',day_one+110,'ends_on',day_one+200),1);
  perform pg_temp.expect((select starts_on=day_one+110 and ends_on=day_one+200 from fieldrush_rating_private.current_season_bounds(day_one+120)),'active server bounds reflect configured dates');
  perform pg_temp.expect(not exists(select 1 from fieldrush_rating_private.current_season_bounds(day_one+105)),'gap does not fall back to hardcoded quarter');
  payload:=public.admin_list_fieldrush_seasons(admin_id);
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(payload->'seasons') s where s->>'id'='reward-regression' and not (s->>'editable')::boolean and (s->>'published_rewards_locked')::boolean),'published lock exposed to admin consistently');
  perform pg_temp.expect(jsonb_array_length(payload->'audit')>=7,'administrative changes produce audit history');
  raise notice 'Season rewards: all configuration, security, qualification and ranking checks passed.';
end;
$$;
rollback;
