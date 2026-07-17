alter table public.season_zero_waitlist
drop constraint season_zero_waitlist_age_check;

alter table public.season_zero_waitlist
add constraint season_zero_waitlist_age_check
check (
  age is null
  or age between 12 and 100
);
