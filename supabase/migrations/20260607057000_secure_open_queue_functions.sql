revoke execute on function public.ensure_profile_player_rating() from public;
revoke execute on function public.snapshot_fixture_player_appearances(uuid) from public;
revoke execute on function public.snapshot_fixture_players_when_live() from public;
revoke execute on function public.apply_clan_fixture_player_ratings() from public;
revoke execute on function public.enforce_open_queue_booking_capacity() from public;
revoke execute on function public.sync_open_queue_game_status() from public;
revoke execute on function public.assign_open_queue_teams(uuid) from public;

revoke execute on function public.book_open_queue_game(uuid, text, text, text)
from public;
revoke execute on function public.preview_open_queue_cancellation(uuid)
from public;
revoke execute on function public.cancel_open_queue_booking(uuid)
from public;
revoke execute on function public.list_open_queue_games() from public;
revoke execute on function public.list_player_rating_leaderboard(text)
from public;
revoke execute on function public.get_my_player_rating() from public;

grant execute on function public.book_open_queue_game(uuid, text, text, text)
to authenticated;
grant execute on function public.preview_open_queue_cancellation(uuid)
to authenticated;
grant execute on function public.cancel_open_queue_booking(uuid)
to authenticated;
grant execute on function public.list_open_queue_games() to authenticated;
grant execute on function public.list_player_rating_leaderboard(text)
to authenticated;
grant execute on function public.get_my_player_rating() to authenticated;
