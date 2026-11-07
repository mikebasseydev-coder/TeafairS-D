-- Addendum A8 Task 2 (§5.1, §5.2, §6.3): insurers and their dated products
-- (two-person approval, one approved product per kind on any day), the shop
-- owner's consent code for sharing a policy, policy submission, review and
-- withdrawal, and the cover status helpers Task 3's quote uses.
--
-- Policies and products are platform-level: every audit row here is
-- tenant-null (a policy is the shop's, and the tenant's ZSMs read audit_logs).

-- ── insurers ────────────────────────────────────────────────────────────
create or replace function public.register_monvelo_insurer(p_idempotency_key uuid, p_code text, p_legal_name text,
                                                           p_naicom_licence_no text, p_api_provider text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_row   public.monvelo_insurers;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'register_monvelo_insurer', jsonb_build_object(
    'code', p_code, 'legal_name', p_legal_name, 'naicom_licence_no', p_naicom_licence_no, 'api_provider', p_api_provider));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_code is null or p_code !~ '^[A-Z0-9_]{2,32}$' then
    raise exception 'an insurer code is 2-32 upper-case letters, digits or underscores' using errcode = 'P0001';
  end if;
  if coalesce(btrim(p_legal_name), '') = '' or coalesce(btrim(p_naicom_licence_no), '') = '' then
    raise exception 'an insurer needs its legal name and NAICOM licence number' using errcode = 'P0001';
  end if;
  if p_api_provider is null or p_api_provider not in ('MOCK', 'MYCOVER', 'MANUAL') then
    raise exception 'the API provider is MOCK, MYCOVER or MANUAL' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.monvelo_insurers i where i.code = p_code) then
    raise exception 'an insurer with that code is already registered' using errcode = 'P0001';
  end if;

  insert into public.monvelo_insurers (code, legal_name, naicom_licence_no, api_provider, created_by)
  values (p_code, btrim(p_legal_name), btrim(p_naicom_licence_no), p_api_provider, v_uid)
  returning * into v_row;
  perform public.write_audit(null, 'register_monvelo_insurer', 'monvelo_insurers', v_row.id::text, null,
                             to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('insurer_id', v_row.id, 'status', v_row.status));
end;
$$;

