-- Run after 20261014002200. Every identity, game, booking, terms snapshot and
-- claim change is transaction-local and rolled back. Do not disable triggers
-- or remove locking from the real party context implementation for this test.
begin;

create function pg_temp.privacy_rpc_expect(condition boolean,message text)
returns void language plpgsql as $$
begin
  if condition is distinct from true then
    raise exception 'Rating privacy RPC verification: %',message;
  end if;
end;
$$;

do $verify$
declare
  signature text;
  alias_signature text;
  wrapper_oid regprocedure;
  alias_oid regprocedure;
  role_to_check text;
  caller uuid:=gen_random_uuid();
  outsider uuid:=gen_random_uuid();
  game_id uuid;
  terms_before public.match_reliability_terms%rowtype;
  terms_after public.match_reliability_terms%rowtype;
  payload jsonb;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
  activation_before boolean;
  rejection_seen boolean:=false;
  i integer;
  player uuid;
begin
  select enabled into activation_before from fieldrush_rating_private.season_zero_activation;

  -- PostgREST chooses READ ONLY for a STABLE/IMMUTABLE POST RPC. A wrapper
  -- must retain its original function's volatility even when its own outer
  -- expression only selects a JSON value. Audit every privacy wrapper, not
  -- only the party endpoint that exposed the original regression.
  foreach signature in array array[
    'public.list_open_queue_games()',
    'public.list_open_queue_fixture_games()',
    'public.list_open_queue_games_for_market(text)',
    'public.list_open_queue_games_for_city(text)',
    'public.get_fieldrush_player_ratings(uuid,date,date)',
    'public.get_player_rating_history(uuid,integer)',
    'public.list_fieldrush_rating_page(text,text,text,date,date,integer,integer)',
    'public.list_fieldrush_placement_page(text,text,text,date,date,integer,integer)',
    'public.search_fieldrush_players(text)',
    'public.list_fieldrush_clan_members(uuid)',
    'public.get_open_queue_match_detail(uuid)',
    'public.get_fieldrush_season_rewards(text,text,text)',
    'public.get_open_queue_party_context(uuid)'
  ] loop
    alias_signature:=replace(signature,'(','_before_sr_privacy(');
    wrapper_oid:=to_regprocedure(signature);
    alias_oid:=to_regprocedure(alias_signature);
    perform pg_temp.privacy_rpc_expect(wrapper_oid is not null and alias_oid is not null,
      'the wrapper and private original exist for '||signature);
    perform pg_temp.privacy_rpc_expect(
      (select wrapper.provolatile=original.provolatile
       from pg_proc wrapper,pg_proc original
       where wrapper.oid=wrapper_oid and original.oid=alias_oid),
      'wrapper volatility matches its original for '||signature);
    foreach role_to_check in array array['anon','authenticated','service_role'] loop
      perform pg_temp.privacy_rpc_expect(
        not has_function_privilege(role_to_check,alias_oid,'EXECUTE'),
        'the unmasked original remains inaccessible to '||role_to_check||': '||alias_signature);
    end loop;
  end loop;

  wrapper_oid:='public.get_open_queue_party_context(uuid)'::regprocedure;
  alias_oid:='public.get_open_queue_party_context_before_sr_privacy(uuid)'::regprocedure;
  perform pg_temp.privacy_rpc_expect(
    (select provolatile='v' and prosecdef
       and proconfig @> array['search_path=public, pg_temp']
       and position('mask_public_rating_payload' in prosrc)>0
       and position('get_open_queue_party_context_before_sr_privacy' in prosrc)>0
     from pg_proc where oid=wrapper_oid),
    'the public party RPC is VOLATILE, security-definer, search-path-pinned and privacy-masked');
  perform pg_temp.privacy_rpc_expect(
    (select provolatile='v' and position('ensure_match_reliability_terms' in prosrc)>0
     from pg_proc where oid=alias_oid),
    'the real party original still uses the locking reliability terms helper');
  perform pg_temp.privacy_rpc_expect(
    has_function_privilege('authenticated',wrapper_oid,'EXECUTE')
      and has_function_privilege('service_role',wrapper_oid,'EXECUTE')
      and not has_function_privilege('anon',wrapper_oid,'EXECUTE'),
    'the public party RPC keeps its authenticated/service-only grants');

  -- Use genuinely new, fully onboarded disposable identities. Neither Auth
  -- ownership nor the initialization guard is bypassed, and no existing
  -- player's booking, wallet, profile or rating is used by this regression.
  perform set_config('request.jwt.claim.role','service_role',true);
  for i in 1..2 loop
    player:=case when i=1 then caller else outsider end;
    insert into auth.users(id,phone,phone_confirmed_at)
      values(player,'15558834'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',player::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object(
      'first_name','Privacy','last_name','RPC',
      'username','privacy_'||replace(left(player::text,13),'-',''),
      'date_of_birth','2000-01-01','email','privacy-rpc-'||player::text||'@example.test',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
  end loop;

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Rollback privacy RPC volatility verification',kickoff,
      kickoff+interval '1 hour',0,caller) returning id into game_id;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,
      amount_paid_fils,base_amount_fils,payment_method)
    values(game_id,caller,'DEF','CONFIRMED',0,0,'FREE');
  select * into terms_before from public.match_reliability_terms where open_queue_game_id=game_id;
  perform pg_temp.privacy_rpc_expect(terms_before.id is not null,
    'normal game/booking triggers bind the initial terms snapshot');

  perform set_config('request.jwt.claim.sub',caller::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  execute 'set local role authenticated';
  payload:=public.get_open_queue_party_context(game_id);
  execute 'reset role';
  perform pg_temp.privacy_rpc_expect(payload->>'game_id'=game_id::text
      and payload->>'can_use_parties'='true'
      and payload->>'policy_version_id'=terms_before.policy_version_id::text
      and (payload->>'max_party_size')::integer>1
      and jsonb_typeof(payload->'received_invites')='array'
      and jsonb_typeof(payload->'eligible_players')='array'
      and payload->'my_party'='null'::jsonb,
    'an authenticated booked player can load real party slots with existing terms');
  select * into terms_after from public.match_reliability_terms where open_queue_game_id=game_id;
  perform pg_temp.privacy_rpc_expect(to_jsonb(terms_after)=to_jsonb(terms_before),
    'loading existing committed terms retains the exact policy snapshot');

  -- Normal creation already exercised new-term binding. Repeat the app's read
  -- with the committed snapshot: this still requires the helper's row locks.
  -- Do not delete/rebuild terms to simulate a legacy fixture, because doing so
  -- would erase append-only attendance audit evidence even for a free booking.
  execute 'set local role authenticated';
  payload:=public.get_open_queue_party_context(game_id);
  execute 'reset role';
  select * into terms_after from public.match_reliability_terms where open_queue_game_id=game_id;
  perform pg_temp.privacy_rpc_expect(to_jsonb(terms_after)=to_jsonb(terms_before)
      and payload->>'policy_version_id'=terms_after.policy_version_id::text
      and (payload->>'party_lock_at')::timestamptz=terms_after.party_lock_at
      and (payload->>'team_assignment_at')::timestamptz=terms_after.team_assignment_at,
    'repeated public RPC loads preserve the snapshot and return authoritative locked values');

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  execute 'set local role authenticated';
  begin
    perform public.get_open_queue_party_context(game_id);
  exception when raise_exception then
    if sqlerrm='You need a confirmed booking in this solo game.' then
      rejection_seen:=true;
    else
      raise;
    end if;
  end;
  execute 'reset role';
  perform pg_temp.privacy_rpc_expect(rejection_seen,
    'an authenticated player without a booking is still rejected');
  perform pg_temp.privacy_rpc_expect(
    (select enabled is not distinct from activation_before
     from fieldrush_rating_private.season_zero_activation),
    'the test does not change Season 0 activation');
  raise notice 'Rating privacy RPCs verified: 13 volatility contracts, private alias ACLs, new-term binding, repeated authenticated real-party reads and non-booker rejection; all fixtures roll back.';
end;
$verify$;

rollback;
