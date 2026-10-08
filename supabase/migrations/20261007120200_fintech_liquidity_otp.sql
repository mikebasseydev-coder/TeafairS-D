-- Spec A §6.11 — the shop-owner OTP: the second proof of the dual-validation
-- handshake. The gateway generates the code and sends the SMS; the database
-- stores only a bcrypt hash and owns every control:
--   single use (consumed_at) · 5-minute expiry · 5 wrong attempts lock the
--   challenge · at most 3 codes per subject and purpose in 10 minutes.
--
-- The code is never part of the idempotency request: request_hash is a plain
-- sha256, and a 6-digit code would fall to a lookup table.
--
-- verify_otp RETURNS its verdict rather than raising, so failed_attempts
-- persists; a raise would roll the counter back. A verified challenge is
-- consumed; Spec D's complete_pos_backed_order binds it to a payment once.

create or replace function public.issue_otp(
  p_idempotency_key uuid,
  p_subject_id      uuid,
  p_purpose         public.otp_purpose_enum,
  p_code            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_ttl           constant interval := interval '5 minutes';
  c_window        constant interval := interval '10 minutes';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(array['DSA', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_phone text;
  v_row   public.otp_challenges;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'issue_otp',
    jsonb_build_object('subject_id', p_subject_id, 'purpose', p_purpose));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'code must be 6 digits' using errcode = 'P0001';
  end if;

  select p.phone_number into v_phone
  from public.tenant_users tu
  join public.profiles p on p.id = tu.profile_id
  where tu.tenant_id = v_me.tenant_id
    and tu.profile_id = p_subject_id
    and tu.role = 'RETAIL_SHOP_OWNER'
    and tu.status = 'ACTIVE';
  if v_phone is null then
    raise exception 'subject is not an active shop owner in this tenant' using errcode = 'P0001';
  end if;

  -- serialise issuance per subject and purpose, so concurrent requests cannot
  -- both slip under the limit
  perform pg_advisory_xact_lock(hashtextextended('issue_otp:' || p_subject_id || ':' || p_purpose, 0));
  if (select count(*) from public.otp_challenges c
       where c.subject_id = p_subject_id
         and c.purpose = p_purpose
         and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this shop owner; try again later' using errcode = 'P0001';
  end if;

  insert into public.otp_challenges (tenant_id, subject_id, purpose, code_hash, destination_phone,
                                     issued_by, expires_at)
  values (v_me.tenant_id, p_subject_id, p_purpose, extensions.crypt(p_code, extensions.gen_salt('bf', 8)),
          v_phone, v_me.profile_id, now() + c_ttl)
  returning * into v_row;

  perform public.write_audit(v_me.tenant_id, 'issue_otp', 'otp_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id',      v_row.id,
    'expires_at',        v_row.expires_at,
    'destination_phone', v_row.destination_phone,
    'replayed',          false));
end;
$$;

create or replace function public.verify_otp(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_me     public.tenant_users := public.assert_tenant_role(array['DSA', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_row    public.otp_challenges;
  v_result jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'verify_otp',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_row
  from public.otp_challenges c
  where c.id = p_challenge_id
    and c.tenant_id = v_me.tenant_id
    and c.issued_by = v_me.profile_id
  for update;
  if not found then
    raise exception 'challenge not found' using errcode = 'P0001';
  end if;

  if v_row.consumed_at is not null then
    v_result := jsonb_build_object('verified', false, 'reason', 'CONSUMED');
  elsif v_row.locked_until is not null then
    v_result := jsonb_build_object('verified', false, 'reason', 'LOCKED');
  elsif v_row.expires_at <= now() then
    v_result := jsonb_build_object('verified', false, 'reason', 'EXPIRED');
  elsif p_code ~ '^[0-9]{6}$' and extensions.crypt(p_code, v_row.code_hash) = v_row.code_hash then
    update public.otp_challenges set consumed_at = now() where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'OTP_VERIFIED', 'otp_challenges', v_row.id::text,
                               null, jsonb_build_object('purpose', v_row.purpose), p_idempotency_key);
    v_result := jsonb_build_object('verified', true, 'challenge_id', v_row.id,
                                   'purpose', v_row.purpose, 'subject_id', v_row.subject_id);
  else
    v_row.failed_attempts := v_row.failed_attempts + 1;
    update public.otp_challenges
       set failed_attempts = v_row.failed_attempts,
           -- a locked challenge stays locked until it would have expired anyway
           locked_until = case when v_row.failed_attempts >= c_max_attempts
                               then greatest(v_row.expires_at, now()) end
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'OTP_FAILED', 'otp_challenges', v_row.id::text,
                               null, jsonb_build_object('failed_attempts', v_row.failed_attempts),
                               p_idempotency_key);
    v_result := jsonb_build_object('verified', false, 'reason', 'INVALID',
                                   'attempts_left', greatest(c_max_attempts - v_row.failed_attempts, 0));
  end if;

  return public.idempotency_complete(p_idempotency_key, v_result);
end;
$$;

grant execute on function public.issue_otp(uuid, uuid, public.otp_purpose_enum, text) to authenticated;
grant execute on function public.verify_otp(uuid, uuid, text) to authenticated;
