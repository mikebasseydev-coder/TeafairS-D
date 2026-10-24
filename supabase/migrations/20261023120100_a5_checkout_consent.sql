-- Addendum A5 §3.3, §3.5, §3.6 — consent and WhatsApp phone verification on
-- web orders. place_web_order is redefined (the 9-arg signature is dropped,
-- not overloaded) so there is no consent-free path.

-- ── web_phone_verifications (platform table) ────────────────────────────
-- RLS on, no policy, no grant: only the service_role RPCs below touch it.
create table public.web_phone_verifications (
  id                uuid primary key default gen_random_uuid(),
  phone             text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  code_hash         text not null,
  client_ip         inet,  -- start throttle only; never returned or audited
  expires_at        timestamptz not null,
  failed_attempts   integer not null default 0 check (failed_attempts >= 0),
  verified_at       timestamptz,
  token_hash        text unique,
  token_expires_at  timestamptz,
  consumed_at       timestamptz,
  created_at        timestamptz not null default now()
);
alter table public.web_phone_verifications enable row level security;
revoke all on public.web_phone_verifications from anon, authenticated, service_role;
create index idx_web_phone_verifications_phone on public.web_phone_verifications (phone, created_at);
create index idx_web_phone_verifications_ip on public.web_phone_verifications (client_ip, created_at);

-- ── consent columns ─────────────────────────────────────────────────────
alter table public.orders
  add column policy_version_tag text references public.refund_policies (version_tag) on delete restrict,
  add column policy_accepted_at timestamptz,
  -- ONLINE orders from the A5 cut-off on must carry consent; older rows are grandfathered
  add constraint orders_web_consent_complete
    check (channel <> 'ONLINE' or created_at < timestamptz '2026-10-23 00:00:00+00'
           or (policy_version_tag is not null and policy_accepted_at is not null));

alter table public.order_contacts
  add column consent_ip inet,
  add column phone_verified_at timestamptz,
  add column phone_verified_channel text check (phone_verified_channel = 'WHATSAPP');

-- ── start_web_phone_verification ────────────────────────────────────────
-- The gateway generates and sends the code; the database stores its hash and
-- enforces the throttles (3 per phone, 10 per IP, per hour).
create function public.start_web_phone_verification(p_phone text, p_code text, p_client_ip inet)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.web_phone_verifications;
begin
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the code must be 6 digits' using errcode = 'P0001';
  end if;
  if (select count(*) from public.web_phone_verifications
       where phone = p_phone and created_at > now() - interval '1 hour') >= 3
     or (p_client_ip is not null and (select count(*) from public.web_phone_verifications
                                       where client_ip = p_client_ip
                                         and created_at > now() - interval '1 hour') >= 10) then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  insert into public.web_phone_verifications (phone, code_hash, client_ip, expires_at)
  values (p_phone, extensions.crypt(p_code, extensions.gen_salt('bf', 8)), p_client_ip,
          now() + interval '10 minutes')
  returning * into v_row;

  return jsonb_build_object('verification_id', v_row.id, 'expires_at', v_row.expires_at);
end;
$$;

