-- Full-schema regression, run inside a disposable transaction and roll back.
-- Real row-lock concurrency is covered by test_party_context_read_lock.mjs.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table party_context_checks(label text);
create function pg_temp.party_context_expect(ok boolean,label text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Party context: %',label; end if;
  insert into party_context_checks values(label);
end;
$$;

do $verify$
declare
  players uuid[]:=array[]::uuid[]; person uuid; game uuid; legacy_game uuid;
  party uuid; invitation uuid; i integer; payload jsonb; expected jsonb;
  original_terms public.match_reliability_terms%rowtype;
  actual_terms public.match_reliability_terms%rowtype;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
  legacy_kickoff timestamptz:=date_trunc('minute',clock_timestamp())-interval '1 minute';
  denied boolean; signature text; new_policy uuid;
begin
  for i in 1..4 loop
    person:=gen_random_uuid(); players:=array_append(players,person);
    insert into auth.users(id,phone,phone_confirmed_at)
      values(person,'15558847'||lpad(i::text,3,'0'),now());
    perform set_config('request.jwt.claim.sub',person::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object(
      'first_name','Party','last_name','Read',
      'username','prty_'||replace(left(person::text,13),'-',''),
      'date_of_birth','2000-01-01','email',person||'@party-read.example.test',
      'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
  end loop;
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(players[3],'Party read admin','+15558847003','admin',true);
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable historical party policy.',now(),players[3]
    from public.reliability_policy_versions order by version limit 1;
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,created_by)
    values('Disposable party context',kickoff,kickoff+interval '1 hour',0,players[1])
    returning id into game;
  for i in 1..2 loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,
      amount_paid_fils,base_amount_fils,payment_method)
      values(game,players[i],'DEF','CONFIRMED',0,0,'FREE');
  end loop;
  perform set_config('request.jwt.claim.sub',players[1]::text,true);
  party:=public.create_open_queue_party(game);
  invitation:=public.invite_open_queue_party_member(party,players[2]);
  perform set_config('request.jwt.claim.sub',players[2]::text,true);
  perform public.respond_open_queue_party_invitation(invitation,true);
  select * into original_terms from public.match_reliability_terms
    where match_kind='SOLO' and open_queue_game_id=game;
  perform pg_temp.party_context_expect(original_terms.id is not null,
    'ordinary booking triggers bind the committed terms');

  expected:=fieldrush_rating_private.mask_public_rating_payload(
    public.get_open_queue_party_context_before_sr_privacy(game),null,'OUTFIELD',null,game);
  perform set_config('request.jwt.claim.role','authenticated',true);
  execute 'set local role authenticated';
  payload:=public.get_open_queue_party_context(game);
  execute 'reset role';
  perform pg_temp.party_context_expect(payload=expected,
    'public wrapper still applies the exact SR privacy projection');
  perform pg_temp.party_context_expect(payload->'my_party'->>'id'=party::text
    and payload->'my_party'->>'is_owner'='false'
    and payload->'my_party'->>'accepted_count'='2'
    and jsonb_array_length(payload->'my_party'->'members')=2
    and payload->'received_invites'='[]'::jsonb,
    'accepted member sees the persisted party and roster');
  select * into actual_terms from public.match_reliability_terms
    where match_kind='SOLO' and open_queue_game_id=game;
  perform pg_temp.party_context_expect(to_jsonb(actual_terms)=to_jsonb(original_terms),
    'existing matching terms are returned without changing the snapshot');

  -- A later published policy cannot replace the terms disclosed at booking.
  perform set_config('request.jwt.claim.role','service_role',true);
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(kickoff-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Disposable later party policy.',now(),players[3]
    from public.reliability_policy_versions where id=original_terms.policy_version_id
    returning id into new_policy;
  payload:=public.get_open_queue_party_context(game);
  perform pg_temp.party_context_expect(payload->>'policy_version_id'=original_terms.policy_version_id::text
    and payload->>'policy_version_id'<>new_policy::text,
    'financially committed policy remains pinned after a newer publication');

  -- Simulate a legacy stale snapshot without deleting attendance audit rows.
  update public.match_reliability_terms set kickoff_at=kickoff_at+interval '1 hour',
    check_in_opens_at=check_in_opens_at+interval '1 hour',
    check_in_deadline_at=check_in_deadline_at+interval '1 hour',
    no_show_cutoff_at=no_show_cutoff_at+interval '1 hour',
    team_assignment_at=team_assignment_at+interval '1 hour',
    party_lock_at=party_lock_at+interval '1 hour'
    where id=original_terms.id;
  payload:=public.get_open_queue_party_context(game);
  select * into actual_terms from public.match_reliability_terms where id=original_terms.id;
  perform pg_temp.party_context_expect(actual_terms.kickoff_at=kickoff
    and actual_terms.policy_version_id=original_terms.policy_version_id
    and actual_terms.party_lock_at=original_terms.party_lock_at
    and (payload->>'party_lock_at')::timestamptz=original_terms.party_lock_at,
    'stale kickoff falls back to the authoritative synchronization helper');

  -- Historical matches do not bind prospective terms on insert. This creates
  -- a genuine missing-terms case without disabling triggers or deleting audits.
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,created_by)
    values('Disposable legacy party context',legacy_kickoff,legacy_kickoff+interval '1 hour',0,players[4])
    returning id into legacy_game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,
    amount_paid_fils,base_amount_fils,payment_method)
    values(legacy_game,players[4],'DEF','CONFIRMED',0,0,'FREE');
  perform pg_temp.party_context_expect(not exists(select 1 from public.match_reliability_terms
    where open_queue_game_id=legacy_game),'historical fixture begins without terms');
  perform set_config('request.jwt.claim.sub',players[3]::text,true);
  denied:=false;
  execute 'set local role authenticated';
  begin perform public.get_open_queue_party_context(legacy_game);
  exception when raise_exception then
    if sqlerrm<>'You need a confirmed booking in this solo game.' then raise; end if;
    denied:=true;
  end;
  execute 'reset role';
  perform pg_temp.party_context_expect(denied and not exists(select 1 from public.match_reliability_terms
    where open_queue_game_id=legacy_game),'unbooked viewer is rejected before lazy initialization');
  perform set_config('request.jwt.claim.sub','',true);
  denied:=false;
  begin perform public.get_open_queue_party_context(legacy_game);
  exception when raise_exception then
    if sqlerrm<>'You need to sign in again.' then raise; end if;
    denied:=true;
  end;
  perform pg_temp.party_context_expect(denied and not exists(select 1 from public.match_reliability_terms
    where open_queue_game_id=legacy_game),'missing identity is rejected before lazy initialization');
  perform set_config('request.jwt.claim.sub',players[4]::text,true);
  execute 'set local role authenticated';
  payload:=public.get_open_queue_party_context(legacy_game);
  execute 'reset role';
  perform pg_temp.party_context_expect(exists(select 1 from public.match_reliability_terms
    where open_queue_game_id=legacy_game and kickoff_at=legacy_kickoff)
    and payload->>'can_use_parties'='false','missing terms still initialize lazily');

  update public.open_queue_bookings set status='CANCELLED' where game_id=game and profile_id=players[2];
  perform set_config('request.jwt.claim.sub',players[2]::text,true);
  denied:=false;
  execute 'set local role authenticated';
  begin perform public.get_open_queue_party_context(game);
  exception when raise_exception then
    if sqlerrm<>'You need a confirmed booking in this solo game.' then raise; end if;
    denied:=true;
  end;
  execute 'reset role';
  perform pg_temp.party_context_expect(denied,'cancelled bookings cannot read party membership');
  foreach signature in array array['public.get_open_queue_party_context(uuid)',
    'public.get_open_queue_party_context_before_sr_privacy(uuid)'] loop
    perform pg_temp.party_context_expect((select provolatile='v' and prosecdef
      from pg_proc where oid=signature::regprocedure),'volatile security-definer contract: '||signature);
  end loop;
  perform pg_temp.party_context_expect(has_function_privilege('authenticated','public.get_open_queue_party_context(uuid)','EXECUTE')
    and has_function_privilege('service_role','public.get_open_queue_party_context(uuid)','EXECUTE')
    and not has_function_privilege('anon','public.get_open_queue_party_context(uuid)','EXECUTE'),
    'public caller grants are unchanged');
  foreach signature in array array['anon','authenticated','service_role'] loop
    perform pg_temp.party_context_expect(not has_function_privilege(signature,
      'public.get_open_queue_party_context_before_sr_privacy(uuid)','EXECUTE'),
      'private implementation is inaccessible to '||signature);
  end loop;
end;
$verify$;
select count(*) as party_context_assertions from party_context_checks;
