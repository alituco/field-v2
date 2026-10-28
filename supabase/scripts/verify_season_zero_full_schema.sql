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

-- Disposable/local full-schema smoke only. Fixture timestamps/clock progression
-- are test-owned; no public timing bypass is introduced. Everything rolls back.
begin;
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create function pg_temp.sr_expect(ok boolean,message text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Full-schema Season 0: %',message; end if; end;
$$;
create temporary table sr_smoke_metrics(label text,matches integer,elapsed_ms numeric,max_finish_ms numeric);
create function pg_temp.sr_smoke_game(admin_id uuid,players uuid[],fixture_number integer) returns uuid language plpgsql as $$
declare match_id uuid; i integer; role_to_use text;
  kickoff timestamptz:=current_setting('fieldrush.test_smoke_anchor')::timestamptz-make_interval(mins=>fixture_number+3);
begin
  perform set_config('field.match_resolution_control_plane','on',true);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('OPEN','Disposable SR connected benchmark',kickoff,kickoff+interval '1 hour',0,6,6) returning id into match_id;
  for i in 1..14 loop
    role_to_use:=case when i in (1,8) then 'GK' when (i-1)%7 between 1 and 3 then 'DEF' else 'ATT' end;
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method)
      values(match_id,players[i],role_to_use,'CONFIRMED',0,0,'FREE');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',match_id);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=admin_id,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=match_id;
  perform set_config('field.match_resolution_control_plane','off',true);
  perform public.referee_assign_season_zero_teams(admin_id,match_id,gen_random_uuid());
  return match_id;
end;
$$;
do $$
declare players uuid[]:=array[]::uuid[]; player uuid; admin_id uuid; match_id uuid; cancel_game uuid; winner_player uuid; loser_player uuid;
  i integer; role_to_use text; payload jsonb; request uuid:=gen_random_uuid(); before_tracks jsonb; after_tracks jsonb;
  before_refunds integer; after_refunds integer; started timestamptz; elapsed_ms numeric; expected_refund integer; cancel_request uuid:=gen_random_uuid();
  benchmark_count integer:=coalesce(nullif(current_setting('fieldrush.test_benchmark_matches',true),'')::integer,50);
  finish_ms numeric; max_finish_ms numeric:=0; benchmark_started timestamptz;
  injury_game uuid; injured_player uuid; injury_response jsonb; private_before jsonb; injured_count integer; owner_preview jsonb;
  public_player jsonb; public_event jsonb; effective_event jsonb; benchmark_first uuid; benchmark_second uuid;
  fixture_anchor timestamptz:=date_trunc('minute',clock_timestamp());
