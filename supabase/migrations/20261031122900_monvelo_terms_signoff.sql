-- Addendum A8 §15.2 (user, 2026-11-08): the onboarding sign-off for the
-- pre-underwriter operating policy. Agents and tenants sign that no premium is
-- charged until a licensed underwriter is live, and that premiums start then.
--
--   monvelo_terms_versions      versioned terms; the wording of a version never changes
--                               (DRAFT -> PUBLISHED -> RETIRED). The two §15.2 clauses
--                               are seeded DRAFT: counsel settles the words, then a
--                               migration publishes them (as refund_policies, A5 R20)
--   monvelo_terms_acceptances   insert-only: who signed which version, when, and the
--                               SHA-256 of the exact text they were shown
--   accept_monvelo_agent_terms  an ACTIVE member of the agent signs for the agent
--   accept_monvelo_tenant_terms the tenant's CSM signs for the tenant, citing an
--                               approved MONVELO_SETTINGS decision (A6 §16, zero backdoors)
--   monvelo_terms_accepted      internal: has the agent / tenant accepted the latest
--                               PUBLISHED version for its audience (for enforcement later)
--
-- Privacy (A6 §16.2.2): an agent's acceptance carries no tenant and no tenant
-- role reads it; its audit row is tenant-null.

create table public.monvelo_terms_versions (
  code          text primary key check (code ~ '^MV-[A-Z0-9-]{3,40}$'),
  audience      text not null check (audience in ('AGENT', 'TENANT')),
  title         text not null check (length(btrim(title)) between 1 and 200),
  body          text not null check (length(btrim(body)) between 1 and 20000),
  status        text not null default 'DRAFT' check (status in ('DRAFT', 'PUBLISHED', 'RETIRED')),
  published_at  timestamptz,
  retired_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((status = 'DRAFT') = (published_at is null)),
  check ((status = 'RETIRED') = (retired_at is not null))
);
create index idx_monvelo_terms_versions_live on public.monvelo_terms_versions (audience, published_at)
  where status = 'PUBLISHED';

create table public.monvelo_terms_acceptances (
  id            uuid primary key default gen_random_uuid(),
  terms_code    text not null references public.monvelo_terms_versions (code) on delete restrict,
  audience      text not null check (audience in ('AGENT', 'TENANT')),
  agent_id      uuid references public.monvelo_agents (id) on delete restrict,
  tenant_id     uuid references public.tenants (id) on delete restrict,
  -- the cited contact-report decision (checked by assert_citable_decision)
  decision_id   uuid,
  body_sha256   text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  accepted_by   uuid not null references public.profiles (id) on delete restrict,
  accepted_at   timestamptz not null default now(),
  check ((audience = 'AGENT') = (agent_id is not null and tenant_id is null and decision_id is null)),
  check ((audience = 'TENANT') = (tenant_id is not null and agent_id is null and decision_id is not null))
);
create unique index monvelo_terms_acceptances_agent on public.monvelo_terms_acceptances (terms_code, agent_id)
  where agent_id is not null;
create unique index monvelo_terms_acceptances_tenant on public.monvelo_terms_acceptances (terms_code, tenant_id)
  where tenant_id is not null;
create index idx_monvelo_terms_acceptances_agent on public.monvelo_terms_acceptances (agent_id);
create index idx_monvelo_terms_acceptances_tenant on public.monvelo_terms_acceptances (tenant_id);
create index idx_monvelo_terms_acceptances_by on public.monvelo_terms_acceptances (accepted_by);

create trigger monvelo_terms_versions_set_updated_at before update on public.monvelo_terms_versions
  for each row execute function public.set_updated_at();
create trigger monvelo_terms_versions_guard before insert or update on public.monvelo_terms_versions
  for each row execute function public.monvelo_cover_guard('DRAFT,PUBLISHED',
    'DRAFT>PUBLISHED,PUBLISHED>RETIRED', 'published_at,retired_at');
