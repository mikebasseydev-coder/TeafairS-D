# Monvelo Step 3: Funding, Delivery, Repayment and the Late Charge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CLAIMED financing is paid through Paystack from the agent's own account, the stock is dispatched and confirmed by the shop owner, the shop repays the agent in confirmed part payments, and an unpaid balance takes the brand's late charge once.

**Architecture:** Same three layers as every step. Edge Functions do the Paystack and WhatsApp IO and forward the caller's JWT. `SECURITY DEFINER` RPCs own every transition. The service-role webhook RPC `settle_monvelo_funding` is the only path to FUNDED. One new cron sweep, `monvelo-money-sweep`, handles the time-driven moves: refund-due, the late charge and unconfirmed repayments. The existing `monvelo-offer-sweep` (Step 2) is unchanged.

**Tech Stack:** Postgres 17 (pgTAP, pg_cron), Deno Edge Functions, Zod, Paystack Initialize/Verify, the A5 message router (WhatsApp only).

**Spec:** `docs/superpowers/specs/2026-10-28-addendum-a6-monvelo-design.md` §4.4, §5 steps 5–10, §6.2, §6.3, §7.4, §11 F1, §16.5, §18.1, §18.2. Builds on `docs/superpowers/plans/2026-10-29-monvelo-step1c-step2.md` (its calls 9, 18, 20, 23 are settled here).

## Scope (what "Step 3" means here)

The spec's build order (§12) puts funding (4) and delivery and repayment OTPs (5) in separate steps. This plan does both, as the user asked on 2026-10-31, plus the money-state sweeps they need.

**Out of scope:**
- Rebate payouts, payout accounts and second approval (Step 5). This step only creates the payable at funding.
- Every template notice (`monvelo_rebate_confirmed`, reminders, `monvelo_late_charge`, day-45 escalation; Step 6). Only the owner's one-time codes are sent here, through the existing OTP template.
- The finance dashboard.

## Global Constraints

- Every mutation is a `SECURITY DEFINER` RPC with `SET search_path = public, pg_temp`, taking `p_idempotency_key uuid` first. Service-role-only RPCs take a derived key (`md5(...)::uuid`), as `settle_paystack_payment` does.
- The tenant is never a parameter. Callers are checked live through `assert_tenant_role` / `assert_platform_role`, or through `my_monvelo_agent_ids()` for agent members.
- Money `numeric(15,2)`, timestamps `timestamptz`, Lagos dates through `public.monvelo_today()` and `at time zone 'Africa/Lagos'`.
- Workflow statuses are `text` + `CHECK`. Monvelo rows are never deleted: reuse the `monvelo_no_delete()` triggers on every new table.
- RLS is `FOR SELECT` only. **Tenants never see or steer lenders (§16.2.2).** No new table or column naming an agent, a pledge or a payer is readable by TENANT_ADMIN, CSM, ZSM, TM, LM or the raiser.
- `payments` is shared (§15.3). Monvelo adds only `monvelo_`-named columns, never the web columns, and grants none of them to `authenticated`.
- Web never touches Monvelo: `042_domain_separation_guard` and `045` stay green and are extended where a task says so.
- Every gateway uses `observe(...)`. Codes are never returned, stored in clear or logged.
- Commits stay on `feat/monvelo-step1`. No merge into `main`, no push, no deploy.

## The green gate (ends every task)

As in the Step 1c/2 plan:

```bash
supabase migration up      # the user runs `supabase db reset` when a full replay is wanted
psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "select count(*) from vault.secrets where name='gateway_secret';"   # 1, else create it
supabase test db                                   # Result: PASS
deno test --allow-all supabase/functions/          # 0 failed
supabase functions serve --env-file supabase/functions/.env   # in the background
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts   # 0 failed
```

"100% coverage" means:
- a pgTAP assertion for every RPC, every policy, every allowed and every refused transition;
- a unit test for every gateway branch;
- the integration run of the whole lifecycle.

There is no line-coverage tool for SQL, so nothing is claimed beyond that list.

## F1, established 2026-10-31

**What Paystack shows:** a transfer charge (`channel` `bank_transfer` or `dedicated_nuban`) carries `authorization.sender_bank`, `authorization.sender_name` and `authorization.sender_bank_account_number`. The account number is **masked** (`XXXXXX0011`), and Paystack warns that the sender name may not match the customer.

