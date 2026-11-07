# Addendum A8: Monvelo Cover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Monvelo financings are insured. The tenant is covered for goods in transit. The funding agent's capital is covered against fire and burglary in the shop: by the shop's own verified policy (no premium) or by an auto-policy whose premium comes out of the agent's rebate. A settled store claim closes the financing as `CLOSED_BY_CLAIM`.

**Architecture:** Seven migrations (`20261031121700`–`20261031122300`) add the cover tables and fold the cover into the existing claim, funding, dispatch, delivery, sweep and reconciliation functions. The database decides every amount. Two new Edge Functions talk to insurers through an adapter (`mock` and `manual` only): `monvelo-insurance-declare`, a cron-driven system function that drains a declarations outbox, and `monvelo-insurance-webhook`, a public HMAC-authenticated receiver. A third function, `monvelo-cover-upload`, takes policy certificates and loss evidence.

**Tech Stack:** Postgres 15 (plpgsql, pgTAP, pg_cron, pg_net, Storage), Supabase Edge Functions (Deno, Zod).

**Spec:** `docs/superpowers/specs/2026-11-07-addendum-a8-monvelo-cover-design.md` (approved 2026-11-07). Read it with A6 (`2026-10-28-addendum-a6-monvelo-design.md`).

## Global Constraints

- Every mutation is a `SECURITY DEFINER` RPC with `SET search_path = public, pg_temp`. It takes `p_idempotency_key uuid` first and uses `idempotency_begin` / `idempotency_complete` and `write_audit` (`20261006130300_write_contract.sql`).
- `authenticated` gets SELECT only. RLS policies are `FOR SELECT` and use `(select auth.uid())` and `public.*` helpers.
- Never a tenant parameter. Platform roles go through `assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[])` (or `MONVELO_FINANCE`). Tenant roles go through `assert_tenant_role`.
- Refusals: wrong role `42501`; not found or out of reach `P0002`; disallowed state `P0001`; bad argument `22023`.
- Money `numeric(15,2)`. Rates are `integer` basis points. Statuses are `text` + `CHECK`. No new Postgres enums.
- No request ever carries an amount, a rate or an account. `p_expected_net_yield_bps` is an acknowledgement compared against the derived quote. It is never used to compute anything.
- Lender privacy (A6 §16.2.2): STORAGE claims, rebate top-ups, cover rows naming a lender, and their audit rows are tenant-null or out of the tenant's column grant. Tenants never see an agent.
- `btree_gist` is not installed. Overlap rules are trigger or RPC checks, as in `20261028120400_monvelo_terms.sql`.
- Ruling 46: the declare function is a system function (`x-cron-secret`, constant-time compare). The webhook is a public function that verifies its HMAC before any service RPC. Both reach the secret key only through `serviceRpc()` / `_shared/core/keys.ts`, and both are listed in `SERVICE_RPC` in `supabase/functions/_tests/service-role-guard.test.ts`.
- No real insurer API code. The adapters are `MOCK` and `MANUAL` only (user, 2026-11-07).
- Everything stays local on branch `feature/addendum-a8-monvelo-cover`. No `db push`, no `functions deploy`, no `git push`.

## Corrections to the spec made while planning (Claude's; state them in the hand-off)

1. **Policy consent uses `monvelo_consent_challenges`, not `monvelo_owner_challenges`.** The spec (§6.3) named the owner challenges. Those require a financing. The consent challenges already carry `tenant_id`, `shop_id` and `area_id`, which is exactly the policy's shape. They gain `purpose text not null default 'ENROLMENT' check in ('ENROLMENT','SHOP_POLICY')`.
2. **Phase 4 is the cross-cutting harness, not "write the tests".** Every task here is test-first, as the repo has always worked. Phase 4 (Task 10) adds the guards, the mock end-to-end run, the full suite and the documentation. The spec's client phase stays under Spec B, which is on hold.

## Review Focus

1. **A shop enrolled under two tenants** with financings open in both. The sum-insured test must add open principal across **all** tenants, or a ₦500k policy exempts ₦900k of stock. Test in Task 2 (`cover status sums all tenants`).
2. **The quote changes inside the claim window.** The STORAGE product is withdrawn or a brand term changes between the read and the claim, or between the claim and the Paystack settlement. The claim refuses (`P0001`). The settlement pays exactly the locked net. Tests in Task 3.
3. **One brand's rebate is below its premium** in a multi-brand order. `request_monvelo_financing` refuses and names that brand. It does not refuse the shop as a whole while the shop is verified. Test in Task 3.
4. **The shop repays in full while a STORAGE claim is open,** or a settlement arrives after repayment. Repayment withdraws the open claim. A settlement on a non-open claim is recorded, flags `CLAIM_SETTLED_AFTER_CLOSE`, and does not touch the financing. Tests in Task 5.
5. **Webhook events arrive twice or out of order** (settled before under-review). Duplicates are no-ops by `(insurer_id, event_id)`. `FILED → SETTLED` is allowed directly. Tests in Tasks 5 and 8.

---

## Phase 1: Schema and migrations

### Task 1: Cover schema (migration 121700)

**Files:**
- Create: `supabase/migrations/20261031121700_monvelo_cover_schema.sql`
- Test: `supabase/tests/database/072_monvelo_cover_schema.test.sql`

**Interfaces:**
- Produces tables exactly as spec §5:
  - `monvelo_insurers` (§5.1; seed none);
  - `monvelo_insurance_products` (§5.1);
  - `monvelo_shop_policies` (§5.2), with the unique index `(lower(insurer_name), policy_number) where status <> 'REJECTED'` and `owner_challenge_id uuid not null references monvelo_consent_challenges(id)`;
  - `monvelo_financing_cover` and `monvelo_financing_line_cover` (§5.3);
  - `monvelo_order_git_cover` (§5.3, pk `order_id`, unique `financing_id`);
  - `monvelo_premium_payables` and `monvelo_rebate_topups` (§5.4);
  - `monvelo_insurance_claims` (§5.5; reference `^IC-[A-Z2-7]{8}$`);
  - `monvelo_insurance_declarations` (§7.2);
  - `monvelo_insurer_events` (`insurer_id`, `event_id text`, `received_at`, `payload jsonb`, pk `(insurer_id, event_id)`).
