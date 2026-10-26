-- Unrevealed players may join any advertised division. Once a booked rating
-- track reaches two lifetime appearances, its normal division range applies.
-- Preserve the staging-bot wrapper and the existing lifetime track source.
create or replace function public.assert_open_queue_division_eligibility_before_staging_bots(
  player_id_to_check uuid,game_id_to_check uuid,role_to_use text
)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare game public.open_queue_games%rowtype; rating integer; counted integer; division integer;
  track text:=public.fieldrush_rating_track(role_to_use);
begin
  select * into game from public.open_queue_games where id=game_id_to_check for share;
  if game.id is null then raise exception 'Game not found.'; end if;
  if game.status not in ('OPEN','FULL','LIVE') then return; end if;
  select skill_rating,matches_played into rating,counted from public.fieldrush_player_rating_tracks
    where profile_id=player_id_to_check and rating_track=track;
  if coalesce(counted,0)<2 then return; end if;
  division:=public.fieldrush_division_for_rating(rating);
  if division<game.highest_division or division>game.lowest_division then
    raise exception 'This game is for DIV %–%. Your % division is %.',game.highest_division,game.lowest_division,lower(track),division;
  end if;
end;
$$;
revoke all on function public.assert_open_queue_division_eligibility_before_staging_bots(uuid,uuid,text)
from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
