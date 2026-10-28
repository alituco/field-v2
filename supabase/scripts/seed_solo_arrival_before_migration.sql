-- True rollout fixture: run AFTER 006 but BEFORE 007 in the isolated replay.
-- Synthetic historical paid bookings are financial preservation evidence;
-- no Stripe payment is created, simulated, collected or called. Every real
-- application trigger stays enabled. The entire PGlite database is disposable.
set local client_min_messages=warning;
select set_config('request.jwt.claim.role','service_role',true);

create temporary table backfill_arrival_ids(name text primary key,id uuid not null);
create temporary table backfill_arrival_rows(kind text,id uuid,before jsonb,primary key(kind,id));
create temporary table backfill_arrival_state(name text primary key,before jsonb);
create sequence pg_temp.backfill_arrival_person;
create function pg_temp.backfill_arrival_player() returns uuid language plpgsql as $$
declare player uuid:=gen_random_uuid(); n bigint:=nextval('pg_temp.backfill_arrival_person');
begin
  insert into auth.users(id,phone,phone_confirmed_at)
    values(player,'15557842'||lpad(n::text,3,'0'),now());
  perform set_config('request.jwt.claim.sub',player::text,true);
  perform public.complete_fieldrush_onboarding(jsonb_build_object(
    'first_name','Backfill','last_name','Arrival','username','backfill_arrival_'||n,
    'date_of_birth','2000-01-01','email','backfill-arrival-'||n||'@example.test',
    'skill_assessment','intermediate'),'fieldrush-v1','fieldrush-v1');
  return player;
end;
$$;

do $seed$
declare staff uuid:=pg_temp.backfill_arrival_player(); staff_auth uuid:=gen_random_uuid();
  people uuid[]:='{}'; player uuid; game uuid; historical uuid; clan_fixture uuid;
  home_clan uuid; away_clan uuid; i integer; match_day date;
  kickoff timestamptz:=date_trunc('minute',clock_timestamp())+interval '7 days';
begin
  if exists(select 1 from pg_attribute where attrelid='public.match_reliability_terms'::regclass
    and attname='arrival_policy_version_id' and not attisdropped) then
    raise exception 'Backfill fixture must be seeded before arrival migration 007';
  end if;
  insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
    values(staff_auth,'backfill-arrival-staff@example.test',now(),'{"fieldrush_account_type":"staff"}');
  insert into public.referee_profiles(profile_id,auth_user_id,email,display_name,phone,role,is_active)
    values(staff,staff_auth,'backfill-arrival-staff@example.test','Backfill arrival referee','+15557842999','admin',true);
  for i in 1..16 loop people:=array_append(people,pg_temp.backfill_arrival_player()); end loop;

  -- Append a test-owned copy effective before the historical control. Existing
  -- published policies and their append-only protections are never modified.
  insert into public.reliability_policy_versions(version,state,effective_from,config,summary,published_at,published_by)
    select (select max(version)+1 from public.reliability_policy_versions),'PUBLISHED',
      date_trunc('day',(now()-interval '1 day') at time zone 'Asia/Bahrain') at time zone 'Asia/Bahrain',
      config,'Isolated pre-migration arrival backfill fixture.',now(),staff
      from public.reliability_policy_versions order by version limit 1;

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Pre-007 already paid Solo',kickoff,kickoff+interval '1 hour',13000,staff)
    returning id into game;
  for i in 1..3 loop
    insert into public.open_queue_bookings(game_id,profile_id,role,status,
      amount_paid_fils,base_amount_fils,payment_method,payment_reference)
      values(game,people[i],'DEF','CONFIRMED',13000,13000,'CARD','synthetic-pre-007-paid-'||i);
  end loop;
  perform set_config('request.jwt.claim.sub',staff_auth::text,true);
  perform public.referee_check_in_player_with_timing(staff,'SOLO',game,people[1],'EARLY');
  perform public.referee_check_in_player_with_timing(staff,'SOLO',game,people[2],'LATE');
  -- A prior finalized decision is a separate control even on future inventory.
  update public.match_attendance_records set outcome='EXCUSED',finalized_at=clock_timestamp()
    where open_queue_game_id=game and profile_id=people[3] and is_current;

  insert into public.open_queue_games(status,venue,starts_at,ends_at,price_fils,created_by)
    values('OPEN','Pre-007 historical Solo',date_trunc('minute',now())-interval '2 hours',
      date_trunc('minute',now())-interval '1 hour',0,staff)
    returning id into historical;
  perform public.ensure_match_reliability_terms('SOLO',historical);

  -- A genuine Clan terms row proves the rollout is Solo-only.
  insert into public.clans(name,tag,created_by) values('Arrival backfill home','ABH',staff) returning id into home_clan;
  insert into public.clans(name,tag,created_by) values('Arrival backfill away','ABA',people[4]) returning id into away_clan;
  for i in 5..10 loop insert into public.clan_members(clan_id,profile_id) values(home_clan,people[i]); end loop;
  for i in 11..16 loop insert into public.clan_members(clan_id,profile_id) values(away_clan,people[i]); end loop;
  select d::date into match_day from generate_series(current_date+7,current_date+14,interval '1 day') d
    where extract(isodow from d) in (2,5) order by d limit 1;
  update public.game_payment_settings set clan_enabled=true where singleton;
  insert into public.fixtures(status,home_clan_id,away_clan_id,venue,day,time_slot,match_date,created_by)
    values('SCHEDULED',home_clan,away_clan,'Pre-007 Clan control',
      case when extract(isodow from match_day)=2 then 'TUESDAY' else 'FRIDAY' end,
      '7:00 PM - 8:00 PM',match_day,staff) returning id into clan_fixture;
  perform public.ensure_match_reliability_terms('CLAN',clan_fixture);

  insert into backfill_arrival_ids values('game',game),('historical',historical),('clan',clan_fixture),
    ('early_player',people[1]),('late_player',people[2]),('finalized_player',people[3]);
  insert into backfill_arrival_rows select 'game',id,to_jsonb(g) from public.open_queue_games g where id in(game,historical);
  insert into backfill_arrival_rows select 'terms',id,to_jsonb(t) from public.match_reliability_terms t
    where open_queue_game_id in(game,historical) or fixture_id=clan_fixture;
  insert into backfill_arrival_rows select 'booking',id,to_jsonb(b) from public.open_queue_bookings b where game_id=game;
  insert into backfill_arrival_rows select 'attendance',id,to_jsonb(a) from public.match_attendance_records a where open_queue_game_id=game;
  insert into backfill_arrival_rows select 'fixture',id,to_jsonb(f) from public.fixtures f where id=clan_fixture;

  insert into backfill_arrival_state values
    ('policies',(select jsonb_agg(to_jsonb(x) order by id) from public.reliability_policy_versions x)),
    ('attendance_events',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from public.attendance_events x)),
    ('audit_events',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from public.admin_audit_events x)),
    ('wallet_transactions',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from public.field_wallet_transactions x)),
    ('payment_intents',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from public.payment_intents x)),
    ('payment_refunds',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from public.payment_refunds x));
end;
$seed$;
select 'Seeded before 007: already paid future Solo, manual Early/Late, finalized attendance, historical Solo and Clan controls' as result;
