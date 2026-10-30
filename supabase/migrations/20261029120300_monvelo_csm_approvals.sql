-- Addendum A6 §16.3, §16.4 and §17.3 (Monvelo Step 1c, Task 3) — zero unaudited
-- backdoors. Every approval and withdrawal of brand terms, every change of a
-- tenant's Monvelo settings and every recording of Teafair's fee terms cites a
-- current contact-report decision (ZSM-approved, signed hard copy attached).
-- The CSM approves while the tenant has one; two different ZSMs approve while
-- it has none (bridging). Also tightens two Task 2b functions: the hard-copy
-- attach demands the stored object's size and mimetype (as A5), and a
-- superseded report takes no new hard-copy slot.

-- ── columns ─────────────────────────────────────────────────────────────
alter table public.monvelo_brand_terms add column approval_decision_id uuid;
alter table public.monvelo_brand_terms add constraint monvelo_brand_terms_decision_fkey
  foreign key (tenant_id, approval_decision_id)
  references public.contact_report_decisions (tenant_id, id) on delete restrict;
create index idx_monvelo_brand_terms_decision on public.monvelo_brand_terms (tenant_id, approval_decision_id);

alter table public.monvelo_tenant_settings add column decision_id uuid;
alter table public.monvelo_tenant_settings add constraint monvelo_tenant_settings_decision_fkey
  foreign key (tenant_id, decision_id)
  references public.contact_report_decisions (tenant_id, id) on delete restrict;
create index idx_monvelo_tenant_settings_decision on public.monvelo_tenant_settings (tenant_id, decision_id);
-- the tenant's cap on limit growth (§7.2); Step 4 reads it
alter table public.monvelo_tenant_settings add column max_limit numeric(15,2);
alter table public.monvelo_tenant_settings add constraint monvelo_tenant_settings_max_limit_check
  check (max_limit is null or max_limit >= opening_limit);

alter table public.monvelo_tenant_fee_terms add column decision_id uuid;
alter table public.monvelo_tenant_fee_terms add constraint monvelo_tenant_fee_terms_decision_fkey
  foreign key (tenant_id, decision_id)
  references public.contact_report_decisions (tenant_id, id) on delete restrict;
create index idx_monvelo_fee_terms_decision on public.monvelo_tenant_fee_terms (tenant_id, decision_id);

-- ── monvelo_brand_terms_guard: the PROPOSED branch lets the decision change with the approval
create or replace function public.monvelo_brand_terms_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old) - 'brand_key';
    v_new := to_jsonb(new) - 'brand_key';  -- generated column not yet computed in BEFORE
    if old.status = 'WITHDRAWN' then
      raise exception 'withdrawn terms are immutable' using errcode = 'P0001';
    elsif old.status = 'APPROVED' then
      -- only to WITHDRAWN, or an end date later than today
      if not (
        (new.status = 'WITHDRAWN' and (v_old - 'status') = (v_new - 'status'))
        or (new.status = 'APPROVED' and new.valid_to is not null and new.valid_to > current_date
            and (old.valid_to is null or old.valid_to > current_date)
            and (v_old - 'valid_to') = (v_new - 'valid_to'))
      ) then
        raise exception 'approved terms are immutable' using errcode = 'P0001';
      end if;
    else
      -- PROPOSED: only a status change, with the approval stamp and its decision
      if (v_old - 'status' - 'approved_by' - 'approved_at' - 'approval_decision_id') is distinct from
         (v_new - 'status' - 'approved_by' - 'approved_at' - 'approval_decision_id') then
        raise exception 'proposed terms are changed by withdrawing and proposing again' using errcode = 'P0001';
      end if;
    end if;
  end if;

  if new.status = 'APPROVED' then
    -- serialise approvals per tenant and brand, then look at committed rows
    perform pg_advisory_xact_lock(hashtextextended('monvelo_brand_terms|' || new.tenant_id::text || '|' || lower(btrim(new.brand)), 0));
    if exists (
      select 1 from public.monvelo_brand_terms t
      where t.tenant_id = new.tenant_id
        and t.brand_key = lower(btrim(new.brand))
        and t.status = 'APPROVED'
        and t.id <> new.id
        and t.valid_from < coalesce(new.valid_to, 'infinity'::date)
        and new.valid_from < coalesce(t.valid_to, 'infinity'::date)
    ) then
      raise exception 'approved terms for this brand overlap in time' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

