-- Run against the complete schema inside the caller's BEGIN/ROLLBACK.
-- Disposable identities and fixtures only; all real application triggers stay
-- enabled. The final reads run in a READ ONLY transaction as PostgREST does
-- for STABLE RPCs, so a locking/write helper is a regression.
set local client_min_messages=warning;

create function pg_temp.assignment_notice_expect(ok boolean,message text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then
    raise exception 'Team assignment notice verification: %',message;
  end if;
end;
$$;

create temporary table assignment_notice_fixtures(
  caller uuid,other_player uuid,outsider uuid,game uuid,legacy_game uuid,
  saved_terms jsonb,expected_assignment timestamptz
);
grant select on assignment_notice_fixtures to authenticated;

do $setup$
declare
  players uuid[]:='{}'; player uuid; i integer; game uuid; legacy_game uuid;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
  saved public.match_reliability_terms%rowtype;
  assigned timestamptz:=clock_timestamp();
begin
  perform set_config('request.jwt.claim.role','service_role',true);
  for i in 1..3 loop
    player:=gen_random_uuid();
    insert into auth.users(id,phone,phone_confirmed_at)
      values(player,'15557992'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',player::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object(
      'first_name','Assignment','last_name','Notice',
      'username','ancheck_'||replace(left(player::text,13),'-',''),
      'date_of_birth','2000-01-01','email','ancheck-'||player::text||'@example.test',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
    players:=array_append(players,player);
  end loop;

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback team assignment notice verification',kickoff,
      kickoff+interval '1 hour',0,players[1]) returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,
    amount_paid_fils,base_amount_fils,payment_method)
    values(game,players[1],'DEF','CONFIRMED',0,0,'FREE'),
      (game,players[2],'ATT','CONFIRMED',0,0,'FREE');
  update public.fieldrush_player_rating_tracks set skill_rating=1000,matches_played=0
    where profile_id=players[1] and rating_track='OUTFIELD';
  update public.fieldrush_player_rating_tracks set skill_rating=3000,matches_played=1
    where profile_id=players[2] and rating_track='OUTFIELD';

  -- A synthetic already-assigned fixture lets placement privacy and assignment
  -- facts be tested independently without changing the assignment algorithm.
  update public.open_queue_bookings set team=case when profile_id=players[1]
    then 'WHITE' else 'BLACK' end,rating_at_team_assignment=case when profile_id=players[1]
    then 1000 else 3000 end where game_id=game and status='CONFIRMED';
  update public.open_queue_games set teams_assigned_at=assigned,
    white_average_sr=1000,black_average_sr=3000,match_average_sr=2000,team_sr_spread=2000
    where id=game;
  select * into saved from public.match_reliability_terms where open_queue_game_id=game;
  perform pg_temp.assignment_notice_expect(saved.id is not null,
    'normal game/booking triggers bind the committed terms');

  -- Only this unbooked disposable game's terms are removed to model inventory
  -- predating policy binding. No booking/attendance history is removed.
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback legacy assignment notice verification',kickoff+interval '1 day',
      kickoff+interval '25 hours',0,players[1]) returning id into legacy_game;
  delete from public.match_reliability_terms where open_queue_game_id=legacy_game;
  insert into assignment_notice_fixtures values(players[1],players[2],players[3],game,legacy_game,
    to_jsonb(saved),assigned);
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
end;
$setup$;

select pg_temp.assignment_notice_expect((select p.provolatile='s' and p.prosecdef
  and p.proconfig @> array['search_path=public, pg_temp']
  and original.provolatile=p.provolatile
  and position('ensure_match_reliability_terms' in p.prosrc)=0
  and position('open_queue_team_assignment_at(' in p.prosrc)=0
  from pg_proc p,pg_proc original
  where p.oid='public.get_open_queue_match_detail(uuid)'::regprocedure
    and original.oid='public.get_open_queue_match_detail_before_sr_privacy(uuid)'::regprocedure),
  'detail retains its STABLE, security-definer, pinned search path and read-only original contract');
select pg_temp.assignment_notice_expect(
  not has_function_privilege('anon','public.get_open_queue_match_detail(uuid)','EXECUTE')
  and has_function_privilege('authenticated','public.get_open_queue_match_detail(uuid)','EXECUTE')
  and has_function_privilege('service_role','public.get_open_queue_match_detail(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.get_open_queue_match_detail_before_sr_privacy(uuid)','EXECUTE'),
  'authorized detail grants and private original remain intact');

-- All remaining work is genuine read-only application RPC access using the
-- authenticated role and JWT identities, rather than owner-bypassing reads.
set local transaction_read_only=on;
set local role authenticated;

do $verify$
declare f assignment_notice_fixtures%rowtype; detail jsonb; fixture record;
  rejected boolean:=false;
