-- Addendum A8 §5.5, §5.6, §6.3, §6.4 (plan Task 5): loss claims and CLOSED_BY_CLAIM.
--
--   report_monvelo_loss              a field agent (STORAGE) or the tenant's LM/CSM (GIT), or an operator
--   file_monvelo_insurance_claim     operator; waits for an accepted declaration; CLAIM_FILE
--   set_monvelo_claim_status         operator; FILED -> UNDER_REVIEW, open -> REJECTED
--   monvelo_settle_claim             internal: the one settlement (closes, waives, flags)
--   settle_monvelo_insurance_claim   service_role: the insurer's webhook (Task 8)
--   record_monvelo_claim_settlement  operator: MANUAL insurers and shops' own policies
--
-- Recreated (newest bodies, signatures and grants kept):
--   monvelo_apply_late_charge (20261031120200)   no charge while a STORAGE claim is open
--   monvelo_sweep_money (20261031120700)         step 2 skips those financings
--   confirm_monvelo_repayment (20261031120200)   a full repayment withdraws the open STORAGE claim
--   get_lender_reconciliation_summary (20261031120700)
--                                                appends closed_by_claim_amount and late_charge_waived
--                                                (the return type changes, so it is dropped and recreated)
-- monvelo_agent_open_exposure already counts only open statuses: CLOSED_BY_CLAIM
-- frees the agent's exposure with no change (tested in 076).
--
-- STORAGE claims name the lender (the payee): their audit rows and notices are
-- tenant-null (§16.2.2). GIT claims are the tenant's.

-- ── internal helpers ────────────────────────────────────────────────────
-- an open STORAGE claim on the financing (it pauses the late charge, §6.4)
create or replace function public.monvelo_has_open_storage_claim(p_financing_id uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.monvelo_insurance_claims c
                  where c.financing_id = p_financing_id and c.kind = 'STORAGE'
                    and c.status in ('REPORTED', 'FILED', 'UNDER_REVIEW'));
$$;
revoke all on function public.monvelo_has_open_storage_claim(uuid) from public, anon, authenticated, service_role;

-- who hears of a claim's progress: a STORAGE claim's agent (tenant-null rows,
-- §16.2.2), a GIT claim's CSM and LOGISTICS_MANAGER (the tenant's own cover)
create or replace function public.monvelo_notify_claim(p_claim public.monvelo_insurance_claims)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_title text := 'Insurance claim ' || p_claim.reference;
  v_body  text := 'Claim ' || p_claim.reference || ' is now ' || p_claim.status || '.';
  v_load  jsonb := jsonb_build_object('claim_id', p_claim.id, 'reference', p_claim.reference, 'kind', p_claim.kind,
                                      'financing_id', p_claim.financing_id, 'status', p_claim.status);
begin
  if p_claim.kind = 'STORAGE' then
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    select null, m.profile_id, 'MONVELO_CLAIM_UPDATE', v_title, v_body, v_load
      from public.monvelo_agent_members m
     where m.agent_id = p_claim.payee_agent_id and m.status = 'ACTIVE';
  else
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    select p_claim.tenant_id, tu.profile_id, 'MONVELO_CLAIM_UPDATE', v_title, v_body, v_load
      from public.tenant_users tu
     where tu.tenant_id = p_claim.tenant_id and tu.status = 'ACTIVE'
       and tu.role in ('CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER');
  end if;
end;
$$;
revoke all on function public.monvelo_notify_claim(public.monvelo_insurance_claims)
  from public, anon, authenticated, service_role;

-- ── the late charge waits for an open STORAGE claim ─────────────────────
-- Recreated from 20261031120200. A8 §6.4: while a STORAGE claim is open the
-- charge is not applied (the sweep also skips; the repayment path calls this).
-- A rejected or withdrawn claim lets the next call apply it as before.
create or replace function public.monvelo_apply_late_charge(p_fin public.monvelo_financings)
returns public.monvelo_financings
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_fin    public.monvelo_financings;
  v_charge numeric(15,2);
begin
  select * into v_fin from public.monvelo_financings where id = p_fin.id for update;
  if v_fin.id is null or v_fin.status <> 'DELIVERED' or public.monvelo_has_open_storage_claim(v_fin.id) then
    return v_fin;
  end if;

  select coalesce(sum(round(v_fin.outstanding * l.amount / v_fin.principal * l.late_charge_bps / 10000.0, 2)), 0)
    into v_charge
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  update public.monvelo_financings
     set late_charge_amount = v_charge, outstanding = outstanding + v_charge,
         status = 'DEFAULTED_WITH_LATE_CHARGE'
   where id = v_fin.id
  returning * into v_fin;

  -- the rule, not a person: no actor, so the row names no lender
  perform public.write_audit(v_fin.tenant_id, 'monvelo_apply_late_charge', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'DELIVERED', 'outstanding', v_fin.outstanding - v_charge, 'late_charge_amount', 0),
    jsonb_build_object('status', v_fin.status, 'outstanding', v_fin.outstanding, 'late_charge_amount', v_charge,
                       'due_at', v_fin.due_at),
    null, 'SYSTEM', v_fin.raised_by);
  return v_fin;
end;
$$;
revoke all on function public.monvelo_apply_late_charge(public.monvelo_financings)
  from public, anon, authenticated, service_role;

