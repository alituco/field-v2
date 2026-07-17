-- Close three release-critical reliability gaps:
--   1. An early verified-injury refund is a full base-fee + deposit refund,
--      even when the deposit was already returned at check-in.
--   2. An active clan participation/indefinite suspension blocks an existing
--      scheduled fixture from starting; booking-only restrictions do not.
--   3. A successful post-final late-attendance appeal appends an auditable SR
--      correction and revokes downstream reliability sanctions whose threshold
--      crossing is no longer valid after the appealed incident is removed.

create or replace function public.settle_verified_early_injury_refunds(
  game_id_to_settle uuid,
  injury_id_to_settle uuid,
  terms_id_to_settle uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  game_to_settle public.open_queue_games%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  injury_to_use public.match_verified_injuries%rowtype;
  refund_booking record;
  injury_refund_bps integer;
  target_fee_refund_fils integer;
  target_deposit_refund_fils integer;
  target_total_refund_fils integer;
  current_total_refund_fils integer;
  current_deposit_refund_fils integer;
  current_fee_refund_fils integer;
  missing_fee_refund_fils integer;
  missing_deposit_refund_fils integer;
  corrected_count integer := 0;
  nominal_seconds integer;
  threshold_bps integer;
begin
  select * into game_to_settle
  from public.open_queue_games game
  where game.id = game_id_to_settle
  for update;
  if game_to_settle.id is null or game_to_settle.status <> 'FINAL' then
    raise exception 'Verified injury refunds require a final Open Queue game.';
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = terms_id_to_settle
    and terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = game_id_to_settle;
  if terms_to_use.id is null then
    raise exception 'The snapshotted match reliability terms are unavailable.';
  end if;

  select * into injury_to_use
  from public.match_verified_injuries injury
  where injury.id = injury_id_to_settle
    and injury.terms_id = terms_to_use.id
    and injury.unable_to_continue
    and not injury.replacement_available;
  if injury_to_use.id is null then
    raise exception 'A qualifying verified injury is required.';
  end if;

  nominal_seconds := greatest(
    1,
    floor(extract(epoch from (
      game_to_settle.ends_at - game_to_settle.starts_at
    )))::integer
  );
  threshold_bps := (terms_to_use.policy_snapshot #>>
    '{injury,halfMatchThresholdBps}')::integer;
  if injury_to_use.match_second::bigint * 10000
    >= nominal_seconds::bigint * threshold_bps
  then
    raise exception 'This verified injury occurred after the full-refund cutoff.';
  end if;

  injury_refund_bps := (terms_to_use.policy_snapshot #>>
    '{injury,incompleteRefundBps}')::integer;

  for refund_booking in
    select
      booking.*,
      attendance.id as attendance_id,
      attendance.deposit_resolution,
      attendance.refund_amount_fils as attendance_refund_amount_fils
    from public.open_queue_bookings booking
    left join public.match_attendance_records attendance
      on attendance.booking_id = booking.id
      and attendance.terms_id = terms_to_use.id
    where booking.game_id = game_id_to_settle
      and booking.status = 'CONFIRMED'
      and booking.played
    order by booking.profile_id
    for update of booking
  loop
    target_fee_refund_fils := (
      refund_booking.base_amount_fils::bigint * injury_refund_bps / 10000
    )::integer;
    target_deposit_refund_fils := refund_booking.reliability_deposit_fils;
    target_total_refund_fils := target_fee_refund_fils
      + target_deposit_refund_fils;

    current_total_refund_fils := greatest(
      0,
      coalesce(refund_booking.refund_amount_fils, 0),
      coalesce(refund_booking.attendance_refund_amount_fils, 0)
    );
    current_deposit_refund_fils := case
      when refund_booking.deposit_resolution = 'RETURNED'
        or refund_booking.reliability_deposit_status in ('RETURNED', 'REFUNDED')
      then target_deposit_refund_fils
      else 0
    end;
    current_fee_refund_fils := least(
      target_fee_refund_fils,
      greatest(0, current_total_refund_fils - current_deposit_refund_fils)
    );
    missing_fee_refund_fils := greatest(
      0,
      target_fee_refund_fils - current_fee_refund_fils
    );
    missing_deposit_refund_fils := case
      when target_deposit_refund_fils > 0
        and current_deposit_refund_fils = 0
      then target_deposit_refund_fils
      else 0
    end;

    if missing_fee_refund_fils > 0 then
      perform public.credit_field_wallet(
        refund_booking.profile_id,
        missing_fee_refund_fils,
        'FIELD_CANCELLATION_REFUND',
        'verified-injury-fee-refund:' || game_id_to_settle::text || ':' ||
          refund_booking.profile_id::text,
        'Full match-fee refund after a verified early-match injury.',
        terms_to_use.policy_version_id,
        refund_booking.id,
        null,
        jsonb_build_object(
          'injury_id', injury_to_use.id,
          'component', 'BASE_FEE',
          'refund_bps', injury_refund_bps,
          'target_fee_refund_fils', target_fee_refund_fils
        )
      );
    end if;

    if missing_deposit_refund_fils > 0 then
      perform public.credit_field_wallet(
        refund_booking.profile_id,
        missing_deposit_refund_fils,
        'RELIABILITY_DEPOSIT_RETURN',
        'verified-injury-deposit-refund:' || game_id_to_settle::text || ':' ||
          refund_booking.profile_id::text,
        'Reliability deposit returned after a verified early-match injury.',
        terms_to_use.policy_version_id,
        refund_booking.id,
        null,
        jsonb_build_object(
          'injury_id', injury_to_use.id,
          'component', 'RELIABILITY_DEPOSIT',
          'deposit_fils', target_deposit_refund_fils
        )
      );
    end if;

    update public.open_queue_bookings booking
    set
      refund_bps = greatest(coalesce(booking.refund_bps, 0), injury_refund_bps),
      refund_percent = round(greatest(
        coalesce(booking.refund_bps, 0),
        injury_refund_bps
      ) / 100.0)::integer,
      refund_amount_fils = greatest(
        coalesce(booking.refund_amount_fils, 0),
        target_total_refund_fils
      ),
      refund_status = case when target_total_refund_fils > 0
        then 'PROCESSED' else booking.refund_status end,
      payment_status = case
        when booking.amount_paid_fils > 0
          and target_total_refund_fils >= booking.amount_paid_fils
          then 'REFUNDED'
        when target_total_refund_fils > 0 then 'PARTIALLY_REFUNDED'
        else booking.payment_status
      end,
      reliability_deposit_status = case
        when booking.reliability_deposit_fils > 0 then 'RETURNED'
        else booking.reliability_deposit_status
      end
    where booking.id = refund_booking.id;

    if refund_booking.attendance_id is not null then
      update public.match_attendance_records attendance
      set
        refund_bps = greatest(attendance.refund_bps, injury_refund_bps),
        refund_amount_fils = greatest(
          attendance.refund_amount_fils,
          target_total_refund_fils
        ),
        deposit_resolution = case
          when attendance.reliability_deposit_fils > 0 then 'RETURNED'
          else attendance.deposit_resolution
        end,
        consequence_snapshot = attendance.consequence_snapshot ||
          jsonb_build_object(
            'verified_injury_refund_bps', injury_refund_bps,
            'verified_injury_fee_refund_fils', target_fee_refund_fils,
            'verified_injury_deposit_refund_fils',
              target_deposit_refund_fils,
            'verified_injury_total_refund_fils', target_total_refund_fils,
            'verified_injury_id', injury_to_use.id
          )
      where attendance.id = refund_booking.attendance_id;

      if missing_deposit_refund_fils > 0 then
        insert into public.attendance_events (
          attendance_id, event_type, event_at, detail, idempotency_key
        ) values (
          refund_booking.attendance_id,
          'DEPOSIT_RETURNED',
          clock_timestamp(),
          jsonb_build_object(
            'source', 'VERIFIED_EARLY_INJURY',
            'injury_id', injury_to_use.id,
            'amount_fils', target_deposit_refund_fils
          ),
          'verified-injury-deposit-returned:' ||
            refund_booking.attendance_id::text
        ) on conflict (idempotency_key) do nothing;
      end if;
    end if;

    corrected_count := corrected_count + 1;
  end loop;

  return corrected_count;
end;
$$;

-- Run the component-aware settlement before the legacy aggregate calculation
-- so its subtraction cannot mistake an already-returned deposit for a fee
-- refund. Run it again afterward to restore the correct total/payment status
-- that the compatibility block would otherwise label as partial.
do $migration$
declare
  function_definition text;
  old_before text := $old$  if injury_applies and injury_before_threshold then
    injury_refund_bps := (terms_to_use.policy_snapshot #>>$old$;
  new_before text := $new$  if injury_applies and injury_before_threshold then
    perform public.settle_verified_early_injury_refunds(
      game_id_to_apply,
      injury_to_use.id,
      terms_to_use.id
    );
    injury_refund_bps := (terms_to_use.policy_snapshot #>>$new$;
  old_after text := $old$  end if;

  if injury_applies and not exists ($old$;
  new_after text := $new$  end if;

  if injury_applies and injury_before_threshold then
    perform public.settle_verified_early_injury_refunds(
      game_id_to_apply,
      injury_to_use.id,
      terms_to_use.id
    );
  end if;

  if injury_applies and not exists ($new$;
begin
  select pg_get_functiondef(
    'public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure
  ) into function_definition;
  if position('settle_verified_early_injury_refunds' in function_definition) = 0 then
    if position(old_before in function_definition) = 0
      or position(old_after in function_definition) = 0
    then
      raise exception 'Could not attach component-aware early injury refunds.';
    end if;
    function_definition := replace(function_definition, old_before, new_before);
    function_definition := replace(function_definition, old_after, new_after);
    execute function_definition;
  end if;
end;
$migration$;

-- An approved appeal can be decided before FINAL. In that case the later SR
-- pass must accept EXCUSED as a neutral attendance outcome and give the player
-- the same team-level protection as an on-time participant.
alter table public.player_rating_events
drop constraint if exists player_rating_events_attendance_outcome_check;
alter table public.player_rating_events
add constraint player_rating_events_attendance_outcome_check check (
  attendance_outcome is null
  or attendance_outcome in ('ON_TIME', 'LATE', 'EXCUSED')
);

do $migration$
declare
  target_function regprocedure;
  function_definition text;
  old_text text := $old$event_to_adjust.attendance_outcome = 'ON_TIME'$old$;
  new_text text := $new$event_to_adjust.attendance_outcome in (
          'ON_TIME', 'EXCUSED'
        )$new$;
begin
  foreach target_function in array array[
    'public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure,
    'public.apply_clan_reliability_rating_adjustments(uuid)'::regprocedure
  ]
  loop
    select pg_get_functiondef(target_function) into function_definition;
    if position(new_text in function_definition) = 0
    then
      if position(old_text in function_definition) = 0 then
        raise exception 'Could not make % appeal-aware.', target_function;
      end if;
      function_definition := replace(function_definition, old_text, new_text);
      execute function_definition;
    end if;
  end loop;
end;
$migration$;

create or replace function public.clan_has_active_participation_suspension(
  clan_id_to_check uuid,
  at_to_use timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.reliability_sanctions sanction
    where sanction.subject_type = 'CLAN'
      and sanction.clan_id = clan_id_to_check
      and sanction.sanction_kind in (
        'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
      )
      and sanction.revoked_at is null
      and sanction.starts_at <= at_to_use
      and (sanction.ends_at is null or sanction.ends_at > at_to_use)
  );
$$;

create index if not exists reliability_sanctions_clan_active_idx
on public.reliability_sanctions (
  clan_id, sanction_kind, starts_at, ends_at
)
where subject_type = 'CLAN' and revoked_at is null;

create or replace function public.enforce_clan_participation_suspension_at_start()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status <> 'LIVE' or old.status = 'LIVE' then
    return new;
  end if;

  if public.clan_has_active_participation_suspension(
    new.home_clan_id,
    clock_timestamp()
  ) then
    raise exception 'The home clan is suspended from participation and this fixture cannot start.';
  end if;
  if new.away_clan_id is not null
    and public.clan_has_active_participation_suspension(
      new.away_clan_id,
      clock_timestamp()
    )
  then
    raise exception 'The away clan is suspended from participation and this fixture cannot start.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_clan_participation_suspension_at_start
on public.fixtures;
create trigger enforce_clan_participation_suspension_at_start
before update of status on public.fixtures
for each row execute function public.enforce_clan_participation_suspension_at_start();

-- Serialize the normal referee start path with clan-incident/sanction creation
-- before it takes the fixture row lock. A suspension committed concurrently
-- therefore cancels the scheduled fixture before START can make it LIVE.
do $migration$
declare
  function_definition text;
  old_text text := $old$begin
  select * into fixture_to_start
  from public.fixtures
  where id = fixture_id_to_start
  for update;$old$;
  new_text text := $new$begin
  perform pg_advisory_xact_lock(
    hashtextextended(participant_clan.clan_id::text, 9175)
  )
  from (
    select distinct unnest(array[
      fixture.home_clan_id,
      fixture.away_clan_id
    ]) as clan_id
    from public.fixtures fixture
    where fixture.id = fixture_id_to_start
  ) participant_clan
  where participant_clan.clan_id is not null
  order by participant_clan.clan_id;

  select * into fixture_to_start
  from public.fixtures
  where id = fixture_id_to_start
  for update;$new$;
begin
  select pg_get_functiondef(
    'public.referee_start_fixture_atomic(uuid,uuid[],integer)'::regprocedure
  ) into function_definition;
  if position('participant_clan.clan_id' in function_definition) = 0 then
    if position(old_text in function_definition) = 0 then
      raise exception 'Could not serialize fixture start with clan sanctions.';
    end if;
    function_definition := replace(function_definition, old_text, new_text);
    execute function_definition;
  end if;
end;
$migration$;

create table public.clan_reliability_fixture_releases (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null unique
    references public.fixtures(id) on delete restrict,
  suspended_clan_id uuid not null references public.clans(id)
    on delete restrict,
  sanction_id uuid not null references public.reliability_sanctions(id)
    on delete restrict,
  incident_id uuid not null references public.reliability_incidents(id)
    on delete restrict,
  source_fixture_id uuid references public.fixtures(id) on delete restrict,
  released_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp()
);

alter table public.clan_reliability_fixture_releases enable row level security;
revoke all on table public.clan_reliability_fixture_releases
from public, anon, authenticated;
grant all on table public.clan_reliability_fixture_releases to service_role;

drop trigger if exists protect_clan_reliability_fixture_releases_append_only
on public.clan_reliability_fixture_releases;
create trigger protect_clan_reliability_fixture_releases_append_only
before update or delete on public.clan_reliability_fixture_releases
for each row execute function public.protect_append_only_reliability_rows();

create or replace function public.release_suspended_clan_future_fixtures(
  clan_id_to_release uuid,
  sanction_id_to_use uuid,
  release_at_to_use timestamptz default clock_timestamp()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  sanction_to_use public.reliability_sanctions%rowtype;
  source_fixture_id uuid;
  fixture_to_release public.fixtures%rowtype;
  released_count integer := 0;
begin
  perform pg_advisory_xact_lock(
    hashtextextended(clan_id_to_release::text, 9175)
  );
  select * into sanction_to_use
  from public.reliability_sanctions sanction
  where sanction.id = sanction_id_to_use
    and sanction.subject_type = 'CLAN'
    and sanction.clan_id = clan_id_to_release
    and sanction.sanction_kind in (
      'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
    )
    and sanction.revoked_at is null
  for update;
  if sanction_to_use.id is null
    or sanction_to_use.starts_at > release_at_to_use
    or (
      sanction_to_use.ends_at is not null
      and sanction_to_use.ends_at <= release_at_to_use
    )
  then
    return 0;
  end if;

  select coalesce(
    incident.fixture_id,
    nullif(incident.detail ->> 'fixture_id', '')::uuid
  ) into source_fixture_id
  from public.reliability_incidents incident
  where incident.id = sanction_to_use.incident_id;

  for fixture_to_release in
    select fixture.*
    from public.fixtures fixture
    where fixture.status in ('OPEN', 'SCHEDULED')
      and clan_id_to_release in (
        fixture.home_clan_id,
        fixture.away_clan_id
      )
      and fixture.id is distinct from source_fixture_id
      and public.fixture_start_at(fixture.match_date, fixture.time_slot)
        > release_at_to_use
    order by fixture.match_date, fixture.time_slot, fixture.id
    for update
  loop
    update public.fixtures fixture
    set
      status = 'CANCELLED',
      cancellation_code = 'ADMIN_CANCELLED',
      cancellation_reason =
        'Field cancelled this fixture because a participating clan became unavailable.',
      cancelled_at = release_at_to_use,
      cancelled_by = null,
      cancellation_context = coalesce(
        fixture.cancellation_context,
        '{}'::jsonb
      ) || jsonb_build_object(
        'source', 'FIELD_AUTOMATIC_RELEASE',
        'automatic', true,
        'released_at', release_at_to_use
      )
    where fixture.id = fixture_to_release.id;

    insert into public.clan_reliability_fixture_releases (
      fixture_id,
      suspended_clan_id,
      sanction_id,
      incident_id,
      source_fixture_id,
      released_at
    ) values (
      fixture_to_release.id,
      clan_id_to_release,
      sanction_to_use.id,
      sanction_to_use.incident_id,
      source_fixture_id,
      release_at_to_use
    ) on conflict (fixture_id) do nothing;

    insert into public.notifications (
      recipient_profile_id,
      type,
      title,
      body,
      related_entity_type,
      related_entity_id,
      data
    )
    select
      member.profile_id,
      'CLAN_RELIABILITY_OUTCOME',
      'Clan fixture cancelled',
      'Field cancelled this future fixture because a participating clan is under a reliability suspension. Any captured payment was returned to the original payer.',
      'FIXTURE',
      fixture_to_release.id,
      jsonb_build_object(
        'fixture_id', fixture_to_release.id,
        'refund_reason', 'FIELD_CLAN_RELIABILITY_SUSPENSION'
      )
    from public.clan_members member
    where member.clan_id in (
        fixture_to_release.home_clan_id,
        fixture_to_release.away_clan_id
      )
      and member.left_at is null
      and member.role in ('owner', 'leader');

    released_count := released_count + 1;
  end loop;

  return released_count;
end;
$$;

create or replace function public.release_fixtures_on_clan_participation_suspension()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.subject_type = 'CLAN'
    and new.sanction_kind in (
      'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
    )
    and new.revoked_at is null
    and new.starts_at <= clock_timestamp()
    and (new.ends_at is null or new.ends_at > clock_timestamp())
  then
    perform public.release_suspended_clan_future_fixtures(
      new.clan_id,
      new.id,
      greatest(new.starts_at, clock_timestamp())
    );
  end if;
  return new;
end;
$$;

drop trigger if exists release_fixtures_on_clan_participation_suspension
on public.reliability_sanctions;
create trigger release_fixtures_on_clan_participation_suspension
after insert on public.reliability_sanctions
for each row execute function public.release_fixtures_on_clan_participation_suspension();

-- The trigger above protects every new sanction after this migration. Release
-- fixtures for sanctions that were already active before the trigger existed
-- as well, including sanctions created by an earlier migration in this push.
do $migration$
declare
  active_sanction record;
  release_at_to_use timestamptz := clock_timestamp();
begin
  for active_sanction in
    select
      sanction.id,
      sanction.clan_id
    from public.reliability_sanctions sanction
    where sanction.subject_type = 'CLAN'
      and sanction.clan_id is not null
      and sanction.sanction_kind in (
        'PARTICIPATION_SUSPENSION', 'INDEFINITE_SUSPENSION'
      )
      and sanction.revoked_at is null
      and sanction.starts_at <= release_at_to_use
      and (
        sanction.ends_at is null
        or sanction.ends_at > release_at_to_use
      )
    order by sanction.starts_at, sanction.id
  loop
    perform public.release_suspended_clan_future_fixtures(
      active_sanction.clan_id,
      active_sanction.id,
      release_at_to_use
    );
  end loop;
end;
$migration$;

create table public.reliability_sr_appeal_adjustments (
  id uuid primary key default gen_random_uuid(),
  appeal_id uuid not null unique
    references public.reliability_appeals(id) on delete restrict,
  attendance_id uuid not null unique
    references public.match_attendance_records(id) on delete restrict,
  rating_event_id uuid not null unique
    references public.player_rating_events(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  source_type text not null check (
    source_type in ('OPEN_QUEUE', 'CLAN_FIXTURE')
  ),
  source_id uuid not null,
  policy_version_id uuid not null
    references public.reliability_policy_versions(id) on delete restrict,
  original_match_rating_change integer not null,
  corrected_match_rating_change integer not null,
  rating_adjustment integer not null,
  rating_before_adjustment integer not null check (
    rating_before_adjustment >= 0
  ),
  rating_after_adjustment integer not null check (
    rating_after_adjustment >= 0
  ),
  original_reliability_multiplier_bps integer not null check (
    original_reliability_multiplier_bps between 0 and 30000
  ),
  corrected_reliability_multiplier_bps integer not null check (
    corrected_reliability_multiplier_bps between 0 and 30000
  ),
  reviewed_by uuid not null references public.referee_profiles(profile_id)
    on delete restrict,
  detail jsonb not null default '{}'::jsonb check (
    jsonb_typeof(detail) = 'object'
  ),
  created_at timestamptz not null default clock_timestamp(),
  check (
    corrected_match_rating_change - original_match_rating_change
      = rating_adjustment
  ),
  check (
    rating_after_adjustment - rating_before_adjustment = rating_adjustment
  )
);

alter table public.reliability_sr_appeal_adjustments enable row level security;
revoke all on table public.reliability_sr_appeal_adjustments
from public, anon, authenticated;
grant all on table public.reliability_sr_appeal_adjustments to service_role;

drop trigger if exists protect_reliability_sr_appeal_adjustments_append_only
on public.reliability_sr_appeal_adjustments;
create trigger protect_reliability_sr_appeal_adjustments_append_only
before update or delete on public.reliability_sr_appeal_adjustments
for each row execute function public.protect_append_only_reliability_rows();

-- Rated lineup snapshots remain immutable, but their displayed match delta is
-- the immutable base event plus any append-only appeal correction.
do $migration$
declare
  function_definition text;
  old_solo text := $old$    select event.rating_change
    from public.player_rating_events event
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = new.game_id
      and event.profile_id = new.profile_id$old$;
  new_solo text := $new$    select event.rating_change +
      coalesce(adjustment.rating_adjustment, 0)
    from public.player_rating_events event
    left join public.reliability_sr_appeal_adjustments adjustment
      on adjustment.rating_event_id = event.id
    where event.source_type = 'OPEN_QUEUE'
      and event.source_id = new.game_id
      and event.profile_id = new.profile_id$new$;
  old_clan text := $old$    select event.rating_change
    from public.player_rating_events event
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = new.fixture_id
      and event.profile_id = new.profile_id$old$;
  new_clan text := $new$    select event.rating_change +
      coalesce(adjustment.rating_adjustment, 0)
    from public.player_rating_events event
    left join public.reliability_sr_appeal_adjustments adjustment
      on adjustment.rating_event_id = event.id
    where event.source_type = 'CLAN_FIXTURE'
      and event.source_id = new.fixture_id
      and event.profile_id = new.profile_id$new$;
begin
  select pg_get_functiondef(
    'public.protect_rated_open_queue_booking_inputs()'::regprocedure
  ) into function_definition;
  if position('reliability_sr_appeal_adjustments' in function_definition) = 0 then
    if position(old_solo in function_definition) = 0 then
      raise exception 'Could not make rated solo snapshots appeal-aware.';
    end if;
    function_definition := replace(function_definition, old_solo, new_solo);
    execute function_definition;
  end if;

  select pg_get_functiondef(
    'public.protect_rated_fixture_appearance_inputs()'::regprocedure
  ) into function_definition;
  if position('reliability_sr_appeal_adjustments' in function_definition) = 0 then
    if position(old_clan in function_definition) = 0 then
      raise exception 'Could not make rated clan snapshots appeal-aware.';
    end if;
    function_definition := replace(function_definition, old_clan, new_clan);
    execute function_definition;
  end if;
end;
$migration$;

create or replace function public.apply_late_appeal_sr_correction(
  actor_admin_id uuid,
  appeal_id_to_correct uuid,
  attendance_id_to_correct uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  attendance_to_correct public.match_attendance_records%rowtype;
  terms_to_use public.match_reliability_terms%rowtype;
  event_to_correct public.player_rating_events%rowtype;
  injury_to_use public.match_verified_injuries%rowtype;
  existing_adjustment_id uuid;
  adjustment_id_to_use uuid;
  current_rating integer;
  corrected_current_rating integer;
  pre_reliability_change integer;
  base_change integer;
  base_applied_change integer;
  neutral_multiplier_bps integer := 10000;
  corrected_match_change integer;
  correction_delta integer;
  nominal_seconds integer;
  match_seconds integer;
  qualifying_seconds integer;
  shorthanded_side_count integer := 0;
  shorthanded_side text;
  threshold_bps integer;
  injury_before_threshold boolean;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  if not exists (
    select 1 from public.reliability_appeals appeal
    where appeal.id = appeal_id_to_correct
      and appeal.attendance_id = attendance_id_to_correct
      and appeal.status = 'OVERTURNED'
      and appeal.reviewed_by = actor_admin_id
  ) then
    raise exception 'A matching approved reliability appeal is required.';
  end if;

  select adjustment.id into existing_adjustment_id
  from public.reliability_sr_appeal_adjustments adjustment
  where adjustment.appeal_id = appeal_id_to_correct;
  if existing_adjustment_id is not null then
    return existing_adjustment_id;
  end if;

  select * into attendance_to_correct
  from public.match_attendance_records attendance
  where attendance.id = attendance_id_to_correct
  for update;
  if attendance_to_correct.id is null then
    raise exception 'Appealed attendance record not found.';
  end if;

  select * into terms_to_use
  from public.match_reliability_terms terms
  where terms.id = attendance_to_correct.terms_id;
  if terms_to_use.id is null then
    raise exception 'The appealed match policy snapshot is unavailable.';
  end if;

  select * into event_to_correct
  from public.player_rating_events event
  where event.profile_id = attendance_to_correct.profile_id
    and event.source_type = case attendance_to_correct.match_kind
      when 'SOLO' then 'OPEN_QUEUE' else 'CLAN_FIXTURE' end
    and event.source_id = case attendance_to_correct.match_kind
      when 'SOLO' then attendance_to_correct.open_queue_game_id
      else attendance_to_correct.fixture_id end
  for update;

  -- No rating event means the match had not been rated for this player. The
  -- attendance/financial appeal remains valid, but there is no SR to correct.
  if event_to_correct.id is null
    or event_to_correct.attendance_outcome <> 'LATE'
    or event_to_correct.reliability_policy_version_id is null
  then
    return null;
  end if;

  if event_to_correct.source_type = 'OPEN_QUEUE'
    and event_to_correct.base_rating_change is not null
  then
    base_applied_change := greatest(
      0,
      event_to_correct.rating_before + event_to_correct.base_rating_change
    ) - event_to_correct.rating_before;
    pre_reliability_change := base_applied_change
      + coalesce(event_to_correct.margin_bonus_applied, 0);
  else
    select calculation.rating_change into base_change
    from public.calculate_player_sr_change(
      event_to_correct.rating_at_match_start,
      event_to_correct.opponent_average_rating,
      event_to_correct.result
    ) calculation;
    pre_reliability_change := greatest(
      0,
      event_to_correct.rating_before + base_change
    ) - event_to_correct.rating_before;
  end if;

  neutral_multiplier_bps := case event_to_correct.sr_protection_reason
    when 'SHORTHANDED_OPPONENT' then (terms_to_use.policy_snapshot #>>
      '{sr,protectedWinnerMultiplierBps}')::integer
    when 'SHORTHANDED_TEAM' then (terms_to_use.policy_snapshot #>>
      '{sr,protectedLosingOnTimeMultiplierBps}')::integer
    when 'SHORTHANDED_TEAM_WIN' then (terms_to_use.policy_snapshot #>>
      '{sr,disadvantagedWinnerMultiplierBps}')::integer
    else 10000
  end;

  -- A late player was deliberately excluded from responsible-teammate loss
  -- protection. Once the appeal excuses that lateness, recompute that one
  -- eligibility edge from the immutable shorthanded-period evidence.
  if event_to_correct.sr_protection_reason is null
    and pre_reliability_change < 0
  then
    match_seconds := public.reliability_match_elapsed_seconds(
      attendance_to_correct.match_kind,
      case attendance_to_correct.match_kind
        when 'SOLO' then attendance_to_correct.open_queue_game_id
        else attendance_to_correct.fixture_id
      end
    );
    qualifying_seconds := (terms_to_use.policy_snapshot #>>
      '{sr,shorthandedQualifyingActualMinutes}')::integer * 60;
    select
      count(distinct period.side)::integer,
      min(period.side)
    into shorthanded_side_count, shorthanded_side
    from public.match_shorthanded_periods period
    where period.terms_id = terms_to_use.id
      and period.reason in ('LATE_ARRIVAL', 'NO_SHOW')
      and period.started_match_second between 0 and 30
      and greatest(
        0,
        coalesce(period.ended_match_second, match_seconds)
          - period.started_match_second
      ) >= qualifying_seconds;
    if shorthanded_side_count = 1
      and shorthanded_side = event_to_correct.side
    then
      neutral_multiplier_bps := (terms_to_use.policy_snapshot #>>
        '{sr,protectedLosingOnTimeMultiplierBps}')::integer;
    end if;
  end if;

  if event_to_correct.sr_protection_reason = 'VERIFIED_INJURY' then
    select * into injury_to_use
    from public.match_verified_injuries injury
    where injury.terms_id = terms_to_use.id
      and injury.side = case
        when pre_reliability_change < 0 then event_to_correct.side
        when event_to_correct.side = 'WHITE' then 'BLACK'
        when event_to_correct.side = 'BLACK' then 'WHITE'
        when event_to_correct.side = 'HOME' then 'AWAY'
        else 'HOME'
      end
      and injury.unable_to_continue
      and not injury.replacement_available
    order by injury.match_second, injury.id
    limit 1;
    if injury_to_use.id is null then
      raise exception 'Verified injury evidence required for the SR correction is missing.';
    end if;

    if attendance_to_correct.match_kind = 'SOLO' then
      select greatest(
        1,
        floor(extract(epoch from (game.ends_at - game.starts_at)))::integer
      ) into nominal_seconds
      from public.open_queue_games game
      where game.id = attendance_to_correct.open_queue_game_id;
    else
      select greatest(1, coalesce(clock.duration_seconds, 3600))
      into nominal_seconds
      from public.fixture_clock_states clock
      where clock.fixture_id = attendance_to_correct.fixture_id;
      nominal_seconds := coalesce(nominal_seconds, 3600);
    end if;
    threshold_bps := (terms_to_use.policy_snapshot #>>
      '{injury,halfMatchThresholdBps}')::integer;
    injury_before_threshold :=
      injury_to_use.match_second::bigint * 10000
        < nominal_seconds::bigint * threshold_bps;
    neutral_multiplier_bps := case
      when pre_reliability_change < 0 and injury_before_threshold
        then (terms_to_use.policy_snapshot #>>
          '{injury,incompleteLosingMultiplierBps}')::integer
      when pre_reliability_change < 0
        then (terms_to_use.policy_snapshot #>>
          '{injury,completedLossMultiplierBps}')::integer
      when injury_before_threshold
        then (terms_to_use.policy_snapshot #>>
          '{injury,incompleteWinningMultiplierBps}')::integer
      else 10000
    end;
  end if;

  corrected_match_change := greatest(
    0,
    event_to_correct.rating_before + round(
      pre_reliability_change::numeric * neutral_multiplier_bps / 10000
    )::integer
  ) - event_to_correct.rating_before;
  correction_delta := corrected_match_change - event_to_correct.rating_change;

  select rating.skill_rating into current_rating
  from public.player_ratings rating
  where rating.profile_id = attendance_to_correct.profile_id
  for update;
  if current_rating is null then
    raise exception 'Player SR row is missing for the appeal correction.';
  end if;
  corrected_current_rating := greatest(0, current_rating + correction_delta);
  correction_delta := corrected_current_rating - current_rating;
  corrected_match_change := event_to_correct.rating_change + correction_delta;

  insert into public.reliability_sr_appeal_adjustments (
    appeal_id,
    attendance_id,
    rating_event_id,
    profile_id,
    source_type,
    source_id,
    policy_version_id,
    original_match_rating_change,
    corrected_match_rating_change,
    rating_adjustment,
    rating_before_adjustment,
    rating_after_adjustment,
    original_reliability_multiplier_bps,
    corrected_reliability_multiplier_bps,
    reviewed_by,
    detail
  ) values (
    appeal_id_to_correct,
    attendance_to_correct.id,
    event_to_correct.id,
    attendance_to_correct.profile_id,
    event_to_correct.source_type,
    event_to_correct.source_id,
    terms_to_use.policy_version_id,
    event_to_correct.rating_change,
    corrected_match_change,
    correction_delta,
    current_rating,
    corrected_current_rating,
    event_to_correct.reliability_multiplier_bps,
    neutral_multiplier_bps,
    actor_admin_id,
    jsonb_build_object(
      'source', 'LATE_ATTENDANCE_APPEAL',
      'pre_reliability_rating_change', pre_reliability_change,
      'sr_protection_reason', event_to_correct.sr_protection_reason,
      'original_attendance_outcome', event_to_correct.attendance_outcome,
      'injury_id', injury_to_use.id
    )
  ) returning id into adjustment_id_to_use;

  if correction_delta <> 0 then
    update public.player_ratings rating
    set
      skill_rating = corrected_current_rating,
      last_change = case
        when not exists (
          select 1 from public.player_rating_events later_event
          where later_event.profile_id = event_to_correct.profile_id
            and later_event.applied_sequence > event_to_correct.applied_sequence
        ) then corrected_match_change
        else rating.last_change
      end
    where rating.profile_id = attendance_to_correct.profile_id;
  end if;

  if event_to_correct.source_type = 'OPEN_QUEUE' then
    update public.open_queue_bookings booking
    set rating_change = corrected_match_change
    where booking.game_id = event_to_correct.source_id
      and booking.profile_id = event_to_correct.profile_id;
  else
    update public.fixture_player_appearances appearance
    set rating_change = corrected_match_change
    where appearance.fixture_id = event_to_correct.source_id
      and appearance.profile_id = event_to_correct.profile_id;
  end if;

  return adjustment_id_to_use;
end;
$$;

create or replace function public.reconcile_player_reliability_sanctions(
  actor_admin_id uuid,
  profile_id_to_reconcile uuid,
  appeal_id_to_use uuid,
  resolution_note_to_use text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  sanction_to_check record;
  corrected_active_before integer;
  corrected_active_after integer;
  revoked_count integer := 0;
begin
  if not public.is_active_moderation_admin(actor_admin_id) then
    raise exception 'Active administrator access is required.';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(profile_id_to_reconcile::text, 9174)
  );

  for sanction_to_check in
    select
      sanction.id,
      sanction.threshold,
      incident.id as incident_id,
      incident.occurred_at,
      incident.created_at,
      incident.strike_delta
    from public.reliability_sanctions sanction
    join public.reliability_incidents incident
      on incident.id = sanction.incident_id
    where sanction.subject_type = 'PLAYER'
      and sanction.profile_id = profile_id_to_reconcile
      and sanction.revoked_at is null
      and (sanction.ends_at is null or sanction.ends_at > clock_timestamp())
    order by sanction.starts_at, sanction.id
    for update of sanction
  loop
    select coalesce(sum(prior.strike_delta), 0)::integer
    into corrected_active_before
    from public.reliability_incidents prior
    where prior.subject_type = 'PLAYER'
      and prior.profile_id = profile_id_to_reconcile
      and prior.reversal_of is null
      and prior.strike_delta > 0
      and prior.id <> sanction_to_check.incident_id
      and (
        prior.occurred_at < sanction_to_check.occurred_at
        or (
          prior.occurred_at = sanction_to_check.occurred_at
          and (prior.created_at, prior.id) <
            (sanction_to_check.created_at, sanction_to_check.incident_id)
        )
      )
      and (prior.expires_at is null
        or prior.expires_at > sanction_to_check.occurred_at)
      and not exists (
        select 1 from public.reliability_incidents reversal
        where reversal.reversal_of = prior.id
      );

    corrected_active_after := corrected_active_before + greatest(
      0,
      sanction_to_check.strike_delta
    );
    if exists (
      select 1 from public.reliability_incidents reversal
      where reversal.reversal_of = sanction_to_check.incident_id
    ) or not (
      corrected_active_before < sanction_to_check.threshold
      and corrected_active_after >= sanction_to_check.threshold
    ) then
      update public.reliability_sanctions sanction
      set
        revoked_at = clock_timestamp(),
        revoked_by = actor_admin_id,
        revocation_reason = left(
          'Threshold crossing invalidated by reliability appeal ' ||
            appeal_id_to_use::text || ': ' || trim(resolution_note_to_use),
          2000
        )
      where sanction.id = sanction_to_check.id
        and sanction.revoked_at is null;
      if found then revoked_count := revoked_count + 1; end if;
    end if;
  end loop;

  return revoked_count;
end;
$$;

create or replace function public.correct_overturned_reliability_appeal_effects()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  attendance_to_correct public.match_attendance_records%rowtype;
  downstream_revoked_count integer := 0;
  sr_adjustment_id uuid;
begin
  if new.status <> 'OVERTURNED'
    or old.status = 'OVERTURNED'
  then
    return new;
  end if;

  select * into attendance_to_correct
  from public.match_attendance_records attendance
  where attendance.id = new.attendance_id;
  if attendance_to_correct.id is null then
    raise exception 'Appealed attendance record not found.';
  end if;

  downstream_revoked_count := public.reconcile_player_reliability_sanctions(
    new.reviewed_by,
    attendance_to_correct.profile_id,
    new.id,
    new.resolution_note
  );
  sr_adjustment_id := public.apply_late_appeal_sr_correction(
    new.reviewed_by,
    new.id,
    attendance_to_correct.id
  );

  update public.match_attendance_records attendance
  set consequence_snapshot = attendance.consequence_snapshot ||
    jsonb_build_object(
      'post_final_appeal_effects', jsonb_build_object(
        'appeal_id', new.id,
        'sr_adjustment_id', sr_adjustment_id,
        'downstream_sanctions_revoked', downstream_revoked_count,
        'corrected_at', clock_timestamp()
      )
    )
  where attendance.id = attendance_to_correct.id;
  return new;
end;
$$;

drop trigger if exists correct_overturned_reliability_appeal_effects
on public.reliability_appeals;
create trigger correct_overturned_reliability_appeal_effects
after update of status on public.reliability_appeals
for each row execute function public.correct_overturned_reliability_appeal_effects();

-- Player history presents the corrected match delta while preserving the
-- original immutable event and exposing the append-only appeal adjustment.
do $migration$
declare
  function_definition text;
  old_rating text := $old$        'rating_change', event.rating_change,
        'rating_after', event.rating_after,$old$;
  new_rating text := $new$        'rating_change', event.rating_change +
          coalesce(sr_appeal.rating_adjustment, 0),
        'rating_after', event.rating_before + event.rating_change +
          coalesce(sr_appeal.rating_adjustment, 0),
        'original_rating_change', event.rating_change,
        'original_rating_after', event.rating_after,
        'appeal_rating_adjustment',
          coalesce(sr_appeal.rating_adjustment, 0),
        'appeal_adjustment_id', sr_appeal.id,$new$;
  old_where text := $old$    left join public.open_queue_games game
      on event.source_type = 'OPEN_QUEUE'
      and game.id = event.source_id
    where event.profile_id = profile_id_to_use$old$;
  new_where text := $new$    left join public.open_queue_games game
      on event.source_type = 'OPEN_QUEUE'
      and game.id = event.source_id
    left join public.reliability_sr_appeal_adjustments sr_appeal
      on sr_appeal.rating_event_id = event.id
    where event.profile_id = profile_id_to_use$new$;
begin
  select pg_get_functiondef(
    'public.get_player_rating_history(uuid,integer)'::regprocedure
  ) into function_definition;
  if position('appeal_rating_adjustment' in function_definition) = 0 then
    if position(old_rating in function_definition) = 0
      or position(old_where in function_definition) = 0
    then
      raise exception 'Could not expose appeal SR corrections in player history.';
    end if;
    function_definition := replace(function_definition, old_rating, new_rating);
    function_definition := replace(function_definition, old_where, new_where);
    execute function_definition;
  end if;
end;
$migration$;

revoke all on function public.settle_verified_early_injury_refunds(
  uuid, uuid, uuid
) from public, anon, authenticated;
revoke all on function public.clan_has_active_participation_suspension(
  uuid, timestamptz
) from public, anon, authenticated;
revoke all on function public.enforce_clan_participation_suspension_at_start()
from public, anon, authenticated;
revoke all on function public.release_suspended_clan_future_fixtures(
  uuid, uuid, timestamptz
) from public, anon, authenticated;
revoke all on function public.release_fixtures_on_clan_participation_suspension()
from public, anon, authenticated;
revoke all on function public.apply_late_appeal_sr_correction(
  uuid, uuid, uuid
) from public, anon, authenticated;
revoke all on function public.reconcile_player_reliability_sanctions(
  uuid, uuid, uuid, text
) from public, anon, authenticated;
revoke all on function public.correct_overturned_reliability_appeal_effects()
from public, anon, authenticated;

grant execute on function public.settle_verified_early_injury_refunds(
  uuid, uuid, uuid
) to service_role;
grant execute on function public.clan_has_active_participation_suspension(
  uuid, timestamptz
) to service_role;
grant execute on function public.release_suspended_clan_future_fixtures(
  uuid, uuid, timestamptz
) to service_role;
grant execute on function public.apply_late_appeal_sr_correction(
  uuid, uuid, uuid
) to service_role;
grant execute on function public.reconcile_player_reliability_sanctions(
  uuid, uuid, uuid, text
) to service_role;

comment on table public.reliability_sr_appeal_adjustments is
'Append-only SR correction ledger for approved post-final late-attendance appeals; original match rating events remain immutable.';

comment on function public.clan_has_active_participation_suspension(
  uuid, timestamptz
) is
'Returns whether a clan has an active participation or indefinite reliability suspension. Booking-only restrictions are intentionally excluded.';
