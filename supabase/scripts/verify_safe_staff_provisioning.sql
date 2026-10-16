-- Disposable full-schema verification only, invoked inside BEGIN / ROLLBACK.
-- Synthetic identities; never contacts Auth, SMS, or a hosted service.
create function pg_temp.provision_expect(ok boolean,message text)
returns void language plpgsql as $$begin
  if ok is not true then raise exception 'Safe staff provisioning: %',message; end if;
end$$;
create function pg_temp.provision_reject(statement text,expected_code text)
returns void language plpgsql as $$declare rejected boolean:=false; begin
  begin execute statement;
  exception when others then
    if sqlstate<>expected_code then raise; end if; rejected:=true;
  end;
  perform pg_temp.provision_expect(rejected,'Expected SQLSTATE '||expected_code);
end$$;

do $$
declare
  actor uuid:=gen_random_uuid(); player uuid:=gen_random_uuid(); fresh uuid:=gen_random_uuid();
  phone_suffix text:=lpad((floor(random()*1000000)::bigint)::text,6,'0');
  actor_phone text; player_phone text; fresh_phone text;
  auth_before jsonb; identities_before jsonb; profile_before jsonb; account_before jsonb;
  reply jsonb; audits bigint;
begin
  actor_phone:='+15551'||phone_suffix;
  player_phone:='+15552'||phone_suffix;
  fresh_phone:='+15553'||phone_suffix;
  insert into auth.users(id,phone,phone_confirmed_at,encrypted_password,raw_user_meta_data)
    values(actor,ltrim(actor_phone,'+'),now(),gen_random_uuid()::text,'{}'),
      (player,ltrim(player_phone,'+'),now(),gen_random_uuid()::text,'{"name":"Original Player","preserve":true}'),
      (fresh,ltrim(fresh_phone,'+'),null,null,'{}');
  insert into auth.identities(id,user_id,provider,provider_id,identity_data)
    values(gen_random_uuid(),player,'phone',player::text,'{"phone":"fixture"}'),
      (gen_random_uuid(),player,'google',player::text,'{"email":"player@example.test","email_verified":true}');
  insert into public.profiles(id,auth_user_id,display_name,phone,username,bio)
    values(actor,actor,'Provision Actor',actor_phone,'staff_actor_'||phone_suffix,''),
      (player,player,'Original P.',player_phone,'staff_player_'||phone_suffix,'Preserve this bio.');
  insert into fieldrush_private.accounts(user_id,status,first_name,last_name,email,date_of_birth,onboarding_completed_at)
    values(player,'active','Original','Player','private@example.test','2000-01-01',now());
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active)
    values(actor,'Provision Actor',actor_phone,'admin',true);
  select to_jsonb(u) into auth_before from auth.users u where id=player;
  select jsonb_agg(to_jsonb(i) order by i.id) into identities_before from auth.identities i where user_id=player;
  select to_jsonb(p) into profile_before from public.profiles p where id=player;
  select to_jsonb(a) into account_before from fieldrush_private.accounts a where user_id=player;
  perform set_config('request.jwt.claim.role','service_role',true);
  reply:=public.admin_grant_fieldrush_staff(actor,player,player_phone,'Staff Label','referee');
  perform pg_temp.provision_expect(reply->'staff'->>'profile_id'=player::text,'exact existing account granted');
  perform pg_temp.provision_expect((select to_jsonb(u)=auth_before from auth.users u where id=player),'Auth phone/password/metadata preserved');
  perform pg_temp.provision_expect((select jsonb_agg(to_jsonb(i) order by i.id)=identities_before from auth.identities i where user_id=player),'Google and phone identities preserved');
  perform pg_temp.provision_expect((select to_jsonb(p)=profile_before from public.profiles p where id=player),'public name/username/bio preserved');
  perform pg_temp.provision_expect((select to_jsonb(a)=account_before from fieldrush_private.accounts a where user_id=player),'private account preserved');
  select count(*) into audits from public.admin_audit_events where entity_id=player;
  reply:=public.admin_grant_fieldrush_staff(actor,player,player_phone,'Replacement Label','referee');
  perform pg_temp.provision_expect((reply->>'already_active')::boolean,'idempotent same-role retry');
  perform pg_temp.provision_expect((select count(*)=audits from public.admin_audit_events where entity_id=player),'no duplicate grant audit');
  perform pg_temp.provision_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,%L,%L,%L)',
    actor,actor,actor_phone,'Admin','referee'),'22023');
  perform pg_temp.provision_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,%L,%L,%L)',
    actor,player,fresh_phone,'Staff','referee'),'22023');
  update public.referee_profiles set is_active=false where profile_id=actor;
  perform pg_temp.provision_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,%L,%L,%L)',
    actor,player,player_phone,'Staff','referee'),'42501');
  update public.referee_profiles set is_active=true where profile_id=actor;
  update fieldrush_private.accounts set status='deletion_pending' where user_id=player;
  perform pg_temp.provision_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,%L,%L,%L)',
    actor,player,player_phone,'Staff','referee'),'22023');
  update fieldrush_private.accounts set status='active' where user_id=player;
  reply:=public.admin_grant_fieldrush_staff(actor,fresh,fresh_phone,'Fresh Staff','referee');
  perform pg_temp.provision_expect((select phone_confirmed_at is null and encrypted_password is null from auth.users where id=fresh),'new staff must still verify phone; no password installed');
  perform pg_temp.provision_expect((select username is null and display_name='Fresh Staff' from public.profiles where id=fresh),'only missing public profile initialized');
  perform pg_temp.provision_expect(not has_function_privilege('anon','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE')
    and not has_function_privilege('authenticated','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE')
    and has_function_privilege('service_role','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE'),'service-only execution grants');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.provision_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,%L,%L,%L)',
    actor,player,player_phone,'Staff','referee'),'42501');
end$$;
select 'Safe staff provisioning full-schema verification passed.' as result;
