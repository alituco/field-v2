-- Solo cancellation closes one booking, not the player's right to buy another
-- available place. Each new booking gets its own attendance identity; cancelled
-- attendance, events, strikes, appeals and payment/refund links remain history.
alter table public.match_attendance_records
  add column is_current boolean not null default true;
comment on column public.match_attendance_records.is_current is
  'Operational attendance selector. A subsequent confirmed solo booking supersedes only its cancelled predecessor; historical financial and reliability records remain addressable by their original IDs.';
drop index public.match_attendance_solo_profile_idx;
create unique index match_attendance_solo_booking_idx
  on public.match_attendance_records(booking_id)
  where match_kind = 'SOLO' and booking_id is not null;
create unique index match_attendance_solo_current_profile_idx
  on public.match_attendance_records(open_queue_game_id, profile_id)
  where match_kind = 'SOLO' and is_current;

-- Operational consumers use a simple, lockable/updatable view. Historical
-- ID-based refund/appeal reads deliberately keep using the physical table.
create view public.current_match_attendance_records
  with (security_invoker = true) as
  select * from public.match_attendance_records where is_current;
revoke all on public.current_match_attendance_records from public, anon, authenticated;
grant select on public.current_match_attendance_records to service_role;

-- Quote/prepare must reject known unsafe legacy/orphan attendance before money
-- is collected. The trigger repeats this pure validation under booking locks.
create function public.assert_open_queue_rebooking_eligible(player_id_to_check uuid, game_id_to_check uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (
    select 1 from public.match_attendance_records a
    where a.match_kind = 'SOLO' and a.open_queue_game_id = game_id_to_check
      and a.profile_id = player_id_to_check and a.is_current
      and not exists (
        select 1 from public.open_queue_bookings b
        where b.id = a.booking_id and b.game_id = game_id_to_check
          and b.profile_id = player_id_to_check and b.status in ('CONFIRMED', 'CANCELLED')
      )
  ) then
    raise exception 'This player''s previous attendance requires admin review before rebooking.';
  end if;
end;
$$;
revoke all on function public.assert_open_queue_rebooking_eligible(uuid,uuid) from public, anon, authenticated;
grant execute on function public.assert_open_queue_rebooking_eligible(uuid,uuid) to service_role;

create or replace function public.prevent_same_solo_game_rebooking()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status <> 'CONFIRMED' then return new; end if;
  -- Same order/locks as booking and capacity. The whole insert, supersession
  -- and fresh attendance creation roll back together if any later guard fails.
  perform pg_advisory_xact_lock(hashtext(new.profile_id::text)::bigint);
  perform 1 from public.open_queue_games where id = new.game_id for update;
  perform public.assert_open_queue_rebooking_eligible(new.profile_id, new.game_id);
  if tg_op = 'UPDATE' and exists (
    select 1 from public.match_attendance_records a
    where a.match_kind = 'SOLO' and a.booking_id = new.id and not a.is_current
  ) then
    raise exception 'A superseded booking cannot be restored. Create a new booking at the current price.';
  end if;
  if exists (
    select 1 from public.open_queue_bookings b
    where b.game_id = new.game_id and b.profile_id = new.profile_id
      and b.status = 'CONFIRMED' and b.id <> new.id
  ) then
    raise exception 'You already booked this Open Queue game.';
  end if;
  -- Orphan/manual attendance is not proof of a cancelled booking. Fail closed
  -- rather than recycle that record or hide an unresolved attendance decision.
  if exists (
    select 1 from public.match_attendance_records a
    where a.match_kind = 'SOLO' and a.open_queue_game_id = new.game_id
      and a.profile_id = new.profile_id and a.is_current
      and a.booking_id is distinct from new.id
      and not exists (
        select 1 from public.open_queue_bookings prior
        where prior.id = a.booking_id and prior.game_id = new.game_id
          and prior.profile_id = new.profile_id and prior.status = 'CANCELLED'
      )
  ) then
    raise exception 'This player''s previous attendance requires admin review before rebooking.';
  end if;
  update public.match_attendance_records a
  set is_current = false
  where a.match_kind = 'SOLO' and a.open_queue_game_id = new.game_id
    and a.profile_id = new.profile_id and a.is_current
    and a.booking_id is distinct from new.id
    and exists (
      select 1 from public.open_queue_bookings prior
      where prior.id = a.booking_id and prior.game_id = new.game_id
        and prior.profile_id = new.profile_id and prior.status = 'CANCELLED'
    );
  return new;
end;
$$;
drop trigger prevent_same_solo_game_rebooking on public.open_queue_bookings;
create trigger prevent_same_solo_game_rebooking
  before insert or update of game_id, profile_id, status on public.open_queue_bookings
  for each row execute function public.prevent_same_solo_game_rebooking();
comment on function public.prevent_same_solo_game_rebooking() is
  'Serializes solo rebooking and supersedes cancelled booking attendance metadata without resetting its historical outcome, strikes, deposit, events, appeal or refund identity.';

do $migration$
declare definition text; anchor text; signature text;
begin
  definition := pg_get_functiondef('public.ensure_match_attendance_records(text,uuid)'::regprocedure);
  anchor := E'on conflict (open_queue_game_id, profile_id)\n      where match_kind = ''SOLO''';
  if position(anchor in definition) = 0 then raise exception 'Solo attendance identity contract changed.'; end if;
  definition := replace(definition, anchor,
    E'on conflict (booking_id)\n      where match_kind = ''SOLO'' and booking_id is not null');
  -- An unchanged booking may sync its role/team, but cannot swap the owner of
  -- historical attendance. New IDs insert with fresh check-in/outcome/deposit.
  anchor := E'      booking_id = excluded.booking_id,\n';
  if position(anchor in definition) = 0 then raise exception 'Solo attendance booking binding changed.'; end if;
  definition := replace(definition, anchor, '');
  definition := replace(definition, 'from public.match_attendance_records attendance',
    'from public.current_match_attendance_records attendance');
  execute definition;

  -- These functions interpret the current match/roster, not a history ID.
  -- Replace only FROM/JOIN relations: rowtypes and base-table writes remain
  -- unchanged, and FOR UPDATE/SHARE locks propagate through the simple view.
  foreach signature in array array[
    'public.admin_force_assign_open_queue_teams(uuid,uuid,text)',
    'public.admin_report_game_player(uuid,text,uuid,uuid,text,text,text,integer)',
    'public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)',
    'public.apply_open_queue_reliability_rating_adjustments(uuid)',
    'public.assert_player_has_one_game(uuid,text,uuid,boolean)',
    'public.book_open_queue_game_server(uuid,text,text,text)',
    'public.enforce_reactivated_player_game_limit()',
    'public.finalize_match_attendance_internal(text,uuid,uuid)',
    'public.get_match_reliability_context(text,uuid)',
    'public.match_resolution_evidence_snapshot(text,uuid)',
    'public.preview_open_queue_booking_cost(uuid,text)',
    'public.referee_check_in_player_with_timing(uuid,text,uuid,uuid,text)',
    'public.referee_check_in_player(uuid,text,uuid,uuid)',
    'public.referee_complete_open_queue_game(uuid)',
    'public.referee_end_shorthanded_period(uuid,uuid,uuid,text)',
    'public.referee_record_verified_injury(uuid,text,uuid,uuid,boolean,boolean,boolean,text)',
    'public.referee_remove_player_check_in(uuid,text,uuid,uuid,integer,text,text)',
    'public.referee_start_open_queue_game(uuid,uuid[],integer)',
    'public.referee_start_shorthanded_period(uuid,text,uuid,text,text,uuid,text)',
    'public.require_checked_in_match_participant()'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    if position('from public.match_attendance_records ' in definition) = 0
      and position('join public.match_attendance_records ' in definition) = 0 then
      raise exception 'Current attendance selector contract changed: %.', signature;
    end if;
    definition := replace(definition, 'from public.match_attendance_records ',
      'from public.current_match_attendance_records ');
    definition := replace(definition, 'join public.match_attendance_records ',
      'join public.current_match_attendance_records ');
    execute definition;
  end loop;

  -- Cancellation remains addressable by the specific booking's attendance;
  -- an earlier cancelled attendance must not disable cancellation of rebooking.
  definition := pg_get_functiondef('public.open_queue_cancellation_quote(uuid,uuid,timestamptz)'::regprocedure);
  anchor := E'where attendance.open_queue_game_id = game_to_preview.id\n      and attendance.profile_id = profile_id_to_use';
  if position(anchor in definition) = 0 then raise exception 'Cancellation quote attendance selector changed.'; end if;
  execute replace(definition, anchor, 'where attendance.booking_id = booking_to_preview.id');
  definition := pg_get_functiondef('public.cancel_open_queue_booking_policy(uuid)'::regprocedure);
  anchor := E'where attendance.open_queue_game_id = game_to_reopen.id\n    and attendance.profile_id = user_id';
  if position(anchor in definition) = 0 then raise exception 'Cancellation attendance selector changed.'; end if;
  execute replace(definition, anchor, 'where attendance.booking_id = booking_to_cancel.id');

  -- A superseded cancellation never produced a played rating event. Reviewing
  -- its historical appeal still reverses the old incident/refund as before,
  -- but must not apply a late-arrival SR correction to the rebooking's event.
  -- Unsuperseded played attendance retains its existing SR correction path.
  definition := pg_get_functiondef('public.apply_late_appeal_sr_correction(uuid,uuid,uuid)'::regprocedure);
  anchor := E'  select * into event_to_correct\n';
  if position(anchor in definition) = 0 then raise exception 'Appeal rating-event selector changed.'; end if;
  execute replace(definition, anchor,
    E'  if attendance_to_correct.match_kind = ''SOLO'' and not attendance_to_correct.is_current then\n    return null;\n  end if;\n\n' || anchor);

  -- In booking contexts bind the attendance to that exact booking in addition
  -- to the current-view filter, rather than relying only on player/game keys.
  foreach signature in array array[
    'public.admin_force_assign_open_queue_teams(uuid,uuid,text)',
    'public.referee_start_open_queue_game(uuid,uuid[],integer)',
    'public.referee_complete_open_queue_game(uuid)'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    anchor := 'and attendance.profile_id = booking.profile_id';
    if position(anchor in definition) = 0 then raise exception 'Booked attendance join changed: %.', signature; end if;
    execute replace(definition, anchor, anchor || E'\n      and attendance.booking_id = booking.id');
  end loop;
  definition := pg_get_functiondef('public.require_checked_in_match_participant()'::regprocedure);
  anchor := 'and attendance.open_queue_game_id = new.game_id';
  if position(anchor in definition) = 0 then raise exception 'Played booking attendance selector changed.'; end if;
  execute replace(definition, anchor, anchor || E'\n          and attendance.booking_id = new.id');
  definition := pg_get_functiondef('public.assert_player_has_one_game(uuid,text,uuid,boolean)'::regprocedure);
  anchor := 'and a.profile_id=b.profile_id';
  if position(anchor in definition) = 0 then raise exception 'One-game booked attendance selector changed.'; end if;
  execute replace(definition, anchor, anchor || ' and a.booking_id=b.id');
  foreach signature in array array[
    'public.preview_open_queue_booking_cost(uuid,text)',
    'public.book_open_queue_game_server(uuid,text,text,text)'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    anchor := 'and a.profile_id=existing.profile_id';
    if position(anchor in definition) = 0 then raise exception 'Booked overlap attendance selector changed: %.', signature; end if;
    execute replace(definition, anchor, anchor || ' and a.booking_id=existing.id');
  end loop;

  foreach signature in array array[
    'public.preview_open_queue_booking_cost(uuid,text)',
    'public.book_open_queue_game_server(uuid,text,text,text)'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    anchor := '  terms_to_use := public.ensure_match_reliability_terms(';
    if position(anchor in definition) = 0 then raise exception 'Rebooking preflight policy contract changed: %.', signature; end if;
    execute replace(definition, anchor,
      E'  perform public.assert_open_queue_rebooking_eligible(user_id, game_to_book.id);\n' || anchor);
  end loop;

  -- Current SR belongs to the current confirmed booking. Replaying a match's
  -- rating pipeline must never copy it onto older cancelled booking history.
  definition := pg_get_functiondef('public.apply_open_queue_player_ratings(uuid)'::regprocedure);
  anchor := E'where booking.game_id = game_id_to_apply\n    and booking.profile_id = event.profile_id';
  if position(anchor in definition) = 0 then raise exception 'Solo base rating booking update changed.'; end if;
  execute replace(definition, anchor, anchor || E'\n    and booking.status = ''CONFIRMED''');
  definition := pg_get_functiondef('public.apply_open_queue_reliability_rating_adjustments(uuid)'::regprocedure);
  anchor := E'where game_id = game_id_to_apply\n      and profile_id = event_to_adjust.profile_id';
  if position(anchor in definition) = 0 then raise exception 'Solo reliability rating booking update changed.'; end if;
  execute replace(definition, anchor, anchor || E'\n      and status = ''CONFIRMED''');
  definition := pg_get_functiondef('public.apply_late_appeal_sr_correction(uuid,uuid,uuid)'::regprocedure);
  anchor := E'where booking.game_id = event_to_correct.source_id\n      and booking.profile_id = event_to_correct.profile_id';
  if position(anchor in definition) = 0 then raise exception 'Appeal rating booking update changed.'; end if;
  execute replace(definition, anchor, 'where booking.id = attendance_to_correct.booking_id');

  -- An admin may restore an administratively cancelled CURRENT booking, but
  -- cannot resurrect a superseded earlier generation of the same player/game.
  definition := pg_get_functiondef('public.admin_resolve_match_case(uuid,text,uuid,integer,text,text,jsonb)'::regprocedure);
  anchor := 'and solo_booking_ids_to_restore ? booking.id::text';
  if position(anchor in definition) = 0 then raise exception 'Admin solo booking restoration contract changed.'; end if;
  execute replace(definition, anchor, anchor || E'\n          and exists (select 1 from public.current_match_attendance_records current_attendance\n            where current_attendance.booking_id = booking.id)');
end;
$migration$;

notify pgrst, 'reload schema';
