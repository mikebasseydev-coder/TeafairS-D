-- Addendum A6 §16.4 (Monvelo Step 1c, Task 2b) — the ZSM review and the signed
-- hard copy of a contact report. A report's decisions cannot be cited until a
-- ZSM of the tenant has approved it (a MONVELO_OPERATOR may review only when
-- the tenant has no ACTIVE ZSM) and the signed hard copy is attached.
--
-- The upload follows the A5 photo pattern: an RPC registers a pending slot,
-- the contact-report-upload gateway signs a one-time upload URL, the client
-- uploads to a private bucket, and a claim RPC checks that the object is
-- really there. Paths and URLs never reach an audit row.

-- ── bucket ──────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('contact-reports', 'contact-reports', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;
update storage.buckets
   set public = false, file_size_limit = 10485760,
       allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
 where id = 'contact-reports';

-- ── contact_report_reviews ──────────────────────────────────────────────
create table public.contact_report_reviews (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  report_id     uuid not null,
  outcome       text not null check (outcome in ('APPROVED', 'REJECTED')),
  note          text check (length(btrim(note)) <= 2000),
  reviewer_kind text not null default 'ZSM' check (reviewer_kind in ('ZSM', 'OPERATOR_FALLBACK')),
  reviewed_by   uuid not null references public.profiles (id) on delete restrict,
  reviewed_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (report_id),
  foreign key (tenant_id, report_id) references public.contact_reports (tenant_id, id) on delete restrict,
  check (outcome <> 'REJECTED' or length(btrim(coalesce(note, ''))) >= 1)
);
create index idx_contact_report_reviews_report on public.contact_report_reviews (tenant_id, report_id);
create index idx_contact_report_reviews_by     on public.contact_report_reviews (reviewed_by);

create trigger contact_report_reviews_no_change before update or delete on public.contact_report_reviews
  for each row execute function public.contact_reports_insert_only();
create trigger contact_report_reviews_no_truncate before truncate on public.contact_report_reviews
  for each statement execute function public.contact_reports_insert_only();

alter table public.contact_report_reviews enable row level security;
revoke all on public.contact_report_reviews from anon, authenticated, service_role;
grant select on public.contact_report_reviews to authenticated;
create policy contact_report_reviews_select on public.contact_report_reviews for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));

-- ── contact_report_hard_copies ──────────────────────────────────────────
create table public.contact_report_hard_copies (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  report_id    uuid not null,
  storage_path text not null unique,
  mime_type    text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes   bigint not null check (size_bytes between 1 and 10485760),
  uploaded_by  uuid not null references public.profiles (id) on delete restrict,
  created_at   timestamptz not null default now(),
  attached_at  timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, report_id) references public.contact_reports (tenant_id, id) on delete restrict,
  check (storage_path ~ ('^contact-reports/' || report_id::text || '/' || id::text || '\.(pdf|jpg|png)$'))
);
create index idx_contact_report_hard_copies_report   on public.contact_report_hard_copies (tenant_id, report_id);
create index idx_contact_report_hard_copies_uploader on public.contact_report_hard_copies (uploaded_by);
-- one attached copy per report
create unique index contact_report_hard_copies_one_attached
  on public.contact_report_hard_copies (report_id) where attached_at is not null;
-- the cleanup scans pending copies by age
create index idx_contact_report_hard_copies_pending
  on public.contact_report_hard_copies (created_at) where attached_at is null;

-- never deleted; the only change is attached_at, from null to a value
create or replace function public.contact_report_hard_copies_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and old.attached_at is null and new.attached_at is not null
     and (new.id, new.tenant_id, new.report_id, new.storage_path, new.mime_type, new.size_bytes,
          new.uploaded_by, new.created_at)
         is not distinct from
         (old.id, old.tenant_id, old.report_id, old.storage_path, old.mime_type, old.size_bytes,
          old.uploaded_by, old.created_at) then
    return new;
  end if;
  raise exception 'a hard copy is never changed; file a correction' using errcode = 'P0001';
