-- Rollback-only application-schema tests. No provider or hosted writes.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table referral_checks(label text);
create temporary table referral_timings(stage text,elapsed_ms numeric);
create function pg_temp.ref_expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Referral: %',label; end if;
  insert into referral_checks values(label); end $$;
create function pg_temp.ref_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
  perform pg_temp.ref_expect(rejected,'rejected: '||expected);
end $$;
create sequence pg_temp.ref_person;
create sequence pg_temp.ref_game_number;
create function pg_temp.ref_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.ref_person'); prior_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555598'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Referral','last_name','Player','username','referral_'||n,
    'date_of_birth','2000-01-01','email','referral_'||n||'@example.test','skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
  return player;
end $$;
create function pg_temp.ref_game(actor uuid,players uuid[],kickoff_to_use timestamptz default null) returns uuid language plpgsql as $$
declare game uuid; i integer; kickoff timestamptz:=coalesce(kickoff_to_use,date_trunc('minute',clock_timestamp())-interval '1 minute'*nextval('pg_temp.ref_game_number'));
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,minimum_players,participation_rules_version)
    values('Disposable referral verification',kickoff,kickoff+interval '1 hour',0,2,'s0-configurable-v1') returning id into game;
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
create function pg_temp.ref_claim(referred uuid,referrer uuid) returns jsonb language plpgsql as $$
declare code text;
begin
  select username into code from public.profiles where id=referrer;
  perform set_config('request.jwt.claim.sub',referred::text,true);
  return public.claim_fieldrush_referral_code(upper(code),referrer);
end $$;

-- Own-code sharing never expires; legacy accounts receive one launch grace
-- window. Neither update nor a second referral code can extend or replace it.
do $$
declare owner uuid:=pg_temp.ref_player(); friend uuid:=pg_temp.ref_player(); other uuid:=pg_temp.ref_player();
  owner_code text; friend_code text; initial jsonb; result jsonb; before_link jsonb; launch_time timestamptz;
