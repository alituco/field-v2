-- A no-data Season 0 game with no kickoff cannot enter rating adjudication.
-- Reuse the existing audited cancellation/refund transaction, but never let
-- that legacy result writer adjudicate a played Season 0 game or assign SR.
-- Patch in place so no callable historical alias bypasses this guard. Preview
-- already invokes this exact writer in a rolled-back subtransaction.
do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'::regprocedure);
  anchor:=$old$  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Admin access required.';
  end if;$old$;
  if position(anchor in definition)=0 then
    raise exception 'Match-resolution administrator authorization contract changed.';
  end if;
  definition:=replace(definition,anchor,anchor||$guard$
  if normalized_kind='SOLO' and exists(select 1 from public.open_queue_games
    where id=match_id_to_use and rating_policy_id='field-sr-season0-v2') then
    -- Match kickoff/adjudication takes this same lock before the game row.
    -- Recheck canonical evidence under the lock, rather than trusting the UI
    -- or a read made before the administrator opened the confirmation dialog.
    perform fieldrush_rating_private.lock_season_zero_sr();
    select * into game_to_resolve from public.open_queue_games
      where id=match_id_to_use and rating_policy_id='field-sr-season0-v2' for update;
    if game_to_resolve.id is null then
      raise exception 'Refresh the changed match before reviewing it.' using errcode='40001';
    end if;
    if game_to_resolve.status not in ('OPEN','FULL')
      or game_to_resolve.white_score is not null or game_to_resolve.black_score is not null
      or exists(select 1 from fieldrush_rating_private.season_zero_matches where game_id=match_id_to_use)
      or exists(select 1 from public.open_queue_clock_states where game_id=match_id_to_use
        and (status<>'NOT_STARTED' or started_at is not null or accumulated_seconds<>0))
      or exists(select 1 from public.open_queue_events where game_id=match_id_to_use
        and event_type<>'INJURY_RECORDED')
      or exists(select 1 from public.open_queue_goals where game_id=match_id_to_use)
      or exists(select 1 from public.open_queue_bookings where game_id=match_id_to_use
        and (played or rating_at_match_start is not null))
      or exists(select 1 from public.player_rating_events where source_type='OPEN_QUEUE' and source_id=match_id_to_use) then
      raise exception 'Use Season 0 rating review for a game with kickoff or playing evidence.' using errcode='22023';
    end if;
    if game_to_resolve.operational_state not in ('NO_DATA','UNDER_REVIEW') then
      raise exception 'Refresh the pending game review before resolving it.' using errcode='40001';
    end if;
    if normalized_resolution not in ('FIELD_OR_VENUE_CANCELLATION','ADMINISTRATIVE_VOID') then
      raise exception 'A Season 0 game without kickoff evidence can only be cancelled with a full refund.' using errcode='22023';
    end if;
    if safe_payload is distinct from '{}'::jsonb then
      raise exception 'Before-kickoff cancellation does not accept score, attendance, penalty, or refund overrides.' using errcode='22023';
    end if;
    -- The existing writer below still verifies the review case and expected
    -- revision, then records the refund entitlement, case revision and audit
    -- in one transaction. No kickoff, result, participation or SR is invented.
  end if;
$guard$);
  execute definition;
end;
$migration$;

-- The reviewed cancellation sets the game CANCELLED before iterating its
-- booked payers. Invalidating that terminal assignment would rewrite the
-- remaining booking rows underneath the refund cursor and skip some payers.
-- Retain the cancelled game's last assignment and its immutable audit instead.
do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('fieldrush_rating_private.invalidate_season_zero_assignment(uuid)'::regprocedure);
  anchor:='if g.rating_policy_id is distinct from ''field-sr-season0-v2'' or g.teams_assigned_at is null';
  if position(anchor in definition)=0 then raise exception 'Season 0 assignment invalidation contract changed.'; end if;
  definition:=replace(definition,anchor,anchor||' or g.status=''CANCELLED''');
  anchor:='if g.teams_assigned_at is null or exists(select 1 from fieldrush_rating_private.season_zero_matches';
  if position(anchor in definition)=0 then raise exception 'Locked Season 0 assignment invalidation contract changed.'; end if;
  definition:=replace(definition,anchor,'if g.status=''CANCELLED'' or g.teams_assigned_at is null or exists(select 1 from fieldrush_rating_private.season_zero_matches');
  execute definition;
end;
$migration$;

revoke all on function public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb) to service_role;

notify pgrst, 'reload schema';
