# Onboarding & entity verification

**Spec:** §5.3, §5.8, §5.9, §7

## Purpose

Field agents sign up outlets, guarantors and fintech agents in their own zone;
HQ verifies each before it can transact. There is no pre-existing customer base
— agents build it.

## Tables

- `outlets` — `business_name`, `contact_name`, `phone`, `market_zone_id`,
  `address`, lat/lng, `credit_limit`, `registered_by`, `status` (`entity_status`),
  `verified_by?`, `verified_at?`.
- `outlet_guarantors` — `outlet_id`, `full_name`, `phone`, `address`,
  `relationship`, `id_document_path`, `photo_path` (Storage), `status`,
  `verified_by?`. At least one `ACTIVE` guarantor is required before any credit
  order (see [payments-debt-remittances](payments-debt-remittances.md)).
- `fintech_agents` — `profile_id?` (bound on link), `provider`
  (`fintech_provider` enum), `provider_account_id`, KYC fields,
  `operation_zone_id`, `status` (`fintech_status`), `secret_pin_hash` + lockout,
  `invite_code?`, `indemnity_version?` / `indemnity_accepted_at?` /
  `indemnity_document_path?`. `UNIQUE(provider, provider_account_id)`.

## Flow

**Outlet:** `register_outlet` (FIELD_AGENT/INFORMAL_REP, zone from caller,
`PENDING_VERIFICATION`) → `verify_outlet` (REGIONAL_MANAGER/ADMIN).

**Guarantor:** `register_guarantor` → `verify_guarantor`.

**Fintech agent:**
1. `register_fintech_agent` — FIELD_AGENT collects provider + KYC; returns a
   one-time `invite_code`. Row has no `profile_id` yet.
2. Fintech installs the app, signs up with **phone OTP**, calls
   `link_fintech_agent(invite_code)` → binds `profile_id`, sets role.
3. `accept_fintech_indemnity(version, signature_path)` — **required before
   verification**.
4. `verify_fintech_agent` (REGIONAL_MANAGER/ADMIN) — rejects if indemnity not
   accepted; status `ACTIVE`; generates the 6-digit transaction PIN (bcrypt
   hash), queues an SMS.

`set_fintech_status(id, status, reason)` — ADMIN. `rotate_fintech_pin` /
`rotate_warehouse_pin` — ADMIN.

**Staff:** `invite_staff` — ADMIN/SUPER_ADMIN.

## Screens

- FIELD_AGENT: Register outlet, Register guarantor, Register fintech agent (→
  show invite code), My registered fintechs (verification + indemnity status).
- FINTECH_AGENT: Sign up + invite code, **Indemnity agreement** (blocks
  everything until signed), PIN setup.
- REGIONAL_MANAGER/ADMIN: Verification queue (outlets, guarantors, fintech
  agents → approve/reject).

## Invariants

- Nothing transacts while `PENDING_VERIFICATION`.
- A fintech agent cannot be `ACTIVE` without an accepted indemnity.
- Zone is taken from the caller's profile, never a parameter.

## Notes

Many shop owners are themselves fintech agents — no data collision (outlets
aren't users), but it is a fraud vector: see the self-dealing rule in
[alerts-and-fraud](alerts-and-fraud.md).