- Produces the CHECK changes, each drop-and-re-add:
  - `monvelo_financings.status` gains `CLOSED_BY_CLAIM`, plus a CHECK that it has `outstanding = 0 and closed_at is not null`;
  - `monvelo_tenant_ledger_entries.entry_type` gains `GIT_PREMIUM` (negative, like the others);
  - `monvelo_consent_challenges.purpose` (correction 1);
  - `email_outbox.template` gains `MONVELO_SHOP_COVER_EXPIRING`, and `source_table` gains `monvelo_shop_policies`;
  - `monvelo_flags.kind` gains `DECLARATION_FAILED`, `DECLARATION_STALE`, `DECLARATION_REJECTED`, `CLAIM_SHORTFALL`, `CLAIM_SETTLED_AFTER_CLOSE`, `POLICY_WITHDRAWN_OPEN_FINANCING` and `PREMIUM_RECOVERY` (check the current list in `20261031120000_monvelo_funding.sql` and keep it);
  - `notifications` kinds gain `MONVELO_SHOP_COVER_EXPIRING`, `MONVELO_COVER_REJECTED` and `MONVELO_CLAIM_UPDATE`, if kinds are CHECK-constrained.
- Produces the transition guard: the latest `monvelo_financings_guard` body, with `DELIVERED → CLOSED_BY_CLAIM` and `DEFAULTED_WITH_LATE_CHARGE → CLOSED_BY_CLAIM` added. `CLOSED_BY_CLAIM` is terminal.
- Produces `monvelo_tenant_settings.git_cover_enabled boolean not null default false`.
- Produces the private buckets `monvelo-shop-policies` and `monvelo-claim-evidence` (follow `20261029120250_contact_report_review_hard_copy.sql`: 10 MB, `image/jpeg`, `image/png`, `application/pdf`).
- Produces the insert-only and no-delete triggers (`monvelo_no_delete`) on every new table. Claims, payables, top-ups, declarations and policies change status only through the RPCs, enforced by guard triggers that allow the transitions in the spec.
- Produces RLS and grants:
  - `monvelo_insurers` and `monvelo_insurance_products`: Monvelo staff read.
  - `monvelo_shop_policies`: Monvelo staff, plus the ZSA and ASA of a tenant where the shop is enrolled in their area (helper `can_read_monvelo_shop_policy(p_shop_id uuid) returns boolean`, STABLE SECURITY DEFINER).
  - `monvelo_order_git_cover` and GIT claims: tenant roles CSM, TENANT_ADMIN and LOGISTICS_MANAGER.
  - STORAGE claims, cover, line cover, top-ups and premium payables: Monvelo staff only.
  - Declarations and insurer events: no policy, revoked from `anon` and `authenticated`.

- [ ] **Step 1: Write the failing pgTAP file** with fixtures in the style of `069_monvelo_deferred_minors.test.sql`:
  - `schema`: `has_table` for all 11 tables; `col_not_null` on every money and status column.
  - `checks`: `throws_ok` (23514) for each of these inserts:
    - a STORAGE product at `rate_bps = 0`;
    - a policy with `expires_on <= starts_on`;
    - a claim of kind STORAGE with payee `TENANT`;
    - a ledger `GIT_PREMIUM` of `+1`;
    - a financing set to `CLOSED_BY_CLAIM` with `outstanding = 5`.
  - `transitions`: `REPAID_WITHIN_WINDOW → CLOSED_BY_CLAIM` → `P0001`; `DELIVERED → CLOSED_BY_CLAIM` with `outstanding = 0`, `closed_at = now()` passes.
  - `RLS`: as a TENANT_ADMIN, CSM, ZSM or TM, `count(*)` of STORAGE claims, cover, top-ups and policies = 0. As a ZSA of a tenant where the shop is not enrolled, policies = 0. As that shop's area ZSA = 1. As an operator, all.
  - `grants`: `authenticated` has no INSERT, UPDATE or DELETE on any new table. SELECT on declarations → `42501`.
  - `buckets`: both exist, `public = false`.
