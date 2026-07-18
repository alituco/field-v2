-- Local-only seed entry point.
--
-- Keep this file safe to run after every `supabase db reset`. Reproducible
-- Field test scenarios are populated by the dedicated scripts in
-- `supabase/scripts/` once the schema has been rebuilt successfully.
--
-- Historical fake fixtures predate the first real policy publication. Give
-- local Docker a policy snapshot that covers those fixtures without changing
-- either hosted project. Version 1 remains the effective policy for current
-- matches because it has the later effective date.
insert into public.reliability_policy_versions (
  version,
  state,
  schema_version,
  effective_from,
  config,
  summary,
  published_at
)
select
  2,
  'PUBLISHED',
  baseline.schema_version,
  '2026-01-01 00:00:00 Asia/Bahrain'::timestamptz,
  baseline.config,
  'Local-only historical fixture policy',
  clock_timestamp()
from public.reliability_policy_versions baseline
where baseline.version = 1
  and not exists (
    select 1
    from public.reliability_policy_versions existing
    where existing.version = 2
  );
