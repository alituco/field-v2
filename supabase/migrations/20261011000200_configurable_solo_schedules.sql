-- Prospective schedules only: no existing game, booking, price or location is
-- rewritten. Each generated date is remembered even after cancellation/deletion.
drop index if exists public.open_queue_games_one_active_start_idx;
drop index if exists public.open_queue_games_venue_start_unique_idx;
create unique index open_queue_games_legacy_start_unique_idx
  on public.open_queue_games(starts_at) where field_id is null and status <> 'CANCELLED';

create or replace function public.enforce_open_queue_permanent_schedule()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare local_start timestamp; duration_seconds numeric;
begin
  if new.starts_at is null or new.ends_at is null then raise exception 'Games need a start and end time.'; end if;
  if tg_op = 'UPDATE' and old.format_version = 'FIELDRUSH_7V7'
    and row(new.starts_at,new.ends_at) is distinct from row(old.starts_at,old.ends_at) then
    raise exception 'A scheduled game time or duration cannot be changed. Cancel and recreate the game instead.';
  end if;
  local_start := new.starts_at at time zone new.timezone;
  if new.format_version = 'FIELDRUSH_7V7' then
    if new.timezone is distinct from 'America/Phoenix' then raise exception 'Fieldrush games must use America/Phoenix time.'; end if;
    duration_seconds := extract(epoch from new.ends_at-new.starts_at);
    if duration_seconds < 1800 or duration_seconds > 10800 or mod(duration_seconds,60) <> 0
      or extract(second from local_start) <> 0 then
      raise exception 'Use a whole-minute kickoff and a duration between 30 and 180 whole minutes.';
    end if;
  else
    if new.timezone is distinct from 'Asia/Bahrain' or extract(isodow from local_start) not in (2,5)
      or local_start::time <> time '20:30' or new.ends_at <> new.starts_at + interval '1 hour' then
      raise exception 'Solo games run Tuesday or Friday, 8:30–9:30 PM in the game timezone.';
    end if;
  end if;
  if new.status <> 'CANCELLED' then
    if new.field_id is not null then
      -- One lock per actual pitch, not its mutable display name. It covers
      -- overlapping starts, midnight and concurrent one-off/scheduler inserts.
      perform pg_advisory_xact_lock(hashtextextended('open-queue-field|' || new.field_id::text,0));
      if exists(select 1 from public.open_queue_games g where g.field_id=new.field_id
        and g.status <> 'CANCELLED' and g.id <> new.id
        and g.starts_at < new.ends_at and g.ends_at > new.starts_at) then
        raise exception 'This field already has a game overlapping that time. Choose another field or time.';
      end if;
    else
      perform pg_advisory_xact_lock(hashtextextended('open-queue-start|' || extract(epoch from new.starts_at)::text,0));
      if exists(select 1 from public.open_queue_games g where g.field_id is null
        and g.starts_at=new.starts_at and g.status <> 'CANCELLED' and g.id <> new.id) then
        raise exception 'An Open Queue game already exists at that start time.';
      end if;
    end if;
  end if;
  return new;
end;
$$;
drop trigger enforce_open_queue_permanent_schedule on public.open_queue_games;
create trigger enforce_open_queue_permanent_schedule
  before insert or update of status,starts_at,ends_at,timezone,field_id on public.open_queue_games
  for each row execute function public.enforce_open_queue_permanent_schedule();
revoke all on function public.enforce_open_queue_permanent_schedule() from public,anon,authenticated;

create function public.admin_create_open_queue_game(
  actor_admin_id uuid, field_id_to_use uuid, starts_at_to_use timestamptz,
  price_fils_to_use integer, age_label_to_use text, duration_minutes_to_use integer
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare created_game public.open_queue_games%rowtype; age_text text := trim(coalesce(age_label_to_use,''));
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if field_id_to_use is null then raise exception 'Choose a saved field before creating the game.'; end if;
  if char_length(age_text) not between 2 and 40 then raise exception 'Age label must be between 2 and 40 characters.'; end if;
  if starts_at_to_use is null or starts_at_to_use <= now() then raise exception 'The solo game must be scheduled in the future.'; end if;
  if duration_minutes_to_use is null or duration_minutes_to_use not between 30 and 180 then
    raise exception 'Duration must be between 30 and 180 whole minutes.';
  end if;
  if price_fils_to_use is null or price_fils_to_use not between 0 and 100000 or price_fils_to_use % 10 <> 0 then
    raise exception 'Price must be between 0 and 100 USD, in whole cents.';
  end if;
  insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by)
  values('OPEN',field_id_to_use,'Saved field',starts_at_to_use,starts_at_to_use+make_interval(mins=>duration_minutes_to_use),
    'America/Phoenix',price_fils_to_use,age_text,actor_admin_id) returning * into created_game;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'SOLO_GAME_CREATED','SOLO_MATCH',created_game.id,
    'Admin created a one-off solo game at a saved field.','{}',to_jsonb(created_game));
  return created_game.id;