begin
  select username into owner_code from public.profiles where id=owner;
  select username into friend_code from public.profiles where id=friend;
  update fieldrush_private.accounts set onboarding_completed_at=now()-interval '365 days' where user_id=owner;
  perform set_config('request.jwt.claim.sub',owner::text,true);
  initial:=public.get_fieldrush_referrals();
  select launched_at into launch_time from fieldrush_referral_private.launch;
  perform pg_temp.ref_expect((initial->>'can_add_code')::boolean
    and (initial->>'entry_expires_at')::timestamptz=launch_time+interval '7 days','old account receives exactly seven days from recorded launch');
  perform pg_temp.ref_expect(initial->>'own_code'=upper(owner_code) and initial->'referrer'='null'::jsonb
    and (initial->>'referral_count')::integer=0,'initial own code, no link and zero credit');
  perform pg_temp.ref_expect((public.check_fieldrush_referral_code('  '||upper(friend_code)||'  ')->>'id')::uuid=friend,
    'username code is case insensitive and trims surrounding spaces');
  perform pg_temp.ref_reject(format('select public.check_fieldrush_referral_code(%L)',owner_code),'your own code');
  perform pg_temp.ref_reject('select public.check_fieldrush_referral_code(''doesnotexist'')','couldn’t find');
  perform pg_temp.ref_reject(format('select public.claim_fieldrush_referral_code(%L,%L)',friend_code,other),'code has changed');
  perform pg_temp.ref_reject(format('select public.claim_fieldrush_referral_code(%L,null)',friend_code),'Check your friend');
  result:=public.claim_fieldrush_referral_code(friend_code,friend);
  perform pg_temp.ref_expect(result#>>'{referrer,id}'=friend::text and result->>'can_add_code'='false','one code becomes permanently linked');
  select to_jsonb(l) into before_link from fieldrush_referral_private.links l where referred_profile_id=owner;
  perform public.claim_fieldrush_referral_code(upper(friend_code),friend);
  perform pg_temp.ref_expect((select to_jsonb(l)=before_link from fieldrush_referral_private.links l where referred_profile_id=owner),
    'same-code retry retains original timestamp and one immutable row');
  perform pg_temp.ref_reject(format('select public.claim_fieldrush_referral_code(%L,%L)',(select username from public.profiles where id=other),other),'already linked');
  perform pg_temp.ref_reject(format('update fieldrush_referral_private.links set referrer_profile_id=%L where referred_profile_id=%L',other,owner),'permanent');
  perform pg_temp.ref_reject(format('delete from fieldrush_referral_private.links where referred_profile_id=%L',owner),'permanent');
  update public.profiles set username='renamed.referrer' where id=friend;
  perform pg_temp.ref_expect(public.get_fieldrush_referrals()#>>'{referrer,id}'=friend::text
    and public.get_fieldrush_referrals()#>>'{referrer,username}'='renamed.referrer','link follows stable player identity after username change');
  perform public.claim_fieldrush_referral_code('RENAMED.REFERRER',friend);
  perform pg_temp.ref_expect((select to_jsonb(l)=before_link from fieldrush_referral_private.links l where referred_profile_id=owner),
    'retry with changed username retains the same permanent identity link');
  perform set_config('request.jwt.claim.sub',other::text,true);
  perform pg_temp.ref_expect(public.check_fieldrush_referral_code('RENAMED.REFERRER')->>'id'=friend::text,'period in username remains significant');
  perform pg_temp.ref_reject('select public.check_fieldrush_referral_code(''renamedreferrer'')','couldn’t find');
  -- A test-only clock fixture moves the protected launch timestamp inside this
  -- rollback transaction; application roles have no such permission.
  alter table fieldrush_referral_private.launch disable trigger immutable_referral_launch;
  update fieldrush_referral_private.launch set launched_at=statement_timestamp()-interval '30 days';
  update fieldrush_private.accounts set onboarding_completed_at=statement_timestamp()-interval '7 days' where user_id=other;
  result:=public.get_fieldrush_referrals();
  perform pg_temp.ref_expect(result->>'can_add_code'='false' and result->>'own_code' is not null,'exact seven-day boundary closes entry but preserves sharing');
  perform pg_temp.ref_reject('select public.check_fieldrush_referral_code(''renamed.referrer'')','window has closed');
  perform pg_temp.ref_reject(format('select public.claim_fieldrush_referral_code(''renamed.referrer'',%L)',friend),'window has closed');
  update fieldrush_private.accounts set onboarding_completed_at=statement_timestamp()-interval '6 days 23 hours 59 minutes' where user_id=other;
  perform pg_temp.ref_expect(public.get_fieldrush_referrals()->>'can_add_code'='true','just before seven-day boundary remains eligible');
  update fieldrush_private.accounts set onboarding_completed_at=statement_timestamp()-interval '8 days' where user_id=other;
  perform pg_temp.ref_expect(public.get_fieldrush_referrals()->>'can_add_code'='false','after seven-day boundary remains closed');
  update fieldrush_referral_private.launch set launched_at=launch_time;
  alter table fieldrush_referral_private.launch enable trigger immutable_referral_launch;
  perform set_config('request.jwt.claim.sub',owner::text,true);
  update fieldrush_private.accounts set onboarding_completed_at=now()-interval '90 days' where user_id=owner;
  perform pg_temp.ref_expect(public.get_fieldrush_referrals()->>'own_code'=upper(owner_code),'linked older player still shares own code');
end $$;

-- Exercise real referee start/finish/reopen paths with FREE bookings. Presence,
-- not payment and not the ten-minute SR threshold, earns exactly one point.
do $$
declare actor uuid:=pg_temp.ref_player(); login uuid:=gen_random_uuid(); first_referrer uuid:=pg_temp.ref_player();
  second_referrer uuid:=pg_temp.ref_player(); players uuid[]:=array[]::uuid[]; game uuid; game2 uuid; zero_game uuid;
  i integer; response jsonb; token text; reviewed jsonb; ordered uuid[]; old_token text; extra uuid;
  extra2 uuid; extra3 uuid; game3 uuid; game_revision integer;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(actor,'Referral admin','+15555989999','admin',true);
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(login,login||'@ref-staff.example.test',now(),'{"fieldrush_account_type":"staff"}');
  update public.referee_profiles set auth_user_id=login,email=login||'@ref-staff.example.test' where profile_id=actor;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable referral policy.',now(),actor from public.reliability_policy_versions order by version limit 1;
  perform public.admin_set_season_zero_policy(actor,true,'Disposable referral verification only.');
  for i in 1..4 loop players:=array_append(players,pg_temp.ref_player()); end loop;
  game:=pg_temp.ref_game(actor,players);
  perform public.referee_season_zero_action(actor,game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=game;
  perform public.referee_finish_season_zero_match(actor,game,gen_random_uuid(),1);
  perform pg_temp.ref_expect((select count(*)=4 from fieldrush_referral_private.attended_games where game_id=game),
    'four verified attendees of a short FREE game each qualify');
  perform pg_temp.ref_expect(not exists(select 1 from public.open_queue_bookings where game_id=game and payment_intent_id is not null),
    'qualification fixture has no payment-intent evidence');
  response:=pg_temp.ref_claim(players[1],first_referrer);
  perform pg_temp.ref_expect(response->>'referrer_credited'='true','linked screen reports retrospective point truthfully');
  perform pg_temp.ref_claim(players[2],first_referrer);
  perform pg_temp.ref_claim(players[3],second_referrer);
  perform pg_temp.ref_claim(players[4],second_referrer);
  perform set_config('request.jwt.claim.sub',first_referrer::text,true);
  response:=public.get_fieldrush_referrals();
  perform pg_temp.ref_expect(response->>'referral_count'='2' and response->>'waiting_count'='0','prior completed game awards +1 immediately for each referred friend');
  perform pg_temp.ref_expect(response->>'rank'='1' and response->>'needs_review'='true','equal referral and game totals require admin review');
  perform pg_temp.ref_expect((select count(*)=2 from fieldrush_referral_private.links where referrer_profile_id=first_referrer),
    'one point per referred person rather than one per game/track');
  response:=public.admin_get_fieldrush_referrals(actor);
  token:=response#>>'{tie_groups,0,evidence_token}';
  ordered:=array[second_referrer,first_referrer];
  perform pg_temp.ref_reject(format('select public.admin_review_fieldrush_referral_tie(%L,%L,%L::uuid[],%L)',actor,token,
    array[first_referrer,first_referrer],'A detailed verification reason.'),'exactly once');
  perform pg_temp.ref_reject(format('select public.admin_review_fieldrush_referral_tie(%L,%L,%L::uuid[],%L)',actor,token,ordered,'short'),'10 and 2000');
  reviewed:=public.admin_review_fieldrush_referral_tie(actor,token,ordered,'Verified tied players and selected this complete ordering.');
  perform pg_temp.ref_expect(reviewed#>>'{tie_groups,0,resolved}'='true'
    and (select rank=1 and not needs_review from fieldrush_referral_private.ranked where id=second_referrer)
    and (select rank=2 and not needs_review from fieldrush_referral_private.ranked where id=first_referrer),'admin review resolves exactly the current tied group');
  perform public.admin_review_fieldrush_referral_tie(actor,token,ordered,'Verified tied players and selected this complete ordering.');
  perform pg_temp.ref_reject(format('select public.admin_review_fieldrush_referral_tie(%L,%L,%L::uuid[],%L)',actor,token,array[first_referrer,second_referrer],
    'A stale second administrator cannot overwrite this decision.'),'already reviewed');
  perform pg_temp.ref_expect((select count(*)=1 from public.admin_audit_events where action='REFERRAL_TIE_REVIEWED'),
    'tie decision writes an administrator audit record');
  perform pg_temp.ref_reject(format('select public.admin_get_fieldrush_referrals(%L)',first_referrer),'administrator access');
  old_token:=token;
  -- More games by the referrer beats referred-player totals at equal points.
  game2:=pg_temp.ref_game(actor,array[first_referrer,second_referrer,players[1],players[3]]);
  perform public.referee_season_zero_action(actor,game2,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(array[first_referrer,second_referrer,players[1]])));
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=game2;
  -- second_referrer is checked in but not in the lineup: showing up still counts.
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null,outcome='NO_SHOW'
    where open_queue_game_id=game2 and profile_id=second_referrer;
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null,outcome=null,finalized_at=null
    where open_queue_game_id=game2 and profile_id=players[3];
  perform public.referee_finish_season_zero_match(actor,game2,gen_random_uuid(),1);
  perform pg_temp.ref_expect((select rank=1 and games_played=1 from fieldrush_referral_private.ranked where id=first_referrer)
    and (select rank=2 and games_played=0 from fieldrush_referral_private.ranked where id=second_referrer),
    'referrer games are first tiebreak; no-show and booked-only players do not count');
  perform pg_temp.ref_reject(format('select public.admin_review_fieldrush_referral_tie(%L,%L,%L::uuid[],%L)',actor,old_token,ordered,
    'Do not reuse an obsolete ordering after evidence changed.'),'standings changed');
  perform pg_temp.ref_expect((select count(*)=1 from fieldrush_referral_private.tie_reviews),'stale review is not recorded');
  -- Removing check-in does not erase genuine positive authoritative play.
  update public.match_attendance_records set checked_in_at=null,checked_in_by=null,outcome=null,finalized_at=null
    where open_queue_game_id=game2 and profile_id=players[1];
  perform pg_temp.ref_expect((select count(*)=1 from fieldrush_referral_private.attended_games where game_id=game2 and profile_id=players[1]),
    'verified playing time also proves attendance without a remaining check-in');
  perform public.referee_reopen_season_zero_match(actor,game,gen_random_uuid(),2);
  perform pg_temp.ref_expect((select referral_count=1 from fieldrush_referral_private.scores where id=first_referrer)
    and (select referral_count=0 from fieldrush_referral_private.scores where id=second_referrer),
    'reopening removes incomplete-game credits without duplicating surviving appearances');
  perform public.referee_finish_season_zero_match(actor,game,gen_random_uuid(),3);
  perform pg_temp.ref_expect((select referral_count=2 from fieldrush_referral_private.scores where id=first_referrer)
    and (select referral_count=2 from fieldrush_referral_private.scores where id=second_referrer),'refinish restores each point exactly once');
  -- Same own-game total now falls through to the referred players' combined
  -- attendance, not signup time, arbitrary UUID ordering, or payment volume.
  extra:=pg_temp.ref_player(); extra2:=pg_temp.ref_player(); extra3:=pg_temp.ref_player();
  game3:=pg_temp.ref_game(actor,array[second_referrer,extra,extra2,extra3]);
  perform public.referee_season_zero_action(actor,game3,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(array[second_referrer,extra,extra2])));
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=game3;
  perform public.referee_finish_season_zero_match(actor,game3,gen_random_uuid(),1);
  perform pg_temp.ref_expect((select rank=1 and games_played=1 and referred_games_played=3 from fieldrush_referral_private.ranked where id=first_referrer)
    and (select rank=2 and games_played=1 and referred_games_played=2 from fieldrush_referral_private.ranked where id=second_referrer),
    'referred players combined games break an equal own-games tie');
  perform pg_temp.ref_expect((select count(*)=1 from fieldrush_referral_private.attended_games where game_id=game3 and profile_id=extra3)
    and (select not counted_as_played from public.player_rating_events where source_id=game3 and profile_id=extra3),
    'referee-confirmed attendance counts even without an SR-counted appearance');
  -- A free zero-second session never becomes a completed attended game.
  zero_game:=pg_temp.ref_game(actor,array[extra,extra2]);
  perform public.referee_season_zero_action(actor,zero_game,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(array[extra,extra2])));
  update public.open_queue_clock_states set accumulated_seconds=0,started_at=clock_timestamp()+interval '1 hour' where game_id=zero_game;
  perform public.referee_finish_season_zero_match(actor,zero_game,gen_random_uuid(),1);
  perform pg_temp.ref_expect(not exists(select 1 from fieldrush_referral_private.attended_games where game_id=zero_game),
    'zero-play result does not qualify despite check-ins');
  -- Legitimate positive-time forfeits count; void/no-contest results do not.
  perform public.admin_resolve_season_zero_match(actor,game3,gen_random_uuid(),2,
    '{"status":"forfeit_confirmed","winner":"A","reason":"Verify an official positive-duration played forfeit."}');
  perform pg_temp.ref_expect((select count(*)=4 from fieldrush_referral_private.attended_games where game_id=game3),
    'positive-time official played forfeit qualifies for verified attendees');
  perform public.admin_resolve_season_zero_match(actor,game3,gen_random_uuid(),3,
    '{"status":"no_contest","winner":null,"reason":"Verify withdrawn no-contest attendance does not qualify."}');
  perform pg_temp.ref_expect(not exists(select 1 from fieldrush_referral_private.attended_games where game_id=game3),
    'official no-contest correction withdraws qualification');
  -- No dependence on lifetime SR reset filters or hidden placement ratings.
  perform pg_temp.ref_expect((fieldrush_referral_private.person(first_referrer)->>'rating_visible')::boolean=false, 'hidden placement does not expose division in referral lookup');
