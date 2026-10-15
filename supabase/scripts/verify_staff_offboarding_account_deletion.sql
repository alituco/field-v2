-- Run in a disposable full-schema database inside BEGIN / ROLLBACK. This file
-- creates synthetic identities only and never commits or calls external APIs.
create temporary table staff_offboarding_checks(label text);
create function pg_temp.staff_expect(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Staff offboarding: %', label; end if;
  insert into staff_offboarding_checks values (label);
end;
$$;
create function pg_temp.staff_reject(statement text, expected_code text, message_part text)
returns void language plpgsql as $$
declare rejected boolean := false;
begin
  begin execute statement;
  exception when others then
    if sqlstate <> expected_code or position(message_part in sqlerrm) = 0 then raise; end if;
    rejected := true;
  end;
  perform pg_temp.staff_expect(rejected, 'rejected: ' || message_part);
end;
$$;
create sequence pg_temp.staff_person;
create function pg_temp.staff_player() returns uuid language plpgsql as $$
declare person uuid := gen_random_uuid(); n bigint := nextval('pg_temp.staff_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at)
    values(person, '1555888' || lpad(n::text,4,'0'), now());
  perform set_config('request.jwt.claim.sub', person::text, true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object(
    'first_name','Staff','last_name','Test','username','staff_check_' || n,
    'date_of_birth','2000-01-01','email','staff_' || n || '@example.test',
    'skill_assessment','not_sure'), 'fieldrush-v1', 'fieldrush-v1');
  return person;
end;
$$;
select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  actor uuid := pg_temp.staff_player(); target uuid := pg_temp.staff_player();
  outsider uuid := pg_temp.staff_player(); keeper uuid := pg_temp.staff_player();
  target_phone text; reply jsonb; finished_game uuid; upcoming_game uuid;
  clan uuid; intent uuid; refund uuid; prior_audit bigint;
begin
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(actor,'Staff Actor','+15558880001','admin',true),
      (target,'Staff Target','+15558880002','admin',true),
      (keeper,'Staff Keeper','+15558880004','referee',true);
  select phone into target_phone from public.referee_profiles where profile_id = target;
  perform pg_temp.staff_expect(not has_function_privilege('anon',
    'public.admin_offboard_fieldrush_staff(uuid,uuid,text)','EXECUTE'), 'anonymous offboarding RPC denied');
  perform pg_temp.staff_expect(not has_function_privilege('authenticated',
    'public.admin_offboard_fieldrush_staff(uuid,uuid,text)','EXECUTE'), 'authenticated offboarding RPC denied');
  perform pg_temp.staff_expect(has_function_privilege('service_role',
    'public.admin_offboard_fieldrush_staff(uuid,uuid,text)','EXECUTE'), 'service offboarding RPC permitted');
  perform pg_temp.staff_expect(not has_function_privilege('authenticated',
    'fieldrush_private.require_active_assigned_staff()','EXECUTE'), 'assignment helper not client callable');
  perform pg_temp.staff_reject(format('select fieldrush_private.assert_deletion_ready(%L)',target),
    '22023','remove your staff access');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    actor,target,'Requested account removal for local verification.'), '42501','staff administration service');
  perform set_config('request.jwt.claim.role','service_role',true);
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    outsider,target,'Requested account removal for local verification.'), '42501','Active administrator');
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    actor,gen_random_uuid(),'Requested account removal for local verification.'), '22023','exact staff account');
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    actor,target,'short'), '22023','10 to 2000');

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
    values('OPEN','Isolated staff upcoming',date_trunc('minute',now())+interval '30 days',
      date_trunc('minute',now())+interval '30 days 1 hour',0)
    returning id into upcoming_game;
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by)
    values(upcoming_game,target,actor);
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    actor,target,'Requested account removal for local verification.'), '22023','Reassign or resolve');
  perform pg_temp.staff_expect((select is_active from public.referee_profiles where profile_id=target),
    'blocked offboarding leaves staff active');
  update public.open_queue_referee_assignments set referee_id=keeper where game_id=upcoming_game;

  -- An ended assignment and an audit authored by the target must survive Auth
  -- deletion. Neither history row is reassigned, deleted or detached.
  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils)
    values('FINAL','Isolated staff history',date_trunc('minute',now())-interval '30 days',
      date_trunc('minute',now())-interval '30 days'+interval '1 hour',0)
    returning id into finished_game;
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by)
    values(finished_game,target,target);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason)
    values(target,'STAFF_HISTORY_TEST','PLAYER',target,'Isolated historical author evidence.')
    returning id into prior_audit;
  reply := public.admin_offboard_fieldrush_staff(actor,target,'User requested account deletion and removal of staff access.');
  perform pg_temp.staff_expect(reply->>'profile_id'=target::text and reply->>'is_active'='false',
    'offboarding targets the exact staff profile');
  perform pg_temp.staff_expect((select phone=target_phone and not is_active from public.referee_profiles where profile_id=target),
    'offboarding changes authority only before account deletion');
  perform pg_temp.staff_expect((select count(*)=1 from public.admin_audit_events where entity_id=target and action='STAFF_OFFBOARDED'
    and actor_referee_id=actor and before_state->>'is_active'='true' and after_state->>'is_active'='false'
    and not (before_state ? 'phone') and not (after_state ? 'phone')), 'authority change audited without copying contact details');
  perform public.admin_offboard_fieldrush_staff(actor,target,'Repeat of the user-authorized removal for verification.');
  perform pg_temp.staff_expect((select count(*)=1 from public.admin_audit_events where entity_id=target and action='STAFF_OFFBOARDED'),
    'repeated offboarding is idempotent');
  perform pg_temp.staff_reject(format('insert into public.open_queue_referee_assignments(game_id,referee_id) values(%L,%L)',
    upcoming_game,target), '22023','inactive staff account');
  perform pg_temp.staff_reject(format('update public.open_queue_referee_assignments set referee_id=%L where game_id=%L',
    target,upcoming_game), '22023','inactive staff account');
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,%L)',
    actor,actor,'The only remaining active administrator must be retained.'), '22023','last active administrator');

  -- Removing staff authority does not bypass the independent clan obligation.
  perform set_config('request.jwt.claim.sub',target::text,true);
  insert into public.clans(name,tag,created_by) values('Staff ownership check','STFCK',target) returning id into clan;
  perform pg_temp.staff_reject(format('select fieldrush_private.assert_deletion_ready(%L)',target),
    '22023','Transfer clan ownership');
  insert into public.clan_members(clan_id,profile_id,role) values(clan,actor,'member');
  perform public.transfer_clan_ownership(clan,actor);
  perform pg_temp.staff_expect((select role='owner' and left_at is null from public.clan_members
    where clan_id=clan and profile_id=actor), 'clan ownership resolves through the supported transfer');

  -- A pending original-method refund continues to block an inactive member's
  -- deletion. Every row below is synthetic and rolls back with this verifier.
  insert into public.payment_intents(profile_id,purpose,status,currency,amount_fils,payload,quote_snapshot,
    transaction_reference,provider,provider_intent_id,provider_payment_id)
    values(target,'SOLO_BOOKING','FINALIZED','USD',9600,jsonb_build_object('game_id',upcoming_game,'role','ATT'),
      '{}'::jsonb,'isolated-staff-'||target,'STRIPE','pi_staff_'||target,'ch_staff_'||target)
    returning id into intent;
  insert into public.payment_refunds(intent_id,recipient_profile_id,idempotency_key,provider_intent_id,
    amount_fils,amount_minor,currency,reason,status)
    values(intent,target,'isolated-staff-refund-'||target,'pi_staff_'||target,9600,960,'USD',
      'Rollback-only original-method refund evidence.','PENDING') returning id into refund;
  perform pg_temp.staff_reject(format('select fieldrush_private.assert_deletion_ready(%L)',target),
    '22023','pending payment refund');
  perform pg_temp.staff_reject(format('delete from auth.users where id=%L',target),
    '22023','pending payment refund');
  perform public.finish_payment_refund(refund,'re_staff_'||target,'succeeded',960,'USD',null,0);
  perform pg_temp.staff_expect((select status='SUCCEEDED' from public.payment_refunds where id=refund),
    'settled refund unlocks the independent financial guard');

  -- Staff offboarding must not weaken the existing recent-authentication gate.
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',target,'role','authenticated','amr',
    jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now()-interval '1 day')::bigint)))::text,true);
  perform pg_temp.staff_reject('select public.prepare_fieldrush_account_deletion(true)',
    '42501','Verify a new login code');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',target,'role','authenticated','amr',
    jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now())::bigint)))::text,true);
  perform public.prepare_fieldrush_account_deletion(true);
  perform pg_temp.staff_expect((select status='deletion_pending' from fieldrush_private.accounts where user_id=target),
    'inactive staff use ordinary deletion preparation');
  delete from auth.users where id=target;
  perform pg_temp.staff_expect(not exists(select 1 from auth.users where id=target), 'Auth identity deleted');
  perform pg_temp.staff_expect((select not is_active and display_name='Deleted staff' and phone is null
    from public.referee_profiles where profile_id=target), 'historical staff key retained with contact details anonymized');
  perform pg_temp.staff_expect((select display_name='Deleted player' and phone is null and username is null
    and auth_user_id is null and account_deleted_at is not null from public.profiles where id=target),
    'normal public profile anonymization preserved');
  perform pg_temp.staff_expect(exists(select 1 from public.admin_audit_events where id=prior_audit and actor_referee_id=target),
    'historical audit author retained');
  perform pg_temp.staff_expect(exists(select 1 from public.open_queue_referee_assignments
    where game_id=finished_game and referee_id=target and assigned_by=target), 'historical assignment retained');
  perform pg_temp.staff_expect((select left_at is not null and removal_reason='LEFT' from public.clan_members
    where clan_id=clan and profile_id=target), 'departed clan membership history retained');
  perform pg_temp.staff_expect(exists(select 1 from public.clans where id=clan and created_by=target and archived_at is null),
    'transferred clan and creator history preserved');
  perform pg_temp.staff_expect(not exists(select 1 from fieldrush_private.accounts where user_id=target),
    'private account deleted through the ordinary Auth cascade');
  perform pg_temp.staff_reject(format('update public.referee_profiles set is_active=true where profile_id=%L',target),
    '23514','referee_profiles_active_phone_required');
  perform pg_temp.staff_reject(format('update public.referee_profiles set phone=null where profile_id=%L',actor),
    '23514','referee_profiles_active_phone_required');
  perform pg_temp.staff_reject(format('update public.referee_profiles set phone=''bad phone'' where profile_id=%L',target),
    '23514','referee_profiles_phone_check');
  -- The original unique-phone contract remains; the old phone is released only
  -- when the deleted staff row itself is anonymized.
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(outsider,'Fresh Staff',target_phone,'referee',true);
  perform pg_temp.staff_reject(format('update public.referee_profiles set phone=%L where profile_id=%L',
    target_phone,keeper), '23505','referee_profiles_phone_key');
end;
$$;

select count(*) as staff_offboarding_checks_passed from staff_offboarding_checks;