-- ── monvelo_tenant_has_csm (internal; no grant) ─────────────────────────
create or replace function public.monvelo_tenant_has_csm(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.tenant_users tu
                  where tu.tenant_id = p_tenant_id
                    and tu.role = 'CLIENT_SERVICE_MANAGER' and tu.status = 'ACTIVE');
$$;
revoke all on function public.monvelo_tenant_has_csm(uuid) from public, anon, authenticated, service_role;

-- ── approve_monvelo_brand_terms ─────────────────────────────────────────
drop function public.approve_monvelo_brand_terms(uuid, uuid);
create or replace function public.approve_monvelo_brand_terms(
  p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_csm    boolean;
  v_before public.monvelo_brand_terms;
  v_after  public.monvelo_brand_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_brand_terms',
    jsonb_build_object('terms_id', p_terms_id, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_csm := public.monvelo_tenant_has_csm(v_me.tenant_id);
  if v_csm and v_me.role <> 'CLIENT_SERVICE_MANAGER' then
    raise exception 'brand terms are approved by the client service manager' using errcode = '42501';
  end if;

  select * into v_before from public.monvelo_brand_terms
   where id = p_terms_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'terms not found' using errcode = 'P0001';
  end if;
  if v_before.status <> 'PROPOSED' then
    raise exception 'only proposed terms can be approved' using errcode = 'P0001';
  end if;
  if not v_csm and v_before.proposed_by = v_me.profile_id then
    raise exception 'terms are approved by a second ZSM' using errcode = '42501';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed these terms' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'BRAND_TERMS');

  update public.monvelo_brand_terms
     set status = 'APPROVED', approved_by = v_me.profile_id, approved_at = now(),
         approval_decision_id = p_decision_id
   where id = p_terms_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'approve_monvelo_brand_terms', 'monvelo_brand_terms',
                             v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('terms_id', v_after.id, 'status', v_after.status));
end;
$$;
revoke all on function public.approve_monvelo_brand_terms(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.approve_monvelo_brand_terms(uuid, uuid, uuid) to authenticated, service_role;

-- ── withdraw_monvelo_brand_terms ────────────────────────────────────────
drop function public.withdraw_monvelo_brand_terms(uuid, uuid);
create or replace function public.withdraw_monvelo_brand_terms(
  p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_brand_terms;
  v_after  public.monvelo_brand_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'withdraw_monvelo_brand_terms',
    jsonb_build_object('terms_id', p_terms_id, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_me.role <> 'CLIENT_SERVICE_MANAGER' and public.monvelo_tenant_has_csm(v_me.tenant_id) then
    raise exception 'brand terms are withdrawn by the client service manager' using errcode = '42501';
  end if;

  select * into v_before from public.monvelo_brand_terms
   where id = p_terms_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'terms not found' using errcode = 'P0001';
  end if;
  if v_before.status = 'WITHDRAWN' then
    raise exception 'terms are already withdrawn' using errcode = 'P0001';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this withdrawal' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'BRAND_TERMS');

  update public.monvelo_brand_terms set status = 'WITHDRAWN'
   where id = p_terms_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'withdraw_monvelo_brand_terms', 'monvelo_brand_terms',
                             v_after.id::text, to_jsonb(v_before),
                             to_jsonb(v_after) || jsonb_build_object('withdrawal_decision_id', p_decision_id),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('terms_id', v_after.id, 'status', v_after.status));
end;
$$;
revoke all on function public.withdraw_monvelo_brand_terms(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.withdraw_monvelo_brand_terms(uuid, uuid, uuid) to authenticated, service_role;

-- ── set_monvelo_tenant_settings ─────────────────────────────────────────
drop function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric);
create or replace function public.set_monvelo_tenant_settings(
  p_idempotency_key uuid, p_enabled boolean, p_opening_limit numeric, p_approval_cap numeric,
  p_max_limit numeric default null, p_decision_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_tenant_settings;
  v_after  public.monvelo_tenant_settings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_tenant_settings',
    jsonb_build_object('enabled', p_enabled, 'opening_limit', p_opening_limit, 'approval_cap', p_approval_cap,
                       'max_limit', p_max_limit, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_me.role <> 'CLIENT_SERVICE_MANAGER' and public.monvelo_tenant_has_csm(v_me.tenant_id) then
    raise exception 'Monvelo settings are set by the client service manager' using errcode = '42501';
  end if;

  if p_enabled is null or p_opening_limit is null or p_approval_cap is null
     or p_opening_limit < 0 or p_approval_cap < 0 then
    raise exception 'enabled, a non-negative opening limit and a non-negative approval cap are required'
      using errcode = 'P0001';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed these settings' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'MONVELO_SETTINGS');

  select * into v_before from public.monvelo_tenant_settings
   where tenant_id = v_me.tenant_id for update;

  insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap, max_limit, decision_id)
  values (v_me.tenant_id, p_enabled, p_opening_limit, p_approval_cap, p_max_limit, p_decision_id)
  on conflict (tenant_id) do update
    set enabled = excluded.enabled,
        opening_limit = excluded.opening_limit,
        approval_cap = excluded.approval_cap,
        max_limit = excluded.max_limit,
        decision_id = excluded.decision_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_tenant_settings', 'monvelo_tenant_settings',
                             v_me.tenant_id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', v_me.tenant_id, 'enabled', v_after.enabled));
end;
$$;
revoke all on function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric, numeric, uuid) from public, anon, authenticated, service_role;
grant execute on function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric, numeric, uuid) to authenticated, service_role;

-- ── record_monvelo_fee_terms ────────────────────────────────────────────
drop function public.record_monvelo_fee_terms(uuid, uuid, integer, date, date);
create or replace function public.record_monvelo_fee_terms(
  p_idempotency_key uuid, p_tenant_id uuid, p_fee_bps integer, p_valid_from date, p_valid_to date,
  p_decision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_after public.monvelo_tenant_fee_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_fee_terms',
    jsonb_build_object('tenant_id', p_tenant_id, 'fee_bps', p_fee_bps,
                       'valid_from', p_valid_from, 'valid_to', p_valid_to, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_tenant_id is null or not exists (select 1 from public.tenants t where t.id = p_tenant_id) then
    raise exception 'tenant not found' using errcode = 'P0001';
  end if;
  if p_fee_bps is null or p_fee_bps not between 0 and 10000 then
    raise exception 'a fee of 0-10000 bps is required' using errcode = 'P0001';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to <= p_valid_from) then
    raise exception 'valid_from is required and valid_to must be later than it' using errcode = 'P0001';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed these fee terms' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(p_tenant_id, p_decision_id, 'FEES');

  insert into public.monvelo_tenant_fee_terms (tenant_id, fee_bps, valid_from, valid_to, recorded_by, decision_id)
  values (p_tenant_id, p_fee_bps, p_valid_from, p_valid_to, v_actor, p_decision_id)
  returning * into v_after;

  perform public.write_audit(p_tenant_id, 'record_monvelo_fee_terms', 'monvelo_tenant_fee_terms',
                             v_after.id::text, null, to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('fee_terms_id', v_after.id));
end;
$$;
revoke all on function public.record_monvelo_fee_terms(uuid, uuid, integer, date, date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.record_monvelo_fee_terms(uuid, uuid, integer, date, date, uuid) to authenticated, service_role;

-- ── Task 2b review items A and B ────────────────────────────────────────
-- A: attach demands the object's size and mimetype (as A5); B: a superseded
-- report takes no new hard-copy slot. Recreated from the live bodies.
create or replace function public.request_contact_report_hard_copy(p_idempotency_key uuid, p_report_id uuid, p_mime_type text, p_size_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_report  public.contact_reports;
  v_outcome text;
  v_ext     text;
  v_id      uuid := gen_random_uuid();
  v_copy    public.contact_report_hard_copies;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_contact_report_hard_copy',
    jsonb_build_object('report_id', p_report_id, 'mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  if v_prior is not null then
    return v_prior;
  end if;

  select r.* into v_report from public.contact_reports r
   where r.id = p_report_id and r.tenant_id = v_me.tenant_id
     for update;
  if not found then
    raise exception 'contact report not found' using errcode = '42501';
  end if;
  if exists (select 1 from public.contact_reports r
              where r.tenant_id = v_report.tenant_id and r.supersedes_id = v_report.id) then
    raise exception 'this contact report has been superseded; upload the hard copy of its correction'
      using errcode = 'P0001';
  end if;
  if exists (select 1 from public.contact_report_hard_copies h
              where h.report_id = v_report.id and h.attached_at is not null) then
    raise exception 'this contact report already has its hard copy' using errcode = 'P0001';
  end if;

  select w.outcome into v_outcome from public.contact_report_reviews w where w.report_id = v_report.id;
  if v_outcome is null then
    raise exception 'a ZSM must approve this contact report before its hard copy is uploaded' using errcode = 'P0001';
  elsif v_outcome = 'REJECTED' then
    raise exception 'this contact report was rejected; file a correction' using errcode = 'P0001';
  end if;

  if p_size_bytes is null or p_size_bytes not between 1 and 10485760
     or p_mime_type is null or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'The hard copy must be a PDF, JPEG or PNG of at most 10 MB.' using errcode = 'P0001';
  end if;
  v_ext := case p_mime_type when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' else 'png' end;

  if (select count(*) from public.contact_report_hard_copies h
       where h.report_id = v_report.id and h.attached_at is null
         and h.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many upload requests. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  insert into public.contact_report_hard_copies (id, tenant_id, report_id, storage_path, mime_type, size_bytes, uploaded_by)
  values (v_id, v_report.tenant_id, v_report.id,
          'contact-reports/' || v_report.id || '/' || v_id || '.' || v_ext,
          p_mime_type, p_size_bytes, v_me.profile_id)
  returning * into v_copy;

  perform public.write_audit(v_report.tenant_id, 'request_contact_report_hard_copy', 'contact_report_hard_copies',
                             v_copy.id::text, null,
                             jsonb_build_object('reference', v_report.reference, 'mime_type', v_copy.mime_type,
                                                'size_bytes', v_copy.size_bytes),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('hard_copy_id', v_copy.id, 'storage_path', v_copy.storage_path));
end;
$function$;

create or replace function public.attach_contact_report_hard_copy(p_idempotency_key uuid, p_hard_copy_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_copy   public.contact_report_hard_copies;
  v_report public.contact_reports;
  v_at     timestamptz := now();
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'attach_contact_report_hard_copy',
    jsonb_build_object('hard_copy_id', p_hard_copy_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select h.* into v_copy from public.contact_report_hard_copies h
   where h.id = p_hard_copy_id and h.tenant_id = v_me.tenant_id;
  if not found then
    raise exception 'hard copy not found' using errcode = '42501';
  end if;
  -- serialise attaches per report
  select r.* into v_report from public.contact_reports r where r.id = v_copy.report_id for update;

  if exists (select 1 from public.contact_report_hard_copies h
              where h.report_id = v_copy.report_id and h.attached_at is not null) then
    raise exception 'this contact report already has its hard copy' using errcode = 'P0001';
  end if;
  -- a pending slot older than a day is queued for the purge by the nightly cleanup
  if v_copy.created_at < now() - interval '24 hours' then
    raise exception 'this upload has expired; request a new one' using errcode = 'P0001';
  end if;
  if not exists (select 1 from storage.objects o
                  where o.bucket_id = 'contact-reports' and o.name = v_copy.storage_path
                    and o.metadata ->> 'size' = v_copy.size_bytes::text
                    and o.metadata ->> 'mimetype' = v_copy.mime_type) then
    raise exception 'the hard copy has not been uploaded yet' using errcode = 'P0001';
  end if;

  update public.contact_report_hard_copies set attached_at = v_at where id = v_copy.id;

  perform public.write_audit(v_report.tenant_id, 'attach_contact_report_hard_copy', 'contact_report_hard_copies',
                             v_copy.id::text, null,
                             jsonb_build_object('reference', v_report.reference, 'mime_type', v_copy.mime_type,
                                                'size_bytes', v_copy.size_bytes),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('report_id', v_report.id, 'reference', v_report.reference, 'attached_at', v_at));
end;
$function$;
revoke all on function public.request_contact_report_hard_copy(uuid, uuid, text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.request_contact_report_hard_copy(uuid, uuid, text, bigint) to authenticated;
revoke all on function public.attach_contact_report_hard_copy(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.attach_contact_report_hard_copy(uuid, uuid) to authenticated;
