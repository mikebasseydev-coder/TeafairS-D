-- Addendum A8, final review fix: a declaration that FAILED (24 hours of
-- retries) left its cover PENDING for good, so file_monvelo_insurance_claim
-- refused that financing's claim forever and no RPC could resolve it. An
-- operator may now record the insurer's answer on a FAILED row through
-- record_monvelo_declaration_outcome (the MANUAL path); the declare function
-- still cannot reopen it.
--
-- The status guard gains FAILED>ACCEPTED and FAILED>REJECTED, and
-- monvelo_apply_declaration_outcome is recreated from 20261031122200 with
-- that one change.

drop trigger monvelo_insurance_declarations_guard on public.monvelo_insurance_declarations;
create trigger monvelo_insurance_declarations_guard before insert or update on public.monvelo_insurance_declarations
  for each row execute function public.monvelo_cover_guard('PENDING',
    'PENDING>SENDING,SENDING>PENDING,SENDING>SENDING,SENDING>ACCEPTED,SENDING>REJECTED,SENDING>FAILED,'
    'PENDING>ACCEPTED,PENDING>REJECTED,PENDING>FAILED,FAILED>ACCEPTED,FAILED>REJECTED',
    'attempts,next_attempt_at,insurer_reference,last_error,completed_at');

create or replace function public.monvelo_apply_declaration_outcome(p_id uuid, p_outcome text, p_insurer_reference text,
                                                                    p_error text, p_actor uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ref     text := nullif(btrim(coalesce(p_insurer_reference, '')), '');
  v_err     text := left(nullif(btrim(coalesce(p_error, '')), ''), 2000);
  v_src     public.audit_source_enum := case when p_actor is null then 'SYSTEM' else 'USER' end;
  v_decl    public.monvelo_insurance_declarations;
  v_fin     public.monvelo_financings;
  v_fin_id  uuid;
  v_cover   public.monvelo_financing_cover;
  v_pay     public.monvelo_premium_payables;
  v_claim   public.monvelo_insurance_claims;
  v_flag    uuid;
  v_topup   uuid;
  v_next    timestamptz;
begin
  if p_outcome is null or p_outcome not in ('ACCEPTED', 'REJECTED', 'RETRY') then
    raise exception 'an outcome is ACCEPTED, REJECTED or RETRY' using errcode = 'P0001';
  end if;
  if length(v_ref) > 128 then
    raise exception 'the insurer''s reference must be at most 128 characters' using errcode = 'P0001';
  end if;
  select * into v_decl from public.monvelo_insurance_declarations where id = p_id;
  if not found then
    raise exception 'declaration not found' using errcode = 'P0001';
  end if;
  v_fin_id := public.monvelo_declaration_financing(v_decl);
  -- lock order: the financing (as the claim and repayment paths), then the declaration
  if v_fin_id is not null then
    select * into v_fin from public.monvelo_financings where id = v_fin_id for update;
  end if;
  select * into v_decl from public.monvelo_insurance_declarations where id = p_id for update;
  -- final review: a FAILED row (24 hours of retries) is answered only by an
  -- operator recording what the insurer said; the declare function never reopens it
  if not (v_decl.status in ('PENDING', 'SENDING')
          or (v_decl.status = 'FAILED' and p_actor is not null and p_outcome in ('ACCEPTED', 'REJECTED'))) then
    return jsonb_build_object('declaration_id', v_decl.id, 'ignored', true, 'status', v_decl.status);
  end if;

  if p_outcome = 'RETRY' then
    if now() >= v_decl.created_at + interval '24 hours' then
      update public.monvelo_insurance_declarations
         set status = 'FAILED', last_error = coalesce(v_err, last_error), completed_at = now()
       where id = v_decl.id;
      v_flag := public.monvelo_raise_flag('DECLARATION_FAILED', v_fin_id, v_fin.funder_agent_id,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'attempts', v_decl.attempts,
                           'last_error', coalesce(v_err, v_decl.last_error)));
      return jsonb_build_object('declaration_id', v_decl.id, 'status', 'FAILED', 'flag_id', v_flag);
    end if;
    v_next := now() + least(make_interval(mins => power(2, least(v_decl.attempts, 16))::integer), interval '6 hours');
    update public.monvelo_insurance_declarations
       set status = 'PENDING', next_attempt_at = v_next, last_error = coalesce(v_err, last_error)
     where id = v_decl.id;
    return jsonb_build_object('declaration_id', v_decl.id, 'status', 'PENDING', 'next_attempt_at', v_next);
  end if;

  update public.monvelo_insurance_declarations
     set status = p_outcome, insurer_reference = coalesce(v_ref, insurer_reference),
         last_error = case when p_outcome = 'REJECTED' then coalesce(v_err, last_error) else last_error end,
         completed_at = now()
   where id = v_decl.id;

  if v_decl.kind = 'STORAGE_DECLARE' then
    select * into v_cover from public.monvelo_financing_cover where financing_id = v_decl.subject_id for update;
    if v_cover.declared_status = 'PENDING' then
      update public.monvelo_financing_cover set declared_status = p_outcome where financing_id = v_cover.financing_id;
    end if;
    if p_outcome = 'REJECTED' and v_cover.declared_status = 'PENDING' then
      -- §6.4: the agent paid for cover that does not exist
      select * into v_pay from public.monvelo_premium_payables
       where financing_id = v_cover.financing_id and kind = 'STORAGE' for update;
      if v_pay.status = 'DUE' then
        update public.monvelo_premium_payables set status = 'CANCELLED' where id = v_pay.id;
      elsif v_pay.status = 'PAID' then
        perform public.monvelo_raise_flag('PREMIUM_RECOVERY', v_fin.id, v_fin.funder_agent_id,
          jsonb_build_object('declaration_id', v_decl.id, 'payable_id', v_pay.id, 'amount', v_pay.amount,
                             'paid_reference', v_pay.paid_reference));
      end if;
      insert into public.monvelo_rebate_topups (tenant_id, financing_id, agent_id, amount, reason, due_at)
      values (v_fin.tenant_id, v_fin.id, v_fin.funder_agent_id, v_cover.storage_premium, 'DECLARATION_REJECTED',
              now() + interval '24 hours')
      on conflict (financing_id, reason) do nothing
      returning id into v_topup;
      v_flag := public.monvelo_raise_flag('DECLARATION_REJECTED', v_fin.id, v_fin.funder_agent_id,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'reason', v_err, 'topup_id', v_topup));
      -- the agent's members (tenant-null, §16.2.2) and every operator
      insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
      select null, r.profile_id, 'MONVELO_COVER_REJECTED', 'Stock cover declined',
             'The insurer declined the stock cover on ' || v_fin.reference
               || '. The financing continues uncovered; the premium is returned to the agent.',
             jsonb_build_object('financing_id', v_fin.id, 'reference', v_fin.reference, 'topup_id', v_topup)
        from (select m.profile_id from public.monvelo_agent_members m
               where m.agent_id = v_fin.funder_agent_id and m.status = 'ACTIVE'
              union
              select p.id from public.profiles p where p.platform_role = 'MONVELO_OPERATOR') r;
    end if;
  elsif v_decl.kind = 'GIT_DECLARE' then
    update public.monvelo_order_git_cover set declared_status = p_outcome
     where order_id = v_decl.subject_id and declared_status = 'PENDING';
    if p_outcome = 'REJECTED' then
      select * into v_pay from public.monvelo_premium_payables
       where financing_id = v_fin_id and kind = 'GIT' for update;
      if v_pay.status = 'DUE' then
        update public.monvelo_premium_payables set status = 'CANCELLED' where id = v_pay.id;
      elsif v_pay.status = 'PAID' then
        perform public.monvelo_raise_flag('PREMIUM_RECOVERY', v_fin_id, null,
          jsonb_build_object('declaration_id', v_decl.id, 'payable_id', v_pay.id, 'amount', v_pay.amount));
      end if;
      v_flag := public.monvelo_raise_flag('DECLARATION_REJECTED', v_fin_id, null,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'reason', v_err));
    end if;
  elsif v_decl.kind = 'CLAIM_FILE' then
    select * into v_claim from public.monvelo_insurance_claims where id = v_decl.subject_id for update;
    if v_claim.status in ('FILED', 'UNDER_REVIEW') then
      update public.monvelo_insurance_claims
         set insurer_claim_reference = coalesce(v_ref, insurer_claim_reference),
             status = case when p_outcome = 'REJECTED' then 'REJECTED' else status end,
             closed_reason = case when p_outcome = 'REJECTED' then coalesce(v_err, 'rejected by the insurer')
                                  else closed_reason end
       where id = v_claim.id returning * into v_claim;
      perform public.monvelo_notify_claim(v_claim);
    end if;
  end if;

  -- declarations carry no tenant reader; the row is tenant-null (STORAGE and claims name the lender)
  perform public.write_audit(null, 'monvelo_declaration_outcome', 'monvelo_insurance_declarations', v_decl.id::text,
                             jsonb_build_object('status', v_decl.status),
                             jsonb_build_object('status', p_outcome, 'kind', v_decl.kind, 'insurer_reference', v_ref,
                                                'flag_id', v_flag, 'topup_id', v_topup),
                             null, v_src);
  return jsonb_build_object('declaration_id', v_decl.id, 'status', p_outcome);
end;
$$;
revoke all on function public.monvelo_apply_declaration_outcome(uuid, text, text, text, uuid)
  from public, anon, authenticated, service_role;
