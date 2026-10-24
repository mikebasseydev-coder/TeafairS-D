-- Auth audit M1 — Supabase Auth's own codes (phone sign-in) go out through
-- the send-auth-sms hook, which sends them with the A5 message router
-- (WhatsApp first, SMS fallback, notification_logs) and only to people
-- Teafair has let in.
--
-- auth_sms_allowed(user, phone): the account's profile holds exactly this
-- phone, and the person is a platform administrator or has an ACTIVE or
-- INVITED membership somewhere (an invitee signs in to accept). A removed
-- member gets no code. Self-serve sign-up is off, so every account was made
-- by the Admin API.

alter table public.notification_logs drop constraint notification_logs_purpose_check;
alter table public.notification_logs add constraint notification_logs_purpose_check
  check (purpose in ('OTP', 'DELIVERY_CODE', 'DELIVERY_CODE_RESEND', 'PHONE_VERIFY', 'AUTH_OTP'));

create function public.auth_sms_allowed(p_user_id uuid, p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.phone_number = '+' || ltrim(btrim(coalesce(p_phone, '')), '+')
      and (p.platform_role is not null
           or exists (select 1 from public.tenant_users tu
                      where tu.profile_id = p.id and tu.status in ('ACTIVE', 'INVITED')))
  );
$$;
revoke all on function public.auth_sms_allowed(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.auth_sms_allowed(uuid, text) to service_role;
