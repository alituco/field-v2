-- A lobby's aggregate includes placement players, even while their individual
-- SR remains private. Keep this explicit aggregate separate from team strength,
-- player snapshots and rating-result fields masked by the existing boundary.
create function fieldrush_rating_private.lobby_rating_average(game_to_use uuid)
returns numeric language sql stable security definer
set search_path=pg_catalog,public,fieldrush_rating_private,pg_temp as $$
  select case
    when g.operational_state in ('NO_DATA','UNDER_REVIEW')
      or state.settlement_status in ('HELD','NOT_RATED') then null
    -- Never silently average a partial set if a confirmed player lacks data.
    when count(b.id)=0 or count(values_to_use.sr)<>count(b.id) then null
    else round(avg(values_to_use.sr),2)
  end
  from public.open_queue_games g
  left join fieldrush_rating_private.season_zero_matches state on state.game_id=g.id
  left join fieldrush_rating_private.season_zero_active_settlements active on active.game_id=g.id
  left join fieldrush_rating_private.season_zero_settlement_revisions settled
    on settled.id=active.settlement_id and settled.status='RATED'
  left join public.open_queue_bookings b on b.game_id=g.id and b.status='CONFIRMED'
  left join public.fieldrush_player_rating_tracks track
    on track.profile_id=b.profile_id and track.rating_track=b.rating_track
  left join lateral (
    select (p.value->>'sr_before')::numeric as sr
    from jsonb_array_elements(settled.input_snapshot->'roster') p(value)
    where p.value->>'id'=b.profile_id::text and p.value->>'rating_track'=b.rating_track
    limit 1
  ) effective on true
  cross join lateral (
    select coalesce(effective.sr,b.rating_at_match_start,b.rating_at_team_assignment,track.skill_rating)::numeric as sr
  ) values_to_use
  where g.id=game_to_use
  group by g.id,g.operational_state,state.settlement_status;
$$;
revoke all on function fieldrush_rating_private.lobby_rating_average(uuid)
  from public,anon,authenticated,service_role;

-- Preserve the original authorization, response and every individual/team
-- privacy guard. Only the approved whole-lobby aggregate is added afterwards.
create or replace function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language sql stable security definer
set search_path=public,pg_temp as $$
  select fieldrush_rating_private.mask_public_rating_payload(
    public.get_open_queue_match_detail_before_sr_privacy($1),
    null::uuid,'OUTFIELD',null::integer,$1
  )||jsonb_build_object('lobby_average_sr',fieldrush_rating_private.lobby_rating_average($1));
$$;

comment on function public.get_open_queue_match_detail(uuid) is
  'Returns authorized match detail with masked individual SR and a server-computed whole confirmed lobby average, including placement players.';
notify pgrst,'reload schema';
