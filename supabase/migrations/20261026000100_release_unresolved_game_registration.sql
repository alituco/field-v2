-- Registration eligibility is separate from unresolved score/rating history.
-- Pin actual kickoff as public operational metadata; a resumed clock is not a
-- new kickoff. No game is finalized, rated, cancelled or refunded here.
alter table public.open_queue_games add column actual_started_at timestamptz;
grant select(actual_started_at) on public.open_queue_games to authenticated;

update public.open_queue_games g set actual_started_at=s.started_at
from fieldrush_rating_private.season_zero_matches s where s.game_id=g.id;
update public.open_queue_games g set actual_started_at=e.started_at
from (select game_id,min(occurred_at) started_at from public.open_queue_events
  where event_type='MATCH_STARTED' group by game_id) e
where e.game_id=g.id and g.actual_started_at is null
  and g.rating_policy_id is distinct from 'field-sr-season0-v2';

create function fieldrush_rating_private.pin_open_queue_actual_kickoff()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare observed timestamptz;
begin
  if tg_op='UPDATE' and old.actual_started_at is not null then
    if new.actual_started_at is distinct from old.actual_started_at then
      raise exception 'Actual kickoff is immutable match evidence.' using errcode='42501';
    end if;
    return new;
  end if;
  select s.started_at into observed from fieldrush_rating_private.season_zero_matches s where s.game_id=new.id;
  if observed is null and new.rating_policy_id is distinct from 'field-sr-season0-v2' then
    select min(e.occurred_at) into observed from public.open_queue_events e
    where e.game_id=new.id and e.event_type='MATCH_STARTED';
  end if;
  if new.actual_started_at is not null and new.actual_started_at is distinct from observed then
    raise exception 'Actual kickoff must come from recorded match evidence.' using errcode='42501';
  end if;
  new.actual_started_at:=observed;
  return new;
end;
$$;
create trigger a_pin_open_queue_actual_kickoff before insert or update of actual_started_at,status
on public.open_queue_games for each row execute function fieldrush_rating_private.pin_open_queue_actual_kickoff();

create function fieldrush_rating_private.publish_open_queue_actual_kickoff()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
declare game uuid;
begin
  if tg_table_schema='fieldrush_rating_private' then game:=new.game_id;
  elsif new.event_type='MATCH_STARTED' then game:=new.game_id;
  else return new;
  end if;
  -- The pin trigger derives the timestamp from authoritative evidence above.
  update public.open_queue_games set actual_started_at=null where id=game and actual_started_at is null;
  return new;
end;
$$;
create trigger publish_open_queue_actual_kickoff after insert on fieldrush_rating_private.season_zero_matches
for each row execute function fieldrush_rating_private.publish_open_queue_actual_kickoff();
create trigger publish_open_queue_actual_kickoff after insert on public.open_queue_events
for each row execute function fieldrush_rating_private.publish_open_queue_actual_kickoff();

create function public.player_game_registration_end_at(game_to_check public.open_queue_games)
returns timestamptz language sql immutable strict parallel safe set search_path=pg_catalog as $$
  select case when (game_to_check).status='LIVE' and (game_to_check).actual_started_at is not null
    then (game_to_check).actual_started_at+((game_to_check).ends_at-(game_to_check).starts_at)
    else (game_to_check).ends_at end;
$$;

create or replace function public.player_game_blocks_registration(
  status_to_check text,scheduled_end_to_check timestamptz,operational_state_to_check text,
  at_time timestamptz default statement_timestamp()
)
returns boolean language sql immutable set search_path=public,pg_temp as $$
  select coalesce(operational_state_to_check not in ('NO_DATA','UNDER_REVIEW')
    and status_to_check in ('OPEN','FULL','SCHEDULED','LIVE')
    and scheduled_end_to_check>at_time,false);
$$;

-- Keep the existing guards, payment checks, attendee exemptions and locking.
-- Supply the actual-kickoff deadline everywhere a solo game is inspected.
do $migration$
declare signature text; d text; alias text; anchor text;
begin
  foreach signature in array array[
    'public.assert_player_has_one_game(uuid,text,uuid,boolean)',
    'public.preview_open_queue_booking_cost(uuid,text)',
    'public.book_open_queue_game_server(uuid,text,text,text)',
    'public.enforce_one_player_registered_game()',
    'public.enforce_reactivated_player_game_limit()',
    'fieldrush_private.replacement_recipient_eligible(uuid,uuid,uuid)'
  ] loop
    d:=pg_get_functiondef(signature::regprocedure);
    foreach alias in array array['g','other_game','other'] loop
      d:=regexp_replace(d,
        'public\.player_game_blocks_registration\('||alias||'\.status,\s*'||alias||'\.ends_at,\s*'||alias||'\.operational_state\)',
        'public.player_game_blocks_registration('||alias||'.status,public.player_game_registration_end_at('||alias||'),'||alias||'.operational_state)','g');
      d:=replace(d,'coalesce('||alias||'.ends_at,public.fixture_end_at(',
        'coalesce(public.player_game_registration_end_at('||alias||'),public.fixture_end_at(');
    end loop;
    if signature='public.enforce_one_player_registered_game()' then
      anchor:='select status,ends_at,operational_state into game_status,game_end,operational from public.open_queue_games';
      if position(anchor in d)=0 then raise exception 'Registered game eligibility selector changed.'; end if;
      d:=replace(d,anchor,'select status,public.player_game_registration_end_at(open_queue_games),operational_state into game_status,game_end,operational from public.open_queue_games');
    elsif signature='public.enforce_reactivated_player_game_limit()' then
      anchor:='old_end:=old.ends_at; new_end:=new.ends_at;';
      if position(anchor in d)=0 then raise exception 'Reactivated game eligibility deadline changed.'; end if;
      d:=replace(d,anchor,'old_end:=public.player_game_registration_end_at(old); new_end:=public.player_game_registration_end_at(new);');
    end if;
    execute d;
  end loop;
end;
$migration$;

revoke all on function fieldrush_rating_private.pin_open_queue_actual_kickoff(),
  fieldrush_rating_private.publish_open_queue_actual_kickoff(),
  public.player_game_registration_end_at(public.open_queue_games)
from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
