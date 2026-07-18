-- Match elapsed time includes the running wall clock. Mark the helper with the
-- correct volatility so PostgreSQL never treats its value as stable while a
-- match clock is actively running.
alter function public.reliability_match_elapsed_seconds(text, uuid) volatile;

comment on function public.reliability_match_elapsed_seconds(text, uuid) is
'Returns the authoritative elapsed match seconds, including live wall-clock time when the persisted match clock is running.';
