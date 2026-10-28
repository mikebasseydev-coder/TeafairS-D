-- Addendum A6 §3 — areas, the ZSA / ASA role anchors, the invite for them and
-- the platform-role gate.
--
--   zone - territory - area        a ZSA works a zone, an ASA works one area
--
-- `areas` is core geography (no monvelo_ prefix): the area is also where a
-- shop is enrolled. Platform roles are checked live on profiles.platform_role,
-- the way tenant roles are checked live on tenant_users.

-- ── areas ───────────────────────────────────────────────────────────────
create table public.areas (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  territory_id  uuid not null,
  area_name     text not null check (length(btrim(area_name)) > 0),
  asa_id        uuid references public.profiles (id) on delete restrict,
  created_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, territory_id, area_name),
  unique (tenant_id, territory_id, id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.areas enable row level security;
create index idx_areas_asa on public.areas (asa_id);

create policy areas_select_tenant_member on public.areas
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── tenant_users anchors ────────────────────────────────────────────────
alter table public.tenant_users add column area_id uuid;
alter table public.tenant_users
  add constraint tenant_users_area_fk
  foreign key (tenant_id, territory_id, area_id)
    references public.areas (tenant_id, territory_id, id) on delete restrict;
create index idx_tenant_users_area on public.tenant_users (tenant_id, area_id);

alter table public.tenant_users
  add constraint tenant_users_zsa_anchor
    check (role <> 'ZSA' or (zone_id is not null and reports_to_id is not null)),
  add constraint tenant_users_asa_anchor
    check (role <> 'ASA' or (territory_id is not null and area_id is not null and reports_to_id is not null));

-- tenant_users is granted column by column: area_id is readable like zone_id
grant select (area_id) on public.tenant_users to authenticated;

-- ── assert_platform_role ────────────────────────────────────────────────
-- Platform roles live on profiles.platform_role and need no tenant. Read live,
-- never from the JWT claim. Internal: called from SECURITY DEFINER RPCs.
create or replace function public.assert_platform_role(p_roles public.platform_role_enum[])
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role public.platform_role_enum;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select p.platform_role into v_role from public.profiles p where p.id = v_uid;
  if v_role is null or p_roles is null or not (v_role = any (p_roles)) then
    raise exception 'not permitted for this platform role' using errcode = '42501';
  end if;
  return v_uid;
end;
$$;

-- ── upsert_area ─────────────────────────────────────────────────────────
-- The ZSM of the territory's zone, or the territory's TM.
create or replace function public.upsert_area(
  p_idempotency_key uuid,
  p_area_id         uuid,
  p_territory_id    uuid,
  p_area_name       text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_terr   public.territories;
  v_before public.areas;
  v_after  public.areas;
begin
  select * into v_terr from public.territories
   where id = p_territory_id and tenant_id = v_me.tenant_id;
  if not found
     or (v_me.role = 'ZSM' and v_terr.zone_id is distinct from v_me.zone_id)
     or (v_me.role = 'TM'  and v_terr.id is distinct from v_me.territory_id) then
    raise exception 'areas are managed by the ZSM of the zone or the TM of the territory'
      using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_area',
    jsonb_build_object('area_id', p_area_id, 'territory_id', p_territory_id, 'area_name', p_area_name));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_area_name is null or btrim(p_area_name) = '' then
    raise exception 'area_name is required' using errcode = 'P0001';
  end if;

  if p_area_id is null then
    insert into public.areas (tenant_id, territory_id, area_name)
    values (v_me.tenant_id, p_territory_id, btrim(p_area_name))
    returning * into v_after;
  else
    select * into v_before from public.areas
     where id = p_area_id and tenant_id = v_me.tenant_id and territory_id = p_territory_id
     for update;
    if not found then
      raise exception 'area not found in this territory' using errcode = 'P0001';
    end if;
    update public.areas set area_name = btrim(p_area_name)
     where id = p_area_id
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_area', 'areas', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('area_id', v_after.id));
end;
$$;

-- ── invite_tenant_user, with ZSA and ASA ────────────────────────────────
-- Same rules as 20261024150000 (an invite reaches only an account whose phone
-- Supabase Auth confirmed), plus:
--   ZSA  zone = the inviting ZSM's zone; reports to a ZSM of that zone
--   ASA  needs an area inside p_territory_id; reports to an ASM or TM there
drop function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid);

create or replace function public.invite_tenant_user(
  p_idempotency_key uuid,
  p_phone_number    text,
  p_role            public.tenant_role_enum,
  p_territory_id    uuid,
  p_reports_to_id   uuid,
  p_area_id         uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  if p_role in ('TM', 'ASM', 'DSM', 'DSA', 'FINTECH_AGENT', 'ASA') and p_territory_id is null then
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
$$;

grant execute on function
  public.upsert_area(uuid, uuid, uuid, text),
  public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid)
to authenticated;
