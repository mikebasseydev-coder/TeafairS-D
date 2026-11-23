# Monvelo Technical Architecture

**B2B trade financing on the Teafair Route-to-Market platform**

| | |
|---|---|
| Document | Technical architecture specification |
| Date | 23 November 2026 |
| Source | `TeafairS-D`, branch `fix/monvelo-register-preflight`, commit `205d0e6` |
| Extracted from | the migrated local database (37 tables, 160 functions, 32 policies) and `supabase/functions/monvelo-*`, `supabase/seed.ts`, `tests/api/monvelo.spec.ts` |
| Governing documents | Spec A; Addendum A6 (Monvelo) §3–§22; Addendum A8 (Monvelo cover) |

<!-- pagebreak -->

## Contents

- 1. Executive overview
    - 1.1 What Monvelo is
    - 1.2 Tenant opt-in
    - 1.3 Architectural principles
    - 1.4 Scope and provenance of this document
- 2. Personas, roles and access
    - 2.1 Role model
    - 2.2 JWT claims
    - 2.3 Seeded personas
    - 2.4 Access matrix: operations
    - 2.5 Access matrix: reads of core tables
- 3. Database schema, RLS and security rulings
    - 3.1 Table inventory
    - 3.2 Core tables
    - 3.3 Status lifecycles
    - 3.4 Row-level security
    - 3.5 Column-level PII protection
    - 3.6 Security rulings referenced in the code
    - 3.7 Constants and scheduled jobs
- 4. Edge Functions reference
    - 4.1 Common error contract
    - 4.2 monvelo-agent-register
    - 4.3 monvelo-shop-consent
    - 4.4 monvelo-fund
    - 4.5 monvelo-confirm-delivery
    - 4.6 monvelo-confirm-repayment
    - 4.7 monvelo-cover-upload
    - 4.8 monvelo-insurance-declare (system)
    - 4.9 monvelo-insurance-webhook (system, public)
- 5. PostgreSQL RPC reference
    - 5.1 Callable by `authenticated` (API surface)
    - 5.2 Callable by `service_role` only
    - 5.3 Internal (no API grant)
    - 5.4 The recruitment RPCs in detail
- 6. End-to-end flows
    - 6.1 POS agent onboarding
    - 6.2 Settlement account change and idempotent retries
    - 6.3 Shop enrolment
    - 6.4 The financing lifecycle
    - 6.5 Who sees what along the way
- 7. Verification and test coverage
    - 7.1 Results at commit `205d0e6`
    - 7.2 Deno unit tests (Monvelo)
    - 7.3 pgTAP (database)
    - 7.4 Playwright API tests (`tests/api/monvelo.spec.ts`)
    - 7.5 Running the suites
- Appendix A. RLS predicates (verbatim)
- Appendix B. Columns of every Monvelo table

<!-- pagebreak -->

## 1. Executive overview

### 1.1 What Monvelo is

Monvelo is the trade-financing domain of Teafair (Addendum A6 to Spec A). A retail shop places a wholesale **trade order** with a brand owner (a *tenant*, such as TEAFAIR). Instead of buying on high-interest street credit, the shop's order is **funded by a third-party POS agent** (Moniepoint, OPay or PalmPay operators: `pos_network_enum`). The agent pays Teafair by Paystack bank transfer, the tenant dispatches the goods, the shop owner confirms delivery with a WhatsApp code, and the shop repays the agent within the brand's interest-free window. The agent earns the brand's **rebate** (`monvelo_brand_terms.rebate_bps`); a shop that repays late pays one **late charge** (`late_charge_bps`).

Monvelo is strictly B2B (A6 §15, user ruling 2026-10-28). It owns every `monvelo_*` table, the `areas` geography, the ZSA/ASA field roles and the `MONVELO_*` platform roles. It never reads or writes a `web_*` (storefront) table, and pgTAP 042 and 045 enforce that boundary. Shared with the rest of the platform are `payments`, the Paystack webhook (`process-payment`), `reconcile-funds`, OTP and the message router, `retail_shops`, `profiles`, `tenants` and `orders`.

### 1.2 Tenant opt-in

A tenant takes part only when its `monvelo_tenant_settings` row has `enabled = true`. Every street-agent RPC checks this live (`42501 "Monvelo is not enabled for this tenant"`), and `is_monvelo_field_agent()`, which gates the read of ACTIVE agents, joins on it. The same row holds the tenant's credit policy (`opening_limit`, `approval_cap`, `max_limit`, `limit_growth_bps`, `default_cure_days`, `post_default_limit_bps`) and its goods-in-transit opt-in (`git_cover_enabled`). Settings are written only through `set_monvelo_tenant_settings` (ZSM or Client Service Manager), which must cite a reviewed, hard-copied `MONVELO_SETTINGS` contact-report decision (A6 §16, "zero backdoors").

In the local seed, TEAFAIR is opted in and LAGOSFMCG has no settings row, so it is opted out.

### 1.3 Architectural principles

| Principle | How it is enforced |
|---|---|
| **No direct client writes** | `authenticated` holds `SELECT` only; every RLS policy on the 37 Monvelo tables is `FOR SELECT`; every mutation is a `SECURITY DEFINER` RPC. Five tables have RLS on and **no policy at all** (read only inside RPCs). |
| **The database decides** | The tenant comes from the JWT (`jwt_tenant_id()`) and is re-verified live against `tenant_users` by `assert_tenant_role`; platform roles are read live from `profiles.platform_role` by `assert_platform_role`. Claims propose, the database decides. |
| **Gateways forward the caller's JWT** | User gateways (`userGateway`) call RPCs as the caller. No `monvelo-*` user gateway holds the secret key (Ruling 46); only the two insurer system functions use `serviceRpc()`. |
| **Gateway proof for code-bearing RPCs** | RPCs that draw a WhatsApp code or carry a bank-resolved name demand `p_gateway_proof`, checked by `assert_gateway_proof` against the Vault secret `gateway_secret`. A direct PostgREST call cannot forge it. |
| **Strict idempotency** | Every mutation takes `p_idempotency_key uuid` first. `idempotency_begin` hashes the request (SHA-256) and stores it with the actor; a replay returns the stored response, and a changed request, operation or actor is `TF002` (HTTP 409 `IDEMPOTENCY_MISMATCH`). |
| **Lenders are invisible to tenants** | A6 §16.2.2: audit rows naming an agent, pledge, payer, payable or repayment are written with `tenant_id = null` (rulings R15, R19, R55), because a tenant's ZSMs and TMs read `audit_logs` tenant-wide. Lender columns of `monvelo_financings` are outside the tenant's column grant (R9). |
| **PII column hiding** | `monvelo_agents.settlement_account_number`, `settlement_bank_code`, `pending_settlement` and `paystack_payer_ref`, and every `payments.monvelo_*` column, are granted to no API role. Responses and audit rows carry the last four digits only. |
| **Codes never leave the database twice** | Shop-owner codes (consent, delivery, repayment) are drawn in Postgres, returned to the gateway on the first call only, sent over WhatsApp only, and never stored in `idempotency_logs`, so a replay sends nothing. |

### 1.4 Scope and provenance of this document

Every table, column, function signature, grant, policy, status value and cron job in this document was extracted from the local database with all migrations applied (including `20261123120000_monvelo_agent_register_preflight`), or read from the source files named. It describes the code on branch `fix/monvelo-register-preflight` at commit `205d0e6`. Deployment state is outside its scope; the preflight migration is new and local.

<!-- pagebreak -->

## 2. Personas, roles and access

### 2.1 Role model

Roles live in two places, and both are read **live**, never from the JWT alone:

- **Tenant roles** (`tenant_role_enum`, on `tenant_users.role`, per tenant): `ZSM`, `TM`, `ASM`, `DSM`, `DSA`, `POS_AGENT`, `RETAIL_SHOP_OWNER`, `ZSA`, `ASA`, `CLIENT_SERVICE_MANAGER`, `TENANT_ADMIN`, `LOGISTICS_MANAGER`.
- **Platform roles** (`platform_role_enum`, on `profiles.platform_role`, tenant-free): `PLATFORM_SUPER_ADMIN`, `MONVELO_OPERATOR`, `MONVELO_FINANCE`. `is_monvelo_staff()` is true for either Monvelo role; `is_monvelo_operator()` for the operator only.
- **Agent membership** is neither: a profile is staff of a POS agent through an `ACTIVE` row in `monvelo_agent_members` (`my_monvelo_agent_ids()`).
- **Shop ownership** is `retail_shops.owner_id` (`my_owned_shop_ids()`).

The geography is zone → territory → **area** (A6 §3). A ZSA works a zone (`tenant_users.zone_id`, reporting to a ZSM: CHECK `tenant_users_zsa_anchor`); an ASA works one area (`territory_id` and `area_id`, reporting to a TM or ASM: CHECK `tenant_users_asa_anchor`).

### 2.2 JWT claims

The Custom Access Token Hook writes `app_metadata` claims, which the API tests assert for every persona:

| Claim | Meaning |
|---|---|
| `active_tenant_id` | The tenant the session acts in. RPCs re-verify membership in it live. |
| `tenant_role` | The caller's role in the active tenant. |
| `tenant_ids` | Every tenant the caller belongs to (empty for platform staff, shop owners and agent staff). |
| `platform_role` | `MONVELO_OPERATOR`, `MONVELO_FINANCE` or `PLATFORM_SUPER_ADMIN`, else absent. |

### 2.3 Seeded personas

`supabase/seed.ts` builds these personas locally (password-based, local stack only; the seed refuses any non-localhost URL):

| Persona | Login | How it is modelled | Claims | Monvelo standing |
|---|---|---|---|---|
| **ASA** | `asa@rtm.local` | `tenant_users` ASA, territory Ojodu-Berger, area Ojodu Central, reports to rep1 (TM) | TEAFAIR / `ASA` | Street agent: registers and recruits POS agents, enrols shops, raises financing |
| **ZSA** | `zsa@rtm.local` | `tenant_users` ZSA, zone Lagos Mainland North, reports to the ZSM | TEAFAIR / `ZSA` | Street agent at zone level; same RPC gates as the ASA |
| **TM** | `rep1@rtm.local`, `rep2@rtm.local` | `tenant_users` TM of a territory | TEAFAIR / `TM` | Sets supply days, raises and approves financing; cannot register agents |
| **ZSM** | `manager@rtm.local` | `tenant_users` ZSM; `zones.zsm_id` of the zone | TEAFAIR / `ZSM` | Settings and brand terms (with CSM), hold decisions only as fallback; cannot register agents |
| **Monvelo operator** | `monvelo-ops@rtm.local` | `profiles.platform_role = MONVELO_OPERATOR`, no tenant | `platform_role` only | Approves agents and account changes, sets caps, adds members, runs insurance |
| **Shop owner** | `shop-owner@rtm.local` | `retail_shops.owner_id` of the first Ojodu outlet, no tenant | none | Receives consent, delivery and repayment codes; withdraws consent; rejects repayments |
| **Fintech agent** | `pos-agent@rtm.local` | `ACTIVE` member of the seeded `ACTIVE` POS agent `MP-SEED-OJODU-0001` (recruited by the ASA) | none | Pledges, claims, funds, records repayments, reads its exposure |
| **LAGOSFMCG TM** | `lagos-tm@rtm.local` | `tenant_users` TM of LAGOSFMCG's territory | LAGOSFMCG / `TM` | Tenant not opted in |
| **LAGOSFMCG ASA** | `lagos-asa@rtm.local` | `tenant_users` ASA of LAGOSFMCG's Allen area | LAGOSFMCG / `ASA` | Right role, tenant not opted in: refused with 42501 |

**`POS_AGENT` is not the fintech agent.** `POS_AGENT` (formerly `FINTECH_AGENT`, renamed in A6 §15) is a **web storefront** tenant role tied to `web_pos_partners` and `web_pos_venues`. No Monvelo RPC admits it: the only Monvelo function that names it, `monvelo_order_financing_status`, returns nothing to a `POS_AGENT`. The Monvelo "fintech agent" is a member of a `monvelo_agents` row, a tenant-free relationship.

