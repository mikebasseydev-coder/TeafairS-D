-- Spec A §8 / §9 — privileges. Supabase's default privileges grant anon and
-- authenticated full DML on every new public table and EXECUTE on every new
-- function. Both are withdrawn here, for existing objects and future ones.
--
--   anon           nothing
--   authenticated  SELECT on tables (rows filtered by RLS), EXECUTE only on the
--                  RLS helpers and the write RPCs, granted one by one
--   service_role   unchanged (system-initiated gateways, §3.4)

-- ── tables ──────────────────────────────────────────────────────────────
revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;

-- Secrets are excluded column by column. A peer can read a membership row
-- (§8) but never its PIN hash; a subject can read their OTP challenge but
-- never its code hash.
revoke select on public.tenant_users from authenticated;
grant select (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id,
              is_primary, status, pin_failed_attempts, pin_locked_until,
              created_at, updated_at)
  on public.tenant_users to authenticated;

revoke select on public.otp_challenges from authenticated;
grant select (id, tenant_id, subject_id, purpose, destination_phone, issued_by,
              expires_at, consumed_at, failed_attempts, locked_until, created_at)
  on public.otp_challenges to authenticated;

-- ── sequences and functions ─────────────────────────────────────────────
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- ── objects created by later migrations ─────────────────────────────────
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  grant select on tables to authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;
-- Postgres grants EXECUTE to PUBLIC on every new function through a built-in
-- *global* default, and a per-schema default can only add to the global one,
-- never subtract. So the PUBLIC grant is withdrawn globally; every function
-- the API may call is then granted explicitly.
alter default privileges for role postgres
  revoke execute on functions from public;