create or replace function public.set_monvelo_insurer_status(p_idempotency_key uuid, p_insurer_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_insurers;
  v_after  public.monvelo_insurers;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_insurer_status',
    jsonb_build_object('insurer_id', p_insurer_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('ACTIVE', 'SUSPENDED') then
    raise exception 'an insurer is ACTIVE or SUSPENDED' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_insurers where id = p_insurer_id for update;
  if not found then
    raise exception 'insurer not found' using errcode = 'P0001';
  end if;
  update public.monvelo_insurers set status = p_status where id = p_insurer_id returning * into v_after;
  perform public.write_audit(null, 'set_monvelo_insurer_status', 'monvelo_insurers', p_insurer_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('insurer_id', p_insurer_id, 'status', p_status));
end;
$$;

-- ── products: proposed by one operator, approved by another ──────────────
create or replace function public.propose_monvelo_insurance_product(p_idempotency_key uuid, p_insurer_id uuid,
  p_kind text, p_rate_bps integer, p_facilitator_fee_bps integer, p_valid_from date, p_valid_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_row   public.monvelo_insurance_products;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'propose_monvelo_insurance_product', jsonb_build_object(
    'insurer_id', p_insurer_id, 'kind', p_kind, 'rate_bps', p_rate_bps, 'facilitator_fee_bps', p_facilitator_fee_bps,
    'valid_from', p_valid_from, 'valid_to', p_valid_to));
  if v_prior is not null then
    return v_prior;
  end if;
  if not exists (select 1 from public.monvelo_insurers i where i.id = p_insurer_id) then
    raise exception 'insurer not found' using errcode = 'P0001';
  end if;
  if p_kind is null or p_kind not in ('GIT', 'STORAGE') then
    raise exception 'a product is GIT or STORAGE' using errcode = 'P0001';
  end if;
  if p_rate_bps is null or p_rate_bps not between 1 and 1000 then
    raise exception 'a premium rate is 1 to 1000 basis points' using errcode = 'P0001';
  end if;
  if p_facilitator_fee_bps is null or p_facilitator_fee_bps not between 0 and 10000 then
    raise exception 'the facilitator fee is 0 to 10000 basis points of the premium' using errcode = 'P0001';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to <= p_valid_from) then
    raise exception 'a product needs a start date before its end date' using errcode = 'P0001';
  end if;

  insert into public.monvelo_insurance_products (insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, valid_to,
                                                 proposed_by)
  values (p_insurer_id, p_kind, p_rate_bps, p_facilitator_fee_bps, p_valid_from, p_valid_to, v_uid)
  returning * into v_row;
  perform public.write_audit(null, 'propose_monvelo_insurance_product', 'monvelo_insurance_products', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('product_id', v_row.id, 'status', v_row.status));
end;
$$;

create or replace function public.approve_monvelo_insurance_product(p_idempotency_key uuid, p_product_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_insurance_products;
  v_after  public.monvelo_insurance_products;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_insurance_product',
    jsonb_build_object('product_id', p_product_id));
  if v_prior is not null then
    return v_prior;
  end if;
  select * into v_before from public.monvelo_insurance_products where id = p_product_id;
  if not found then
    raise exception 'product not found' using errcode = 'P0001';
  end if;
  if v_before.proposed_by = v_uid then
    raise exception 'a product is approved by an operator other than its proposer' using errcode = '42501';
  end if;
  -- one approved product per kind on any day: serialise approvals of a kind
  perform pg_advisory_xact_lock(hashtextextended('monvelo_insurance_product:' || v_before.kind, 0));
  select * into v_before from public.monvelo_insurance_products where id = p_product_id for update;
  if v_before.status <> 'PROPOSED' then
    raise exception 'only a PROPOSED product can be approved' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_insurers i where i.id = v_before.insurer_id and i.status = 'ACTIVE') then
    raise exception 'the insurer is suspended' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.monvelo_insurance_products p
              where p.kind = v_before.kind and p.status = 'APPROVED'
                and daterange(p.valid_from, p.valid_to) && daterange(v_before.valid_from, v_before.valid_to)) then
    raise exception 'another approved % product covers some of those dates', v_before.kind using errcode = 'P0001';
  end if;

  update public.monvelo_insurance_products set status = 'APPROVED', approved_by = v_uid, approved_at = now()
   where id = p_product_id returning * into v_after;
  perform public.write_audit(null, 'approve_monvelo_insurance_product', 'monvelo_insurance_products', p_product_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('product_id', p_product_id, 'status', 'APPROVED'));
end;
$$;