end;
$$;
-- Older clients keep their existing 60-minute contract, now on any date/time.
create or replace function public.admin_create_open_queue_game(
  actor_admin_id uuid,field_id_to_use uuid,starts_at_to_use timestamptz,price_fils_to_use integer,age_label_to_use text
)
returns uuid language sql security definer set search_path = public, pg_temp as $$
  select public.admin_create_open_queue_game(actor_admin_id,field_id_to_use,starts_at_to_use,
    price_fils_to_use,age_label_to_use,60);
$$;
revoke all on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer) from public,anon,authenticated;
grant execute on function public.admin_create_open_queue_game(uuid,uuid,timestamptz,integer,text,integer) to service_role;

-- Keep all the existing attendance/authorization logic in the start RPC. Only
-- its nominal-duration fallback and upper bound change; live referee overrides
-- remain possible and existing stored clocks are not modified.
do $migration$
declare definition text; old_clause text := 'least(7200, coalesce(duration_seconds_to_use, 3600))';
begin
  select pg_get_functiondef('public.referee_start_open_queue_game(uuid,uuid[],integer)'::regprocedure) into definition;
  if position(old_clause in definition)=0 then raise exception 'Could not locate solo start duration guard.'; end if;
  definition:=replace(definition,old_clause,
    'least(10800, coalesce(duration_seconds_to_use, extract(epoch from (game_to_start.ends_at-game_to_start.starts_at))::integer, 3600))');
  execute definition;
end;
$migration$;

