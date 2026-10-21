-- Full application-schema regression, inside caller-owned BEGIN/ROLLBACK.
-- Auth tables are the isolated harness contract, not a live OTP provider.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);
create temporary table staff_account_checks(label text);
create function pg_temp.staff_expect(ok boolean,label text) returns void language plpgsql security definer as $$
begin if ok is distinct from true then raise exception 'Independent staff: %',label; end if;
  insert into pg_temp.staff_account_checks values(label); end $$;
create function pg_temp.staff_reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise; end if; rejected:=true; end;
  perform pg_temp.staff_expect(rejected,'rejected: '||expected);
end $$;
create sequence pg_temp.staff_person;
create function pg_temp.staff_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.staff_person'); previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
  insert into auth.users(id,phone,phone_confirmed_at,raw_user_meta_data)
    values(player,'1555999'||lpad(n::text,4,'0'),now(),'{"fieldrush_account_type":"staff"}');
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object('first_name','Separate','last_name','Player','username','separate_'||n,
    'date_of_birth','2000-01-01','email','player_'||n||'@example.test','skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  return player;
end $$;
create function pg_temp.staff_auth(email_to_use text,confirmed boolean default true) returns uuid language plpgsql as $$
declare identity_id uuid:=gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(identity_id,email_to_use,case when confirmed then now() end,'{"fieldrush_account_type":"staff"}');
  return identity_id;
end $$;
do $$
declare fresh uuid:=gen_random_uuid(); existing_email uuid:=gen_random_uuid(); google_user uuid:=gen_random_uuid();
begin
  -- Follow GoTrue adminUserCreate ordering, including the intermediate role
  -- update. Direct SQL insertion of final metadata alone missed this path.
  insert into auth.users(id,email,raw_app_meta_data)
    values(fresh,'auth-create-order@example.test','{"provider":"email","providers":["email"]}');
  insert into auth.identities(user_id,provider,provider_id,identity_data)
    values(fresh,'email',fresh::text,'{"email":"auth-create-order@example.test"}');
  update auth.users set role='authenticated' where id=fresh;
  update auth.users set raw_app_meta_data=raw_app_meta_data||'{"fieldrush_account_type":"staff"}' where id=fresh;
  update auth.users set email_confirmed_at=now() where id=fresh;
  perform pg_temp.staff_expect(fieldrush_private.is_staff_auth_user(fresh),'GoTrue staged creation initializes staff');
  perform pg_temp.staff_expect(not exists(select 1 from public.profiles where id=fresh or auth_user_id=fresh)
    and not exists(select 1 from fieldrush_private.accounts where user_id=fresh)
    and not exists(select 1 from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=fresh)
    and not exists(select 1 from fieldrush_private.staff_auth_creation_context where user_id=fresh),
    'staged staff creation leaves no player records or reusable admission');
  insert into auth.users(id,email) values(existing_email,'existing-email-player@example.test');
  -- Execute exactly the deferred cleanup that runs at transaction commit.
  set constraints auth.fieldrush_close_staff_auth_creation immediate;
  set constraints auth.fieldrush_close_staff_auth_creation deferred;
  perform pg_temp.staff_expect(not exists(select 1 from fieldrush_private.staff_auth_creation_context),
    'creation admission expires at the transaction boundary');
  update auth.users set role='authenticated' where id=existing_email;
  perform pg_temp.staff_reject(format('update auth.users set raw_app_meta_data=''{"fieldrush_account_type":"staff"}'' where id=%L',existing_email),
    'do not convert a player');
  insert into auth.users(id,email) values(google_user,'google-player@example.test');
  insert into auth.identities(user_id,provider,provider_id) values(google_user,'google',google_user::text);
  perform pg_temp.staff_reject(format('update auth.users set raw_app_meta_data=''{"fieldrush_account_type":"staff"}'' where id=%L',google_user),
    'independent of player');
  perform pg_temp.staff_expect(not has_table_privilege('service_role','fieldrush_private.staff_auth_creation_context','INSERT')
    and not has_table_privilege('authenticated','fieldrush_private.staff_auth_creation_context','INSERT'),
    'API callers cannot manufacture staff creation admission');
end $$;
do $$
declare player_admin uuid:=pg_temp.staff_player(); other_player uuid:=pg_temp.staff_player();
  admin_auth uuid:=pg_temp.staff_auth('staff-admin@example.test',false); ref_auth uuid;
  staff_ref uuid; pending_ref uuid:=gen_random_uuid(); second_admin uuid:=gen_random_uuid(); pending_auth uuid;
  created jsonb; again jsonb; original_player jsonb; original_private jsonb; original_staff jsonb; original_ratings jsonb;
  game uuid; field uuid; response jsonb; original_audit_count integer; old_auth_count integer;
  clan_player uuid; home_clan uuid; away_clan uuid; clan_fixture uuid; forfeit_id uuid:=gen_random_uuid();
  report_id uuid; stoppage_id uuid; clan_day date; terms public.match_reliability_terms; clan_enabled_before boolean;
begin
  -- Retained staff keys can coincide with an old player key, but no FK or Auth
  -- mapping equates those accounts after migration.
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (player_admin,'Retained administrator','+15559990001','admin',true),
    (pending_ref,'Inactive retained referee',null,'referee',false),
    (second_admin,'Another pending administrator',null,'admin',true);
  select to_jsonb(p) into original_player from public.profiles p where id=player_admin;
  select to_jsonb(a) into original_private from fieldrush_private.accounts a where user_id=player_admin;
  select jsonb_agg(to_jsonb(r) order by rating_track) into original_ratings from public.fieldrush_player_rating_tracks r where profile_id=player_admin;
  perform set_config('request.jwt.claim.sub',player_admin::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.staff_expect(public.current_fieldrush_staff_id() is null,'old player token has no staff identity');
  perform pg_temp.staff_expect(not public.is_active_moderation_admin(player_admin),'old player token cannot claim retained admin key');
  perform pg_temp.staff_reject(format('select public.bootstrap_independent_staff_admin(%L,%L,''staff-admin@example.test'')',player_admin,admin_auth),'administration service');
  perform set_config('request.jwt.claim.role','service_role',true);
  created:=public.bootstrap_independent_staff_admin(player_admin,admin_auth,'staff-admin@example.test');
  again:=public.bootstrap_independent_staff_admin(player_admin,admin_auth,'staff-admin@example.test');
  perform pg_temp.staff_expect(created->>'already_active'='false' and again->>'already_active'='true','manual bootstrap exact retry is idempotent');
  perform pg_temp.staff_expect((select count(*)=1 from public.admin_audit_events where action='INDEPENDENT_STAFF_BOOTSTRAP' and entity_id=player_admin),'bootstrap records one audit event');
  perform pg_temp.staff_expect(not fieldrush_private.staff_identity_is_active(player_admin),'unconfirmed invited email cannot act');
  perform set_config('request.jwt.claim.sub',admin_auth::text,true);
  perform pg_temp.staff_expect(public.current_fieldrush_staff_id() is null,'unconfirmed email has no mapped staff authority');
  update auth.users set email_confirmed_at=now() where id=admin_auth;
  perform pg_temp.staff_expect(public.current_fieldrush_staff_id()=player_admin,'confirmed independent email resolves stable staff key');
  perform pg_temp.staff_expect(public.is_active_moderation_admin(player_admin),'confirmed bound admin is authorized');
  perform pg_temp.staff_expect((select to_jsonb(p)=original_player from public.profiles p where id=player_admin),'bootstrap preserves player profile');
  perform pg_temp.staff_expect((select to_jsonb(a)=original_private from fieldrush_private.accounts a where user_id=player_admin),'bootstrap preserves player private account');
  perform pg_temp.staff_expect((select jsonb_agg(to_jsonb(r) order by rating_track)=original_ratings from public.fieldrush_player_rating_tracks r where profile_id=player_admin),'bootstrap preserves player rating and seed');
  perform pg_temp.staff_expect(not exists(select 1 from public.profiles where id=admin_auth or auth_user_id=admin_auth)
    and not exists(select 1 from fieldrush_private.accounts where user_id=admin_auth)
    and not exists(select 1 from fieldrush_rating_private.season_zero_initialization_eligibility where user_id=admin_auth),'staff Auth creation creates no player identity/account/rating eligibility');
  perform pg_temp.staff_reject('select public.get_my_fieldrush_account()','separate player sign-in');
  perform pg_temp.staff_reject(format('insert into public.profiles(id,auth_user_id,display_name) values(%L,%L,''Unwanted player'')',admin_auth,admin_auth),'separate player sign-in');
  perform pg_temp.staff_reject(format('insert into fieldrush_private.accounts(user_id) values(%L)',admin_auth),'separate player sign-in');
  perform pg_temp.staff_reject(format('update auth.users set raw_app_meta_data=''{}'' where id=%L',admin_auth),'cannot be converted');
  perform pg_temp.staff_reject(format('update auth.users set phone=''15550000000'' where id=%L',admin_auth),'independent of player');
  perform pg_temp.staff_reject(format('update auth.users set email=''unbound-new@example.test'' where id=%L',admin_auth),'audited staff administration');
  perform pg_temp.staff_reject(format('insert into auth.identities(user_id,provider,provider_id) values(%L,''google'',''unwanted-google'')',admin_auth),'email codes only');
  perform pg_temp.staff_reject(format('insert into auth.identities(user_id,provider,provider_id) values(%L,''phone'',''unwanted-phone'')',admin_auth),'email codes only');
  perform pg_temp.staff_reject(format('insert into auth.identities(user_id,provider,provider_id,identity_data) values(%L,''email'',''unwanted-email'',''{"email":"staff-admin@example.test"}'')',other_player),'independent staff sign-in');
  perform pg_temp.staff_reject(format('update auth.users set raw_app_meta_data=''{"fieldrush_account_type":"staff"}'' where id=%L',other_player),'do not convert a player');
  pending_auth:=pg_temp.staff_auth('other-bootstrap@example.test');
  perform pg_temp.staff_reject(format('select public.bootstrap_independent_staff_admin(%L,%L,''other-bootstrap@example.test'')',second_admin,pending_auth),'already bound');
  ref_auth:=pg_temp.staff_auth('staff-referee@example.test');
  created:=public.admin_grant_independent_staff(player_admin,ref_auth,'staff-referee@example.test','Independent referee','referee');
  staff_ref:=(created#>>'{staff,profile_id}')::uuid;
  perform pg_temp.staff_expect(staff_ref<>ref_auth and staff_ref<>player_admin,'new staff stable key is separate from auth and player keys');
  perform pg_temp.staff_expect((created#>>'{staff,phone}') is null,'email-only staff needs no player phone');
  again:=public.admin_grant_independent_staff(player_admin,ref_auth,'staff-referee@example.test','Independent referee','referee');
  perform pg_temp.staff_expect(again->>'already_active'='true' and again#>>'{staff,profile_id}'=staff_ref::text,'normal provisioning exact retry retains stable staff key');
  perform pg_temp.staff_reject(format('select public.admin_grant_independent_staff(%L,%L,''player@example.test'',''Player misuse'',''referee'')',player_admin,other_player),'independent staff-only');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.staff_reject(format('select public.admin_grant_independent_staff(%L,%L,''staff-referee@example.test'',''Independent referee'',''referee'')',player_admin,ref_auth),'administration service');
  perform set_config('request.jwt.claim.role','service_role',true);
  select to_jsonb(s) into original_staff from public.referee_profiles s where profile_id=pending_ref;
  select count(*) into original_audit_count from public.admin_audit_events where entity_id=pending_ref;
  perform pg_temp.staff_reject(format('select public.admin_grant_independent_staff(%L,%L,''other-bootstrap@example.test'',''Inactive retained referee'',''referee'',%L)',player_admin,pending_auth,pending_ref),'Inactive staff access');
  perform pg_temp.staff_expect((select to_jsonb(s)=original_staff from public.referee_profiles s where profile_id=pending_ref)
    and (select count(*)=original_audit_count from public.admin_audit_events where entity_id=pending_ref),
    'rejected inactive staff binding leaves the entire staff record and audit history unchanged');
  perform pg_temp.staff_reject(format('select public.admin_grant_fieldrush_staff(%L,%L,''+15550000000'',''Old phone flow'',''referee'')',player_admin,other_player),'independent email staff provisioning');

  -- Actual staff operations work without ANY player profile for the new staff.
  response:=public.admin_save_field(player_admin,null,jsonb_build_object('name','Independent staff fixture field','address','1 Disposable Lane',
    'city','Phoenix','state','AZ','country_code','US','latitude',33.4,'longitude',-111.9,'market_city_id','phoenix','is_active',true));
  field:=(response->>'id')::uuid;
  perform public.admin_set_season_zero_policy(player_admin,true,'Independent staff fixture verifies staff-only actor references.');
  game:=public.admin_create_open_queue_game(player_admin,field,date_trunc('minute',now())+interval '2 days',0,'18+',60,1,5,1,2,4);
  perform pg_temp.staff_expect((select created_by is null and created_by_staff_id=player_admin from public.open_queue_games where id=game),'staff-created game uses its own actor FK');
  insert into public.open_queue_referee_assignments(game_id,referee_id,assigned_by) values(game,staff_ref,player_admin);
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,''Retire assigned referee safely.'')',player_admin,staff_ref),'unfinished match');
  perform public.create_broadcast_pairing(staff_ref,'SOLO',game,repeat('a',64));
  perform pg_temp.staff_expect(exists(select 1 from public.broadcast_pairing_codes where owner_profile_id=staff_ref),'profile-free referee can own broadcaster pairing');
  perform public.admin_cancel_match(player_admin,'SOLO',game,'ADMIN_DECISION','Cancel disposable independent staff fixture.');
  perform pg_temp.staff_expect((select cancelled_by is null and cancelled_by_staff_id=player_admin from public.open_queue_games where id=game),'staff cancellation uses separate actor FK');

  -- A referee-created forfeit settles through the real financial/reliability
  -- function without requiring a same-ID player profile for the referee.
  clan_player:=pg_temp.staff_player();
  insert into public.clans(name,tag,created_by) values('Independent Staff Home','ISH',other_player) returning id into home_clan;
  insert into public.clans(name,tag,created_by) values('Independent Staff Away','ISA',clan_player) returning id into away_clan;
  select d::date into clan_day from generate_series(current_date+7,current_date+14,interval '1 day') d
    where extract(isodow from d) in (2,5) order by d limit 1;
  select clan_enabled into clan_enabled_before from public.game_payment_settings where singleton;
  update public.game_payment_settings set clan_enabled=true where singleton;
  insert into public.fixtures(status,home_clan_id,away_clan_id,venue,day,time_slot,match_date,created_by,cancellation_context,cancellation_code,cancellation_reason,cancelled_at)
    values('CANCELLED',home_clan,away_clan,'Isolated staff forfeit',
      case when extract(isodow from clan_day)=2 then 'TUESDAY' else 'FRIDAY' end,
      '7:00 PM - 8:00 PM',clan_day,other_player,jsonb_build_object('forfeit_decision_id',forfeit_id),
      'ADMIN_CANCELLED','Isolated provisional clan forfeit.',clock_timestamp()) returning id into clan_fixture;
  update public.game_payment_settings set clan_enabled=clan_enabled_before where singleton;
  terms:=public.ensure_match_reliability_terms('CLAN',clan_fixture);
  insert into public.moderation_reports(reporter_referee_id,source,subject_type,subject_clan_id,fixture_id,category,details)
    values(staff_ref,'REFEREE','CLAN',home_clan,clan_fixture,'NO_SHOW_OR_MATCH_MANIPULATION','Isolated referee-attributed clan walkout.') returning id into report_id;
  insert into public.match_stoppages(match_kind,fixture_id,stopped_by,mode,reason_code,note)
    values('CLAN',clan_fixture,staff_ref,'ABANDON','TEAM_WALKOUT','Isolated referee-attributed clan walkout.') returning id into stoppage_id;
  insert into public.match_forfeit_decisions(id,fixture_id,stoppage_id,source_report_id,reported_clan_id,awarded_clan_id,provisional_home_score,provisional_away_score,created_by)
    values(forfeit_id,clan_fixture,stoppage_id,report_id,home_clan,away_clan,0,3,staff_ref);
  response:=public.settle_reviewed_clan_forfeit_reliability(player_admin,forfeit_id,true,'Isolated independent referee forfeit is confirmed.');
  perform pg_temp.staff_expect((select cancelled_by is null and cancelled_by_staff_id=staff_ref from public.clan_fixture_cancellations where fixture_id=clan_fixture)
    and not exists(select 1 from public.profiles where id=staff_ref),
    'profile-free referee forfeit settlement records its independent staff actor');
  perform pg_temp.staff_expect((select policy_snapshot=terms.policy_snapshot and policy_version_id=terms.policy_version_id
    from public.clan_fixture_cancellations where fixture_id=clan_fixture),
    'independent forfeit actor preserves snapshotted cancellation policy');
  perform public.admin_offboard_fieldrush_staff(player_admin,staff_ref,'Retire completed fixture referee safely.');
  delete from auth.users where id=ref_auth;
  perform pg_temp.staff_expect((select not is_active and auth_user_id is null and email is null from public.referee_profiles where profile_id=staff_ref),'offboarded staff auth deletion retains detached history key');
  perform pg_temp.staff_expect(exists(select 1 from public.open_queue_referee_assignments where game_id=game and referee_id=staff_ref),'completed assignment history survives staff auth deletion');
  perform pg_temp.staff_reject(format('select public.admin_offboard_fieldrush_staff(%L,%L,''Do not remove final administrator.'')',player_admin,player_admin),'last active administrator');
  perform pg_temp.staff_reject(format('delete from auth.users where id=%L',admin_auth),'Remove staff access');

  -- Deleting the OLD player account neither removes nor anonymizes its now
  -- independently authenticated staff record. Wallet consent still applies.
  select to_jsonb(s) into original_staff from public.referee_profiles s where profile_id=player_admin;
  insert into public.field_wallet_usd_accounts(profile_id,balance_fils) values(player_admin,500)
    on conflict(profile_id) do update set balance_fils=500;
  perform set_config('request.jwt.claim.sub',player_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',player_admin,'role','authenticated','amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',floor(extract(epoch from now())))))::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform public.prepare_fieldrush_account_deletion(true);
  perform set_config('request.jwt.claim.role','service_role',true);
  delete from auth.users where id=player_admin;
  perform pg_temp.staff_expect((select to_jsonb(s)=original_staff from public.referee_profiles s where profile_id=player_admin),'player deletion leaves staff name, phone, active access and login unchanged');
  perform pg_temp.staff_expect((select auth_user_id is null and account_deleted_at is not null from public.profiles where id=player_admin),'normal player anonymization still occurs');
  perform pg_temp.staff_expect((select balance_fils=0 from public.field_wallet_usd_accounts where profile_id=player_admin),'confirmed player wallet forfeiture still occurs');
  perform pg_temp.staff_expect((select count(*)=1 from public.field_wallet_transactions where profile_id=player_admin and transaction_type='ACCOUNT_DELETION_FORFEITURE' and direction='DEBIT' and amount_fils=500),'wallet ledger remains explicit and append-only');
  perform set_config('request.jwt.claim.sub',admin_auth::text,true);
  perform pg_temp.staff_expect(public.current_fieldrush_staff_id()=player_admin and public.is_active_moderation_admin(player_admin),'independent staff remains authorized after player deletion');
  perform pg_temp.staff_expect(not exists(select 1 from pg_constraint where conrelid='public.referee_profiles'::regclass and confrelid='public.profiles'::regclass),'staff registry has no player-profile FK');
  perform pg_temp.staff_expect(not has_function_privilege('authenticated','public.admin_grant_independent_staff(uuid,uuid,text,text,text,uuid)','EXECUTE')
    and not has_function_privilege('anon','public.bootstrap_independent_staff_admin(uuid,uuid,text)','EXECUTE'),'provision and bootstrap are not public APIs');
end $$;

-- Exercise actual RLS as an authenticated player, including the old same UUID.
select set_config('request.jwt.claim.sub',(select id::text from auth.users where phone is not null order by created_at limit 1),true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select pg_temp.staff_expect((select count(*)=0 from public.referee_profiles),'player cannot read staff directory under RLS');
select pg_temp.staff_expect((select count(*)=0 from public.open_queue_referee_assignments),'player cannot read staff assignments under RLS');
reset role;
select set_config('request.jwt.claim.sub',(select id::text from auth.users where email='staff-admin@example.test'),true);
set local role authenticated;
select pg_temp.staff_expect(public.current_fieldrush_staff_id() is not null,'independent staff helper works under actual authenticated role');
select pg_temp.staff_expect((select count(*)>0 from public.referee_profiles),'independent staff can read authorized directory under RLS');
select pg_temp.staff_expect((select count(*)=1 from public.open_queue_referee_assignments),'bound admin can read historical assignments under RLS');
reset role;
select count(*) as independent_staff_checks from staff_account_checks;