-- ── report_monvelo_loss ─────────────────────────────────────────────────
-- STORAGE: an ACTIVE ZSA or ASA covering the financing's area, or an operator;
-- the financing DELIVERED or DEFAULTED_WITH_LATE_CHARGE; the incident after
-- delivery and before due_at; a cover (AUTO_POLICY or SHOP_POLICY) the insurer
-- has not rejected. It claims the unpaid principal; the late charge is not
-- insured. GIT: the tenant's LOGISTICS_MANAGER or CSM, or an operator; the
-- financing FUNDED or REFUND_DUE with a GIT cover; the incident after dispatch.
-- It claims the insured value, for the tenant.
create or replace function public.report_monvelo_loss(p_idempotency_key uuid, p_financing_id uuid, p_kind text,
  p_peril text, p_incident_at timestamptz, p_description text, p_evidence_paths text[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_op      boolean := public.is_monvelo_operator();
  v_me      public.tenant_users;
  v_prior   jsonb;
  v_fin     public.monvelo_financings;
  v_cover   public.monvelo_financing_cover;
  v_git     public.monvelo_order_git_cover;
  v_paths   text[] := coalesce(p_evidence_paths, array[]::text[]);
  v_desc    text := nullif(btrim(coalesce(p_description, '')), '');
  v_insurer uuid;
  v_amount  numeric(15,2);
  v_claim   public.monvelo_insurance_claims;
  v_p       text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not v_op then
    v_me := public.assert_tenant_role(array['ZSA', 'ASA', 'LOGISTICS_MANAGER', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'report_monvelo_loss',
    jsonb_build_object('financing_id', p_financing_id, 'kind', p_kind, 'peril', p_peril, 'incident_at', p_incident_at,
                       'description', v_desc, 'evidence_paths', to_jsonb(v_paths)));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_kind is null or p_kind not in ('GIT', 'STORAGE') then
    raise exception 'a loss is GIT or STORAGE' using errcode = 'P0001';
  end if;
  -- the financing row lock serialises this with repayments and settlements
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;
  if v_fin.id is null and v_op then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;
  if not v_op then
    if v_fin.id is null or v_fin.tenant_id <> v_me.tenant_id
       or (p_kind = 'STORAGE' and not (v_me.role in ('ZSA', 'ASA') and public.monvelo_covers_area(v_me, v_fin.area_id)))
       or (p_kind = 'GIT' and v_me.role not in ('LOGISTICS_MANAGER', 'CLIENT_SERVICE_MANAGER')) then
      raise exception 'not permitted to report a % loss on this financing', p_kind using errcode = '42501';
    end if;
  end if;

  if p_peril is null or p_peril not in ('FIRE', 'SPECIAL_PERILS', 'BURGLARY', 'THEFT_IN_TRANSIT', 'ACCIDENT_IN_TRANSIT', 'OTHER') then
    raise exception 'unknown peril' using errcode = 'P0001';
  end if;
  if p_incident_at is null or p_incident_at > now() then
    raise exception 'the incident time must be in the past' using errcode = 'P0001';
  end if;
  if length(v_desc) > 2000 then
    raise exception 'the description must be at most 2000 characters' using errcode = 'P0001';
  end if;
  if cardinality(v_paths) > 10 then
    raise exception 'at most 10 evidence files' using errcode = 'P0001';
  end if;
  foreach v_p in array v_paths loop
    if v_p is null or v_p not like v_fin.id::text || '/_%' or v_p like '%..%' or length(v_p) > 300 then
      raise exception 'evidence must be uploaded under this financing''s folder' using errcode = 'P0001';
    end if;
  end loop;

  if p_kind = 'STORAGE' then
    if v_fin.status not in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
      raise exception 'a stock loss is reported on a delivered financing' using errcode = 'P0001';
    end if;
    if p_incident_at <= v_fin.delivered_at or p_incident_at >= v_fin.due_at then
      raise exception 'the incident must fall after delivery and before the due date' using errcode = 'P0001';
    end if;
    select * into v_cover from public.monvelo_financing_cover where financing_id = v_fin.id;
    if v_cover.cover_kind is null or v_cover.cover_kind = 'NONE' then
      raise exception 'this financing has no storage cover' using errcode = 'P0001';
    end if;
    if v_cover.declared_status = 'REJECTED' then
      raise exception 'the insurer rejected this financing''s storage cover' using errcode = 'P0001';
    end if;
    if v_cover.cover_kind = 'AUTO_POLICY' then
      select p.insurer_id into v_insurer from public.monvelo_insurance_products p where p.id = v_cover.product_id;
    end if;
    -- repayments go to principal first (A6): the unpaid principal is what is lost
    v_amount := greatest(v_fin.principal - coalesce((select sum(r.amount) from public.monvelo_repayments r
                                                      where r.tenant_id = v_fin.tenant_id and r.financing_id = v_fin.id
                                                        and r.status = 'CONFIRMED'), 0), 0);
  else
    select * into v_git from public.monvelo_order_git_cover where financing_id = v_fin.id;
    if v_git.order_id is null then
      raise exception 'this order has no transit cover' using errcode = 'P0001';
    end if;
    if v_fin.status not in ('FUNDED', 'REFUND_DUE') then
      raise exception 'a transit loss is reported before delivery' using errcode = 'P0001';
    end if;
    if p_incident_at < v_git.created_at then
      raise exception 'the incident must fall after dispatch' using errcode = 'P0001';
    end if;
    if v_git.declared_status = 'REJECTED' then
      raise exception 'the insurer rejected this order''s transit cover' using errcode = 'P0001';
    end if;
    select p.insurer_id into v_insurer from public.monvelo_insurance_products p where p.id = v_git.product_id;
    v_amount := v_git.insured_value;
  end if;
  if v_amount <= 0 then
    raise exception 'nothing is left to claim on this financing' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.monvelo_insurance_claims c
              where c.financing_id = v_fin.id and c.kind = p_kind and c.status in ('REPORTED', 'FILED', 'UNDER_REVIEW')) then
    raise exception 'this financing already has an open % claim', p_kind using errcode = 'P0001';
  end if;

  insert into public.monvelo_insurance_claims (reference, tenant_id, kind, financing_id, insurer_id, peril, incident_at,
    description, evidence_paths, reported_by, payee_kind, payee_agent_id, claimed_amount)
  values ('IC-' || substr(public.monvelo_draw_reference(), 4), v_fin.tenant_id, p_kind, v_fin.id, v_insurer, p_peril,
          p_incident_at, v_desc, v_paths, v_uid,
          case p_kind when 'STORAGE' then 'AGENT' else 'TENANT' end,
          case p_kind when 'STORAGE' then v_fin.funder_agent_id end, v_amount)
  returning * into v_claim;

  -- a STORAGE claim names the lender (payee): tenant-null (§16.2.2)
  perform public.write_audit(case p_kind when 'GIT' then v_fin.tenant_id end, 'report_monvelo_loss',
                             'monvelo_insurance_claims', v_claim.id::text, null,
                             to_jsonb(v_claim) - 'description', p_idempotency_key);
  perform public.monvelo_notify_claim(v_claim);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('claim_id', v_claim.id, 'reference', v_claim.reference, 'status', v_claim.status));
end;
$$;
revoke all on function public.report_monvelo_loss(uuid, uuid, text, text, timestamptz, text, text[]) from public, anon, service_role;
grant execute on function public.report_monvelo_loss(uuid, uuid, text, text, timestamptz, text, text[]) to authenticated;

-- ── file_monvelo_insurance_claim ────────────────────────────────────────
-- An auto-policy or GIT claim is filed only once the insurer accepted the
-- declaration (§6.4: cover attaches at delivery, the claim waits for it) and
-- goes out as a CLAIM_FILE declaration. A shop-policy claim is filed by hand
-- with the shop's insurer: no declaration.
create or replace function public.file_monvelo_insurance_claim(p_idempotency_key uuid, p_claim_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_claim  public.monvelo_insurance_claims;
  v_fin    public.monvelo_financings;
  v_policy text;
  v_status text;
  v_agent  public.monvelo_agents;
  v_payee  jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'file_monvelo_insurance_claim',
    jsonb_build_object('claim_id', p_claim_id));
  if v_prior is not null then
    return v_prior;
  end if;
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id for update;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  if v_claim.status <> 'REPORTED' then
    raise exception 'only a REPORTED claim can be filed' using errcode = 'P0001';
  end if;
  select * into v_fin from public.monvelo_financings where id = v_claim.financing_id;

  if v_claim.kind = 'STORAGE' then
    select c.cover_kind, c.declared_status into v_policy, v_status
      from public.monvelo_financing_cover c where c.financing_id = v_claim.financing_id;
  else
    select 'GIT', g.declared_status into v_policy, v_status
      from public.monvelo_order_git_cover g where g.financing_id = v_claim.financing_id;
  end if;

  if v_policy in ('AUTO_POLICY', 'GIT') then
    if v_status is distinct from 'ACCEPTED' then
      raise exception 'the insurer has not accepted this cover''s declaration yet' using errcode = 'P0001';
    end if;
    if v_claim.payee_kind = 'AGENT' then
      select * into v_agent from public.monvelo_agents where id = v_claim.payee_agent_id;
      v_payee := jsonb_build_object('kind', 'AGENT', 'settlement_account_number', v_agent.settlement_account_number,
                                    'settlement_bank_code', v_agent.settlement_bank_code);
    else
      v_payee := jsonb_build_object('kind', 'TENANT');
    end if;
    perform public.monvelo_enqueue_declaration(v_claim.tenant_id, 'CLAIM_FILE', v_claim.insurer_id,
      'monvelo_insurance_claims', v_claim.id,
      jsonb_build_object('claim_reference', v_claim.reference, 'policy_kind', v_claim.kind,
                         'financing_reference', v_fin.reference, 'peril', v_claim.peril,
                         'incident_at', v_claim.incident_at, 'claimed_amount', v_claim.claimed_amount,
                         'payee', v_payee));
  end if;

  update public.monvelo_insurance_claims set status = 'FILED', filed_by = v_uid, filed_at = now()
   where id = v_claim.id returning * into v_claim;
  perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'file_monvelo_insurance_claim',
                             'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', 'REPORTED'),
                             jsonb_build_object('status', 'FILED', 'policy_kind', v_policy,
                                                'declared', v_policy in ('AUTO_POLICY', 'GIT')),
                             p_idempotency_key);
  perform public.monvelo_notify_claim(v_claim);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('claim_id', v_claim.id, 'reference', v_claim.reference, 'status', 'FILED'));