exception when others then
  -- No exception swallowing: preserve original test context on failures.
  raise;
end $$;

-- A tie spanning the fifth prize place cannot silently pick winners by UUID.
-- An administrator's complete ordering is the final, audited tiebreak only.
do $$
declare actor uuid; referrers uuid[]:=array[]::uuid[]; friends uuid[]:=array[]::uuid[];
  i integer; game uuid; token text; members uuid[]; response jsonb;
begin
  select profile_id into actor from public.referee_profiles where display_name='Referral admin';
  for i in 1..6 loop referrers:=array_append(referrers,pg_temp.ref_player()); end loop;
  for i in 1..12 loop friends:=array_append(friends,pg_temp.ref_player()); end loop;
  for i in 0..2 loop
    game:=pg_temp.ref_game(actor,friends[(i*4+1):(i*4+4)]);
    perform public.referee_season_zero_action(actor,game,gen_random_uuid(),0,
      jsonb_build_object('action','START','participant_ids',to_jsonb(friends[(i*4+1):(i*4+4)])));
    update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=game;
    perform public.referee_finish_season_zero_match(actor,game,gen_random_uuid(),1);
  end loop;
  for i in 1..6 loop
    perform pg_temp.ref_claim(friends[i*2-1],referrers[i]);
    perform pg_temp.ref_claim(friends[i*2],referrers[i]);
  end loop;
  select evidence_token into token from fieldrush_referral_private.ranked where id=referrers[1];
  select member_ids into members from fieldrush_referral_private.tie_groups where evidence_token=token;
  perform pg_temp.ref_expect(cardinality(members)>=6 and
    (select bool_and(needs_review and not prize_eligible) from fieldrush_referral_private.ranked where evidence_token=token),
    'unresolved tie crossing prize cutoff withholds affected prize places');
  perform set_config('request.jwt.claim.sub',referrers[1]::text,true);
  response:=public.get_fieldrush_referral_leaderboard();
  perform pg_temp.ref_expect(jsonb_array_length(response->'prize_entries')=1
    and (response->>'qualified_total')::integer=8,'unresolved tie does not advertise arbitrary fifth-place winner');
  members:=(select array_agg(x order by n desc) from unnest(members) with ordinality a(x,n));
  perform public.admin_review_fieldrush_referral_tie(actor,token,members,'Reviewed the exact remaining tied candidates for the prize cutoff.');
  response:=public.get_fieldrush_referral_leaderboard();
  perform pg_temp.ref_expect(jsonb_array_length(response->'prize_entries')=5
    and jsonb_array_length(response->'entries')=3,
    'explicit final tiebreak yields exactly five prize places and everyone else');
  perform pg_temp.ref_expect((select count(distinct rank)=cardinality(members) and not bool_or(needs_review)
    from fieldrush_referral_private.ranked where evidence_token=token),'review gives distinct exact ranks within the original tied group');
