-- Assert the exact pre-007 committed fixtures AFTER the real migration runs.
-- Invoke with the optional hook in test_season_zero_migration_chain.mjs.
-- This paired fixture is intentionally not a standalone verify_*.sql script.
create temporary table backfill_arrival_checks(label text);
create function pg_temp.backfill_arrival_expect(ok boolean,label text)
returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Arrival rollout: %',label; end if;
  insert into backfill_arrival_checks values(label); end;
$$;

do $verify$
declare game uuid:=(select id from backfill_arrival_ids where name='game');
  early_player uuid:=(select id from backfill_arrival_ids where name='early_player');
  late_player uuid:=(select id from backfill_arrival_ids where name='late_player');
  terms public.match_reliability_terms; projected public.match_reliability_terms;
  early public.match_attendance_records; late public.match_attendance_records;
  r record; actual jsonb; old_terms jsonb;
begin
  select * into terms from public.match_reliability_terms where open_queue_game_id=game;
  select before into old_terms from backfill_arrival_rows where kind='terms' and id=terms.id;
  perform pg_temp.backfill_arrival_expect(terms.arrival_policy_version_id='solo-arrival-30-10-v1'
    and terms.arrival_check_in_opens_at=terms.kickoff_at-interval '30 minutes'
    and terms.arrival_check_in_deadline_at=terms.kickoff_at-interval '10 minutes',
    'already booked future game receives the new saved 30/10 arrival contract');
  perform pg_temp.backfill_arrival_expect(to_jsonb(terms)-array['arrival_policy_version_id','arrival_check_in_opens_at','arrival_check_in_deadline_at']=old_terms,
    'every accepted commercial terms byte, policy snapshot and original cutoff stays unchanged');
  perform pg_temp.backfill_arrival_expect((select count(*)=3 and bool_and(amount_paid_fils=13000
    and base_amount_fils=13000 and payment_method='CARD' and payment_reference like 'synthetic-pre-007-paid-%')
    from public.open_queue_bookings where game_id=game),
    'the rollout fixture has three genuine preexisting committed paid-booking rows');

  for r in select * from backfill_arrival_rows loop
    case r.kind
      when 'game' then select to_jsonb(x) into actual from public.open_queue_games x where id=r.id;
      when 'booking' then select to_jsonb(x) into actual from public.open_queue_bookings x where id=r.id;
      when 'fixture' then select to_jsonb(x) into actual from public.fixtures x where id=r.id;
      when 'terms' then
        select to_jsonb(x)-array['arrival_policy_version_id','arrival_check_in_opens_at','arrival_check_in_deadline_at']
          into actual from public.match_reliability_terms x where id=r.id;
      when 'attendance' then
        select to_jsonb(x) into actual from public.match_attendance_records x where id=r.id;
        if r.before->>'outcome' is null and r.before->>'finalized_at' is null then
          perform pg_temp.backfill_arrival_expect((actual->>'check_in_deadline_at')::timestamptz=terms.arrival_check_in_deadline_at,
            'unfinalized existing attendance deadline is updated '||r.id);
          actual:=actual-array['check_in_deadline_at','updated_at'];
          r.before:=r.before-array['check_in_deadline_at','updated_at'];
        end if;
      else raise exception 'Unexpected rollout reference kind %',r.kind;
    end case;
    perform pg_temp.backfill_arrival_expect(actual=r.before,
      'preexisting '||r.kind||' preserves all unrelated fields '||r.id);
  end loop;
  perform pg_temp.backfill_arrival_expect((select bool_and(t.arrival_policy_version_id is null
    and t.arrival_check_in_opens_at is null and t.arrival_check_in_deadline_at is null)
    from public.match_reliability_terms t where t.id in(select id from backfill_arrival_rows
      where kind='terms' and id<>terms.id)),
    'historical Solo and Clan controls do not receive arrival policy or deadlines');

  select * into early from public.match_attendance_records where open_queue_game_id=game and profile_id=early_player and is_current;
  select * into late from public.match_attendance_records where open_queue_game_id=game and profile_id=late_player and is_current;
  projected:=fieldrush_private.arrival_attendance_terms(terms);
  perform pg_temp.backfill_arrival_expect(early.check_in_timing='EARLY'
    and fieldrush_private.arrival_is_on_time(early.checked_in_at,early.check_in_timing,projected),
    'pre-migration manual Early remains authoritative after rollout');
  perform pg_temp.backfill_arrival_expect(late.check_in_timing='LATE'
    and late.checked_in_at<terms.arrival_check_in_deadline_at
    and not fieldrush_private.arrival_is_on_time(late.checked_in_at,late.check_in_timing,projected)
    and (projected.policy_snapshot#>>'{solo,outcomes,late,strikes}')::integer=1,
    'manual Late keeps one-strike classification even when its old classified timestamp is before the new cutoff');

  for r in select * from backfill_arrival_state loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by id),''[]'') from public.%I x',
      case r.name when 'policies' then 'reliability_policy_versions'
        when 'audit_events' then 'admin_audit_events'
        when 'wallet_transactions' then 'field_wallet_transactions' else r.name end) into actual;
    perform pg_temp.backfill_arrival_expect(actual=r.before,
      'rollout leaves policy, payment, refund and append-only evidence unchanged: '||r.name);
  end loop;
end;
$verify$;
select count(*)||' true pre-007 rollout assertions passed' as result from backfill_arrival_checks;
