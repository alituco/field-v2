-- Keep the concurrency/capacity mutation available to authenticated callers
-- only through a wrapper that rejects the legacy MOCK method. The server
-- implementation still performs the captured-intent lookup for every real
-- payment method.

alter function public.book_open_queue_game(uuid, text, text, text)
rename to book_open_queue_game_server;

revoke all on function
  public.book_open_queue_game_server(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.book_open_queue_game_server(uuid, text, text, text)
to service_role;

create function public.book_open_queue_game(
  game_id_to_book uuid,
  role_to_book text,
  payment_method_to_use text,
  payment_reference_to_use text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if upper(trim(coalesce(payment_method_to_use, ''))) = 'MOCK' then
    raise exception 'Mock payments cannot create a booking.';
  end if;

  return public.book_open_queue_game_server(
    game_id_to_book,
    role_to_book,
    payment_method_to_use,
    payment_reference_to_use
  );
end;
$$;

revoke all on function public.book_open_queue_game(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function public.book_open_queue_game(uuid, text, text, text)
to authenticated, service_role;

comment on function public.book_open_queue_game(uuid, text, text, text) is
'Validates a server-captured payment and atomically creates an Open Queue booking. Legacy mock payments are rejected.';
comment on function
  public.book_open_queue_game_server(uuid, text, text, text) is
'Internal authoritative Open Queue booking mutation. Direct access is restricted to the service role.';
