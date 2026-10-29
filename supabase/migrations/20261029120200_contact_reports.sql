-- Addendum A6 §16.4 (Monvelo Step 1c, Task 2) — contact reports.
-- One insert-only report per meeting or call, its decisions, the tenant
-- contacts in copy, and the send log (one PENDING delivery per recipient;
-- Step 6's sender is the only writer after that, and only of status columns).
-- A mistake is corrected by a report that supersedes the old one. A change in
-- the app cites a decision through assert_citable_decision.

-- ── contact_reports ─────────────────────────────────────────────────────
create table public.contact_reports (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  reference     text not null unique check (reference ~ '^CR-[A-Z2-7]{8}$'),
  met_at        timestamptz not null,
  channel       text not null check (channel in ('MEETING', 'CALL', 'VIDEO', 'MESSAGE')),
  attendees     jsonb not null check (jsonb_typeof(attendees) = 'array'),
  summary       text not null check (length(btrim(summary)) between 1 and 4000),
  filed_by      uuid not null references public.profiles (id) on delete restrict,
  filed_at      timestamptz not null default now(),
  supersedes_id uuid,
  unique (tenant_id, id),
  unique (supersedes_id),
  check (met_at <= filed_at),
  foreign key (tenant_id, supersedes_id) references public.contact_reports (tenant_id, id) on delete restrict
);
create index idx_contact_reports_tenant     on public.contact_reports (tenant_id, filed_at desc);
create index idx_contact_reports_filed_by   on public.contact_reports (filed_by);
create index idx_contact_reports_supersedes on public.contact_reports (tenant_id, supersedes_id);

-- ── contact_report_decisions ────────────────────────────────────────────
create table public.contact_report_decisions (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  report_id     uuid not null,
  seq           integer not null check (seq >= 1),
  subject       text not null check (subject in ('BRAND_TERMS', 'MONVELO_SETTINGS', 'FEES', 'CATALOGUE', 'STOCK', 'OTHER')),
  decision_text text not null check (length(btrim(decision_text)) between 1 and 2000),
  created_at    timestamptz not null default now(),
  unique (report_id, seq),
  unique (tenant_id, id),
  foreign key (tenant_id, report_id) references public.contact_reports (tenant_id, id) on delete restrict
);
create index idx_contact_report_decisions_report on public.contact_report_decisions (tenant_id, report_id);

-- ── contact_report_recipients ───────────────────────────────────────────
create table public.contact_report_recipients (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  report_id    uuid not null,
  name         text not null check (length(btrim(name)) between 1 and 200),
  channel      text not null check (channel in ('WHATSAPP', 'EMAIL')),
  address      text not null,
  address_hint text not null,
  created_at   timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, report_id) references public.contact_reports (tenant_id, id) on delete restrict,
  check ((channel = 'WHATSAPP' and address ~ '^\+[1-9][0-9]{7,14}$')
      or (channel = 'EMAIL' and address ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'))
);
create index idx_contact_report_recipients_report on public.contact_report_recipients (tenant_id, report_id);

-- ── contact_report_deliveries (the send log) ────────────────────────────
create table public.contact_report_deliveries (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  report_id       uuid not null,
  recipient_id    uuid not null,
  channel         text not null check (channel in ('WHATSAPP', 'EMAIL')),
  status          text not null default 'PENDING' check (status in ('PENDING', 'SENT', 'FAILED')),
  attempts        integer not null default 0 check (attempts >= 0),
  last_attempt_at timestamptz,
  sent_at         timestamptz,
  error_code      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (recipient_id),
  foreign key (tenant_id, report_id) references public.contact_reports (tenant_id, id) on delete restrict,
  foreign key (tenant_id, recipient_id) references public.contact_report_recipients (tenant_id, id) on delete restrict
);
create index idx_contact_report_deliveries_report  on public.contact_report_deliveries (tenant_id, report_id);
create index idx_contact_report_deliveries_pending on public.contact_report_deliveries (created_at) where status = 'PENDING';

-- ── protection ──────────────────────────────────────────────────────────
create or replace function public.contact_reports_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'contact reports are insert-only; file a correction that supersedes the report'
    using errcode = 'P0001';
end;
$$;
revoke all on function public.contact_reports_insert_only() from public, anon, authenticated, service_role;

create trigger contact_reports_no_change before update or delete on public.contact_reports
  for each row execute function public.contact_reports_insert_only();
create trigger contact_reports_no_truncate before truncate on public.contact_reports
  for each statement execute function public.contact_reports_insert_only();
create trigger contact_report_decisions_no_change before update or delete on public.contact_report_decisions
  for each row execute function public.contact_reports_insert_only();
create trigger contact_report_decisions_no_truncate before truncate on public.contact_report_decisions
  for each statement execute function public.contact_reports_insert_only();
create trigger contact_report_recipients_no_change before update or delete on public.contact_report_recipients
  for each row execute function public.contact_reports_insert_only();
create trigger contact_report_recipients_no_truncate before truncate on public.contact_report_recipients
  for each statement execute function public.contact_reports_insert_only();

-- The send log: only the status columns move, and a row is never deleted.
create or replace function public.contact_report_deliveries_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op <> 'UPDATE' then
    raise exception 'the send log is never deleted' using errcode = 'P0001';
  end if;
  if (new.id, new.tenant_id, new.report_id, new.recipient_id, new.channel, new.created_at)
     is distinct from (old.id, old.tenant_id, old.report_id, old.recipient_id, old.channel, old.created_at) then
    raise exception 'only the delivery status columns may change' using errcode = 'P0001';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.contact_report_deliveries_guard() from public, anon, authenticated, service_role;
create trigger contact_report_deliveries_guard_row before update or delete on public.contact_report_deliveries
  for each row execute function public.contact_report_deliveries_guard();
create trigger contact_report_deliveries_no_truncate before truncate on public.contact_report_deliveries
  for each statement execute function public.contact_report_deliveries_guard();

-- ── grants and RLS ──────────────────────────────────────────────────────
alter table public.contact_reports           enable row level security;
alter table public.contact_report_decisions  enable row level security;
alter table public.contact_report_recipients enable row level security;
alter table public.contact_report_deliveries enable row level security;
revoke all on public.contact_reports, public.contact_report_decisions,
              public.contact_report_recipients, public.contact_report_deliveries
  from anon, authenticated, service_role;
grant select on public.contact_reports, public.contact_report_decisions,
                public.contact_report_deliveries to authenticated;
-- the address is never readable through the API: no column grant on it
grant select (id, tenant_id, report_id, name, channel, address_hint, created_at)
  on public.contact_report_recipients to authenticated;

-- the readers of a tenant's reports
create or replace function public.my_contact_report_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.my_tenant_ids_with_role(
    array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER', 'ZSM']::public.tenant_role_enum[]);
$$;
revoke all on function public.my_contact_report_tenant_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_contact_report_tenant_ids() to authenticated;

create policy contact_reports_select on public.contact_reports for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));
create policy contact_report_decisions_select on public.contact_report_decisions for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));
create policy contact_report_recipients_select on public.contact_report_recipients for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));
create policy contact_report_deliveries_select on public.contact_report_deliveries for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));