end;
$$;
revoke all on function public.file_monvelo_insurance_claim(uuid, uuid) from public, anon, service_role;
grant execute on function public.file_monvelo_insurance_claim(uuid, uuid) to authenticated;

-- ── set_monvelo_claim_status: FILED -> UNDER_REVIEW, open -> REJECTED ────
create or replace function public.set_monvelo_claim_status(p_idempotency_key uuid, p_claim_id uuid, p_status text,
                                                           p_insurer_claim_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_ref    text := nullif(btrim(coalesce(p_insurer_claim_reference, '')), '');
  v_before public.monvelo_insurance_claims;
  v_claim  public.monvelo_insurance_claims;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_claim_status',
    jsonb_build_object('claim_id', p_claim_id, 'status', p_status, 'insurer_claim_reference', v_ref));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('UNDER_REVIEW', 'REJECTED') then
    raise exception 'a claim is set UNDER_REVIEW or REJECTED' using errcode = 'P0001';
  end if;
  if length(v_ref) > 128 then
    raise exception 'the insurer''s claim reference must be at most 128 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_insurance_claims where id = p_claim_id for update;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  if not ((v_before.status = 'FILED' and p_status in ('UNDER_REVIEW', 'REJECTED'))
          or (v_before.status = 'UNDER_REVIEW' and p_status = 'REJECTED')) then
    raise exception 'a % claim cannot become %', v_before.status, p_status using errcode = 'P0001';
  end if;
  update public.monvelo_insurance_claims
     set status = p_status, insurer_claim_reference = coalesce(v_ref, insurer_claim_reference)
   where id = p_claim_id returning * into v_claim;
  perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'set_monvelo_claim_status',
                             'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', v_before.status),
                             jsonb_build_object('status', v_claim.status,
                                                'insurer_claim_reference', v_claim.insurer_claim_reference),
                             p_idempotency_key);
  perform public.monvelo_notify_claim(v_claim);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status));
