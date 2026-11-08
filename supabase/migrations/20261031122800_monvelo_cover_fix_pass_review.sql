-- Addendum A8, second review of the fix pass (2026-11-08):
--   1. confirm_monvelo_repayment: a repayment confirmed after due_at applies
--      the late charge first, on the whole outstanding, whatever the claim.
--      (122700 forced it only on the repayment that cleared the principal, so
--      47000 then 1000 charged 10 % of 1000.) An open STORAGE claim still
--      pauses the sweep's charge.
--   2. monvelo_settle_claim: PENDING repayments count against the cap and are
--      named in the CLAIM_OVER_RECOVERY flag.
-- Both recreated from 20261031122700 with only these changes.

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
    -- second review: any repayment confirmed after due_at takes the charge
    -- first, on the whole outstanding, open claim or not. An open STORAGE claim
    -- pauses only the sweep (no repayment is coming); a repayment in parts can
    -- no longer shrink the charge to the last part.
    v_fin := public.monvelo_apply_late_charge_now(v_fin);
    v_charged := v_fin.status = 'DEFAULTED_WITH_LATE_CHARGE';
  end if;
  if v_rep.amount > v_fin.outstanding then
    raise exception 'the amount is more than is left to repay' using errcode = 'P0001';
  end if;

  update public.monvelo_repayments set status = 'CONFIRMED', confirmed_at = now(), ended_at = now() where id = v_rep.id;
  update public.monvelo_financings
     set outstanding = outstanding - v_rep.amount,
         status = case when outstanding - v_rep.amount > 0 then status
                       when status = 'DELIVERED' and now() < due_at then 'REPAID_WITHIN_WINDOW'
                       else 'REPAID_LATE' end,
         closed_at = case when outstanding - v_rep.amount = 0 then now() else closed_at end
   where id = v_fin.id
  returning * into v_fin;

  -- A8 §6.4: the principal repaid, an open STORAGE claim has nothing left to
  -- cover; otherwise it claims only what is still unpaid (fix pass)
  if public.monvelo_unpaid_principal(v_fin) = 0 then
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
  else
    update public.monvelo_insurance_claims c set claimed_amount = public.monvelo_unpaid_principal(v_fin)
     where c.financing_id = v_fin.id and c.kind = 'STORAGE' and c.status in ('REPORTED', 'FILED', 'UNDER_REVIEW')
       and c.claimed_amount > public.monvelo_unpaid_principal(v_fin);
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
  v_cap    numeric(15,2);
  v_paid   numeric(15,2);
  v_over   uuid;
  v_pend   numeric(15,2) := 0;
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
  -- fix pass: a STORAGE settlement is recognised up to the principal still
  -- unpaid now (a repayment may have landed since the report); the insurer's
  -- excess is flagged for recovery, never credited to the agent's loan
  -- second review: a repayment recorded but not yet confirmed is money the
  -- agent's member already holds; it counts against the cap too (the
  -- financing row lock above serialises this with confirm_monvelo_repayment)
  v_paid := p_settled_amount;
  if v_claim.kind = 'STORAGE' then
    select coalesce(sum(r.amount), 0) into v_pend from public.monvelo_repayments r
     where r.tenant_id = v_fin.tenant_id and r.financing_id = v_fin.id and r.status = 'PENDING';
    v_cap := least(v_claim.claimed_amount, greatest(public.monvelo_unpaid_principal(v_fin) - v_pend, 0));
  else
    v_cap := v_claim.claimed_amount;
  end if;
  if v_paid > v_cap then
    v_over := public.monvelo_raise_flag('CLAIM_OVER_RECOVERY', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'insurer_paid', v_paid, 'recognised', v_cap,
                         'excess', v_paid - v_cap, 'pending_repayments', v_pend, 'payout_reference', v_ref));
  end if;

  if v_claim.kind = 'STORAGE' and v_fin.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    v_waived := v_fin.late_charge_amount;
    update public.monvelo_financings
       set status = 'CLOSED_BY_CLAIM', outstanding = 0, closed_at = now()
     where id = v_fin.id;
    v_closed := true;
  end if;
  update public.monvelo_insurance_claims
     set status = 'SETTLED', settled_amount = least(v_paid, v_cap), settled_at = now(), payout_reference = v_ref,
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
                                                'late_charge_waived', v_waived, 'flag_id', v_flag,
                                                'insurer_paid', v_paid, 'over_recovery_flag_id', v_over),
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
