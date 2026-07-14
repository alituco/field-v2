alter table public.fixtures
validate constraint fixtures_day_check;

alter table public.fixtures
validate constraint fixtures_time_slot_check;

alter table public.fixtures
validate constraint fixtures_day_matches_date_check;

alter table public.open_queue_games
validate constraint open_queue_games_permanent_timezone_check;

alter table public.open_queue_games
validate constraint open_queue_games_permanent_schedule_check;