**What that means:** the full account number cannot be proven. The strongest binding available is:
- the charge is a transfer;
- its last four digits equal the agent's `settlement_account_last4`;
- its sender name matches `settlement_account_name` (resolved by Paystack at registration).

**Recorded gap:** two accounts with the same holder name and last four digits are indistinguishable.

**Before launch:** confirm on a test key that Verify returns the same `authorization` block as the webhook. If it does not, the gateway reads the webhook body's `authorization` for the payer check only. The amount still comes from Verify.

## Review Focus

1. **The payment lands after its claim lapsed** (the agent paid at minute 14 and the webhook arrived at minute 16). Expected: it still funds if the financing is OFFERED, unclaimed by anyone else, within its supply day, and the pledge still covers it. Otherwise the agent is refunded and a `LATE_PAYMENT` flag is raised. Tested in Task 1.
2. **The same `charge.success` arrives twice, or from both the webhook and the sweep.** Expected: funds once, pledge debited once, one payable. Tested in Task 1 and Task 2.
3. **A repayment greater than what is left once other pending repayments are counted.** Expected: refused. Two pending repayments can never confirm past zero. Tested in Task 4.
4. **The owner confirms a repayment after the due date passed but before the sweep ran.** Expected: the status is decided by `now()` against `due_at` at confirmation. Paid in full after `due_at` with no late charge yet means the charge is applied first, in the same transaction, so the shop still owes it. Tested in Task 4.
5. **A tenant member reads `payments` for a financed order.** Expected: they never see the payer, the agent or the Verify payload. Tested in Task 1 (column grants) and Task 6 (over PostgREST).

---

### Task 1: Funding in the database

**Files:**
- Create: `supabase/migrations/20261031120000_monvelo_funding.sql`, `supabase/tests/database/061_monvelo_funding.test.sql`
- Modify: `001_schema_shape.test.sql` (`tables_are` gains `monvelo_rebate_payables`, `monvelo_rebate_payable_lines`, `monvelo_flags`), `042_domain_separation_guard.test.sql` (the new `payments` column is `monvelo_`-named and ungranted)

