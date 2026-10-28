-- Prospective Season 0 arithmetic only. This migration does not activate the
-- policy, change existing rating functions, seed/reset players, or settle games.
-- Callers must supply server-normalized, adjudicated inputs from one snapshot.
-- Fixture inputs may describe a subset of players: roster/timeline validation
-- belongs to the normalizer, not this pure calculation boundary.
-- Approved extension: BLUE_CARD records temporary-dismissal history (including
-- a later return). Its personal eligibility follows RED_CARD. The normalizer
-- owns the 120-wall-second expiry, referee-approved return, retained contribution,
-- and actual-five-player pause rule; none can be derived from these totals.

create function fieldrush_rating_private.season_zero_sr_number(value jsonb, field_name text)
returns numeric language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare result numeric;
begin
  if jsonb_typeof(value) is distinct from 'number' then
    raise exception '% must be a finite JSON number', field_name using errcode = '22023';
  end if;
  result := value::text::numeric;
  -- Match the finite-number domain of the reference; never coerce strings,
  -- booleans, null, NaN, or infinity into a rating input.
  if result::text in ('NaN', 'Infinity', '-Infinity')
      or abs(result) > 1.7976931348623157e308::numeric then
    raise exception '% must be finite', field_name using errcode = '22023';
  end if;
  return result;
end;
$$;

create function fieldrush_rating_private.season_zero_sr_integer(
  value jsonb, field_name text, minimum_value integer default null
)
returns integer language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare result numeric;
begin
  result := fieldrush_rating_private.season_zero_sr_number(value, field_name);
  if result <> trunc(result) or result < -2147483648::numeric or result > 2147483647::numeric
      or (minimum_value is not null and result < minimum_value) then
    raise exception '% must be an in-range integer (minimum %)', field_name, minimum_value
      using errcode = '22023';
  end if;
  return result::integer;
end;
$$;

create function fieldrush_rating_private.season_zero_sr_seed(assessment text)
returns integer language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
begin
  case assessment
    when 'beginner' then return 800;
    when 'casual' then return 900;
    when 'intermediate' then return 1000;
    when 'advanced' then return 1100;
    when 'highly_competitive' then return 1200;
    when 'not_sure' then return 1000;
    else raise exception 'Unknown self-assessment' using errcode = '22023';
  end case;
end;
$$;

create function fieldrush_rating_private.season_zero_sr_k(games_before integer)
returns integer language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
begin
  if games_before is null or games_before < 0 then
    raise exception 'games_before must be nonnegative' using errcode = '22023';
  end if;
  return case when games_before < 6 then 80 when games_before < 10 then 60 else 40 end;
end;
$$;

create function fieldrush_rating_private.season_zero_sr_round(value numeric)
returns integer language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare result numeric;
begin
  if value is null or value::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'Rounding input must be finite' using errcode = '22023';
  end if;
  -- PostgreSQL numeric round is symmetric half-away-from-zero, unlike float8.
  result := round(value);
  if result < -2147483648::numeric or result > 2147483647::numeric then
    raise exception 'Rounded result exceeds integer storage bounds' using errcode = '22023';
  end if;
  return result::integer;
end;
$$;

create function fieldrush_rating_private.season_zero_sr_public_state(sr integer, games integer)
returns jsonb language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
begin
  if sr is null or games is null or games < 0 then
    raise exception 'Public state requires SR and nonnegative games' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'visible', games >= 2,
    'public_sr', case when games >= 2 then sr else null end,
    'provisional', games >= 2 and games < 10
  );
end;
$$;

create function fieldrush_rating_private.season_zero_sr_expected(difference numeric)
returns numeric language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare z numeric;
begin
  if difference is null or difference::text in ('NaN', 'Infinity', '-Infinity')
      or abs(difference) > 1.7976931348623157e308::numeric then
    raise exception 'Effective difference must be finite' using errcode = '22023';
  end if;
  -- Branch on sign so exponentiation never overflows. Beyond 10^-324 the
  -- reference's float cannot represent the probability; saturating only the
  -- expectation here avoids numeric exponent underflow, not an SR floor/cap.
  if difference >= 129600 then return 1; end if;
  if difference <= -129600 then return 0; end if;
  z := power(10::numeric, round(-abs(difference) / 400, 60));
  if difference >= 0 then return 1 / (1 + z); end if;
  return z / (1 + z);
end;
$$;

