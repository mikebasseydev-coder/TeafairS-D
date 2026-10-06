# CLAUDE.md (supabase)

The entire backend. Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`) is
the authority; this file is the working summary.

## Status

| Phase (Spec A §14) | State |
|---|---|
| 1. Schema — extensions, enums, 33 tables | done |
| 2. Grants, RLS, write contract, foundation RPCs, brand tiers, escalation cron | done |
| 3. Edge Function gateway (`supabase/functions/`) | next |
| 4. Client offline queue | needs Spec B |

No remote project is linked. Nothing is pushed until explicitly asked.

## Layout

```
supabase/
├── config.toml
├── migrations/        hand-written, ordered — Supabase CLI owns all DDL
└── tests/database/    pgTAP, run by `supabase test db`
```

Migrations are **hand-written**, not generated from declarative schemas: grants,
column privileges, comments and `cron.schedule` are outside what `db diff`
tracks, and grants are the security core (Spec A §13).

## Writing a migration

- Every new table: `enable row level security` in the same migration, a
  `FOR SELECT` policy, and nothing else. Never an INSERT/UPDATE/DELETE policy.
- Tenant-scoped tables carry `tenant_id uuid not null references
  tenants(id) on delete restrict`, a `unique (tenant_id, id)`, and reference
  other tenant rows through **composite** `(tenant_id, x)` foreign keys so a
  row can never point into another tenant.
- Index every foreign key and every column a policy filters on.
- Mutable tables get the `set_updated_at()` trigger.
- PostGIS lives in the `extensions` schema: write `extensions.geometry(...)`
  and `extensions.st_*` — function search paths do not include it.
- New functions get **no** EXECUTE for PUBLIC/anon/authenticated by default
  (grants migration). Grant explicitly, and only what the API may call.

## Writing an RPC

Follow the skeleton in `20261006130300_write_contract.sql`:

```sql
create or replace function public.<op>(p_idempotency_key uuid, ...)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, '<op>', <request jsonb>);
  if v_prior is not null then return v_prior; end if;
  -- validate (P0001), lock contended rows in primary-key order, write
  perform public.write_audit(v_me.tenant_id, '<op>', '<table>', <id>, <before>, <after>, p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, <response jsonb>);
end; $$;
grant execute on function public.<op>(...) to authenticated;
```

- No `p_tenant_id` parameter, ever (the only exception is `set_active_tenant`,
  which proposes a tenant and is checked against membership).
- Error codes (Spec A §3.5): `P0001` business 422 · `42501` forbidden 403 ·
  `23505` 409 · `TF001` insufficient stock 409 · `TF002` idempotency mismatch
  409 · `40001`/`55P03` retry 503. Do not use `P0002`: it is PL/pgSQL's
  `no_data_found`.
- Pure DB work is an RPC; scheduled pure-SQL work is a `pg_cron` job. Edge
  Functions are for HTTP, PINs and external IO only.

## Testing

```bash
supabase test db                 # all files; look for "Result: PASS"
psql -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
     -qAt -f supabase/tests/database/003_rls.test.sql   # one file, every assertion
```

Act as a user the way PostgREST does: `set_config('role','authenticated',true)`
plus `request.jwt.claims` JSON with `sub` and `app_metadata.active_tenant_id`.
Test helpers created with `create function pg_temp.*` need an explicit
`grant execute … to authenticated`. Write the test first and watch it fail.

If `supabase start` / `db reset` fails with `LegacyDbSetupError` and a realtime
`nxdomain` message, Docker's internal DNS hiccuped; restart Docker Desktop and
retry. `supabase migration up` applies new migrations without a full reset.