begin
  select * into f from assignment_notice_fixtures;
  detail:=public.get_open_queue_match_detail(f.game);
  perform pg_temp.assignment_notice_expect(detail->>'my_booking_team'='WHITE'
    and (detail->>'teams_assigned_at')::timestamptz=f.expected_assignment,
    'assigned kit and operational assignment timestamp stay visible for placement players');
  perform pg_temp.assignment_notice_expect(detail->>'policy_version_id'=f.saved_terms->>'policy_version_id'
    and (detail->>'team_assignment_at')::timestamptz=(f.saved_terms->>'team_assignment_at')::timestamptz
    and (detail->>'party_lock_at')::timestamptz=(f.saved_terms->>'party_lock_at')::timestamptz
    and (detail->>'team_assignment_lead_minutes')::integer=(f.saved_terms #>> '{policy_snapshot,solo,teamAssignmentLeadMinutes}')::integer
    and (detail->>'party_lock_lead_minutes')::integer=(f.saved_terms #>> '{policy_snapshot,solo,partyLockLeadMinutes}')::integer
    and (detail->>'max_party_size')::integer=(f.saved_terms #>> '{policy_snapshot,replacement,maxPartySize}')::integer,
    'all six notice fields come from the saved policy terms');

  select * into fixture from public.list_open_queue_fixture_games() where id=f.game;
  perform pg_temp.assignment_notice_expect(fixture.id is not null
    and fixture.policy_version_id::text=detail->>'policy_version_id'
    and fixture.team_assignment_at=(detail->>'team_assignment_at')::timestamptz
    and fixture.party_lock_at=(detail->>'party_lock_at')::timestamptz
    and fixture.team_assignment_lead_minutes=(detail->>'team_assignment_lead_minutes')::integer
    and fixture.party_lock_lead_minutes=(detail->>'party_lock_lead_minutes')::integer
    and fixture.max_party_size=(detail->>'max_party_size')::integer,
    'detail and fixture feed agree on the exact committed deadline contract');
  perform pg_temp.assignment_notice_expect((detail->>'lobby_average_sr')::numeric=2000
    and detail->'white_average_sr'='null'::jsonb
    and detail->'black_average_sr'='null'::jsonb
    and detail->'match_average_sr'='null'::jsonb
    and (select count(*)=2 and bool_and(p.value->>'rating_visible'='false'
      and p.value->'rating_at_team_assignment'='null'::jsonb
      and p.value->'rating_at_match_start'='null'::jsonb)
      from jsonb_array_elements(detail->'players') p(value)),
    'whole lobby includes both hidden placement ratings while individual/team SR stays masked');

  detail:=public.get_open_queue_match_detail(f.legacy_game);
  perform pg_temp.assignment_notice_expect(detail->'policy_version_id'='null'::jsonb
    and detail->'team_assignment_at'='null'::jsonb and detail->'party_lock_at'='null'::jsonb
    and detail->'team_assignment_lead_minutes'='null'::jsonb
    and detail->'party_lock_lead_minutes'='null'::jsonb and detail->'max_party_size'='null'::jsonb,
    'legacy missing terms remain unknown without binding/rebuilding policy on a read');

  -- Non-bookers have always been allowed to inspect match detail. Preserve
  -- that behavior, while never returning another player's booking or kit.
  perform set_config('request.jwt.claim.sub',f.outsider::text,true);
  detail:=public.get_open_queue_match_detail(f.game);
  perform pg_temp.assignment_notice_expect(detail->>'id'=f.game::text
    and detail->'my_booking_id'='null'::jsonb and detail->'my_booking_team'='null'::jsonb
    and detail->>'team_assignment_at'=f.saved_terms->>'team_assignment_at'
    and (detail->>'lobby_average_sr')::numeric=2000,
    'signed-in non-booker retains detail access and the same terms/aggregate without a personal kit');
  begin
    perform public.get_open_queue_match_detail(gen_random_uuid());
  exception when raise_exception then
    if sqlerrm='Open Queue game not found.' then rejected:=true; else raise; end if;
  end;
  perform pg_temp.assignment_notice_expect(rejected,'unknown game retains the original not-found error');
  rejected:=false;
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.get_open_queue_match_detail(f.game);
  exception when raise_exception then
    if sqlerrm='You need to sign in again.' then rejected:=true; else raise; end if;
  end;
  perform pg_temp.assignment_notice_expect(rejected,'a missing Auth identity remains rejected');
  perform set_config('request.jwt.claim.sub',f.caller::text,true);
end;
$verify$;
reset role;

select pg_temp.assignment_notice_expect((select to_jsonb(t)=f.saved_terms
  from public.match_reliability_terms t,assignment_notice_fixtures f where t.open_queue_game_id=f.game),
  'repeated authorized detail reads preserve every byte of the committed terms');
select pg_temp.assignment_notice_expect(not exists(select 1 from public.match_reliability_terms t,
  assignment_notice_fixtures f where t.open_queue_game_id=f.legacy_game),
  'read-only legacy detail does not create terms');
select 'PASS: real authenticated read-only detail, saved assignment terms/feed consistency, placement privacy, full-lobby average, assignment facts, legacy inventory and caller errors' as result;