create or replace function public.withdraw_monvelo_insurance_product(p_idempotency_key uuid, p_product_id uuid,
                                                                     p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_insurance_products;
  v_after  public.monvelo_insurance_products;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'withdraw_monvelo_insurance_product',
    jsonb_build_object('product_id', p_product_id, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;
  if coalesce(char_length(btrim(p_reason)), 0) not between 5 and 1000 then
    raise exception 'a withdrawal needs a reason of 5 to 1000 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_insurance_products where id = p_product_id for update;
  if not found then
    raise exception 'product not found' using errcode = 'P0001';
  end if;
  if v_before.status = 'WITHDRAWN' then
    raise exception 'the product is already withdrawn' using errcode = 'P0001';
  end if;
  -- financings already locked to it keep their cover (A8 §6.2: the quote is locked at claim)
  update public.monvelo_insurance_products
     set status = 'WITHDRAWN', withdrawn_by = v_uid, withdrawn_at = now(), withdraw_reason = btrim(p_reason)
   where id = p_product_id returning * into v_after;
  perform public.write_audit(null, 'withdraw_monvelo_insurance_product', 'monvelo_insurance_products', p_product_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('product_id', p_product_id, 'status', 'WITHDRAWN'));
end;
$$;

-- ── the field agent's reach over a shop's enrolment ─────────────────────
-- The caller (a tenant_users row) covers the area: an ASA of that area, or a
-- ZSA whose zone holds the area's territory.
create or replace function public.monvelo_covers_area(p_me public.tenant_users, p_area_id uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.areas a
      join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
     where a.id = p_area_id and a.tenant_id = p_me.tenant_id
       and ((p_me.role = 'ASA' and p_me.area_id = a.id) or (p_me.role = 'ZSA' and p_me.zone_id = t.zone_id)));
$$;
revoke all on function public.monvelo_covers_area(public.tenant_users, uuid) from public, anon, authenticated, service_role;

-- ── the shop owner's consent to share a policy ──────────────────────────
-- As start_monvelo_consent (20261028120600), for a shop already ACTIVE-ly
-- enrolled in the caller's tenant and area; the code reaches the owner's
-- verified phone through the monvelo-shop-consent gateway (Task 9).
create or replace function public.start_monvelo_policy_consent(p_idempotency_key uuid, p_gateway_proof text,
                                                               p_shop_id uuid, p_area_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_shop  public.retail_shops;
  v_phone text;
  v_draw  bigint;
  v_code  text;
  v_row   public.monvelo_consent_challenges;
  v_reply jsonb;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_policy_consent',
    jsonb_build_object('shop_id', p_shop_id, 'area_id', p_area_id));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if not public.monvelo_covers_area(v_me, p_area_id) then
    raise exception 'that area is not yours' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id and e.area_id = p_area_id
                    and e.status = 'ACTIVE') then
    raise exception 'the shop is not enrolled in that area' using errcode = '42501';
  end if;
  select * into v_shop from public.retail_shops where id = p_shop_id;
  if v_shop.owner_id is null then
    raise exception 'this shop has no owner on record to give consent' using errcode = 'P0001';
  end if;
  select p.phone_number into v_phone
    from public.profiles p join auth.users u on u.id = p.id
   where p.id = v_shop.owner_id and u.phone_confirmed_at is not null;
  if v_phone is null then
    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('start_monvelo_policy_consent:' || p_shop_id, 0));
  if (select count(*) from public.monvelo_consent_challenges c
       where c.shop_id = p_shop_id and c.purpose = 'SHOP_POLICY' and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this shop; try again later' using errcode = 'P0001';
  end if;

  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.monvelo_consent_challenges (tenant_id, shop_id, area_id, code_hash, expires_at, issued_by, purpose)
  values (v_me.tenant_id, p_shop_id, p_area_id, extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          now() + c_ttl, v_me.profile_id, 'SHOP_POLICY')
  returning * into v_row;
  perform public.write_audit(null, 'start_monvelo_policy_consent', 'monvelo_consent_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_phone', v_phone));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$$;

