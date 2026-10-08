-- Spec A §6.3 — tenancy and identity: tenants, tenant_settings, profiles,
-- user_secure_profiles, devices. tenant_users follows the geography migration
-- because it references zones and territories.
--
-- Every table enables RLS at creation. Policies arrive in Phase 2; until then
-- RLS with no policy denies everything, so no table is ever briefly open.

-- ── tenants ─────────────────────────────────────────────────────────────
-- Decision 6: never deleted. Offboarding is status = 'INACTIVE'.
create table public.tenants (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) > 0),
  code        text not null unique check (code ~ '^[A-Z0-9_]{2,16}$'),
  status      public.tenant_status_enum not null default 'ACTIVE',
  logo_url    text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.tenants enable row level security;
create trigger tenants_set_updated_at before update on public.tenants
  for each row execute function public.set_updated_at();

create table public.tenant_settings (
  tenant_id             uuid primary key references public.tenants (id) on delete restrict,
  currency              text not null default 'NGN' check (currency ~ '^[A-Z]{3}$'),
  timezone              text not null default 'Africa/Lagos',
  allow_shared_network  boolean not null default true,
  custom_fields         jsonb not null default '{}'::jsonb
                          check (jsonb_typeof(custom_fields) = 'object'),
  updated_at            timestamptz not null default now()
);
alter table public.tenant_settings enable row level security;
create trigger tenant_settings_set_updated_at before update on public.tenant_settings
  for each row execute function public.set_updated_at();

-- ── profiles ────────────────────────────────────────────────────────────
-- profiles.id IS auth.users.id. No role column (decision 8): role is
-- per-tenant, in tenant_users. No BVN hash (decision 16): that lives in
-- user_secure_profiles, which peers can never read.
create table public.profiles (
  id             uuid primary key references auth.users (id) on delete restrict,
  full_name      text not null default '',
  phone_number   text not null unique check (phone_number ~ '^\+[1-9][0-9]{7,14}$'),
  email          text unique check (email = lower(email)),
  platform_role  public.platform_role_enum,
  kyc_status     public.kyc_status_enum not null default 'UNVERIFIED',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
alter table public.profiles enable row level security;
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- Provision the profile when Supabase Auth creates the user. Field roles sign
-- in by phone OTP, so a phone number is mandatory.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := nullif(btrim(coalesce(new.phone, new.raw_user_meta_data ->> 'phone')), '');
begin
  if v_phone is null then
    raise exception 'a phone number is required to create a Teafair account'
      using errcode = 'P0001';
  end if;

  insert into public.profiles (id, full_name, phone_number, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    '+' || ltrim(v_phone, '+'),
    lower(nullif(new.email, ''))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── user_secure_profiles ────────────────────────────────────────────────
-- §4.5 / decision 17. Owner-only. The hash is HMAC-SHA256 under a Vault
-- pepper; each pepper version wraps the previous hash, so a rotation moves
-- the current hash to *_prev and lookups match either while it runs.
create table public.user_secure_profiles (
  user_id                uuid primary key references public.profiles (id) on delete restrict,
  bvn_nin_hash           text not null unique,
  bvn_hash_version       smallint not null check (bvn_hash_version > 0),
  bvn_nin_hash_prev      text,
  bvn_hash_prev_version  smallint,
  bank_name              text,
  bank_account_number    text check (bank_account_number ~ '^[0-9]{10}$'),  -- NUBAN
  bank_code              text,
  verified_at            timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint user_secure_profiles_prev_pair
    check ((bvn_nin_hash_prev is null) = (bvn_hash_prev_version is null)),
  constraint user_secure_profiles_prev_older
    check (bvn_hash_prev_version is null or bvn_hash_prev_version < bvn_hash_version)
);
alter table public.user_secure_profiles enable row level security;
create unique index user_secure_profiles_hash_prev_key
  on public.user_secure_profiles (bvn_nin_hash_prev)
  where bvn_nin_hash_prev is not null;
-- the rotation job scans rows still below the current version
create index idx_user_secure_profiles_version
  on public.user_secure_profiles (bvn_hash_version);
create trigger user_secure_profiles_set_updated_at before update on public.user_secure_profiles
  for each row execute function public.set_updated_at();

-- ── devices ─────────────────────────────────────────────────────────────
create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete restrict,
  hardware_id   text not null,
  device_model  text,
  push_token    text,
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  unique (user_id, hardware_id)
);
alter table public.devices enable row level security;
