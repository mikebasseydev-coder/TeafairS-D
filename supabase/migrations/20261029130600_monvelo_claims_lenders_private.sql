-- Final review (Monvelo Step 1c/2): tenants never see or steer lenders
-- (A6 §16.2.2; plan call 25). A claim names the agent behind it, so it is read
-- only by that agent's members and by Monvelo staff, never by the financing's
-- tenant-side readers (TENANT_ADMIN, CSM, ZSM, TM, the raiser, the owner).
drop policy monvelo_financing_claims_select on public.monvelo_financing_claims;
create policy monvelo_financing_claims_select on public.monvelo_financing_claims for select to authenticated
  using (
    agent_id in (select public.my_monvelo_agent_ids())
    or (select public.is_monvelo_staff()));
