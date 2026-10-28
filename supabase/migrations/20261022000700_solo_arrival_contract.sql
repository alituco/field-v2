-- Arrival guidance is separate from the accepted commercial booking deadline.
-- Do not rewrite published reliability policies, prices, refunds, replacement
-- windows, payments or the historical attendance ledger to change Home copy.
create table fieldrush_private.solo_arrival_policy_versions (
  id text primary key,
  version integer not null unique check (version>0),
  arrival_lead_minutes integer not null,
  late_lead_minutes integer not null,
  late_cutoff_inclusive boolean not null check (late_cutoff_inclusive),
  late_strikes integer not null check (late_strikes>=0),
  created_at timestamptz not null default clock_timestamp(),
  check (arrival_lead_minutes>late_lead_minutes and late_lead_minutes>=0)
);
revoke all on fieldrush_private.solo_arrival_policy_versions from public,anon,authenticated;
grant select on fieldrush_private.solo_arrival_policy_versions to service_role;
create trigger protect_solo_arrival_policy_versions before update or delete
  on fieldrush_private.solo_arrival_policy_versions for each row
  execute function public.protect_append_only_reliability_rows();
insert into fieldrush_private.solo_arrival_policy_versions
  (id,version,arrival_lead_minutes,late_lead_minutes,late_cutoff_inclusive,late_strikes)
values ('solo-arrival-30-10-v1',1,30,10,true,1);

alter table public.match_reliability_terms
  add column arrival_policy_version_id text references fieldrush_private.solo_arrival_policy_versions(id),
  add column arrival_check_in_opens_at timestamptz,
  add column arrival_check_in_deadline_at timestamptz,
  add constraint solo_arrival_terms_complete check (
    (arrival_policy_version_id is null and arrival_check_in_opens_at is null and arrival_check_in_deadline_at is null)
    or (match_kind='SOLO' and arrival_policy_version_id is not null
      and arrival_check_in_opens_at is not null and arrival_check_in_deadline_at is not null
      and arrival_check_in_opens_at<arrival_check_in_deadline_at
      and arrival_check_in_deadline_at<=kickoff_at)
  );
comment on column public.match_reliability_terms.arrival_check_in_opens_at is
  'Player arrival target/reminder only; never a hard gate on referee check-in.';
comment on column public.match_reliability_terms.arrival_check_in_deadline_at is
  'Solo late-arrival threshold. Separate from the original commercial check_in_deadline_at.';

create function fieldrush_private.bind_solo_arrival_terms()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare policy fieldrush_private.solo_arrival_policy_versions%rowtype;
begin
  if new.match_kind<>'SOLO' then return new; end if;
  if new.arrival_policy_version_id is null and new.kickoff_at>clock_timestamp()
    and exists(select 1 from public.open_queue_games g where g.id=new.open_queue_game_id and g.status in ('OPEN','FULL'))
    and not exists(select 1 from fieldrush_rating_private.season_zero_matches s where s.game_id=new.open_queue_game_id)
    and not exists(select 1 from public.open_queue_events e where e.game_id=new.open_queue_game_id and e.event_type='MATCH_STARTED')
  then
    select * into policy from fieldrush_private.solo_arrival_policy_versions order by version desc limit 1;
    new.arrival_policy_version_id:=policy.id;
  elsif new.arrival_policy_version_id is not null then
    select * into policy from fieldrush_private.solo_arrival_policy_versions where id=new.arrival_policy_version_id;
  end if;
  if policy.id is not null then
    new.arrival_check_in_opens_at:=new.kickoff_at-make_interval(mins=>policy.arrival_lead_minutes);
    new.arrival_check_in_deadline_at:=new.kickoff_at-make_interval(mins=>policy.late_lead_minutes);
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.bind_solo_arrival_terms() from public,anon,authenticated,service_role;
create trigger bind_solo_arrival_terms before insert or update of kickoff_at,arrival_policy_version_id
  on public.match_reliability_terms for each row execute function fieldrush_private.bind_solo_arrival_terms();

