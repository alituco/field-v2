-- Complete schema, disposable transaction only. No hosted identities or data.
create function pg_temp.clan_assert(ok boolean,message text)
returns void language plpgsql as $$begin
  if ok is not true then raise exception 'Clan containment: %',message; end if;
end$$;
create function pg_temp.clan_reject(statement text,expected text)
returns void language plpgsql as $$declare denied boolean:=false; begin
  begin execute statement; exception when others then
    if sqlstate<>expected then raise; end if; denied:=true;
  end;
  perform pg_temp.clan_assert(denied,'Expected rejection: '||statement);
end$$;

insert into auth.users(id,phone,phone_confirmed_at) values
  ('fc163000-0000-4000-8000-000000000001','15551630001',now()),
  ('fc163000-0000-4000-8000-000000000002','15551630002',now());
select set_config('request.jwt.claims','{"sub":"fc163000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.complete_fieldrush_onboarding(
  '{"first_name":"Clan","last_name":"Fixture","username":"clan_guard_fixture","date_of_birth":"2000-01-01","email":"clan@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1');
select pg_temp.clan_reject($q$insert into public.clans(name,tag,created_by,skill_rating) values
  ('Forged rating','CGF','fc163000-0000-4000-8000-000000000001',9999)$q$,'42501');
select pg_temp.clan_reject($q$insert into public.clans(name,tag,created_by,wins) values
  ('Forged wins','CGW','fc163000-0000-4000-8000-000000000001',50)$q$,'42501');
select pg_temp.clan_reject($q$insert into public.clans(name,tag,created_by,losses) values
  ('Forged losses','CGL','fc163000-0000-4000-8000-000000000001',5)$q$,'42501');
select pg_temp.clan_reject($q$insert into public.clans(name,tag,created_by,archived_at) values
  ('Pre archived','CGA','fc163000-0000-4000-8000-000000000001',now())$q$,'42501');
insert into public.clans(id,name,tag,created_by) values
  ('fc163000-0000-4000-8000-000000000010','Guarded clan','CGOK','fc163000-0000-4000-8000-000000000001');
select pg_temp.clan_assert((select skill_rating=1500 and wins=0 and losses=0 from public.clans
  where id='fc163000-0000-4000-8000-000000000010'),'ordinary creation uses canonical defaults');
update public.clans set motto='Presentation still editable' where id='fc163000-0000-4000-8000-000000000010';
select pg_temp.clan_assert((select motto='Presentation still editable' from public.clans
  where id='fc163000-0000-4000-8000-000000000010'),'normal manager edits still work');
select pg_temp.clan_reject($q$update public.clans set skill_rating=5000 where id='fc163000-0000-4000-8000-000000000010'$q$,'42501');
select pg_temp.clan_reject($q$update public.clans set archived_at=now(),archived_by=auth.uid()
  where id='fc163000-0000-4000-8000-000000000010'$q$,'42501');
select pg_temp.clan_reject($q$update public.clans set archived_by=auth.uid()
  where id='fc163000-0000-4000-8000-000000000010'$q$,'42501');
select public.archive_clan('fc163000-0000-4000-8000-000000000010');
reset role;
select pg_temp.clan_assert((select archived_at is not null and archived_by='fc163000-0000-4000-8000-000000000001'
  from public.clans where id='fc163000-0000-4000-8000-000000000010'),'owner archive RPC still works');
select pg_temp.clan_assert(not exists(select 1 from public.clan_members
  where clan_id='fc163000-0000-4000-8000-000000000010' and left_at is null),'archive atomically releases active membership');
-- Trusted settlement writes retain their existing ability; this is NOT an RLS
-- bypass granted to players. In particular no arbitrary field-updating RPC is added.
update public.clans set skill_rating=1510,wins=1 where id='fc163000-0000-4000-8000-000000000010';
select pg_temp.clan_assert((select skill_rating=1510 and wins=1 from public.clans
  where id='fc163000-0000-4000-8000-000000000010'),'server-owned competitive settlement remains possible');
select 'Clan insert/update/archive containment passed.' as result;