create function fieldrush_rating_private.calculate_season_zero_sr(data jsonb)
returns jsonb language plpgsql immutable parallel safe
set search_path = pg_catalog as $$
declare
  status text;
  scheduled integer;
  played integer;
  winner text;
  strength_a numeric;
  strength_b numeric;
  manpower numeric;
  rated boolean;
  settlement text;
  denominator integer;
  difference numeric;
  expected_a numeric;
  expected_b numeric;
  player jsonb;
  player_id text;
  seen_ids text[] := array[]::text[];
  sr_before integer;
  games_before integer;
  actual_seconds integer;
  protected_seconds integer;
  reason text;
  k integer;
  actual_result numeric;
  expected numeric;
  raw_delta numeric;
  q numeric;
  multiplier numeric;
  forgiven numeric;
  adjusted numeric;
  counted boolean;
  delta integer;
  games_after integer;
  sr_after integer;
  results jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(data) is distinct from 'object'
      or data->>'policy_id' is distinct from 'field-sr-season0-v2' then
    raise exception 'Unsupported policy_id or input object' using errcode = '22023';
  end if;
  status := data->>'status';
  if status is null or status not in (
      'completed', 'forfeit_confirmed', 'no_contest', 'cancelled', 'unranked', 'pending_review') then
    raise exception 'Unknown match status' using errcode = '22023';
  end if;
  scheduled := fieldrush_rating_private.season_zero_sr_integer(data->'scheduled_seconds', 'scheduled_seconds', 600);
  played := fieldrush_rating_private.season_zero_sr_integer(data->'played_seconds', 'played_seconds', 0);
  if not data ? 'winner' or (data->'winner' <> 'null'::jsonb and (
      jsonb_typeof(data->'winner') <> 'string' or data->>'winner' not in ('A', 'B'))) then
    raise exception 'winner must be A, B, or null (draw)' using errcode = '22023';
  end if;
  winner := data->>'winner';
  if status = 'forfeit_confirmed' and winner is null then
    raise exception 'A confirmed forfeit needs a winner' using errcode = '22023';
  end if;
  if status = 'completed' and played < scheduled then
    raise exception 'A shortened session is not a normally completed match' using errcode = '22023';
  end if;
  strength_a := fieldrush_rating_private.season_zero_sr_number(data#>'{team_strengths,A}', 'team_strengths.A');
  strength_b := fieldrush_rating_private.season_zero_sr_number(data#>'{team_strengths,B}', 'team_strengths.B');
  manpower := fieldrush_rating_private.season_zero_sr_number(data->'average_count_difference_a', 'manpower');
  if manpower < -2 or manpower > 2 then
    raise exception 'Normalized manpower must respect the 5-to-7 format' using errcode = '22023';
  end if;
  if jsonb_typeof(data->'players') is distinct from 'array' then
    raise exception 'players must be an array' using errcode = '22023';
  end if;

  -- Validate every snapshot even for held/unrated matches. Do not partially
  -- calculate a roster or silently convert a malformed result into zero points.
  for player in select value from jsonb_array_elements(data->'players') loop
    player_id := player->>'id';
    if jsonb_typeof(player) is distinct from 'object'
        or jsonb_typeof(player->'id') is distinct from 'string'
        or player_id = '' or player_id = any(seen_ids) then
      raise exception 'Player IDs must be nonempty and unique' using errcode = '22023';
    end if;
    seen_ids := array_append(seen_ids, player_id);
    if player->>'team' is null or player->>'team' not in ('A', 'B') then
      raise exception 'Player team must be A or B' using errcode = '22023';
    end if;
    perform fieldrush_rating_private.season_zero_sr_integer(player->'sr_before', 'sr_before');
    perform fieldrush_rating_private.season_zero_sr_integer(player->'games_before', 'games_before', 0);
    actual_seconds := fieldrush_rating_private.season_zero_sr_integer(player->'actual_seconds', 'actual_seconds', 0);
    protected_seconds := fieldrush_rating_private.season_zero_sr_integer(player->'protected_seconds', 'protected_seconds', 0);
    if protected_seconds > actual_seconds or actual_seconds > played then
      raise exception 'Require protected_seconds <= actual_seconds <= played' using errcode = '22023';
    end if;
    reason := player->>'exit_reason';
    if reason is null or reason not in ('NORMAL', 'EXCUSED', 'QUIT', 'RED_CARD', 'BLUE_CARD') then
      raise exception 'Unknown/unadjudicated departure reason' using errcode = '22023';
    end if;
  end loop;

  rated := status = 'completed' or (status = 'forfeit_confirmed' and played >= 600);
  settlement := case when rated then 'RATED' when status = 'pending_review' then 'HELD' else 'NOT_RATED' end;
  if rated then
    denominator := case when status = 'forfeit_confirmed' then greatest(scheduled, played) else played end;
    difference := strength_a - strength_b + 100 * manpower;
    expected_a := fieldrush_rating_private.season_zero_sr_expected(difference);
    expected_b := 1 - expected_a;
  end if;

  for player in select value from jsonb_array_elements(data->'players') loop
    player_id := player->>'id';
    sr_before := (player->>'sr_before')::numeric::integer;
    games_before := (player->>'games_before')::numeric::integer;
    if not rated then
      results := results || jsonb_build_object(player_id, jsonb_build_object(
        'delta', 0, 'sr_after', sr_before, 'games_after', games_before, 'counted', false
      ) || fieldrush_rating_private.season_zero_sr_public_state(sr_before, games_before));
      continue;
    end if;

    actual_seconds := (player->>'actual_seconds')::numeric::integer;
    protected_seconds := (player->>'protected_seconds')::numeric::integer;
    reason := player->>'exit_reason';
    k := fieldrush_rating_private.season_zero_sr_k(games_before);
    actual_result := case when winner is null then 0.5 when winner = player->>'team' then 1 else 0 end;
    expected := case when player->>'team' = 'A' then expected_a else expected_b end;
    raw_delta := k * (actual_result - expected);
    q := protected_seconds::numeric / denominator;
    counted := actual_seconds >= 600;
    multiplier := 1;
    forgiven := 0;

    if actual_seconds = 0 then
      adjusted := 0;
      counted := false;
    elsif reason = 'QUIT' then
      adjusted := least(raw_delta, 0);
    elsif actual_seconds < 600 and reason in ('RED_CARD', 'BLUE_CARD') then
      adjusted := least(raw_delta, 0);
      counted := false;
    elsif actual_seconds < 600 then
      adjusted := 0;
      counted := false;
    else
      multiplier := case when actual_result = 0 then 1 - 0.85 * q else 1 end;
      -- Keep the exposure ratio as an exact fraction until the final division.
      -- Multiplying a rounded decimal q can turn an exact -17.5 tie into
      -- -17.49999... (e.g. 300 protected seconds out of 2040 at raw -20).
      adjusted := case when actual_result = 0
        then raw_delta * (denominator::numeric - 0.85 * protected_seconds) / denominator
        else raw_delta end;
      forgiven := case when actual_result = 0 then adjusted - raw_delta else 0 end;
    end if;

    delta := fieldrush_rating_private.season_zero_sr_round(adjusted);
    if sr_before::bigint + delta < -2147483648::bigint or sr_before::bigint + delta > 2147483647::bigint
        or (counted and games_before = 2147483647) then
      raise exception 'Rating result exceeds integer storage bounds' using errcode = '22023';
    end if;
    sr_after := sr_before + delta;
    games_after := games_before + counted::integer;
    results := results || jsonb_build_object(player_id, jsonb_build_object(
      'k', k, 'expected', expected, 'actual_result', actual_result,
      'q', q, 'loss_multiplier', multiplier, 'raw_delta', raw_delta,
      'raw_forgiveness', forgiven, 'adjusted_raw', adjusted,
      'delta', delta, 'sr_after', sr_after, 'games_after', games_after, 'counted', counted
    ) || fieldrush_rating_private.season_zero_sr_public_state(sr_after, games_after));
  end loop;

  return jsonb_build_object(
    'settlement', settlement, 'expected_a', expected_a, 'expected_b', expected_b,
    'effective_difference_a', difference, 'protection_denominator', denominator, 'players', results
  );
end;
$$;

revoke all on function
  fieldrush_rating_private.season_zero_sr_number(jsonb,text),
  fieldrush_rating_private.season_zero_sr_integer(jsonb,text,integer),
  fieldrush_rating_private.season_zero_sr_seed(text),
  fieldrush_rating_private.season_zero_sr_k(integer),
  fieldrush_rating_private.season_zero_sr_round(numeric),
  fieldrush_rating_private.season_zero_sr_public_state(integer,integer),
  fieldrush_rating_private.season_zero_sr_expected(numeric),
  fieldrush_rating_private.calculate_season_zero_sr(jsonb)
from public, anon, authenticated, service_role;
