-- Addendum A8 §6.4, §7.1, §7.2 (plan Task 6): what insurers answer, and the
-- daily policy-expiry sweep.
--
--   claim_monvelo_declarations       service_role: a batch for monvelo-insurance-declare (Task 7)
--   complete_monvelo_declaration     service_role: ACCEPTED, REJECTED or RETRY
--   record_monvelo_declaration_outcome  MONVELO_OPERATOR: the MANUAL adapter's path
--   monvelo_apply_declaration_outcome   internal: the one place an answer lands
--   monvelo_sweep_declarations       cron: DECLARATION_STALE, once per storage declaration
--   monvelo_sweep_shop_policies      cron: EXPIRED, and the 15-day expiry notice
--
-- Retries back off 2^attempts minutes, at most 6 hours, for 24 hours from
-- the row's creation; then FAILED with a flag. A rejected storage
-- declaration leaves the financing uncovered (§6.4): the unpaid premium is
-- cancelled (a paid one is flagged for recovery), the agent's rebate is
-- topped back up, and the agent and the operators are told. Every answer to
-- a row already completed is ignored, so a repeat changes nothing.

-- the financing a declaration is about
create or replace function public.monvelo_declaration_financing(p_decl public.monvelo_insurance_declarations)
returns uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select case p_decl.subject_table
           when 'monvelo_financing_cover' then p_decl.subject_id
           when 'monvelo_order_git_cover' then (select g.financing_id from public.monvelo_order_git_cover g
                                                 where g.order_id = p_decl.subject_id)
           when 'monvelo_insurance_claims' then (select c.financing_id from public.monvelo_insurance_claims c
                                                  where c.id = p_decl.subject_id)
         end;
$$;
revoke all on function public.monvelo_declaration_financing(public.monvelo_insurance_declarations)
  from public, anon, authenticated, service_role;

-- ── the batch ───────────────────────────────────────────────────────────
create or replace function public.claim_monvelo_declarations(p_limit integer default 20)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with due as (
    select d.id from public.monvelo_insurance_declarations d
     where (d.status = 'PENDING' and d.next_attempt_at <= now())
        or (d.status = 'SENDING' and d.next_attempt_at <= now() - interval '10 minutes')
     order by d.next_attempt_at, d.created_at, d.id
     for update skip locked
     limit greatest(coalesce(p_limit, 0), 0)
  ), claimed as (
    update public.monvelo_insurance_declarations d
       set status = 'SENDING', attempts = d.attempts + 1, next_attempt_at = now()
      from due
     where d.id = due.id
    returning d.*
  )
  select jsonb_build_object('id', c.id, 'kind', c.kind, 'insurer_code', i.code, 'api_provider', i.api_provider,
                            'attempts', c.attempts, 'payload', c.payload)
    from claimed c
    join public.monvelo_insurers i on i.id = c.insurer_id;
end;
$$;
revoke all on function public.claim_monvelo_declarations(integer) from public, anon, authenticated;
grant execute on function public.claim_monvelo_declarations(integer) to service_role;

-- ── the one place an insurer's answer lands ─────────────────────────────
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
  if v_decl.status not in ('PENDING', 'SENDING') then
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