**Interfaces:**
- Produces:
  - `payments.monvelo_financing_id uuid null`, a FK `(tenant_id, monvelo_financing_id) → monvelo_financings (tenant_id, id)`, indexed. Not added to the column grant.
  - `monvelo_flags(id, kind, financing_id, agent_id, details jsonb, status, reviewed_by, reviewed_at, created_at)`:
    - `kind` ∈ `PAYER_MISMATCH`, `LATE_PAYMENT`, `AMOUNT_MISMATCH`, `REPAYMENT_REJECTED`, `REPAYMENT_UNCONFIRMED`;
    - `status` ∈ `OPEN`, `REVIEWED`;
    - read by `is_monvelo_staff()` only.
  - `review_monvelo_flag(p_idempotency_key uuid, p_flag_id uuid, p_note text) returns jsonb` (MONVELO_OPERATOR): OPEN → REVIEWED, once.
  - `monvelo_rebate_payables(id, tenant_id, financing_id unique, agent_id, amount, due_at, status, created_at)`, `status` ∈ `DUE`, `CANCELLED` (Step 5 adds `AWAITING_SECOND_APPROVAL`, `PAID`, `OVERDUE` and the payout columns).
  - `monvelo_rebate_payable_lines(payable_id, brand_key, amount)`.
  - Readers of both payable tables: the agent's members and Monvelo staff.
  - `start_monvelo_funding(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid) returns jsonb` (the agent's member). Returns `{payment_id, reference, amount_minor, currency, claim_expires_at}`.
  - `monvelo_payer_matches(p_agent public.monvelo_agents, p_verified jsonb) returns boolean` (internal, immutable).
  - `settle_monvelo_funding(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text) returns jsonb` (service_role only). `outcome` ∈ `funded`, `unchanged`, `not_final`, `unknown_reference`, `mismatch`, `payer_mismatch`, `late_payment`, `failed`.

**Rules:**
- **`start_monvelo_funding`:**
  - refuses unless the financing is CLAIMED by `p_agent_id`, the caller is an ACTIVE member of that agent, and `claim_expires_at > now() + interval '60 seconds'`;
  - inserts one `payments` row:
    - `order_id` = the trade order; `teafair_agent_id` = `raised_by`; `amount` = `principal`; status `INITIATED`;
    - `paystack_reference` = `<financing.reference>-<n>`, where n = 1 + the financing's earlier payments, so it matches `^MV-[A-Z2-7]{8}-[1-9][0-9]*$`;
    - `monvelo_financing_id` set;
  - a replay returns the same row.
- **`settle_monvelo_funding`:**
  - Finds the payment by reference and locks payment, financing, then order. A non-final status follows `settle_paystack_payment`'s age rules.
  - On `success`, the checks run in this order:
    1. **Amount and currency** equal `principal × 100` and the tenant currency. Otherwise: `AMOUNT_MISMATCH` flag, payment `SUCCESS`, financing untouched, `mismatch`.
    2. **The payer:** `monvelo_payer_matches(agent, p_verified)` is true. Otherwise: `PAYER_MISMATCH` flag, payment `SUCCESS`, financing stays CLAIMED, `payer_mismatch`. Staff refund it in Paystack, as D1 does.
    3. **The financing is CLAIMED by this payment's agent,** or it is OFFERED with no open claim, still inside its supply day, and the agent's pledge for the area and date has `remaining ≥ principal`. Otherwise: `LATE_PAYMENT` flag, `late_payment`.
  - **When all three pass, one transaction does all of this:**
    - financing FUNDED, with `funder_agent_id`, `paystack_reference`, `funded_at`;
    - the open claim's outcome is `FUNDED`;
    - every line locks its terms from `monvelo_terms_at(tenant, brand, monvelo_today())`;
    - the pledge's `remaining -= principal`;
    - the trade order goes PENDING → PAID, so the stock sweep no longer cancels it as unpaid;
    - the payable is created: Σ `round(line.amount × rebate_bps / 10000, 2)` per line, `due_at = funded_at + interval '24 hours'`, `DUE`;
    - payment `SUCCESS`, and an audit row with source `WEBHOOK` or `CRON`.
  - `failed`/`abandoned` after 2 h means payment `FAILED`, financing untouched.
  - At most once per `(event, reference)`, through `md5('monvelo:' || p_event || ':' || p_reference)::uuid`.
- **`monvelo_payer_matches`:** true only when all of these hold:
  - `authorization.channel` (or `channel`) ∈ `bank_transfer`, `dedicated_nuban`;
  - the last 4 digits of `authorization.sender_bank_account_number` with non-digits removed = `settlement_account_last4`;
  - `monvelo_name_tokens(sender_name)` ⊆ `monvelo_name_tokens(settlement_account_name)`, or the reverse, with at least 2 tokens on the smaller side. Tokens are upper-case alphabetic words, punctuation removed.

- [ ] **Step 1: Write the failing tests** in `061` (plan ≈ 70):
  - start: refused for a non-member (42501), for another agent's claim, inside the last 60 s, and for an OFFERED financing; references `-1` then `-2` after a lapse and a re-claim; the replay returns the same reference;
  - settle happy path: FUNDED; the claim outcome FUNDED; 1 payable `amount = 4800.00` for one ₦48,000 Purerigin line at 1000 bps; payable `due_at = funded_at + 24 h`; pledge `150000 → 102000`; lines locked (`terms_locked_at` not null, the 5 terms columns set); order PAID; payment SUCCESS;
  - settle twice (webhook then sweep): `unchanged`, one payable, remaining still 102000;
  - amount ₦47,999: `mismatch`, a flag, the financing still CLAIMED;
  - masked account `XXXXXX9999`: `payer_mismatch`, a flag, still CLAIMED; card channel: `payer_mismatch`;
  - names: `"BISI ADE"` vs `"ADE, BISI O."` match; `"BISI"` vs `"BISI ADE"` does not (one token);
  - late payment with the financing OFFERED and no claim: funds; with another agent's open claim: `late_payment` and a flag; after the supply day: `late_payment`;
  - unknown reference: `unknown_reference`;
  - `authenticated` cannot execute `settle_monvelo_funding`;
  - a TM, the raiser and the TENANT_ADMIN read 0 payables, 0 flags, and cannot select `payments.gateway_response_payload` or `payments.monvelo_financing_id` (42501);
  - the agent's member reads its payable;
  - `review_monvelo_flag`: the operator succeeds once, a second time is refused, `MONVELO_FINANCE` is refused.
- [ ] **Step 2: Run** `061`. Expected: FAIL (`function public.start_monvelo_funding(uuid, uuid, uuid) does not exist`).
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `001`, `042`, `061`, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): Monvelo funding: the agent's payment, the payer check, FUNDED and the rebate payable (A6 §4.4, §7.4, F1)`

