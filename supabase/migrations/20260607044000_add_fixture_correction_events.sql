alter table public.fixture_events
drop constraint if exists fixture_events_event_type_check;

alter table public.fixture_events
add constraint fixture_events_event_type_check
check (
  event_type in (
    'MATCH_STARTED',
    'MATCH_PAUSED',
    'MATCH_RESUMED',
    'MATCH_ENDED',
    'GOAL',
    'BLUE_CARD',
    'BLUE_CARD_EXPIRED',
    'CORRECTION'
  )
);
