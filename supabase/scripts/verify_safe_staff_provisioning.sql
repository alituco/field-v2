-- Disposable full-schema verification, inside caller-owned rollback. Never
-- contacts an email, SMS or hosted Auth provider.
create function pg_temp.provision_expect(ok boolean,message text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'Safe staff provisioning: %',message; end if; end $$;
create function pg_temp.provision_reject(statement text,expected_code text) returns void language plpgsql as $$
declare rejected boolean:=false; begin
  begin execute statement; exception when others then
    if sqlstate<>expected_code then raise; end if; rejected:=true; end;
  perform pg_temp.provision_expect(rejected,'Expected SQLSTATE '||expected_code);
end $$;
do $$
declare actor uuid:=gen_random_uuid(); player uuid:=gen_random_uuid(); actor_auth uuid:=gen_random_uuid();
  player_staff_auth uuid:=gen_random_uuid(); fresh_auth uuid:=gen_random_uuid(); fresh_staff uuid;
  suffix text:=lpad((floor(random()*1000000)::bigint)::text,6,'0');
  actor_phone text; player_phone text; staff_email text; auth_before jsonb; identities_before jsonb;
  profile_before jsonb; account_before jsonb; reply jsonb; audits bigint;
begin
  actor_phone:='+15551'||suffix; player_phone:='+15552'||suffix; staff_email:='independent-'||suffix||'@example.test';
  insert into auth.users(id,phone,phone_confirmed_at,encrypted_password,raw_user_meta_data) values
    (actor,ltrim(actor_phone,'+'),now(),gen_random_uuid()::text,'{}'),
    (player,ltrim(player_phone,'+'),now(),gen_random_uuid()::text,'{"name":"Original Player","preserve":true}');
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values
    (actor_auth,'admin-'||suffix||'@example.test',now(),'{"fieldrush_account_type":"staff"}'),
    (player_staff_auth,staff_email,now(),'{"fieldrush_account_type":"staff"}'),
    (fresh_auth,'fresh-'||suffix||'@example.test',null,'{"fieldrush_account_type":"staff"}');
  insert into auth.identities(id,user_id,provider,provider_id,identity_data) values
    (gen_random_uuid(),player,'phone',player::text,'{"phone":"fixture"}'),
    (gen_random_uuid(),player,'google',player::text,'{"email":"player@example.test","email_verified":true}');
  insert into public.profiles(id,auth_user_id,display_name,phone,username,bio) values
    (actor,actor,'Provision Actor',actor_phone,'staff_actor_'||suffix,''),
    (player,player,'Original P.',player_phone,'staff_player_'||suffix,'Preserve this bio.');
  insert into fieldrush_private.accounts(user_id,status,first_name,last_name,email,date_of_birth,onboarding_completed_at)
    values(player,'active','Original','Player','private@example.test','2000-01-01',now());
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (actor,'Provision Actor',actor_phone,'admin',true),(player,'Retained Referee',player_phone,'referee',true);
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.bootstrap_independent_staff_admin(actor,actor_auth,'admin-'||suffix||'@example.test');
  select to_jsonb(u) into auth_before from auth.users u where id=player;
  select jsonb_agg(to_jsonb(i) order by i.id) into identities_before from auth.identities i where user_id=player;
  select to_jsonb(p) into profile_before from public.profiles p where id=player;
  select to_jsonb(a) into account_before from fieldrush_private.accounts a where user_id=player;
  reply:=public.admin_grant_independent_staff(actor,player_staff_auth,staff_email,'Retained Referee','referee',player);
  perform pg_temp.provision_expect(reply#>>'{staff,profile_id}'=player::text and reply#>>'{staff,auth_user_id}'=player_staff_auth::text,'retained staff key binds separate exact email identity');
  perform pg_temp.provision_expect((select to_jsonb(u)=auth_before from auth.users u where id=player),'player Auth phone/password/metadata preserved');
  perform pg_temp.provision_expect((select jsonb_agg(to_jsonb(i) order by i.id)=identities_before from auth.identities i where user_id=player),'Google and phone identities preserved');
  perform pg_temp.provision_expect((select to_jsonb(p)=profile_before from public.profiles p where id=player),'public name/username/bio preserved');
  perform pg_temp.provision_expect((select to_jsonb(a)=account_before from fieldrush_private.accounts a where user_id=player),'private player account preserved');
  select count(*) into audits from public.admin_audit_events where entity_id=player;
  reply:=public.admin_grant_independent_staff(actor,player_staff_auth,staff_email,'Retained Referee','referee',player);
  perform pg_temp.provision_expect((reply->>'already_active')::boolean,'idempotent same-binding retry');
  perform pg_temp.provision_expect((select count(*)=audits from public.admin_audit_events where entity_id=player),'no duplicate grant audit');
  perform pg_temp.provision_reject(format('select public.admin_grant_independent_staff(%L,%L,%L,''Retained Referee'',''admin'',%L)',actor,player_staff_auth,staff_email,player),'22023');
  perform pg_temp.provision_reject(format('select public.admin_grant_independent_staff(%L,%L,%L,''Replacement Label'',''referee'',%L)',actor,player_staff_auth,staff_email,player),'22023');
  perform pg_temp.provision_reject(format('select public.admin_grant_independent_staff(%L,%L,%L,''Player misuse'',''referee'')',actor,player,'private@example.test'),'22023');
  update public.referee_profiles set is_active=false where profile_id=actor;
  perform pg_temp.provision_reject(format('select public.admin_grant_independent_staff(%L,%L,%L,''Retained Referee'',''referee'',%L)',actor,player_staff_auth,staff_email,player),'42501');
  update public.referee_profiles set is_active=true where profile_id=actor;
  reply:=public.admin_grant_independent_staff(actor,fresh_auth,'fresh-'||suffix||'@example.test','Fresh Staff','referee');
  fresh_staff:=(reply#>>'{staff,profile_id}')::uuid;
  perform pg_temp.provision_expect(fresh_staff<>fresh_auth and fresh_staff<>player,'new staff stable key is independent');
  perform pg_temp.provision_expect((select email_confirmed_at is null and encrypted_password is null and phone is null from auth.users where id=fresh_auth),'new staff must verify email; no password or phone installed');
  perform pg_temp.provision_expect(not exists(select 1 from public.profiles where id in(fresh_auth,fresh_staff))
    and not exists(select 1 from fieldrush_private.accounts where user_id=fresh_auth),'staff provisioning creates no player profile/account');
  perform pg_temp.provision_expect(not fieldrush_private.staff_identity_is_active(fresh_staff),'invited unconfirmed email cannot operate matches');
  perform pg_temp.provision_expect(not has_function_privilege('anon','public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid)','EXECUTE')
    and not has_function_privilege('authenticated','public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid)','EXECUTE')
    and has_function_privilege('service_role','public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid)','EXECUTE'),'service-only independent execution grants');
  perform pg_temp.provision_expect(not has_function_privilege('service_role','public.admin_grant_fieldrush_staff(uuid,uuid,text,text,text)','EXECUTE'),'old phone grant cannot recouple a player');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.provision_reject(format('select public.admin_grant_independent_staff(%L,%L,%L,''Retained Referee'',''referee'',%L)',actor,player_staff_auth,staff_email,player),'42501');
end $$;
select 'Independent staff provisioning preserves player credentials and account details.' as result;