### Task 2: The `monvelo-fund` gateway and webhook routing

**Files:**
- Create: `supabase/functions/monvelo-fund/{handler.ts,handler.test.ts,index.ts}`
- Modify:
  - `supabase/functions/_shared/payments/paystack.ts`: `InitializeRequest` gains optional `channels?: string[]`, and `callbackUrl` becomes optional (both are sent only when set);
  - `supabase/functions/_shared/payments/settle.ts`: `settleVerified` routes `MV-` references;
  - `paystack.test.ts`, `settle.test.ts`.

**Interfaces:**
- Consumes: Task 1's `start_monvelo_funding` and `settle_monvelo_funding`.
- Produces:
  - `POST /functions/v1/monvelo-fund` with body `{idempotency_key, financing_id, agent_id}`, returning `{reference, authorization_url, access_code}`;
  - `isMonveloReference(ref: string): boolean` in `_shared/payments/settle.ts` (`/^MV-[A-Z2-7]{8}-\d+$/`).

**Rules:**
- **The gateway:**
  1. calls `start_monvelo_funding`;
  2. initialises Paystack with:
     - `amountMinor` from the RPC;
     - `email` = `monvelo-<reference lower-case>@pay.teafairweb.com` (the D1 synthetic-email pattern; no new secret);
     - `channels: ["bank_transfer"]`;
     - `metadata: {kind: "monvelo", financing_id}`;
     - no split and no callback URL (the app reads the financing status);
  3. maps an RPC refusal through the kernel. A Paystack failure is a 502 `PAYSTACK_UNAVAILABLE`.
- **`settleVerified` for an `MV-` reference:**
  - `reversed` throws `"monvelo reversals are applied as refunds"`. Task 5 routes them; until then, test that it throws.
  - Every other status calls `settle_monvelo_funding` with the same values as for web, minus the split.
  - Because `process-payment` and `reconcile-funds` both call `settleVerified`, the webhook and the sweep are covered with no change to either handler.

- [ ] **Step 1: Write the failing tests:**
  - handler: happy path (the initialise call carries `channels: ["bank_transfer"]`, the synthetic email, `metadata.kind = "monvelo"`, and `amountMinor` from the RPC); RPC 42501 → 403; Paystack throws → 502; a bad body → 400;
  - `settle.test.ts`: `MV-ABCDEFGH-1` calls `settle_monvelo_funding` and never `settle_paystack_payment`; a web reference is unchanged; an `MV-` reversal throws;
  - `paystack.test.ts`: `channels` is sent when set; `callback_url` is omitted when unset.
- [ ] **Step 2: Run** `deno test --allow-all supabase/functions/monvelo-fund supabase/functions/_shared/payments`. Expected: FAIL.
- [ ] **Step 3: Write the handler, `index.ts` (live deps, `observe`), and the two shared changes.**
- [ ] **Step 4: Run** the same command, `deno check supabase/functions/monvelo-fund/index.ts`, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(functions): monvelo-fund initialises the agent's transfer; MV- charges settle through Monvelo (A6 §6.3)`

### Task 3: Dispatch and the owner's delivery code

**Files:**
- Create: `supabase/migrations/20261031120100_monvelo_delivery.sql`, `supabase/tests/database/062_monvelo_delivery.test.sql`, `supabase/functions/monvelo-confirm-delivery/{handler.ts,handler.test.ts,index.ts}`
- Modify: `001` (`tables_are` gains `monvelo_owner_challenges`), `049` (allowlist: `dispatch_monvelo_financing` consumes stock citing the order)

**Interfaces:**
- Consumes:
  - Task 1's FUNDED financing with a PAID order;
  - `fulfilment_can_dispatch`, `fulfilment_delivery_path`, `stock_consume_order`, `assert_gateway_proof`;
  - the code draw used in `start_monvelo_consent`.