-- ── submission: the owner's code read out, checked and consumed here ────
create or replace function public.submit_monvelo_shop_policy(p_idempotency_key uuid, p_challenge_id uuid, p_code text,
  p_insurer_name text, p_policy_number text, p_covers_fire_perils boolean, p_covers_burglary boolean,
  p_sum_insured numeric, p_lender_interest_endorsed boolean, p_starts_on date, p_expires_on date,
  p_document_path text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_ch     public.monvelo_consent_challenges;
  v_number text := upper(btrim(p_policy_number));
  v_row    public.monvelo_shop_policies;
begin
  -- the code is never part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'submit_monvelo_shop_policy', jsonb_build_object(
    'challenge_id', p_challenge_id, 'insurer_name', p_insurer_name, 'policy_number', p_policy_number,
    'covers_fire_perils', p_covers_fire_perils, 'covers_burglary', p_covers_burglary, 'sum_insured', p_sum_insured,
    'lender_interest_endorsed', p_lender_interest_endorsed, 'starts_on', p_starts_on, 'expires_on', p_expires_on,
    'document_path', p_document_path));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_ch from public.monvelo_consent_challenges where id = p_challenge_id for update;
  if not found or v_ch.tenant_id <> v_me.tenant_id or v_ch.purpose <> 'SHOP_POLICY' then
    raise exception 'unknown consent code request' using errcode = '42501';
  end if;
  if v_ch.issued_by <> v_me.profile_id then
    raise exception 'this consent code was requested by someone else' using errcode = '42501';
  end if;
  if not public.monvelo_covers_area(v_me, v_ch.area_id) then
    raise exception 'that area is not yours' using errcode = '42501';
  end if;

  -- the policy's own fields, before the code is spent
  if coalesce(btrim(p_insurer_name), '') = '' or coalesce(v_number, '') = '' or char_length(v_number) > 64 then
    raise exception 'the insurer''s name and the policy number are required' using errcode = 'P0001';
  end if;
  if p_covers_fire_perils is null or p_covers_burglary is null or p_lender_interest_endorsed is null then
    raise exception 'say whether the policy covers fire, burglary, and names Monvelo lenders' using errcode = 'P0001';
  end if;
  if p_sum_insured is null or round(p_sum_insured, 2) <= 0 then
    raise exception 'the sum insured must be positive' using errcode = 'P0001';
  end if;
  if p_starts_on is null or p_expires_on is null or p_expires_on <= p_starts_on then
    raise exception 'the policy must expire after it starts' using errcode = 'P0001';
  end if;
  if p_expires_on <= public.monvelo_today() then
    raise exception 'this policy has already expired' using errcode = 'P0001';
  end if;
  if p_document_path is null or p_document_path not like v_ch.shop_id::text || '/%'
     or not exists (select 1 from storage.objects o
                     where o.bucket_id = 'monvelo-shop-policies' and o.name = p_document_path) then
    raise exception 'upload the certificate first' using errcode = 'P0001';
  end if;

  -- the owner's code (wrong, expired, locked and spent codes are data, so the counter commits)
  if v_ch.consumed_at is not null then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('submitted', false, 'reason', 'INVALID'));
  end if;
  if v_ch.failed_attempts >= c_max_attempts then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('submitted', false, 'reason', 'LOCKED'));
  end if;
  if v_ch.expires_at <= now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('submitted', false, 'reason', 'EXPIRED'));
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' or v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_consent_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(null, 'MONVELO_CONSENT_FAILED', 'monvelo_consent_challenges', v_ch.id::text, null,
                               jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'shop_id', v_ch.shop_id),
                               p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('submitted', false,
      'reason', case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('monvelo_shop_policy:' || lower(btrim(p_insurer_name)) || ':' || v_number, 0));
  if exists (select 1 from public.monvelo_shop_policies p
              where lower(btrim(p.insurer_name)) = lower(btrim(p_insurer_name)) and p.policy_number = v_number
                and p.status in ('PENDING', 'VERIFIED')) then
    raise exception 'this policy is already on record' using errcode = 'P0001';
  end if;

  update public.monvelo_consent_challenges set consumed_at = now() where id = v_ch.id;
  insert into public.monvelo_shop_policies (shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
    sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id)
  values (v_ch.shop_id, btrim(p_insurer_name), v_number, p_covers_fire_perils, p_covers_burglary, round(p_sum_insured, 2),
          p_lender_interest_endorsed, p_starts_on, p_expires_on, p_document_path, v_me.profile_id, v_ch.id)
  returning * into v_row;
  perform public.write_audit(null, 'submit_monvelo_shop_policy', 'monvelo_shop_policies', v_row.id::text, null,
                             to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('submitted', true, 'policy_id', v_row.id, 'status', v_row.status));
end;
$$;

