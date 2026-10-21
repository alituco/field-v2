-- Bind a synthetic staff login separately from the historical operational key.
-- This temporary fixture helper never converts the existing player Auth user.
create function pg_temp.bind_staff_login_for_verification(staff_id uuid)
returns uuid language plpgsql as $$
declare login uuid:=gen_random_uuid(); address text:=login::text||'@staff-fixture.example';
begin
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,address,now(),'{"fieldrush_account_type":"staff"}'::jsonb);
  update public.referee_profiles set auth_user_id=login,email=address where profile_id=staff_id;
  if not found then raise exception 'The exact synthetic staff fixture was not found.'; end if;
  return login;
end$$;

-- Transactional behavioral checks: no hosted configuration or ratings change.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create function pg_temp.expect(condition boolean,message text) returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'Season management verification: %',message; end if; end;
$$;
create function pg_temp.season_game(player uuid,opponent uuid,played_at timestamptz,finish boolean)
returns uuid language plpgsql as $$
declare game uuid;
begin
  played_at:=date_trunc('minute',played_at);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,white_score,black_score,market_city_id)
    values('OPEN','Isolated season management regression',played_at,played_at+interval '1 hour',0,1,0,'phoenix') returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,team,status,played,rating_at_team_assignment,rating_at_match_start,amount_paid_fils,base_amount_fils,payment_method)
    select game,id,case when id=player then 'ATT' else 'GK' end,case when id=player then 'WHITE' else 'BLACK' end,
      'CONFIRMED',true,1200,1200,0,0,'FREE' from unnest(array[player,opponent]) id;
  insert into public.open_queue_clock_states(game_id,status,started_at) values(game,'RUNNING',played_at)
    on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at;
  update public.open_queue_games set status='LIVE' where id=game;
  update public.open_queue_bookings set team=case when profile_id=player then 'WHITE' else 'BLACK' end,played=true where game_id=game;
  perform public.ensure_match_attendance_records('SOLO',game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',check_in_timing='EARLY' where open_queue_game_id=game;
  if finish then
    perform set_config('field.allow_early_open_queue_finalization',game::text,true);
    update public.open_queue_clock_states set status='ENDED' where game_id=game;
    update public.open_queue_games set status='FINAL' where id=game;
    perform public.apply_open_queue_player_ratings(game);
  end if;
  return game;
end;
$$;
do $$
declare admin_id uuid:=gen_random_uuid(); player uuid:=gen_random_uuid(); opponent uuid:=gen_random_uuid(); member uuid;
  today date:=(now() at time zone 'America/Phoenix')::date; current_id text; original public.fieldrush_seasons%rowtype;
  season jsonb; payload jsonb; preview jsonb; result jsonb; reward jsonb; old_game uuid; late_game uuid; future_game uuid;
  live_game uuid; rejected boolean; before_sr jsonb; after_sr jsonb; rev integer; n integer; current_rev integer; next_rev integer;
begin
  for member in select unnest(array[admin_id,player,opponent]) loop
    insert into auth.users(id,phone,phone_confirmed_at) values(member,'1555888'||lpad((case when member=admin_id then 1 when member=player then 2 else 3 end)::text,4,'0'),now());
    -- This rollback-only season lifecycle fixture models a pre-policy identity.
    delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=member;
    insert into public.profiles(id,auth_user_id,display_name,username) values(member,member,'Season Test','season_'||left(replace(member::text,'-',''),12)) on conflict(id) do nothing;
    insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) values(member,'active',now()) on conflict(user_id) do update set status='active',onboarding_completed_at=now();
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values(admin_id,'Season Admin','+15558880001','admin',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  perform set_config('request.jwt.claim.sub',player::text,true);
  select * into original from public.fieldrush_seasons where lifecycle='ACTIVE'; current_id:=original.id;
  perform pg_temp.expect(current_id is not null,'migration initializes the existing current season');
  perform pg_temp.expect(not has_function_privilege('authenticated','public.admin_update_fieldrush_season(uuid,text,text,jsonb,text,integer)','EXECUTE'),'players cannot call admin mutations');
  perform pg_temp.expect(not has_function_privilege('service_role','fieldrush_rating_private.process_season_transitions(date)','EXECUTE'),'date override is not exposed through service API');
  perform pg_temp.expect(not has_table_privilege('service_role','public.fieldrush_seasons','UPDATE'),'service writes are only through audited season RPCs');
  rejected:=false;
  begin perform public.admin_update_fieldrush_season(player,current_id,'RENAME','{"label":"No"}',null,original.revision); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'non-admin is rejected even when supplied as an actor by a service caller');
  season:=public.admin_update_fieldrush_season(admin_id,current_id,'RENAME','{"label":"Phoenix season"}',null,original.revision);
  perform pg_temp.expect(season->>'label'='Phoenix season' and season->>'starts_on'=original.starts_on::text,'rename current without changing its start');
  perform pg_temp.expect(exists(select 1 from public.fieldrush_season_audit_events where season_id=current_id and action='SEASON_RENAMED'
    and actor_admin_id=admin_id and before_state->>'label'=original.label and after_state->>'label'='Phoenix season'),'rename records previous name and actor');
  rejected:=false;
  begin perform public.admin_update_fieldrush_season(admin_id,current_id,'RENAME','{"label":"Stale"}',null,original.revision); exception when serialization_failure then rejected:=true; end;
  perform pg_temp.expect(rejected,'stale metadata revision prevents lost updates');
  rejected:=false;
  begin perform public.admin_update_fieldrush_season(admin_id,current_id,'VISIBILITY','{"visible_to_players":false}',null,(season->>'revision')::integer); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'active season cannot be hidden');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,current_id,'{"minimum_rated_games":5}',(season->>'revision')::integer); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'qualification remains locked after start');

  -- Prepare fresh drafts without replacing the administrator's real calendar.
  season:=public.admin_save_fieldrush_season(admin_id,'management-next',jsonb_build_object('label','Next season','starts_on',today+1,'ends_on',today+1),0);
  perform pg_temp.expect(season->>'lifecycle'='DRAFT','new seasons start as private drafts');
  payload:=public.list_fieldrush_seasons();
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'seasons') s where s->>'id'='management-next'),'drafts are absent from picker');
  rejected:=false;
  begin perform public.admin_save_fieldrush_season(admin_id,'management-next',jsonb_build_object('starts_on',today),1); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'existing future draft cannot move its start into today');
  -- Copy a published offer; cloned offers must never become an advertised prize.
  select revision into rev from public.fieldrush_season_rewards where season_id=current_id and city_id='phoenix' and rating_track='OUTFIELD';
  reward:=public.admin_save_fieldrush_season_reward(admin_id,current_id,'phoenix','OUTFIELD','{"first_prize_cents":22222}',
    case when exists(select 1 from public.fieldrush_season_rewards where season_id=current_id and city_id='phoenix' and rating_track='OUTFIELD' and status='PUBLISHED') then 'CORRECT' else 'PUBLISH' end,
    'Isolated fixture published prize setup.',rev);
  season:=public.admin_duplicate_fieldrush_season(admin_id,current_id,'management-copy',jsonb_build_object('label','Copied draft','starts_on',today+50,'ends_on',today+80),
    (select revision from public.fieldrush_seasons where id=current_id));
  perform pg_temp.expect(season->>'lifecycle'='DRAFT' and exists(select 1 from public.fieldrush_season_rewards where season_id='management-copy'
    and rating_track='OUTFIELD' and first_prize_cents=22222 and status='DRAFT' and published_at is null),'duplicate copies cash amounts but resets publication');
  rejected:=false;
  begin perform public.admin_update_fieldrush_season(admin_id,'management-copy','SCHEDULE','{}',null,1); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'scheduling a draft checks the complete existing calendar');
  select revision into rev from public.fieldrush_seasons where id='s0';
  season:=public.admin_update_fieldrush_season(admin_id,'s0','VISIBILITY','{"visible_to_players":false}',null,rev);
  payload:=public.list_fieldrush_seasons();
  perform pg_temp.expect(not exists(select 1 from jsonb_array_elements(payload->'seasons') s where s->>'id'='s0'),'hidden historical season disappears from picker');
  season:=public.admin_update_fieldrush_season(admin_id,'s0','VISIBILITY','{"visible_to_players":true}',null,(season->>'revision')::integer);
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(public.list_fieldrush_seasons()->'seasons') s where s->>'id'='s0'),'historical visibility is reversible');

  old_game:=pg_temp.season_game(player,opponent,now()+interval '1 minute',true);
  perform pg_temp.season_game(player,opponent,now()+interval '2 minutes',true);
  late_game:=pg_temp.season_game(player,opponent,now()+interval '3 minutes',false);
  preview:=public.admin_preview_fieldrush_season_transition(admin_id,current_id,'management-next',today+1);
  perform pg_temp.expect(not (preview->>'can_schedule')::boolean and jsonb_array_length(preview->'live_games')=1,'running game blocks both transition preview and scheduling');
  rejected:=false;
  begin perform public.admin_schedule_fieldrush_season_transition(admin_id,current_id,'management-next',today+1,'Start the next test season at midnight.',
    (select revision from public.fieldrush_seasons where id=current_id),1); exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'live transition mutation independently rechecks blocker');
  update public.open_queue_clock_states set status='ENDED' where game_id=late_game;
  preview:=public.admin_preview_fieldrush_season_transition(admin_id,current_id,'management-next',today+1);
  perform pg_temp.expect((preview->>'can_schedule')::boolean and jsonb_array_length(preview->'live_games')=0,'ended clock with missing result may finalize late');
  preview:=public.admin_preview_fieldrush_season_end(admin_id,current_id,today);
  perform pg_temp.expect((preview->>'can_save')::boolean and preview#>>'{current_season,id}'=current_id,'end date impact preview is authoritative');
  result:=public.admin_schedule_fieldrush_season_transition(admin_id,current_id,'management-next',today+1,'Start the next test season at midnight.',
    (select revision from public.fieldrush_seasons where id=current_id),1);
  perform pg_temp.expect(result->>'scheduled'='true' and (select season_id=current_id from public.open_queue_games where id=old_game),'played game identity survives shortened end');
  perform pg_temp.expect((select season_id=current_id from public.open_queue_games where id=late_game),'completed unfinalized game remains in its original season');
  rejected:=false;
  begin update public.open_queue_games set season_id='management-next' where id=old_game; exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'direct played-game season changes are rejected');
  rejected:=false;
  begin update public.player_rating_events set season_id='management-next' where source_id=old_game; exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'rating event identity cannot be changed');
  -- Draft overlaps must not borrow the active season's participation totals.
  update public.fieldrush_seasons set starts_on=original.starts_on,ends_on=today where id='management-copy';
  payload:=public.admin_list_fieldrush_seasons(admin_id);
  perform pg_temp.expect((select (s#>>'{stats,players}')::integer=0 from jsonb_array_elements(payload->'seasons') s where s->>'id'='management-copy'),'overlapping draft has its own zero participation totals');
  select jsonb_agg(to_jsonb(r) order by rating_track) into before_sr from public.fieldrush_player_rating_tracks r where profile_id=player;

  -- A match can start after confirmation: execution rechecks under the same lock.
  live_game:=pg_temp.season_game(player,opponent,(today+1)::timestamp at time zone 'America/Phoenix',false);
  update public.fieldrush_seasons set lifecycle='DRAFT' where lifecycle='SCHEDULED' and id<>'management-next';
  perform public.admin_save_fieldrush_season(admin_id,'management-successor',jsonb_build_object('label','Successor','starts_on',today+2,'ends_on',today+5,'lifecycle','SCHEDULED'),0);
  result:=fieldrush_rating_private.process_season_transitions(today+1);
  perform pg_temp.expect(result->>'blocked'='true' and result->>'retry_on'=(today+2)::text,'live game at cutoff delays until next Phoenix midnight');
  perform pg_temp.expect((select lifecycle='ACTIVE' and transition_state='BLOCKED_LIVE' from public.fieldrush_seasons where id=current_id),'previous season remains active during blocked rollover');
  perform pg_temp.expect((select starts_on=today+2 and ends_on=today+2 from public.fieldrush_seasons where id='management-next')
    and (select starts_on=today+3 and ends_on=today+6 from public.fieldrush_seasons where id='management-successor'),'one-day next season and colliding successor slide without overlapping');
  result:=fieldrush_rating_private.process_season_transitions(today+1);
  perform pg_temp.expect(result->>'changed'='false','repeated same-day processing never starts a season mid-day');
  update public.open_queue_clock_states set status='ENDED' where game_id=live_game;
  result:=fieldrush_rating_private.process_season_transitions(today+2);
  perform pg_temp.expect(result->>'blocked'='false' and (select lifecycle='ACTIVE' and visible_to_players from public.fieldrush_seasons where id='management-next'),'next midnight activates next season after games finish');
  select jsonb_agg(to_jsonb(r) order by rating_track) into after_sr from public.fieldrush_player_rating_tracks r where profile_id=player;
  perform pg_temp.expect(before_sr=after_sr,'rollover carries both canonical role ratings without resets or updates');
  payload:=public.get_fieldrush_player_ratings(player,today+2,today+2);
  perform pg_temp.expect(payload#>>'{ratings,OUTFIELD,matches_played}'='0' and payload#>>'{ratings,GOALKEEPER,matches_played}'='0','new season repeats role placement with zero seasonal games');
  perform set_config('field.allow_early_open_queue_finalization',late_game::text,true);
  update public.open_queue_games set status='FINAL' where id=late_game;
  perform public.apply_open_queue_player_ratings(late_game);
  perform pg_temp.expect(exists(select 1 from public.player_rating_events where source_id=late_game and season_id=current_id),'late-finalized game writes events to original season');
  perform pg_temp.expect((select count(*)=3 from fieldrush_rating_private.season_track_events(original.starts_on,today+1) where profile_id=player and rating_track='OUTFIELD'),'late result contributes to original season participation');
  payload:=public.get_fieldrush_player_ratings(player,today+2,today+2);
  perform pg_temp.expect(payload#>>'{ratings,OUTFIELD,matches_played}'='0','late prior result does not reveal new-season placement');
  season:=public.admin_update_fieldrush_season(admin_id,current_id,'VISIBILITY','{"visible_to_players":false}',null,(select revision from public.fieldrush_seasons where id=current_id));
  perform pg_temp.expect(public.get_fieldrush_season_rewards(current_id,'phoenix','OUTFIELD') is null,'hidden season does not advertise cash prizes');
  perform pg_temp.expect((select count(*)=3 from fieldrush_rating_private.season_track_events(original.starts_on,today+1) where profile_id=player),'hiding preserves historical statistics');
  perform pg_temp.expect(exists(select 1 from public.player_rating_events where source_id=old_game),'hiding does not remove match history');
  -- Simulate several missed cutoffs: never activate an already elapsed season.
  result:=fieldrush_rating_private.process_season_transitions(today+20);
  perform pg_temp.expect(not exists(select 1 from public.fieldrush_seasons where lifecycle='ACTIVE')
    and (select lifecycle='ENDED' from public.fieldrush_seasons where id='management-successor'),'missed scheduler catches up expired seasons in one invocation');
  perform pg_temp.expect(exists(select 1 from public.fieldrush_season_audit_events where action='SEASON_TRANSITION_BLOCKED' and actor_admin_id is null),'automatic block is audited as a scheduler action');
  raise notice 'Season management: authorization, drafts, visibility, live guards, rollover, history and carried SR passed.';
end;
$$;
rollback;