end;
$$;
revoke all on function public.set_monvelo_claim_status(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.set_monvelo_claim_status(uuid, uuid, text, text) to authenticated;

-- ── monvelo_settle_claim: the one settlement, for both entry points ─────
-- A STORAGE settlement closes a DELIVERED or DEFAULTED financing
-- CLOSED_BY_CLAIM whatever the amount (§6.4, "extinguishing the loan"),
-- waives its late charge, and flags any shortfall (the agent bears it). A
-- settlement on a claim that is no longer open (withdrawn by a full
-- repayment, rejected, settled) changes nothing and is flagged. Locks: the
-- financing, then the claim (the repayment's order).
create or replace function public.monvelo_settle_claim(p_claim_id uuid, p_settled_amount numeric,
                                                       p_payout_reference text, p_actor uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ref    text := nullif(btrim(coalesce(p_payout_reference, '')), '');
  v_src    public.audit_source_enum := case when p_actor is null then 'WEBHOOK' else 'USER' end;
  v_claim  public.monvelo_insurance_claims;
  v_fin    public.monvelo_financings;
  v_closed boolean := false;
  v_waived numeric(15,2);
  v_flag   uuid;
begin
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  if p_settled_amount is null or p_settled_amount < 0 or p_settled_amount <> round(p_settled_amount, 2) then
    raise exception 'the settled amount must be zero or more, with at most 2 decimals' using errcode = 'P0001';
  end if;
  if v_ref is null or length(v_ref) > 128 then
    raise exception 'the payout reference is 1 to 128 characters' using errcode = 'P0001';
  end if;
  select * into v_fin from public.monvelo_financings where id = v_claim.financing_id for update;
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id for update;

  if v_claim.status not in ('FILED', 'UNDER_REVIEW') then
    v_flag := public.monvelo_raise_flag('CLAIM_SETTLED_AFTER_CLOSE', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'claim_status', v_claim.status,
                         'settled_amount', p_settled_amount, 'payout_reference', v_ref));
    perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'monvelo_settle_claim',
                               'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', v_claim.status),
                               jsonb_build_object('status', v_claim.status, 'ignored', true, 'flag_id', v_flag,
                                                  'settled_amount', p_settled_amount),
                               null, v_src);
    return jsonb_build_object('claim_id', v_claim.id, 'ignored', true, 'status', v_claim.status);
  end if;
  if p_settled_amount > v_claim.claimed_amount then
    raise exception 'the settlement is more than was claimed' using errcode = 'P0001';
  end if;

  if v_claim.kind = 'STORAGE' and v_fin.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    v_waived := v_fin.late_charge_amount;
    update public.monvelo_financings
       set status = 'CLOSED_BY_CLAIM', outstanding = 0, closed_at = now()
     where id = v_fin.id;
    v_closed := true;
  end if;
  update public.monvelo_insurance_claims
     set status = 'SETTLED', settled_amount = p_settled_amount, settled_at = now(), payout_reference = v_ref,
         late_charge_waived = v_waived
   where id = v_claim.id returning * into v_claim;

  if v_claim.kind = 'STORAGE' and v_claim.shortfall > 0 then
    v_flag := public.monvelo_raise_flag('CLAIM_SHORTFALL', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'claimed_amount', v_claim.claimed_amount,
                         'settled_amount', v_claim.settled_amount, 'shortfall', v_claim.shortfall));
  end if;

  -- a STORAGE settlement names the lender's money: tenant-null, the financing's row too
  perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'monvelo_settle_claim',
                             'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', 'FILED'),
                             jsonb_build_object('status', 'SETTLED', 'settled_amount', v_claim.settled_amount,
                                                'shortfall', v_claim.shortfall, 'payout_reference', v_ref,
                                                'late_charge_waived', v_waived, 'flag_id', v_flag),
                             null, v_src);
  if v_closed then
    perform public.write_audit(null, 'monvelo_settle_claim', 'monvelo_financings', v_fin.id::text,
                               jsonb_build_object('status', v_fin.status, 'outstanding', v_fin.outstanding),
                               jsonb_build_object('status', 'CLOSED_BY_CLAIM', 'outstanding', 0, 'claim_id', v_claim.id,
                                                  'late_charge_waived', v_waived),
                               null, v_src);
  end if;
  perform public.monvelo_notify_claim(v_claim);
  return jsonb_build_object('claim_id', v_claim.id, 'status', 'SETTLED', 'settled_amount', v_claim.settled_amount,
                            'shortfall', v_claim.shortfall,
                            'financing_status', case when v_closed then 'CLOSED_BY_CLAIM' else v_fin.status end);
