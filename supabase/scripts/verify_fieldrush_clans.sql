-- Local/disposable verification. Every user, clan, request and membership rolls back.
begin;
create function pg_temp.expect(condition boolean,message text) returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'Fieldrush clan verification: %',message; end if; end;
$$;
create temporary table clan_preview_ids(kind text,id uuid);
insert into clan_preview_ids values('owner',gen_random_uuid()),('member',gen_random_uuid()),('visitor',gen_random_uuid());
insert into auth.users(id,phone,phone_confirmed_at) select id,case kind when 'owner' then '15559990101' when 'member' then '15559990102' else '15559990103' end,now() from clan_preview_ids;
-- These rollback-only fixtures represent existing, pre-Season-0 identities.
-- New-account assessment is exercised by the dedicated initialization suite.
delete from fieldrush_rating_private.season_zero_initialization_eligibility where user_id in(select id from clan_preview_ids);
insert into public.profiles(id,auth_user_id,display_name,username) select id,id,'Clan Test '||kind,'clan_test_'||kind from clan_preview_ids
on conflict(id) do update set display_name=excluded.display_name,username=excluded.username;
insert into fieldrush_private.accounts(user_id,status,onboarding_completed_at) select id,'active',now() from clan_preview_ids
on conflict(user_id) do update set status='active',onboarding_completed_at=now();
grant select,insert on clan_preview_ids to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',(select id::text from clan_preview_ids where kind='owner'),true);
do $$ declare clan uuid; payload jsonb; rejected boolean:=false; begin
  insert into public.clans(name,tag,created_by,theme_id,market_city_id) values('Isolated Clan Preview','ZCP',auth.uid(),'electric','phoenix') returning id into clan;
  insert into clan_preview_ids values('clan',clan);
  payload:=public.list_fieldrush_clans();
  perform pg_temp.expect(exists(select 1 from jsonb_array_elements(payload) c where c->>'id'=clan::text and c->>'market_city_id'='phoenix' and c->>'city_name'='Phoenix' and c->>'member_count'='1'),'creator city and captain membership are persisted');
  payload:=public.list_fieldrush_clan_members(clan);
  perform pg_temp.expect(payload#>>'{0,role}'='owner' and payload#>>'{0,profiles,username}'='clan_test_owner','public roster has captain and username');
  perform pg_temp.expect(payload#>>'{0,skill_rating}' is null and not ((payload#>'{0,profiles}') ?| array['phone','email','date_of_birth']),'unplaced SR stays hidden and roster has no private identity');
  begin update public.clans set region='bahrain' where id=clan; exception when raise_exception then rejected:=true; end;
  perform pg_temp.expect(rejected,'identity updates cannot change earned clan city');
end; $$;
select set_config('request.jwt.claim.sub',(select id::text from clan_preview_ids where kind='member'),true);
select public.request_clan_join((select id from clan_preview_ids where kind='clan'));
do $$ declare rejected boolean:=false; request uuid; begin
  select id into request from public.clan_join_requests where clan_id=(select id from clan_preview_ids where kind='clan') and profile_id=auth.uid() and status='PENDING';
  perform pg_temp.expect(request is not null,'player can request membership');
  begin perform public.review_clan_join_request(request,true); exception when raise_exception or insufficient_privilege then rejected:=true; end;
  perform pg_temp.expect(rejected,'applicant cannot approve their own request');
end; $$;
select set_config('request.jwt.claim.sub',(select id::text from clan_preview_ids where kind='owner'),true);
select public.review_clan_join_request((select id from public.clan_join_requests where clan_id=(select id from clan_preview_ids where kind='clan') and status='PENDING'),true);
select pg_temp.expect(jsonb_array_length(public.list_fieldrush_clan_members((select id from clan_preview_ids where kind='clan')))=2,'captain approval updates roster');
select set_config('request.jwt.claim.sub',(select id::text from clan_preview_ids where kind='visitor'),true);
select public.request_clan_join((select id from clan_preview_ids where kind='clan'));
select public.cancel_clan_join_request((select id from public.clan_join_requests where profile_id=auth.uid() and status='PENDING'));
select pg_temp.expect(not exists(select 1 from public.clan_join_requests where profile_id=auth.uid() and status='PENDING'),'request cancellation persists');
reset role;
select pg_temp.expect(not has_function_privilege('anon','public.list_fieldrush_clans()','EXECUTE') and not has_function_privilege('anon','public.list_fieldrush_clan_members(uuid)','EXECUTE'),'anonymous clan directory denied');
rollback;
