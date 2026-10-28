-- Keep the immutable goal/correction audit, but derive replay credit from the
-- official scorer rows. Unlinked legacy goals retain their existing behavior.
create function fieldrush_private.is_credited_replay_goal(source text,match_id uuid,event_id uuid)
returns boolean language sql stable security definer
set search_path=public,pg_temp as $$
  select case source
    when 'SOLO' then exists(
      select 1 from public.open_queue_events e where e.id=event_id and e.game_id=match_id
        and e.event_type='GOAL' and lower(trim(coalesce(e.note,'')))<>'admin correction'
        and (e.goal_id is null or exists(select 1 from public.open_queue_goals g
          where g.id=e.goal_id and g.game_id=e.game_id))
        and not exists(select 1 from public.open_queue_events c where c.game_id=e.game_id
          and c.event_type='CORRECTION' and c.goal_id=e.goal_id))
    when 'CLAN' then exists(
      select 1 from public.fixture_events e where e.id=event_id and e.fixture_id=match_id
        and e.event_type='GOAL' and lower(trim(coalesce(e.note,'')))<>'admin correction'
        and (e.goal_id is null or exists(select 1 from public.fixture_scorers g
          where g.id=e.goal_id and g.fixture_id=e.fixture_id))
        and not exists(select 1 from public.fixture_events c where c.fixture_id=e.fixture_id
          and c.event_type='CORRECTION' and c.goal_id=e.goal_id))
    else false end;
$$;
revoke all on function fieldrush_private.is_credited_replay_goal(text,uuid,uuid)
  from public,anon,authenticated,service_role;

-- The edge function uses this same authoritative predicate for downloads and
-- already-created goal clips. It does not accept client-supplied validity.
create function public.get_credited_replay_goals(source_type_to_use text,match_id_to_use uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'occurred_at',e.occurred_at)
    order by e.occurred_at,e.id),'[]'::jsonb)
  from (
    select id,occurred_at from public.open_queue_events where source_type_to_use='SOLO' and game_id=match_id_to_use
    union all
    select id,occurred_at from public.fixture_events where source_type_to_use='CLAN' and fixture_id=match_id_to_use
  ) e where fieldrush_private.is_credited_replay_goal(source_type_to_use,match_id_to_use,e.id);
$$;
revoke all on function public.get_credited_replay_goals(text,uuid) from public,anon,authenticated;
grant execute on function public.get_credited_replay_goals(text,uuid) to service_role;

-- Preserve the existing authorized, privacy-masked boundary and every policy
-- field. Older apps also stop treating DISALLOWED_GOAL as a credited highlight.
alter function public.get_open_queue_match_detail(uuid) rename to get_open_queue_match_detail_before_goal_credit;
revoke all on function public.get_open_queue_match_detail_before_goal_credit(uuid)
  from public,anon,authenticated,service_role;
create function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb; events jsonb;
begin
  result:=public.get_open_queue_match_detail_before_goal_credit(game_id_to_use);
  select coalesce(jsonb_agg(item.value||jsonb_build_object(
    'goal_id',e.goal_id,
    'is_goal_valid',case when e.event_type='GOAL' then
      fieldrush_private.is_credited_replay_goal('SOLO',game_id_to_use,e.id) else null end,
    'original_event_type',e.event_type,
    'event_type',case when e.event_type='GOAL'
      and not fieldrush_private.is_credited_replay_goal('SOLO',game_id_to_use,e.id)
      then 'DISALLOWED_GOAL' else e.event_type end
  ) order by item.ordinal),'[]'::jsonb) into events
  from jsonb_array_elements(coalesce(result->'events','[]'::jsonb)) with ordinality item(value,ordinal)
  join public.open_queue_events e on e.id=(item.value->>'id')::uuid and e.game_id=game_id_to_use;
  return jsonb_set(result,'{events}',events);
end;
$$;
revoke all on function public.get_open_queue_match_detail(uuid) from public,anon;
grant execute on function public.get_open_queue_match_detail(uuid) to authenticated,service_role;

-- Validate before the existing idempotent clip lookup, so retrying a formerly
-- valid saved goal cannot bypass a later referee correction.
do $migration$
declare definition text; old text;
begin
  definition:=pg_get_functiondef('public.request_profile_goal_clip(text,uuid,uuid,text)'::regprocedure);
  old:='and coalesce(lower(trim(event.note)), '''') <> ''admin correction''';
  if (length(definition)-length(replace(definition,old,'')))/length(old)<>4 then
    raise exception 'Goal clip validation contract changed.';
  end if;
  definition:=replace(definition,old,
    'and fieldrush_private.is_credited_replay_goal(normalized_source_type,source_match_id_to_use,event.id)');
  execute definition;
end;
$migration$;

-- A goal saved after an earlier finish can subsequently be removed after a
-- reopen. Retain its clip record for the owner, but revoke earned/public media.
create function fieldrush_private.invalidate_removed_goal_clips()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.profile_highlights h set processing_status='FAILED',
    processing_error='This goal was removed from the official score.',
    is_public=false,video_url=null,download_status='UNAVAILABLE',download_url=null
  where h.source_type=case when tg_table_name='open_queue_goals' then 'SOLO' else 'CLAN' end
    and h.source_event_id in (
      select id from public.open_queue_events where tg_table_name='open_queue_goals' and goal_id=old.id
      union all select id from public.fixture_events where tg_table_name='fixture_scorers' and goal_id=old.id
    );
  return old;
end;
$$;
revoke all on function fieldrush_private.invalidate_removed_goal_clips() from public,anon,authenticated,service_role;
create trigger invalidate_removed_solo_goal_clips after delete on public.open_queue_goals
  for each row execute function fieldrush_private.invalidate_removed_goal_clips();
create trigger invalidate_removed_clan_goal_clips after delete on public.fixture_scorers
  for each row execute function fieldrush_private.invalidate_removed_goal_clips();
update public.profile_highlights h set processing_status='FAILED',
  processing_error='This goal was removed from the official score.',
  is_public=false,video_url=null,download_status='UNAVAILABLE',download_url=null
where h.source_event_id is not null and h.source_type in ('SOLO','CLAN')
  and not fieldrush_private.is_credited_replay_goal(h.source_type,h.source_match_id,h.source_event_id);

-- A provider response or visibility retry arriving after removal must not
-- restore media that the removal transaction just revoked. Validate at the
-- database write boundary, including service-role writes from the edge worker.
create function fieldrush_private.guard_profile_goal_clip_credit()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.source_event_id is not null and new.source_type in ('SOLO','CLAN')
    and (new.is_public or new.processing_status='READY' or new.video_url is not null or new.download_url is not null)
    and not fieldrush_private.is_credited_replay_goal(new.source_type,new.source_match_id,new.source_event_id) then
    raise exception 'This goal was removed from the official score.' using errcode='23514';
  end if;
  return new;
end;
$$;
revoke all on function fieldrush_private.guard_profile_goal_clip_credit() from public,anon,authenticated,service_role;
create trigger guard_profile_goal_clip_credit before insert or update on public.profile_highlights
  for each row execute function fieldrush_private.guard_profile_goal_clip_credit();
notify pgrst,'reload schema';
