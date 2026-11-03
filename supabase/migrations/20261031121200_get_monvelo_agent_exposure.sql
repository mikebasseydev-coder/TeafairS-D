-- A6 §19.4, §20, §21.2; audit finding G1 (docs/reports, 2026-11-03).
-- The agent's exposure meter: one read-only RPC for the members of a Monvelo
-- agent (and Monvelo staff) that returns what the claim checks use, so the app
-- never computes a limit itself.
--
--   get_monvelo_agent_exposure(p_agent_id uuid default null)   authenticated
--   monvelo_agent_day_used(p_agent_id uuid)                    internal, ungranted
--
-- Callers. An ACTIVE member of the agent (my_monvelo_agent_ids()) or Monvelo
-- staff (is_monvelo_staff(): MONVELO_OPERATOR, MONVELO_FINANCE), who already
-- read every Monvelo table (A6 §8). Everyone else gets 42501, whether or not
-- the agent exists. Tenant roles (ZSM, ASA, ZSA, TM, CSM, TENANT_ADMIN) are
-- refused on purpose: a tenant never sees a lender (§16.2.2), and a market
-- maker never sees the agent's identity or figures (§20.2 decision 3, call 9).
--
-- p_agent_id is a monvelo_agents.id, not a profile id: an agent is a business
-- with members. Null means the caller's agent when the caller is an ACTIVE
-- member of exactly one; a member of several must name one (22023); a caller
-- who is a member of none gets 42501.
--
-- The figures come from the same functions the claim uses:
--   open_exposure     monvelo_agent_open_exposure() (A6 §19.4.1, §20): CLAIMED,
--                     HELD and FUNDED at principal; DELIVERED and
--                     DEFAULTED_WITH_LATE_CHARGE at least(outstanding,
--                     principal); REFUND_DUE counts nothing (R63)
--   platform_ceiling  monvelo_open_exposure_ceiling()  (₦1,000,000, §21)
--   allowance_ceiling monvelo_allowance_ceiling()      (₦3,000,000, §21)
--   personal limits   monvelo_agents.daily_cap and per_financing_cap; both
--                     default to 0 until Monvelo staff set them (§21.2), and
--                     no market maker can lift them (§20.2 decision 7)
--   today_utilized    monvelo_agent_day_used(): check 8 of
--                     monvelo_claim_refusal (20261031120800), for no request in
--                     particular: CLAIMED now, HELD now, and funded on this
--                     Lagos day unless REFUND_DUE
--
-- No table, grant on a table, or RLS policy changes.

-- ── what the agent has used of its daily cap today ──────────────────────
-- Keep in step with check 8 of monvelo_claim_refusal (20261031120800); 067
-- pins the definition.
create or replace function public.monvelo_agent_day_used(p_agent_id uuid)
returns numeric(15,2)
language sql
stable
set search_path = public, pg_temp
as $$
  select (
      coalesce((select sum(f.principal) from public.monvelo_financings f
                 where f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent_id), 0)
    + coalesce((select sum(f.principal) from public.monvelo_financings f
                 where f.funder_agent_id = p_agent_id
                   and (f.funded_at at time zone 'Africa/Lagos')::date = public.monvelo_today()
                   and f.status <> 'REFUND_DUE'), 0)
    + coalesce((select sum(f.principal) from public.monvelo_financings f
                  join public.monvelo_claim_holds h on h.financing_id = f.id and h.status = 'HELD'
                 where f.status = 'HELD' and h.agent_id = p_agent_id), 0)
  )::numeric(15,2);
$$;
revoke all on function public.monvelo_agent_day_used(uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_agent_day_used(uuid) is
  'A6 §19, §20: what the agent has used of its daily cap on this Lagos day: CLAIMED and HELD now, plus funded today unless REFUND_DUE (R63). Mirrors check 8 of monvelo_claim_refusal.';

-- ── the RPC ─────────────────────────────────────────────────────────────
create or replace function public.get_monvelo_agent_exposure(p_agent_id uuid default null)
returns table (
  agent_id                 uuid,
  agent_status             text,
  open_exposure            numeric(15,2),
  platform_ceiling         numeric(15,2),
  allowance_ceiling        numeric(15,2),
  remaining_room           numeric(15,2),
  active_commitments_count bigint,
  personal_daily_limit     numeric(15,2),
  per_financing_limit      numeric(15,2),
  today_utilized_limit     numeric(15,2),
  today_remaining_limit    numeric(15,2)
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_staff   boolean := public.is_monvelo_staff();
  v_agent   uuid    := p_agent_id;
  v_mine    uuid[];
  v_row     public.monvelo_agents;
  v_open    numeric(15,2);
  v_ceiling numeric(15,2) := public.monvelo_open_exposure_ceiling();
  v_used    numeric(15,2);
begin
  if (select auth.uid()) is null then
    raise exception 'Unauthorized access to agent exposure metrics' using errcode = '42501';
  end if;

  select coalesce(array_agg(a), '{}') into v_mine from public.my_monvelo_agent_ids() a;

  if v_agent is null then
    if cardinality(v_mine) = 1 then
      v_agent := v_mine[1];
    elsif cardinality(v_mine) > 1 then
      raise exception 'you belong to more than one Monvelo agent: name the agent' using errcode = '22023';
    else
      raise exception 'Unauthorized access to agent exposure metrics' using errcode = '42501';
    end if;
  end if;

  if not (v_staff or v_agent = any (v_mine)) then
    raise exception 'Unauthorized access to agent exposure metrics' using errcode = '42501';
  end if;

  select * into v_row from public.monvelo_agents a where a.id = v_agent;
  if v_row.id is null then
    return;  -- only staff reach this: a member's agent always exists
  end if;

  v_open := public.monvelo_agent_open_exposure(v_row.id);
  v_used := public.monvelo_agent_day_used(v_row.id);

  return query
  select v_row.id,
         v_row.status,
         v_open,
         v_ceiling,
         public.monvelo_allowance_ceiling(),
         greatest(v_ceiling - v_open, 0)::numeric(15,2),
         (select count(*) from public.monvelo_financings f
           where (f.status = 'CLAIMED' and f.claimed_by_agent_id = v_row.id)
              or (f.funder_agent_id = v_row.id
                  and f.status in ('FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE'))
              or (f.status = 'HELD'
                  and exists (select 1 from public.monvelo_claim_holds h
                               where h.financing_id = f.id and h.status = 'HELD' and h.agent_id = v_row.id))),
         v_row.daily_cap,
         v_row.per_financing_cap,
         v_used,
         greatest(v_row.daily_cap - v_used, 0)::numeric(15,2);
end;
$$;
revoke all on function public.get_monvelo_agent_exposure(uuid) from public, anon, service_role;
grant execute on function public.get_monvelo_agent_exposure(uuid) to authenticated;
comment on function public.get_monvelo_agent_exposure(uuid) is
  'A6 §19.4, §20, §21.2 (finding G1): the agent''s open exposure against the platform and allowance ceilings, and today''s use of its own daily cap. ACTIVE members of the agent and Monvelo staff only; anyone else 42501. Null names the caller''s only agent.';