- Produces:
  - `monvelo_owner_challenges(id, tenant_id, financing_id, repayment_id null, purpose, code_hash, expires_at, attempts, consumed_at, created_by, created_at)`:
    - `purpose` ∈ `DELIVERY`, `REPAYMENT`;
    - no reader (RLS on, no policy), like `monvelo_consent_challenges`.
  - `dispatch_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_tracking_reference text) returns jsonb`. Callers pass `fulfilment_can_dispatch` (the LM, a ZSM, the warehouse manager). FUNDED and order PAID → order IN_TRANSIT, stock consumed. Refused after the funding day.
  - `start_monvelo_delivery(p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid) returns jsonb`. Callers have a non-null `fulfilment_delivery_path`. FUNDED and order IN_TRANSIT. Returns `{challenge_id, expires_at, destination_phone, code?}`, exactly as `start_monvelo_consent`.
  - `confirm_monvelo_delivery(p_idempotency_key uuid, p_challenge_id uuid, p_code text) returns jsonb`. Returns `{confirmed: true, due_at}` or `{confirmed: false, reason: 'INVALID'|'EXPIRED'|'LOCKED'}`.
  - `monvelo_fee_bps_at(p_tenant_id uuid, p_date date) returns integer`: the fee terms valid that day, 0 if none.
  - `POST /functions/v1/monvelo-confirm-delivery` with `{idempotency_key, action: "start", financing_id}` or `{idempotency_key, action: "confirm", challenge_id, code}`.

**Rules:**
- **Codes:** the same TTL (10 min), the same attempt limit and the same 3-per-hour cap as the consent code, keyed on the financing. The code goes to the shop owner's verified profile phone, never the shop's contact number.
- **Confirm, in one transaction:**
  - financing FUNDED → DELIVERED, `delivered_at = now()`;
  - `due_at = ((delivered Lagos date + min(line.interest_free_days) + 1)::timestamp at time zone 'Africa/Lagos')`, which is the end of day 30 for 30 days;
  - `outstanding = principal`;
  - order IN_TRANSIT → DELIVERED;
  - ledger entries for the tenant on the delivery's Lagos date: `FUNDED_GROSS +principal`, and `FEE −round(principal × fee_bps / 10000, 2)` when that is above 0. The gross is booked at delivery, not at funding, because §4.4 defines gross as "principal funded and delivered". A refund before delivery therefore never needs a `REFUND` entry.
- **The gateway:** mirrors `monvelo-shop-consent`: start sends `otpTemplate(code)` WhatsApp-only under a new `notification_logs` purpose `MONVELO_DELIVERY`; confirm maps the reasons to 422 `DELIVERY_CODE_INVALID|EXPIRED|LOCKED`.

- [ ] **Step 1: Write the failing tests:**
  - `062` (plan ≈ 45):
    - dispatch: by the LM succeeds, stock consumed and order IN_TRANSIT; a TM or a DSA is refused (42501); a CLAIMED financing is refused; an agent member is refused;
    - start: without the proof, refused; the right path succeeds; a 4th code in an hour is refused;
    - confirm: a wrong code 5 times → LOCKED; an expired code → EXPIRED;
    - right code: DELIVERED; `due_at` = end of the Lagos day 30 days after delivery; outstanding = principal; order DELIVERED; one `FUNDED_GROSS` 48000.00 and one `FEE` −960.00 at 200 bps, none at 0 bps;
    - the replay does not double the ledger;
    - the TENANT_ADMIN reads both ledger rows; nobody reads `monvelo_owner_challenges`;
  - `handler.test.ts`: start sends one WhatsApp with the code and never returns it; a replay sends nothing; each reason maps to its 422.
- [ ] **Step 2: Run** `062` and the handler test. Expected: FAIL.
- [ ] **Step 3: Write the migration (including the `notification_logs` purpose) and the gateway.**
- [ ] **Step 4: Run** `001`, `049`, `062`, the handler test, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: Monvelo dispatch and the shop owner's delivery code start the clock (A6 §5 step 7)`

### Task 4: Repayments, limit growth and outstanding-based exposure

**Files:**
- Create: `supabase/migrations/20261031120200_monvelo_repayments.sql`, `supabase/tests/database/063_monvelo_repayments.test.sql`, `supabase/functions/monvelo-confirm-repayment/{handler.ts,handler.test.ts,index.ts}`
- Modify: `001` (`tables_are` gains `monvelo_repayments`)