-- ── review and withdrawal (MONVELO_OPERATOR) ────────────────────────────
create or replace function public.review_monvelo_shop_policy(p_idempotency_key uuid, p_policy_id uuid, p_verify boolean,
                                                             p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_shop_policies;
  v_after  public.monvelo_shop_policies;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'review_monvelo_shop_policy',
    jsonb_build_object('policy_id', p_policy_id, 'verify', p_verify, 'note', p_note));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_verify is null or char_length(p_note) > 1000 then
    raise exception 'a review is verify or reject, with a note of at most 1000 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_shop_policies where id = p_policy_id for update;
  if not found then
    raise exception 'policy not found' using errcode = 'P0001';
  end if;
  if v_before.submitted_by = v_uid then
    raise exception 'a policy is reviewed by someone other than its submitter' using errcode = '42501';
  end if;
  if v_before.status <> 'PENDING' then
    raise exception 'only a PENDING policy can be reviewed' using errcode = 'P0001';
  end if;
  if p_verify then
    -- A8 §5.2: fire and perils, burglary, the lender endorsement (§5.2.1), still in force
    if not (v_before.covers_fire_perils and v_before.covers_burglary) then
      raise exception 'a verified policy covers fire and special perils and burglary' using errcode = 'P0001';
    end if;
    if not v_before.lender_interest_endorsed then
      raise exception 'the policy must name lenders financing stock through Monvelo as loss payee' using errcode = 'P0001';
    end if;
    if v_before.expires_on <= public.monvelo_today() then
      raise exception 'the policy has expired' using errcode = 'P0001';
    end if;
  end if;

  update public.monvelo_shop_policies
     set status = case when p_verify then 'VERIFIED' else 'REJECTED' end,
         reviewed_by = v_uid, reviewed_at = now(), review_note = nullif(btrim(p_note), '')
   where id = p_policy_id returning * into v_after;
  perform public.write_audit(null, 'review_monvelo_shop_policy', 'monvelo_shop_policies', p_policy_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('policy_id', p_policy_id, 'status', v_after.status));
end;
$$;