-- ── internal: draw a unique reference ───────────────────────────────────
-- CR- + 8 characters of RFC 4648 base32 (A-Z, 2-7), uniform; a collision retries.
create or replace function public.contact_report_draw_reference()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_bytes bytea;
  v_ref   text;
  v_try   integer := 0;
begin
  loop
    v_try := v_try + 1;
    v_bytes := extensions.gen_random_bytes(8);
    v_ref := 'CR-';
    for i in 0..7 loop
      v_ref := v_ref || substr(c_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
    end loop;
    if not exists (select 1 from public.contact_reports r where r.reference = v_ref) then
      return v_ref;
    end if;
    if v_try >= 20 then
      raise exception 'could not draw a free contact report reference' using errcode = 'P0001';
    end if;
  end loop;
end;
$$;
revoke all on function public.contact_report_draw_reference() from public, anon, authenticated, service_role;

-- ── internal: normalise one recipient → address, hint ───────────────────
create or replace function public.contact_report_recipient_clean(p_recipient jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_name    text;
  v_channel text;
  v_raw     text;
  v_addr    text;
  v_hint    text;
begin
  if jsonb_typeof(p_recipient) <> 'object' then
    raise exception 'each recipient needs a name, channel and address' using errcode = 'P0001';
  end if;
  v_name := btrim(coalesce(p_recipient ->> 'name', ''));
  v_channel := p_recipient ->> 'channel';
  v_raw := btrim(coalesce(p_recipient ->> 'address', ''));
  if length(v_name) not between 1 and 200 then
    raise exception 'each recipient needs a name of 1 to 200 characters' using errcode = 'P0001';
  end if;
  if v_channel = 'WHATSAPP' then
    v_addr := '+' || regexp_replace(v_raw, '[^0-9]', '', 'g');
    if v_addr !~ '^\+[1-9][0-9]{7,14}$' then
      raise exception 'a WhatsApp recipient needs a valid international phone number' using errcode = 'P0001';
    end if;
    v_hint := '…' || right(v_addr, 4);
  elsif v_channel = 'EMAIL' then
    v_addr := lower(v_raw);
    if v_addr !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'an email recipient needs a valid email address' using errcode = 'P0001';
    end if;
    v_hint := left(v_addr, 1) || '***@' || split_part(v_addr, '@', 2);
  else
    raise exception 'a recipient channel is WHATSAPP or EMAIL' using errcode = 'P0001';
  end if;
  return jsonb_build_object('name', v_name, 'channel', v_channel, 'address', v_addr, 'address_hint', v_hint);
end;
$$;
revoke all on function public.contact_report_recipient_clean(jsonb) from public, anon, authenticated, service_role;

-- ── file_contact_report ─────────────────────────────────────────────────
create or replace function public.file_contact_report(p_idempotency_key uuid, p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me         public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior      jsonb;
  v_met_at     timestamptz;
  v_channel    text;
  v_summary    text;
  v_attendees  jsonb;
  v_supersedes uuid;
  v_decisions  jsonb;
  v_recipients jsonb;
  v_clean      jsonb := '[]'::jsonb;
  v_hints      jsonb := '[]'::jsonb;
  v_item       jsonb;
  v_c          jsonb;
  v_a          jsonb;
  v_report     public.contact_reports;
  v_rid        uuid;
  v_did        uuid;
  v_ids        uuid[] := '{}';
  v_seq        integer := 0;
  v_subjects   jsonb := '[]'::jsonb;
  v_n          integer;
begin
  if p_report is null or jsonb_typeof(p_report) <> 'object' then
    raise exception 'the report is required' using errcode = 'P0001';
  end if;

  -- shape checks (a bad value is P0001 before anything is written)
  begin
    v_met_at := (p_report ->> 'met_at')::timestamptz;
  exception when others then
    raise exception 'met_at must be a timestamp' using errcode = 'P0001';
  end;
  if v_met_at is null or v_met_at > now() then
    raise exception 'met_at must be a past time' using errcode = 'P0001';
  end if;
  v_channel := p_report ->> 'channel';
  if v_channel is null or v_channel not in ('MEETING', 'CALL', 'VIDEO', 'MESSAGE') then
    raise exception 'channel must be MEETING, CALL, VIDEO or MESSAGE' using errcode = 'P0001';
  end if;
  v_summary := btrim(coalesce(p_report ->> 'summary', ''));
  if length(v_summary) not between 1 and 4000 then
    raise exception 'the summary must be 1 to 4000 characters' using errcode = 'P0001';
  end if;
  v_attendees := p_report -> 'attendees';
  if v_attendees is null or jsonb_typeof(v_attendees) <> 'array'
     or jsonb_array_length(v_attendees) not between 1 and 30 then
    raise exception 'list 1 to 30 attendees' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_attendees) loop
    if jsonb_typeof(v_item) <> 'object'
       or length(btrim(coalesce(v_item ->> 'name', ''))) not between 1 and 200
       or coalesce(v_item ->> 'side', '') not in ('TEAFAIR', 'TENANT') then
      raise exception 'each attendee needs a name and a side of TEAFAIR or TENANT' using errcode = 'P0001';
    end if;
    v_a := coalesce(v_a, '[]'::jsonb)
           || jsonb_build_object('name', btrim(v_item ->> 'name'), 'side', v_item ->> 'side');
  end loop;
  v_attendees := v_a;

  begin
    v_supersedes := nullif(p_report ->> 'supersedes_id', '')::uuid;
  exception when others then
    raise exception 'supersedes_id must be a report id' using errcode = 'P0001';
  end;

  v_decisions := coalesce(p_report -> 'decisions', '[]'::jsonb);
  if jsonb_typeof(v_decisions) <> 'array' or jsonb_array_length(v_decisions) > 50 then
    raise exception 'a report records at most 50 decisions' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_decisions) loop
    if jsonb_typeof(v_item) <> 'object'
       or coalesce(v_item ->> 'subject', '') not in ('BRAND_TERMS', 'MONVELO_SETTINGS', 'FEES', 'CATALOGUE', 'STOCK', 'OTHER')
       or length(btrim(coalesce(v_item ->> 'text', ''))) not between 1 and 2000 then
      raise exception 'each decision needs a subject and 1 to 2000 characters of text' using errcode = 'P0001';
    end if;
  end loop;

  v_recipients := p_report -> 'recipients';
  if v_recipients is null or jsonb_typeof(v_recipients) <> 'array' or jsonb_array_length(v_recipients) < 1 then
    raise exception 'a contact report copies at least one tenant contact' using errcode = 'P0001';
  end if;
  if jsonb_array_length(v_recipients) > 20 then
    raise exception 'a contact report copies at most 20 contacts' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_recipients) loop
    v_c := public.contact_report_recipient_clean(v_item);
    v_clean := v_clean || v_c;
    v_hints := v_hints || (v_c - 'address');
  end loop;

  -- the stored request carries hints, never addresses
  v_prior := public.idempotency_begin(p_idempotency_key, 'file_contact_report',
    jsonb_build_object('met_at', v_met_at, 'channel', v_channel, 'attendees', v_attendees,
                       'summary', v_summary, 'supersedes_id', v_supersedes,
                       'decisions', v_decisions, 'recipients', v_hints));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_supersedes is not null then
    perform 1 from public.contact_reports r
     where r.id = v_supersedes and r.tenant_id = v_me.tenant_id
       for update;
    if not found or exists (select 1 from public.contact_reports r where r.supersedes_id = v_supersedes) then
      raise exception 'only the current version of a report can be corrected' using errcode = 'P0001';
    end if;
  end if;

  insert into public.contact_reports (tenant_id, reference, met_at, channel, attendees, summary,
                                      filed_by, supersedes_id)
  values (v_me.tenant_id, public.contact_report_draw_reference(), v_met_at, v_channel, v_attendees,
          v_summary, v_me.profile_id, v_supersedes)
  returning * into v_report;

  for v_item in select * from jsonb_array_elements(v_decisions) loop
    v_seq := v_seq + 1;
    insert into public.contact_report_decisions (tenant_id, report_id, seq, subject, decision_text)
    values (v_me.tenant_id, v_report.id, v_seq, v_item ->> 'subject', btrim(v_item ->> 'text'))
    returning id into v_did;
    v_ids := v_ids || v_did;
    v_subjects := v_subjects || to_jsonb(v_item ->> 'subject');
  end loop;

  for v_item in select * from jsonb_array_elements(v_clean) loop
    insert into public.contact_report_recipients (tenant_id, report_id, name, channel, address, address_hint)
    values (v_me.tenant_id, v_report.id, v_item ->> 'name', v_item ->> 'channel',
            v_item ->> 'address', v_item ->> 'address_hint')
    returning id into v_rid;
    insert into public.contact_report_deliveries (tenant_id, report_id, recipient_id, channel)
    values (v_me.tenant_id, v_report.id, v_rid, v_item ->> 'channel');
  end loop;
  select count(*) into v_n from public.contact_report_deliveries d where d.report_id = v_report.id;

  perform public.write_audit(v_me.tenant_id, 'file_contact_report', 'contact_reports', v_report.id::text, null,
                             jsonb_build_object('reference', v_report.reference, 'channel', v_channel,
                                                'supersedes_id', v_supersedes,
                                                'decision_subjects', v_subjects, 'recipients', v_hints),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'report_id', v_report.id, 'reference', v_report.reference,
    'decision_ids', to_jsonb(v_ids), 'deliveries_pending', v_n));
end;
$$;
revoke all on function public.file_contact_report(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.file_contact_report(uuid, jsonb) to authenticated;

-- ── assert_citable_decision (internal; no grant) ────────────────────────
-- The decision must be of this tenant and subject, and its report current.
-- Task 2b adds the ZSM approval and the signed hard copy.
create or replace function public.assert_citable_decision(p_tenant_id uuid, p_decision_id uuid, p_subject text)
returns public.contact_report_decisions
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_d public.contact_report_decisions;
begin
  select d.* into v_d
    from public.contact_report_decisions d
   where d.id = p_decision_id and d.tenant_id = p_tenant_id;
  if not found then
    raise exception 'decision not found' using errcode = '42501';
  end if;
  if v_d.subject <> p_subject then
    raise exception 'cite a decision on %', p_subject using errcode = 'P0001';
  end if;
  if exists (select 1 from public.contact_reports r
              where r.tenant_id = v_d.tenant_id and r.supersedes_id = v_d.report_id) then
    raise exception 'this contact report has been superseded; cite the decision in its correction'
      using errcode = 'P0001';
  end if;
  return v_d;
end;
$$;
revoke all on function public.assert_citable_decision(uuid, uuid, text) from public, anon, authenticated, service_role;