Also in the schema but not seeded: `MONVELO_FINANCE` (records paid premiums and top-ups), `CLIENT_SERVICE_MANAGER` (represents a tenant in house), `LOGISTICS_MANAGER` (dispatch) and `TENANT_ADMIN` (the tenant's read-only login; every write RPC refuses it except the A7 support-ticket RPCs).

### 2.4 Access matrix: operations

Derived from each RPC's `assert_tenant_role(...)`, `assert_platform_role(...)`, membership and ownership checks (section 5 lists every gate). ✓ = permitted; **cond.** = permitted with an extra condition noted below; blank = refused (42501).

| Operation (RPC / gateway) | ASA | ZSA | TM | ZSM | Shop owner | Fintech agent | Operator |
|---|---|---|---|---|---|---|---|
| Register POS agent (`monvelo-agent-register` register) | ✓ | ✓ | | | | | |
| Request settlement change (`change_settlement`) | cond.¹ | cond.¹ | | | | | |
| Approve agent / settlement change, suspend, set caps, add member | | | | | | | ✓ |
| Create or rename an area (`upsert_area`) | | | cond.² | cond.² | | | |
| Set a supply day (`set_monvelo_supply_day`) | | | cond.³ | | | | |
| Enrol a shop: start consent, enrol (`monvelo-shop-consent`) | cond.⁴ | cond.⁴ | | | code holder | | |
| Withdraw shop consent | | | | | ✓ | | |
| Nominate a POS agent (`nominate_monvelo_agent`) | ✓ | ✓ | | | cond.⁹ | | |
| Pledge funds for a supply day | | | | | | ✓ | |
| Request financing (`request_monvelo_financing`) | ✓ | ✓ | ✓ | | | | |
| Approve financing above the limit | | | cond.⁵ | | | | |
| Cancel financing | cond.⁶ | cond.⁶ | ✓ | | | | |
| Claim an offer / start funding (`monvelo-fund`) | | | | | | ✓ | |
| Decide a held claim (`decide_monvelo_claim_hold`) | cond.⁷ | cond.⁷ | | fallback⁷ | | | |
| Dispatch / confirm delivery (`monvelo-confirm-delivery`; fulfilment roles, see below) | | | | | code holder | | |
| Record / confirm repayment (`monvelo-confirm-repayment`) | | | | | code holder | ✓ | |
| Reject a repayment | | | | | ✓ | | |
| Tenant settings, brand terms approve/withdraw | | | | ✓ | | | |
| Agent exposure meter (`get_monvelo_agent_exposure`) | | | | | | ✓ | ✓ |
| Lender reconciliation summary | cond.⁸ | cond.⁸ | | | | ✓ | |
| Insurers, products, claims, flags, shop-policy review | | | | | | | ✓ |

1. Only the street agent who recruited the agent (`recruited_by`); checked in the preflight and again in the RPC.
2. ZSM of the territory's zone, or the territory's TM.
3. The TM of the area's territory.
4. The area must be in the caller's tenant; a ZSA's area must lie in the ZSA's zone; an ASA's area must be its own `area_id`.
5. The territory's TM.
6. The raiser of the request, or the TM.
7. Deciders are ACTIVE ZSAs of the request's zone and ASAs of its area (A6 §22); ZSMs in reach decide only when no field agent is eligible. Never the raiser, never anyone with a membership row in the held agent (R78).
8. A ZSA sees their zone, an ASA their area, in the active tenant; an agent's member sees their own agent across tenants.
9. The shop's owner must also be an ACTIVE `RETAIL_SHOP_OWNER` member of the tenant in their session (re-verified live). The seeded shop owner has no membership, so it is refused.

Dispatch and delivery are decided by the fulfilment helpers (`fulfilment_can_dispatch`, `fulfilment_delivery_path`), as for web orders. The shop owner never calls the delivery or repayment gateway; they read the code out to the deliverer or recorder, who types it in.

### 2.5 Access matrix: reads of core tables

From the `FOR SELECT` policies (verbatim predicates in Appendix A):

| Table | ASA / ZSA | TM / ZSM | Shop owner | Fintech agent | Monvelo staff |
|---|---|---|---|---|---|
| `monvelo_tenant_settings` | own tenant | own tenant | | | all |
| `areas` | own tenant | own tenant | | | |
| `monvelo_agents` | ACTIVE agents (opted-in tenant) | | | own agent | all |
| `monvelo_agent_members` | | | | own row | all |
| `monvelo_shop_enrolments` | own tenant¹ | own tenant¹ | own shop | | all |
| `monvelo_financings` | raised by me, or my territory² | my territory; ZSM: territories in reach² | own shop | claimed or funded by own agent | all |
| `monvelo_pledges`, `monvelo_financing_claims`, `monvelo_rebate_payables` | | | | own agent | all |
| `monvelo_flags`, `monvelo_insurers`, `monvelo_premium_payables`, cover tables | | | | | all |
| `monvelo_claim_holds`, `monvelo_owner_challenges`, `monvelo_consent_challenges`, `monvelo_insurance_declarations`, `monvelo_insurer_events` | | | | | none: no policy |
| `audit_logs` rows with `tenant_id = null` | | | | | none: no policy |

1. `my_monvelo_staff_tenant_ids()`: tenants where the caller is ACTIVE tenant staff (ZSM, TM, ASM, DSM, DSA, ZSA, ASA, CLIENT_SERVICE_MANAGER, TENANT_ADMIN).
2. `raised_by = auth.uid()`, `my_monvelo_territory_ids()` or `my_zsm_territory_ids()`; TENANT_ADMIN and CSM read their tenant's rows, a LOGISTICS_MANAGER the FUNDED ones. Lender columns stay hidden (section 3.5).

The API tests prove the key cells: a PENDING agent is invisible to every tenant persona and to field agents; the seeded ACTIVE agent is visible to the TEAFAIR ASA and ZSA and to the operator, and hidden from the TM, ZSM, shop owner and both LAGOSFMCG users.

<!-- pagebreak -->

## 3. Database schema, RLS and security rulings

### 3.1 Table inventory

All 37 Monvelo tables (36 `monvelo_*` plus `areas`), with their column and policy counts. Every one has row-level security enabled.

| Table | Columns | SELECT policies | API readers |
|---|---|---|---|
| `areas` | 6 | 1 | per policy (Appendix A) |
| `monvelo_agent_members` | 4 | 1 | per policy (Appendix A) |
| `monvelo_agent_nominations` | 10 | 1 | per policy (Appendix A) |
| `monvelo_agents` | 22 | 1 | per policy (Appendix A) |
| `monvelo_brand_terms` | 15 | 1 | per policy (Appendix A) |
| `monvelo_claim_holds` | 16 | 0 | **none**: RPCs only |
| `monvelo_consent_challenges` | 11 | 0 | **none**: RPCs only |
| `monvelo_financing_claims` | 10 | 1 | per policy (Appendix A) |
| `monvelo_financing_cover` | 14 | 1 | per policy (Appendix A) |
| `monvelo_financing_line_cover` | 12 | 1 | per policy (Appendix A) |
| `monvelo_financing_lines` | 10 | 1 | per policy (Appendix A) |
| `monvelo_financings` | 34 | 1 | per policy (Appendix A) |
| `monvelo_flags` | 10 | 1 | per policy (Appendix A) |
| `monvelo_insurance_claims` | 26 | 1 | per policy (Appendix A) |
| `monvelo_insurance_declarations` | 15 | 0 | **none**: RPCs only |
| `monvelo_insurance_products` | 16 | 1 | per policy (Appendix A) |
| `monvelo_insurer_events` | 4 | 0 | **none**: RPCs only |
| `monvelo_insurers` | 9 | 1 | per policy (Appendix A) |
| `monvelo_order_git_cover` | 10 | 1 | per policy (Appendix A) |
| `monvelo_owner_challenges` | 11 | 0 | **none**: RPCs only |
| `monvelo_platform_settings` | 6 | 1 | per policy (Appendix A) |
| `monvelo_pledges` | 10 | 1 | per policy (Appendix A) |
| `monvelo_premium_payables` | 13 | 1 | per policy (Appendix A) |
| `monvelo_rebate_payable_lines` | 3 | 1 | per policy (Appendix A) |
| `monvelo_rebate_payables` | 9 | 1 | per policy (Appendix A) |
| `monvelo_rebate_topups` | 13 | 1 | per policy (Appendix A) |
| `monvelo_repayments` | 10 | 1 | per policy (Appendix A) |
| `monvelo_shop_enrolments` | 10 | 1 | per policy (Appendix A) |
| `monvelo_shop_limit_events` | 9 | 1 | per policy (Appendix A) |
| `monvelo_shop_limits` | 7 | 1 | per policy (Appendix A) |
| `monvelo_shop_policies` | 22 | 1 | per policy (Appendix A) |
| `monvelo_supply_days` | 7 | 1 | per policy (Appendix A) |
| `monvelo_tenant_fee_terms` | 8 | 1 | per policy (Appendix A) |
| `monvelo_tenant_ledger_entries` | 7 | 1 | per policy (Appendix A) |
| `monvelo_tenant_settings` | 11 | 1 | per policy (Appendix A) |
| `monvelo_terms_acceptances` | 9 | 1 | per policy (Appendix A) |
| `monvelo_terms_versions` | 9 | 1 | per policy (Appendix A) |

### 3.2 Core tables

**`monvelo_tenant_settings`**: one row per tenant (`tenant_id` primary key, FK `tenants`). Columns: `enabled`, `opening_limit` and `approval_cap` (`numeric(15,2)`, non-negative), `max_limit` (CHECK `max_limit >= opening_limit`), `limit_growth_bps`, `default_cure_days`, `post_default_limit_bps`, `git_cover_enabled`, `decision_id` (composite FK to `contact_report_decisions`), `updated_at`.

**`monvelo_agents`**: the POS agents, platform-wide (no `tenant_id`). Key columns: `business_name`, `pos_network` (`pos_network_enum`), `network_agent_id` (CHECK upper-case and trimmed; **unique per `pos_network`**, the race-safe duplicate guard), `contact_phone`, `location` (`geography(Point,4326)`), `address_text`, the settlement account (`settlement_account_number` CHECK ten digits, `settlement_account_last4`, `settlement_bank_code`, `settlement_account_name`), `pending_settlement` (jsonb), `paystack_payer_ref`, `network_kyc_reference`, `recruited_by` (FK `profiles`), `status`, `approved_by`, `approved_at`, `daily_cap` and `per_financing_cap` (CHECK `per_financing_cap <= daily_cap`).

**`monvelo_agent_members`**: an agent's staff logins. Primary key `(agent_id, profile_id)`, `status` `ACTIVE` or `REVOKED`.

**`areas`**: core geography under a territory (`tenant_id`, `territory_id`, `area_name`, `asa_id`), with composite FK `(tenant_id, territory_id)` to `territories` and uniqueness of the name per territory.

**`idempotency_logs`** (shared): `key` (unique), `tenant_id` (recorded only when the caller really belongs to it), `actor_id`, `operation`, `request_hash` (SHA-256 of the request jsonb), `status` (`IN_PROGRESS` then `COMPLETED`) and `response`. Policy `idempotency_logs_select_actor`: only the actor reads their rows.

**`audit_logs`** (shared): `tenant_id`, `actor_id`, `actor_role`, `operation`, `entity_type`, `entity_id`, `idempotency_key`, `source` (`USER`, `CRON`, ...), `before`, `after`. The only policy, `audit_logs_select_zsm_tm`, admits rows whose `tenant_id` is a tenant where the caller is ZSM (zone-scoped) or TM (territory-scoped). A row with `tenant_id = null` therefore has **no API reader at all**.

### 3.3 Status lifecycles

From the CHECK constraints:

| Table | Column | Values |
|---|---|---|
| `monvelo_agents` | `status` | `PENDING` → `ACTIVE` → `SUSPENDED` |
| `monvelo_agent_members` | `status` | `ACTIVE`, `REVOKED` |
| `monvelo_shop_enrolments` | `status` | `ACTIVE`, `SUSPENDED`, `WITHDRAWN` |
| `monvelo_agent_nominations` | `status` | `OPEN`, `RECRUITED`, `DECLINED` |
| `monvelo_brand_terms` | `status` | `PROPOSED`, `APPROVED`, `WITHDRAWN` |
| `monvelo_financings` | `status` | `REQUESTED`, `AWAITING_APPROVAL`, `OFFERED`, `HELD`, `CLAIMED`, `FUNDED`, `DELIVERED`, `REPAID_WITHIN_WINDOW`, `DEFAULTED_WITH_LATE_CHARGE`, `REPAID_LATE`, `EXPIRED`, `CANCELLED`, `REFUND_DUE`, `CLOSED_BY_CLAIM` |
| `monvelo_financing_claims` | `outcome` | `LAPSED`, `FUNDED`, `EXPIRED` |
| `monvelo_claim_holds` | `status` | `HELD`, `ALLOWED`, `DECLINED`, `LAPSED` (decided ⇔ `decided_by` set) |
| `monvelo_repayments` | `status` | `PENDING`, `CONFIRMED`, `REJECTED`, `EXPIRED` |
| `monvelo_owner_challenges` | `purpose` | `DELIVERY`, `REPAYMENT` |
| `monvelo_consent_challenges` | `purpose` | `ENROLMENT`, `SHOP_POLICY` |
| `monvelo_shop_limits` | `status` | `ACTIVE`, `FROZEN` |
| `monvelo_shop_limit_events` | `kind` | `OPENED`, `GROWN`, `FROZEN`, `RESET` |
| `monvelo_rebate_payables` | `status` | `DUE`, `CANCELLED` |
| `monvelo_flags` | `status` / `kind` | `OPEN`, `REVIEWED` / `PAYER_MISMATCH`, `LATE_PAYMENT`, `AMOUNT_MISMATCH`, `REPAYMENT_REJECTED`, `REPAYMENT_UNCONFIRMED`, `FUNDING_REFUNDED`, `DECLARATION_FAILED`, `DECLARATION_STALE`, `DECLARATION_REJECTED`, `CLAIM_SHORTFALL`, `CLAIM_SETTLED_AFTER_CLOSE`, `POLICY_WITHDRAWN_OPEN_FINANCING`, `PREMIUM_RECOVERY`, `CLAIM_OVER_RECOVERY` |
| `monvelo_shop_policies` | `status` | `PENDING`, `VERIFIED`, `REJECTED`, `EXPIRED`, `WITHDRAWN` (VERIFIED needs fire, burglary and the lender-interest endorsement) |
| `monvelo_financing_cover` | `cover_kind` / `declared_status` | `SHOP_POLICY`, `AUTO_POLICY`, `NONE` / `NOT_DUE`, `PENDING`, `ACCEPTED`, `REJECTED`, `CANCELLED` |
| `monvelo_insurance_claims` | `status` | `REPORTED`, `FILED`, `UNDER_REVIEW`, `SETTLED`, `REJECTED`, `WITHDRAWN` |
| `monvelo_insurance_declarations` | `kind` / `status` | `GIT_DECLARE`, `STORAGE_DECLARE`, `STORAGE_CANCEL`, `CLAIM_FILE` / `PENDING`, `SENDING`, `ACCEPTED`, `REJECTED`, `FAILED` |
| `monvelo_terms_versions` | `status` | `DRAFT`, `PUBLISHED`, `RETIRED` |

The financing status machine is enforced by the `monvelo_financings_guard` trigger. Monvelo records are never deleted (`monvelo_no_delete`, `monvelo_refuse_delete`), and the ledgers are insert-only (`monvelo_insert_only`, `monvelo_ledger_insert_only`, `monvelo_shop_limit_events_insert_only`, `monvelo_rebate_payable_lines_insert_only`).

### 3.4 Row-level security

Every Monvelo policy is `FOR SELECT TO authenticated` and calls `public.*` helpers through `(select ...)`, so each helper is evaluated once per statement, not per row (Spec A §9). The helpers (`is_monvelo_staff`, `is_monvelo_field_agent`, `my_monvelo_agent_ids`, `my_owned_shop_ids`, `my_tenant_ids_with_role`, ...) are `SECURITY DEFINER STABLE` functions that read `profiles`, `tenant_users` and `monvelo_agent_members` live.

Five tables have RLS enabled and **no policy**, so they are readable only inside `SECURITY DEFINER` RPCs: `monvelo_claim_holds`, `monvelo_consent_challenges`, `monvelo_owner_challenges` (the shop owner's code hashes), `monvelo_insurance_declarations` and `monvelo_insurer_events`. `service_role` holds no write on the Monvelo tables (pgTAP 054, 061).

### 3.5 Column-level PII protection

Table grants are column by column where a table holds secrets:

| Table | Columns granted to no API role |
|---|---|
| `monvelo_agents` | `settlement_account_number`, `settlement_bank_code`, `pending_settlement`, `paystack_payer_ref` |
| `monvelo_financings` | `preferred_agent_id`, `claimed_by_agent_id`, `claimed_by`, `pledge_id`, `funder_agent_id`, `paystack_reference` (R9: the tenant never sees its lender) |
| `payments` | `monvelo_financing_id`, `monvelo_agent_id`, `monvelo_started_by`, `monvelo_authorization_url`, `monvelo_access_code` |

The API test asks PostgREST for `settlement_account_number` as the **operator** and gets a refusal: not even Monvelo staff can read it through the API. Audit payloads for agents go through `monvelo_agent_audit(monvelo_agents)`, which drops the account number, bank code, pending settlement, payer reference, phone and location.

### 3.6 Security rulings referenced in the code

| Ruling | Rule |
|---|---|
| **R9** | The lender columns of `monvelo_financings` are outside the tenant's column grant. |
| **R15 / R19 / R55** | Audit rows naming an agent, pledge, payer, payable, repayment or its recorder are tenant-null. The four recruitment RPCs (`register_monvelo_agent`, `request_monvelo_settlement_change`, `nominate_monvelo_agent`, `close_monvelo_nomination`) write `write_audit(null, ...)` (migration `20261031120060`). |
| **R20** | Only a holder of a `fulfilment_delivery_path` confirms a delivery; a code alone never does. |
| **R30 / R32 / R54** | An expired or locked repayment code ends its repayment; only the recording member confirms; recording again ends the recorder's own dead-code PENDING repayment quietly. |
| **R53 / R59** | `monvelo-fund` stores the Paystack checkout (`record_monvelo_checkout`, gateway proof, only the payment's starter) so a replay returns it without re-initialising. |
| **R63** | `REFUND_DUE` counts toward neither the open exposure nor the daily cap. |
| **R78** | Anyone with a membership row in the held agent is never a market maker for its hold. |
| **Ruling 46** | API keys are read only through `_shared/core/keys.ts`; only reviewed system functions reach the secret key; no secret under a client prefix. |
| **Preflight (2026-11-23)** | `monvelo-agent-register` authorises and replays before calling Paystack (section 4.1, migration `20261123120000`). |

### 3.7 Constants and scheduled jobs

| Constant | Value | Where |
|---|---|---|
| Open exposure ceiling | ₦1,000,000 | `monvelo_open_exposure_ceiling()` (A6 §21; was ₦100,000) |
| Market-maker allowance ceiling | ₦3,000,000 | `monvelo_allowance_ceiling()` |
| Claim hold | 15 minutes | `monvelo_claim_holds` / `monvelo_sweep_offers` |
| Delivery cutoff | `funded_at` + 23 hours | `monvelo_delivery_cutoff()` |
| Radius, preferred window, claim window | 1000 m, 10 min, 15 min | `monvelo_platform_settings` |

| Cron job | Schedule | Command |
|---|---|---|
| `monvelo-offer-sweep` | every minute | `monvelo_sweep_offers()`: lapsed claims and holds, expired requests |
| `monvelo-money-sweep` | every 5 minutes | `monvelo_sweep_money()`: REFUND_DUE, the late charge, stale repayments |
| `monvelo-insurance-declare` | every minute | `invoke_system_function('monvelo-insurance-declare')` |
| `monvelo-declaration-sweep` | every 15 minutes | `monvelo_sweep_declarations()` |
| `monvelo-shop-policy-sweep` | 05:00 UTC daily | `monvelo_sweep_shop_policies()` |

<!-- pagebreak -->

## 4. Edge Functions reference

All eight functions are `POST /functions/v1/<name>` with `verify_jwt = false` in `config.toml`: each authenticates its caller itself. Six are **user gateways** (`userGateway`: POST only → JWT verified with `auth.getClaims` → client `tenantId`, `tenant_id` and `p_tenant_id` keys stripped at every depth → Zod → handler → error mapping), which run every RPC on the caller's JWT. Two are **system functions** that use `serviceRpc()` after their own authentication (Ruling 46).

### 4.1 Common error contract

The gateway maps Postgres SQLSTATEs (`_shared/core/errors.ts`):

| SQLSTATE | HTTP | `error.code` |
|---|---|---|
| `P0001` | 422 | `BUSINESS_RULE` |
| `42501` | 403 | `FORBIDDEN` |
| `23505` | 409 | `CONFLICT` |
| `TF001` | 409 | `INSUFFICIENT_STOCK` |
| `TF002` | 409 | `IDEMPOTENCY_MISMATCH` |
| `40001`, `55P03` | 503 | `RETRY` |
| `PGRST301` | 401 | `UNAUTHENTICATED` |
| anything else | 500 | `INTERNAL` (generic message, logged without data) |

Gateway errors of their own: 401 (no or invalid JWT), 400 `INVALID_JSON`, 400 `VALIDATION_FAILED`, 405 `METHOD_NOT_ALLOWED`. Bodies are `{ "error": { "code", "message", "details" } }`. Across the Monvelo migration files (counting functions that later migrations recreate), `errcode` occurrences are `P0001` (535), `42501` (144), `22023` (15, in three PostgREST-called reads and decisions: `decide_monvelo_claim_hold`, `get_monvelo_agent_exposure`, `get_lender_reconciliation_summary`), `23505` (4), `40001` (1) and `TF002` (the preflight; every other `TF002` comes from `idempotency_begin`).

### 4.2 monvelo-agent-register

A street agent registers a POS agent, or asks to change an agent's settlement account (A6 §6.3). Teafair does no duplicate KYC: the bank account's existence is checked with Paystack `/bank/resolve`, and the **resolved** holder name, never a client-sent one, goes to the database.

**Pipeline** (since `20261123120000`):

```
 client             gateway (userGateway)              Postgres                    Paystack
   |  POST + JWT      |                                    |                           |
   |----------------->| 1 verify JWT (401)                 |                           |
   |                  | 2 strip tenant keys, Zod (400)     |                           |
   |                  |   idempotency_key: strict UUID v4  |                           |
   |                  |   phone normalised (400)           |                           |
   |                  | 3 monvelo_agent_register_preflight |                           |
   |                  |----------------------------------->| role gate ZSA/ASA (42501) |
   |                  |                                    | opted-in tenant (42501)   |
   |                  |                                    | recruiter (change only)   |
   |                  |                                    | key lookup:               |
   |                  |<-----------------------------------|  replay / TF002 / new     |
   |<-- 200 replay ---| (replay: stop here, no Paystack)   |                           |
   |                  | 4 GET /bank/resolve ---------------------------------------->|
   |                  |<------------------------------------------ account_name -----|
   |                  | 5 register / settlement-change RPC |                           |
   |                  |----------------------------------->| same gates + gateway proof|
   |                  |                                    | idempotency_begin, write, |
   |                  |<-----------------------------------| tenant-null audit         |
   |<---- 200 --------|                                    |                           |
```

**Request** (`action: "register"`): `idempotency_key` (UUID v4: version 4, variant 8/9/a/b), `business_name` (1–200), `pos_network` (`MONIEPOINT` · `OPAY` · `PALMPAY`), `network_agent_id` (1–64), `contact_phone` (7–24, normalised to E.164), `latitude` (−90..90), `longitude` (−180..180), `address_text` (1–500), `network_kyc_reference` (1–100), `settlement_account_number` (exactly ten digits), `settlement_bank_code` (1–16).

**Request** (`action: "change_settlement"`): `idempotency_key`, `agent_id` (uuid), `settlement_account_number`, `settlement_bank_code`.

**Responses (200)**: register `{ agent_id, status: "PENDING", name_matches, settlement_account_last4 }`; change `{ agent_id, status: "PENDING_APPROVAL", settlement_account_last4 }`. Neither carries the account number or the phone.

**Errors**: 401; 400 `VALIDATION_FAILED` (including a v1/v7 key or a key sent only as `x-idempotency-key`); 403 `FORBIDDEN` (role, tenant not opted in, not the recruiter); 409 `IDEMPOTENCY_MISMATCH` (same key, different request or actor); 409 `CONFLICT` (the network agent is already registered); 422 `ACCOUNT_NOT_RESOLVED` (Paystack refused the account; only an authorised street agent can reach this); 422 `BUSINESS_RULE` (unknown agent); 502 `BANK_VERIFICATION_UNAVAILABLE`; 503 `RETRY` (a concurrent request holds the key).

**Idempotency**: the hashed request is the client's request only (`monvelo_recruitment_request`), so a holder name that changed at the bank cannot break a replay. A completed key replays its stored answer from the preflight with **no Paystack call**. **Env**: `PAYSTACK_SECRET_KEY`, optional `PAYSTACK_API_BASE`, `GATEWAY_SECRET`.

### 4.3 monvelo-shop-consent

A street agent enrols a shop with its owner's consent (A6 §4.1, consent text `MV-SHARE-2026-10`), and (A8 §6.3) records the shop's own fire and burglary policy.

| Action | Body | RPC | Effect |
|---|---|---|---|
| `start` | `shop_id`, `area_id` | `start_monvelo_consent` (proof) | DB draws a 6-digit code; gateway sends it to the owner's verified phone, WhatsApp only |
| `enrol` | `challenge_id`, `code` (6 digits) | `enrol_monvelo_shop` | Spends the code; returns `{ enrolled: true, shop_code }` |
| `start_policy` | `shop_id`, `area_id` | `start_monvelo_policy_consent` (proof) | As `start`, purpose `SHOP_POLICY` |
| `submit_policy` | `challenge_id`, `code`, `insurer_name`, `policy_number`, `covers_fire_perils`, `covers_burglary`, `sum_insured`, `lender_interest_endorsed`, `starts_on`, `expires_on`, `document_path` | `submit_monvelo_shop_policy` | Spends the code; policy `PENDING` for an operator's review |

Start replies `{ challenge_id, expires_at, destination }` (masked phone). A wrong, expired or locked code comes back from the RPC as data (so the attempt counter commits) and becomes 422 `CONSENT_CODE_INVALID`, `CONSENT_CODE_EXPIRED` or `CONSENT_CODE_LOCKED`. A failed send is 502 `MESSAGE_DELIVERY_FAILED`. A replayed start carries no code and sends nothing. **Env**: `GATEWAY_SECRET`.

### 4.4 monvelo-fund

An agent's member starts the Paystack bank transfer that funds a claimed financing.

- **Body**: `idempotency_key`, `financing_id`, `agent_id`.
- **Sequence**: `start_monvelo_funding` (member of an ACTIVE agent holding the claim; draws reference `MV-<financing>-<n>`) → Paystack Initialize (`channels: ["bank_transfer"]`, no split, no callback URL, email `monvelo-<reference>@pay.teafairweb.com`, metadata `{ kind: "monvelo", financing_id }`) → `record_monvelo_checkout` (gateway proof; idempotency key derived from SHA-256 of the payment id, so a retried store replays).
- **Response**: `{ reference, authorization_url, access_code }`. A replay returns the stored checkout without calling Paystack (R53).
- **Errors**: 502 `PAYSTACK_UNAVAILABLE`; 409 `MONVELO_CHECKOUT_LOST` when a replay finds nothing stored and Paystack refuses the duplicate reference (the client starts again with a new key).
- **Settlement**: the Paystack webhook (`process-payment`) and `reconcile-funds` route `MV-` references to `settle_monvelo_funding` (service_role). A funding counts only if Verify shows a bank transfer from an account ending in the agent's `settlement_account_last4` whose holder name matches (`monvelo_payer_matches`); otherwise a `PAYER_MISMATCH` flag. **Env**: `PAYSTACK_SECRET_KEY`, `PAYSTACK_API_BASE`, `GATEWAY_SECRET`.

### 4.5 monvelo-confirm-delivery

| Action | Body | RPC | Response |
|---|---|---|---|
| `start` | `financing_id` | `start_monvelo_delivery` (proof; a `fulfilment_delivery_path` holder; dispatched, funded financing only) | `{ challenge_id, expires_at, destination }`; code sent over WhatsApp to the owner |
| `confirm` | `challenge_id`, `code` | `confirm_monvelo_delivery` (the deliverer, R20) | `{ confirmed: true, due_at }`: the repayment clock starts and the tenant ledger books `FUNDED_GROSS` and the fee |

Refusals: 422 `DELIVERY_CODE_INVALID` · `DELIVERY_CODE_EXPIRED` · `DELIVERY_CODE_LOCKED`; 502 `MESSAGE_DELIVERY_FAILED`. **Env**: `GATEWAY_SECRET`.

### 4.6 monvelo-confirm-repayment

| Action | Body | RPC | Response |
|---|---|---|---|
| `record` | `financing_id`, `agent_id`, `amount` (positive, at most two decimals) | `record_monvelo_repayment` (proof; the funder's member) | `{ repayment_id, challenge_id, expires_at, destination }` |
| `confirm` | `challenge_id`, `code` | `confirm_monvelo_repayment` (only the recorder, R32) | `{ confirmed: true, outstanding, status }` |

Refusals: 422 `REPAYMENT_CODE_INVALID` · `REPAYMENT_CODE_EXPIRED` · `REPAYMENT_CODE_LOCKED`. A failed send is 502 `MESSAGE_DELIVERY_FAILED`; the repayment stays PENDING, holding its amount, until its code lapses in 10 minutes. The notification log for this code is platform-level (no tenant), so no tenant's ZSM reads a lender's log row (§16.2.2). The owner may instead reject the repayment (`reject_monvelo_repayment`), which raises a flag and a HIGH ticket. **Env**: `GATEWAY_SECRET`.

### 4.7 monvelo-cover-upload

A signed upload slot for a cover document (A8 §6.3): a shop's policy certificate or loss evidence.

- **Body**: `purpose` (`SHOP_POLICY` · `CLAIM_EVIDENCE`), `subject_id` (shop or financing uuid), `content_type` (`application/pdf` · `image/jpeg` · `image/png`), `byte_length` (1 to 10,485,760).
- **Authorisation**: `can_upload_monvelo_cover(purpose, subject_id)` on the caller's JWT (ZSA, ASA, LM, CSM per scope); false is 403 `FORBIDDEN`.
- **Response**: `{ bucket, path, upload_url }` with bucket `monvelo-shop-policies` or `monvelo-claim-evidence` and path `<subject_id>/<uuid>.<ext>`. Storage signing uses the secret key (A5 R22, the one user-gateway exception); the RPC still runs on the caller's JWT. No idempotency key: it writes nothing.

### 4.8 monvelo-insurance-declare (system)

The cron-invoked drain of `monvelo_insurance_declarations` (A8 §7.2), every minute through `pg_net`.

- **Authentication**: header `x-cron-secret` compared in constant time with `CRON_SECRET`; otherwise 401 `UNAUTHORIZED`; non-POST is 405.
- **Work**: `claim_monvelo_declarations(p_limit)` claims a batch; each row goes to its insurer's adapter with the row id as idempotency key; `complete_monvelo_declaration(p_id, p_outcome, p_insurer_reference, p_error)` records `ACCEPTED`, `REJECTED`, `RETRY` (back-off and the 24-hour limit are the database's) or `MANUAL`. One row's failure never stops the batch.
- **Response**: per-outcome counts. Adapters are `MOCK` and `MANUAL` only.

### 4.9 monvelo-insurance-webhook (system, public)

`POST /functions/v1/monvelo-insurance-webhook?insurer=<CODE>` (A8 §7.3).

- `CODE` must match `^[A-Z0-9_]{2,32}$`; body at most 64 KiB.
- `get_monvelo_insurer_provider(p_code)` looks up the adapter; the adapter verifies the request (MOCK: hex HMAC-SHA256 of `"<x-insurer-timestamp>.<raw body>"` with `MONVELO_MOCK_INSURER_SECRET`, header `x-insurer-signature`, 5-minute window). A failure, an unknown insurer or a MANUAL insurer is 401.
- Zod validates the event (`eventId`, `type`, optional `claimReference` `^IC-[A-Z2-7]{8}$`, `declarationId`, `settledAmount` `^\d{1,13}\.\d{2}$`, `payoutReference`, `insurerReference`, `error`; strict) → 400 on failure.
- `apply_monvelo_insurer_event(p_insurer_code, p_event_id, p_type, p_event)` records `(insurer, event_id)` and applies it in one transaction. A duplicate is 200 `{ duplicate: true }`; an unknown target refuses the whole event (422) so the insurer's retry still applies.

<!-- pagebreak -->

## 5. PostgreSQL RPC reference

The tables below are generated from `pg_proc` on the migrated database. **Gate** is the role check found in the function body (`assert_tenant_role` / `assert_platform_role`), or the condition the body checks instead. **Flags**: `proof` = takes and checks `p_gateway_proof`; `idem` = runs `idempotency_begin`; `member` = checks agent membership; `owner` = checks shop ownership. Volatility: `v` volatile, `s` stable, `i` immutable. Every function here is `SECURITY DEFINER` unless marked `INVOKER`, and pins `search_path = public, pg_temp`.

### 5.1 Callable by `authenticated` (API surface)

75 functions.

| Function | Parameters | Returns | Gate | Flags | Vol. |
|---|---|---|---|---|---|
| `accept_monvelo_agent_terms` | `p_idempotency_key uuid, p_agent_id uuid, p_terms_code text, p_body_sha256 text` | `jsonb` | ACTIVE member of the agent | member, idem | v |
| `accept_monvelo_tenant_terms` | `p_idempotency_key uuid, p_terms_code text, p_body_sha256 text, p_decision_id uuid` | `jsonb` | tenant: CLIENT_SERVICE_MANAGER | idem | v |
| `add_monvelo_member` | `p_idempotency_key uuid, p_agent_id uuid, p_phone_number text` | `jsonb` | platform: MONVELO_OPERATOR | member, idem | v |
| `approve_monvelo_agent` | `p_idempotency_key uuid, p_agent_id uuid` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `approve_monvelo_brand_terms` | `p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid` | `jsonb` | tenant: ZSM, CLIENT_SERVICE_MANAGER | idem | v |
| `approve_monvelo_financing` | `p_idempotency_key uuid, p_financing_id uuid` | `jsonb` | tenant: TM | idem | v |
| `approve_monvelo_insurance_product` | `p_idempotency_key uuid, p_product_id uuid` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `approve_monvelo_settlement_change` | `p_idempotency_key uuid, p_agent_id uuid` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `can_upload_monvelo_cover` | `p_purpose text, p_subject_id uuid` | `boolean` | tenant: ZSA, ASA, LOGISTICS_MANAGER, CLIENT_SERVICE_MANAGER | — | s |
| `cancel_monvelo_financing` | `p_idempotency_key uuid, p_financing_id uuid, p_reason text` | `jsonb` | tenant: ZSA, ASA, TM | idem | v |
| `claim_monvelo_financing` | `p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid, p_expected_net_yield_bps integer` | `jsonb` | ACTIVE member of an ACTIVE agent | member, idem | v |
| `close_monvelo_insurance_claim` | `p_idempotency_key uuid, p_claim_id uuid, p_reason text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `close_monvelo_nomination` | `p_idempotency_key uuid, p_nomination_id uuid, p_agent_id uuid, p_status text` | `jsonb` | tenant: ZSA, ASA | idem | v |
| `confirm_monvelo_delivery` | `p_idempotency_key uuid, p_challenge_id uuid, p_code text` | `jsonb` | `fulfilment_delivery_path` holder (R20) | idem | v |
| `confirm_monvelo_repayment` | `p_idempotency_key uuid, p_challenge_id uuid, p_code text` | `jsonb` | the recording member (R32) | member, idem | v |
| `decide_monvelo_claim_hold` | `p_idempotency_key uuid, p_hold_id uuid, p_allow boolean, p_reason text` | `jsonb` | tenant: ZSA, ASA, ZSM | idem | v |
| `dispatch_monvelo_financing` | `p_idempotency_key uuid, p_financing_id uuid, p_tracking_reference text` | `jsonb` | `fulfilment_can_dispatch` | idem | v |
| `enrol_monvelo_shop` | `p_idempotency_key uuid, p_challenge_id uuid, p_code text` | `jsonb` | tenant: ZSA, ASA | idem | v |
| `file_monvelo_insurance_claim` | `p_idempotency_key uuid, p_claim_id uuid` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `get_lender_reconciliation_summary` | `p_weeks integer` | `TABLE(agent_id uuid, agent_name text, week_start date, capital_funded numeric, outstanding numeric, repaid numeric, refunded numeric, rebates_owed numeric, rebates_paid numeric, mv_references text[], closed_by_claim_amount numeric, late_charge_waived numeric)` | tenant: ZSA, ASA | member | s |
| `get_monvelo_agent_exposure` | `p_agent_id uuid` | `TABLE(agent_id uuid, agent_status text, open_exposure numeric, platform_ceiling numeric, allowance_ceiling numeric, remaining_room numeric, active_commitments_count bigint, personal_daily_limit numeric, per_financing_limit numeric, today_utilized_limit numeric, today_remaining_limit numeric)` | agent member or Monvelo staff | member | s |
| `get_monvelo_claim_hold` | `p_hold_id uuid` | `TABLE(hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text, principal numeric, brand_lines jsonb, expires_at timestamp with time zone, ready boolean, blocks text[], within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer, shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamp with time zone, reason text, can_decide boolean)` | tenant: ZSA, ASA, ZSM | — | s |
| `get_monvelo_offer_cover` | `p_financing_id uuid, p_agent_id uuid` | `TABLE(cover_label text, gross_rebate numeric, storage_premium numeric, net_rebate numeric, net_yield_bps integer, net_yield_percent numeric, quote_valid_until timestamp with time zone)` | agent member | member | s |
| `is_monvelo_field_agent` | — | `boolean` | policy helper | — | s |
| `is_monvelo_operator` | — | `boolean` | policy helper | — | s |
| `is_monvelo_staff` | — | `boolean` | policy helper | — | s |
| `list_monvelo_claim_holds` | — | `TABLE(hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text, principal numeric, brand_lines jsonb, expires_at timestamp with time zone, ready boolean, blocks text[], within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer, shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamp with time zone, reason text, can_decide boolean)` | tenant: ZSA, ASA, ZSM | — | s |
| `monvelo_agent_register_preflight` | `p_idempotency_key uuid, p_operation text, p_request jsonb` | `jsonb` | tenant: ZSA, ASA | idem | s |
| `monvelo_agents_near` | `p_shop_id uuid, p_radius_m integer` | `TABLE(agent_id uuid, pos_network pos_network_enum, distance_m integer)` | Monvelo staff | — | s |
| `monvelo_open_offers` | `p_agent_id uuid` | `TABLE(financing_id uuid, reference text, shop_name text, shop_code text, area_name text, principal numeric, distance_m integer, supply_date date, preferred_until timestamp with time zone)` | agent member | member | s |
| `monvelo_order_financing_status` | `p_order_ids uuid[]` | `TABLE(order_id uuid, financing_state text, financing_id uuid, reference text, principal numeric)` | any member; owner sees own shop; `POS_AGENT` gets nothing | owner | s |
| `monvelo_supply_days_near` | `p_agent_id uuid, p_days integer` | `TABLE(area_id uuid, area_name text, supply_date date, shop_count integer)` | agent member | member | s |
| `monvelo_today` (INVOKER) | — | `date` | helper | — | s |
| `my_monvelo_agent_ids` | — | `SETOF uuid` | policy helper | member | s |
| `my_monvelo_nomination_tenant_ids` | — | `SETOF uuid` | policy helper | — | s |
| `my_monvelo_policy_shop_ids` | — | `SETOF uuid` | policy helper | — | s |
| `my_monvelo_repayment_financing_ids` | — | `SETOF uuid` | policy helper | member | s |
| `my_monvelo_staff_tenant_ids` | — | `SETOF uuid` | policy helper | — | s |
| `my_monvelo_territory_ids` | — | `SETOF uuid` | policy helper | — | s |
| `my_zsm_monvelo_nomination_ids` | — | `SETOF uuid` | policy helper | — | s |
| `nominate_monvelo_agent` | `p_idempotency_key uuid, p_shop_id uuid, p_name text, p_phone text, p_pos_network pos_network_enum` | `jsonb` | tenant: RETAIL_SHOP_OWNER or ZSA, ASA | owner, idem | v |
| `pledge_monvelo_funds` | `p_idempotency_key uuid, p_agent_id uuid, p_area_id uuid, p_supply_date date, p_amount numeric` | `jsonb` | agent member | member, idem | v |
| `propose_monvelo_brand_terms` | `p_idempotency_key uuid, p_brand text, p_rebate_bps integer, p_interest_free_days integer, p_late_charge_bps integer, p_valid_from date, p_valid_to date` | `jsonb` | tenant: ZSM | idem | v |
| `propose_monvelo_insurance_product` | `p_idempotency_key uuid, p_insurer_id uuid, p_kind text, p_rate_bps integer, p_facilitator_fee_bps integer, p_valid_from date, p_valid_to date` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `record_monvelo_checkout` | `p_idempotency_key uuid, p_gateway_proof text, p_payment_id uuid, p_authorization_url text, p_access_code text` | `jsonb` | the payment's starter (R59) | member, proof, idem | v |
| `record_monvelo_claim_settlement` | `p_idempotency_key uuid, p_claim_id uuid, p_settled_amount numeric, p_payout_reference text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `record_monvelo_declaration_outcome` | `p_idempotency_key uuid, p_declaration_id uuid, p_outcome text, p_insurer_reference text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `record_monvelo_fee_terms` | `p_idempotency_key uuid, p_tenant_id uuid, p_fee_bps integer, p_valid_from date, p_valid_to date, p_decision_id uuid` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `record_monvelo_premium_paid` | `p_idempotency_key uuid, p_payable_id uuid, p_reference text` | `jsonb` | platform: MONVELO_FINANCE | idem | v |
| `record_monvelo_repayment` | `p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid, p_agent_id uuid, p_amount numeric` | `jsonb` | the funder's member | member, owner, proof, idem | v |
| `record_monvelo_topup_paid` | `p_idempotency_key uuid, p_topup_id uuid, p_reference text` | `jsonb` | platform: MONVELO_FINANCE | idem | v |
| `register_monvelo_agent` | `p_idempotency_key uuid, p_gateway_proof text, p_agent jsonb` | `jsonb` | tenant: ZSA, ASA | proof, idem | v |
| `register_monvelo_insurer` | `p_idempotency_key uuid, p_code text, p_legal_name text, p_naicom_licence_no text, p_api_provider text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `reject_monvelo_repayment` | `p_idempotency_key uuid, p_repayment_id uuid` | `jsonb` | the shop owner | owner, idem | v |
| `report_monvelo_loss` | `p_idempotency_key uuid, p_financing_id uuid, p_kind text, p_peril text, p_incident_at timestamp with time zone, p_description text, p_evidence_paths text[]` | `jsonb` | tenant: ZSA, ASA, LOGISTICS_MANAGER, CLIENT_SERVICE_MANAGER | idem | v |
| `request_monvelo_financing` | `p_idempotency_key uuid, p_order_id uuid` | `jsonb` | tenant: ZSA, ASA, TM | owner, idem | v |
| `request_monvelo_settlement_change` | `p_idempotency_key uuid, p_gateway_proof text, p_agent_id uuid, p_account jsonb` | `jsonb` | tenant: ZSA, ASA | proof, idem | v |
| `review_monvelo_flag` | `p_idempotency_key uuid, p_flag_id uuid, p_note text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `review_monvelo_shop_policy` | `p_idempotency_key uuid, p_policy_id uuid, p_verify boolean, p_note text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `set_monvelo_agent_caps` | `p_idempotency_key uuid, p_agent_id uuid, p_daily_cap numeric, p_per_financing_cap numeric` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `set_monvelo_claim_status` | `p_idempotency_key uuid, p_claim_id uuid, p_status text, p_insurer_claim_reference text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `set_monvelo_insurer_status` | `p_idempotency_key uuid, p_insurer_id uuid, p_status text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `set_monvelo_supply_day` | `p_idempotency_key uuid, p_area_id uuid, p_day_of_week integer, p_active boolean` | `jsonb` | TM of the area's territory | idem | v |
| `set_monvelo_tenant_settings` | `p_idempotency_key uuid, p_enabled boolean, p_opening_limit numeric, p_approval_cap numeric, p_max_limit numeric, p_decision_id uuid, p_limit_growth_bps integer, p_default_cure_days integer, p_post_default_limit_bps integer` | `jsonb` | tenant: ZSM, CLIENT_SERVICE_MANAGER | idem | v |
| `start_monvelo_consent` | `p_idempotency_key uuid, p_gateway_proof text, p_shop_id uuid, p_area_id uuid` | `jsonb` | tenant: ZSA, ASA | owner, proof, idem | v |
| `start_monvelo_delivery` | `p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid` | `jsonb` | `fulfilment_delivery_path` holder | owner, proof, idem | v |
| `start_monvelo_funding` | `p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid` | `jsonb` | member of the claiming agent | member, idem | v |
| `start_monvelo_policy_consent` | `p_idempotency_key uuid, p_gateway_proof text, p_shop_id uuid, p_area_id uuid` | `jsonb` | tenant: ZSA, ASA | owner, proof, idem | v |
| `submit_monvelo_shop_policy` | `p_idempotency_key uuid, p_challenge_id uuid, p_code text, p_insurer_name text, p_policy_number text, p_covers_fire_perils boolean, p_covers_burglary boolean, p_sum_insured numeric, p_lender_interest_endorsed boolean, p_starts_on date, p_expires_on date, p_document_path text` | `jsonb` | tenant: ZSA, ASA | idem | v |
| `suspend_monvelo_agent` | `p_idempotency_key uuid, p_agent_id uuid, p_reason text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `upsert_area` | `p_idempotency_key uuid, p_area_id uuid, p_territory_id uuid, p_area_name text` | `jsonb` | tenant: ZSM, TM | idem | v |
| `withdraw_monvelo_brand_terms` | `p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid` | `jsonb` | tenant: ZSM, CLIENT_SERVICE_MANAGER | idem | v |
| `withdraw_monvelo_insurance_product` | `p_idempotency_key uuid, p_product_id uuid, p_reason text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |
| `withdraw_monvelo_shop_consent` | `p_idempotency_key uuid, p_shop_id uuid` | `jsonb` | the shop owner | owner, idem | v |
| `withdraw_monvelo_shop_policy` | `p_idempotency_key uuid, p_policy_id uuid, p_reason text` | `jsonb` | platform: MONVELO_OPERATOR | idem | v |

### 5.2 Callable by `service_role` only

Called by system functions after their own authentication (`process-payment`, `reconcile-funds`, the insurer functions), or internal helpers that carry the default `service_role` grant but no `authenticated` grant.

17 functions.

| Function | Parameters | Returns | Security | Vol. |
|---|---|---|---|---|
| `apply_monvelo_insurer_event` | `p_insurer_code text, p_event_id text, p_type text, p_event jsonb` | `jsonb` | DEFINER | v |
| `apply_monvelo_refund` | `p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb` | `jsonb` | DEFINER | v |
| `assert_platform_role` | `p_roles platform_role_enum[]` | `uuid` | INVOKER | s |
| `claim_monvelo_declarations` | `p_limit integer` | `SETOF jsonb` | DEFINER | v |
| `complete_monvelo_declaration` | `p_id uuid, p_outcome text, p_insurer_reference text, p_error text` | `jsonb` | DEFINER | v |
| `get_monvelo_insurer_provider` | `p_code text` | `text` | DEFINER | s |
| `monvelo_agent_audit` | `p_agent monvelo_agents` | `jsonb` | INVOKER | i |
| `monvelo_assign_shop_code` | `p_shop_id uuid` | `text` | DEFINER | v |
| `monvelo_brand_terms_guard` | — | `trigger` | INVOKER | v |
| `monvelo_clean_account` | `p_account jsonb` | `jsonb` | INVOKER | i |
| `monvelo_fee_terms_guard` | — | `trigger` | INVOKER | v |
| `monvelo_recruitment_request` | `p_operation text, p_args jsonb` | `jsonb` | INVOKER | i |
| `monvelo_terms_at` | `p_tenant_id uuid, p_brand text, p_at date` | `monvelo_brand_terms` | INVOKER | s |
| `monvelo_terms_no_delete` | — | `trigger` | INVOKER | v |
| `record_monvelo_insurer_event` | `p_insurer_code text, p_event_id text, p_payload jsonb` | `boolean` | DEFINER | v |
| `settle_monvelo_funding` | `p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text` | `jsonb` | DEFINER | v |
| `settle_monvelo_insurance_claim` | `p_insurer_code text, p_claim_reference text, p_settled_amount numeric, p_payout_reference text` | `jsonb` | DEFINER | v |

### 5.3 Internal (no API grant)

Called only from other functions or triggers:

68 functions (triggers return `trigger`).

| Function | Parameters | Returns | Security | Vol. |
|---|---|---|---|---|
| `assert_gateway_proof` | `p_proof text` | `void` | DEFINER | s |
| `monvelo_active_insurer` | `p_code text` | `uuid` | INVOKER | s |
| `monvelo_agent_day_used` | `p_agent_id uuid` | `numeric` | INVOKER | s |
| `monvelo_agent_open_exposure` | `p_agent_id uuid` | `numeric` | INVOKER | s |
| `monvelo_allowance_ceiling` | — | `numeric` | INVOKER | i |
| `monvelo_apply_declaration_outcome` | `p_id uuid, p_outcome text, p_insurer_reference text, p_error text, p_actor uuid` | `jsonb` | INVOKER | v |
| `monvelo_apply_late_charge` | `p_fin monvelo_financings` | `monvelo_financings` | INVOKER | v |
| `monvelo_apply_late_charge_now` | `p_fin monvelo_financings` | `monvelo_financings` | INVOKER | v |
| `monvelo_assert_delivery_day` | `p_fin monvelo_financings` | `void` | INVOKER | s |
| `monvelo_brand_exposure` | `p_tenant_id uuid, p_shop_id uuid, p_brand_key text, p_exclude uuid` | `numeric` | DEFINER | s |
| `monvelo_cancel_trade_order` | `p_tenant_id uuid, p_order_id uuid` | `integer` | DEFINER | v |
| `monvelo_claim_hold_rows` | `p_tenant_id uuid, p_profile_id uuid, p_hold_id uuid` | `TABLE(hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text, principal numeric, brand_lines jsonb, expires_at timestamp with time zone, ready boolean, blocks text[], within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer, shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamp with time zone, reason text, can_decide boolean)` | DEFINER | s |
| `monvelo_claim_holds_guard` | — | `trigger` | INVOKER | v |
| `monvelo_claim_refusal` | `p_fin monvelo_financings, p_agent monvelo_agents, p_member uuid, p_pledge monvelo_pledges, p_late boolean, p_exposure_ceiling numeric` | `text` | INVOKER | s |
| `monvelo_cover_guard` | — | `trigger` | INVOKER | v |
| `monvelo_covers_area` | `p_me tenant_users, p_area_id uuid` | `boolean` | INVOKER | s |
| `monvelo_declaration_financing` | `p_decl monvelo_insurance_declarations` | `uuid` | INVOKER | s |
| `monvelo_delivery_cutoff` | `p_funded_at timestamp with time zone` | `timestamp with time zone` | INVOKER | i |
| `monvelo_draw_reference` | — | `text` | INVOKER | v |
| `monvelo_enqueue_declaration` | `p_tenant_id uuid, p_kind text, p_insurer_id uuid, p_subject_table text, p_subject_id uuid, p_payload jsonb` | `uuid` | INVOKER | v |
| `monvelo_fee_bps_at` | `p_tenant_id uuid, p_date date` | `integer` | INVOKER | s |
| `monvelo_financing_claims_guard` | — | `trigger` | INVOKER | v |
| `monvelo_financing_cover_guard` | — | `trigger` | INVOKER | v |
| `monvelo_financing_lines_guard` | — | `trigger` | INVOKER | v |
| `monvelo_financings_guard` | — | `trigger` | INVOKER | v |
| `monvelo_flags_guard` | — | `trigger` | INVOKER | v |
| `monvelo_git_cover_guard` | — | `trigger` | INVOKER | v |
| `monvelo_has_open_storage_claim` | `p_financing_id uuid` | `boolean` | INVOKER | s |
| `monvelo_hold_market_makers` | `p_tenant_id uuid, p_area_id uuid, p_raiser uuid, p_agent_id uuid` | `SETOF uuid` | DEFINER | s |
| `monvelo_hold_viewers` | `p_tenant_id uuid, p_area_id uuid, p_raiser uuid, p_agent_id uuid` | `SETOF uuid` | DEFINER | s |
| `monvelo_insert_only` | — | `trigger` | INVOKER | v |
| `monvelo_insurer_underwrites` | `p_insurer_id uuid` | `boolean` | DEFINER | s |
| `monvelo_is_shop_covered` | `p_shop_id uuid, p_through timestamp with time zone, p_principal numeric` | `boolean` | DEFINER | s |
| `monvelo_ledger_insert_only` | — | `trigger` | INVOKER | v |
| `monvelo_lock_cover` | `p_quote jsonb` | `void` | DEFINER | v |
| `monvelo_lock_financing` | `p_me tenant_users, p_financing_id uuid` | `monvelo_financings` | INVOKER | v |
| `monvelo_name_tokens` | `p_name text` | `text[]` | INVOKER | i |
| `monvelo_no_delete` | — | `trigger` | INVOKER | v |
| `monvelo_notify_claim` | `p_claim monvelo_insurance_claims` | `void` | INVOKER | v |
| `monvelo_notify_hold` | `p_hold_id uuid` | `void` | DEFINER | v |
| `monvelo_notify_hold_decided` | `p_hold_id uuid` | `void` | DEFINER | v |
| `monvelo_offer` | `p_id uuid` | `monvelo_financings` | DEFINER | v |
| `monvelo_open_exposure_ceiling` | — | `numeric` | INVOKER | i |
| `monvelo_payer_matches` | `p_agent monvelo_agents, p_verified jsonb` | `boolean` | INVOKER | i |
| `monvelo_quote_agent_yield` | `p_financing_id uuid` | `jsonb` | DEFINER | s |
| `monvelo_raise_flag` | `p_kind text, p_financing_id uuid, p_agent_id uuid, p_details jsonb` | `uuid` | DEFINER | v |
| `monvelo_rebate_payable_lines_insert_only` | — | `trigger` | INVOKER | v |
| `monvelo_rebate_payables_guard` | — | `trigger` | INVOKER | v |
| `monvelo_refuse_delete` | — | `trigger` | INVOKER | v |
| `monvelo_repayments_guard` | — | `trigger` | INVOKER | v |
| `monvelo_settings` | — | `monvelo_platform_settings` | DEFINER | s |
| `monvelo_settle_claim` | `p_claim_id uuid, p_settled_amount numeric, p_payout_reference text, p_actor uuid` | `jsonb` | INVOKER | v |
| `monvelo_shop_cover_status` | `p_shop_id uuid, p_through timestamp with time zone, p_principal numeric` | `TABLE(status text, policy_id uuid)` | DEFINER | s |
| `monvelo_shop_limit_events_insert_only` | — | `trigger` | INVOKER | v |
| `monvelo_shop_limit_for` | `p_tenant_id uuid, p_shop_id uuid, p_brand_key text` | `monvelo_shop_limits` | DEFINER | v |
| `monvelo_shop_open_principal` | `p_shop_id uuid` | `numeric` | DEFINER | s |
| `monvelo_supply_day_ended` | `p_supply_date date` | `boolean` | INVOKER | s |
| `monvelo_sweep_declarations` | — | `integer` | DEFINER | v |
| `monvelo_sweep_money` | — | `jsonb` | DEFINER | v |
| `monvelo_sweep_offers` | — | `jsonb` | DEFINER | v |
| `monvelo_sweep_shop_policies` | — | `jsonb` | DEFINER | v |
| `monvelo_tenant_has_csm` | `p_tenant_id uuid` | `boolean` | DEFINER | s |
| `monvelo_terms_accepted` | `p_audience text, p_agent_id uuid, p_tenant_id uuid` | `boolean` | DEFINER | s |
| `monvelo_terms_body_sha256` | `p_code text` | `text` | INVOKER | s |
| `monvelo_terms_checked` | `p_code text, p_audience text, p_body_sha256 text` | `monvelo_terms_versions` | INVOKER | s |
| `monvelo_unpaid_principal` | `p_fin monvelo_financings` | `numeric` | INVOKER | s |
| `payment_for_monvelo` | `p_payment payments` | `boolean` | INVOKER | i |
| `payment_monvelo_route` | `p_payment payments, p_event text, p_source audit_source_enum` | `jsonb` | INVOKER | v |

### 5.4 The recruitment RPCs in detail

**`monvelo_agent_register_preflight(p_idempotency_key uuid, p_operation text, p_request jsonb) returns jsonb`**: `SECURITY DEFINER`, `STABLE`, granted to `authenticated` only. Steps:

1. `assert_tenant_role(['ZSA','ASA'])`: live ACTIVE membership in the JWT tenant, else 42501.
2. `monvelo_tenant_settings.enabled` for that tenant, else 42501 "Monvelo is not enabled for this tenant".
3. A null key is P0001; `p_operation` other than `register_monvelo_agent` / `request_monvelo_settlement_change` is P0001.
4. For a settlement change: the agent must exist (P0001 "unknown Monvelo agent") and `recruited_by` must be the caller (42501).
5. Look the key up in `idempotency_logs`: none → `{ replay: false }`; operation, request hash or actor differs → `TF002`; `COMPLETED` → `{ replay: true, response }`; `IN_PROGRESS` → `40001`.

It writes nothing and needs no gateway proof: it hands back only the caller's own stored response, which they can already read in `idempotency_logs`.

**`register_monvelo_agent(p_idempotency_key uuid, p_gateway_proof text, p_agent jsonb) returns jsonb`**: gate ZSA/ASA → tenant opted in → `assert_gateway_proof` → `idempotency_begin('register_monvelo_agent', monvelo_recruitment_request(...))` → validate (P0001: required fields, POS network, coordinates, `monvelo_clean_account`) → insert `monvelo_agents` (`PENDING`, `recruited_by = auth.uid()`; the unique constraint on `(pos_network, network_agent_id)` decides races, re-raised as 23505) → `write_audit(null, ...)` with the redacted agent → `idempotency_complete` with `{ agent_id, status, name_matches }`. `name_matches` compares the bank's holder name with the business name, case- and padding-insensitively.

**`request_monvelo_settlement_change(p_idempotency_key uuid, p_gateway_proof text, p_agent_id uuid, p_account jsonb) returns jsonb`**: same gates and proof → idempotency → the agent (locked `FOR UPDATE`) must exist and be the caller's recruit → `pending_settlement` set to the cleaned account plus `requested_by`, `requested_at` → tenant-null audit → `{ agent_id, status: "PENDING_APPROVAL", last4 }`. An operator applies it with `approve_monvelo_settlement_change`.

**`monvelo_recruitment_request(p_operation text, p_args jsonb) returns jsonb`** (`IMMUTABLE`, internal): the request both the preflight and the two RPCs hash. For a registration, `p_args - 'settlement_account_name'`; for a settlement change, `{ agent_id, account: account - 'settlement_account_name' }`.

<!-- pagebreak -->

## 6. End-to-end flows

### 6.1 POS agent onboarding

```
 ASA / ZSA          monvelo-agent-register        Postgres                  Operator
    |  register (v4 key) |                            |                         |
    |------------------->| preflight: role, opt-in,   |                         |
    |                    | key ------------------------>  { replay: false }     |
    |                    | Paystack /bank/resolve     |                         |
    |                    | register_monvelo_agent --->| agent PENDING           |
    |                    |                            | audit tenant_id = null  |
    |<-- 200 PENDING ----|                            |                         |
    |                    |                            |<-- approve_monvelo_agent|
    |                    |                            |    ACTIVE, approved_by  |
    |                    |                            |<-- add_monvelo_member   |
    |                    |                            |    (verified phone)     |
    |                    |                            |<-- set_monvelo_agent_caps
    |                    |                            |    daily / per-financing|
```

1. The street agent posts the registration with a fresh UUID v4 key.
2. The preflight refuses anyone but an ACTIVE ZSA or ASA of an opted-in tenant **before** Paystack is called, so a refused caller spends no quota and cannot tell an existing account (422) from a refusal (403).
3. Paystack resolves the account; the RPC stores the bank's holder name and the agent as `PENDING`. A PENDING agent is visible only to Monvelo staff.
4. A `MONVELO_OPERATOR` approves (`approve_monvelo_agent` → `ACTIVE`), adds staff logins (`add_monvelo_member`: the fintech agent persona) and sets caps (`set_monvelo_agent_caps`; `daily_cap` and `per_financing_cap` default to 0). `suspend_monvelo_agent` moves it to `SUSPENDED`; a suspended agent cannot start funding (R57), but may still record repayments (R34).
5. Once ACTIVE, the agent is visible to field agents of opted-in tenants and to its own members.

### 6.2 Settlement account change and idempotent retries

```
 ASA (recruiter)    monvelo-agent-register          Postgres                Paystack
    | change, key K      |                              |                       |
    |------------------->| preflight(K): recruiter ok,  |                       |
    |                    | K unknown ------------------>| { replay: false }     |
    |                    | /bank/resolve -------------------------------------->|
    |                    | request_monvelo_settlement_change ->| pending_settlement |
    |<- 200 PENDING_APPROVAL                            | log K COMPLETED       |
    | retry, key K       |                              |                       |
    |------------------->| preflight(K) --------------->| { replay: true, ... } |
    |<- 200 (stored) ----|   no Paystack call           |                       |
    | key K, new account |                              |                       |
    |------------------->| preflight(K) --------------->| TF002                 |
    |<- 409 IDEMPOTENCY_MISMATCH  no Paystack call      |                       |
```

- A ZSA or ASA who did not recruit the agent is refused by the preflight (403), with no Paystack call.
- Two simultaneous sends of one key: both may pass the preflight, but `idempotency_begin` serialises them on the key, so one agent is written and both answer with it (or the second gets 503 `RETRY`).
- Two registrations of one network agent under different keys race on the unique constraint: one 200, one 409 `CONFLICT`.
- An operator applies the pending account with `approve_monvelo_settlement_change`.

### 6.3 Shop enrolment

1. The ASA (own area) or ZSA (an area in its zone) calls `monvelo-shop-consent` `start`. The database draws a code; the gateway sends it over WhatsApp to the **owner's verified profile phone** (never the shop's contact number).
2. The owner reads the code to the street agent, who sends `enrol`. The enrolment (`ACTIVE`, `consent_version`, `consent_at`) gives the shop a shop code (`monvelo_assign_shop_code`).
3. The owner may withdraw at any time (`withdraw_monvelo_shop_consent`); every ACTIVE or SUSPENDED enrolment of the shop becomes `WITHDRAWN`.
4. Shop owners and street agents may nominate a POS agent they know (`nominate_monvelo_agent`); the nomination keeps the phone's last four digits only.

### 6.4 The financing lifecycle

```
 TM            ASA/ZSA/TM          Fintech agent         Tenant (LM)        Shop owner
  | set_monvelo_supply_day |              |                     |                 |
  |----------------------->|              |                     |                 |
  |                        |   pledge_monvelo_funds (area, date)|                 |
  |                        | place_trade_order + request_monvelo_financing        |
  |                        |   -> OFFERED (or AWAITING_APPROVAL -> TM approves)   |
  |                        |              | monvelo_open_offers |                 |
  |                        |              | claim_monvelo_financing -> CLAIMED    |
  |                        |              |   (cap blocked: HELD 15 min,          |
  |                        |              |    ZSA/ASA decide -> CLAIMED/OFFERED) |
  |                        |              | monvelo-fund -> Paystack transfer     |
  |                        |              |   webhook -> settle_monvelo_funding   |
  |                        |              |   -> FUNDED                           |
  |                        |              |                     | dispatch        |
  |                        |              |                     | monvelo-confirm-delivery
  |                        |              |                     |<--- code -------|
  |                        |              |                     | -> DELIVERED, due_at
  |                        |              | monvelo-confirm-repayment record      |
  |                        |              |<-------------- code read out ---------|
  |                        |              | confirm -> REPAID_WITHIN_WINDOW       |
```

1. **Supply day.** The territory's TM sets the area's weekly supply day (`set_monvelo_supply_day`).
2. **Pledge.** An agent's member pledges funds for an area and date (`pledge_monvelo_funds`).
3. **Request.** A ZSA, ASA or TM places a wholesale trade order (whole packs, wholesale price, stock reserved FEFO) and requests financing (`request_monvelo_financing`). Integrity checks: an ACTIVE enrolment, a verified owner phone, approved brand terms for every brand of the order, a supply day, the operational state, no unresolved default with any tenant (§18.2), and the raiser's PAR30 under 10% (§7.3). Above the shop's per-brand limit, the territory's TM approves (`approve_monvelo_financing`).
4. **Offer and claim.** The shop's preferred agent alone may claim during the preferred window; then any ACTIVE agent within 1000 m whose pledge, caps and the ₦1,000,000 open-exposure ceiling allow (`claim_monvelo_financing`, which also locks the cover quote: `p_expected_net_yield_bps`). A claim blocked only by the exposure ceiling but within ₦3,000,000 is **HELD** for 15 minutes for a field-agent decision (`decide_monvelo_claim_hold`).
5. **Fund.** The claimant's member pays by Paystack bank transfer (`monvelo-fund`); the webhook settles it (`settle_monvelo_funding`) if the payer binding holds. Status `FUNDED`.
6. **Dispatch and deliver.** The tenant dispatches (`dispatch_monvelo_financing`, consuming the reservations); the deliverer confirms with the owner's code (`monvelo-confirm-delivery`). Status `DELIVERED`; `due_at` set by the brand's interest-free days; the tenant ledger books `FUNDED_GROSS` and the fee. Undelivered 23 hours after funding, the money sweep moves it to `REFUND_DUE`, cancels the order, and raises a HIGH ticket.
7. **Repay.** The funder's member records each repayment and confirms it with the owner's code (`monvelo-confirm-repayment`). Repaid in the window: `REPAID_WITHIN_WINDOW`. Past `due_at`, the sweep applies the one late charge (`DEFAULTED_WITH_LATE_CHARGE`), and full repayment then gives `REPAID_LATE`. A settled storage-cover claim closes it `CLOSED_BY_CLAIM`.
8. **Sweeps.** `monvelo-offer-sweep` lapses claims and holds and expires requests at the end of their supply day; `monvelo-money-sweep` handles refunds, the late charge and repayments pending 24 hours.

### 6.5 Who sees what along the way

- The tenant sees its financings, limits and ledger, but **never the lender**: lender columns are ungranted (R9) and lender-naming audit rows are tenant-null.
- The fintech agent sees its own pledges, claims, financings, payables, repayments and exposure, across tenants.
- The shop owner sees its own financings, enrolments, limits and repayments.
- Monvelo staff see everything that has a policy; five tables have no API reader at all.

<!-- pagebreak -->

## 7. Verification and test coverage

### 7.1 Results at commit `205d0e6`

| Layer | Command | Result |
|---|---|---|
| Deno unit and guard tests | `deno test --node-modules-dir=none --allow-env --allow-read supabase/functions/` | 452 passed, 0 failed |
| pgTAP | `supabase test db` (on a freshly reset, unseeded database) | 79 files, 4,072 assertions, PASS |
| Playwright API | `pnpm exec playwright test` after `pnpm db:fresh` | 71 passed (51 Monvelo, 20 RTM); 71 again on the re-seeded database |

### 7.2 Deno unit tests (Monvelo)

| Function | Tests | Highlights |
|---|---|---|
| `monvelo-agent-register` | 14 | Preflight before Paystack; cached replay with no Paystack call; 409 and 403 from the preflight stop the flow; strict v4 keys (v1, v7, bad variant, nil); the RPC gets the bank's name, never the client's |
| `monvelo-fund` | 12 | Checkout stored and replayed; `MONVELO_CHECKOUT_LOST`; Paystack errors |
| `monvelo-confirm-repayment` | 11 | Code never returned; refusals map to 422; failed send is 502 |
| `monvelo-shop-consent` | 10 | Consent and policy codes; WhatsApp only; replayed start sends nothing |
| `monvelo-insurance-webhook` | 8 | HMAC, window, strict Zod, duplicates |
| `monvelo-confirm-delivery` | 7 | Start and confirm; refusals |
| `monvelo-cover-upload` | 4 | Type and size; DB decides |
| `monvelo-insurance-declare` | 4 | Cron secret; batch outcomes |
| `_shared/core/validate.ts` | 5 | Includes `idempotencyKeyV4` |

Repository guards in the same run: `service-role-guard` (every `serviceRpc()` caller and the check it runs first; no `monvelo-*` user gateway holds the key), `secret-scoping` (no secret under a client prefix) and `keys`.

### 7.3 pgTAP (database)

29 files named `*monvelo*` plan 1,590 assertions (A6 Step 1c files 046–049, 051, 055–060 and A7 files 070–071 add more without the prefix). Highlights: `040_monvelo_agents` (82: registration, caps, members, the read policy), `041_monvelo_shop_enrolment` (85), `052_monvelo_financings` (90), `061_monvelo_funding` (180), `066_monvelo_claim_holds` (134), `067_get_monvelo_agent_exposure` (39), and `081_monvelo_register_preflight` (32: the preflight's grants and volatility, ZSA/ASA pass, TM/ZSM/operator/opted-out tenant refused, replay, holder-name independence, TF002 for a changed request, the other operation and another actor, `40001` for an in-progress key, the recruiter check, and both RPCs' client-only hash).

### 7.4 Playwright API tests (`tests/api/monvelo.spec.ts`)

Runs against the local stack as the seeded personas, with a fake Paystack on `0.0.0.0:54399` that counts every call it receives.

| Group | Tests | What it proves |
|---|---|---|
| Personas: claims and live membership | 10 | Every persona's JWT claims; live `tenant_users` rows; the fintech agent reads its agent and exposure; the ZSM is refused the meter; isolation between TEAFAIR and LAGOSFMCG; ACTIVE agents visible to opted-in field agents only |
| Refused callers cost no Paystack call | 10 | No JWT and a bad token (401); TM, ZSM, operator, shop owner, fintech agent, LAGOSFMCG TM and ASA (403, never 422); a client-sent tenant is stripped. **0 Paystack calls each** |
| Write protection | 5 | Direct PostgREST inserts and updates on `monvelo_agents`, `monvelo_agent_members`, `areas`, `monvelo_tenant_settings` are 403; the RPC without the gateway proof is 403 |
| Request validation | 6 | Header-only key, UUID v1, UUID v7, bad variant, nil and junk keys: 400 with 0 Paystack calls; an unresolvable account is 422 only for an authorised caller |
| Registration by the ASA, audit, idempotency | 12 | 200 PENDING with one Paystack call; the stored row; the hidden account number; PENDING invisible to tenants; the idempotency log; the tenant-null audit row (unreadable through the API, verified as postgres); **identical retry: cached 200, 0 Paystack calls, even after the bank's name changed**; mismatch 409 with 0 calls; another actor's key; duplicate network agent 409 |
| Registration by the ZSA and races | 3 | ZSA registration end to end; concurrent sends of one key create one agent; concurrent different keys: one 200, one 409 |
| `change_settlement` | 5 | Non-recruiter ZSA and unknown agent refused with 0 Paystack calls; the recruiter succeeds; retry replays with 0 calls; mismatch 409 |

### 7.5 Running the suites

```
supabase db reset && supabase test db          # pgTAP needs an unseeded database
pnpm db:seed                                    # personas (local stack only)
pnpm functions:serve:api                        # Sentry off, codes to the SMS log
pnpm exec playwright test                       # both API specs
```

The seed's TEAFAIR Lagos zone collides with the zones the pgTAP fixtures create, so run pgTAP before seeding. After stopping `functions:serve:api`, remove the `supabase_edge_runtime_teafair` container before serving again, or the old code keeps answering.

<!-- pagebreak -->

## Appendix A. RLS predicates (verbatim)

Every policy below is `FOR SELECT TO authenticated`. Predicates are copied from `pg_policies.qual`.

**`areas`** (SELECT)

```
(tenant_id IN ( SELECT my_tenant_ids() AS my_tenant_ids))
```

**`monvelo_agent_members`** (SELECT)

```
((profile_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_agent_nominations`** (SELECT)

```
((tenant_id IN ( SELECT my_monvelo_nomination_tenant_ids() AS my_monvelo_nomination_tenant_ids)) OR (id IN ( SELECT my_zsm_monvelo_nomination_ids() AS my_zsm_monvelo_nomination_ids)) OR (shop_id IN ( SELECT my_owned_shop_ids() AS my_owned_shop_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_agents`** (SELECT)

```
(( SELECT is_monvelo_staff() AS is_monvelo_staff) OR (id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR ((status = 'ACTIVE'::text) AND ( SELECT is_monvelo_field_agent() AS is_monvelo_field_agent)))
```

**`monvelo_brand_terms`** (SELECT)

```
((tenant_id IN ( SELECT my_tenant_ids() AS my_tenant_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_financing_claims`** (SELECT)

```
((agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_financing_cover`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_financing_line_cover`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_financing_lines`** (SELECT)

```
((tenant_id, financing_id) IN ( SELECT f.tenant_id, f.id FROM monvelo_financings f))
```

**`monvelo_financings`** (SELECT)

```
((shop_id IN ( SELECT my_owned_shop_ids() AS my_owned_shop_ids)) OR (claimed_by_agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR (funder_agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR (raised_by = ( SELECT auth.uid() AS uid)) OR (territory_id IN ( SELECT my_monvelo_territory_ids() AS my_monvelo_territory_ids)) OR (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role)) OR (territory_id IN ( SELECT my_zsm_territory_ids() AS my_zsm_territory_ids)) OR ((status = 'FUNDED'::text) AND (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['LOGISTICS_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role))) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_flags`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_insurance_claims`** (SELECT)

```
(( SELECT is_monvelo_staff() AS is_monvelo_staff) OR ((kind = 'GIT'::text) AND (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum, 'LOGISTICS_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role))))
```

**`monvelo_insurance_products`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_insurers`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_order_git_cover`** (SELECT)

```
(( SELECT is_monvelo_staff() AS is_monvelo_staff) OR (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum, 'LOGISTICS_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role)))
```

**`monvelo_platform_settings`** (SELECT)

```
true
```

**`monvelo_pledges`** (SELECT)

```
((agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_premium_payables`** (SELECT)

```
( SELECT is_monvelo_staff() AS is_monvelo_staff)
```

**`monvelo_rebate_payable_lines`** (SELECT)

```
(payable_id IN ( SELECT p.id FROM monvelo_rebate_payables p))
```

**`monvelo_rebate_payables`** (SELECT)

```
((agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_rebate_topups`** (SELECT)

```
((agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_repayments`** (SELECT)

```
((financing_id IN ( SELECT my_monvelo_repayment_financing_ids() AS my_monvelo_repayment_financing_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_shop_enrolments`** (SELECT)

```
((tenant_id IN ( SELECT my_monvelo_staff_tenant_ids() AS my_monvelo_staff_tenant_ids)) OR (shop_id IN ( SELECT my_owned_shop_ids() AS my_owned_shop_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_shop_limit_events`** (SELECT)

```
((shop_id IN ( SELECT my_owned_shop_ids() AS my_owned_shop_ids)) OR (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['ZSM'::tenant_role_enum, 'TM'::tenant_role_enum, 'ASM'::tenant_role_enum, 'ZSA'::tenant_role_enum, 'ASA'::tenant_role_enum, 'TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_shop_limits`** (SELECT)

```
((shop_id IN ( SELECT my_owned_shop_ids() AS my_owned_shop_ids)) OR (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['ZSM'::tenant_role_enum, 'TM'::tenant_role_enum, 'ASM'::tenant_role_enum, 'ZSA'::tenant_role_enum, 'ASA'::tenant_role_enum, 'TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum]) AS my_tenant_ids_with_role)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_shop_policies`** (SELECT)

```
(( SELECT is_monvelo_staff() AS is_monvelo_staff) OR (shop_id IN ( SELECT my_monvelo_policy_shop_ids() AS my_monvelo_policy_shop_ids)))
```

**`monvelo_supply_days`** (SELECT)

```
((tenant_id IN ( SELECT my_tenant_ids() AS my_tenant_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_tenant_fee_terms`** (SELECT)

```
((tenant_id IN ( SELECT my_tenant_ids() AS my_tenant_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_tenant_ledger_entries`** (SELECT)

```
((tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum, 'ZSM'::tenant_role_enum]) AS my_tenant_ids_with_role)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_tenant_settings`** (SELECT)

```
((tenant_id IN ( SELECT my_tenant_ids() AS my_tenant_ids)) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

**`monvelo_terms_acceptances`** (SELECT)

```
(( SELECT is_monvelo_staff() AS is_monvelo_staff) OR (agent_id IN ( SELECT my_monvelo_agent_ids() AS my_monvelo_agent_ids)) OR (tenant_id IN ( SELECT my_tenant_ids_with_role(ARRAY['TENANT_ADMIN'::tenant_role_enum, 'CLIENT_SERVICE_MANAGER'::tenant_role_enum, 'ZSM'::tenant_role_enum]) AS my_tenant_ids_with_role)))
```

**`monvelo_terms_versions`** (SELECT)

```
((status <> 'DRAFT'::text) OR ( SELECT is_monvelo_staff() AS is_monvelo_staff))
```

## Appendix B. Columns of every Monvelo table

| Table | Columns |
|---|---|
| `areas` | `id`, `tenant_id`, `territory_id`, `area_name`, `asa_id`, `created_at` |
| `monvelo_agent_members` | `agent_id`, `profile_id`, `status`, `created_at` |
| `monvelo_agent_nominations` | `id`, `tenant_id`, `shop_id`, `nominated_name`, `nominated_phone_last4`, `pos_network`, `raised_by`, `status`, `recruited_agent_id`, `created_at` |
| `monvelo_agents` | `id`, `business_name`, `pos_network`, `network_agent_id`, `contact_phone`, `location`, `address_text`, `settlement_account_number`, `settlement_account_last4`, `settlement_bank_code`, `settlement_account_name`, `pending_settlement`, `paystack_payer_ref`, `network_kyc_reference`, `recruited_by`, `status`, `approved_by`, `approved_at`, `daily_cap`, `per_financing_cap`, `created_at`, `updated_at` |
| `monvelo_brand_terms` | `id`, `tenant_id`, `brand`, `brand_key`, `rebate_bps`, `interest_free_days`, `late_charge_bps`, `valid_from`, `valid_to`, `status`, `proposed_by`, `approved_by`, `approved_at`, `created_at`, `approval_decision_id` |
| `monvelo_claim_holds` | `id`, `tenant_id`, `financing_id`, `agent_id`, `claimed_by`, `blocks`, `exposure_before`, `exposure_after`, `pledge_remaining`, `created_at`, `expires_at`, `status`, `decided_by`, `decided_at`, `reason`, `quoted_net_yield_bps` |
| `monvelo_consent_challenges` | `id`, `tenant_id`, `shop_id`, `area_id`, `code_hash`, `expires_at`, `failed_attempts`, `consumed_at`, `issued_by`, `created_at`, `purpose` |
| `monvelo_financing_claims` | `id`, `tenant_id`, `financing_id`, `agent_id`, `claimed_by`, `pledge_id`, `claimed_at`, `expires_at`, `outcome`, `ended_at` |
| `monvelo_financing_cover` | `financing_id`, `tenant_id`, `cover_kind`, `shop_policy_id`, `product_id`, `storage_rate_bps`, `blocks`, `storage_premium`, `gross_rebate`, `net_rebate`, `declared_status`, `locked_at`, `created_at`, `updated_at` |
| `monvelo_financing_line_cover` | `financing_id`, `brand_key`, `tenant_id`, `terms_id`, `rebate_bps`, `interest_free_days`, `late_charge_bps`, `gross_rebate`, `storage_premium`, `net_rebate`, `created_at`, `updated_at` |
| `monvelo_financing_lines` | `tenant_id`, `financing_id`, `brand`, `brand_key`, `amount`, `terms_id`, `rebate_bps`, `interest_free_days`, `late_charge_bps`, `terms_locked_at` |
| `monvelo_financings` | `id`, `tenant_id`, `reference`, `shop_id`, `order_id`, `area_id`, `territory_id`, `raised_by`, `principal`, `supply_date`, `status`, `approval_required`, `approved_by`, `approved_at`, `offered_at`, `preferred_agent_id`, `preferred_window_ends_at`, `claimed_by_agent_id`, `claimed_by`, `claim_expires_at`, `pledge_id`, `funder_agent_id`, `paystack_reference`, `funded_at`, `delivered_at`, `due_at`, `late_charge_amount`, `outstanding`, `closed_at`, `cancelled_by`, `cancelled_at`, `cancel_reason`, `created_at`, `updated_at` |
| `monvelo_flags` | `id`, `kind`, `financing_id`, `agent_id`, `details`, `status`, `reviewed_by`, `reviewed_at`, `review_note`, `created_at` |
| `monvelo_insurance_claims` | `id`, `reference`, `tenant_id`, `kind`, `financing_id`, `insurer_id`, `peril`, `incident_at`, `description`, `evidence_paths`, `reported_by`, `payee_kind`, `payee_agent_id`, `status`, `insurer_claim_reference`, `claimed_amount`, `settled_amount`, `shortfall`, `late_charge_waived`, `payout_reference`, `filed_by`, `filed_at`, `settled_at`, `closed_reason`, `created_at`, `updated_at` |
| `monvelo_insurance_declarations` | `id`, `tenant_id`, `kind`, `insurer_id`, `subject_table`, `subject_id`, `payload`, `status`, `attempts`, `next_attempt_at`, `insurer_reference`, `last_error`, `completed_at`, `created_at`, `updated_at` |
| `monvelo_insurance_products` | `id`, `insurer_id`, `kind`, `rate_bps`, `facilitator_fee_bps`, `valid_from`, `valid_to`, `status`, `proposed_by`, `approved_by`, `approved_at`, `withdrawn_by`, `withdrawn_at`, `withdraw_reason`, `created_at`, `updated_at` |
| `monvelo_insurer_events` | `insurer_id`, `event_id`, `payload`, `received_at` |
| `monvelo_insurers` | `id`, `code`, `legal_name`, `naicom_licence_no`, `api_provider`, `status`, `created_by`, `created_at`, `updated_at` |
| `monvelo_order_git_cover` | `order_id`, `tenant_id`, `financing_id`, `product_id`, `rate_bps`, `insured_value`, `premium`, `declared_status`, `created_at`, `updated_at` |
| `monvelo_owner_challenges` | `id`, `tenant_id`, `financing_id`, `repayment_id`, `purpose`, `code_hash`, `expires_at`, `failed_attempts`, `consumed_at`, `issued_by`, `created_at` |
| `monvelo_platform_settings` | `id`, `offer_radius_m`, `preferred_window_minutes`, `claim_minutes`, `updated_at`, `allow_mock_insurers` |
| `monvelo_pledges` | `id`, `tenant_id`, `agent_id`, `area_id`, `supply_date`, `amount`, `remaining`, `pledged_by`, `created_at`, `updated_at` |
| `monvelo_premium_payables` | `id`, `tenant_id`, `kind`, `financing_id`, `insurer_id`, `amount`, `due_at`, `status`, `paid_reference`, `paid_by`, `paid_at`, `created_at`, `updated_at` |
| `monvelo_rebate_payable_lines` | `payable_id`, `brand_key`, `amount` |
| `monvelo_rebate_payables` | `id`, `tenant_id`, `financing_id`, `agent_id`, `amount`, `due_at`, `status`, `created_at`, `updated_at` |
| `monvelo_rebate_topups` | `id`, `tenant_id`, `financing_id`, `agent_id`, `amount`, `reason`, `due_at`, `status`, `paid_reference`, `paid_by`, `paid_at`, `created_at`, `updated_at` |
| `monvelo_repayments` | `id`, `tenant_id`, `financing_id`, `amount`, `recorded_by`, `recorded_at`, `status`, `challenge_id`, `confirmed_at`, `ended_at` |
| `monvelo_shop_enrolments` | `tenant_id`, `shop_id`, `area_id`, `recruited_by`, `consent_at`, `consent_version`, `consent_challenge_id`, `status`, `withdrawn_at`, `created_at` |
| `monvelo_shop_limit_events` | `id`, `tenant_id`, `shop_id`, `brand_key`, `kind`, `old_limit`, `new_limit`, `financing_id`, `created_at` |
| `monvelo_shop_limits` | `tenant_id`, `shop_id`, `brand_key`, `limit_amount`, `status`, `created_at`, `updated_at` |
| `monvelo_shop_policies` | `id`, `shop_id`, `insurer_name`, `policy_number`, `covers_fire_perils`, `covers_burglary`, `sum_insured`, `lender_interest_endorsed`, `starts_on`, `expires_on`, `document_path`, `status`, `submitted_by`, `consent_challenge_id`, `reviewed_by`, `reviewed_at`, `review_note`, `withdrawn_at`, `withdraw_reason`, `expiry_notice_sent_at`, `created_at`, `updated_at` |
| `monvelo_supply_days` | `tenant_id`, `area_id`, `day_of_week`, `active`, `set_by`, `created_at`, `updated_at` |
| `monvelo_tenant_fee_terms` | `id`, `tenant_id`, `fee_bps`, `valid_from`, `valid_to`, `recorded_by`, `created_at`, `decision_id` |
| `monvelo_tenant_ledger_entries` | `id`, `tenant_id`, `business_date`, `entry_type`, `financing_id`, `amount`, `created_at` |
| `monvelo_tenant_settings` | `tenant_id`, `enabled`, `opening_limit`, `approval_cap`, `updated_at`, `decision_id`, `max_limit`, `limit_growth_bps`, `default_cure_days`, `post_default_limit_bps`, `git_cover_enabled` |
| `monvelo_terms_acceptances` | `id`, `terms_code`, `audience`, `agent_id`, `tenant_id`, `decision_id`, `body_sha256`, `accepted_by`, `accepted_at` |
| `monvelo_terms_versions` | `code`, `audience`, `title`, `body`, `status`, `published_at`, `retired_at`, `created_at`, `updated_at` |
