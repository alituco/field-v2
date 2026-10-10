-- Fixture browsing includes the immutable public currency and team price.
-- Keep the column allowlist: table-wide SELECT would expose private clan
-- reliability deposits, payment history and refund details.
grant select (currency, base_price_fils)
  on table public.fixtures to authenticated;

notify pgrst, 'reload schema';