end;
$$;
revoke all on function public.contact_report_hard_copies_guard() from public, anon, authenticated, service_role;
create trigger contact_report_hard_copies_guard_row before update or delete on public.contact_report_hard_copies
  for each row execute function public.contact_report_hard_copies_guard();
create trigger contact_report_hard_copies_no_truncate before truncate on public.contact_report_hard_copies
  for each statement execute function public.contact_report_hard_copies_guard();

alter table public.contact_report_hard_copies enable row level security;
revoke all on public.contact_report_hard_copies from anon, authenticated, service_role;
grant select on public.contact_report_hard_copies to authenticated;
-- the storage path is never sent to a client (it goes only to the gateway)
revoke select on public.contact_report_hard_copies from authenticated;
grant select (id, tenant_id, report_id, mime_type, size_bytes, uploaded_by, created_at, attached_at)
  on public.contact_report_hard_copies to authenticated;
create policy contact_report_hard_copies_select on public.contact_report_hard_copies for select to authenticated
  using (tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff()));

-- ── download: the readers of a report read its ATTACHED copy only ───────
create or replace function public.my_contact_report_hard_copy_paths()
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select h.storage_path
    from public.contact_report_hard_copies h
   where h.attached_at is not null
     and (h.tenant_id in (select public.my_contact_report_tenant_ids())
          or (select public.is_platform_staff()));
$$;
revoke all on function public.my_contact_report_hard_copy_paths() from public, anon, authenticated, service_role;
grant execute on function public.my_contact_report_hard_copy_paths() to authenticated;

create policy contact_reports_hard_copy_select on storage.objects
  for select to authenticated
  using (bucket_id = 'contact-reports'
         and name in (select public.my_contact_report_hard_copy_paths()));

-- ── review_contact_report ───────────────────────────────────────────────
create or replace function public.review_contact_report(
  p_idempotency_key uuid, p_report_id uuid, p_outcome text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_platform public.platform_role_enum;
  v_me       public.tenant_users;
  v_kind     text;
  v_report   public.contact_reports;
  v_prior    jsonb;
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_review   public.contact_report_reviews;
begin
  if v_uid is not null then
    select p.platform_role into v_platform from public.profiles p where p.id = v_uid;
  end if;
  if v_platform = 'MONVELO_OPERATOR' then
    perform public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
    v_kind := 'OPERATOR_FALLBACK';
  else
    v_me := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
    v_kind := 'ZSM';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'review_contact_report',
    jsonb_build_object('report_id', p_report_id, 'outcome', p_outcome, 'note', v_note));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_outcome is null or p_outcome not in ('APPROVED', 'REJECTED') then
    raise exception 'the outcome is APPROVED or REJECTED' using errcode = 'P0001';
  end if;
  if v_note is not null and length(v_note) > 2000 then
    raise exception 'the note is at most 2000 characters' using errcode = 'P0001';
  end if;

  -- the tenant comes from the report, never from a parameter
  select r.* into v_report from public.contact_reports r where r.id = p_report_id for update;
  if not found or (v_kind = 'ZSM' and v_report.tenant_id <> v_me.tenant_id) then
    raise exception 'contact report not found' using errcode = '42501';
  end if;
  if v_kind = 'OPERATOR_FALLBACK' and exists (
       select 1 from public.tenant_users tu
        where tu.tenant_id = v_report.tenant_id and tu.role = 'ZSM' and tu.status = 'ACTIVE') then
    raise exception 'this tenant has an active ZSM; the ZSM reviews' using errcode = '42501';
  end if;

  if exists (select 1 from public.contact_reports r
              where r.tenant_id = v_report.tenant_id and r.supersedes_id = v_report.id) then
    raise exception 'only the current version of a report can be reviewed' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.contact_report_reviews w where w.report_id = v_report.id) then
    raise exception 'this contact report has already been reviewed' using errcode = '23505';
  end if;
  if p_outcome = 'REJECTED' and v_note is null then
    raise exception 'say what must be corrected' using errcode = 'P0001';
  end if;

  insert into public.contact_report_reviews (tenant_id, report_id, outcome, note, reviewer_kind, reviewed_by)
  values (v_report.tenant_id, v_report.id, p_outcome, v_note, v_kind, v_uid)
  returning * into v_review;

  perform public.write_audit(v_report.tenant_id, 'review_contact_report', 'contact_report_reviews',
                             v_review.id::text, null,
                             jsonb_build_object('reference', v_report.reference, 'outcome', p_outcome,
                                                'reviewer_kind', v_kind),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('review_id', v_review.id, 'report_id', v_report.id, 'outcome', p_outcome));
