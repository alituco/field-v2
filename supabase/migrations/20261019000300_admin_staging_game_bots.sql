-- Installed inert everywhere. Only after verifying the staging database target,
-- a database administrator may run:
-- update fieldrush_private.staging_bot_controls set enabled=true where singleton;
-- Never enable this control in production. The admin HTTP route separately
-- requires the exact staging Supabase project and staging app environment.
create table fieldrush_private.staging_bot_controls (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false
);
insert into fieldrush_private.staging_bot_controls(singleton) values(true);
create table fieldrush_private.staging_bot_fill_requests (
  request_id uuid primary key,
  game_id uuid not null references public.open_queue_games(id) on delete restrict,
  actor_admin_id uuid not null references public.referee_profiles(profile_id),
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
create table fieldrush_private.staging_bot_profiles (
  profile_id uuid primary key references public.profiles(id) on delete restrict,
  game_id uuid not null references public.open_queue_games(id) on delete restrict,
  booking_id uuid not null unique,
  request_id uuid not null,
  role text not null check(role in ('GK','DEF','ATT')),
  created_by uuid not null references public.referee_profiles(profile_id),
  created_at timestamptz not null default clock_timestamp()
);
alter table fieldrush_private.staging_bot_controls enable row level security;
alter table fieldrush_private.staging_bot_fill_requests enable row level security;
alter table fieldrush_private.staging_bot_profiles enable row level security;
revoke all on fieldrush_private.staging_bot_controls,fieldrush_private.staging_bot_fill_requests,
  fieldrush_private.staging_bot_profiles from public,anon,authenticated,service_role;

create function fieldrush_private.is_staging_bot_fill_participant(profile_to_check uuid,game_to_check uuid,role_to_check text default null)
returns boolean language sql stable security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
  select coalesce(auth.role()='service_role'
    and nullif(current_setting('fieldrush.staging_bot_fill_game',true),'')=game_to_check::text
    and exists(select 1 from fieldrush_private.staging_bot_controls where singleton and enabled)
    and exists(select 1 from fieldrush_private.staging_bot_profiles b join public.profiles p on p.id=b.profile_id
      where b.profile_id=profile_to_check and b.game_id=game_to_check
        and (role_to_check is null or b.role=role_to_check)
        and p.auth_user_id is null and p.account_deleted_at is null),false);
$$;
revoke all on function fieldrush_private.is_staging_bot_fill_participant(uuid,uuid,text) from public,anon,authenticated,service_role;

-- Authless test profiles cannot pass active account validation. This exception
-- covers exactly the registry-owned booking during the atomic fill operation;
-- it never makes a bot an active account or relaxes clan/follow/staff gates.
create or replace function fieldrush_private.require_completed_participant()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,auth,fieldrush_private,pg_temp as $$
declare participant uuid:=(to_jsonb(new)->>tg_argv[0])::uuid;
begin
  if tg_table_schema='public' and tg_table_name='open_queue_bookings' then
    if fieldrush_private.is_staging_bot_fill_participant(participant,new.game_id,new.role)
      and exists(select 1 from fieldrush_private.staging_bot_profiles where profile_id=participant
        and game_id=new.game_id and booking_id=new.id) then return new; end if;
  end if;
  perform 1 from fieldrush_private.accounts where user_id=participant for share;
  if not public.is_fieldrush_account_active(participant) then
    raise exception 'Complete Fieldrush signup before joining games or players.' using errcode='42501';
  end if;
  return new;
end;
$$;

-- Do not invent played games to reveal placement for a bot in a restricted
-- division. Real players keep the installed lifetime-placement eligibility.
alter function public.assert_open_queue_division_eligibility(uuid,uuid,text)
  rename to assert_open_queue_division_eligibility_before_staging_bots;
revoke all on function public.assert_open_queue_division_eligibility_before_staging_bots(uuid,uuid,text)
  from public,anon,authenticated,service_role;
create function public.assert_open_queue_division_eligibility(player_id_to_check uuid,game_id_to_check uuid,role_to_use text)
returns void language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
begin
  if fieldrush_private.is_staging_bot_fill_participant(player_id_to_check,game_id_to_check,role_to_use) then return; end if;
  perform public.assert_open_queue_division_eligibility_before_staging_bots(player_id_to_check,game_id_to_check,role_to_use);
end;
$$;
revoke all on function public.assert_open_queue_division_eligibility(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.assert_open_queue_division_eligibility(uuid,uuid,text) to service_role;

-- A final booking can invoke the legacy timed automatic team reveal. Filling
-- test seats does not lock teams; the existing Lock teams action remains separate.
alter function public.assign_open_queue_teams(uuid) rename to assign_open_queue_teams_before_staging_bots;
revoke all on function public.assign_open_queue_teams_before_staging_bots(uuid) from public,anon,authenticated,service_role;
create function public.assign_open_queue_teams(game_id_to_assign uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
begin
  if auth.role()='service_role'
    and nullif(current_setting('fieldrush.staging_bot_fill_game',true),'')=game_id_to_assign::text
    and exists(select 1 from fieldrush_private.staging_bot_controls where singleton and enabled) then return; end if;
  perform public.assign_open_queue_teams_before_staging_bots(game_id_to_assign);
end;
$$;
revoke all on function public.assign_open_queue_teams(uuid) from public,anon,authenticated;
grant execute on function public.assign_open_queue_teams(uuid) to service_role;

-- Legacy incomplete-roster callbacks rewrite every existing booking even when
-- its values are already null. Test-seat insertion must not touch real rows or
-- their update timestamps. Retain every installed callback outside this branch.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('public.sync_open_queue_game_status()'::regprocedure);
  if position(E'begin\n' in definition)=0 then raise exception 'Booking status callback contract changed.'; end if;
  definition:=replace(definition,E'begin\n',$branch$begin
  if tg_op='INSERT' and fieldrush_private.is_staging_bot_fill_participant(new.profile_id,new.game_id,new.role)
    and exists(select 1 from fieldrush_private.staging_bot_profiles where profile_id=new.profile_id and booking_id=new.id) then
    update public.open_queue_games g set status=case when
      (select count(*) from public.open_queue_bookings b where b.game_id=g.id and b.status='CONFIRMED')>=g.capacity
      then 'FULL' else 'OPEN' end where g.id=new.game_id and g.status in ('OPEN','FULL');
    return new;
  end if;
$branch$);
  execute definition;
end;
$migration$;

create function public.admin_fill_open_queue_game_with_bots(actor_admin_id uuid,game_id_to_use uuid,request_id_to_use uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,fieldrush_private,fieldrush_rating_private,pg_temp as $$
declare g public.open_queue_games%rowtype; prior fieldrush_private.staging_bot_fill_requests%rowtype;
  response jsonb; role_to_fill text; role_capacity integer; occupied integer; total_confirmed integer;
  added integer:=0; bot_id uuid; booking_id_to_use uuid; ordinal integer;
  original_context text:=current_setting('fieldrush.staging_bot_fill_game',true);
begin
  if auth.role() is distinct from 'service_role' or not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access through the staging service is required.' using errcode='42501';
  end if;
  perform 1 from fieldrush_private.staging_bot_controls where singleton and enabled for share;
  if not found then raise exception 'Staging bot tools are not enabled in this database.' using errcode='42501'; end if;
  if game_id_to_use is null or request_id_to_use is null then raise exception 'Provide a game and unique request ID.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staging-bot-request:'||request_id_to_use::text,0));
  select * into prior from fieldrush_private.staging_bot_fill_requests where request_id=request_id_to_use;
  if found then
    if row(prior.game_id,prior.actor_admin_id) is distinct from row(game_id_to_use,actor_admin_id) then
      raise exception 'This request ID belongs to another bot-fill action.' using errcode='22023';
    end if;
    return prior.response;
  end if;
  -- START uses rating-global -> game ordering. Booking triggers retain their
  -- existing capacity/player checks and cannot race kickoff through this lock.
  perform pg_advisory_xact_lock(hashtextextended('fieldrush-season-zero-rating',0));
  select * into g from public.open_queue_games where id=game_id_to_use for update;
  if g.id is null then raise exception 'Game not found.' using errcode='22023'; end if;
  if g.format_version<>'FIELDRUSH_7V7' or g.status not in ('OPEN','FULL')
    or g.operational_state<>'NORMAL' or g.starts_at<=clock_timestamp()
    or g.white_score is not null or g.black_score is not null
    or exists(select 1 from public.open_queue_clock_states where game_id=g.id
      and (status<>'NOT_STARTED' or started_at is not null or accumulated_seconds<>0))
    or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=g.id) then
    raise exception 'Only an upcoming, unstarted solo game without an active review can be filled.' using errcode='22023';
  end if;
  select count(*) into total_confirmed from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
  if total_confirmed>g.capacity then raise exception 'The saved roster exceeds this game capacity.'; end if;
  if total_confirmed<g.capacity and (g.teams_assigned_at is not null or exists(
    select 1 from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and (team is not null or played)
  )) then raise exception 'Teams are already locked. Fill only an unassigned game.' using errcode='22023'; end if;
  -- A paid or provider-backed pending checkout can still finalize after its
  -- local expiry. Preserve those attempts instead of taking their remaining seats.
  if total_confirmed<g.capacity and exists(select 1 from public.payment_intents i
    where i.purpose='SOLO_BOOKING' and i.payload->>'game_id'=g.id::text
      and i.status in ('PENDING','PROCESSING','CAPTURED','PAID','REQUIRES_REFUND')) then
    raise exception 'Resolve the game’s pending checkout or payment before adding bots.' using errcode='40001';
  end if;
  perform set_config('fieldrush.staging_bot_fill_game',g.id::text,true);
  select count(*) into ordinal from fieldrush_private.staging_bot_profiles where game_id=g.id;
  foreach role_to_fill in array array['GK','DEF','ATT'] loop
    role_capacity:=case role_to_fill when 'GK' then g.goalkeeper_capacity when 'DEF' then g.defender_capacity else g.attacker_capacity end;
    select count(*) into occupied from public.open_queue_bookings where game_id=g.id and status='CONFIRMED' and role=role_to_fill;
    if occupied>role_capacity then raise exception 'The saved position roster exceeds its configured capacity.'; end if;
    for slot in 1..(role_capacity-occupied) loop
      bot_id:=gen_random_uuid(); booking_id_to_use:=gen_random_uuid(); ordinal:=ordinal+1;
      insert into public.profiles(id,auth_user_id,display_name,username,phone)
      values(bot_id,null,'Bot '||role_to_fill||' '||ordinal,'bot_'||substr(replace(bot_id::text,'-',''),1,16),null);
      insert into fieldrush_private.staging_bot_profiles(profile_id,game_id,booking_id,request_id,role,created_by)
      values(bot_id,g.id,booking_id_to_use,request_id_to_use,role_to_fill,actor_admin_id);
      insert into public.open_queue_bookings(id,game_id,profile_id,role,status,team,played,player_rating_at_booking,
        amount_paid_fils,base_amount_fils,discount_bps,reliability_deposit_fils,reliability_deposit_status,
        payment_method,payment_reference,payment_intent_id,provider_payment_id)
      values(booking_id_to_use,g.id,bot_id,role_to_fill,'CONFIRMED',null,false,1200,0,0,0,0,'NOT_REQUIRED',
        'MOCK','STAGING_BOT:'||booking_id_to_use::text,null,null);
      added:=added+1;
    end loop;
  end loop;
  perform set_config('fieldrush.staging_bot_fill_game',coalesce(original_context,''),true);
  select count(*) into total_confirmed from public.open_queue_bookings where game_id=g.id and status='CONFIRMED';
  if total_confirmed<>g.capacity then raise exception 'The bot roster could not fill the configured formation.'; end if;
  response:=jsonb_build_object('gameId',g.id,'requestId',request_id_to_use,'createdBots',added,
    'confirmedCount',total_confirmed,'capacity',g.capacity,'alreadyFilled',added=0);
  insert into fieldrush_private.staging_bot_fill_requests(request_id,game_id,actor_admin_id,response)
    values(request_id_to_use,g.id,actor_admin_id,response);
  insert into public.admin_audit_events(actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state)
    values(actor_admin_id,'STAGING_SOLO_BOTS_ADDED','SOLO_MATCH',g.id,'Fill remaining staging test places with isolated, authless bots.',
      jsonb_build_object('confirmedCount',total_confirmed-added),response);
  return response;
end;
$$;
revoke all on function public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_fill_open_queue_game_with_bots(uuid,uuid,uuid) to service_role;
notify pgrst,'reload schema';
