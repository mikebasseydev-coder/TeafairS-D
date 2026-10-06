-- Spec A §3.3 / §3.5 — the write-RPC skeleton every mutation is built on.
--
--   v_me    := public.assert_tenant_role(array[...]);         -- who, which tenant, allowed?
--   v_prior := public.idempotency_begin(key, 'op', request);  -- replay?
--   if v_prior is not null then return v_prior; end if;
--   ... the business writes, locking contended rows in primary-key order ...
--   perform public.write_audit(...);                          -- one row per effect
--   return public.idempotency_complete(key, response);
--
-- The RPC body is the transaction (§3.1): if anything raises, the idempotency
-- row, the business writes and the audit rows all roll back together, so a
-- retry with the same key starts clean.
--
-- These internals are NOT executable by API roles. They run inside SECURITY
-- DEFINER RPCs, as the function owner, while auth.uid()/auth.jwt() still read
-- the caller's verified claims.
--
-- Error codes the gateway maps (§3.5):
--   P0001  business-rule violation           → 422 terminal
--   42501  not authenticated / not permitted → 403 terminal
--   23505  unique violation                  → 409 terminal
--   TF001  insufficient stock                → 409 terminal (+ structured detail)
--   TF002  idempotency key reused differently → 409 terminal
--   40001  same key still in flight / serialization failure → 503 retry
--   55P03  lock timeout                      → 503 retry

-- ── who is calling, in which tenant, with which role ────────────────────
-- Tenant comes from the JWT; ACTIVE membership and role come from
-- tenant_users, live (§4.4). Pass null roles to require membership only.
create or replace function public.assert_tenant_role(p_roles public.tenant_role_enum[])
returns public.tenant_users
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_tenant uuid := public.jwt_tenant_id();
  v_me     public.tenant_users;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'no active tenant selected' using errcode = '42501';
  end if;

  select * into v_me
  from public.tenant_users tu
  where tu.tenant_id = v_tenant
    and tu.profile_id = v_uid
    and tu.status = 'ACTIVE';

  if not found then
    raise exception 'not an active member of the selected tenant' using errcode = '42501';
  end if;
  if p_roles is not null and not (v_me.role = any (p_roles)) then
    raise exception 'role % may not perform this operation', v_me.role using errcode = '42501';
  end if;
  return v_me;
end;
$$;

-- The caller, required. For self-scoped operations that need no tenant.
create or replace function public.assert_authenticated()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return v_uid;
end;
$$;

-- ── idempotency (§7.2) ──────────────────────────────────────────────────
-- Returns null for a new key (proceed), or the stored response for a replay.
-- A key is bound to (actor, operation, request); any difference is TF002.
create or replace function public.idempotency_begin(p_key uuid, p_operation text, p_request jsonb)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := (select auth.uid());
  v_tenant uuid := public.jwt_tenant_id();
  v_hash   text := encode(extensions.digest(coalesce(p_request, '{}'::jsonb)::text, 'sha256'), 'hex');
  v_row    public.idempotency_logs;
begin
  if p_key is null then
    raise exception 'p_idempotency_key is required' using errcode = 'P0001';
  end if;
  -- record the tenant only when the caller really belongs to it
  if v_tenant is not null and not public.is_tenant_member(v_tenant) then
    v_tenant := null;
  end if;

  insert into public.idempotency_logs (key, tenant_id, actor_id, operation, request_hash, status)
  values (p_key, v_tenant, v_actor, p_operation, v_hash, 'IN_PROGRESS')
  on conflict (key) do nothing;
  if found then
    return null;
  end if;

  select * into v_row from public.idempotency_logs where key = p_key;
  if v_row.operation <> p_operation
     or v_row.request_hash <> v_hash
     or v_row.actor_id is distinct from v_actor then
    raise exception 'idempotency key % was already used for a different request', p_key
      using errcode = 'TF002';
  end if;
  if v_row.status = 'COMPLETED' then
    return v_row.response;
  end if;
  -- only reachable if a prior attempt committed without completing
  raise exception 'request % is still in progress', p_key using errcode = '40001';
end;
$$;

create or replace function public.idempotency_complete(p_key uuid, p_response jsonb)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
begin
  update public.idempotency_logs
     set status = 'COMPLETED', response = p_response
   where key = p_key;
  return p_response;
end;
$$;

-- ── audit (§4.6, §6.10) ─────────────────────────────────────────────────
-- actor_id is the caller, for USER rows only; cron, webhook and system rows
-- have no actor even if a claim is lying around in the session.
-- teafair_agent_id defaults to the actor when the actor is Teafair field or
-- management staff; partners and shop owners are never the accountable agent.
create or replace function public.write_audit(
  p_tenant_id         uuid,
  p_operation         text,
  p_entity_type       text,
  p_entity_id         text,
  p_before            jsonb,
  p_after             jsonb,
  p_idempotency_key   uuid,
  p_source            public.audit_source_enum default 'USER',
  p_teafair_agent_id  uuid default null
)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_role  text;
begin
  if p_source = 'USER' then
    v_actor := (select auth.uid());
    if p_tenant_id is not null then
      v_role := public.tenant_role(p_tenant_id)::text;
    end if;
    if v_role is null and v_actor is not null then
      select p.platform_role::text into v_role from public.profiles p where p.id = v_actor;
    end if;
  end if;

  insert into public.audit_logs (tenant_id, actor_id, actor_role, teafair_agent_id, operation,
                                 entity_type, entity_id, before, after, idempotency_key, source)
  values (
    p_tenant_id, v_actor, v_role,
    coalesce(p_teafair_agent_id,
             case when v_role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA') then v_actor end),
    p_operation, p_entity_type, p_entity_id, p_before, p_after, p_idempotency_key, p_source
  );
end;
$$;

-- GeoJSON Polygon/MultiPolygon → MultiPolygon(4326). Null passes through.
create or replace function public.geojson_to_multipolygon(p_geojson jsonb)
returns extensions.geometry
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_geom extensions.geometry;
begin
  if p_geojson is null then
    return null;
  end if;
  begin
    v_geom := extensions.st_setsrid(extensions.st_geomfromgeojson(p_geojson::text), 4326);
  exception when others then
    raise exception 'boundary is not valid GeoJSON' using errcode = 'P0001';
  end;
  if extensions.geometrytype(v_geom) not in ('POLYGON', 'MULTIPOLYGON') then
    raise exception 'boundary must be a Polygon or MultiPolygon' using errcode = 'P0001';
  end if;
  v_geom := extensions.st_multi(v_geom);
  if not extensions.st_isvalid(v_geom) then
    raise exception 'boundary polygon is not valid: %', extensions.st_isvalidreason(v_geom)
      using errcode = 'P0001';
  end if;
  return v_geom;
end;
$$;
