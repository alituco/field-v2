-- Local/CI only. Invoke inside BEGIN / ROLLBACK after the complete schema.
-- No provider calls; fixture identity never owns a registered push device.
create function pg_temp.notification_event_assert(ok boolean,message text)
returns void language plpgsql as $$
begin if ok is not true then raise exception 'Notification event contract failed: %',message; end if; end;
$$;
create function pg_temp.notification_event_expect_denied(statement text)
returns void language plpgsql as $$
declare denied boolean:=false;
begin
  begin execute statement; exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Expected notification permission denial'; end if;
end;
$$;

insert into auth.users(id,instance_id,aud,role,phone,phone_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('fe154000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','15551540001',now(),'{}','{}',now(),now());
select set_config('request.jwt.claims','{"sub":"fe154000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.complete_fieldrush_onboarding(
  '{"first_name":"Notification","last_name":"Fixture","username":"notify_event_fixture","date_of_birth":"2000-01-01","email":"notification@example.test","skill_assessment":"not_sure"}',
  'fieldrush-v1','fieldrush-v1');
select pg_temp.notification_event_expect_denied('select public.process_fieldrush_notification_events()');
select pg_temp.notification_event_expect_denied('select * from fieldrush_private.notification_event_receipts');
select pg_temp.notification_event_expect_denied('select * from fieldrush_private.notification_news_publications');
select pg_temp.notification_event_expect_denied($q$select fieldrush_private.emit_notification_event(
  'fe154000-0000-4000-8000-000000000001','GAME_REMINDER','forged','Forged title','Forged body',null,null,'{}')$q$);
reset role;

-- Defaults are opt-out for marketing, and a suppressed event is still consumed.
select pg_temp.notification_event_assert(not fieldrush_private.emit_notification_event(
  'fe154000-0000-4000-8000-000000000001','NEWS_AND_OFFERS','fixture:off','Fixture news','Fixture body',null,null,'{}'),
  'marketing requires an explicit recipient opt-in');
select pg_temp.notification_event_assert(exists(select 1 from fieldrush_private.notification_event_receipts
  where recipient_id='fe154000-0000-4000-8000-000000000001' and event_key='fixture:off' and notification_id is null),
  'suppression consumes an event without an alert');
set local role authenticated;
select public.update_my_notification_preferences(
  '{"game_reminders":true,"clan_callups":true,"party_invites":true,"ladder_moves":true,"replays_ready":true,"news_and_offers":true}');
reset role;
select pg_temp.notification_event_assert(not fieldrush_private.emit_notification_event(
  'fe154000-0000-4000-8000-000000000001','NEWS_AND_OFFERS','fixture:off','Fixture news','Fixture body',null,null,'{}'),
  'enabling a preference does not replay a suppressed old event');
select pg_temp.notification_event_assert(fieldrush_private.emit_notification_event(
  'fe154000-0000-4000-8000-000000000001','NEWS_AND_OFFERS','fixture:on','Fixture news','Fixture body',null,null,'{}'),
  'an enabled optional event is persisted');
select pg_temp.notification_event_assert(not fieldrush_private.emit_notification_event(
  'fe154000-0000-4000-8000-000000000001','NEWS_AND_OFFERS','fixture:on','Fixture news','Fixture body',null,null,'{}'),
  'event retries are idempotent');
select pg_temp.notification_event_assert(not fieldrush_private.notification_source_is_current(
  (select id from public.notifications where recipient_profile_id='fe154000-0000-4000-8000-000000000001'
    and data->>'fieldrush_event_key'='fixture:on')),
  'a source-less marketing row cannot reach push delivery');

-- Execute the actual canonical ranking/attendance contracts on the full schema.
-- This catches source-column/function drift absent from isolated domain stubs.
select pg_temp.notification_event_assert(fieldrush_private.observe_notification_ladder()>=0,
  'canonical ranking source can be read after complete-schema replay');
select pg_temp.notification_event_assert(fieldrush_private.emit_ready_replay('SOLO','fe154000-0000-4000-8000-000000000099')=0,
  'a nonexistent replay has no recipients');
select pg_temp.notification_event_assert(fieldrush_private.emit_ready_replay('CLAN','fe154000-0000-4000-8000-000000000099')=0,
  'a nonexistent clan replay has no recipients');
select pg_temp.notification_event_assert(not has_function_privilege('authenticated',
  'public.admin_publish_fieldrush_news(uuid,uuid,text,text,text,timestamptz,boolean)','EXECUTE'),
  'players cannot publish marketing campaigns');
select pg_temp.notification_event_assert(not has_function_privilege('service_role',
  'fieldrush_private.emit_notification_event(uuid,text,text,text,text,text,uuid,jsonb)','EXECUTE'),
  'service clients cannot bypass audited event publishers');
select pg_temp.notification_event_assert(has_function_privilege('service_role',
  'public.process_fieldrush_notification_events()','EXECUTE'),
  'the event worker has only its guarded public entry point');