end $$;

-- Launch grace includes older players whose first attendance predates this
-- season. Points are lifetime-first-attendance based; game tiebreaks are seasonal.
do $$
declare actor uuid; owner uuid:=pg_temp.ref_player(); old_friend uuid:=pg_temp.ref_player();
  opponent uuid:=pg_temp.ref_player(); historical_game uuid; next_game uuid; old_kickoff timestamptz;
  response jsonb; contest_id text; earned timestamptz; saved_window text;
begin
  select profile_id into actor from public.referee_profiles where display_name='Referral admin';
  select id,starts_at-interval '1 day' into contest_id,old_kickoff from fieldrush_referral_private.competition;
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',date_trunc('day',(old_kickoff-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable historical referral policy.',now(),actor
      from public.reliability_policy_versions order by version limit 1;
  update fieldrush_private.accounts set onboarding_completed_at=old_kickoff-interval '30 days' where user_id=old_friend;
  -- Isolated fixture only: historical matches cannot be started now through
  -- the 24-hour operational window. Save/restore only that clock gate while
  -- using the real assignment, roster, attendance and completion writers.
  saved_window:=pg_get_functiondef('fieldrush_rating_private.solo_start_window_allows(timestamptz,timestamptz)'::regprocedure);
  execute $fixture$create or replace function fieldrush_rating_private.solo_start_window_allows(
    starts_at_to_use timestamptz,at_time_to_use timestamptz) returns boolean language sql immutable strict
    set search_path=public,pg_temp as 'select true'$fixture$;
  historical_game:=pg_temp.ref_game(actor,array[old_friend,opponent],old_kickoff);
  perform public.referee_season_zero_action(actor,historical_game,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(array[old_friend,opponent])));
  execute saved_window;
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=historical_game;
  perform public.referee_finish_season_zero_match(actor,historical_game,gen_random_uuid(),1);
  -- This rollback-only fixture assigns the official finish event its historical
  -- wall time after exercising the actual start/finish/attendance writers.
  update public.open_queue_events set occurred_at=old_kickoff+interval '129 seconds'
    where game_id=historical_game and event_type='MATCH_ENDED';
  perform pg_temp.ref_expect((select season_id is distinct from contest_id from public.open_queue_games where id=historical_game)
    and not exists(select 1 from fieldrush_referral_private.season_attendance where game_id=historical_game),
    'previous-season match stays outside current-season game tiebreak totals');
  response:=pg_temp.ref_claim(old_friend,owner);
  perform pg_temp.ref_expect(response->>'referrer_credited'='true',
    'old account linking after a previous-season first game credits referrer immediately');
  select earned_at into earned from fieldrush_referral_private.link_credits where referred_profile_id=old_friend;
  perform pg_temp.ref_expect(earned=(select claimed_at from fieldrush_referral_private.links where referred_profile_id=old_friend),
    'retroactive qualification time is current claim time, not historical match time');
  perform set_config('request.jwt.claim.sub',owner::text,true);
  response:=public.get_fieldrush_referrals();
  perform pg_temp.ref_expect(response->>'referral_count'='1' and response->>'waiting_count'='0'
    and response->>'referred_games_played'='0' and response#>>'{referrals,0,qualified}'='true',
    'summary and friend list agree on lifetime credit while seasonal tiebreak remains zero');
  next_game:=pg_temp.ref_game(actor,array[old_friend,opponent]);
  perform public.referee_season_zero_action(actor,next_game,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(array[old_friend,opponent])));
  update public.open_queue_clock_states set accumulated_seconds=129,started_at=clock_timestamp()+interval '1 hour' where game_id=next_game;
  perform public.referee_finish_season_zero_match(actor,next_game,gen_random_uuid(),1);
  response:=public.get_fieldrush_referrals();
  perform pg_temp.ref_expect(response->>'referral_count'='1' and response->>'referred_games_played'='1',
    'later current-season game changes tiebreak games but never awards a second referral point');