begin
  -- One fixed test-owned anchor prevents duplicate starts if the 50-match run
  -- crosses a wall-clock minute between consecutive fixture creations.
  perform set_config('fieldrush.test_smoke_anchor',fixture_anchor::text,true);
  for i in 1..15 loop
    player:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at) values(player,'15558817'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',player::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Smoke','last_name','Player',
      'username','sr_smoke_'||lpad(i::text,3,'0'),'date_of_birth','2000-01-01','email','smoke'||i||'@example.test',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
    if i=15 then admin_id:=player; else players:=array_append(players,player); end if;
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(admin_id,'Smoke Admin','+15558817015','admin',true);
  perform pg_temp.bind_staff_login_for_verification(admin_id);
  -- Fresh migrations publish their initial policy "now". This rollback-only
  -- clone supplies unchanged existing financial rules to our past kickoff.
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_by,published_at)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      (date_trunc('day',clock_timestamp() at time zone 'Asia/Bahrain')-interval '1 day') at time zone 'Asia/Bahrain',
      config,'Disposable unchanged policy for past fixture clock',admin_id,clock_timestamp()
    from public.reliability_policy_versions where state='PUBLISHED' order by effective_from desc limit 1;
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable full-schema SR verification only.');
  -- Signed pre-existing SR exercises the actual widened storage and native
  -- event constraints. Initial assessment audit remains its original 1000.
  update public.fieldrush_player_rating_tracks set skill_rating=-10 where profile_id=any(players);
  perform set_config('field.match_resolution_control_plane','on',true);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('FULL','Disposable SR full schema',fixture_anchor-interval '1 minute',fixture_anchor+interval '59 minutes',0,6,6) returning id into match_id;
  for i in 1..14 loop
    role_to_use:=case when i in (1,8) then 'GK' when (i-1)%7 between 1 and 3 then 'DEF' else 'ATT' end;
    insert into public.open_queue_bookings(game_id,profile_id,role,team,status,amount_paid_fils,base_amount_fils,payment_method)
      values(match_id,players[i],role_to_use,case when i<=7 then 'WHITE' else 'BLACK' end,'CONFIRMED',0,0,'FREE');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',match_id);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=admin_id,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=match_id;
  perform set_config('field.match_resolution_control_plane','off',true);
  perform public.referee_assign_season_zero_teams(admin_id,match_id,gen_random_uuid());
  select b.profile_id into winner_player from public.open_queue_bookings b where b.game_id=match_id and b.role='GK' and b.team='WHITE';
  select b.profile_id into loser_player from public.open_queue_bookings b where b.game_id=match_id and b.role='GK' and b.team='BLACK';
  perform public.referee_season_zero_action(admin_id,match_id,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  insert into public.open_queue_goals(game_id,team,profile_id,minute) values(match_id,'WHITE',winner_player,1);
  update public.open_queue_clock_states c set accumulated_seconds=3600,started_at=clock_timestamp() where c.game_id=match_id;
  started:=clock_timestamp();
  payload:=public.referee_finish_season_zero_match(admin_id,match_id,request,1);
  elapsed_ms:=extract(epoch from clock_timestamp()-started)*1000;
  insert into sr_smoke_metrics values('first_native_finish',1,round(elapsed_ms,2),round(elapsed_ms,2));
  perform pg_temp.sr_expect(payload->>'settlement_status'='RATED','actual finalization rates the match');
  -- Match the hosted completion verifier's real persisted sources. Its legacy
  -- early-admin-test audit is deliberately absent on this ordinary S0 path.
  perform pg_temp.sr_expect((select
      s.game_id=match_id and s.policy_id='field-sr-season0-v2' and s.lifecycle='FINAL'
      and s.rating_status='completed' and s.settlement_status='RATED'
      and s.scheduled_seconds=extract(epoch from(g.ends_at-g.starts_at))
      and s.played_seconds>=s.scheduled_seconds
      and fieldrush_rating_private.solo_start_window_allows(g.starts_at,s.started_at)
      and c.status='ENDED' and c.started_at is null
      and c.duration_seconds=s.scheduled_seconds and c.accumulated_seconds=s.played_seconds
      and (public.get_season_zero_match_state(admin_id,match_id)->>'elapsed_seconds')::integer=s.played_seconds
      and (select count(*)=1 from public.open_queue_events e where e.game_id=match_id
        and e.event_type='MATCH_STARTED' and e.occurred_at=s.started_at)
      and (select count(*)=1 from public.open_queue_events e where e.game_id=match_id
        and e.event_type='MATCH_ENDED' and e.minute*60+e.second=s.played_seconds)
    from fieldrush_rating_private.season_zero_matches s
    join public.open_queue_games g on g.id=s.game_id
    join public.open_queue_clock_states c on c.game_id=s.game_id where s.game_id=match_id),
    'normal completion exposes consistent S0 participation, event and stopped-clock evidence');
  perform pg_temp.sr_expect((select count(*)=14 from public.player_rating_events e where e.source_id=match_id),'14 native ledger rows');
  perform pg_temp.sr_expect((select skill_rating=30 and matches_played=1 from public.fieldrush_player_rating_tracks
    where profile_id=winner_player and rating_track='GOALKEEPER'),'first winner +40, keeper count1');
  perform pg_temp.sr_expect((select skill_rating=-50 from public.fieldrush_player_rating_tracks
    where profile_id=loser_player and rating_track='GOALKEEPER'),'negative loser SR persists without clamp');
  perform pg_temp.sr_expect((select skill_rating=-10 and matches_played=0 from public.fieldrush_player_rating_tracks
    where profile_id=winner_player and rating_track='OUTFIELD'),'other rating pool untouched');
  perform set_config('request.jwt.claim.sub',winner_player::text,true);
  owner_preview:=public.get_fieldrush_player_ratings(winner_player,
    (select starts_on from public.fieldrush_seasons where lifecycle='ACTIVE'),
    (select ends_on from public.fieldrush_seasons where lifecycle='ACTIVE'));
  perform pg_temp.sr_expect(owner_preview#>>'{placement_predictions,GOALKEEPER,skill_rating}'='30'
    and owner_preview#>>'{placement_predictions,GOALKEEPER,last_change}'='40'
    and owner_preview#>>'{placement_predictions,OUTFIELD,skill_rating}'='-10','owner sees canonical independent placement predictions');
  perform pg_temp.sr_expect(owner_preview#>'{ratings,GOALKEEPER,skill_rating}'='null'::jsonb,'owner prediction does not unmask public SR');
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  owner_preview:=public.get_fieldrush_player_ratings(winner_player,
    (select starts_on from public.fieldrush_seasons where lifecycle='ACTIVE'),
    (select ends_on from public.fieldrush_seasons where lifecycle='ACTIVE'));
  perform pg_temp.sr_expect(not owner_preview ? 'placement_predictions','other viewers cannot see a placement prediction');
  select p into public_player from jsonb_array_elements(public.get_open_queue_match_detail(match_id)->'players') p
    where p->>'id'=winner_player::text;
  perform pg_temp.sr_expect(public_player->>'counted_as_played'='true' and (public_player->>'actual_played_seconds')::integer=3600,
    'public nested lineup projects the winner actual counted appearance');
  perform pg_temp.sr_expect(public_player->>'rating_visible'='false' and public_player->'rating_before'='null'::jsonb
    and public_player->'rating_at_match_start'='null'::jsonb and public_player->'rating_after'='null'::jsonb
    and public_player->'rating_change'='null'::jsonb and public_player->'rating_at_team_assignment'='null'::jsonb,
    'public first-game eligibility does not reveal any numeric SR snapshot');
  select e into public_event from jsonb_array_elements(public.get_player_rating_history(winner_player,100)->'events') e
    where e->>'source_id'=match_id::text;
  perform pg_temp.sr_expect(public_event->>'counted_as_played'='true' and public_event->'rating_before'='null'::jsonb
    and public_event->'rating_after'='null'::jsonb and public_event->'rating_change'='null'::jsonb,
    'public first-game history retains counted eligibility while hiding numbers');
  perform pg_temp.sr_expect(public.referee_finish_season_zero_match(admin_id,match_id,request,999)=payload,'duplicate finish exact response');
  payload:=public.admin_resolve_season_zero_match(admin_id,match_id,gen_random_uuid(),2,
    '{"status":"completed","winner":"B","white_score":0,"black_score":1,"reason":"Verified actual-score reversal in disposable smoke."}');
  perform pg_temp.sr_expect((select skill_rating=-50 from public.fieldrush_player_rating_tracks
    where profile_id=winner_player and rating_track='GOALKEEPER'),'native rated guard permits audited correction');
  payload:=public.admin_resolve_season_zero_match(admin_id,match_id,gen_random_uuid(),3,
    '{"status":"no_contest","winner":null,"reason":"External interruption verified, rating-only result void."}');
  perform pg_temp.sr_expect(payload->>'settlement_status'='NOT_RATED','void is not rated');
  perform pg_temp.sr_expect((select count(*)=0 from public.player_rating_events e where e.source_id=match_id),'void removes only active ledger');
  perform pg_temp.sr_expect((select bool_and(skill_rating=-10 and matches_played=0) from public.fieldrush_player_rating_tracks where profile_id=any(players)),
    'void restores original SR and lifetime counts');
  select p into public_player from jsonb_array_elements(public.get_open_queue_match_detail(match_id)->'players') p
    where p->>'id'=winner_player::text;
  perform pg_temp.sr_expect(public_player->>'rating_status'='NOT_RATED' and public_player->>'counted_as_played'='false'
    and public_player->'rating_change'='null'::jsonb,'public void does not retain a counted appearance or stale award');
  -- Cancellation reuses the actual established financial policy, once only.
  perform set_config('field.match_resolution_control_plane','on',true);
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('OPEN','Disposable SR cancelled fixture',fixture_anchor-interval '2 minutes',
      fixture_anchor+interval '58 minutes',10000,6,6) returning id into cancel_game;
  for i in 1..14 loop
    role_to_use:=case when i in (1,8) then 'GK' when (i-1)%7 between 1 and 3 then 'DEF' else 'ATT' end;
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
      values(cancel_game,players[i],role_to_use,'CONFIRMED',10000,10000,'MOCK','PAID');
  end loop;
  perform public.ensure_match_attendance_records('SOLO',cancel_game);
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',checked_in_by=admin_id,
    check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=cancel_game;
  perform set_config('field.match_resolution_control_plane','off',true);
  perform public.referee_assign_season_zero_teams(admin_id,cancel_game,gen_random_uuid());
  perform public.referee_season_zero_action(admin_id,cancel_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  select (policy_snapshot#>>'{solo,outcomes,fieldCancelled,refundBps}')::integer into expected_refund
    from public.match_reliability_terms where open_queue_game_id=cancel_game;
  select count(*) into before_refunds from public.field_wallet_transactions;
  payload:=public.admin_resolve_season_zero_match(admin_id,cancel_game,cancel_request,1,
    '{"status":"cancelled","winner":null,"reason":"Verified unsafe venue requires existing Field cancellation policy."}');
  perform pg_temp.sr_expect(payload->>'settlement_status'='NOT_RATED','financial cancellation is NOT_RATED');
  perform pg_temp.sr_expect((select status='CANCELLED' and operational_state='RESOLVED' from public.open_queue_games where id=cancel_game),
    'financial cancellation is publicly CANCELLED, not FINAL 0-0');
  perform pg_temp.sr_expect((select count(*)=14 and bool_and(status='CANCELLED' and refund_amount_fils=expected_refund and team is not null)
    from public.open_queue_bookings b where b.game_id=cancel_game),'existing refund ratio, original roster team evidence retained');
  select count(*) into after_refunds from public.field_wallet_transactions;
  perform pg_temp.sr_expect(after_refunds-before_refunds=14,'actual existing wallet refund ledger credited once per booking');
  perform pg_temp.sr_expect(public.admin_resolve_season_zero_match(admin_id,cancel_game,cancel_request,999,
    '{"status":"cancelled","winner":null,"reason":"Verified unsafe venue requires existing Field cancellation policy."}')=payload,'cancel idempotency exact response');
  perform pg_temp.sr_expect((select count(*)=after_refunds from public.field_wallet_transactions),'cancel retry issues no extra refund');
  perform pg_temp.sr_expect((select bool_and(skill_rating=-10 and matches_played=0) from public.fieldrush_player_rating_tracks where profile_id=any(players)),
    'cancel does not alter SR or counted appearances');
  public_player:=public.get_open_queue_match_detail(cancel_game);
  perform pg_temp.sr_expect(public_player->'white_average_sr'='null'::jsonb and public_player->'black_average_sr'='null'::jsonb
    and public_player->'match_average_sr'='null'::jsonb and public_player->'team_sr_spread'='null'::jsonb,
    'cancelled original hidden participants do not become an empty visible roster leaking team means');
  benchmark_started:=clock_timestamp();
  for i in 1..benchmark_count loop
    match_id:=pg_temp.sr_smoke_game(admin_id,players,i);
    if i=1 then benchmark_first:=match_id; elsif i=2 then benchmark_second:=match_id; end if;
    perform public.referee_season_zero_action(admin_id,match_id,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
    update public.open_queue_clock_states c set accumulated_seconds=3600,started_at=clock_timestamp() where c.game_id=match_id;
    started:=clock_timestamp();
    payload:=public.referee_finish_season_zero_match(admin_id,match_id,gen_random_uuid(),1);
    finish_ms:=extract(epoch from clock_timestamp()-started)*1000;
    max_finish_ms:=greatest(max_finish_ms,finish_ms);
    perform pg_temp.sr_expect(payload->>'settlement_status'='RATED','connected benchmark match rates');
    if i in (1,10,25,50,100) or i=benchmark_count then
      insert into sr_smoke_metrics values('connected_14_player_chain',i,round(extract(epoch from clock_timestamp()-benchmark_started)*1000,2),round(max_finish_ms,2));
    end if;
  end loop;
  perform pg_temp.sr_expect((select matches_played=benchmark_count from public.fieldrush_player_rating_tracks
    where profile_id=winner_player and rating_track='GOALKEEPER'),'connected replay counts exactly once per match');
  injury_game:=pg_temp.sr_smoke_game(admin_id,players,200);
  update public.open_queue_bookings b set amount_paid_fils=10000,base_amount_fils=10000,payment_method='MOCK',payment_status='PAID'
    where b.game_id=injury_game;
  select b.profile_id into injured_player from public.open_queue_bookings b where b.game_id=injury_game and b.role='GK' and b.team='BLACK';
  select matches_played into injured_count from public.fieldrush_player_rating_tracks where profile_id=injured_player and rating_track='GOALKEEPER';
  perform public.referee_season_zero_action(admin_id,injury_game,gen_random_uuid(),0,jsonb_build_object('action','START','participant_ids',to_jsonb(players)));
  update public.open_queue_clock_states c set accumulated_seconds=300,started_at=clock_timestamp() where c.game_id=injury_game;
  select to_jsonb(m) into private_before from fieldrush_rating_private.season_zero_matches m where m.game_id=injury_game;
  injury_response:=public.referee_record_verified_injury(admin_id,'SOLO',injury_game,injured_player,true,false,true,'Verified early injury for financial evidence only.');
  perform pg_temp.sr_expect((select to_jsonb(m)=private_before from fieldrush_rating_private.season_zero_matches m where m.game_id=injury_game),
    'legacy financial injury/shorthanded evidence does not change v2 participation or SR');
  perform public.referee_season_zero_action(admin_id,injury_game,gen_random_uuid(),1,
    jsonb_build_object('action','EXCUSED_LEAVE','profile_id',injured_player,'note','Verified injury; actual departure at five minutes.'));
  update public.open_queue_clock_states c set accumulated_seconds=3600,started_at=clock_timestamp() where c.game_id=injury_game;
  select count(*) into before_refunds from public.field_wallet_transactions;
  payload:=public.referee_finish_season_zero_match(admin_id,injury_game,gen_random_uuid(),2);
  select (policy_snapshot#>>'{injury,incompleteRefundBps}')::integer into expected_refund from public.match_reliability_terms where open_queue_game_id=injury_game;
  perform pg_temp.sr_expect((select count(*)=14 and bool_and(refund_amount_fils=expected_refund) from public.open_queue_bookings b where b.game_id=injury_game),
    'existing early-injury fee-refund policy still runs at v2 completion');
  perform pg_temp.sr_expect((select count(*)-before_refunds=14 from public.field_wallet_transactions),'injury wallet refunds issued once');
  perform pg_temp.sr_expect((select not counted_as_played and rating_change=0 from public.player_rating_events e where e.source_id=injury_game and e.profile_id=injured_player),
    'financial injury evidence cannot fabricate a counted SR appearance below 600 actual seconds');
  perform pg_temp.sr_expect((select matches_played=injured_count from public.fieldrush_player_rating_tracks where profile_id=injured_player and rating_track='GOALKEEPER'),
    'injured keeper lifetime count unchanged');
  select p into public_player from jsonb_array_elements(public.get_open_queue_match_detail(injury_game)->'players') p
    where p->>'id'=injured_player::text;
  perform pg_temp.sr_expect(public_player->>'rating_status'='RATED' and public_player->>'counted_as_played'='false'
    and (public_player->>'actual_played_seconds')::integer=300
    and public_player->>'rating_explanation' like 'No SR change:%This appearance does not count.',
    'public rated match still explains a five-minute noncounted player without medical details');
  select e into public_event from jsonb_array_elements(public.get_player_rating_history(injured_player,100)->'events') e
    where e->>'source_id'=injury_game::text;
  perform pg_temp.sr_expect(public_event->>'counted_as_played'='false' and (public_event->>'actual_played_seconds')::integer=300,
    'public history uses individual participation, not the match-wide RATED flag');
  perform public.apply_open_queue_reliability_rating_adjustments(injury_game);
  perform pg_temp.sr_expect((select count(*)-before_refunds=14 from public.field_wallet_transactions),'financial retry is idempotent');
  if benchmark_second is not null then
    -- Correct an early result only after later results reveal the lifetime pool.
    -- Public nested lineups/history must now use the active replay snapshot,
    -- while original booking kickoff evidence remains immutable.
    perform public.admin_resolve_season_zero_match(admin_id,benchmark_first,gen_random_uuid(),2,
      '{"status":"completed","winner":"A","white_score":1,"black_score":0,"reason":"Verified early result correction tests public replayed snapshots."}');
    select to_jsonb(e) into effective_event from public.player_rating_events e
      where e.source_id=benchmark_second and e.profile_id=winner_player;
    select p into public_player from jsonb_array_elements(public.get_open_queue_match_detail(benchmark_second)->'players') p
      where p->>'id'=winner_player::text;
    perform pg_temp.sr_expect((select b.rating_at_match_start=-10 and b.rating_at_match_start<>(effective_event->>'rating_before')::integer
      from public.open_queue_bookings b where b.game_id=benchmark_second and b.profile_id=winner_player),
      'replay differs from unchanged original booking kickoff evidence');
    perform pg_temp.sr_expect(public_player->>'rating_visible'='true' and public_player->'rating_before'=effective_event->'rating_before'
      and public_player->'rating_at_match_start'=effective_event->'rating_before' and public_player->'rating_after'=effective_event->'rating_after'
      and public_player->'rating_change'=effective_event->'rating_change','revealed public lineup uses effective replayed before/change/after');
    select e into public_event from jsonb_array_elements(public.get_player_rating_history(winner_player,100)->'events') e
      where e->>'source_id'=benchmark_second::text;
    perform pg_temp.sr_expect(public_event->'rating_before'=effective_event->'rating_before' and public_event->'rating_after'=effective_event->'rating_after'
      and public_event->'rating_change'=effective_event->'rating_change','revealed public history agrees with the active corrected ledger');
  end if;
end;
$$;
select * from sr_smoke_metrics order by label,matches;
rollback;
