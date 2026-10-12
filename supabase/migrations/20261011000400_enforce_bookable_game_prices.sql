-- New USD prices must be bookable by Stripe. Do not reprice existing games,
-- payments or schedule templates: historical low-price rows can still undergo
-- operational updates, and admins can pause those schedules before correcting
-- their prospective price. New generation from such a rule records a retryable
-- occurrence conflict through the scheduler's existing exception handling.
create function public.enforce_bookable_solo_game_price()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'open_queue_games' then
    -- Legacy BHD fixtures keep their existing currency/price contract.
    if new.currency is distinct from 'USD'
      or new.format_version is distinct from 'FIELDRUSH_7V7' then
      return new;
    end if;
  end if;
  if tg_op = 'UPDATE' and new.price_fils is not distinct from old.price_fils then
    return new;
  end if;
  if new.price_fils is null or new.price_fils not between 0 and 100000
    or new.price_fils % 10 <> 0 or new.price_fils between 1 and 499 then
    raise exception 'Price must be free or between 0.50 and 100 USD, in whole cents.';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_bookable_solo_game_price() from public, anon, authenticated, service_role;

-- Trigger enforcement covers every server-owned create path, including older
-- one-off RPC overloads and recurring generation, without a CHECK constraint
-- that would prevent cancelling or otherwise updating a historical cheap game.
create trigger enforce_bookable_open_queue_game_price
  before insert or update of price_fils on public.open_queue_games
  for each row execute function public.enforce_bookable_solo_game_price();
create trigger enforce_bookable_game_schedule_price
  before insert or update of price_fils on public.game_schedules
  for each row execute function public.enforce_bookable_solo_game_price();

notify pgrst, 'reload schema';
