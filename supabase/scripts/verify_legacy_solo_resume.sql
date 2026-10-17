-- Disposable full-schema transaction. Exercises the actual transition and
-- event/audit transaction with injected failures, not just route substitutes.
create function pg_temp.resume_expect(ok boolean,message text)
returns void language plpgsql as $$begin
  if ok is not true then raise exception 'Legacy resume: %',message; end if;
end$$;
create function pg_temp.resume_reject(statement text,pattern text)
returns void language plpgsql as $$declare denied boolean:=false; begin
  begin execute statement; exception when others then
    if sqlerrm!~*pattern then raise; end if; denied:=true;
  end;
  perform pg_temp.resume_expect(denied,'Expected rejection '||pattern);
end$$;
create function pg_temp.reject_resume_event() returns trigger language plpgsql as $$begin
  if current_setting('fieldrush.test_resume_failure',true)='event' and new.event_type='MATCH_RESUMED' then raise exception 'Injected resume event failure'; end if;
  return new;
end$$;
create trigger test_resume_event_failure before insert on public.open_queue_events for each row execute function pg_temp.reject_resume_event();
create function pg_temp.reject_resume_audit() returns trigger language plpgsql as $$begin
  if current_setting('fieldrush.test_resume_failure',true)='audit' and new.action='SOLO_CLOCK_RESUMED' then raise exception 'Injected resume audit failure'; end if;
  return new;
end$$;
create trigger test_resume_audit_failure before insert on public.admin_audit_events for each row execute function pg_temp.reject_resume_audit();

do $$
declare actor uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); game uuid; new_game uuid; reply jsonb;
  before_clock jsonb; after_clock jsonb; event_count integer; failure text;
begin
  insert into auth.users(id,phone,phone_confirmed_at) values(actor,'15558619001',now()),(outsider,'15558619002',now());
  insert into public.profiles(id,auth_user_id,display_name,phone) values(actor,actor,'Resume admin','+15558619001'),(outsider,outsider,'Unassigned referee','+15558619002');
  insert into public.referee_profiles(profile_id,display_name,phone,role,is_active) values
    (actor,'Resume admin','+15558619001','admin',true),(outsider,'Unassigned referee','+15558619002','referee',true);
  perform set_config('request.jwt.claim.role','service_role',true);
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values('Resume fixture',date_trunc('minute',now())+interval '1 hour',date_trunc('minute',now())+interval '2 hours',0) returning id into game;
  insert into public.open_queue_clock_states(game_id,status,started_at,accumulated_seconds,duration_seconds)
    values(game,'RUNNING',clock_timestamp(),900,3600);
  update public.open_queue_games set status='LIVE' where id=game;
  update public.open_queue_clock_states set status='PAUSED',started_at=null where game_id=game;
  perform pg_temp.resume_reject(format('select public.referee_resume_legacy_solo_game(%L,%L)',outsider,game),'not assigned');
  foreach failure in array array['event','audit'] loop
    perform set_config('fieldrush.test_resume_failure',failure,true);
    perform pg_temp.resume_reject(format('select public.referee_resume_legacy_solo_game(%L,%L)',actor,game),'Injected resume');
    perform pg_temp.resume_expect((select status='PAUSED' and started_at is null and accumulated_seconds=900 from public.open_queue_clock_states where game_id=game),'failure rolls back clock');
    perform pg_temp.resume_expect(not exists(select 1 from public.open_queue_events where game_id=game and event_type='MATCH_RESUMED'),'failure rolls back event');
  end loop;
  perform set_config('fieldrush.test_resume_failure','',true);
  reply:=public.referee_resume_legacy_solo_game(actor,game);
  perform pg_temp.resume_expect(reply->>'status'='RUNNING' and reply->>'accumulated_seconds'='900' and reply->>'already_running'='false','paused clock resumes once');
  -- Simulate two minutes already played after a successful resume. The old
  -- route reset this anchor and lost those minutes on a repeated request.
  update public.open_queue_clock_states set started_at=clock_timestamp()-interval '2 minutes' where game_id=game;
  select to_jsonb(c) into before_clock from public.open_queue_clock_states c where game_id=game;
  select count(*) into event_count from public.open_queue_events where game_id=game and event_type='MATCH_RESUMED';
  reply:=public.referee_resume_legacy_solo_game(actor,game);
  select to_jsonb(c) into after_clock from public.open_queue_clock_states c where game_id=game;
  perform pg_temp.resume_expect(reply->>'already_running'='true' and before_clock=after_clock,'repeated resume preserves exact running anchor and accumulated time');
  perform pg_temp.resume_expect((select count(*)=event_count from public.open_queue_events where game_id=game and event_type='MATCH_RESUMED'),'retry adds no resume event');
  update public.open_queue_games set operational_state='UNDER_REVIEW' where id=game;
  perform pg_temp.resume_reject(format('select public.referee_resume_legacy_solo_game(%L,%L)',actor,game),'unlocked live');
  update public.open_queue_games set operational_state='NORMAL' where id=game;
  perform public.admin_set_season_zero_policy(actor,true,'Disposable policy-boundary resume regression.');
  insert into public.open_queue_games(venue,starts_at,ends_at,price_fils) values('V2 resume boundary',date_trunc('minute',now())+interval '3 hours',date_trunc('minute',now())+interval '4 hours',0) returning id into new_game;
  perform pg_temp.resume_reject(format('select public.referee_resume_legacy_solo_game(%L,%L)',actor,new_game),'Season 0');
  perform pg_temp.resume_expect(not has_function_privilege('authenticated','public.referee_resume_legacy_solo_game(uuid,uuid)','EXECUTE'),'players cannot resume through service action');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform pg_temp.resume_reject(format('select public.referee_resume_legacy_solo_game(%L,%L)',actor,game),'not assigned');
end$$;
select 'Atomic legacy resume, rollback, retries and authorization passed.' as result;