- [ ] **Step 2: Run and see it fail.** Run `npx supabase test db` from `C:\Users\User\Teafair`. Expected: `072` FAILs (relation does not exist).
- [ ] **Step 3: Write the migration** with the Interfaces above. Copy the guard bodies from their latest definitions (`grep -l "function public.monvelo_financings_guard"` and take the newest file).
- [ ] **Step 4: Apply and test.** Run `npx supabase migration up`, then `npx supabase test db`. Expected: `Result: PASS` for the whole suite (the old files are untouched).
- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261031121700_monvelo_cover_schema.sql supabase/tests/database/072_monvelo_cover_schema.test.sql
git commit -m "feat(db): Monvelo cover schema, CLOSED_BY_CLAIM, premium payables (A8 §5)"
```

---

## Phase 2: Core functions and RPCs

### Task 2: Insurance products, shop policies, cover status (migration 121800)

**Files:**
- Create: `supabase/migrations/20261031121800_monvelo_cover_policies.sql`
- Test: `supabase/tests/database/073_monvelo_cover_policies.test.sql`

**Interfaces:**
- Consumes: the Task 1 tables.
- Produces (all `returns jsonb`, granted to `authenticated` unless noted):
  - `propose_monvelo_insurance_product(p_idempotency_key uuid, p_insurer_id uuid, p_kind text, p_rate_bps integer, p_facilitator_fee_bps integer, p_valid_from date, p_valid_to date)` → `{ product_id, status }`. OPERATOR only.
  - `approve_monvelo_insurance_product(p_idempotency_key uuid, p_product_id uuid)`. OPERATOR, not the proposer (`42501`). An overlapping APPROVED product of the same kind → `P0001`.
  - `withdraw_monvelo_insurance_product(p_idempotency_key uuid, p_product_id uuid, p_reason text)`.
  - `register_monvelo_insurer(p_idempotency_key uuid, p_code text, p_legal_name text, p_naicom_licence_no text, p_api_provider text)` and `set_monvelo_insurer_status(p_idempotency_key uuid, p_insurer_id uuid, p_status text)`. OPERATOR.
  - `start_monvelo_policy_consent(p_idempotency_key uuid, p_gateway_proof text, p_shop_id uuid, p_area_id uuid)`: mirrors `start_monvelo_consent` (`20261028120600_monvelo_shop_enrolment.sql`) with `purpose = 'SHOP_POLICY'`. The caller is an ACTIVE ZSA or ASA of `jwt_tenant_id()` covering `p_area_id`, and the shop has an ACTIVE enrolment there.
  - `submit_monvelo_shop_policy(p_idempotency_key uuid, p_shop_id uuid, p_consent_challenge_id uuid, p_insurer_name text, p_policy_number text, p_covers_fire_perils boolean, p_covers_burglary boolean, p_sum_insured numeric, p_lender_interest_endorsed boolean, p_starts_on date, p_expires_on date, p_document_path text)` → `{ policy_id, status: 'PENDING' }`. The challenge must be consumed, of purpose SHOP_POLICY, for this shop, issued to this caller, and under 30 minutes old. `p_document_path` must start with `<shop_id>/` and exist in `storage.objects` in `monvelo-shop-policies`.
  - `review_monvelo_shop_policy(p_idempotency_key uuid, p_policy_id uuid, p_verify boolean, p_note text)`. OPERATOR, not the submitter. `p_verify = true` refuses (`P0001`) unless fire, burglary and endorsement are all true and `expires_on > current_date`.
  - `withdraw_monvelo_shop_policy(p_idempotency_key uuid, p_policy_id uuid, p_reason text)`. OPERATOR. Flags `POLICY_WITHDRAWN_OPEN_FINANCING` for each open financing locked to it.
  - `monvelo_shop_open_principal(p_shop_id uuid) returns numeric`: internal. Sums the principal of the shop's financings in `CLAIMED`, `FUNDED`, `DELIVERED` and `DEFAULTED_WITH_LATE_CHARGE` across all tenants.
  - `monvelo_shop_cover_status(p_shop_id uuid, p_through timestamptz, p_principal numeric) returns table (status text, policy_id uuid)`: internal, revoked from everyone. Rules as spec §5.2.2: VERIFIED only if `starts_on <= current_date (Lagos)`, `expires_on >= p_through::date (Lagos)` and `sum_insured >= monvelo_shop_open_principal + p_principal`.
- Audit: every policy and product row is tenant-null (`write_audit` with a null tenant).

- [ ] **Step 1: Write the failing pgTAP file.** Tests:
  - `product two-person`: proposer approves → `42501`; a second operator approves → APPROVED; an overlapping second STORAGE product → `P0001`; a ZSA proposing → `42501`.
  - `policy consent`: submit with an unconsumed, expired or other-shop challenge → `P0001`; a ZSA of a tenant without the shop's enrolment → `42501`.
  - `review`: the submitter reviewing → `42501`; verifying without the endorsement → `P0001`; a valid one → VERIFIED; reviewing again → `P0001`.
  - `cover status`:
    - no row → `UNVERIFIED`;
    - PENDING → `PENDING`;
    - VERIFIED, covering through `p_through` → `VERIFIED` with its id;
    - `expires_on` one day before `p_through` → not VERIFIED;
    - `sum_insured` 500000 with 300000 open in tenant A and `p_principal` 250000 in tenant B → not VERIFIED (`cover status sums all tenants`);
    - REJECTED only → `REJECTED`.
  - `withdraw`: VERIFIED → WITHDRAWN; one flag per open locked financing.
  - `audit tenant-null`: `audit_logs.tenant_id is null` for policy rows.
- [ ] **Step 2: Run and see it fail** (`npx supabase test db`; `073` FAILs, function does not exist).
- [ ] **Step 3: Write the migration** with the Interfaces above.
- [ ] **Step 4: Apply and test** (`npx supabase migration up && npx supabase test db`). Expected: `Result: PASS`.
- [ ] **Step 5: Commit** with `feat(db): insurer products, shop policies and cover status (A8 §5.1, §5.2)`.

### Task 3: Quote, offer read model, claim lock, net rebate at funding (migration 121900)

**Files:**
- Create: `supabase/migrations/20261031121900_monvelo_cover_quote.sql`
- Test: `supabase/tests/database/074_monvelo_cover_quote.test.sql`
- Modify (in the new migration, `create or replace` from the newest body of each):
  - `request_monvelo_financing` (`20261029130300` or newer);
  - `claim_monvelo_financing` (`20261031120800`);
  - `decide_monvelo_claim_hold` (`20261031121300`);
  - `settle_monvelo_funding` (the newest body; grants in `20261031120900`);
  - the `monvelo-fund` / claim gateway Zod schema in `supabase/functions/monvelo-fund/` (and its `_shared/monvelo` helper), if the claim goes through it.

**Interfaces:**
- Consumes: `monvelo_shop_cover_status`, `monvelo_terms_at(tenant_id, brand, day)`.
- Produces:
  - `monvelo_quote_cover(p_financing_id uuid) returns jsonb`: internal, revoked from everyone. Shape: `{ cover_kind, shop_policy_id, product_id, storage_rate_bps, blocks, gross_rebate, storage_premium, net_rebate, net_yield_bps, lines: [{ brand_key, terms_id, rebate_bps, interest_free_days, late_charge_bps, gross_rebate, storage_premium, net_rebate }] }`. Algorithm: spec §6.1 and §6.2 steps 1–4, with:
    - `p_through = (supply_date + 1) at 00:00 Lagos + 23 h + min(interest_free_days)`;
    - `blocks = ceil(min(interest_free_days) / 30.0)`;
    - premium and net rounded per line with `round(…, 2)`;
    - `net_yield_bps = floor(sum(net) * 10000 / principal)`.
  - `get_monvelo_offer_cover(p_financing_id uuid) returns table (cover_label text, gross_rebate numeric, storage_premium numeric, net_rebate numeric, net_yield_bps integer, quote_valid_until timestamptz)`. STABLE SECURITY DEFINER, granted to `authenticated`. The caller must be a member of an ACTIVE agent eligible for the offer (`my_monvelo_agent_ids()`, the same eligibility as `monvelo_open_offers`), else `42501`. The label maps `SHOP_POLICY → VERIFIED_SHOP_COVER`, `AUTO_POLICY → AUTO_POLICY` and `NONE → NO_COVER`. `quote_valid_until` is the offer's preferred-window or offer expiry.
  - `claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid, p_expected_net_yield_bps integer)` replaces the three-argument version: drop the old signature in the same migration. On a quote mismatch → `P0001` with message `cover changed; review the new yield` and `DETAIL` = the new yield. On success it upserts `monvelo_financing_cover` and `monvelo_financing_line_cover` from the quote (`locked_at = now()`, `declared_status = 'NOT_DUE'`). The hold path is the same: when a hold is created, the quote is stored on the hold, and `decide_monvelo_claim_hold` allow re-quotes. A mismatch with the stored quote refuses the allow (`P0001`), and the agent must claim again.
  - `request_monvelo_financing`: after the existing checks, if `monvelo_shop_cover_status` (with `p_principal` = the order total) is not VERIFIED and an approved STORAGE product exists, compute each line's premium. If any `premium > gross` → `P0001` with `rebate below storage premium for brand <brand>; verify the shop's cover`.
  - `settle_monvelo_funding`: the line terms come from `monvelo_financing_line_cover` and the lock (`terms_id`, `rebate_bps`, `interest_free_days`, `late_charge_bps`; `terms_locked_at` = the cover's `locked_at`). It no longer calls `monvelo_terms_at`. `monvelo_rebate_payables.amount` = Σ net, and the payable lines carry the net per brand. No ledger change.
- The gateway's Zod schema adds `expected_net_yield_bps: z.number().int().min(0).max(10000)`. A `P0001` "cover changed" maps to HTTP 409 `{ code: "COVER_CHANGED", net_yield_bps }`.

- [ ] **Step 1: Write the failing pgTAP file.** Fixtures: one brand at 1000 bps, 30 days; an approved STORAGE product at 100 bps. Tests:
  - `worked example`: principal 200000, uninsured → `gross 20000.00`, `premium 2000.00`, `net 18000.00`, `net_yield_bps 900`. Verified → premium 0, yield 1000.
  - `blocks`: 30 → 1, 31 → 2, 60 → 2 (`storage_premium` 2000 / 4000 / 4000).
  - `multi-brand rounding`: lines 33333.33 and 66666.67 at 1000 and 500 bps. Σ line net = header net. Shown yield ≤ the actual yield.
  - `no product`: `cover_kind NONE`, full rebate.
  - `read model privacy`: an agent sees the label only (the column list has no policy fields); a TENANT_ADMIN or ZSA calling it → `42501`.
  - `claim mismatch`: claim with 1000 when the quote is 900 → `P0001`, nothing written. With 900 → cover row `AUTO_POLICY`.
  - `quote changes inside the window`: withdraw the product after the read → claim with 900 → `P0001`.
  - `funding pays the locked net`: claim, then approve a new brand term at 500 bps, then `settle_monvelo_funding` → payable amount 18000.00, lines `rebate_bps = 1000`, `terms_locked_at = locked_at`.
  - `hold allow re-quotes`: a held claim, then verify the shop's policy, then allow → `P0001`.
  - `request refuses one brand`: brand B at 50 bps with a premium of 100 bps → `request_monvelo_financing` `P0001` whose message names brand B. The same order for a verified shop succeeds.
  - `old signature gone`: `hasnt_function('claim_monvelo_financing', array['uuid','uuid','uuid'])`.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Write the migration and the gateway change.** Update the existing tests that call the three-argument claim (`grep -ln "claim_monvelo_financing(" supabase/tests/database`) to pass the quoted yield. In those fixtures, with no STORAGE product approved, the yield is the full rebate in bps.
- [ ] **Step 4: Apply and test.** Run `npx supabase migration up && npx supabase test db` and `deno test -A supabase/functions/monvelo-fund`. Expected: PASS for both.
- [ ] **Step 5: Commit** with `feat(db): cover quote at claim, terms lock moves to claim, net rebate (A8 §6)`.

### Task 4: GIT at dispatch, STORAGE at delivery, payables paid (migration 122000)

**Files:**
- Create: `supabase/migrations/20261031122000_monvelo_cover_dispatch_delivery.sql`
- Test: `supabase/tests/database/075_monvelo_cover_dispatch_delivery.test.sql`
- Modify (`create or replace` from the newest bodies): `dispatch_monvelo_financing` (`20261031120100` or newer) and `confirm_monvelo_delivery`.

**Interfaces:**
- Produces:
  - `monvelo_enqueue_declaration(p_tenant_id uuid, p_kind text, p_insurer_id uuid, p_subject_table text, p_subject_id uuid, p_payload jsonb) returns uuid`: internal. The payload never contains a shop name, a phone number or an account number.
  - **Dispatch**, when `git_cover_enabled` and a GIT product is approved today: insert the `monvelo_order_git_cover` row (`insured_value` = principal, `premium = round(principal * rate_bps / 10000, 2)`, `declared_status = 'PENDING'`), a GIT premium payable (`due_at = now() + 24 h`), a `GIT_PREMIUM` ledger entry (`-premium`, `business_date` = the Lagos dispatch day), and a `GIT_DECLARE` declaration with payload `{ financing_reference, order_id, insured_value, premium, dispatched_at, tracking_reference }`.
  - **Delivery**, for `cover_kind = 'AUTO_POLICY'`: insert a STORAGE premium payable (`amount` = the cover's `storage_premium`, `due_at = now() + 24 h`), set the cover's `declared_status = 'PENDING'`, and enqueue `STORAGE_DECLARE` with payload `{ financing_reference, sum_insured: principal, premium, cover_from: delivered_at, cover_to: due_at, area_id }`. For `SHOP_POLICY` and `NONE`, do nothing new.
  - `record_monvelo_premium_paid(p_idempotency_key uuid, p_payable_id uuid, p_reference text)` and `record_monvelo_topup_paid(p_idempotency_key uuid, p_topup_id uuid, p_reference text)`. `MONVELO_FINANCE` only. `DUE → PAID`; anything else `P0001`.

- [ ] **Step 1: Write the failing pgTAP file.** Tests:
  - `GIT off`: dispatch writes no cover, payable or ledger row.
  - `GIT on`: principal 200000 at 75 bps → payable 1500.00, ledger `-1500.00` dated today (Lagos), one `GIT_DECLARE` PENDING, and the payload has no key `phone` or `shop_name`.
  - `refund keeps GIT`: run the money sweep after 23 h with no delivery → financing `REFUND_DUE`, GIT payable still `DUE`, ledger line still there, no STORAGE payable exists.
  - `STORAGE at delivery`: an AUTO_POLICY financing delivered → payable 2000.00, `declared_status PENDING`, one `STORAGE_DECLARE`. A SHOP_POLICY one → none.
  - `premium paid`: a ZSM or OPERATOR calling it → `42501`; FINANCE → PAID; again → `P0001`.
  - `tenant reads GIT only`: a CSM sees `monvelo_order_git_cover` and the `GIT_PREMIUM` ledger line, and 0 premium payables.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Apply and test.** Expected: `Result: PASS`.
- [ ] **Step 5: Commit** with `feat(db): GIT declared at dispatch, storage cover at delivery (A8 §6.2)`.

### Task 5: Loss claims and `CLOSED_BY_CLAIM` (migration 122100)

**Files:**
- Create: `supabase/migrations/20261031122100_monvelo_insurance_claims.sql`
- Test: `supabase/tests/database/076_monvelo_insurance_claims.test.sql`
- Modify (`create or replace` from the newest bodies): `monvelo_sweep_money` (`20261031120700` or newer), `confirm_monvelo_repayment` and `get_lender_reconciliation_summary`.

**Interfaces:**
- Produces:
  - `report_monvelo_loss(p_idempotency_key uuid, p_financing_id uuid, p_kind text, p_peril text, p_incident_at timestamptz, p_description text, p_evidence_paths text[])` → `{ claim_id, reference, status: 'REPORTED' }`. Caller and state rules as spec §6.3. In addition, STORAGE requires `cover_kind in ('AUTO_POLICY','SHOP_POLICY')` and `declared_status <> 'REJECTED'`. GIT requires a `monvelo_order_git_cover` row. Evidence paths must be in `monvelo-claim-evidence` under `<financing_id>/`. `claimed_amount`: STORAGE = `greatest(principal − repaid_confirmed, 0)`; GIT = `insured_value`. The payee is set from the financing (`funder_agent_id`) or the tenant.
  - `file_monvelo_insurance_claim(p_idempotency_key uuid, p_claim_id uuid)`: OPERATOR; `REPORTED → FILED`. If the cover is `AUTO_POLICY` or GIT and `declared_status` is not `ACCEPTED` → `P0001`. AUTO_POLICY and GIT enqueue `CLAIM_FILE` (payload `{ claim_reference, policy_kind, financing_reference, peril, incident_at, claimed_amount, payee: { kind, settlement_account_number, settlement_bank_code } }`). The settlement account is read from the agent for AGENT payees. A SHOP_POLICY claim is filed manually (no declaration) and goes straight to FILED.
  - `monvelo_settle_claim(p_claim_id uuid, p_settled_amount numeric, p_payout_reference text, p_actor uuid) returns jsonb`: internal, used by both entry points below.
    - Claim `FILED` or `UNDER_REVIEW` → SETTLED.
    - STORAGE: lock the financing (`monvelo_lock_financing`). If it is `DELIVERED` or `DEFAULTED_WITH_LATE_CHARGE`, set `CLOSED_BY_CLAIM`, `outstanding = 0`, `closed_at = now()`, and `late_charge_waived = late_charge_amount` (a new nullable column on the claim). A shortfall above 0 flags `CLAIM_SHORTFALL`. Notify the agent's members (`MONVELO_CLAIM_UPDATE`). Audit tenant-null.
    - GIT: notify the tenant's CSM and LOGISTICS_MANAGER.
    - A claim that is not open → `CLAIM_SETTLED_AFTER_CLOSE` flag, nothing else changes, returns `{ ignored: true }`.
  - `settle_monvelo_insurance_claim(p_insurer_code text, p_claim_reference text, p_settled_amount numeric, p_payout_reference text)`: `service_role` only, for the webhook.
  - `record_monvelo_claim_settlement(p_idempotency_key uuid, p_claim_id uuid, p_settled_amount numeric, p_payout_reference text)`: OPERATOR; for MANUAL insurers and SHOP_POLICY claims.
  - `set_monvelo_claim_status(p_idempotency_key uuid, p_claim_id uuid, p_status text, p_insurer_claim_reference text)`: OPERATOR; FILED → UNDER_REVIEW | REJECTED.
  - **Sweep:** skip the late charge for a `DELIVERED` financing with an open STORAGE claim.
  - **Repayment:** a confirmation that brings `outstanding` to 0 sets every open STORAGE claim to WITHDRAWN.
  - **Reconciliation summary:** gains `closed_by_claim_amount numeric(15,2)` and `late_charge_waived numeric(15,2)`. Keep the existing columns and their order, and append the new ones. Drop and recreate the function if the return type changes, and keep its grants.
  - **Exposure:** `monvelo_agent_open_exposure` already excludes non-open statuses. Assert that `CLOSED_BY_CLAIM` frees it, and change it only if the test fails.

- [ ] **Step 1: Write the failing pgTAP file.** Tests:
  - `report rules`:
    - an ASA of another area → `42501`;
    - STORAGE on a `FUNDED` financing → `P0001`;
    - an incident before `delivered_at` → `P0001`;
    - STORAGE on cover `NONE` → `P0001`;
    - a second open claim → `P0001`;
    - GIT by the LOGISTICS_MANAGER on a `REFUND_DUE` financing → REPORTED with payee TENANT.
  - `claimed amount`: principal 200000, 50000 repaid, late charge applied → `claimed_amount` 150000.00.
  - `file waits for acceptance`: `declared_status PENDING` → `P0001`; ACCEPTED → FILED and one `CLAIM_FILE` declaration.
  - `settle closes`: settled 150000 → claim SETTLED; financing `CLOSED_BY_CLAIM`, `outstanding 0`; `late_charge_waived` equals the charge; agent exposure decreases by the principal; summary `closed_by_claim_amount` = 150000.
  - `shortfall`: settled 120000 → one `CLAIM_SHORTFALL` flag; still closed.
  - `FILED → SETTLED directly` passes.
  - `late charge paused`: an open claim plus `due_at` passed → the sweep leaves `late_charge_amount = 0`. Reject the claim, then sweep → the charge is applied.
  - `repaid in full withdraws`: an open claim plus a full repayment → WITHDRAWN. Then `settle_monvelo_insurance_claim` → `{ ignored: true }`, a `CLAIM_SETTLED_AFTER_CLOSE` flag, and the financing stays `REPAID_*`.
  - `privacy`: a TENANT_ADMIN sees 0 STORAGE claims and 1 GIT claim; audit rows of STORAGE claims are tenant-null.
  - `grants`: `settle_monvelo_insurance_claim` is not executable by `authenticated`.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Apply and test.** Expected: `Result: PASS` (the existing sweep, repayment and reconciliation tests 063–065 still pass).
- [ ] **Step 5: Commit** with `feat(db): loss claims, CLOSED_BY_CLAIM, late charge paused and waived (A8 §5.5, §5.6, §6.4)`.

### Task 6: Declaration outcomes and the policy-expiry sweep (migration 122200)

**Files:**
- Create: `supabase/migrations/20261031122200_monvelo_declarations_and_expiry.sql`
- Test: `supabase/tests/database/077_monvelo_declarations_and_expiry.test.sql`

**Interfaces:**
- Produces (`service_role` only unless noted):
  - `claim_monvelo_declarations(p_limit integer default 20) returns setof jsonb`. Claims rows with `PENDING` and `next_attempt_at <= now()`, or `SENDING` older than 10 minutes, using `FOR UPDATE SKIP LOCKED`. Sets `SENDING` and `attempts + 1`, and returns `{ id, kind, insurer_code, api_provider, payload }`.
  - `complete_monvelo_declaration(p_id uuid, p_outcome text, p_insurer_reference text, p_error text) returns jsonb`. `p_outcome in ('ACCEPTED','REJECTED','RETRY')`:
    - **RETRY:** back to PENDING with `next_attempt_at = now() + least(2^attempts minutes, 6 h)`. Past 24 h from `created_at` → FAILED plus a `DECLARATION_FAILED` flag.
    - **ACCEPTED / REJECTED:** propagate to the subject (`monvelo_financing_cover.declared_status`, `monvelo_order_git_cover.declared_status`, or the claim's `insurer_claim_reference` and status → FILED stays FILED on ACCEPTED, REJECTED → claim REJECTED).
    - **STORAGE_DECLARE REJECTED** (spec §6.4): cancel the STORAGE payable if it is DUE, otherwise flag `PREMIUM_RECOVERY`. Insert a `monvelo_rebate_topups` row (`amount` = the premium, `reason DECLARATION_REJECTED`, `due_at = now() + 24 h`), flag `DECLARATION_REJECTED`, and notify the agent's members (`MONVELO_COVER_REJECTED`) and the operators. All idempotent: a second REJECTED for the same declaration is a no-op.
  - `record_monvelo_declaration_outcome(p_idempotency_key uuid, p_declaration_id uuid, p_outcome text, p_insurer_reference text)`: OPERATOR, granted to `authenticated`. The MANUAL adapter's path: the operator records what the insurer said.
  - `monvelo_sweep_declarations() returns integer`: flags `DECLARATION_STALE` once per STORAGE declaration still not ACCEPTED 24 h after delivery.
  - `monvelo_sweep_shop_policies() returns jsonb`: spec §7.1, steps 1 and 2. The Lagos date decides "today". It enqueues through the A7 `enqueue_email(p_template, p_to_email, p_payload, p_source_table, p_source_id)` with payload `{ shop_name, expires_on }` only, and inserts notifications.
  - Cron: `monvelo-shop-policy-sweep` at `0 5 * * *` (05:00 UTC = 06:00 Lagos) and `monvelo-declaration-sweep` at `*/15 * * * *`.

- [ ] **Step 1: Write the failing pgTAP file.** Tests:
  - `claim batch`: 3 PENDING, `p_limit` 2 → 2 SENDING; a stale SENDING row is reclaimed.
  - `retry schedule`: RETRY after `attempts = 3` → `next_attempt_at ≈ now() + 8 min`. With `created_at` 25 h ago → FAILED plus a flag.
  - `accepted propagates`: the cover's `declared_status` becomes ACCEPTED.
  - `storage rejected`: payable CANCELLED, top-up 2000.00 DUE, a `DECLARATION_REJECTED` flag, an agent notification. A repeat call adds no second top-up. `report_monvelo_loss` STORAGE afterwards → `P0001`.
  - `rejected after premium paid`: the payable stays PAID and a `PREMIUM_RECOVERY` flag is raised.
  - `stale`: a delivered AUTO_POLICY financing with its declaration PENDING 25 h → one flag; a second sweep adds none.
  - `expiry`: a VERIFIED policy with `expires_on` yesterday → EXPIRED. One expiring in 15 days → one `email_outbox` row per area ZSA and ASA with an email, `template MONVELO_SHOP_COVER_EXPIRING`, payload keys exactly `{shop_name, expires_on}`, and `expiry_notice_sent_at` set. A second run adds no row. A ZSA without an email gets the notification only.
  - `manual outcome`: a ZSA calling `record_monvelo_declaration_outcome` → `42501`; OPERATOR → applied.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Apply and test.** Expected: `Result: PASS`.
- [ ] **Step 5: Commit** with `feat(db): insurer declaration outcomes and the policy-expiry sweep (A8 §7.1, §7.2)`.

---

## Phase 3: Edge Functions and background automation

### Task 7: Insurer adapters and `monvelo-insurance-declare` (migration 122300)

**Files:**
- Create:
  - `supabase/functions/_shared/insurance/adapter.ts`, `mock.ts`, `manual.ts`, `registry.ts`, and `adapter.test.ts`;
  - `supabase/functions/monvelo-insurance-declare/index.ts`, `handler.ts` and `handler.test.ts`;
  - `supabase/migrations/20261031122300_monvelo_insurance_declare_cron.sql`.
- Modify: `supabase/functions/_tests/service-role-guard.test.ts` (`SERVICE_RPC` entry `"system: x-cron-secret (constant time)"`) and `supabase/functions/_tests/secret-scoping.test.ts`, if it lists functions.

**Interfaces:**
- Produces in `adapter.ts`:

```ts
export type DeclarationKind = "GIT_DECLARE" | "STORAGE_DECLARE" | "STORAGE_CANCEL" | "CLAIM_FILE";
export type SendResult =
  | { outcome: "ACCEPTED"; insurerReference: string }
  | { outcome: "REJECTED"; insurerReference: string | null; error: string }
  | { outcome: "RETRY"; error: string }
  | { outcome: "QUEUED_MANUAL" };                      // MANUAL: leave SENDING→PENDING untouched for the operator
export interface InsurerAdapter {
  send(kind: DeclarationKind, payload: Record<string, unknown>, idempotencyKey: string): Promise<SendResult>;
  verifyWebhook(req: Request, rawBody: string): Promise<boolean>;
  parseEvent(rawBody: string): InsurerEvent;          // { eventId, type, claimReference?, declarationId?, settledAmount?, payoutReference?, insurerReference? }
}
```

- `registry.ts`: `adapterFor(apiProvider: "MOCK" | "MANUAL")`. Any other value throws (there is no MYCOVER adapter yet, by decision 8).
- `mock.ts`: accepts by default. A payload with `financing_reference` ending in `REJ` → REJECTED, and `RTY` → RETRY. The webhook HMAC is SHA-256 over the raw body with env `MONVELO_MOCK_INSURER_SECRET`, in header `x-insurer-signature`, with `x-insurer-timestamp` (5-minute window).
- `manual.ts`: `send` returns `QUEUED_MANUAL`, and `verifyWebhook` always returns false (manual insurers never call in).
- Handler: authenticate `x-cron-secret`, then `claim_monvelo_declarations(20)`. For each row, call `adapterFor(row.api_provider).send(row.kind, row.payload, row.id)`, then:
  - ACCEPTED, REJECTED or RETRY → `complete_monvelo_declaration`;
  - QUEUED_MANUAL → leave the row in `SENDING` with `next_attempt_at` far ahead. Add an outcome `'MANUAL'` to `complete_monvelo_declaration` in this migration that sets it back to `PENDING` with `next_attempt_at = 'infinity'`, so it waits for `record_monvelo_declaration_outcome`.
  - It never throws on one row's failure, and returns `{ sent, accepted, rejected, retried, manual }`.
- The migration adds the `MANUAL` outcome and `cron.schedule('monvelo-insurance-declare', '* * * * *', $$select public.invoke_system_function('monvelo-insurance-declare', '{}'::jsonb)$$)`.

- [ ] **Step 1: Write the failing Deno tests**:
  - `adapter.test.ts`: mock accept, REJ, RTY; signature valid, tampered and stale; `adapterFor("MYCOVER")` throws.
  - `handler.test.ts` (stubbed RPC client): missing or wrong cron secret → 401 and no RPC call; mixed batch → one `complete_monvelo_declaration` per row with the right outcome; MANUAL → outcome `MANUAL`; an adapter throwing on one row → that row gets RETRY and the others complete.
- [ ] **Step 2: Run and see it fail.** Run `deno test -A supabase/functions/_shared/insurance supabase/functions/monvelo-insurance-declare`. Expected: FAIL (module not found).
- [ ] **Step 3: Implement** the files above, following `email-outbox-send/handler.ts` for the cron auth and the RPC client.
- [ ] **Step 4: Run the tests.** Run the Deno tests, `deno test -A supabase/functions/_tests`, `npx supabase migration up` and `npx supabase test db`. Expected: all PASS.
- [ ] **Step 5: Commit** with `feat(functions): insurer adapters (mock, manual) and monvelo-insurance-declare (A8 §7.2, §7.4)`.

### Task 8: `monvelo-insurance-webhook`

**Files:**
- Create: `supabase/functions/monvelo-insurance-webhook/index.ts`, `handler.ts` and `handler.test.ts`; `supabase/migrations/20261031122400_monvelo_insurer_events.sql`.
- Modify: `service-role-guard.test.ts` (entry `"public: insurer HMAC (adapter.verifyWebhook)"`).

**Interfaces:**
- Produces: `record_monvelo_insurer_event(p_insurer_code text, p_event_id text, p_payload jsonb) returns boolean` (`service_role`). Returns true if new, false on a duplicate `(insurer_id, event_id)`. An unknown or SUSPENDED insurer → `P0002`.
- Route: `POST /functions/v1/monvelo-insurance-webhook?insurer=<CODE>`. Look up the insurer's `api_provider` (service RPC `get_monvelo_insurer_provider(p_code text) returns text`, defined in the same migration), then `verifyWebhook` (401 on failure, before any other RPC) and `parseEvent`. Then:
  - `record_monvelo_insurer_event`; a duplicate → 200 `{ duplicate: true }`;
  - dispatch by type:
    - `declaration.accepted` / `declaration.rejected` → `complete_monvelo_declaration`;
    - `claim.under_review` / `claim.rejected` → the internal `monvelo_set_claim_status_service(p_claim_reference, p_status)` (same migration, `service_role`);
    - `claim.settled` → `settle_monvelo_insurance_claim`.
  - An unknown type → 200 `{ ignored: true }`, after being recorded.
- Zod schemas validate every event body. Amounts are decimal strings matching `^\d{1,13}\.\d{2}$`.

- [ ] **Step 1: Write the failing Deno tests**: a bad signature → 401 and zero RPC calls; a stale timestamp → 401; a duplicate event → 200 with no dispatch; `claim.settled` → `settle_monvelo_insurance_claim` with the parsed amount string; a malformed amount → 400; `?insurer=` missing → 400; a MANUAL insurer → 401.
- [ ] **Step 2: Run and see it fail.** Run `deno test -A supabase/functions/monvelo-insurance-webhook`.
- [ ] **Step 3: Implement** the function, the migration, and a pgTAP addition in `077` for `record_monvelo_insurer_event` (new → true, repeat → false, `authenticated` → no execute).
- [ ] **Step 4: Run the tests.** Run the Deno tests, `deno test -A supabase/functions/_tests` and `npx supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(functions): monvelo-insurance-webhook with HMAC and event dedupe (A8 §7.3)`.

### Task 9: Uploads, consent gateway and the expiry email template

**Files:**
- Create: `supabase/functions/monvelo-cover-upload/index.ts`, `handler.ts` and `handler.test.ts`.
- Modify:
  - `supabase/functions/monvelo-shop-consent/` (add the `start_policy` action calling `start_monvelo_policy_consent`, and its confirm path);
  - `supabase/functions/email-outbox-send/templates.ts` and `templates.test.ts` (`MONVELO_SHOP_COVER_EXPIRING`).

**Interfaces:**
- `monvelo-cover-upload`: a user-facing function that forwards the caller's JWT and never uses the secret key. It follows `contact-report-upload`. Body `{ purpose: "SHOP_POLICY" | "CLAIM_EVIDENCE", subject_id: uuid, content_type, byte_length }`. It returns a signed upload URL for `monvelo-shop-policies/<shop_id>/<uuid>.<ext>` or `monvelo-claim-evidence/<financing_id>/<uuid>.<ext>`. It authorises through a read RPC, `can_upload_monvelo_cover(p_purpose text, p_subject_id uuid) returns boolean` (new migration `20261031122500_monvelo_cover_upload_check.sql`, with its pgTAP cases appended to `077`): the area's ZSA or ASA for SHOP_POLICY, and the reporters allowed by `report_monvelo_loss` for CLAIM_EVIDENCE. It enforces 10 MB and JPEG, PNG or PDF.
- Template: subject `Shop cover expiring: {shop_name}`, body "The fire and burglary policy for {shop_name} expires on {expires_on}. Ask the shop owner for the renewed certificate and add it in the app before then, or the shop's agents will pay the auto-policy premium." HTML-escaped as in A7.

- [ ] **Step 1: Write the failing tests**:
  - upload: unauthorised → 403; wrong type or size → 400; ok → a path with the right prefix;
  - the consent gateway's `start_policy` → RPC called with the forwarded JWT;
  - template: `<script>` in `shop_name` is escaped, and the body contains no policy number.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Deno tests for the three functions and `deno test -A supabase/functions/_tests`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(functions): cover uploads, policy consent action, expiry email (A8 §6.3, §7.1)`.

---

## Phase 4: Testing harness and assertions

### Task 10: Guards, mock end-to-end, full suite, records

**Files:**
- Create: `supabase/tests/database/078_monvelo_cover_end_to_end.test.sql`
- Modify:
  - `supabase/tests/database/045_monvelo_agent_renames.test.sql` (or wherever the §15 boundary guard lives; `grep -ln "web_" supabase/tests/database | xargs grep -l "monvelo"`): add the new tables to the Monvelo set, so that no `web_*` function reads them;
  - `supabase/functions/_tests/gateway.integration.ts`: an A8 case;
  - `CLAUDE.md`, `supabase/CLAUDE.md` (rulings for the §13 calls and the two plan corrections, the function list, the env `MONVELO_MOCK_INSURER_SECRET`);
  - the deploy checklist generator content (`docs/reports/generator/content/deploy.mjs`), which is **regenerated, never committed** (memory: project_deploy_checklist).

**Interfaces:**
- Consumes everything above.

- [ ] **Step 1: Write the failing end-to-end pgTAP file `078`.** One AUTO_POLICY financing, start to finish:
  - request, quote (yield 900), claim at 900, settle funding (rebate payable 18000.00);
  - dispatch (GIT payable 1500.00 and ledger `-1500.00`), deliver (STORAGE payable 2000.00);
  - `claim_monvelo_declarations`, then `complete_monvelo_declaration(ACCEPTED)` for both;
  - report a FIRE loss, file it (a `CLAIM_FILE` row), complete it as ACCEPTED, then `settle_monvelo_insurance_claim('MOCK', ref, '200000.00', 'PAYOUT-1')`.
  - Assert:
    - `CLOSED_BY_CLAIM`, `outstanding 0`;
    - agent exposure 0;
    - the reconciliation summary shows funded 200000 and closed by claim 200000;
    - the tenant ledger has `FUNDED_GROSS`, `FEE` and `GIT_PREMIUM` only;
    - the TENANT_ADMIN sees no agent id anywhere in the rows it can read;
    - `select count(*) from audit_logs where tenant_id is not null and new_values::text like '%' || agent_id || '%'` = 0.
  - A second financing for a VERIFIED shop: yield 1000, no STORAGE payable or declaration.
- [ ] **Step 2: Run and see it fail, or pass at once.** If it passes, that confirms the earlier tasks join up. Record which.
- [ ] **Step 3: Add the boundary-guard and integration cases. Run every check:**

```bash
npx supabase db reset
npx supabase test db
deno test -A supabase/functions
```

Expected: `Result: PASS`, with the file count up by 7 (072–078), and every Deno test green, including `service-role-guard`, `secret-scoping` and `keys`.
- [ ] **Step 4: Update the records.** Add the A8 row to `CLAUDE.md` (built locally, not pushed, with the migration and assertion counts from the run). Add the rulings to `supabase/CLAUDE.md`. Regenerate the deploy checklist PDF without committing it. Add a memory entry for A8.
- [ ] **Step 5: Commit** with `docs: record addendum A8 (Monvelo cover); end-to-end and guards`. Then run `superpowers:requesting-code-review` on the branch before any merge.