create trigger monvelo_terms_acceptances_insert_only before update on public.monvelo_terms_acceptances
  for each row execute function public.monvelo_insert_only();

do $$
declare t text;
begin
  foreach t in array array['monvelo_terms_versions', 'monvelo_terms_acceptances'] loop
    execute format('create trigger %1$s_no_delete before delete on public.%1$s
                      for each row execute function public.monvelo_no_delete()', t);
    execute format('create trigger %1$s_no_truncate before truncate on public.%1$s
                      for each statement execute function public.monvelo_no_delete()', t);
    execute format('alter table public.%s enable row level security', t);
    execute format('revoke all on public.%s from anon, authenticated, service_role', t);
  end loop;
end;
$$;
grant select on public.monvelo_terms_versions, public.monvelo_terms_acceptances to authenticated;

create policy monvelo_terms_versions_select on public.monvelo_terms_versions for select to authenticated
  using (status <> 'DRAFT' or (select public.is_monvelo_staff()));
create policy monvelo_terms_acceptances_select on public.monvelo_terms_acceptances for select to authenticated
  using ((select public.is_monvelo_staff())
         or agent_id in (select public.my_monvelo_agent_ids())
         or tenant_id in (select public.my_tenant_ids_with_role(
              array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER', 'ZSM']::public.tenant_role_enum[])));

-- ── the §15.2 clauses, as drafts for counsel ────────────────────────────
insert into public.monvelo_terms_versions (code, audience, title, body) values
  ('MV-AGENT-COVER-2026-11', 'AGENT', 'Stock cover',
   'Stock cover. Monvelo may arrange fire and burglary cover for stock you finance, through a licensed insurer. '
   'Until such an insurer is live on Monvelo, no cover is in place and no premium is deducted from your rebate. '
   'Once an insurer is live, financings you claim from then on are quoted with cover. Where the shop has no '
   'verified policy of its own, the premium is deducted from your rebate, and the net yield is shown before you '
   'claim. Financings claimed earlier are not changed.'),
  ('MV-TENANT-GIT-2026-11', 'TENANT', 'Goods in transit',
   'Goods in transit. If you opt in, Monvelo arranges goods-in-transit cover for financed orders through a licensed '
   'insurer, and the premium is billed to your Monvelo ledger at dispatch. Until such an insurer is live on Monvelo, '
   'no cover is in place and nothing is billed. If the insurer declines a shipment''s cover, the premium is reversed.');

-- ── internal: the published version a party must have accepted ─────────
create or replace function public.monvelo_terms_body_sha256(p_code text)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to(v.body, 'UTF8')), 'hex') from public.monvelo_terms_versions v where v.code = p_code;
$$;
revoke all on function public.monvelo_terms_body_sha256(text) from public, anon, authenticated, service_role;

create or replace function public.monvelo_terms_accepted(p_audience text, p_agent_id uuid, p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with latest as (
    select v.code from public.monvelo_terms_versions v
     where v.audience = p_audience and v.status = 'PUBLISHED'
     order by v.published_at desc, v.code
     limit 1
  )
  select exists (select 1 from latest l join public.monvelo_terms_acceptances a on a.terms_code = l.code
                  where (p_audience = 'AGENT' and a.agent_id = p_agent_id)
                     or (p_audience = 'TENANT' and a.tenant_id = p_tenant_id));
$$;
revoke all on function public.monvelo_terms_accepted(text, uuid, uuid) from public, anon, authenticated, service_role;

-- the version must be PUBLISHED, for this audience, and the text the caller saw
create or replace function public.monvelo_terms_checked(p_code text, p_audience text, p_body_sha256 text)
returns public.monvelo_terms_versions
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v public.monvelo_terms_versions;
begin
  select * into v from public.monvelo_terms_versions where code = p_code;
  if v.code is null or v.audience <> p_audience then
    raise exception 'unknown terms' using errcode = 'P0001';
  end if;
  if v.status <> 'PUBLISHED' then
    raise exception 'these terms are not published' using errcode = 'P0001';
  end if;
  if p_body_sha256 is distinct from public.monvelo_terms_body_sha256(p_code) then
    raise exception 'these terms have changed; read them again' using errcode = 'P0001';
  end if;
  return v;
end;
$$;
revoke all on function public.monvelo_terms_checked(text, text, text) from public, anon, authenticated, service_role;

-- ── accept_monvelo_agent_terms: a member signs for the agent ────────────
create or replace function public.accept_monvelo_agent_terms(p_idempotency_key uuid, p_agent_id uuid, p_terms_code text,
                                                             p_body_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_prior jsonb;
  v_terms public.monvelo_terms_versions;
  v_row   public.monvelo_terms_acceptances;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_agent_id is null or not exists (select 1 from public.monvelo_agent_members m
                                        where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'accept_monvelo_agent_terms',
    jsonb_build_object('agent_id', p_agent_id, 'terms_code', p_terms_code, 'body_sha256', p_body_sha256));
  if v_prior is not null then
    return v_prior;
  end if;
  v_terms := public.monvelo_terms_checked(p_terms_code, 'AGENT', p_body_sha256);

  select * into v_row from public.monvelo_terms_acceptances where terms_code = v_terms.code and agent_id = p_agent_id;
  if v_row.id is not null then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'accepted', true, 'already', true, 'terms_code', v_terms.code, 'accepted_at', v_row.accepted_at));
  end if;
  insert into public.monvelo_terms_acceptances (terms_code, audience, agent_id, body_sha256, accepted_by)
  values (v_terms.code, 'AGENT', p_agent_id, p_body_sha256, v_uid)
  returning * into v_row;
  -- it names the agent: tenant-null (§16.2.2)
  perform public.write_audit(null, 'accept_monvelo_agent_terms', 'monvelo_terms_acceptances', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'accepted', true, 'already', false, 'terms_code', v_terms.code, 'accepted_at', v_row.accepted_at));
end;
$$;
revoke all on function public.accept_monvelo_agent_terms(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.accept_monvelo_agent_terms(uuid, uuid, text, text) to authenticated;

-- ── accept_monvelo_tenant_terms: the CSM signs for the tenant ───────────
create or replace function public.accept_monvelo_tenant_terms(p_idempotency_key uuid, p_terms_code text,
                                                              p_body_sha256 text, p_decision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_terms public.monvelo_terms_versions;
  v_row   public.monvelo_terms_acceptances;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'accept_monvelo_tenant_terms',
    jsonb_build_object('terms_code', p_terms_code, 'body_sha256', p_body_sha256, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;
  v_terms := public.monvelo_terms_checked(p_terms_code, 'TENANT', p_body_sha256);
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'MONVELO_SETTINGS');

  select * into v_row from public.monvelo_terms_acceptances where terms_code = v_terms.code and tenant_id = v_me.tenant_id;
  if v_row.id is not null then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'accepted', true, 'already', true, 'terms_code', v_terms.code, 'accepted_at', v_row.accepted_at));
  end if;
  insert into public.monvelo_terms_acceptances (terms_code, audience, tenant_id, decision_id, body_sha256, accepted_by)
  values (v_terms.code, 'TENANT', v_me.tenant_id, p_decision_id, p_body_sha256, v_me.profile_id)
  returning * into v_row;
  perform public.write_audit(v_me.tenant_id, 'accept_monvelo_tenant_terms', 'monvelo_terms_acceptances', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'accepted', true, 'already', false, 'terms_code', v_terms.code, 'accepted_at', v_row.accepted_at));
end;
$$;
revoke all on function public.accept_monvelo_tenant_terms(uuid, text, text, uuid) from public, anon, service_role;
grant execute on function public.accept_monvelo_tenant_terms(uuid, text, text, uuid) to authenticated;