**Interfaces:**
- Consumes: Task 3's DELIVERED financing, `monvelo_owner_challenges` (`purpose = 'REPAYMENT'`), and `raise_system_ticket(p_system_key, p_order_id, p_body, p_priority)`.
- Produces:
  - `monvelo_repayments(id, tenant_id, financing_id, amount, recorded_by, recorded_at, status, challenge_id, confirmed_at, ended_at)`:
    - `status` ∈ `PENDING`, `CONFIRMED`, `REJECTED`, `EXPIRED`;
    - insert-only except the single PENDING → final move;
    - readers: the funder's members, the shop owner (`retail_shops.owner_id`), Monvelo staff. Tenant staff read none (the row names the lender by its recorder).
  - `record_monvelo_repayment(p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid, p_agent_id uuid, p_amount numeric) returns jsonb` (the funder's member):
    - the financing is DELIVERED or DEFAULTED_WITH_LATE_CHARGE, and `p_agent_id = funder_agent_id`;
    - `0 < p_amount ≤ outstanding − Σ PENDING amounts`, with 2 decimals at most;
    - inserts PENDING and draws a REPAYMENT code; returns as `start_monvelo_delivery`.
  - `confirm_monvelo_repayment(p_idempotency_key uuid, p_challenge_id uuid, p_code text) returns jsonb` (the same member). Returns `{confirmed: true, outstanding, status}` or `{confirmed: false, reason}`.
  - `reject_monvelo_repayment(p_idempotency_key uuid, p_repayment_id uuid) returns jsonb` (the shop owner): PENDING → REJECTED, a `REPAYMENT_REJECTED` flag, and `raise_system_ticket('monvelo-repayment:' || id, order_id, …, 'HIGH')`.
  - `monvelo_brand_exposure` is recreated with the same signature. It sums line `amount` for AWAITING_APPROVAL, OFFERED, CLAIMED and FUNDED, and `round(outstanding × line.amount / principal, 2)` for DELIVERED and DEFAULTED_WITH_LATE_CHARGE. This settles plan call 9 of Step 2.
  - `POST /functions/v1/monvelo-confirm-repayment` with `{idempotency_key, action: "record", financing_id, agent_id, amount}` or `{idempotency_key, action: "confirm", challenge_id, code}`.

**Rules:**
- **Confirm, in one transaction:**
  1. if `now() ≥ due_at`, the financing is still DELIVERED, and no late charge has been taken: apply Task 5's `monvelo_apply_late_charge(financing)` first (Review Focus 4);
  2. `outstanding -= amount`, and the repayment becomes CONFIRMED.
- **At `outstanding = 0`:**
  - DELIVERED → REPAID_WITHIN_WINDOW, `closed_at`. Each brand's limit grows to `least(coalesce(max_limit, ∞), round(limit × (10000 + limit_growth_bps) / 10000, 2))`, with a `GROWN` event naming the financing. Nothing happens when `limit_growth_bps = 0` or the limit is already at `max_limit`.
  - DEFAULTED_WITH_LATE_CHARGE → REPAID_LATE, `closed_at`. No growth. Step 2's cure rules already read `REPAID_LATE`.
- **The gateway:** mirrors Task 3, with the purpose `MONVELO_REPAYMENT`, and 422 `REPAYMENT_CODE_INVALID|EXPIRED|LOCKED`.

- [ ] **Step 1: Write the failing tests:**
  - `063` (plan ≈ 55):
    - record: a non-funder member is refused; above outstanding is refused; two PENDING of 30000 + 20000 against 48000 → the second is refused;
    - confirm: the wrong code → INVALID;
    - partial 20000 → outstanding 28000, still DELIVERED; final 28000 → REPAID_WITHIN_WINDOW;
    - growth: limit 50000 at 2000 bps → 60000 and one GROWN event; with `max_limit` 55000 → 55000; at 0 bps → no event;
    - after `due_at`, uncharged, paying the original 48000 → the charge 4800 is applied first, outstanding 4800, DEFAULTED_WITH_LATE_CHARGE; paying 4800 → REPAID_LATE;
    - reject: by the owner → REJECTED, one flag, one SYSTEM ticket; by another user → 42501;
    - readers: the TM reads 0 repayments; the owner reads its own;
    - exposure: a DELIVERED financing with outstanding 28000 counts 28000, not 48000.
  - `handler.test.ts`: as Task 3, plus `amount` validation (positive, 2 decimals) → 400.
- [ ] **Step 2: Run** `063` and the handler test. Expected: FAIL.
- [ ] **Step 3: Write the migration and the gateway.** `monvelo_apply_late_charge` is created here (see Task 5 for its rule) so confirm can call it.
- [ ] **Step 4: Run** `051`–`054`, `063`, the handler test, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: Monvelo repayments confirmed by the shop owner; limits grow on repayment within the window (A6 §5 steps 9–10, §7.2)`

### Task 5: The money sweep and Monvelo refunds

**Files:**
- Create: `supabase/migrations/20261031120300_monvelo_money_sweep.sql`, `supabase/tests/database/064_monvelo_money_sweep.test.sql`
- Modify: `supabase/functions/_shared/payments/settle.ts` (`applyRefunds` and the `reversed` branch route `MV-` references), `settle.test.ts`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `monvelo_apply_late_charge(p_fin public.monvelo_financings) returns public.monvelo_financings` (internal; created in Task 4's migration, specified here):
    - `late_charge_amount = Σ round(outstanding × line.amount / principal × line.late_charge_bps / 10000, 2)`;
    - `outstanding += late_charge_amount`;
    - DELIVERED → DEFAULTED_WITH_LATE_CHARGE;
    - an audit row; applied once ever.
  - `monvelo_sweep_money() returns jsonb` (no grants), scheduled as `monvelo-money-sweep` every 5 minutes. Returns `{refund_due, late_charged, repayments_expired}`.
  - `apply_monvelo_refund(p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb) returns jsonb` (service_role). At most once per refund id. The payment becomes REFUNDED. If the financing is REFUND_DUE and this is its funding payment, `closed_at` is set.

**The sweep, in order:**
1. **Refund due:** FUNDED and `now() ≥ ((funded_at Lagos date + 1)::timestamp at time zone 'Africa/Lagos')` → REFUND_DUE.
   - The order becomes CANCELLED: reserved stock is released (`stock_release_order`); consumed stock comes back through `record_order_return`.
   - The payable goes DUE → CANCELLED.
   - `raise_system_ticket('monvelo-refund:' || id, order_id, 'Refund the funding of <reference> in Paystack.', 'HIGH')`.
2. **Late charge:** DELIVERED with `now() ≥ due_at` and `outstanding > 0` → `monvelo_apply_late_charge`.
3. **Repayments:** PENDING older than 24 h → EXPIRED, a `REPAYMENT_UNCONFIRMED` flag and `raise_system_ticket('monvelo-repayment:' || id, …)`.

Each loop uses `for update skip locked`, as `monvelo_sweep_offers` does.

- [ ] **Step 1: Write the failing tests:**
  - `064` (plan ≈ 40):
    - funded yesterday and undelivered → REFUND_DUE, order CANCELLED, reservations released, payable CANCELLED, one ticket; funded today → untouched;
    - 30 days, ₦48,000 outstanding, 1000 bps → late charge 4800.00 and outstanding 52800.00; with 28000 outstanding → 2800.00; a second sweep adds nothing;
    - two lines (30000 at 1000 bps, 18000 at 500 bps), all outstanding → 3000 + 900 = 3900.00;
    - a pending repayment at 25 h → EXPIRED, a flag and a ticket; at 23 h → untouched;
    - refund: `apply_monvelo_refund` twice with one refund id → applied once; REFUND_DUE gets `closed_at`; a payer-mismatch payment's refund leaves the financing CLAIMED;
    - the job `monvelo-money-sweep` exists with `*/5 * * * *`;
    - `authenticated` cannot execute the sweep or the refund.
  - `settle.test.ts`: an `MV-` refund calls `apply_monvelo_refund`; an `MV-` reversal calls it with `p_reason: "REVERSAL"`; web refunds are unchanged.
- [ ] **Step 2: Run** `064` and `settle.test.ts`. Expected: FAIL.
- [ ] **Step 3: Write the migration and the routing.**
- [ ] **Step 4: Run** `061`–`064`, `058`, the shared tests, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: Monvelo money sweep: refund due, the one late charge, unconfirmed repayments; MV- refunds (A6 §4.4, §5 step 10)`

### Task 6: The Ikeja lifecycle over PostgREST, guards and docs

**Files:**
- Modify: `supabase/functions/_tests/gateway.integration.ts`, `supabase/CLAUDE.md`, `CLAUDE.md`, the A6 spec (a new §19 recording this plan's calls)

- [ ] **Step 1: Write the integration test** `"monvelo step 3: the Ikeja lifecycle, with a payer mismatch, a lapsed claim and a default"`. Paystack and WhatsApp are faked as the existing tests fake them.
  - It continues the Step 2 test's CLAIMED financing:
    1. `monvelo-fund`;
    2. a signed `charge.success` to `process-payment` → FUNDED;
    3. `dispatch_monvelo_financing`;
    4. `monvelo-confirm-delivery` start/confirm → DELIVERED;
    5. a part repayment confirmed;
    6. time is moved by updating `due_at` as postgres, then the sweep runs → DEFAULTED_WITH_LATE_CHARGE;
    7. the rest repaid → REPAID_LATE.
  - A second financing pays from a mismatched account → `payer_mismatch`, still CLAIMED.
  - Readers over PostgREST: the TENANT_ADMIN selects `payments` columns and gets no `gateway_response_payload` (Review Focus 5), and reads the ledger.
- [ ] **Step 2: Run the green gate.** Expected: `Result: PASS` (62 files), 0 failed, and integration 0 failed. Note the counts.
- [ ] **Step 3: Update the docs:**
  - `supabase/CLAUDE.md`: status rows for Step 3 "done (local)"; a section with the tables, the RPCs, the 3 gateways (`monvelo-fund`, `monvelo-confirm-delivery`, `monvelo-confirm-repayment`) and the `MV-` routing in `settle.ts`, `monvelo-money-sweep`, the F1 binding and its gap, and the calls below;
  - `CLAUDE.md`: the counts, and "Step 3 built locally, not pushed";
  - A6 §19: the calls below.
- [ ] **Step 4: Commit.** `docs: Monvelo Step 3`. Do not merge or push.

---

## Calls made in this plan

1. **Funding comes before dispatch, not on dispatch.** The agent pays once the financing is CLAIMED. Stock leaves only for a FUNDED financing, and the owner's code confirms delivery (§4.4, §5 steps 5–7).
   - **Cost if wrong:** none for money. Dispatch-first would mean Teafair ships stock nobody has paid for.
2. **No Paystack subaccount split on funding.** The agent pays Teafair's main account. Subaccounts are the web commission path (§15.5), and web never touches Monvelo.
3. **The rebate is not deducted from repayment.** It is a payable Teafair owes the agent within 24 hours (§4.4). Step 3 creates it; Step 5 pays it.
4. **The payer binding is a transfer charge with matching last four digits and name (F1).** Card and USSD funding are refused by `channels: ["bank_transfer"]` and by the check.
   - **Cost if wrong:** an agent whose bank truncates names is flagged. The operator reviews the flag and the funding is refunded.
5. **A payment that lands after its claim lapsed still funds** when nobody else holds the request and the pledge covers it (Review Focus 1).
   - **Cost if wrong:** a lapsed claimant funds instead of the next agent; one condition to drop.
6. **Funding marks the trade order PAID.** The stock sweep then no longer cancels it, and Spec C sees a paid order.
7. **`due_at` uses the shortest interest-free period across the order's brands,** so the shop has one due date. The late charge is computed per brand.
   - **Cost if wrong:** a mixed order's longer-term brand falls due early. Per-line due dates are a column and a sweep change.
8. **The tenant's gross and fee are booked at delivery.** §4.4 defines gross as "funded and delivered", although §16.5 names the funding webhook as a writer. As a result, refunds before delivery need no `REFUND` entry.
9. **REFUND_DUE cancels the trade order and the payable,** and opens a HIGH system ticket. Staff refund in the Paystack dashboard, as D1 does, and `refund.processed` closes the financing.
10. **The late charge is applied once,** at the sweep or at a confirmation that finds `due_at` passed. The charge goes to the lender as part of `outstanding`.
11. **No callback URL on funding,** to avoid a new secret. The synthetic email follows D1's pattern.
12. **`payments` gains only `monvelo_financing_id`,** ungranted. The agent is never on `payments`; it is reached through the financing and its claims.
