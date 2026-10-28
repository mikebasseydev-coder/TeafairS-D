-- A6 §15.4: the tenant role FINTECH_AGENT is renamed POS_AGENT. Every body that
-- held the literal is recreated (same signature, same grants); the territory
-- check constraint follows the enum value by itself.

alter type public.tenant_role_enum rename value 'FINTECH_AGENT' to 'POS_AGENT';

create or replace function public.issue_otp(p_idempotency_key uuid, p_subject_id uuid, p_purpose otp_purpose_enum, p_gateway_proof text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_ttl           constant interval := interval '5 minutes';
  c_window        constant interval := interval '10 minutes';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(array['DSA', 'POS_AGENT']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_phone text;
  v_code  text;
  v_draw  bigint;
  v_row  public.otp_challenges;
begin
  perform public.assert_gateway_proof(p_gateway_proof);
  -- neither the proof nor the code is part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'issue_otp',
    jsonb_build_object('subject_id', p_subject_id, 'purpose', p_purpose));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
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

  -- uniform 6 digits: a 32-bit draw, rejection-sampled below the largest
  -- multiple of 10^6 so the modulo has no bias (as otp-issue's code.ts did)
  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.otp_challenges (tenant_id, subject_id, purpose, code_hash, destination_phone,
                                     issued_by, expires_at)
  values (v_me.tenant_id, p_subject_id, p_purpose, extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          v_phone, v_me.profile_id, now() + c_ttl)
  returning * into v_row;

  perform public.write_audit(v_me.tenant_id, 'issue_otp', 'otp_challenges', v_row.id::text,
                             -- no full phone number in an audit row (A5 rule; Spec A wrote it)
                             null, to_jsonb(v_row) - 'code_hash' - 'destination_phone', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id',      v_row.id,
    'expires_at',        v_row.expires_at,
    'destination_phone', v_row.destination_phone,
    'replayed',          false))
    || jsonb_build_object('code', v_code);
end;
$function$

;

create or replace function public.verify_otp(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_max_attempts constant integer := 5;
  v_me     public.tenant_users := public.assert_tenant_role(array['DSA', 'POS_AGENT']::public.tenant_role_enum[]);
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
$function$

;

create or replace function public.invite_tenant_user(p_idempotency_key uuid, p_phone_number text, p_role tenant_role_enum, p_territory_id uuid, p_reports_to_id uuid, p_area_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_phone   text := '+' || ltrim(btrim(coalesce(p_phone_number, '')), '+');
  v_profile uuid;
  v_member  public.tenant_users;
  v_zone    uuid;
  v_area    uuid;
begin
  if p_role = 'ZSM' then
    raise exception 'only a platform administrator appoints a ZSM' using errcode = '42501';
  end if;
  if p_territory_id is not null and not exists (
    select 1 from public.territories t
    where t.id = p_territory_id and t.tenant_id = v_me.tenant_id and t.zone_id = v_me.zone_id
  ) then
    raise exception 'a ZSM invites into territories of their own zone only' using errcode = '42501';
  end if;
  if p_role = 'ASA' and p_territory_id is null then
    raise exception 'ASA requires a territory' using errcode = 'P0001';
  end if;
  if p_role = 'ASA' and p_area_id is not null and not exists (
    select 1 from public.areas a
    where a.id = p_area_id and a.tenant_id = v_me.tenant_id and a.territory_id = p_territory_id
  ) then
    raise exception 'the area is not inside the territory' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'invite_tenant_user',
    jsonb_build_object('phone_number', v_phone, 'role', p_role,
                       'territory_id', p_territory_id, 'reports_to_id', p_reports_to_id,
                       'area_id', p_area_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select p.id into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone_number = v_phone
    and u.phone_confirmed_at is not null;
  if v_profile is null then
    raise exception 'no Teafair account with a verified phone exists for %', v_phone using errcode = 'P0001';
  end if;
  if p_role in ('TM', 'ASM', 'DSM', 'DSA', 'POS_AGENT', 'ASA') and p_territory_id is null then
    raise exception '% requires a territory', p_role using errcode = 'P0001';
  end if;
  if p_role in ('ASM', 'DSM', 'DSA', 'ZSA', 'ASA') and p_reports_to_id is null then
    raise exception '% must report to someone', p_role using errcode = 'P0001';
  end if;
  if p_reports_to_id is not null and not exists (
    select 1 from public.tenant_users tu
    where tu.id = p_reports_to_id and tu.tenant_id = v_me.tenant_id and tu.status = 'ACTIVE'
  ) then
    raise exception 'reports_to must be an active member of this tenant' using errcode = 'P0001';
  end if;

  if p_role = 'ZSA' then
    v_zone := v_me.zone_id;
    if not exists (
      select 1 from public.tenant_users tu
      where tu.id = p_reports_to_id and tu.tenant_id = v_me.tenant_id
        and tu.role = 'ZSM' and tu.zone_id = v_zone
    ) then
      raise exception 'a ZSA reports to a ZSM of the zone' using errcode = 'P0001';
    end if;
  elsif p_role = 'ASA' then
    if p_area_id is null then
      raise exception 'ASA requires an area' using errcode = 'P0001';
    end if;
    v_area := p_area_id;
    if not exists (
      select 1 from public.tenant_users tu
      where tu.id = p_reports_to_id and tu.tenant_id = v_me.tenant_id
        and tu.role in ('ASM', 'TM') and tu.territory_id = p_territory_id
    ) then
      raise exception 'an ASA reports to an ASM or TM of the territory' using errcode = 'P0001';
    end if;
  end if;

  insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status)
  values (v_me.tenant_id, v_profile, p_role, v_zone, p_territory_id, v_area, p_reports_to_id, 'INVITED')
  returning * into v_member;

  insert into public.notifications (tenant_id, user_id, kind, title, payload)
  values (v_me.tenant_id, v_profile, 'TENANT_INVITE', 'You have been invited to join a team',
          jsonb_build_object('tenant_user_id', v_member.id, 'role', p_role));

  perform public.write_audit(v_me.tenant_id, 'invite_tenant_user', 'tenant_users', v_member.id::text,
                             null, to_jsonb(v_member) - 'pin_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_member.id, 'status', v_member.status));
end;
$function$

;

create or replace function public.set_terminal_venue(p_idempotency_key uuid, p_terminal_id uuid, p_venue_channel venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'POS_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.fintech_terminals;
  v_after    public.fintech_terminals;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_terminal_venue',
    jsonb_build_object('terminal_id', p_terminal_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.fintech_terminals
   where id = p_terminal_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'POS_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.fintech_terminals
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_terminal_venue', 'fintech_terminals', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('terminal_id', v_after.id));
end;
$function$

;