end;
$$;
revoke all on function public.monvelo_settle_claim(uuid, numeric, text, uuid) from public, anon, authenticated, service_role;

-- the insurer's webhook (Task 8), after its HMAC: service_role only
create or replace function public.settle_monvelo_insurance_claim(p_insurer_code text, p_claim_reference text,
                                                                 p_settled_amount numeric, p_payout_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claim_id uuid;
begin
  select c.id into v_claim_id
    from public.monvelo_insurance_claims c
    join public.monvelo_insurers i on i.id = c.insurer_id
   where i.code = p_insurer_code and c.reference = p_claim_reference;
  if v_claim_id is null then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  return public.monvelo_settle_claim(v_claim_id, p_settled_amount, p_payout_reference, null);
end;
$$;
revoke all on function public.settle_monvelo_insurance_claim(text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.settle_monvelo_insurance_claim(text, text, numeric, text) to service_role;

-- an operator records a settlement for a MANUAL insurer or a shop's own policy
create or replace function public.record_monvelo_claim_settlement(p_idempotency_key uuid, p_claim_id uuid,
                                                                  p_settled_amount numeric, p_payout_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_claim public.monvelo_insurance_claims;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_claim_settlement',
    jsonb_build_object('claim_id', p_claim_id, 'settled_amount', p_settled_amount,
                       'payout_reference', p_payout_reference));
  if v_prior is not null then
    return v_prior;
  end if;
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  if v_claim.insurer_id is not null
     and (select i.api_provider from public.monvelo_insurers i where i.id = v_claim.insurer_id) <> 'MANUAL' then
    raise exception 'this insurer settles through its webhook' using errcode = 'P0001';
  end if;
  return public.idempotency_complete(p_idempotency_key,
    public.monvelo_settle_claim(p_claim_id, p_settled_amount, p_payout_reference, v_uid));
end;
$$;
revoke all on function public.record_monvelo_claim_settlement(uuid, uuid, numeric, text) from public, anon, service_role;
grant execute on function public.record_monvelo_claim_settlement(uuid, uuid, numeric, text) to authenticated;

-- ── the money sweep: step 2 waits for an open STORAGE claim ────────────
-- Recreated from 20261031120700; only step 2's filter changes.
create or replace function public.monvelo_sweep_money()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin      public.monvelo_financings;
  v_order    public.orders;
  v_rep      public.monvelo_repayments;
  v_payable  uuid;
  v_refunded boolean;
  v_rel      integer;
  v_tkt      uuid;
  v_flag     uuid;
  v_due      integer := 0;
  v_charged  integer := 0;
  v_expired  integer := 0;
  v_quiet    integer := 0;
  v_why      text;
  v_pledge   public.monvelo_pledges;
  v_restored public.monvelo_pledges;
begin
  -- 1. funded, not delivered within 23 hours: REFUND_DUE (R46: the same instant
  --    monvelo_assert_delivery_day starts refusing)
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'FUNDED' and now() >= public.monvelo_delivery_cutoff(f.funded_at)
     order by f.id
       for update skip locked
  loop
    select * into v_order from public.orders
     where tenant_id = v_fin.tenant_id and id = v_fin.order_id
       for update;
    -- staff may have refunded the funding already: then it is closed now
    v_refunded := exists (select 1 from public.payments p
                           where p.tenant_id = v_fin.tenant_id and p.monvelo_financing_id = v_fin.id
                             and p.paystack_reference = v_fin.paystack_reference and p.payment_status = 'REFUNDED');
    update public.monvelo_financings
       set status = 'REFUND_DUE', closed_at = case when v_refunded then now() end
     where id = v_fin.id;

    -- A6 §19.4 (R62): Paystack already confirmed the refund of this funding,
    -- so the agent's pledge has the principal back, as apply_monvelo_refund
    -- gives it when the refund lands after REFUND_DUE. Locks: financing, order,
    -- then pledge. Once: only while closed_at was null.
    if v_refunded and v_fin.closed_at is null and v_fin.pledge_id is not null then
      select * into v_pledge from public.monvelo_pledges
       where tenant_id = v_fin.tenant_id and id = v_fin.pledge_id
         for update;
      if v_pledge.id is not null then
        update public.monvelo_pledges set remaining = remaining + v_fin.principal
         where id = v_pledge.id
        returning * into v_restored;
        -- R15: it names the agent and its pledge, so no tenant reads it
        perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_pledges', v_pledge.id::text,
          jsonb_build_object('remaining', v_pledge.remaining),
          jsonb_build_object('remaining', v_restored.remaining, 'amount', v_fin.principal,
                             'agent_id', v_pledge.agent_id, 'pledge_id', v_pledge.id, 'financing_id', v_fin.id,
                             'reason', 'REFUND_CONFIRMED'),
          null, 'CRON');
      end if;
    end if;

    v_rel := null;
    if v_order.status in ('PAID', 'IN_TRANSIT') then
      update public.orders set status = 'CANCELLED' where id = v_order.id;
      -- what is still RESERVED goes back; CONSUMED stock waits for record_order_return
      v_rel := public.stock_release_order(v_order.tenant_id, v_order.id, 'CANCELLED');
    end if;

    -- no rebate is owed (§4.4); the payable names the agent, so no tenant reads its row
    for v_payable in
      update public.monvelo_rebate_payables set status = 'CANCELLED'
       where tenant_id = v_fin.tenant_id and financing_id = v_fin.id and status = 'DUE'
      returning id
    loop
      perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_rebate_payables', v_payable::text,
        jsonb_build_object('status', 'DUE'),
        jsonb_build_object('status', 'CANCELLED', 'financing_id', v_fin.id, 'reason', 'REFUND_DUE'),
        null, 'CRON');
    end loop;

    v_tkt := null;
    if not v_refunded then
      v_tkt := public.raise_system_ticket('monvelo-refund:' || v_fin.id, v_fin.order_id,
        'Refund the funding of ' || v_fin.paystack_reference || ' in Paystack.'
          || case when v_order.status = 'IN_TRANSIT' then ' The stock was dispatched: record its return.' else '' end,
        'HIGH');
    end if;

    perform public.write_audit(v_fin.tenant_id, 'monvelo_sweep_money', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'FUNDED', 'order_status', v_order.status),
      jsonb_build_object('status', 'REFUND_DUE', 'reason', 'NOT_DELIVERED_IN_23_HOURS', 'funded_at', v_fin.funded_at,
                         'order_id', v_order.id,
                         'order_status', case when v_order.status in ('PAID', 'IN_TRANSIT') then 'CANCELLED'
                                              else v_order.status end,
                         'reservations_released', v_rel, 'closed', v_refunded, 'ticket_id', v_tkt),
      null, 'CRON', v_fin.raised_by);
    v_due := v_due + 1;
  end loop;

  -- 2. due and not repaid: the one late charge (monvelo_apply_late_charge audits it)
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'DELIVERED' and now() >= f.due_at and f.outstanding > 0
       -- A8 §6.4: an open STORAGE claim pauses the charge; a rejected one lets it run
       and not public.monvelo_has_open_storage_claim(f.id)
     order by f.id
       for update skip locked
  loop
    perform public.monvelo_apply_late_charge(v_fin);
    v_charged := v_charged + 1;
  end loop;

  -- 3. repayments the owner has not confirmed in 24 hours: EXPIRED, a flag and
  --    a dispute ticket for the TM (§4.4). The financing is only read: its
  --    funder and order never change once funded. R54: an orphan (its financing
  --    closed, or the same recorder's later repayment on it CONFIRMED) is only
  --    EXPIRED, with no flag and no ticket.
  for v_rep in
    select * from public.monvelo_repayments r
     where r.status = 'PENDING' and r.recorded_at <= now() - interval '24 hours'
     order by r.id
       for update skip locked
  loop
    select * into v_fin from public.monvelo_financings where id = v_rep.financing_id;
    update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_rep.id;
    v_why := case
               when v_fin.closed_at is not null
                    or v_fin.status in ('REPAID_WITHIN_WINDOW', 'REPAID_LATE', 'REFUND_DUE') then 'FINANCING_CLOSED'
               when exists (select 1 from public.monvelo_repayments r2
                             where r2.tenant_id = v_rep.tenant_id and r2.financing_id = v_rep.financing_id
                               and r2.recorded_by = v_rep.recorded_by and r2.status = 'CONFIRMED'
                               and r2.recorded_at > v_rep.recorded_at) then 'SUPERSEDED'
             end;
    if v_why is not null then
      -- R15: the row names the recorder's repayment, so no tenant reads it
      perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_repayments', v_rep.id::text,
        jsonb_build_object('status', 'PENDING'),
        jsonb_build_object('status', 'EXPIRED', 'reason', v_why, 'financing_id', v_fin.id),
        null, 'CRON');
      v_quiet := v_quiet + 1;
      continue;
    end if;
    v_flag := public.monvelo_raise_flag('REPAYMENT_UNCONFIRMED', v_fin.id, v_fin.funder_agent_id,
      jsonb_build_object('repayment_id', v_rep.id, 'amount', v_rep.amount, 'recorded_at', v_rep.recorded_at));
    -- it names the financing, never the lender
    v_tkt := public.raise_system_ticket('monvelo-repayment:' || v_rep.id, v_fin.order_id,
      format('A repayment of NGN %s recorded on Monvelo financing %s was not confirmed by the shop owner within 24 hours. Check it with the shop.',
             to_char(v_rep.amount, 'FM999,999,999,990.00'), v_fin.reference),
      'HIGH');
    -- R15: the row names the repayment and its flag (the agent), so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_repayments', v_rep.id::text,
      jsonb_build_object('status', 'PENDING'),
      jsonb_build_object('status', 'EXPIRED', 'reason', 'UNCONFIRMED_24_HOURS', 'financing_id', v_fin.id,
                         'flag_id', v_flag, 'ticket_id', v_tkt),
      null, 'CRON');
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('refund_due', v_due, 'late_charged', v_charged, 'repayments_expired', v_expired,
                            'repayments_superseded', v_quiet);
