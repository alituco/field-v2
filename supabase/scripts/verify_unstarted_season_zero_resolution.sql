-- Disposable full-schema regression. Run inside caller-owned BEGIN/ROLLBACK.
-- Synthetic players/payments only; no provider request or hosted data change.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table unstarted_resolution_checks(label text);
create function pg_temp.unstarted_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Unstarted S0 resolution: %',label; end if;
  insert into unstarted_resolution_checks values(label);
end;
$$;
create function pg_temp.unstarted_reject(statement text,message_part text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if position(message_part in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.unstarted_expect(rejected,'rejected: '||message_part);
end;
$$;
create sequence pg_temp.unstarted_person;
create function pg_temp.unstarted_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.unstarted_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(player,'1555448'||lpad(n::text,4,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Unstarted','last_name','Player',
    'username','prestart_check_'||n,'date_of_birth','2000-01-01','email','prestart_'||n||'@example.test',
    'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;
create function pg_temp.unstarted_game(players uuid[],paid boolean,kickoff timestamptz) returns uuid language plpgsql as $$
declare game uuid; player uuid; intent uuid; booking uuid; i integer; booked_role text;
begin
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,currency,defender_capacity,attacker_capacity,
    participation_rules_version,minimum_players)
    values('Disposable unstarted review',kickoff,kickoff+interval '1 hour',case when paid then 12000 else 0 end,
      'USD',4,8,'s0-configurable-v1',2) returning id into game;
  for i in 1..cardinality(players) loop
    player:=players[i]; booked_role:=case when i<=2 then 'GK' when i<=6 then 'DEF' else 'ATT' end;
    if cardinality(players)=2 then booked_role:='ATT'; end if;
    if paid then
      insert into public.payment_intents(profile_id,purpose,status,currency,amount_fils,payload,quote_snapshot,
        transaction_reference,provider,provider_intent_id,provider_payment_id)
        values(player,'SOLO_BOOKING','FINALIZED','USD',13000,jsonb_build_object('game_id',game,'role',booked_role),
          '{}','prestart-'||game||'-'||i,'STRIPE','pi_prestart_'||game||'_'||i,'ch_prestart_'||game||'_'||i)
        returning id into intent;
    else intent:=null;
    end if;
    insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,
      reliability_deposit_fils,reliability_deposit_status,payment_method,payment_status,payment_intent_id)
      values(game,player,booked_role,'CONFIRMED',case when paid then 13000 else 0 end,
        case when paid then 12000 else 0 end,case when paid then 1000 else 0 end,
        case when paid then 'HELD' else 'NOT_REQUIRED' end,case when paid then 'CARD' else 'FREE' end,'PAID',intent)
      returning id into booking;
    if intent is not null then
      update public.payment_intents set resource_type='OPEN_QUEUE_BOOKING',resource_id=booking where id=intent;
    end if;
  end loop;
  perform public.ensure_match_attendance_records('SOLO',game);
  return game;
end;
$$;
create function pg_temp.unstarted_case(game uuid) returns uuid language plpgsql as $$
declare review uuid;
begin
  insert into public.match_resolution_cases(match_kind,open_queue_game_id,state,reason_code,
    scheduled_end_at,high_priority_at,policy_snapshot)
    select 'SOLO',g.id,'NO_DATA','RESULT_MISSING',g.ends_at,g.ends_at+interval '24 hours',t.policy_snapshot
      from public.open_queue_games g join public.match_reliability_terms t on t.open_queue_game_id=g.id
      where g.id=game returning id into review;
  update public.open_queue_games set operational_state='NO_DATA',operational_reason_code='RESULT_MISSING' where id=game;
  return review;
end;
$$;

do $$
declare admin_id uuid:=gen_random_uuid(); admin_auth uuid:=gen_random_uuid(); players uuid[]:=array[]::uuid[];
  game uuid; free_game uuid; live_game uuid; review uuid; free_review uuid; i integer; rejected boolean;
  preview jsonb; result jsonb; before_tracks jsonb; after_tracks jsonb; request_sql text; overrides jsonb;
  refund public.payment_refunds%rowtype; refund_count integer; revision_count integer;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '1 hour';
begin
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(admin_auth,'prestart-admin@example.test',now(),'{"fieldrush_account_type":"staff"}');
  insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,role,is_active)
    values(admin_id,admin_auth,'prestart-admin@example.test','Prestart review administrator','admin',true);
  perform public.admin_set_season_zero_policy(admin_id,true,'Disposable cancellation regression activation.');
  for i in 1..14 loop players:=array_append(players,pg_temp.unstarted_player()); end loop;
  game:=pg_temp.unstarted_game(players,true,kickoff);
  perform public.referee_assign_season_zero_teams(admin_id,game,gen_random_uuid());
  review:=pg_temp.unstarted_case(game);
  perform pg_temp.unstarted_expect((select status='FULL' and teams_assigned_at is not null
    and rating_policy_id='field-sr-season0-v2' from public.open_queue_games where id=game),
    'reproduces full, assigned, no-data Season 0 game without kickoff');
  select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) into before_tracks
    from public.fieldrush_player_rating_tracks t where profile_id=any(players);
  perform pg_temp.unstarted_expect(not has_function_privilege('authenticated',
    'public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)','EXECUTE')
    and not has_function_privilege('anon','public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)','EXECUTE')
    and has_function_privilege('service_role','public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)','EXECUTE'),
    'review writer retains service-only ACL');
  perform pg_temp.unstarted_expect((select count(*)=1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'admin_resolve_match_case%'),'no historical writer alias bypasses guard');
  request_sql:=format('select public.admin_resolve_match_case(%L,%L,%L,0,%L,%L,%L)',admin_id,'SOLO',game,
    'ADMINISTRATIVE_VOID','Verified that the scheduled game never began.','{}');
  perform pg_temp.unstarted_reject(replace(request_sql,admin_id::text,players[1]::text),'Admin access required');
  perform pg_temp.unstarted_reject(format('select public.admin_resolve_match_case(%L,%L,%L,1,%L,%L,%L)',
    admin_id,'SOLO',game,'ADMINISTRATIVE_VOID','A stale preview must never refund the game.','{}'),'review changed');
  perform pg_temp.unstarted_reject(replace(request_sql,'ADMINISTRATIVE_VOID','RECORDED_RESULT'),'can only be cancelled with a full refund');
  perform pg_temp.unstarted_reject(replace(request_sql,'ADMINISTRATIVE_VOID','BOTH_NO_SHOW'),'can only be cancelled with a full refund');
  for overrides in select value from jsonb_array_elements('[{"home_refund_bps":0},{"home_strikes":1},{"attendance":{"WHITE":"NO_SHOW"}},{"home_score":1},{"home_sr_delta":10}]') loop
    perform pg_temp.unstarted_reject(format('select public.admin_resolve_match_case(%L,%L,%L,0,%L,%L,%L)',
      admin_id,'SOLO',game,'ADMINISTRATIVE_VOID','Overrides cannot hide within a neutral cancellation.',overrides),
      'does not accept score, attendance, penalty, or refund overrides');
  end loop;
  rejected:=false;
  begin
    insert into public.open_queue_clock_states(game_id,status,started_at,accumulated_seconds,duration_seconds)
      values(game,'RUNNING',clock_timestamp(),1,3600)
      on conflict(game_id) do update set status='RUNNING',started_at=excluded.started_at,accumulated_seconds=1;
    execute request_sql;
  exception when invalid_parameter_value then
    if position('kickoff or playing evidence' in sqlerrm)=0 then raise; end if;
    rejected:=true;
  end;
  perform pg_temp.unstarted_expect(rejected,'running clock blocks legacy cancellation even without kickoff snapshot');
  perform pg_temp.unstarted_reject(format('select fieldrush_private.assert_deletion_ready(%L)',players[1]),'Resolve your active games');

  preview:=public.admin_preview_match_case_resolution(admin_id,'SOLO',game,0,'ADMINISTRATIVE_VOID',
    'Verified that the scheduled game never began.','{}');
  perform pg_temp.unstarted_expect(preview->>'would_set_case_state'='RESOLVED'
    and jsonb_array_length(preview->'refunds')=14
    and (select bool_and((r->>'amount_fils')::integer=13000 and r->>'destination'='ORIGINAL_PAYMENT_METHOD')
      from jsonb_array_elements(preview->'refunds') r),'preview includes exact original-payment fee and held-deposit refunds');
  perform pg_temp.unstarted_expect((select status='FULL' and operational_state='NO_DATA' from public.open_queue_games where id=game)
    and not exists(select 1 from public.match_resolution_revisions where case_id=review)
    and not exists(select 1 from public.match_resolution_refunds where case_id=review)
    and not exists(select 1 from public.payment_refunds where recipient_profile_id=any(players)),
    'preview rolls back status, case revision and refund requests');
  result:=public.admin_resolve_match_case(admin_id,'SOLO',game,0,'ADMINISTRATIVE_VOID',
    'Verified that the scheduled game never began.','{}');
  perform pg_temp.unstarted_expect((select status='CANCELLED' and operational_state='RESOLVED' and teams_assigned_at is not null
    and white_score is null and black_score is null from public.open_queue_games where id=game)
    and (select state='RESOLVED' and current_revision=1 and resolved_by=admin_id from public.match_resolution_cases where id=review),
    'one transaction cancels the game and resolves its review case');
  perform pg_temp.unstarted_expect((select count(*)=14 and bool_and(status='CANCELLED' and not played
    and refund_destination='ORIGINAL_PAYMENT_METHOD' and refund_status='PROCESSING' and refund_amount_fils=13000)
    from public.open_queue_bookings where game_id=game),'all current bookings cancel while transfer state remains pending');
  perform pg_temp.unstarted_expect((select count(*)=14 and bool_and(amount_fils=13000 and amount_minor=1300
    and currency='USD' and status='PENDING') from public.payment_refunds where recipient_profile_id=any(players)),
    'each payer has exactly one pending 13 USD provider refund');
  perform pg_temp.unstarted_expect((select count(*)=14 and bool_and(status='PENDING' and amount_fils=13000
    and destination='ORIGINAL_PAYMENT_METHOD') from public.match_resolution_refunds where case_id=review),
    'case refunds retain the provider request and honest pending status');
  perform pg_temp.unstarted_expect(not exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=game)
    and not exists(select 1 from public.open_queue_events where game_id=game)
    and not exists(select 1 from public.player_rating_events where source_id=game)
    and not exists(select 1 from public.reliability_incidents where profile_id=any(players)),
    'cancellation fabricates no kickoff, playing events, SR or strikes');
  select jsonb_agg(to_jsonb(t) order by profile_id,rating_track) into after_tracks
    from public.fieldrush_player_rating_tracks t where profile_id=any(players);
  perform pg_temp.unstarted_expect(before_tracks=after_tracks,'both rating tracks and lifetime appearances remain unchanged');
  perform pg_temp.unstarted_expect(exists(select 1 from public.admin_audit_events where entity_id=game
    and action='NO_DATA_MATCH_RESOLVED' and actor_referee_id=admin_id)
    and exists(select 1 from public.admin_audit_events where entity_id=game and action='SOLO_SR_TEAMS_ASSIGNED'),
    'cancellation records its audit and preserves original assignment history');
  select count(*) into refund_count from public.payment_refunds where recipient_profile_id=any(players);
  select count(*) into revision_count from public.match_resolution_revisions where case_id=review;
  perform pg_temp.unstarted_reject(request_sql,'kickoff or playing evidence');
  perform pg_temp.unstarted_expect((select count(*)=refund_count from public.payment_refunds where recipient_profile_id=any(players))
    and (select count(*)=revision_count from public.match_resolution_revisions where case_id=review),
    'repeated cancellation creates no duplicate refund or case revision');
  perform pg_temp.unstarted_reject(format('select fieldrush_private.assert_deletion_ready(%L)',players[1]),'settle your pending payment refund');
  select * into refund from public.payment_refunds where recipient_profile_id=players[1];
  perform public.finish_payment_refund(refund.id,'re_prestart_'||refund.id,'succeeded',refund.amount_minor,refund.currency);
  perform public.finish_payment_refund(refund.id,'re_prestart_'||refund.id,'succeeded',refund.amount_minor,refund.currency);
  perform fieldrush_private.assert_deletion_ready(players[1]);
  perform pg_temp.unstarted_expect((select status='COMPLETED' from public.match_resolution_refunds where payment_refund_id=refund.id),
    'settled refund clears deletion blocker and repeated confirmation is idempotent');

  free_game:=pg_temp.unstarted_game(players[1:2],false,kickoff+interval '1 minute');
  free_review:=pg_temp.unstarted_case(free_game);
  result:=public.admin_resolve_match_case(admin_id,'SOLO',free_game,0,'FIELD_OR_VENUE_CANCELLATION',
    'Verified venue unavailable before any player began the game.','{}');
  perform pg_temp.unstarted_expect((select status='CANCELLED' and operational_state='RESOLVED' from public.open_queue_games where id=free_game)
    and (select current_revision=1 from public.match_resolution_cases where id=free_review),
    'field cancellation also resolves an OPEN game with free bookings');
  live_game:=pg_temp.unstarted_game(players[1:2],false,kickoff+interval '2 minutes');
  perform public.referee_assign_season_zero_teams(admin_id,live_game,gen_random_uuid());
  update public.match_attendance_records set checked_in_at=check_in_deadline_at-interval '1 minute',
    checked_in_by=admin_id,check_in_timing='EARLY',outcome='ON_TIME',finalized_at=clock_timestamp() where open_queue_game_id=live_game;
  perform public.referee_season_zero_action(admin_id,live_game,gen_random_uuid(),0,
    jsonb_build_object('action','START','participant_ids',to_jsonb(players[1:2])));
  perform pg_temp.unstarted_case(live_game);
  perform pg_temp.unstarted_reject(format('select public.admin_resolve_match_case(%L,%L,%L,0,%L,%L,%L)',
    admin_id,'SOLO',live_game,'ADMINISTRATIVE_VOID','A started game must use audited Season 0 review.','{}'),
    'kickoff or playing evidence');
  perform pg_temp.unstarted_expect(public.get_season_zero_match_state(admin_id,live_game)->>'lifecycle'='LIVE',
    'started game retains actual kickoff and its rating-review evidence');
end;
$$;
select count(*)||' unstarted Season 0 resolution checks passed.' as result from unstarted_resolution_checks;