create function fieldrush_private.sync_solo_arrival_attendance_deadline()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare deadline timestamptz;
begin
  if new.match_kind='SOLO' and new.outcome is null and new.finalized_at is null then
    select t.arrival_check_in_deadline_at into deadline from public.match_reliability_terms t where t.id=new.terms_id;
    if deadline is not null then new.check_in_deadline_at:=deadline; end if;
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.sync_solo_arrival_attendance_deadline() from public,anon,authenticated,service_role;
create trigger sync_solo_arrival_attendance_deadline before insert or update of terms_id,check_in_deadline_at
  on public.match_attendance_records for each row execute function fieldrush_private.sync_solo_arrival_attendance_deadline();

-- The game callback also covers reopening previously cancelled, unbooked
-- inventory whose reliability terms already exist and therefore need no rebind.
create function fieldrush_private.bind_solo_arrival_game()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
begin
  if new.status in ('OPEN','FULL') and new.starts_at>clock_timestamp()
    and not exists(select 1 from fieldrush_rating_private.season_zero_matches s where s.game_id=new.id)
    and not exists(select 1 from public.open_queue_events e where e.game_id=new.id and e.event_type='MATCH_STARTED') then
    update public.match_reliability_terms set arrival_policy_version_id=(
      select id from fieldrush_private.solo_arrival_policy_versions order by version desc limit 1
    ) where match_kind='SOLO' and open_queue_game_id=new.id and arrival_policy_version_id is null;
    update public.match_attendance_records a set check_in_deadline_at=t.arrival_check_in_deadline_at
      from public.match_reliability_terms t where t.open_queue_game_id=new.id and a.terms_id=t.id
        and t.arrival_policy_version_id is not null and a.is_current and a.cancelled_at is null
        and a.outcome is null and a.finalized_at is null
        and a.check_in_deadline_at is distinct from t.arrival_check_in_deadline_at;
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.bind_solo_arrival_game() from public,anon,authenticated,service_role;
create trigger z_bind_solo_arrival_game after insert or update of starts_at,status
  on public.open_queue_games for each row execute function fieldrush_private.bind_solo_arrival_game();

-- Explicitly include already-booked future Solo inventory. Retain all accepted
-- commercial terms and every referee timestamp/category/audit event. Never
-- touch finished/live/past games, clan terms or finalized/cancelled attendance.
update public.match_reliability_terms t set arrival_policy_version_id='solo-arrival-30-10-v1'
from public.open_queue_games g where t.match_kind='SOLO' and t.open_queue_game_id=g.id
  and g.status in ('OPEN','FULL') and g.starts_at>clock_timestamp()
  and not exists(select 1 from fieldrush_rating_private.season_zero_matches s where s.game_id=g.id)
  and not exists(select 1 from public.open_queue_events e where e.game_id=g.id and e.event_type='MATCH_STARTED');
update public.match_attendance_records a set check_in_deadline_at=t.arrival_check_in_deadline_at
from public.match_reliability_terms t where a.terms_id=t.id and t.arrival_policy_version_id is not null
  and a.is_current and a.cancelled_at is null and a.outcome is null and a.finalized_at is null;

-- Only attendance consumers receive this projection. Commercial quote,
-- cancellation, marketplace and replacement functions keep the original row.
create function fieldrush_private.arrival_attendance_terms(terms public.match_reliability_terms)
returns public.match_reliability_terms language plpgsql stable security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare late_strikes integer;
begin
  if terms.match_kind='SOLO' and terms.arrival_policy_version_id is not null then
    terms.check_in_opens_at:=terms.arrival_check_in_opens_at;
    terms.check_in_deadline_at:=terms.arrival_check_in_deadline_at;
    select p.late_strikes into late_strikes from fieldrush_private.solo_arrival_policy_versions p
      where p.id=terms.arrival_policy_version_id;
    terms.policy_snapshot:=jsonb_set(terms.policy_snapshot,'{solo,outcomes,late,strikes}',to_jsonb(late_strikes),false);
  end if;
  return terms;