create table public.game_schedules (
  id uuid primary key default gen_random_uuid(),
  name text not null check(char_length(trim(name)) between 2 and 80),
  field_id uuid not null references public.fields(id) on delete restrict,
  weekdays integer[] not null check(cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]
    and array_position(weekdays,null) is null),
  kickoff_time time not null check(extract(second from kickoff_time)=0 and kickoff_time < time '24:00'),
  duration_minutes integer not null default 60 check(duration_minutes between 30 and 180),
  starts_on date not null check(isfinite(starts_on)),
  ends_on date check(ends_on is null or (isfinite(ends_on) and ends_on>=starts_on)),
  booking_window_days integer not null default 28 check(booking_window_days between 7 and 84),
  price_fils integer not null default 13000 check(price_fils between 0 and 100000 and price_fils%10=0),
  age_label text not null default '18+' check(char_length(trim(age_label)) between 2 and 40),
  is_active boolean not null default true,
  timezone text not null default 'America/Phoenix' check(timezone='America/Phoenix'),
  created_by uuid not null references public.referee_profiles(profile_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger set_game_schedules_updated_at before update on public.game_schedules
  for each row execute function public.set_updated_at();
create index game_schedules_active_idx on public.game_schedules(is_active,created_at);
create table public.game_schedule_skips (
  schedule_id uuid not null references public.game_schedules(id) on delete restrict,
  match_date date not null check(isfinite(match_date)),
  reason text not null check(char_length(trim(reason)) between 3 and 500),
  created_by uuid not null references public.referee_profiles(profile_id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(schedule_id,match_date)
);
create table public.game_schedule_occurrences (
  schedule_id uuid not null references public.game_schedules(id) on delete restrict,
  match_date date not null,
  game_id uuid unique references public.open_queue_games(id) on delete set null,
  status text not null check(status in ('CREATED','CONFLICT','SKIPPED')),
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(schedule_id,match_date)
);
create trigger set_game_schedule_occurrences_updated_at before update on public.game_schedule_occurrences
  for each row execute function public.set_updated_at();
alter table public.game_schedules enable row level security;
alter table public.game_schedule_skips enable row level security;
alter table public.game_schedule_occurrences enable row level security;
revoke all on public.game_schedules,public.game_schedule_skips,public.game_schedule_occurrences from public,anon,authenticated,service_role;
grant select on public.game_schedules,public.game_schedule_skips,public.game_schedule_occurrences to service_role;

create function fieldrush_private.generate_game_schedule(schedule_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.game_schedules%rowtype; day_to_use date; local_today date;
  start_at timestamptz; game public.open_queue_games%rowtype; occurrence public.game_schedule_occurrences%rowtype;
  created_count integer:=0; conflict_count integer:=0; skipped_count integer:=0; problem text;
begin
  -- Same lock order in generation, edits and skips. Two workers can never
  -- materialize the same schedule/date, including after cancellation/deletion.
  select * into s from public.game_schedules where id=schedule_id_to_use for update;
  if s.id is null then raise exception 'Schedule not found.'; end if;
  if not s.is_active then return jsonb_build_object('created',0,'conflicts',0,'skipped',0); end if;
  local_today := (now() at time zone s.timezone)::date;
  for day_to_use in select day::date from generate_series(
    greatest(s.starts_on,local_today)::timestamp,
    least(coalesce(s.ends_on,local_today+s.booking_window_days-1),local_today+s.booking_window_days-1)::timestamp,
    interval '1 day') day
    where extract(isodow from day)::integer=any(s.weekdays)
  loop
    start_at := (day_to_use+s.kickoff_time) at time zone s.timezone;
    if start_at<=now() then continue; end if;
    select * into occurrence from public.game_schedule_occurrences
      where schedule_id=s.id and match_date=day_to_use;
    if occurrence.status='CREATED' then continue; end if;
    if exists(select 1 from public.game_schedule_skips where schedule_id=s.id and match_date=day_to_use) then
      insert into public.game_schedule_occurrences(schedule_id,match_date,status)
      values(s.id,day_to_use,'SKIPPED') on conflict(schedule_id,match_date)
      do update set status='SKIPPED',error_message=null;
      skipped_count:=skipped_count+1;
      continue;
    end if;
    begin
      -- The existing field-binding trigger snapshots the active catalog record.
      -- The pitch-overlap trigger serializes this with every manual game too.
      insert into public.open_queue_games(status,field_id,venue,starts_at,ends_at,timezone,price_fils,age_label,created_by)
      values('OPEN',s.field_id,'Saved field',start_at,start_at+make_interval(mins=>s.duration_minutes),
        s.timezone,s.price_fils,s.age_label,s.created_by) returning * into game;
      insert into public.game_schedule_occurrences(schedule_id,match_date,game_id,status)
      values(s.id,day_to_use,game.id,'CREATED') on conflict(schedule_id,match_date)
      do update set game_id=excluded.game_id,status='CREATED',error_message=null;
      insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
      values(s.created_by,'SOLO_GAME_SCHEDULED','SOLO_MATCH',game.id,
        'Generated from recurring schedule '||s.name||'.','{}',to_jsonb(game)||jsonb_build_object('schedule_id',s.id));
      created_count:=created_count+1;
    exception when others then
      -- A failed occurrence must remain visible and retryable, not abort other
      -- dates or disappear silently. SQL error detail never contains secrets.
      get stacked diagnostics problem=message_text;
      insert into public.game_schedule_occurrences(schedule_id,match_date,status,error_message)
      values(s.id,day_to_use,'CONFLICT',left(problem,500)) on conflict(schedule_id,match_date)
      do update set status='CONFLICT',error_message=excluded.error_message;
      conflict_count:=conflict_count+1;
    end;
  end loop;
  return jsonb_build_object('created',created_count,'conflicts',conflict_count,'skipped',skipped_count);
end;
$$;
revoke all on function fieldrush_private.generate_game_schedule(uuid) from public,anon,authenticated,service_role;

create function public.admin_save_game_schedule(actor_admin_id uuid,schedule_id_to_update uuid,values_to_use jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare before_schedule public.game_schedules%rowtype; saved public.game_schedules%rowtype;
  merged jsonb; key text; normalized_days integer[]; active_field boolean;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  if values_to_use is null or jsonb_typeof(values_to_use)<>'object' or values_to_use='{}'::jsonb
    or exists(select 1 from jsonb_object_keys(values_to_use) k where k not in
      ('name','field_id','weekdays','kickoff_time','duration_minutes','starts_on','ends_on','booking_window_days','price_fils','age_label','is_active')) then
    raise exception 'Invalid schedule details.';
  end if;
  if schedule_id_to_update is not null then
    select * into before_schedule from public.game_schedules where id=schedule_id_to_update for update;
    if before_schedule.id is null then raise exception 'Schedule not found.'; end if;
    merged:=to_jsonb(before_schedule)||values_to_use;
  else
    merged:=jsonb_build_object('duration_minutes',60,'booking_window_days',28,'price_fils',13000,'age_label','18+','is_active',true,'ends_on',null)||values_to_use;
  end if;
  foreach key in array array['name','field_id','kickoff_time','starts_on','age_label'] loop
    if jsonb_typeof(merged->key) is distinct from 'string' then raise exception 'Schedule % must be text.',key; end if;
  end loop;
  if jsonb_typeof(merged->'ends_on') not in ('string','null') then raise exception 'Schedule end date must be a date or empty.'; end if;
  foreach key in array array['duration_minutes','booking_window_days','price_fils'] loop
    if jsonb_typeof(merged->key) is distinct from 'number' or merged->>key !~ '^[0-9]+$' then
      raise exception 'Schedule % must be a whole number.',key;
    end if;
  end loop;
  if jsonb_typeof(merged->'is_active') is distinct from 'boolean' then raise exception 'Active status must be true or false.'; end if;
  if jsonb_typeof(merged->'weekdays') is distinct from 'array' then raise exception 'Choose one or more weekdays.'; end if;
  if jsonb_array_length(merged->'weekdays') not between 1 and 7 or exists(
    select 1 from jsonb_array_elements(merged->'weekdays') value
    where jsonb_typeof(value)<>'number' or value::text !~ '^[1-7]$') then
    raise exception 'Choose weekdays from Monday (1) through Sunday (7).';
  end if;
  select array_agg(distinct value::text::integer order by value::text::integer) into normalized_days
    from jsonb_array_elements(merged->'weekdays') value;
  if cardinality(normalized_days)<>jsonb_array_length(merged->'weekdays') then raise exception 'Choose each weekday only once.'; end if;
  if merged->>'starts_on' !~ '^\d{4}-\d{2}-\d{2}$' or
    (merged->>'ends_on' is not null and merged->>'ends_on' !~ '^\d{4}-\d{2}-\d{2}$') or
    merged->>'kickoff_time' !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:00)?$' then
    raise exception 'Use valid calendar dates and a whole-minute kickoff time.';
  end if;
  select is_active into active_field from public.fields where id=(merged->>'field_id')::uuid for share;
  if active_field is null or (not active_field and (merged->>'is_active')::boolean) then
    raise exception 'Choose an active saved field before enabling this schedule.';
  end if;
  if schedule_id_to_update is null then
    insert into public.game_schedules(name,field_id,weekdays,kickoff_time,duration_minutes,starts_on,ends_on,
      booking_window_days,price_fils,age_label,is_active,created_by)
    values(trim(merged->>'name'),(merged->>'field_id')::uuid,normalized_days,(merged->>'kickoff_time')::time,
      (merged->>'duration_minutes')::integer,(merged->>'starts_on')::date,(merged->>'ends_on')::date,
      (merged->>'booking_window_days')::integer,(merged->>'price_fils')::integer,trim(merged->>'age_label'),
      (merged->>'is_active')::boolean,actor_admin_id) returning * into saved;
  else
    update public.game_schedules set name=trim(merged->>'name'),field_id=(merged->>'field_id')::uuid,weekdays=normalized_days,
      kickoff_time=(merged->>'kickoff_time')::time,duration_minutes=(merged->>'duration_minutes')::integer,
      starts_on=(merged->>'starts_on')::date,ends_on=(merged->>'ends_on')::date,booking_window_days=(merged->>'booking_window_days')::integer,
      price_fils=(merged->>'price_fils')::integer,age_label=trim(merged->>'age_label'),is_active=(merged->>'is_active')::boolean
      where id=schedule_id_to_update returning * into saved;
  end if;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,case when before_schedule.id is null then 'GAME_SCHEDULE_CREATED'
    when before_schedule.is_active and not saved.is_active then 'GAME_SCHEDULE_PAUSED'
    when not before_schedule.is_active and saved.is_active then 'GAME_SCHEDULE_RESUMED' else 'GAME_SCHEDULE_UPDATED' end,
    'ACTION',saved.id,'Changed recurring schedule. Existing games remain unchanged.',
    case when before_schedule.id is null then '{}'::jsonb else to_jsonb(before_schedule) end,to_jsonb(saved));
  if before_schedule.id is not null and values_to_use ?| array['field_id','weekdays','kickoff_time',
    'duration_minutes','starts_on','ends_on','booking_window_days','price_fils','age_label'] then
    -- Unmaterialized failures belong to the old rule and must not remain as
    -- misleading alerts after a date/time/field change. Explicit skip dates stay
    -- in the skip table and are reapplied if the new rule includes that date.
    -- CREATED includes cancelled/deleted games: those tombstones NEVER reset.
    delete from public.game_schedule_occurrences where schedule_id=saved.id and status<>'CREATED';
  end if;
  perform fieldrush_private.generate_game_schedule(saved.id);
  return to_jsonb(saved);
end;
$$;
revoke all on function public.admin_save_game_schedule(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.admin_save_game_schedule(uuid,uuid,jsonb) to service_role;

create function public.admin_set_game_schedule_skip(
  actor_admin_id uuid,schedule_id_to_use uuid,match_date_to_use date,reason_to_use text,skip_to_use boolean
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.game_schedules%rowtype; before_skip public.game_schedule_skips%rowtype;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  select * into s from public.game_schedules where id=schedule_id_to_use for update;
  if s.id is null then raise exception 'Schedule not found.'; end if;
  if skip_to_use is null or match_date_to_use is null or not isfinite(match_date_to_use)
    or match_date_to_use<(now() at time zone s.timezone)::date then raise exception 'Choose a current or future date.'; end if;
  if skip_to_use and (match_date_to_use<s.starts_on or (s.ends_on is not null and match_date_to_use>s.ends_on)
    or not extract(isodow from match_date_to_use)::integer=any(s.weekdays)) then
    raise exception 'Choose a date included in this schedule.';
  end if;
  if char_length(trim(coalesce(reason_to_use,''))) not between 3 and 500 then raise exception 'Provide a reason between 3 and 500 characters.'; end if;
  if skip_to_use and exists(select 1 from public.game_schedule_occurrences o
    join public.open_queue_games g on g.id=o.game_id where o.schedule_id=s.id
      and o.match_date=match_date_to_use and g.status<>'CANCELLED') then
    raise exception 'A game already exists on this date. Cancel it from its game page first; skipping never cancels bookings.';
  end if;
  select * into before_skip from public.game_schedule_skips where schedule_id=s.id and match_date=match_date_to_use;
  if skip_to_use then
    insert into public.game_schedule_skips(schedule_id,match_date,reason,created_by)
    values(s.id,match_date_to_use,trim(reason_to_use),actor_admin_id) on conflict(schedule_id,match_date)
    do update set reason=excluded.reason,created_by=excluded.created_by,created_at=now();
  else
    delete from public.game_schedule_skips where schedule_id=s.id and match_date=match_date_to_use;
    -- Only an unmaterialized skip can be cleared. CREATED tombstones survive.
    delete from public.game_schedule_occurrences where schedule_id=s.id and match_date=match_date_to_use and status='SKIPPED';
  end if;
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,case when skip_to_use then 'GAME_SCHEDULE_DATE_SKIPPED' else 'GAME_SCHEDULE_SKIP_REMOVED' end,
    'ACTION',s.id,trim(reason_to_use),case when before_skip.schedule_id is null then '{}'::jsonb else to_jsonb(before_skip) end,
    jsonb_build_object('schedule_id',s.id,'match_date',match_date_to_use,'skipped',skip_to_use));
  perform fieldrush_private.generate_game_schedule(s.id);
  return jsonb_build_object('schedule_id',s.id,'match_date',match_date_to_use,'skipped',skip_to_use);
end;
$$;
revoke all on function public.admin_set_game_schedule_skip(uuid,uuid,date,text,boolean) from public,anon,authenticated;
grant execute on function public.admin_set_game_schedule_skip(uuid,uuid,date,text,boolean) to service_role;

create function public.admin_generate_game_schedule(actor_admin_id uuid,schedule_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then raise exception 'Admin referee access required.'; end if;
  result:=fieldrush_private.generate_game_schedule(schedule_id_to_use);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
  values(actor_admin_id,'GAME_SCHEDULE_GENERATED','ACTION',schedule_id_to_use,'Admin refreshed the booking window.','{}',result);
  return result;
end;
$$;
revoke all on function public.admin_generate_game_schedule(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_generate_game_schedule(uuid,uuid) to service_role;

create function fieldrush_private.generate_due_game_schedules()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare schedule_id uuid;
begin
  -- Never wait on a schedule being edited while retaining the advisory pitch
  -- locks from an earlier schedule in this batch. The edited schedule is
  -- generated by its save transaction, or picked up by the next hourly run.
  for schedule_id in select id from public.game_schedules where is_active order by id for update skip locked loop
    perform fieldrush_private.generate_game_schedule(schedule_id);
  end loop;
end;
$$;
revoke all on function fieldrush_private.generate_due_game_schedules() from public,anon,authenticated,service_role;
-- pg_cron is already provisioned by the earlier reliability/payment migrations.
select cron.schedule('fieldrush-game-schedule-generation','7 * * * *','select fieldrush_private.generate_due_game_schedules();');
notify pgrst,'reload schema';
