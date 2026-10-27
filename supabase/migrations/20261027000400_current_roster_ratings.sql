-- The Players roster needs current public SR before assignment/start snapshots
-- exist. Keep this separate from frozen match inputs/results and their masks.
alter function public.get_open_queue_match_detail(uuid)
  rename to get_open_queue_match_detail_before_roster_sr;
revoke all on function public.get_open_queue_match_detail_before_roster_sr(uuid)
  from public,anon,authenticated,service_role;

create function public.get_open_queue_match_detail(game_id_to_use uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare result jsonb; players jsonb;
begin
  -- Preserve the existing authorization, privacy, policy, arrival and goal
  -- credit boundaries. Completed/cancelled payloads remain exactly unchanged.
  result:=public.get_open_queue_match_detail_before_roster_sr(game_id_to_use);
  if result is null or jsonb_typeof(result)<>'object'
    or coalesce(result->>'status','') not in ('OPEN','FULL','LIVE') then
    return result;
  end if;

  select coalesce(jsonb_agg(item.value||jsonb_build_object(
    'roster_skill_rating',case when coalesce(
      (fieldrush_rating_private.public_rating_state(track.profile_id,track.rating_track)->>'rating_visible')::boolean,false)
      then track.skill_rating else null end
  ) order by item.ordinal),'[]'::jsonb) into players
  from jsonb_array_elements(case when jsonb_typeof(result->'players')='array'
    then result->'players' else '[]'::jsonb end) with ordinality item(value,ordinal)
  left join public.open_queue_bookings booking
    on booking.game_id=game_id_to_use and booking.profile_id::text=item.value->>'id'
      and booking.role=item.value->>'role' and booking.status='CONFIRMED'
  left join public.fieldrush_player_rating_tracks track
    on track.profile_id=booking.profile_id and track.rating_track=booking.rating_track;

  return jsonb_set(result,'{players}',players);
end;
$$;

comment on function public.get_open_queue_match_detail(uuid) is
  'Authorized match detail with current public, booking-track SR on active rosters; frozen match ratings/results and placement privacy remain unchanged.';
revoke all on function public.get_open_queue_match_detail(uuid) from public,anon;
grant execute on function public.get_open_queue_match_detail(uuid) to authenticated,service_role;
notify pgrst,'reload schema';