end $$;

-- The API returns a bounded JSON page rather than relying on PostgREST's
-- default 1000-row cap. Each page remains private to its authenticated owner.
do $$
declare owner uuid:=pg_temp.ref_player(); outsider uuid:=pg_temp.ref_player(); response jsonb; player uuid;
  launch_time timestamptz; i integer; count_before integer; timed_at timestamptz; credited_owner uuid; credited_friend uuid;
begin
  timed_at:=clock_timestamp();
  for i in 1..1005 loop
    player:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(player,'155558'||lpad(i::text,5,'0'),now());
    insert into public.profiles(id,auth_user_id,display_name,username)
      values(player,player,'Referral Page','ref_page_'||i);
    insert into fieldrush_private.accounts(user_id,first_name,last_name,username,email,date_of_birth,status,onboarding_completed_at)
      values(player,'Referral','Page','ref_page_'||i,'ref_page_'||i||'@example.test','2000-01-01','active',now());
    insert into fieldrush_referral_private.links(referred_profile_id,referrer_profile_id) values(player,owner);
  end loop;
  insert into referral_timings values('seed_1005',extract(epoch from clock_timestamp()-timed_at)*1000);
  timed_at:=clock_timestamp();
  perform set_config('request.jwt.claim.sub',owner::text,true);
  response:=public.get_fieldrush_referrals();
  insert into referral_timings values('read_summary_1005',extract(epoch from clock_timestamp()-timed_at)*1000);
  perform pg_temp.ref_expect(response->>'referrals_total'='1005' and jsonb_array_length(response->'referrals')=50
    and response->>'referrals_next_offset'='50' and response->>'waiting_count'='1005',
    'summary exposes real total beyond1000 while returning first50');
  response:=public.get_fieldrush_referred_players(1000,100);
  perform pg_temp.ref_expect(response->>'total'='1005' and jsonb_array_length(response->'entries')=5
    and response->'next_offset'='null'::jsonb,'final page retrieves referred players beyond1000');
  perform pg_temp.ref_expect(not exists(select 1 from jsonb_array_elements(response->'entries') v
    where v ? 'email' or v ? 'phone' or v ? 'date_of_birth' or (v->>'qualified')::boolean),
    'own referral rows contain no contact details and unplayed signups earn no credit');
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  response:=public.get_fieldrush_referred_players(0,100);
  perform pg_temp.ref_expect(response->>'total'='0' and response->'entries'='[]'::jsonb,
    'another player cannot read the owners referred-player list');
  perform pg_temp.ref_reject('select public.get_fieldrush_referred_players(-1,50)','valid referral page');
  perform pg_temp.ref_reject('select public.get_fieldrush_referral_leaderboard(0,101)','valid referral leaderboard page');
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.ref_reject('select public.get_fieldrush_referrals()','session has expired');
  -- Deletion hides identity; it does not erase an already earned referral
  -- point from the still-active referrer or allow reassignment.
  select l.referred_profile_id,l.referrer_profile_id into credited_friend,credited_owner
    from fieldrush_referral_private.links l join fieldrush_referral_private.season_attendance a on a.profile_id=l.referred_profile_id limit 1;
  select referral_count into count_before from fieldrush_referral_private.scores where id=credited_owner;
  update fieldrush_private.accounts set status='deletion_pending' where user_id=credited_friend;
  perform pg_temp.ref_expect((select referral_count=count_before from fieldrush_referral_private.scores where id=credited_owner),
    'referred account deletion preserves already earned attendance credit');
  perform set_config('request.jwt.claim.sub',credited_owner::text,true);
  response:=public.get_fieldrush_referred_players(0,100);
  perform pg_temp.ref_expect(exists(select 1 from jsonb_array_elements(response->'entries') e
    where e->>'id'=credited_friend::text and e->>'name'='Deleted player' and e->'username'='null'::jsonb and e->>'qualified'='true'),
    'own list retains counted friend as an anonymized tombstone');
  -- The deleted referrer itself is excluded from public competition rows.

  select referred_profile_id into player from fieldrush_referral_private.links where referrer_profile_id=owner limit 1;
  update fieldrush_private.accounts set status='deletion_pending' where user_id=owner;
  perform set_config('request.jwt.claim.sub',player::text,true);
  response:=public.get_fieldrush_referrals();
  perform pg_temp.ref_expect(response#>>'{referrer,name}'='Deleted player' and response#>'{referrer,username}'='null'::jsonb
    and response->>'can_add_code'='false','deleted referrer is anonymized while link remains permanent');
end $$;

select pg_temp.ref_expect(not has_function_privilege('anon','public.get_fieldrush_referrals()','EXECUTE')
  and not has_function_privilege('authenticated','public.admin_get_fieldrush_referrals(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.admin_review_fieldrush_referral_tie(uuid,text,uuid[],text)','EXECUTE'),
  'anonymous/private-admin RPC privileges are denied');
select pg_temp.ref_expect(not has_table_privilege('authenticated','fieldrush_referral_private.links','SELECT,INSERT,UPDATE,DELETE')
  and not has_table_privilege('service_role','fieldrush_referral_private.links','INSERT,UPDATE,DELETE')
  and not has_function_privilege('authenticated','fieldrush_referral_private.person(uuid)','EXECUTE'),
  'no direct referral writes or arbitrary private player lookup');
select count(*) as passed_checks,(select jsonb_agg(to_jsonb(t)) from referral_timings t) as timings from referral_checks;
