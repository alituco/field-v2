-- Open Queue bookings are now finalized by the server after Tap confirms a
-- captured charge. Clients may preview a price, but they must not call the
-- underlying booking mutation directly or claim the legacy MOCK method.

revoke all on function public.book_open_queue_game(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function public.book_open_queue_game(uuid, text, text, text)
to service_role;

comment on function public.book_open_queue_game(uuid, text, text, text) is
'Creates an Open Queue booking after server-side payment verification. Callable only by the service role through payment finalization.';