end;
$$;
revoke all on function public.monvelo_sweep_money() from public, anon, authenticated, service_role;

-- ── confirm_monvelo_repayment: repaid in full withdraws the open STORAGE claim ──
-- Recreated from 20261031120200.
create or replace function public.confirm_monvelo_repayment(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_uid      uuid := (select auth.uid());
  v_prior    jsonb;
  v_ch       public.monvelo_owner_challenges;
  v_rep      public.monvelo_repayments;
  v_fin      public.monvelo_financings;
  v_from     text;
  v_charged  boolean := false;
  v_settings public.monvelo_tenant_settings;
  v_line     record;
  v_limit    public.monvelo_shop_limits;
  v_new      numeric(15,2);
  v_grown    jsonb := '[]'::jsonb;
  v_reason   text;
  v_claim    uuid;
  v_withdrawn uuid[] := array[]::uuid[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'confirm_monvelo_repayment',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- the challenge, then its repayment, then the financing
  select * into v_ch from public.monvelo_owner_challenges where id = p_challenge_id for update;
  if not found or v_ch.purpose <> 'REPAYMENT' then
    raise exception 'unknown repayment code request' using errcode = '42501';
  end if;
  select * into v_rep from public.monvelo_repayments where id = v_ch.repayment_id for update;
  select * into v_fin from public.monvelo_financings where id = v_rep.financing_id for update;
  -- R32: the member who recorded it, still an ACTIVE member of the funder
  if v_rep.recorded_by is distinct from v_uid
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = v_fin.funder_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'only the member who recorded this repayment confirms it' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the repayment code must be 6 digits' using errcode = 'P0001';
  end if;

  -- a repayment already ended answers as it ended
  if v_rep.status = 'CONFIRMED' then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('confirmed', true, 'outstanding', v_fin.outstanding, 'status', v_fin.status));
  elsif v_rep.status = 'EXPIRED' then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', 'EXPIRED'));
  elsif v_rep.status = 'REJECTED' then
    raise exception 'the shop owner rejected this repayment' using errcode = 'P0001';
  end if;

  if v_ch.failed_attempts >= c_max_attempts then
    v_reason := 'LOCKED';
  elsif v_ch.expires_at <= now() then
    v_reason := 'EXPIRED';
  elsif v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_owner_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(null, 'MONVELO_REPAYMENT_CODE_FAILED', 'monvelo_owner_challenges', v_ch.id::text,
      null, jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'repayment_id', v_rep.id,
                               'financing_id', v_fin.id),
      p_idempotency_key);
    v_reason := case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end;
  end if;

  if v_reason is not null then
    -- R30: a code that can no longer confirm ends its repayment
    if v_reason in ('LOCKED', 'EXPIRED') then
      update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_rep.id;
      perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
        jsonb_build_object('status', 'PENDING'), jsonb_build_object('status', 'EXPIRED', 'reason', v_reason),
        p_idempotency_key);
    end if;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', v_reason));
  end if;

  -- the right code
  if v_fin.status not in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    raise exception 'this financing takes no more repayments' using errcode = 'P0001';
  end if;
  update public.monvelo_owner_challenges set consumed_at = now() where id = v_ch.id;
  v_from := v_fin.status;

  -- Review Focus 4: past due_at and still uncharged, the charge comes first
  if v_fin.status = 'DELIVERED' and now() >= v_fin.due_at then
    v_fin := public.monvelo_apply_late_charge(v_fin);
    -- A8 §6.4: an open STORAGE claim holds the charge back
    v_charged := v_fin.status = 'DEFAULTED_WITH_LATE_CHARGE';
  end if;
  if v_rep.amount > v_fin.outstanding then
    raise exception 'the amount is more than is left to repay' using errcode = 'P0001';
  end if;

  update public.monvelo_repayments set status = 'CONFIRMED', confirmed_at = now(), ended_at = now() where id = v_rep.id;
  update public.monvelo_financings
     set outstanding = outstanding - v_rep.amount,
         status = case when outstanding - v_rep.amount > 0 then status
                       when status = 'DELIVERED' then 'REPAID_WITHIN_WINDOW'
                       else 'REPAID_LATE' end,
         closed_at = case when outstanding - v_rep.amount = 0 then now() else closed_at end
   where id = v_fin.id
  returning * into v_fin;

  -- A8 §6.4: repaid in full, an open STORAGE claim has nothing left to cover
  if v_fin.outstanding = 0 then
    for v_claim in
      update public.monvelo_insurance_claims set status = 'WITHDRAWN', closed_reason = 'repaid in full'
       where financing_id = v_fin.id and kind = 'STORAGE' and status in ('REPORTED', 'FILED', 'UNDER_REVIEW')
      returning id
    loop
      v_withdrawn := v_withdrawn || v_claim;
      -- R15: a STORAGE claim names the lender: tenant-null
      perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_insurance_claims', v_claim::text,
        null, jsonb_build_object('status', 'WITHDRAWN', 'reason', 'REPAID_IN_FULL', 'financing_id', v_fin.id),
        p_idempotency_key);
      perform public.monvelo_notify_claim((select c from public.monvelo_insurance_claims c where c.id = v_claim));
    end loop;
  end if;

  -- §7.2: repaid within the window, each brand's limit grows, capped by max_limit
  if v_fin.status = 'REPAID_WITHIN_WINDOW' then
    select * into v_settings from public.monvelo_tenant_settings where tenant_id = v_fin.tenant_id;
    if coalesce(v_settings.limit_growth_bps, 0) > 0 then
      for v_line in
        select l.brand_key from public.monvelo_financing_lines l
         where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id
         order by l.brand_key
      loop
        v_limit := public.monvelo_shop_limit_for(v_fin.tenant_id, v_fin.shop_id, v_line.brand_key);
        v_new := round(v_limit.limit_amount * (10000 + v_settings.limit_growth_bps) / 10000.0, 2);
        if v_settings.max_limit is not null then
          v_new := least(v_new, v_settings.max_limit);
        end if;
        if v_new > v_limit.limit_amount then
          update public.monvelo_shop_limits set limit_amount = v_new
           where tenant_id = v_fin.tenant_id and shop_id = v_fin.shop_id and brand_key = v_line.brand_key;
          insert into public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key, kind, old_limit, new_limit, financing_id)
          values (v_fin.tenant_id, v_fin.shop_id, v_line.brand_key, 'GROWN', v_limit.limit_amount, v_new, v_fin.id);
          v_grown := v_grown || jsonb_build_object('brand_key', v_line.brand_key, 'old_limit', v_limit.limit_amount,
                                                   'new_limit', v_new);
        end if;
      end loop;
    end if;
  end if;

  -- R15: the row names the recorder, so no tenant reads it
  perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
    jsonb_build_object('status', 'PENDING', 'financing_status', v_from),
    jsonb_build_object('status', 'CONFIRMED', 'financing_id', v_fin.id, 'amount', v_rep.amount,
                       'outstanding', v_fin.outstanding, 'financing_status', v_fin.status,
                       'late_charge_applied', v_charged, 'grown', v_grown,
                       'claims_withdrawn', to_jsonb(v_withdrawn)),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('confirmed', true, 'outstanding', v_fin.outstanding, 'status', v_fin.status));