end;
$$;
revoke all on function public.review_contact_report(uuid, uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.review_contact_report(uuid, uuid, text, text) to authenticated;

-- ── request_contact_report_hard_copy ────────────────────────────────────
create or replace function public.request_contact_report_hard_copy(
  p_idempotency_key uuid, p_report_id uuid, p_mime_type text, p_size_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;
revoke all on function public.request_contact_report_hard_copy(uuid, uuid, text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.request_contact_report_hard_copy(uuid, uuid, text, bigint) to authenticated;

-- ── attach_contact_report_hard_copy ─────────────────────────────────────
create or replace function public.attach_contact_report_hard_copy(p_idempotency_key uuid, p_hard_copy_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
                    and (o.metadata ->> 'size' is null or o.metadata ->> 'size' = v_copy.size_bytes::text)
                    and (o.metadata ->> 'mimetype' is null or o.metadata ->> 'mimetype' = v_copy.mime_type)) then
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
$$;
revoke all on function public.attach_contact_report_hard_copy(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.attach_contact_report_hard_copy(uuid, uuid) to authenticated;

-- ── cleanup_pending_upload_slots: recreated from the live body ──────────
-- + the objects of hard copies never attached within 24 hours. The rows stay
-- (records are never deleted); only the stored object is queued for the purge.
create or replace function public.cleanup_pending_upload_slots()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  with gone as (
    delete from public.upload_slots
     where claimed_at is null and created_at < now() - interval '24 hours'
    returning bucket, storage_path
  ), queued as (
    insert into public.storage_purge_queue (bucket, path)
    select bucket, storage_path from gone
    on conflict (bucket, path) do nothing
  )
  select count(*)::int into v_count from gone;

  insert into public.storage_purge_queue (bucket, path)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('support-attachments', 'delivery-proofs')
     and o.created_at < now() - interval '24 hours'
     and not exists (select 1 from public.upload_slots s where s.storage_path = o.name)
  on conflict (bucket, path) do nothing;

  insert into public.storage_purge_queue (bucket, path)
  select 'contact-reports', h.storage_path
    from public.contact_report_hard_copies h
   where h.attached_at is null
     and h.created_at < now() - interval '24 hours'
     and exists (select 1 from storage.objects o
                  where o.bucket_id = 'contact-reports' and o.name = h.storage_path)
  on conflict (bucket, path) do nothing;

  return v_count;
end;
$$;
revoke all on function public.cleanup_pending_upload_slots() from public, anon, authenticated, service_role;

-- ── assert_citable_decision: + ZSM approval and the signed hard copy ────
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
  if not exists (select 1 from public.contact_report_reviews w
                  where w.report_id = v_d.report_id and w.outcome = 'APPROVED') then
    raise exception 'a ZSM must approve this contact report before it is cited' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.contact_report_hard_copies h
                  where h.report_id = v_d.report_id and h.attached_at is not null) then
    raise exception 'upload the signed hard copy of this contact report before citing it' using errcode = 'P0001';
  end if;
  return v_d;
end;
$$;
revoke all on function public.assert_citable_decision(uuid, uuid, text) from public, anon, authenticated, service_role;
