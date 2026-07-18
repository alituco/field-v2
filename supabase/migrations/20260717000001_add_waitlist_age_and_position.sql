alter table public.season_zero_waitlist
add column age smallint,
add column preferred_position text;

alter table public.season_zero_waitlist
add constraint season_zero_waitlist_age_check
check (
  age is null
  or age between 16 and 100
),
add constraint season_zero_waitlist_preferred_position_check
check (
  preferred_position is null
  or preferred_position in (
    'GOALKEEPER',
    'DEFENDER',
    'MIDFIELDER',
    'ATTACKER'
  )
);

comment on column public.season_zero_waitlist.age is
  'Age supplied when joining the waitlist. Null only for legacy entries.';

comment on column public.season_zero_waitlist.preferred_position is
  'Optional primary football position supplied by the applicant.';