end;
$$;
revoke all on function public.confirm_monvelo_repayment(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_monvelo_repayment(uuid, uuid, text) to authenticated;

-- ── the lender reconciliation summary gains the claim columns ───────────
drop function public.get_lender_reconciliation_summary(integer);
create or replace function public.get_lender_reconciliation_summary(p_weeks integer default 12)
returns table (
  agent_id       uuid,
  agent_name     text,
  week_start     date,
  capital_funded numeric(15,2),
  outstanding    numeric(15,2),
  repaid         numeric(15,2),
  refunded       numeric(15,2),
  rebates_owed   numeric(15,2),
  rebates_paid   numeric(15,2),
  mv_references  text[],
  closed_by_claim_amount numeric(15,2),
  late_charge_waived     numeric(15,2)
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_agents uuid[];
  v_me     public.tenant_users;
  v_from   date;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_agents := array(select m.id from public.my_monvelo_agent_ids() m(id));
  if cardinality(v_agents) = 0 then
    v_me := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 52 then
    raise exception 'p_weeks must be between 1 and 52' using errcode = '22023';
  end if;

  v_from := (date_trunc('week', now() at time zone 'Africa/Lagos'))::date - 7 * (p_weeks - 1);

  return query
  with fin as (
    select f.id, f.tenant_id, f.funder_agent_id, f.principal, f.status, f.outstanding, f.closed_at,
           f.paystack_reference,
           (date_trunc('week', f.funded_at at time zone 'Africa/Lagos'))::date as wk
      from public.monvelo_financings f
     where f.funded_at is not null
       and f.funder_agent_id is not null
       and f.funded_at >= (v_from::timestamp at time zone 'Africa/Lagos')
       and case
             when cardinality(v_agents) > 0 then f.funder_agent_id = any (v_agents)
             when v_me.role = 'ZSA' then
               f.tenant_id = v_me.tenant_id
               and exists (select 1
                             from public.areas ar
                             join public.territories t on t.tenant_id = ar.tenant_id and t.id = ar.territory_id
                            where ar.tenant_id = f.tenant_id and ar.id = f.area_id and t.zone_id = v_me.zone_id)
             else f.tenant_id = v_me.tenant_id and f.area_id = v_me.area_id
           end
  ),
  rep as (
    select r.financing_id, sum(r.amount) as amount
      from public.monvelo_repayments r
      join fin on fin.tenant_id = r.tenant_id and fin.id = r.financing_id
     where r.status = 'CONFIRMED'
     group by r.financing_id
  ),
  -- A8 §5.6: what the insurer paid on a financing it closed, and the late charge waived
  clm as (
    select c.financing_id, sum(c.settled_amount) as settled, sum(coalesce(c.late_charge_waived, 0)) as waived
      from public.monvelo_insurance_claims c
      join fin on fin.tenant_id = c.tenant_id and fin.id = c.financing_id
     where c.kind = 'STORAGE' and c.status = 'SETTLED' and fin.status = 'CLOSED_BY_CLAIM'
     group by c.financing_id
  )
  select fin.funder_agent_id,
         a.business_name,
         fin.wk,
         coalesce(sum(fin.principal), 0)::numeric(15,2),
         coalesce(sum(fin.outstanding) filter (where fin.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')), 0)::numeric(15,2),
         coalesce(sum(rep.amount), 0)::numeric(15,2),
         coalesce(sum(fin.principal) filter (where fin.status = 'REFUND_DUE' and fin.closed_at is not null), 0)::numeric(15,2),
         coalesce(sum(pay.amount) filter (where pay.status = 'DUE'), 0)::numeric(15,2),
         coalesce(sum(pay.amount) filter (where pay.status = 'PAID'), 0)::numeric(15,2),
         coalesce(array_agg(fin.paystack_reference order by fin.paystack_reference)
                    filter (where fin.paystack_reference is not null), array[]::text[]),
         coalesce(sum(clm.settled), 0)::numeric(15,2),
         coalesce(sum(clm.waived), 0)::numeric(15,2)
    from fin
    join public.monvelo_agents a on a.id = fin.funder_agent_id
    left join rep on rep.financing_id = fin.id
    left join clm on clm.financing_id = fin.id
    left join public.monvelo_rebate_payables pay on pay.tenant_id = fin.tenant_id and pay.financing_id = fin.id
   group by fin.funder_agent_id, a.business_name, fin.wk
   order by fin.wk desc, a.business_name, fin.funder_agent_id;
end;
$$;
revoke all on function public.get_lender_reconciliation_summary(integer) from public, anon, service_role;
grant execute on function public.get_lender_reconciliation_summary(integer) to authenticated;
comment on function public.get_lender_reconciliation_summary(integer) is
  'A6 §19: per agent and Lagos funding week: capital funded, outstanding, repaid, refunded, rebates owed and paid, MV- references; A8: claim settlements that closed financings and the late charges they waived. Readers: the agent''s members (all tenants), a ZSA (zone), an ASA (area).';