end;
$$;
create function fieldrush_private.arrival_is_on_time(
  checked_at timestamptz,timing text,terms public.match_reliability_terms
)
returns boolean language sql immutable set search_path=pg_catalog,public,pg_temp as $$
  select case when checked_at is null then null else case
    when terms.match_kind='SOLO' and terms.arrival_policy_version_id is not null then
      case timing when 'EARLY' then true when 'LATE' then false when 'AFTER_KICKOFF' then false
        else checked_at<terms.arrival_check_in_deadline_at end
    else checked_at<=terms.check_in_deadline_at end end;
$$;
revoke all on function fieldrush_private.arrival_attendance_terms(public.match_reliability_terms),
  fieldrush_private.arrival_is_on_time(timestamptz,text,public.match_reliability_terms)
  from public,anon,authenticated,service_role;

do $migration$
declare definition text; signature text; anchor text;
begin
  foreach signature in array array[
    'public.ensure_match_attendance_records(text,uuid)',
    'public.get_match_reliability_context(text,uuid)',
    'public.referee_check_in_player(uuid,text,uuid,uuid)',
    'public.finalize_match_attendance_internal(text,uuid,uuid)'
  ] loop
    definition:=pg_get_functiondef(signature::regprocedure);
    if signature='public.get_match_reliability_context(text,uuid)' then
      anchor:='  reserve_activation_minutes := ';
      if position(anchor in definition)=0 then raise exception 'Attendance context terms contract changed.'; end if;
      definition:=replace(definition,anchor,'  terms_to_use:=fieldrush_private.arrival_attendance_terms(terms_to_use);'||E'\n'||anchor);
    else
      anchor:=substring(definition from 'terms_to_use\s*:=\s*public.ensure_match_reliability_terms\(\s*normalized_kind,\s*match_id_to_use\s*\);');
      if anchor is null then raise exception 'Attendance terms contract changed: %',signature; end if;
      definition:=replace(definition,anchor,anchor||E'\n  terms_to_use:=fieldrush_private.arrival_attendance_terms(terms_to_use);');
    end if;
    if signature='public.get_match_reliability_context(text,uuid)' then
      definition:=replace(definition,'attendance.checked_in_at <= terms_to_use.check_in_deadline_at',
        'fieldrush_private.arrival_is_on_time(attendance.checked_in_at,attendance.check_in_timing,terms_to_use)');
      definition:=replace(definition,'attendance.checked_in_at > terms_to_use.check_in_deadline_at',
        'not fieldrush_private.arrival_is_on_time(attendance.checked_in_at,attendance.check_in_timing,terms_to_use)');
      definition:=replace(definition,'''check_in_authority'', ''REFEREE'',',
        '''check_in_authority'', ''REFEREE'',''late_cutoff_inclusive'', terms_to_use.arrival_policy_version_id is not null,');
    elsif signature='public.finalize_match_attendance_internal(text,uuid,uuid)' then
      definition:=replace(definition,'attendance_to_finalize.checked_in_at <= terms_to_use.check_in_deadline_at',
        'fieldrush_private.arrival_is_on_time(attendance_to_finalize.checked_in_at,attendance_to_finalize.check_in_timing,terms_to_use)');
    end if;
    execute definition;
  end loop;

  definition:=pg_get_functiondef('public.referee_check_in_player_with_timing(uuid,text,uuid,uuid,text)'::regprocedure);
  anchor:='  actual_checked_in_at := attendance_to_use.checked_in_at;';
  if position(anchor in definition)=0 then raise exception 'Referee timing contract changed.'; end if;
  execute replace(definition,anchor,
    '  terms_to_use:=fieldrush_private.arrival_attendance_terms(terms_to_use);'||E'\n'||anchor);

  -- Default admin resolution must retain an explicit referee arrival category
  -- as well. Explicit administrator attendance overrides remain authoritative.
  definition:=pg_get_functiondef('public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'::regprocedure);
  anchor:='  policy_snapshot_to_use := case when terms_to_use.id is null';
  if position(anchor in definition)=0 then raise exception 'Admin arrival policy projection changed.'; end if;
  definition:=replace(definition,anchor,
    '  terms_to_use:=fieldrush_private.arrival_attendance_terms(terms_to_use);'||E'\n'||anchor);
  anchor:=$old$attendance_before.checked_in_at <=
                attendance_before.check_in_deadline_at$old$;
  if position(anchor in definition)=0 then raise exception 'Admin attendance fallback contract changed.'; end if;
  definition:=replace(definition,anchor,
    'fieldrush_private.arrival_is_on_time(attendance_before.checked_in_at,attendance_before.check_in_timing,terms_to_use)');
  anchor:=$old$        attendance_strikes := case
          when attendance_outcome <> 'NO_SHOW' then 0$old$;
  if position(anchor in definition)=0 then raise exception 'Solo admin attendance consequence changed.'; end if;
  definition:=replace(definition,anchor,$new$        attendance_strikes := case
          when attendance_outcome='LATE' and terms_to_use.arrival_policy_version_id is not null then
            (policy_snapshot_to_use#>>'{solo,outcomes,late,strikes}')::integer
          when attendance_outcome <> 'NO_SHOW' then 0$new$);
  anchor:=$old$            'SOLO', match_id_to_use,
            case when normalized_resolution = 'BOTH_AT_FAULT'$old$;
  if position(anchor in definition)=0 then raise exception 'Solo admin attendance incident changed.'; end if;
  definition:=replace(definition,anchor,$new$            'SOLO', match_id_to_use,
            case when attendance_outcome='LATE' then 'LATE'
              when normalized_resolution = 'BOTH_AT_FAULT'$new$);
  execute definition;
end;
$migration$;

-- Additive feed wrappers preserve every original filter, ordering, privacy
-- boundary and STABLE contract. Private aliases are never caller backdoors.
do $migration$
declare signature text; original regprocedure; name_to_use text; alias_name text;
  arguments text; identities text; result_type text; calls text; n integer;
begin
  foreach signature in array array['public.list_open_queue_games()','public.list_open_queue_fixture_games()',
    'public.list_open_queue_games_for_market(text)','public.list_open_queue_games_for_city(text)'] loop
    original:=signature::regprocedure;
    select proname,pronargs into name_to_use,n from pg_proc where oid=original;
    arguments:=pg_get_function_arguments(original); identities:=pg_get_function_identity_arguments(original);
    result_type:=pg_get_function_result(original);
    result_type:=regexp_replace(result_type,'\)$',', check_in_opens_at timestamp with time zone, check_in_deadline_at timestamp with time zone)');
    alias_name:=name_to_use||'_before_arrival_notice';
    select coalesce(string_agg('$'||i,',' order by i),'') into calls from generate_series(1,n) i;
    execute format('alter function %s rename to %I',signature,alias_name);
    execute format('revoke all on function public.%I(%s) from public,anon,authenticated,service_role',alias_name,identities);
    execute format('create function public.%I(%s) returns %s language sql stable security definer set search_path=public,pg_temp as $body$
      select row.*,terms.arrival_check_in_opens_at,terms.arrival_check_in_deadline_at
      from public.%I(%s) row left join public.match_reliability_terms terms on terms.match_kind=''SOLO'' and terms.open_queue_game_id=row.id $body$',
      name_to_use,arguments,result_type,alias_name,calls);
    execute format('revoke all on function public.%I(%s) from public,anon',name_to_use,identities);
    execute format('grant execute on function public.%I(%s) to authenticated,service_role',name_to_use,identities);
  end loop;
end;
$migration$;

alter function public.get_open_queue_match_detail(uuid) rename to get_open_queue_match_detail_before_arrival_notice;
revoke all on function public.get_open_queue_match_detail_before_arrival_notice(uuid) from public,anon,authenticated,service_role;
create function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select public.get_open_queue_match_detail_before_arrival_notice(requested.game_id)||jsonb_build_object(
    'check_in_opens_at',terms.arrival_check_in_opens_at,
    'check_in_deadline_at',terms.arrival_check_in_deadline_at,
    'late_cutoff_inclusive',terms.arrival_policy_version_id is not null
  ) from (values(game_id_to_use)) requested(game_id)
  left join public.match_reliability_terms terms on terms.match_kind='SOLO' and terms.open_queue_game_id=requested.game_id;
$$;
revoke all on function public.get_open_queue_match_detail(uuid) from public,anon;
grant execute on function public.get_open_queue_match_detail(uuid) to authenticated,service_role;
notify pgrst,'reload schema';