create or replace function public.complete_monvelo_declaration(p_id uuid, p_outcome text, p_insurer_reference text,
                                                               p_error text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.monvelo_apply_declaration_outcome(p_id, p_outcome, p_insurer_reference, p_error, null);
end;
$$;
revoke all on function public.complete_monvelo_declaration(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.complete_monvelo_declaration(uuid, text, text, text) to service_role;

-- the MANUAL adapter: an operator records what the insurer said
create or replace function public.record_monvelo_declaration_outcome(p_idempotency_key uuid, p_declaration_id uuid,
                                                                     p_outcome text, p_insurer_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_declaration_outcome',
    jsonb_build_object('declaration_id', p_declaration_id, 'outcome', p_outcome,
                       'insurer_reference', p_insurer_reference));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_outcome is null or p_outcome not in ('ACCEPTED', 'REJECTED') then
    raise exception 'an insurer''s answer is ACCEPTED or REJECTED' using errcode = 'P0001';
  end if;
  return public.idempotency_complete(p_idempotency_key,
    public.monvelo_apply_declaration_outcome(p_declaration_id, p_outcome, p_insurer_reference, null, v_uid));
end;
$$;
revoke all on function public.record_monvelo_declaration_outcome(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.record_monvelo_declaration_outcome(uuid, uuid, text, text) to authenticated;

-- ── the stale sweep: the agent's capital waits unprotected ──────────────
create or replace function public.monvelo_sweep_declarations()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select f.id, f.funder_agent_id, f.delivered_at, d.id as declaration_id, d.status
      from public.monvelo_financing_cover c
      join public.monvelo_financings f on f.id = c.financing_id
      join public.monvelo_insurance_declarations d
        on d.kind = 'STORAGE_DECLARE' and d.subject_table = 'monvelo_financing_cover' and d.subject_id = c.financing_id
     where c.declared_status = 'PENDING'
       and f.delivered_at <= now() - interval '24 hours'
       and not exists (select 1 from public.monvelo_flags fl
                        where fl.kind = 'DECLARATION_STALE' and fl.financing_id = f.id)
     order by f.id
  loop
    perform public.monvelo_raise_flag('DECLARATION_STALE', v_row.id, v_row.funder_agent_id,
      jsonb_build_object('declaration_id', v_row.declaration_id, 'declaration_status', v_row.status,
                         'delivered_at', v_row.delivered_at));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.monvelo_sweep_declarations() from public, anon, authenticated, service_role;

-- ── the policy-expiry sweep (§7.1) ──────────────────────────────────────
-- 1. VERIFIED and past expires_on -> EXPIRED.
-- 2. VERIFIED, expiring within 15 days (today + 15 on a normal day; a missed
--    run catches up) and not yet noticed -> an email to every ACTIVE ZSA and
--    ASA of an area where the shop is ACTIVE-ly enrolled who has an email,
--    and an in-app notice to each of them. The email names the shop and the
--    date only.
create or replace function public.monvelo_sweep_shop_policies()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_today   date := public.monvelo_today();
  v_pol     public.monvelo_shop_policies;
  v_shop    text;
  v_rcpt    record;
  v_expired integer := 0;
  v_noticed integer := 0;
  v_emails  integer := 0;
begin
  for v_pol in
    select * from public.monvelo_shop_policies p
     where p.status = 'VERIFIED' and p.expires_on < v_today
     order by p.id
       for update skip locked
  loop
    update public.monvelo_shop_policies set status = 'EXPIRED' where id = v_pol.id;
    perform public.write_audit(null, 'monvelo_sweep_shop_policies', 'monvelo_shop_policies', v_pol.id::text,
                               jsonb_build_object('status', 'VERIFIED'),
                               jsonb_build_object('status', 'EXPIRED', 'expires_on', v_pol.expires_on),
                               null, 'CRON');
    v_expired := v_expired + 1;
  end loop;

  for v_pol in
    select * from public.monvelo_shop_policies p
     where p.status = 'VERIFIED' and p.expires_on between v_today and v_today + 15
       and p.expiry_notice_sent_at is null
     order by p.id
       for update skip locked
  loop
    select s.shop_name into v_shop from public.retail_shops s where s.id = v_pol.shop_id;
    for v_rcpt in
      select distinct tu.tenant_id, tu.profile_id, pr.email
        from public.monvelo_shop_enrolments e
        join public.areas a on a.tenant_id = e.tenant_id and a.id = e.area_id
        join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
        join public.tenant_users tu on tu.tenant_id = e.tenant_id and tu.status = 'ACTIVE'
         and ((tu.role = 'ASA' and tu.area_id = e.area_id) or (tu.role = 'ZSA' and tu.zone_id = t.zone_id))
        join public.profiles pr on pr.id = tu.profile_id
       where e.shop_id = v_pol.shop_id and e.status = 'ACTIVE'
       order by tu.tenant_id, tu.profile_id
    loop
      if v_rcpt.email is not null then
        perform public.enqueue_email('MONVELO_SHOP_COVER_EXPIRING', v_rcpt.email,
          jsonb_build_object('shop_name', v_shop, 'expires_on', v_pol.expires_on),
          'monvelo_shop_policies', v_pol.id);
        v_emails := v_emails + 1;
      end if;
      insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
      values (v_rcpt.tenant_id, v_rcpt.profile_id, 'MONVELO_SHOP_COVER_EXPIRING', 'Shop cover expiring',
              v_shop || '''s stock insurance expires on ' || to_char(v_pol.expires_on, 'DD Mon YYYY')
                || '. Ask the owner for the renewal.',
              jsonb_build_object('policy_id', v_pol.id, 'shop_id', v_pol.shop_id, 'expires_on', v_pol.expires_on));
    end loop;
    update public.monvelo_shop_policies set expiry_notice_sent_at = now() where id = v_pol.id;
    v_noticed := v_noticed + 1;
  end loop;

  return jsonb_build_object('expired', v_expired, 'noticed', v_noticed, 'emails', v_emails);
end;
$$;
revoke all on function public.monvelo_sweep_shop_policies() from public, anon, authenticated, service_role;

-- ── cron (pure SQL; cron.schedule upserts by name) ──────────────────────
select cron.schedule('monvelo-shop-policy-sweep', '0 5 * * *', $$select public.monvelo_sweep_shop_policies()$$);
select cron.schedule('monvelo-declaration-sweep', '*/15 * * * *', $$select public.monvelo_sweep_declarations()$$);
