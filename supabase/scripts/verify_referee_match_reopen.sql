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
create function pg_temp.reopen_game(admin_id uuid,referee_id uuid,players uuid[],paid boolean default false) returns uuid language plpgsql as $$
declare game uuid; i integer; kickoff timestamptz:=date_trunc('minute',clock_timestamp())-make_interval(mins=>nextval('pg_temp.reopen_game_number')::integer);
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

do $$
declare players uuid[]:=array[]::uuid[]; admin_id uuid:=pg_temp.reopen_player(); referee_id uuid:=pg_temp.reopen_player(); outsider uuid:=pg_temp.reopen_player();
  login uuid; staff uuid; i integer; game uuid; later uuid; zero_game uuid; injury_game uuid; injured uuid; scorer uuid;
  result jsonb; early_result jsonb; reopened jsonb; before_tracks jsonb; rated_tracks jsonb; before_finances jsonb; before_attendance jsonb;
  request uuid:=gen_random_uuid(); reopen_request uuid:=gen_random_uuid(); goals_before jsonb; roster_before jsonb;
  refund_count integer; incident_count integer; terms_before jsonb; failed boolean:=false;
  conflict_game uuid; pending_checkout uuid; conflict_before jsonb;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (admin_id,'Reopen admin','+15555570001','admin',true),(referee_id,'Reopen referee','+15555570002','referee',true);
  foreach staff in array array[admin_id,referee_id] loop
    login:=gen_random_uuid();
    insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
      values(login,login||'@reopen-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
    update public.referee_profiles set auth_user_id=login,email=login||'@reopen-staff.example.test' where profile_id=staff;
  end loop;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable unchanged financial policy for reopen regression.',now(),admin_id
      from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable referee end/reopen verification only.');
  for i in 1..14 loop players:=array_append(players,pg_temp.reopen_player()); end loop;
  game:=pg_temp.reopen_game(admin_id,referee_id,players);
  select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) into before_tracks from public.fieldrush_player_rating_tracks t where profile_id=any(players);
  select to_jsonb(t) into terms_before from public.match_reliability_terms t where open_queue_game_id=game;
  perform public.referee_season_zero_action(referee_id,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set accumulated_seconds=300,started_at=clock_timestamp() where game_id=game;
  select profile_id into scorer from public.open_queue_bookings where game_id=game and team='WHITE' limit 1;
  insert into public.open_queue_goals(game_id,team,profile_id,minute) values(game,'WHITE',scorer,5);
  select jsonb_agg(to_jsonb(g) order by id) into goals_before from public.open_queue_goals g where game_id=game;
  early_result:=public.referee_finish_season_zero_match(referee_id,game,request,1);
  perform pg_temp.reopen_expect(early_result->>'rating_status'='completed' and early_result->>'settlement_status'='RATED'
    and early_result->>'completion_rules_version'='s0-referee-ended-v1'
    and early_result->>'referee_can_reopen'='true','early finish rates the completed actual playing duration');
  perform pg_temp.reopen_expect((select status='FINAL' and white_score=1 and black_score=0 from public.open_queue_games where id=game),'early score saved');
  perform pg_temp.reopen_expect(public.referee_finish_season_zero_match(referee_id,game,request,999)=early_result,'finish retry returns original response');
  perform pg_temp.reopen_expect((select count(*)=14 and bool_and(counted_as_played) from public.player_rating_events
    where source_type='OPEN_QUEUE' and source_id=game),'all players who completed the early match receive one counted rating event');
  perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,2)',outsider,game,gen_random_uuid()),'not assigned');
  perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,1)',referee_id,game,gen_random_uuid()),'changed match');
  perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,2)',referee_id,game,request),'another action');
  reopened:=public.referee_reopen_season_zero_match(referee_id,game,reopen_request,2);
  perform pg_temp.reopen_expect(reopened->>'lifecycle'='LIVE' and reopened->>'settlement_status'='HELD'
    and reopened->>'referee_can_reopen'='false' and reopened->'audit'->>'final_clock_state'='PAUSED','reopen is live with paused evidence and held SR');
  perform pg_temp.reopen_expect(reopened->'observed_roster'=early_result->'observed_roster'
    and reopened->'events'=early_result->'events' and reopened->'played_seconds'=early_result->'played_seconds','reopen preserves original roster and playing evidence');
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(g) order by id)=goals_before from public.open_queue_goals g where game_id=game),'recorded goals survive');
  perform pg_temp.reopen_expect((select status='PAUSED' and started_at is null and accumulated_seconds=(early_result->>'played_seconds')::integer from public.open_queue_clock_states where game_id=game),'reopened clock does not count time after final whistle');
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(t)-'updated_at' order by profile_id,rating_track)=
    (select jsonb_agg(value-'updated_at' order by value->>'profile_id',value->>'rating_track') from jsonb_array_elements(before_tracks))
    from public.fieldrush_player_rating_tracks t where profile_id=any(players)),'reopening the early rated result restores the original ratings and counts');
  perform pg_temp.reopen_expect(public.referee_reopen_season_zero_match(referee_id,game,reopen_request,999)=reopened,'reopen retry is idempotent');
  perform public.referee_season_zero_action(referee_id,game,gen_random_uuid(),3,'{"action":"RESUME"}');
  update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=game;
  result:=public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),4);
  perform pg_temp.reopen_expect(result->>'settlement_status'='RATED','continued game rates after agreed playing duration');
  later:=pg_temp.reopen_game(admin_id,referee_id,players);
  perform public.referee_season_zero_action(referee_id,later,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=later;
  perform public.referee_finish_season_zero_match(referee_id,later,gen_random_uuid(),1);
  select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) into rated_tracks from public.fieldrush_player_rating_tracks t where profile_id=any(players);
  -- A participant may book another match once this one finishes. Reopening
  -- must retain the existing registration safeguard and explain the conflict
  -- to the referee, without cancelling that booking or partly withdrawing SR.
  begin
    conflict_game:=pg_temp.reopen_game(admin_id,referee_id,players);
    conflict_before:=pg_temp.reopen_snapshot(game);
    perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,5)',referee_id,game,gen_random_uuid()),
      'A player has another active game or checkout. Resolve that booking before reopening.');
    perform pg_temp.reopen_expect(pg_temp.reopen_snapshot(game)=conflict_before,'registration conflict rolls back all match, clock, evidence and SR changes');
    perform pg_temp.reopen_expect((select count(*)=14 and bool_and(status='CONFIRMED') from public.open_queue_bookings where game_id=conflict_game),
      'registration conflict preserves the other active bookings');
    raise exception 'Rollback synthetic conflicting booking.' using errcode='ZX002';
  exception when sqlstate 'ZX002' then null;
  end;
  perform pg_temp.reopen_expect(true,'another booked game prevents reopening atomically and retains its booking');
  begin
    insert into public.open_queue_games(venue,starts_at,ends_at,price_fils)
      values('Disposable pending checkout conflict',date_trunc('minute',clock_timestamp())+interval '1 day',
        date_trunc('minute',clock_timestamp())+interval '25 hours',10000) returning id into conflict_game;
    insert into public.payment_intents(profile_id,purpose,status,currency,amount_fils,payload,quote_snapshot,transaction_reference,provider)
      values(players[1],'SOLO_BOOKING','PENDING','USD',10000,jsonb_build_object('game_id',conflict_game,'role','GK'),
        '{}','reopen-pending-'||gen_random_uuid(),'STRIPE') returning id into pending_checkout;
    conflict_before:=pg_temp.reopen_snapshot(game);
    perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,5)',referee_id,game,gen_random_uuid()),
      'A player has another active game or checkout. Resolve that booking before reopening.');
    perform pg_temp.reopen_expect(pg_temp.reopen_snapshot(game)=conflict_before,'pending checkout conflict rolls back all match, clock, evidence and SR changes');
    perform pg_temp.reopen_expect((select status='PENDING' from public.payment_intents where id=pending_checkout),'pending checkout is preserved');
    raise exception 'Rollback synthetic conflicting checkout.' using errcode='ZX002';
  exception when sqlstate 'ZX002' then null;
  end;
  perform pg_temp.reopen_expect(true,'another pending checkout prevents reopening atomically and retains the checkout');
  perform public.referee_reopen_season_zero_match(referee_id,game,gen_random_uuid(),5);
  perform pg_temp.reopen_expect(not exists(select 1 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id in (game,later))
    and (select settlement_status='HELD' from fieldrush_rating_private.season_zero_matches where game_id=later),'reopening rated game withdraws its award and holds dependent later game');
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(t)-'updated_at' order by profile_id,rating_track)=
    (select jsonb_agg(value-'updated_at' order by value->>'profile_id',value->>'rating_track') from jsonb_array_elements(before_tracks))
    from public.fieldrush_player_rating_tracks t where profile_id=any(players)),'reopen restores lifetime pools before the two withdrawn results');
  perform public.referee_finish_season_zero_match(referee_id,game,gen_random_uuid(),6);
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(t)-'updated_at' order by profile_id,rating_track)=
    (select jsonb_agg(value-'updated_at' order by value->>'profile_id',value->>'rating_track') from jsonb_array_elements(rated_tracks))
    from public.fieldrush_player_rating_tracks t where profile_id=any(players)),'refinish reapplies each dependent award and appearance exactly once');
  perform pg_temp.reopen_expect((select count(*)=28 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id in (game,later)),'one active rating event per participant per game');
  perform pg_temp.reopen_expect((select to_jsonb(t)=terms_before from public.match_reliability_terms t where open_queue_game_id=game),'paid contractual terms never change');
  perform public.admin_resolve_season_zero_match(admin_id,game,gen_random_uuid(),7,jsonb_build_object('status','unranked','winner',null,'reason','Organizer review remains protected from referee reopening.'));
  perform pg_temp.reopen_reject(format('select public.referee_reopen_season_zero_match(%L,%L,%L,8)',referee_id,game,gen_random_uuid()),'organizer-reviewed');
  perform pg_temp.reopen_expect(public.get_season_zero_match_state(referee_id,game)->>'referee_can_reopen'='false','organizer result does not offer referee reopen');

  zero_game:=pg_temp.reopen_game(admin_id,referee_id,players);
  perform public.referee_season_zero_action(referee_id,zero_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set started_at=clock_timestamp()+interval '1 hour',accumulated_seconds=0 where game_id=zero_game;
  result:=public.referee_finish_season_zero_match(referee_id,zero_game,gen_random_uuid(),1);
  perform pg_temp.reopen_expect(result->>'played_seconds'='0' and result->>'settlement_status'='NOT_RATED','immediate finish records zero playing time without fabricated SR');

  -- Exercise the actual attendance/financial callbacks, not test stand-ins.
  injury_game:=pg_temp.reopen_game(admin_id,referee_id,players,true);
  select profile_id into injured from public.open_queue_bookings where game_id=injury_game and team='BLACK' and role='GK';
  perform public.referee_season_zero_action(referee_id,injury_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set accumulated_seconds=300,started_at=clock_timestamp() where game_id=injury_game;
  perform public.referee_record_verified_injury(referee_id,'SOLO',injury_game,injured,true,false,true,'Verified injury for refund idempotency regression.');
  perform public.referee_season_zero_action(referee_id,injury_game,gen_random_uuid(),1,jsonb_build_object('action','EXCUSED_LEAVE','profile_id',injured,'note','Verified injury departure.'));
  update public.open_queue_clock_states set accumulated_seconds=3600,started_at=clock_timestamp() where game_id=injury_game;
  select count(*) into refund_count from public.field_wallet_transactions;
  perform public.referee_finish_season_zero_match(referee_id,injury_game,gen_random_uuid(),2);
  perform pg_temp.reopen_expect((select count(*)-refund_count=14 from public.field_wallet_transactions),'real injury refunds credited once on first completed finish');
  select jsonb_agg(to_jsonb(b)-array['updated_at','rating_change'] order by id) into before_finances from public.open_queue_bookings b where game_id=injury_game;
  select jsonb_agg(to_jsonb(a) order by id) into before_attendance from public.match_attendance_records a where open_queue_game_id=injury_game;
  select count(*) into refund_count from public.field_wallet_transactions;
  select count(*) into incident_count from public.reliability_incidents;
  perform public.referee_reopen_season_zero_match(referee_id,injury_game,gen_random_uuid(),3);
  perform public.referee_finish_season_zero_match(referee_id,injury_game,gen_random_uuid(),4);
  perform pg_temp.reopen_expect((select count(*)=refund_count from public.field_wallet_transactions),'refinish creates no duplicate wallet refund');
  perform pg_temp.reopen_expect((select count(*)=incident_count from public.reliability_incidents),'refinish creates no duplicate strike or incident');
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(b)-array['updated_at','rating_change'] order by id)=before_finances from public.open_queue_bookings b where game_id=injury_game),'refinish preserves booking payment/refund/deposit amounts');
  perform pg_temp.reopen_expect((select jsonb_agg(to_jsonb(a) order by id)=before_attendance from public.match_attendance_records a where open_queue_game_id=injury_game),'refinish preserves finalized attendance evidence');
  perform pg_temp.reopen_expect(not has_function_privilege('anon','public.referee_reopen_season_zero_match(uuid,uuid,uuid,integer)','EXECUTE')
    and not has_function_privilege('authenticated','public.referee_reopen_season_zero_match(uuid,uuid,uuid,integer)','EXECUTE')
    and has_function_privilege('service_role','public.referee_reopen_season_zero_match(uuid,uuid,uuid,integer)','EXECUTE'),'reopen remains service-only with server actor authorization');
end;
$$;
select count(*) as passed_checks from reopen_checks;
