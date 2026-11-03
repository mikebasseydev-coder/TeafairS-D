-- A6 §19.4 and §20, user decision 2026-11-03: the Monvelo limits scale tenfold
-- for real wholesale stock runs.
--
--   monvelo_open_exposure_ceiling()   100000.00  -> 1000000.00  (§19.4)
--   monvelo_allowance_ceiling()       300000.00  -> 3000000.00  (§20)
--
-- The ratio stays at 3x. Only the two constants change: every caller reads them
-- at run time (claim_monvelo_financing, monvelo_claim_refusal, the hold views,
-- decide_monvelo_hold, settle_monvelo_funding's late route), so no function
-- body is recreated. An agent's own daily_cap and per_financing_cap are
-- untouched and a market maker still cannot override them.
--
-- Rows already written keep their figures: monvelo_claim_holds.exposure_after
-- and within_limit (recorded once decided, R72) were judged under the old
-- limits and stay as history.
--
-- No grants, tables or RLS policies change.

create or replace function public.monvelo_open_exposure_ceiling()
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select 1000000.00::numeric(15,2);
$$;
revoke all on function public.monvelo_open_exposure_ceiling() from public, anon, authenticated, service_role;
comment on function public.monvelo_open_exposure_ceiling() is
  'A6 §19: the most one agent may have open across Monvelo, in naira (₦1,000,000 from 2026-11-03). A migration changes it.';

create or replace function public.monvelo_allowance_ceiling()
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select 3000000.00::numeric(15,2);
$$;
revoke all on function public.monvelo_allowance_ceiling() from public, anon, authenticated, service_role;
comment on function public.monvelo_allowance_ceiling() is
  'A6 §20: the most a market maker may allow one agent to have open across Monvelo, in naira (₦3,000,000 from 2026-11-03). A migration changes it.';
