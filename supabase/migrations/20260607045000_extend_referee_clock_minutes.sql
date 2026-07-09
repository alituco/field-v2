alter table public.fixture_clock_states
drop constraint if exists fixture_clock_states_accumulated_seconds_check;

alter table public.fixture_clock_states
add constraint fixture_clock_states_accumulated_seconds_check
check (accumulated_seconds between 0 and 14400);

alter table public.fixture_clock_states
drop constraint if exists fixture_clock_states_duration_seconds_check;

alter table public.fixture_clock_states
add constraint fixture_clock_states_duration_seconds_check
check (duration_seconds between 600 and 14400);

alter table public.fixture_events
drop constraint if exists fixture_events_minute_check;

alter table public.fixture_events
add constraint fixture_events_minute_check
check (minute between 0 and 240);

alter table public.fixture_blue_cards
drop constraint if exists fixture_blue_cards_minute_check;

alter table public.fixture_blue_cards
add constraint fixture_blue_cards_minute_check
check (minute between 0 and 240);

alter table public.fixture_scorers
drop constraint if exists fixture_scorers_minute_check;

alter table public.fixture_scorers
add constraint fixture_scorers_minute_check
check (minute between 1 and 240);
