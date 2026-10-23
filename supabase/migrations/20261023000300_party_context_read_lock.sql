-- Reading an already-booked party must not queue behind unrelated game writes.
-- Checkout/booking and schedule triggers already bind its committed policy.
-- Retain lazy initialization and reschedule validation for missing/stale terms.
do $migration$
declare
  definition text;
  anchor text := $old$  policy_terms := public.ensure_match_reliability_terms(
    'SOLO', game_id_to_use
  );$old$;
  replacement text := $new$  select * into policy_terms
  from public.match_reliability_terms terms
  where terms.match_kind = 'SOLO'
    and terms.open_queue_game_id = game_id_to_use
    and terms.kickoff_at = game_to_use.starts_at;
  if policy_terms.id is null then
    policy_terms := public.ensure_match_reliability_terms(
      'SOLO', game_id_to_use
    );
  end if;$new$;
begin
  definition := pg_get_functiondef(
    'public.get_open_queue_party_context_before_sr_privacy(uuid)'::regprocedure
  );
  if position(anchor in definition) = 0 then
    raise exception 'Party context reliability-terms contract changed.';
  end if;
  execute replace(definition, anchor, replacement);
  -- The fallback can still bind terms. PostgREST must permit that write.
  if (select provolatile from pg_proc where oid =
      'public.get_open_queue_party_context(uuid)'::regprocedure) <> 'v'::"char"
    or (select provolatile from pg_proc where oid =
      'public.get_open_queue_party_context_before_sr_privacy(uuid)'::regprocedure) <> 'v'::"char"
  then
    raise exception 'Party context must retain its volatile transaction contract.';
  end if;
end;
$migration$;

-- Only the private implementation changed. Keep the public SR privacy wrapper
-- and existing authenticated/service-role grants exactly as deployed.
notify pgrst, 'reload schema';