create or replace function public.withdraw_monvelo_shop_policy(p_idempotency_key uuid, p_policy_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_before  public.monvelo_shop_policies;
  v_after   public.monvelo_shop_policies;
  v_fin     record;
  v_flagged integer := 0;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'withdraw_monvelo_shop_policy',
    jsonb_build_object('policy_id', p_policy_id, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;
  if coalesce(char_length(btrim(p_reason)), 0) not between 5 and 1000 then
    raise exception 'a withdrawal needs a reason of 5 to 1000 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_shop_policies where id = p_policy_id for update;
  if not found then
    raise exception 'policy not found' using errcode = 'P0001';
  end if;
  if v_before.status <> 'VERIFIED' then
    raise exception 'only a VERIFIED policy can be withdrawn' using errcode = 'P0001';
  end if;

  update public.monvelo_shop_policies
     set status = 'WITHDRAWN', withdrawn_at = now(), withdraw_reason = btrim(p_reason)
   where id = p_policy_id returning * into v_after;

  -- A8 §6.4: open financings locked to it keep SHOP_POLICY; the operator follows each up
  for v_fin in
    select f.id, f.funder_agent_id from public.monvelo_financing_cover c
      join public.monvelo_financings f on f.id = c.financing_id
     where c.shop_policy_id = p_policy_id
       and f.status in ('CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
     order by f.id
  loop
    perform public.monvelo_raise_flag('POLICY_WITHDRAWN_OPEN_FINANCING', v_fin.id, v_fin.funder_agent_id,
                                      jsonb_build_object('policy_id', p_policy_id));
    v_flagged := v_flagged + 1;
  end loop;

  perform public.write_audit(null, 'withdraw_monvelo_shop_policy', 'monvelo_shop_policies', p_policy_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('policy_id', p_policy_id, 'status', 'WITHDRAWN', 'flagged', v_flagged));
end;
$$;

-- ── a policy consent code never enrols a shop ───────────────────────────
-- Recreated from 20261029130050 (its latest body); the only change is the
-- purpose check beside the tenant check.
create or replace function public.enrol_monvelo_shop(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_version      constant text    := 'MV-SHARE-2026-10';
  c_max_attempts constant integer := 5;
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_ch      public.monvelo_consent_challenges;
  v_before  public.monvelo_shop_enrolments;
  v_after   public.monvelo_shop_enrolments;
  v_shopcode text;
  v_terr     uuid;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'enrol_monvelo_shop',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_ch from public.monvelo_consent_challenges where id = p_challenge_id for update;
  if not found or v_ch.tenant_id <> v_me.tenant_id or v_ch.purpose <> 'ENROLMENT' then
    raise exception 'unknown consent code request' using errcode = '42501';
  end if;
  if v_ch.issued_by <> v_me.profile_id then
    raise exception 'this consent code was requested by someone else' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the consent code must be 6 digits' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('enrol_monvelo_shop:' || v_ch.tenant_id || ':' || v_ch.shop_id, 0));
  select * into v_before from public.monvelo_shop_enrolments e
   where e.tenant_id = v_ch.tenant_id and e.shop_id = v_ch.shop_id for update;

  if v_ch.consumed_at is not null then
    if v_before.shop_id is not null and v_before.status = 'ACTIVE' and v_before.consent_challenge_id = v_ch.id then
      select shop_code into v_shopcode from public.retail_shops where id = v_ch.shop_id;
      return public.idempotency_complete(p_idempotency_key,
        jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
    end if;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'INVALID'));
  end if;
  select a.territory_id into v_terr from public.areas a where a.id = v_ch.area_id;
  perform public.assert_state_app_operational(v_ch.tenant_id, v_terr);
  if v_ch.failed_attempts >= c_max_attempts then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'LOCKED'));
  end if;
  if v_ch.expires_at <= now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'EXPIRED'));
  end if;

  if v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_consent_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(v_ch.tenant_id, 'MONVELO_CONSENT_FAILED', 'monvelo_consent_challenges', v_ch.id::text,
                               null, jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'shop_id', v_ch.shop_id),
                               p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false,
      'reason', case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end));
  end if;

  update public.monvelo_consent_challenges set consumed_at = now() where id = v_ch.id;
  if v_before.shop_id is not null and v_before.status in ('ACTIVE', 'SUSPENDED') then
    v_after := v_before;
  elsif v_before.shop_id is not null then
    update public.monvelo_shop_enrolments
       set status = 'ACTIVE', withdrawn_at = null, area_id = v_ch.area_id, recruited_by = v_ch.issued_by,
           consent_at = clock_timestamp(), consent_version = c_version, consent_challenge_id = v_ch.id
     where tenant_id = v_ch.tenant_id and shop_id = v_ch.shop_id
    returning * into v_after;
  else
    insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at,
                                                consent_version, consent_challenge_id, status)
    values (v_ch.tenant_id, v_ch.shop_id, v_ch.area_id, v_ch.issued_by, clock_timestamp(), c_version, v_ch.id, 'ACTIVE')
    returning * into v_after;
  end if;
  v_shopcode := public.monvelo_assign_shop_code(v_ch.shop_id);

  perform public.write_audit(v_ch.tenant_id, 'enrol_monvelo_shop', 'monvelo_shop_enrolments', v_ch.shop_id::text,
                             case when v_before.shop_id is null then null else to_jsonb(v_before) end,
                             to_jsonb(v_after) || jsonb_build_object('shop_code', v_shopcode), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
end;
$$;

-- ── the cover status (§5.2.2), internal ────────────────────────────────
-- The shop's open Monvelo principal across every tenant: what its own policy
-- has to cover if it is to exempt one more financing.
create or replace function public.monvelo_shop_open_principal(p_shop_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(f.principal), 0)::numeric(15,2)
    from public.monvelo_financings f
   where f.shop_id = p_shop_id
     and f.status in ('CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE');
$$;

-- VERIFIED (with the policy) only when a VERIFIED policy is in force today
-- and through p_through (Lagos dates), and its sum insured covers the open
-- principal plus p_principal. A verified policy that falls short reports
-- INSUFFICIENT; otherwise the most recent policy's status, or UNVERIFIED.
create or replace function public.monvelo_shop_cover_status(p_shop_id uuid, p_through timestamptz, p_principal numeric)
returns table (status text, policy_id uuid)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_open  numeric(15,2) := public.monvelo_shop_open_principal(p_shop_id);
  v_until date := (coalesce(p_through, now()) at time zone 'Africa/Lagos')::date;
  v_id    uuid;
  v_last  public.monvelo_shop_policies;
begin
  select p.id into v_id
    from public.monvelo_shop_policies p
   where p.shop_id = p_shop_id and p.status = 'VERIFIED'
     and p.starts_on <= public.monvelo_today() and p.expires_on >= v_until
     and p.sum_insured >= v_open + coalesce(p_principal, 0)
   order by p.expires_on desc, p.id
   limit 1;
  if v_id is not null then
    return query select 'VERIFIED'::text, v_id;
    return;
  end if;

  -- a verified policy that does not reach (dates or sum) outranks older or rejected rows
  select p.id into v_id from public.monvelo_shop_policies p
   where p.shop_id = p_shop_id and p.status = 'VERIFIED'
   order by p.expires_on desc, p.id limit 1;
  if v_id is not null then
    return query select 'INSUFFICIENT'::text, v_id;
    return;
  end if;

  select * into v_last from public.monvelo_shop_policies p
   where p.shop_id = p_shop_id order by p.created_at desc, p.id desc limit 1;
  if v_last.id is null then
    return query select 'UNVERIFIED'::text, null::uuid;
  else
    return query select v_last.status, v_last.id;
  end if;
end;
$$;

create or replace function public.monvelo_is_shop_covered(p_shop_id uuid, p_through timestamptz default now(),
                                                          p_principal numeric default 0)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select s.status = 'VERIFIED' from public.monvelo_shop_cover_status(p_shop_id, p_through, p_principal) s), false);
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.register_monvelo_insurer(uuid, text, text, text, text),
  public.set_monvelo_insurer_status(uuid, uuid, text),
  public.propose_monvelo_insurance_product(uuid, uuid, text, integer, integer, date, date),
  public.approve_monvelo_insurance_product(uuid, uuid),
  public.withdraw_monvelo_insurance_product(uuid, uuid, text),
  public.start_monvelo_policy_consent(uuid, text, uuid, uuid),
  public.submit_monvelo_shop_policy(uuid, uuid, text, text, text, boolean, boolean, numeric, boolean, date, date, text),
  public.review_monvelo_shop_policy(uuid, uuid, boolean, text),
  public.withdraw_monvelo_shop_policy(uuid, uuid, text),
  public.monvelo_shop_open_principal(uuid),
  public.monvelo_shop_cover_status(uuid, timestamptz, numeric),
  public.monvelo_is_shop_covered(uuid, timestamptz, numeric)
  from public, anon, authenticated, service_role;
grant execute on function public.register_monvelo_insurer(uuid, text, text, text, text),
  public.set_monvelo_insurer_status(uuid, uuid, text),
  public.propose_monvelo_insurance_product(uuid, uuid, text, integer, integer, date, date),
  public.approve_monvelo_insurance_product(uuid, uuid),
  public.withdraw_monvelo_insurance_product(uuid, uuid, text),
  public.start_monvelo_policy_consent(uuid, text, uuid, uuid),
  public.submit_monvelo_shop_policy(uuid, uuid, text, text, text, boolean, boolean, numeric, boolean, date, date, text),
  public.review_monvelo_shop_policy(uuid, uuid, boolean, text),
  public.withdraw_monvelo_shop_policy(uuid, uuid, text)
  to authenticated;
