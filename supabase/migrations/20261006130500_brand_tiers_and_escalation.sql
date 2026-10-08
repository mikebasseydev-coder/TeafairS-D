-- Spec A §5.4 (decision 18) and §7.4 (decision 19).

-- ── brand-tier requisition evaluation ───────────────────────────────────
-- The required approval level for a set of SKUs: the highest tier among their
-- brands' policies (DSM < ASM < TM < ZSM); a brand with no policy clears at
-- DSM. Cash value plays no part. One definition, used by submit_requisition
-- and any later re-check. Internal: not callable from the API.
create or replace function public.requisition_required_level(p_tenant_id uuid, p_sku_codes text[])
returns public.tenant_role_enum
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_missing text;
  v_level   public.tenant_role_enum;
begin
  if p_sku_codes is null or cardinality(p_sku_codes) = 0 then
    raise exception 'a requisition needs at least one SKU' using errcode = 'P0001';
  end if;

  select s into v_missing
  from unnest(p_sku_codes) as s
  where not exists (
    select 1 from public.central_products cp
    where cp.tenant_id = p_tenant_id and cp.sku_code = s
  )
  limit 1;
  if v_missing is not null then
    raise exception 'unknown SKU %', v_missing using errcode = 'P0001';
  end if;

  select lvl into v_level
  from (
    select coalesce(bap.required_approval_level, 'DSM'::public.tenant_role_enum) as lvl
    from public.central_products cp
    left join public.brand_approval_policies bap
      on bap.tenant_id = cp.tenant_id and lower(bap.brand) = lower(cp.brand)
    where cp.tenant_id = p_tenant_id
      and cp.sku_code = any (p_sku_codes)
  ) levels
  order by public.approval_rank(lvl) desc
  limit 1;

  return v_level;
end;
$$;

-- ── 24-hour pickup escalation ───────────────────────────────────────────
-- Flags every pickup still PENDING_CONFIRMATION 24 hours after it landed
-- (server created_at) and not yet escalated, notifies the supervising DSM,
-- and audits it as CRON against the accountable DSA. Status is unchanged:
-- the shop owner can still confirm or dispute.
--
-- Recipient: the pickup's dsm_supervisor_id; else the DSA's reports_to when
-- that member is an ACTIVE DSM; else the TM of the DSA's territory.
-- SKIP LOCKED lets an overlapping run (or a concurrent confirmation) proceed
-- without blocking; escalated_at guarantees each pickup escalates once.
create or replace function public.escalate_stale_pickups()
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r           public.retail_stock_pickups;
  v_recipient uuid;
  v_count     integer := 0;
begin
  for r in
    select * from public.retail_stock_pickups p
    where p.status = 'PENDING_CONFIRMATION'
      and p.escalated_at is null
      and p.created_at < now() - interval '24 hours'
    order by p.created_at
    for update skip locked
  loop
    v_recipient := coalesce(
      r.dsm_supervisor_id,
      (select mgr.profile_id
         from public.tenant_users dsa
         join public.tenant_users mgr on mgr.tenant_id = dsa.tenant_id and mgr.id = dsa.reports_to_id
        where dsa.tenant_id = r.tenant_id and dsa.profile_id = r.dsa_agent_id
          and mgr.role = 'DSM' and mgr.status = 'ACTIVE'),
      (select t.tm_id
         from public.tenant_users dsa
         join public.territories t on t.tenant_id = dsa.tenant_id and t.id = dsa.territory_id
        where dsa.tenant_id = r.tenant_id and dsa.profile_id = r.dsa_agent_id)
    );

    update public.retail_stock_pickups set escalated_at = now() where id = r.id;

    if v_recipient is not null then
      insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
      values (r.tenant_id, v_recipient, 'PICKUP_ESCALATED',
              'Pickup unconfirmed for 24 hours',
              'A stock pickup is still awaiting shop-owner confirmation and needs your attention.',
              jsonb_build_object('pickup_id', r.id, 'retail_shop_id', r.retail_shop_id,
                                 'dsa_agent_id', r.dsa_agent_id, 'logged_at', r.created_at));
    end if;

    perform public.write_audit(
      r.tenant_id, 'escalate_pickup', 'retail_stock_pickups', r.id::text,
      jsonb_build_object('escalated_at', null),
      jsonb_build_object('escalated_at', now(), 'notified', v_recipient),
      null, 'CRON', r.dsa_agent_id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Every 15 minutes: an escalation fires between 24h and 24h15m after landing.
-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule(
  'escalate-stale-pickups',
  '*/15 * * * *',
  $$select public.escalate_stale_pickups()$$
);
