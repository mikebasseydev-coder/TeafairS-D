-- Addendum A5 §7 — delivery log for the WhatsApp-first message router.
-- Platform table: never stores the message, the code or the full phone number.
create table public.notification_logs (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references public.tenants (id) on delete restrict,
  purpose         text not null check (purpose in ('OTP', 'DELIVERY_CODE', 'DELIVERY_CODE_RESEND', 'PHONE_VERIFY')),
  channel         text not null check (channel in ('WHATSAPP', 'SMS')),
  status          text not null check (status in ('SENT', 'FAILED')),
  whatsapp_error  text,  -- provider error code only
  phone_last4     text not null check (phone_last4 ~ '^[0-9]{4}$'),
  related_id      uuid,  -- the challenge or order
  created_at      timestamptz not null default now()
);
alter table public.notification_logs enable row level security;
revoke all on public.notification_logs from anon, authenticated, service_role;
grant select on public.notification_logs to authenticated;
create index idx_notification_logs_tenant on public.notification_logs (tenant_id, created_at desc);

create policy notification_logs_select_zsm on public.notification_logs
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])));

-- Internal RPC called by the router (service_role only).
create function public.log_message_delivery(
  p_tenant_id uuid, p_purpose text, p_channel text, p_status text,
  p_phone text, p_related_id uuid, p_whatsapp_error text
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_phone is null or p_phone !~ '[0-9]{4}$' then
    raise exception 'a phone number ending in four digits is required' using errcode = 'P0001';
  end if;
  insert into public.notification_logs
    (tenant_id, purpose, channel, status, whatsapp_error, phone_last4, related_id)
  values
    (p_tenant_id, p_purpose, p_channel, p_status, left(p_whatsapp_error, 64), right(p_phone, 4), p_related_id);
end;
$$;
revoke all on function public.log_message_delivery(uuid, text, text, text, text, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.log_message_delivery(uuid, text, text, text, text, uuid, text) to service_role;
