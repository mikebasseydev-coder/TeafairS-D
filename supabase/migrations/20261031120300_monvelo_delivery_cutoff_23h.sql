-- Monvelo Step 3, Task 3b: the delivery cutoff is a rolling 23 hours after
-- funding (user decision 2026-11-01). It replaces A6 Q1 as written ("not
-- delivered by 23:59 Africa/Lagos on its funding day"): a financing FUNDED at T
-- can be dispatched, take a delivery code and be confirmed while
-- now() < T + 23 hours; at or after T + 23 hours all three are refused (and the
-- Task 5 money sweep moves it to REFUND_DUE). The calendar day no longer matters.
--
-- dispatch_monvelo_financing, start_monvelo_delivery and confirm_monvelo_delivery
-- all call this one helper (Task 4 did not redefine any of them), so only the
-- helper changes; signatures, grants and the three callers are untouched.

create or replace function public.monvelo_assert_delivery_day(p_fin public.monvelo_financings)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if now() >= p_fin.funded_at + interval '23 hours' then
    raise exception 'the 23-hour delivery window has passed; this financing is due a refund' using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.monvelo_assert_delivery_day(public.monvelo_financings) from public, anon, authenticated, service_role;
