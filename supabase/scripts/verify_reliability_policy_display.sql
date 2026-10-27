-- Rollback-only local fixture: run with test_season_zero_migration_chain.mjs.
-- No provider calls, hosted writes, or policy changes.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('field.match_resolution_control_plane','on',true);
create temporary table reliability_display_checks(label text);
create function pg_temp.display_expect(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Reliability display: %',label; end if;
  insert into reliability_display_checks values(label);
end;
$$;

do $verify$
declare player uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); game uuid;
  booking uuid; attendance uuid; finding uuid; response jsonb; before_payload jsonb; policy jsonb;
  before_counts bigint[]; after_counts bigint[]; actor uuid; staff_login uuid:=gen_random_uuid(); appeal_id uuid;
begin
  perform pg_temp.display_expect(not has_function_privilege('anon','public.get_my_reliability_status()','EXECUTE'),
    'anonymous users cannot read the private record');
  perform pg_temp.display_expect(has_function_privilege('authenticated','public.get_my_reliability_status()','EXECUTE'),
    'signed-in caller retains the existing entry point');
  perform pg_temp.display_expect(not has_function_privilege('authenticated','public.get_my_reliability_status_before_display()','EXECUTE')
    and not has_function_privilege('service_role','public.get_my_reliability_status_before_display()','EXECUTE'),
    'the implementation alias is not exposed');
  foreach actor in array array[player,outsider] loop
    insert into auth.users(id,phone,phone_confirmed_at) values(actor,
      '1555548'||case when actor=player then '0001' else '0002' end,clock_timestamp());
    perform set_config('request.jwt.claim.sub',actor::text,true);
    perform public.complete_fieldrush_onboarding(jsonb_build_object(
      'first_name','Display','last_name','Player','username',case when actor=player then 'display_one' else 'display_two' end,
      'date_of_birth','2000-01-01','email',case when actor=player then 'display-one@example.test' else 'display-two@example.test' end,
      'skill_assessment','not_sure'),'fieldrush-v1','fieldrush-v1');
  end loop;
  perform set_config('request.jwt.claim.sub',player::text,true);
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils,defender_capacity,attacker_capacity)
    values('Disposable reliability display',date_trunc('minute',clock_timestamp())+interval '5 days',
      date_trunc('minute',clock_timestamp())+interval '5 days 1 hour',0,4,8) returning id into game;
  insert into public.open_queue_bookings(game_id,profile_id,role,status,amount_paid_fils,base_amount_fils,payment_method,payment_status)
    values(game,player,'ATT','CONFIRMED',0,0,'FREE','PAID') returning id into booking;
  perform public.ensure_match_attendance_records('SOLO',game);
  select id into attendance from public.match_attendance_records where booking_id=booking;
  update public.match_attendance_records set outcome='LATE',strike_delta=1,
    checked_in_at=clock_timestamp(),finalized_at=clock_timestamp(),appeal_due_at=clock_timestamp()+interval '1 day' where id=attendance;
  finding:=public.record_reliability_incident(attendance,'LATE',1,statement_timestamp()-interval '1 minute');
  before_payload:=public.get_my_reliability_status_before_display();
  select config into policy from public.reliability_policy_versions where id::text=before_payload->>'policy_version_id';
  select array[(select count(*) from public.reliability_incidents),(select count(*) from public.reliability_sanctions),
    (select count(*) from public.reliability_appeals)] into before_counts;
  response:=public.get_my_reliability_status();
  perform pg_temp.display_expect(response->'active_strikes'=before_payload->'active_strikes'
    and response->'message'=before_payload->'message' and response->'active_sanction'=before_payload->'active_sanction',
    'standing and sanctions are preserved');
  perform pg_temp.display_expect(response#>'{policy_display,no_show_strikes}'=policy#>'{solo,outcomes,noShow,strikes}'
    and response#>'{policy_display,sanctions}'=policy#>'{solo,sanctions}'
    and response#>'{policy_display,cancellations}'=policy#>'{solo,cancellations}'
    and response#>'{policy_display,deposit}'=policy#>'{solo,reliabilityDeposit}',
    'all rules are taken from the effective published policy');
  perform pg_temp.display_expect(response->>'timezone'='America/Phoenix'
    and response#>>'{incidents,0,timezone}'='America/Phoenix',
    'account and game timezones do not use the legacy Bahrain policy zone');
  perform pg_temp.display_expect(response#>>'{incidents,0,attendance_record_id}'=attendance::text
    and response#>'{incidents,0,strike_active}'='true'::jsonb,
    'the caller sees their current unreversed finding');
  select array[(select count(*) from public.reliability_incidents),(select count(*) from public.reliability_sanctions),
    (select count(*) from public.reliability_appeals)] into after_counts;
  perform pg_temp.display_expect(before_counts=after_counts,'display reads do not create decisions or appeals');
  appeal_id:=public.submit_reliability_appeal(attendance,'VERIFIED_MEDICAL_EMERGENCY','Disposable documented medical emergency.');
  response:=public.get_my_reliability_status();
  perform pg_temp.display_expect(response#>>'{incidents,0,appeal_status}'='OPEN'
    and response#>>'{incidents,0,appeal_submitted_at}' is not null,
    'a submitted appeal includes its actual status and timestamp');
  -- Exercise the real audited review/compensating-ledger workflow with a
  -- synthetic independent staff identity, never a hosted administrator.
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(staff_login,'display-staff@example.test',clock_timestamp(),'{"fieldrush_account_type":"staff"}');
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active,auth_user_id,email)
    values(outsider,'Disposable display admin','+15555480002','admin',true,staff_login,'display-staff@example.test');
  perform public.admin_review_reliability_appeal(outsider,appeal_id,'OVERTURN','Disposable verified exception.');
  response:=public.get_my_reliability_status();
  perform pg_temp.display_expect(response#>'{incidents,0,strike_active}'='false'::jsonb,
    'a reversed finding no longer appears active');
  perform pg_temp.display_expect(response#>>'{incidents,0,original_outcome}'='LATE'
    and response#>>'{incidents,0,original_strike_delta}'='1'
    and response#>>'{incidents,0,appeal_resolution_note}'='Disposable verified exception.',
    'excused history retains the original finding and actual review decision');
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  response:=public.get_my_reliability_status();
  perform pg_temp.display_expect(response->'incidents'='[]'::jsonb and (response->>'active_strikes')::integer=0,
    'another caller cannot see the first player’s incident');
end;
$verify$;
select count(*) as reliability_display_checks_passed from reliability_display_checks;
