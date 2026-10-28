-- Disposable complete-schema verification inside caller-owned BEGIN/ROLLBACK.
-- Uses real onboarding, booking/attendance triggers, referee identity mapping,
-- public feeds/detail, manual check-in and finalization. No trigger is disabled.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create temporary table solo_arrival_checks(label text);
create function pg_temp.arrival_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Solo arrival: %',label; end if;
  insert into solo_arrival_checks values(label); end;
$$;
create sequence pg_temp.arrival_person;
create function pg_temp.arrival_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.arrival_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'15557993'||lpad(n::text,3,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Arrival','last_name','Player',
    'username','arrive_'||n,'date_of_birth','2000-01-01','email','arrive_'||n||'@example.test',
    'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;

do $verify$
declare admin_id uuid:=pg_temp.arrival_player(); admin_auth uuid:=gen_random_uuid(); players uuid[]:='{}';
  game uuid; historical_game uuid; cancelled_game uuid; final_game uuid; b uuid; player uuid; i integer;
  final_players uuid[]:='{}';
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
  terms public.match_reliability_terms; original_terms jsonb; original_booking jsonb; original_events jsonb;
  original_policy jsonb; quote_before jsonb; quote_after jsonb; context jsonb; detail jsonb; feed record;
  modified public.match_reliability_terms; old_cutoff timestamptz; past_kickoff timestamptz;
  historical_before jsonb; cancelled_before jsonb; s boolean; signature text; alias_signature text;
begin
  -- A staff login is separate from its retained operational profile key.
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Arrival admin','+15557993999','admin',true);
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(admin_auth,admin_auth::text||'@arrival-staff.example',now(),'{"fieldrush_account_type":"staff"}');
  update public.referee_profiles set auth_user_id=admin_auth,email=admin_auth::text||'@arrival-staff.example'
    where profile_id=admin_id;
  -- Legitimate rollback-only policy evidence permits a historical fixture;
  -- neither the real published policy nor its immutable trigger is changed.
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Rollback-only historical arrival verification.',now(),admin_id
    from public.reliability_policy_versions order by version limit 1;
  select jsonb_agg(to_jsonb(p) order by p.id) into original_policy from public.reliability_policy_versions p;
  for i in 1..5 loop players:=array_append(players,pg_temp.arrival_player()); end loop;
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback Solo arrival verification',kickoff,kickoff+interval '1 hour',0,admin_id)
    returning id into game;
  for i in 1..5 loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(game,players[i],case when i<=4 then 'DEF' else 'ATT' end,'CONFIRMED',0,0,'FREE');
  end loop;
  select * into terms from public.match_reliability_terms where open_queue_game_id=game;
  original_terms:=to_jsonb(terms);
  select jsonb_agg(to_jsonb(x) order by x.id) into original_booking from public.open_queue_bookings x where game_id=game;
  perform pg_temp.arrival_expect(terms.arrival_policy_version_id='solo-arrival-30-10-v1'
    and terms.arrival_check_in_opens_at=kickoff-interval '30 minutes'
    and terms.arrival_check_in_deadline_at=kickoff-interval '10 minutes',
    'new booked Solo game saves the versioned 30/10 arrival contract');
  perform pg_temp.arrival_expect(terms.check_in_deadline_at=kickoff-make_interval(mins=>(terms.policy_snapshot#>>'{attendance,checkInLeadMinutes}')::integer)
    and terms.check_in_opens_at=kickoff-make_interval(mins=>(terms.policy_snapshot#>>'{attendance,checkInOpenLeadMinutes}')::integer),
    'accepted commercial deadline/reminder fields retain original policy values');
  perform pg_temp.arrival_expect((select count(*)=5 and bool_and(check_in_deadline_at=kickoff-interval '10 minutes')
    from public.current_match_attendance_records where open_queue_game_id=game),
    'all new provisional booking attendance receives the new arrival deadline');

  -- The public player views agree while calibrated individual SR stays hidden.
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  execute 'set local role authenticated';
  detail:=public.get_open_queue_match_detail(game);
  execute 'reset role';
  perform pg_temp.arrival_expect((detail->>'check_in_opens_at')::timestamptz=kickoff-interval '30 minutes'
    and (detail->>'check_in_deadline_at')::timestamptz=kickoff-interval '10 minutes'
    and detail->>'late_cutoff_inclusive'='true' and (detail->>'lobby_average_sr')::numeric=1000
    and not exists(select 1 from jsonb_array_elements(detail->'players') p where p->>'rating_visible'='true'),
    'authenticated detail exposes arrival fields and full lobby average without unmasking placement SR');
  foreach signature in array array['public.list_open_queue_games()','public.list_open_queue_fixture_games()',
    'public.list_open_queue_games_for_market(''America/Phoenix'')','public.list_open_queue_games_for_city(''phoenix'')'] loop
    execute 'set local role authenticated';
    execute 'select check_in_opens_at=$1 and check_in_deadline_at=$2 from '||signature||' where id=$3'
      into s using kickoff-interval '30 minutes',kickoff-interval '10 minutes',game;
    execute 'reset role';
    perform pg_temp.arrival_expect(s,'arrival fields present in feed '||signature);
  end loop;

  perform set_config('request.jwt.claim.role','service_role',true);
  perform set_config('request.jwt.claim.sub',admin_auth::text,true);
  context:=public.get_match_reliability_context('SOLO',game);
  perform pg_temp.arrival_expect((context->>'check_in_opens_at')::timestamptz=kickoff-interval '30 minutes'
    and (context->>'check_in_deadline_at')::timestamptz=kickoff-interval '10 minutes'
    and context->>'late_cutoff_inclusive'='true' and context->>'check_in_authority'='REFEREE',
    'referee context uses arrival target/late cutoff and inclusive boundary');
  -- The arrival target never stops the host recording an earlier arrival.
  context:=public.referee_check_in_player_with_timing(admin_id,'SOLO',game,players[1],'EARLY');
  context:=public.referee_check_in_player_with_timing(admin_id,'SOLO',game,players[2],'LATE');
  perform pg_temp.arrival_expect((select checked_in_at<terms.arrival_check_in_opens_at
    from public.current_match_attendance_records where open_queue_game_id=game and profile_id=players[1]),
    'referee can record Early before the 30-minute display target');
  perform pg_temp.arrival_expect((select check_in_timing='LATE'
    from public.current_match_attendance_records where open_queue_game_id=game and profile_id=players[2]),
    'manual referee Late choice remains authoritative');

  -- Boundary and migrated-manual-category checks do not invent a wall clock.
  perform pg_temp.arrival_expect(fieldrush_private.arrival_is_on_time(terms.arrival_check_in_deadline_at-interval '1 microsecond',null,terms)
    and not fieldrush_private.arrival_is_on_time(terms.arrival_check_in_deadline_at,null,terms)
    and not fieldrush_private.arrival_is_on_time(terms.arrival_check_in_deadline_at+interval '1 microsecond',null,terms),
    'T-10 exact and later are late, one microsecond earlier is on time');
  perform pg_temp.arrival_expect(not fieldrush_private.arrival_is_on_time(terms.check_in_deadline_at+interval '1 millisecond','LATE',terms)
    and fieldrush_private.arrival_is_on_time(kickoff,'EARLY',terms),
    'existing old-deadline Late evidence and explicit Early choices are preserved');
  modified:=terms;
  modified.policy_snapshot:=jsonb_set(modified.policy_snapshot,'{solo,outcomes,late,strikes}','2',false);
  modified:=fieldrush_private.arrival_attendance_terms(modified);
  perform pg_temp.arrival_expect(modified.policy_snapshot#>>'{solo,outcomes,late,strikes}'='1'
    and modified.policy_snapshot#>'{solo,outcomes,noShow}'=terms.policy_snapshot#>'{solo,outcomes,noShow}'
    and modified.policy_snapshot#>'{solo,cancellations}'=terms.policy_snapshot#>'{solo,cancellations}',
    'new contract fixes Late at one strike without changing no-show or cancellation rules');

  -- Same-time commercial quotes use the accepted commercial terms, not the
  -- new displayed arrival threshold, and reads never replace that snapshot.
  select id into b from public.open_queue_bookings where game_id=game and profile_id=players[3];
  quote_before:=public.open_queue_cancellation_quote(b,players[3],kickoff-interval '20 minutes');
  perform public.get_match_reliability_context('SOLO',game);
  quote_after:=public.open_queue_cancellation_quote(b,players[3],kickoff-interval '20 minutes');
  perform pg_temp.arrival_expect(quote_before=quote_after
    and (quote_after->>'check_in_deadline_at')::timestamptz=terms.check_in_deadline_at
    and (select to_jsonb(t)=original_terms from public.match_reliability_terms t where t.id=terms.id),
    'attendance reads leave commercial cancellation quote and accepted policy snapshot unchanged');
  perform pg_temp.arrival_expect((select jsonb_agg(to_jsonb(x) order by x.id)=original_booking
    from public.open_queue_bookings x where game_id=game),
    'arrival policy and referee check-in do not rewrite bookings, payments or refunds');

  -- Past/cancelled/live inventory is outside the prospective backfill; a
  -- legitimate reopening binds the new contract without erasing its terms.
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback historical arrival',date_trunc('minute',now())-interval '2 hours',date_trunc('minute',now())-interval '1 hour',0,admin_id)
    returning id into historical_game;
  perform public.ensure_match_reliability_terms('SOLO',historical_game);
  select to_jsonb(t) into historical_before from public.match_reliability_terms t where open_queue_game_id=historical_game;
  perform pg_temp.arrival_expect(historical_before->'arrival_policy_version_id'='null'::jsonb,
    'historical game is not assigned a new arrival policy');
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by,cancelled_at,cancelled_by,cancellation_reason,cancellation_code)
    values('CANCELLED','Rollback reopen arrival',kickoff+interval '1 day',kickoff+interval '25 hours',0,admin_id,
      now(),admin_id,'Rollback-only cancelled inventory','ADMIN_DECISION')
    returning id into cancelled_game;
  perform public.ensure_match_reliability_terms('SOLO',cancelled_game);
  select to_jsonb(t) into cancelled_before from public.match_reliability_terms t where open_queue_game_id=cancelled_game;
  perform pg_temp.arrival_expect(cancelled_before->'arrival_policy_version_id'='null'::jsonb,
    'cancelled inventory remains unchanged');
  update public.open_queue_games set status='OPEN',cancelled_at=null,cancelled_by=null,cancellation_reason=null,cancellation_code=null where id=cancelled_game;
  perform pg_temp.arrival_expect((select arrival_policy_version_id='solo-arrival-30-10-v1'
    and to_jsonb(t)-array['arrival_policy_version_id','arrival_check_in_opens_at','arrival_check_in_deadline_at']
      =cancelled_before-array['arrival_policy_version_id','arrival_check_in_opens_at','arrival_check_in_deadline_at']
    from public.match_reliability_terms t where open_queue_game_id=cancelled_game),
    'reopened upcoming inventory gets only arrival fields with commercial snapshot intact');
  modified:=terms;
  modified.match_kind:='CLAN'; modified.arrival_policy_version_id:=null;
  perform pg_temp.arrival_expect(fieldrush_private.arrival_attendance_terms(modified)=modified
    and fieldrush_private.arrival_is_on_time(modified.check_in_deadline_at,null,modified),
    'clan terms and legacy inclusive-on-time boundary remain unchanged');

  -- Model a game whose bound arrival contract has now passed its cutoff.
  -- This is a new, test-owned past fixture with explicit saved policy evidence;
  -- permanent schedules are never edited and no clock/trigger is substituted.
  past_kickoff:=date_trunc('minute',clock_timestamp())-interval '20 minutes';
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback elapsed arrival contract',past_kickoff,past_kickoff+interval '1 hour',0,admin_id)
    returning id into final_game;
  perform public.ensure_match_reliability_terms('SOLO',final_game);
  update public.match_reliability_terms set arrival_policy_version_id='solo-arrival-30-10-v1'
    where open_queue_game_id=final_game;
  for i in 1..5 loop
    player:=pg_temp.arrival_player(); final_players:=array_append(final_players,player);
    -- These consequence-only elapsed fixtures intentionally carry no payment
    -- or booking identity. The real future bookings above cover preservation;
    -- creating a new booking after kickoff is correctly rejected by the app.
    insert into public.match_attendance_records(terms_id,match_kind,open_queue_game_id,profile_id,
      policy_version_id,check_in_deadline_at,no_show_cutoff_at,expected_for_match,role)
      select t.id,'SOLO',final_game,player,t.policy_version_id,t.arrival_check_in_deadline_at,
        t.no_show_cutoff_at,true,case when i<=4 then 'DEF' else 'ATT' end
      from public.match_reliability_terms t where t.open_queue_game_id=final_game;
  end loop;
  perform set_config('request.jwt.claim.sub',admin_auth::text,true);
  select * into terms from public.match_reliability_terms where open_queue_game_id=final_game;
  update public.match_attendance_records set checked_in_at=past_kickoff+interval '5 minutes',
    check_in_timing='EARLY' where open_queue_game_id=final_game and profile_id=final_players[1];
  update public.match_attendance_records set checked_in_at=terms.check_in_deadline_at+interval '1 millisecond',
    check_in_timing='LATE' where open_queue_game_id=final_game and profile_id=final_players[2];
  update public.match_attendance_records set checked_in_at=terms.arrival_check_in_deadline_at,
    check_in_timing=null where open_queue_game_id=final_game and profile_id=final_players[3];
  update public.match_attendance_records set checked_in_at=terms.arrival_check_in_deadline_at-interval '1 microsecond',
    check_in_timing=null where open_queue_game_id=final_game and profile_id=final_players[4];
  context:=public.get_match_reliability_context('SOLO',final_game);
  perform pg_temp.arrival_expect((context->>'late_count')::integer=2 and (context->>'on_time_count')::integer=2,
    'provisional context agrees with manual categories and exact late boundary');
  perform pg_temp.arrival_expect(public.finalize_match_attendance_internal('SOLO',final_game,admin_id)=5
    and public.finalize_match_attendance_internal('SOLO',final_game,admin_id)=0,
    'final attendance settles each player once');
  perform pg_temp.arrival_expect((select bool_and(case
    when profile_id in (final_players[1],final_players[4]) then outcome='ON_TIME' and strike_delta=0
    when profile_id in (final_players[2],final_players[3]) then outcome='LATE' and strike_delta=1
    else outcome='NO_SHOW' and strike_delta=(terms.policy_snapshot#>>'{solo,outcomes,noShow,strikes}')::integer end)
    from public.current_match_attendance_records where open_queue_game_id=final_game),
    'actual finalizer applies one late strike, preserves Early and leaves no-show rule intact');
  perform pg_temp.arrival_expect((select to_jsonb(t)=historical_before from public.match_reliability_terms t
    where open_queue_game_id=historical_game)
    and (select jsonb_agg(to_jsonb(p) order by p.id)=original_policy from public.reliability_policy_versions p),
    'historical terms and all published commercial policy versions remain unchanged');

  foreach signature in array array['public.list_open_queue_games()','public.list_open_queue_fixture_games()',
    'public.list_open_queue_games_for_market(text)','public.list_open_queue_games_for_city(text)',
    'public.get_open_queue_match_detail(uuid)'] loop
    alias_signature:=replace(signature,'(','_before_arrival_notice(');
    perform pg_temp.arrival_expect((select provolatile='s' and prosecdef from pg_proc where oid=signature::regprocedure)
      and has_function_privilege('authenticated',signature,'EXECUTE')
      and not has_function_privilege('anon',signature,'EXECUTE')
      and not has_function_privilege('authenticated',alias_signature,'EXECUTE')
      and not has_function_privilege('service_role',alias_signature,'EXECUTE'),
      'STABLE privacy-preserving public and private-alias ACL contract '||signature);
  end loop;
end;
$verify$;
select count(*)||' Solo arrival assertions passed' as result from solo_arrival_checks;