-- ── confirm_web_phone_verification ──────────────────────────────────────
-- A dead or exhausted verification RAISES. A WRONG CODE RETURNS
-- {verified:false, error:'That code is not right.', attempts_left} instead
-- of raising, like verify_otp: a raise would roll back the failed_attempts
-- increment and the 5-attempt limit would never bite. The gateway maps it to 422.
create function public.confirm_web_phone_verification(p_verification_id uuid, p_code text, p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.web_phone_verifications;
begin
  select * into v_row from public.web_phone_verifications where id = p_verification_id for update;
  if not found or v_row.expires_at <= now() or v_row.consumed_at is not null
     or v_row.verified_at is not null or v_row.failed_attempts >= 5 then
    raise exception 'Please verify your WhatsApp number again.' using errcode = 'P0001';
  end if;
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'a token hash is required' using errcode = 'P0001';
  end if;

  if p_code is null or p_code !~ '^[0-9]{6}$'
     or extensions.crypt(p_code, v_row.code_hash) <> v_row.code_hash then
    update public.web_phone_verifications set failed_attempts = failed_attempts + 1
     where id = v_row.id;
    return jsonb_build_object('verified', false, 'error', 'That code is not right.',
                              'attempts_left', greatest(4 - v_row.failed_attempts, 0));
  end if;

  update public.web_phone_verifications
     set verified_at = now(), token_hash = p_token_hash,
         token_expires_at = now() + interval '30 minutes'
   where id = v_row.id;
  return jsonb_build_object('verified', true);
end;
$$;

-- ── place_web_order ─────────────────────────────────────────────────────
-- The D1 body, plus: consent assertion and policy tag, sellable categories,
-- and a single-use WhatsApp verification token bound to the buyer's phone.
drop function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid);
create function public.place_web_order(
  p_idempotency_key  uuid,
  p_code             text,
  p_items            jsonb,
  p_customer         jsonb,
  p_utm              jsonb,
  p_payment_route    text,
  p_expected_total   numeric,
  p_checkout         jsonb,
  p_lga_id           uuid,
  p_accepted_refund_policy   boolean,  -- A5 §3.6
  p_policy_version_tag       text,     -- A5 §3.3
  p_client_ip                inet,     -- A5 §3.3
  p_phone_verification_token text      -- A5 §3.5
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior       jsonb;
  v_code        public.agent_codes;
  v_cart        jsonb;
  v_total       numeric(15,2);
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');
  v_terminal    public.fintech_terminals;
  v_route       public.web_route;  -- D1
  v_split       jsonb;             -- D1
  v_ref         text;
  v_order       public.orders;
  v_policy      public.refund_policies;          -- A5
  v_verif       public.web_phone_verifications;  -- A5
  v_now         timestamptz := now();
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total,
                       'lga_id', p_lga_id));  -- D1
  -- A5: the verification token and the client IP are left out of the request
  -- hash on purpose (as A3 leaves out its secret): a replay carries a token
  -- that is already consumed, and neither belongs in idempotency_logs.
  if v_prior is not null then
    return v_prior;  -- a replay keeps the original order and its original consent
  end if;

  -- A5 §3.6, §3.3: consent first, then the policy it was given against
  if p_accepted_refund_policy is distinct from true then
    raise exception 'You must accept the refund policy to place an order.' using errcode = 'P0001';
  end if;
  select * into v_policy from public.refund_policies where is_active;
  if not found or p_policy_version_tag is distinct from v_policy.version_tag then
    raise exception 'The refund policy has changed. Please review it and try again.' using errcode = 'P0001';
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_storefront_code(p_code);  -- D1: null or blank is codeless
  if p_payment_route = 'POS_AGENT' and v_code.terminal_id is null then
    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';
  end if;

  v_cart := public.web_price_cart(v_code, p_items);
  v_total := (v_cart ->> 'total')::numeric;
  if p_expected_total is distinct from v_total then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A5 §3.1: every line must be in a category the active policy covers
  if exists (select 1 from jsonb_array_elements(v_cart -> 'lines') l
               join public.central_products cp
                 on cp.tenant_id = v_code.tenant_id and cp.sku_code = l ->> 'sku_code'
              where not public.web_category_sellable(cp.sale_category)) then
    raise exception 'This product is not available to order yet.' using errcode = 'P0001';
  end if;

  if v_name is null then
    raise exception 'your name is required' using errcode = 'P0001';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'the email address is not valid' using errcode = 'P0001';
  end if;
  if v_address is null then
    raise exception 'a delivery address is required' using errcode = 'P0001';
  end if;
  if p_payment_route = 'PAYSTACK_WEB' and (
       coalesce(p_checkout ->> 'reference', '') = '' or coalesce(p_checkout ->> 'authorization_url', '') = '') then
    raise exception 'checkout details are missing' using errcode = 'P0001';
  end if;

  -- D1 Decision 6: the split Paystack was initialised with must be this
  -- quote split, or both JSON null. A missing key is not JSON null.
  v_split := nullif(v_cart -> 'split', 'null'::jsonb);
  if p_payment_route = 'PAYSTACK_WEB' and (p_checkout -> 'split') is distinct from
       (case when v_split is null then 'null'::jsonb
             else jsonb_build_object('subaccount_code', v_split -> 'subaccount_code',
                                     'commission_bps',  v_split -> 'commission_bps',
                                     'partner_share',   v_split -> 'partner_share') end) then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- A5 §3.5: the buyer proved this number on WhatsApp. The token is bound to
  -- the phone, single use and short lived; the row is locked and consumed.
  select * into v_verif from public.web_phone_verifications
   where token_hash = encode(extensions.digest(coalesce(p_phone_verification_token, ''), 'sha256'), 'hex')
     and verified_at is not null and consumed_at is null
     and token_expires_at > v_now and phone = v_phone
   for update;
  if not found then
    raise exception 'Please verify your WhatsApp number again.' using errcode = 'P0001';
  end if;
  update public.web_phone_verifications set consumed_at = v_now where id = v_verif.id;

  -- D1 §4: territory, warehouse and accountable person, or a refusal
  v_route := public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  if v_code.terminal_id is not null then
    select * into v_terminal from public.fintech_terminals
     where tenant_id = v_code.tenant_id and id = v_code.terminal_id;
  end if;

  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform
  loop
    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                         from generate_series(1, 6));
    exit when not exists (select 1 from public.orders where public_reference = v_ref);
  end loop;

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, status,
                             agent_code_id, attributed_agent_id, attributed_terminal_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id,
                             policy_version_tag, policy_accepted_at)
  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref,
          p_lga_id, v_route.territory_id, v_route.warehouse_id,
          v_policy.version_tag, v_now)
  returning * into v_order;

  -- A2; D1: the contacts territory is the order territory
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address,
                                     consent_ip, phone_verified_at, phone_verified_channel)
  values (v_order.id, v_order.tenant_id, v_route.territory_id, v_name, v_phone, v_email, v_address,
          p_client_ip, v_verif.verified_at, 'WHATSAPP');  -- A5: the IP lives on A2's table only

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, fintech_partner_id, fintech_terminal_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload,
                                 split_subaccount_code, split_bps, split_amount)
    values (v_order.tenant_id, v_order.id, v_route.accountable_id, v_terminal.partner_id, v_code.terminal_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')),
            v_split ->> 'subaccount_code', (v_split ->> 'commission_bps')::integer,
            (v_split ->> 'partner_share')::numeric);
  end if;

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null),
                               -- A5: the consent and the fact of verification, never the IP
                               'policy_version_tag', v_order.policy_version_tag,
                               'policy_accepted_at', v_order.policy_accepted_at,
                               'phone_verified', true),
                             p_idempotency_key, 'WEB', v_route.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.start_web_phone_verification(text, text, inet) from public, anon, authenticated, service_role;
revoke all on function public.confirm_web_phone_verification(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid, boolean, text, inet, text)
  from public, anon, authenticated, service_role;
grant execute on function public.start_web_phone_verification(text, text, inet) to service_role;
grant execute on function public.confirm_web_phone_verification(uuid, text, text) to service_role;
grant execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid, boolean, text, inet, text)
  to service_role;

-- ── cleanup_web_phone_verifications (cron) ──────────────────────────────
-- Retention: a verification is useful for its 10-minute code, its 30-minute
-- token and the 1-hour throttle windows. After 7 days the row (phone, code
-- hash, client IP) goes; the order's consent facts stay in order_contacts.
-- Transient rows: no audit. Internal: no grant. Returns the rows deleted.
create function public.cleanup_web_phone_verifications()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  delete from public.web_phone_verifications where created_at < now() - interval '7 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.cleanup_web_phone_verifications() from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('cleanup-web-phone-verifications', '50 0 * * *',
  $$select public.cleanup_web_phone_verifications()$$);
