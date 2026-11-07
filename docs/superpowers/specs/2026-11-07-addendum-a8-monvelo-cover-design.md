# Addendum A8 to Spec A: Monvelo cover (goods in transit and shop stock)

**Date:** 2026-11-07
**Status:** draft for the user's review
**Authority:** Spec A still governs and its §9 rules hold without exception.
Addendum A6 (Monvelo) governs everything this addendum does not change. Where
A8 changes A6, it says so.

## 1. Why

A Monvelo financing puts a POS agent's money into a shop's stock for the
brand's interest-free period. Two physical hazards can destroy that money:

- **In transit** (before the shop's delivery code): the stock belongs to the
  tenant. A6 already protects the agent: no delivery within 23 hours means
  `REFUND_DUE`, and the agent is refunded. The tenant loses the stock.
- **In the shop** (after delivery): a fire or burglary wipes the shop out, the
  shop cannot repay, and the agent carries the bad debt.

A8 wraps both in licensed insurance so that losses are recovered:

- the tenant is covered for goods in transit (GIT);
- the funding agent is covered for stock in the shop during the financing.

It also rewards shops that carry their own cover. Their agents earn the full
rebate.

## 2. Decisions (the user's, 2026-11-07)

1. **Agents stay the only lenders.** Monvelo takes no balance-sheet risk and
   there is no credit fund (A6 §2 holds). Insurance protects the agent's capital.
2. **Transit risk is the tenant's.** It runs up to the shop's delivery code. The
   GIT premium (benchmark 0.55%–1.00% of the financed invoice) is billed to the
   tenant and never added to the shop's invoice. **GIT claims pay the tenant.**
3. **The shop pays 0%.** No interest and no storage premium inside the
   interest-free period, insured or not.
4. **Shops with verified cover are exempt.** If a shop holds a verified SME or
   shop bundle covering fire and special perils plus burglary, no storage
   premium is charged.
5. **For other shops, the premium comes out of the agent's rebate.** The
   blended storage premium (benchmark 0.60%–1.40% per 30 days) is deducted from
   the brand rebate before the agent is paid. Example: a 10% rebate and a 1%
   premium leave the agent 9%.
6. **The agent sees the shop's cover status and net yield before funding.**
   "Verified SME (0% storage fee)" → 10.0%. "Uninsured (protected via
   auto-policy)" → 9.0%.
7. **Store claims pay the funding agent as loss payee.** On settlement the
   financing ends in a new status, **`CLOSED_BY_CLAIM`**.
8. **NAICOM.** Monvelo is a technology facilitator integrated by API with
   licensed insurers or brokers (MyCover.ai, Leadway, AXA Mansard and others).
   100% of each premium goes to the licensed insurer. Monvelo receives at most a
   disclosed technology or agency fee.

## 3. Departures from the pasted directive (Claude's, stated to the user)

- **No "Monvelo wallet".** Teafair holds no float (A6 §2). The insurer pays the
  claim straight to the agent's registered settlement account. Monvelo records
  the payout and closes the financing.
- **The rebate is not paid "on settlement".** Under A6 it is paid within 24
  hours of funding, from Teafair's account on the agent's network. For an
  uninsured shop, Teafair now makes two separate, traceable payments at that
  point: the net rebate to the agent and the premium to the insurer. Nothing is
  netted against the funding (the A6 anti-goal still holds).
- **The premium is fixed when the agent claims the financing, not at a
  "checkout".** Monvelo has no checkout. The agent's claim is the moment they
  commit, so the cover and yield they saw are the ones applied.
- **Names follow §15:** `monvelo_shop_policies`, `monvelo_financing_cover`,
  `monvelo_insurance_claims` and so on, not `shop_insurance_profiles`.
- **Statuses are `text` + `CHECK`, not Postgres enums** (Spec A §9). Workflow
  sets change. `UNVERIFIED` is not stored: it is what a shop with no policy row
  reports.
- **No premium "pool".** Every premium is a payable to a named insurer for a
  named financing or order.
- **Benchmark rates are not hard limits.** The ranges in §2 describe the market.
  The rate actually applied is the insurer's approved quote, stored as dated
  product terms, so a quote outside the range does not need a migration.
- **Expiry notices go to people who have an email address.** Shops have only a
  phone number (`retail_shops.contact_phone`). The 15-day notice goes by email
  to the shop's area ZSA and ASA, plus an in-app notification. A WhatsApp notice
  to the shop owner is §11 work.

## 4. Money flows

```
                       TRANSIT (tenant's risk)                SHOP (agent's capital)
 funding ──▶ FUNDED ──dispatch──▶ in transit ──delivery code──▶ DELIVERED ──▶ repaid
                        │                                        │
             GIT declaration                         storage declaration
             (tenant pays the premium)               (exempt, or premium out of rebate)
                        │                                        │
                 GIT claim → tenant               store claim → agent → CLOSED_BY_CLAIM

 At funding (A6 §19 rebate payable, now net for uninsured shops):
   brand rebate R ──▶ agent: R − P      (monvelo_rebate_payables.amount = net)
 At delivery (storage cover starts):
                  ──▶ insurer: P        (monvelo_premium_payables, kind STORAGE)
   The rebate is not in the tenant ledger today, so neither is P: the tenant's
   cost is the same rebate R, split two ways.

 At dispatch:
   tenant ──▶ insurer: G                (monvelo_premium_payables, kind GIT)
   tenant ledger:     GIT_PREMIUM −G    (a new cost the tenant opted into; kept on refund)
```

## 5. Data model

All tables: `tenant_id` where the row belongs to a tenant, `SELECT`-only RLS,
writes through `SECURITY DEFINER` RPCs, `search_path` pinned, no delete
(`monvelo_no_delete`), money `NUMERIC(15,2)`, rates in basis points.

### 5.1 Insurers and product terms (platform-level, no tenant)

`monvelo_insurers`

| column | type | notes |
|---|---|---|
| id | uuid pk | |
| code | text unique | `^[A-Z0-9_]{2,32}$`, e.g. `MYCOVER`, `LEADWAY` |
| legal_name | text not null | |
| naicom_licence_no | text not null | recorded at onboarding; operator-entered |
| api_provider | text not null check in (`MOCK`, `MYCOVER`, `MANUAL`) | which adapter (§8.1) |
| status | text check in (`ACTIVE`, `SUSPENDED`) | |

`monvelo_insurance_products`: dated, two-person approved, locked into each
financing or order (the same pattern as `monvelo_brand_terms`).

| column | type | notes |
|---|---|---|
| id | uuid pk | |
| insurer_id | uuid fk → monvelo_insurers | |
| kind | text check in (`GIT`, `STORAGE`) | |
| rate_bps | integer check (1–1000) | GIT: per shipment. STORAGE: per 30-day block |
| facilitator_fee_bps | integer check (0–10000) | the disclosed share of the premium the insurer pays Monvelo; informational, Monvelo never deducts it |
| valid_from / valid_to | date | `valid_to > valid_from` |
| status | text check in (`PROPOSED`, `APPROVED`, `WITHDRAWN`) | |
| proposed_by / approved_by / approved_at | | approver ≠ proposer; both `MONVELO_OPERATOR` |

Partial unique index: at most one `APPROVED` product per `kind` whose dates
overlap a given day. A guard trigger enforces that (exclusion constraint on
`daterange` with `kind` and status `APPROVED`). One insurer per kind at a time,
so the agent is never shown a premium that depends on a choice they did not make.

### 5.2 A shop's own cover

`monvelo_shop_policies` holds one row per submitted certificate. It is
platform-level because `retail_shops` is the shared registry; a shop's cover is
the shop's, not a tenant's.

| column | type | notes |
|---|---|---|
| id | uuid pk | |
| shop_id | uuid fk → retail_shops | |
| insurer_name | text not null | the shop's insurer (any NAICOM-licensed insurer) |
| policy_number | text not null | unique per `(insurer_name, policy_number)` among non-REJECTED rows |
| covers_fire_perils | boolean not null | |
| covers_burglary | boolean not null | |
| sum_insured | numeric(15,2) not null check > 0 | stock cover |
| lender_interest_endorsed | boolean not null | §5.2.1 |
| starts_on / expires_on | date not null | `expires_on > starts_on` |
| document_path | text not null | private bucket `monvelo-shop-policies` |
| status | text check in (`PENDING`, `VERIFIED`, `REJECTED`, `EXPIRED`, `WITHDRAWN`) | |
| submitted_by | uuid → profiles | the ZSA or ASA |
| owner_challenge_id | uuid → monvelo_owner_challenges | the shop owner's OTP consent to share the certificate |
| reviewed_by / reviewed_at / review_note | | reviewer ≠ submitter; `MONVELO_OPERATOR` |
| expiry_notice_sent_at | timestamptz | set by the expiry job (§7.1) |

Transitions: `PENDING → VERIFIED | REJECTED`, `VERIFIED → EXPIRED | WITHDRAWN`.
A row cannot be edited after review. A changed policy is a new row.

**Who reads a policy.** Monvelo staff, and the ZSA and ASA of every tenant
where the shop is enrolled in their area. No tenant role reads it. A policy
is the shop's, not the tenant's. Audit rows are tenant-null. Any of those
field agents may submit one.

**Verification requires** fire and perils, burglary, `lender_interest_endorsed`,
and a readable certificate. The reviewer checks these by eye against the
document. Verifying through an insurer's API is §11 work.

#### 5.2.1 Why the endorsement matters (Claude's call; flagged for the user)

A shop's own policy pays the **shop**, not the agent. The exemption only
protects the agent if the agent can reach the payout. Verification therefore
requires the policy to carry an interested-party or loss-payee endorsement in
favour of "lenders financing stock through Monvelo". Without that endorsement
the policy is recorded but does not exempt the shop. The insurer and counsel
must confirm that a blanket endorsement like this is obtainable. If it isn't,
the exemption protects the agent less than the auto-policy does.

#### 5.2.2 The derived status

`monvelo_shop_cover_status(p_shop_id uuid, p_through timestamptz, p_principal numeric)`
returns `VERIFIED | PENDING | EXPIRED | REJECTED | UNVERIFIED` plus the
policy id. It is an internal helper, not granted to `authenticated`.

It returns `VERIFIED` only if a `VERIFIED` row:

- covers `[now(), p_through]`;
- has `sum_insured ≥` the shop's open Monvelo principal across all tenants
  plus `p_principal`.

Otherwise it reports the most recent row's status, or `UNVERIFIED` if there
are none. **Only `VERIFIED` exempts.** `PENDING` is treated as uninsured.

### 5.3 Cover locked into a financing

`monvelo_financing_cover` has one row per financing. It is written when the
agent claims the financing and rewritten if the claim lapses and another agent
claims it.

| column | type | notes |
|---|---|---|
| financing_id | uuid pk, fk (tenant_id, financing_id) | |
| tenant_id | uuid | |
| cover_kind | text check in (`SHOP_POLICY`, `AUTO_POLICY`, `NONE`) | `NONE` only when no STORAGE product is approved (§6.4) |
| shop_policy_id | uuid → monvelo_shop_policies | set iff `SHOP_POLICY` |
| product_id | uuid → monvelo_insurance_products | set iff `AUTO_POLICY` |
| storage_rate_bps | integer | 0 unless `AUTO_POLICY` |
| blocks | integer check ≥ 1 | 30-day blocks (§6.1) |
| storage_premium | numeric(15,2) check ≥ 0 | 0 unless `AUTO_POLICY` |
| gross_rebate / net_rebate | numeric(15,2) | `net = gross − storage_premium` |
| declared_status | text check in (`NOT_DUE`, `PENDING`, `ACCEPTED`, `REJECTED`, `CANCELLED`) | the insurer's answer to the storage declaration |
| locked_at | timestamptz | |

`monvelo_financing_line_cover` holds the per-brand split, with primary key
`(financing_id, brand_key)`: `gross_rebate`, `storage_premium` and
`net_rebate`. It feeds `monvelo_rebate_payable_lines`, which stay per brand.

`monvelo_order_git_cover` has one row per financed order at dispatch:
`order_id`, `tenant_id`, `financing_id`, `product_id`, `rate_bps`,
`insured_value`, `premium` and `declared_status`. A tenant with GIT switched
off has no row. The GIT switch is a new column,
`monvelo_tenant_settings.git_cover_enabled boolean not null default false`,
set by the existing `set_monvelo_tenant_settings` (CSM, audited).

### 5.4 Premium payables

`monvelo_premium_payables` is shaped like `monvelo_rebate_payables`:

| column | type | notes |
|---|---|---|
| id | uuid pk | |
| tenant_id | uuid | |
| kind | text check in (`STORAGE`, `GIT`) | |
| financing_id | uuid | |
| insurer_id | uuid | |
| amount | numeric(15,2) check > 0 | |
| due_at | timestamptz | 24 hours after the event that creates it (delivery for STORAGE, dispatch for GIT) |
| status | text check in (`DUE`, `PAID`, `CANCELLED`) | |
| paid_reference | text | Teafair's transfer reference, set by `record_monvelo_premium_paid` |

Unique `(financing_id, kind)`. `monvelo_tenant_ledger_entries.entry_type`
gains `GIT_PREMIUM` only. It is negative and dated on the dispatch day. No
`STORAGE_PREMIUM` ledger type: the rebate is not ledgered today (only
`FUNDED_GROSS` and `FEE` are written, at delivery), and the storage premium is
part of the rebate.

**The STORAGE payable is created at delivery, not at funding.** Cover starts
at delivery, and a `REFUND_DUE` financing (no delivery within 23 hours) never
has one. A refund therefore never has to cancel or recover a storage premium.

`monvelo_rebate_topups` (`id`, `tenant_id`, `financing_id`, `agent_id`,
`amount > 0`, `reason` check in (`DECLARATION_REJECTED`), `status` check in
(`DUE`, `PAID`, `CANCELLED`), `due_at`) records rebate owed to an agent after
the original payable. `monvelo_rebate_payables` stays immutable and single per
financing. A6's rebate payout (its Step 5, not built) pays these with the
payables. Until then they sit `DUE` beside them, and `MONVELO_FINANCE` marks
them paid with `record_monvelo_topup_paid`.

### 5.5 Insurance claims

`monvelo_insurance_claims`:

| column | type | notes |
|---|---|---|
| id | uuid pk | |
| reference | text unique | `^IC-[A-Z2-7]{8}$` (`monvelo_draw_reference`) |
| tenant_id | uuid | |
| kind | text check in (`GIT`, `STORAGE`) | |
| financing_id | uuid | |
| peril | text check in (`FIRE`, `SPECIAL_PERILS`, `BURGLARY`, `THEFT_IN_TRANSIT`, `ACCIDENT_IN_TRANSIT`, `OTHER`) | |
| incident_at | timestamptz | ≤ now() |
| description | text ≤ 2000 | |
| evidence_paths | text[] | private bucket, via an upload function like `contact-report-upload` |
| reported_by | uuid → profiles | |
| payee_kind | text check in (`AGENT`, `TENANT`) | STORAGE → AGENT, GIT → TENANT, enforced by a CHECK |
| payee_agent_id | uuid | set iff `AGENT`; the financing's `funder_agent_id` |
| status | text check in (`REPORTED`, `FILED`, `UNDER_REVIEW`, `SETTLED`, `REJECTED`, `WITHDRAWN`) | |
| insurer_claim_reference | text | |
| claimed_amount | numeric(15,2) | STORAGE: the financing's outstanding principal; GIT: `insured_value` |
| settled_amount | numeric(15,2) | |
| shortfall | numeric(15,2) generated | `greatest(claimed_amount − settled_amount, 0)` when SETTLED |
| payout_reference | text | the insurer's payout reference to the payee |
| settled_at | timestamptz | |

At most one open (`REPORTED`, `FILED` or `UNDER_REVIEW`) claim per
`(financing_id, kind)`.

**Who sees it.** STORAGE claims name a lender, so they are tenant-private
(§16.2.2). Their audit rows are tenant-null, and the tenant role grant excludes
`payee_agent_id`, `payout_reference` and `settled_amount`. GIT claims belong to
the tenant, whose CSM, TENANT_ADMIN and LOGISTICS_MANAGER can read them.

### 5.6 The financing status

`monvelo_financings.status` gains **`CLOSED_BY_CLAIM`**. The transition guard
allows:

- `DELIVERED → CLOSED_BY_CLAIM`;
- `DEFAULTED_WITH_LATE_CHARGE → CLOSED_BY_CLAIM`, for a loss that happened
  before `due_at` but was settled after it.

It is terminal: `outstanding = 0` and `closed_at` is set. It frees the
agent's open exposure (`monvelo_agent_open_exposure`), as `REPAID_*` does, and
counts in the lender reconciliation summary as a new column,
`closed_by_claim_amount`.

The A6 open statuses that keep a financing in exposure do not change.

## 6. The calculations

### 6.1 Formulas

For financing *F* with lines *i* (brand key, line amount *aᵢ*, locked rebate
`rebate_bpsᵢ`):

```
grossᵢ      = round(aᵢ × rebate_bpsᵢ / 10000, 2)             -- unchanged from A6
blocks      = ceil(interest_free_days(F) / 30)                 -- the shortest period across F's brands (A6 decision 7)
premiumᵢ    = 0                                                if cover_kind ∈ {SHOP_POLICY, NONE}
            = round(aᵢ × storage_rate_bps × blocks / 10000, 2) if cover_kind = AUTO_POLICY
netᵢ        = grossᵢ − premiumᵢ                                -- must be ≥ 0 (§6.4)
net_yield_bps(F) = floor(Σ netᵢ × 10000 / principal(F))      -- what the agent is shown

GIT premium G(F) = round(principal(F) × git_rate_bps / 10000, 2)
```

The premium is rounded per line so that the per-brand rebate lines and the
ledger add up to the cent. The shown yield is rounded down, so it never
promises more than is paid.

**Worked example.** Principal ₦200,000, one brand, 10% rebate, 30-day period,
STORAGE rate 100 bps, GIT rate 75 bps:

- uninsured: gross ₦20,000, premium ₦2,000, net ₦18,000, yield 9.00%;
- verified shop: gross ₦20,000, premium 0, net ₦20,000, yield 10.00%;
- the tenant also pays GIT ₦1,500 at dispatch, if switched on.

### 6.2 RPC signatures

```sql
-- Read model for the agent's offer and claim screens. Agent members only
-- (my_monvelo_agent_ids); 42501 otherwise. STABLE, no writes. Shows cover
-- status as a label, never the shop's policy details.
create function public.get_monvelo_offer_cover(p_financing_id uuid)
returns table (
  cover_label      text,          -- 'VERIFIED_SHOP_COVER' | 'AUTO_POLICY' | 'NO_COVER'
  gross_rebate     numeric(15,2),
  storage_premium  numeric(15,2),
  net_rebate       numeric(15,2),
  net_yield_bps    integer,
  quote_valid_until timestamptz   -- the offer's expiry; the claim re-quotes
)
language plpgsql stable security definer set search_path = public, pg_temp;

-- Internal, not granted: computes the quote. Used by the read model above and
-- by claim_monvelo_financing so the two can never differ.
create function public.monvelo_quote_cover(p_financing_id uuid)
returns public.monvelo_financing_cover  -- an unsaved row
language plpgsql stable security definer set search_path = public, pg_temp;
```

`monvelo_quote_cover`:

1. Find `p_through = supply_date + 1 day + 23 h + interest_free_days` (Lagos),
   the latest possible `due_at`.
2. Call `monvelo_shop_cover_status(shop_id, p_through, principal)`.
3. `VERIFIED` → `SHOP_POLICY`. Otherwise, use the STORAGE product approved for
   today: `AUTO_POLICY` if there is one, `NONE` if there isn't.
4. Apply §6.1.

**Changes to existing RPCs:**

- `claim_monvelo_financing` (and the market-maker allow path, A6 §20) takes
  `p_expected_net_yield_bps integer` after the idempotency key. It runs
  `monvelo_quote_cover` under the existing locks. If the quote no longer
  matches what the agent saw, it refuses with
  `P0001 'cover changed; review the new yield'`. The agent re-reads and
  re-claims. On success it writes `monvelo_financing_cover` and the line rows.
  This yield is the agent's acknowledgement, not an input to any amount: the
  amount is always derived (A6 anti-goal).
- **The terms lock moves from funding to claim (changes A6).** Today
  `settle_monvelo_funding` reads `monvelo_terms_at(…, today)` and writes
  `rebate_bps` and `interest_free_days` onto `monvelo_financing_lines`. Under
  A8 the claim locks the brand terms and the STORAGE product into
  `monvelo_financing_cover` and its line rows, and funding copies them onto
  the lines without reading the terms again. The agent is paid exactly what
  they acknowledged, even if a term changes inside the 15-minute claim window.
  A claim that lapses re-quotes on the next claim.
- `settle_monvelo_funding` builds the rebate payable from `net_rebate` per
  line. It writes no ledger entries (unchanged).
- `dispatch_monvelo_financing`: if `git_cover_enabled` and a GIT product is
  approved, it writes `monvelo_order_git_cover`, the GIT premium payable, the
  `GIT_PREMIUM` ledger entry, and a GIT declaration (§7.2).
- `confirm_monvelo_delivery`, for `AUTO_POLICY` financings: inserts the
  STORAGE premium payable, sets `declared_status = PENDING`, and enqueues the
  STORAGE declaration.
- **Refunds** (`REFUND_DUE`, A6 §19) are unchanged. There is no STORAGE
  payable to undo. The GIT payable and ledger line stay, because transit cover
  was bought.

### 6.3 New RPCs (standard write contract: `p_idempotency_key uuid` first, live role check, audit)

| RPC | Caller | Effect |
|---|---|---|
| `start_monvelo_policy_consent(key, shop_id)` → `confirm` through the `monvelo-shop-consent` gateway | the shop's area ZSA or ASA | the OTP goes to the shop's `contact_phone`, as enrolment consent does. `monvelo_owner_challenges.purpose` gains `SHOP_POLICY`; `financing_id` becomes nullable for that purpose only (a CHECK). `tenant_id` is the submitter's tenant, which must have the shop enrolled in the submitter's area |
| `submit_monvelo_shop_policy(key, shop_id, owner_challenge_id, insurer_name, policy_number, covers_fire_perils, covers_burglary, sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path)` | the shop's area ZSA or ASA, with the shop owner's OTP | `PENDING` row |
| `review_monvelo_shop_policy(key, policy_id, decision, note)` | `MONVELO_OPERATOR`, not the submitter | `VERIFIED` or `REJECTED`. Verification refuses if any §5.2 requirement is false |
| `withdraw_monvelo_shop_policy(key, policy_id, reason)` | operator | `WITHDRAWN` (cancelled policy, fraud) |
| `propose_monvelo_insurance_product(key, …)` / `approve_…` / `withdraw_…` | operator, two-person | product terms |
| `report_monvelo_loss(key, financing_id, kind, peril, incident_at, description)` | STORAGE: the area's ZSA or ASA, or an operator. GIT: the tenant's LOGISTICS_MANAGER or CSM, or an operator | `REPORTED` claim. STORAGE: the financing must be `DELIVERED` or `DEFAULTED_WITH_LATE_CHARGE`, and `incident_at` falls after `delivered_at` and before `due_at`. GIT: the financing must be `FUNDED` or `REFUND_DUE`, and the incident falls after dispatch |
| `file_monvelo_insurance_claim(key, claim_id)` | operator | enqueues the CLAIM declaration (§7.2) → `FILED` |
| `record_monvelo_premium_paid(key, payable_id, reference)` | `MONVELO_FINANCE` | `PAID` |
| `record_monvelo_claim_settlement(key, claim_id, settled_amount, payout_reference)` | operator, for `MANUAL` insurers and shop policies | as the webhook (§7.3) |

### 6.4 Edge cases (Claude's calls)

- **The premium exceeds a brand's rebate** (*netᵢ* < 0). The financing cannot
  be claimed while the shop is uninsured. `request_monvelo_financing` refuses
  up front with `'rebate below storage premium for brand %; verify the shop's
  cover'`, so the raiser knows why.
- **No STORAGE product approved.** `cover_kind = NONE`: the full rebate is
  paid, and the agent sees "No cover" and the 10% yield. This keeps Monvelo
  working before an insurer is signed.
- **The shop's policy expires or is withdrawn during a financing.** The
  financing keeps `SHOP_POLICY` (it was checked to cover through the latest
  `due_at`). A withdrawal for fraud raises a `monvelo_flags` row for the
  operator.
- **An open STORAGE claim pauses the late charge.** The money sweep skips a
  `DELIVERED` financing with an open STORAGE claim. If the claim is rejected,
  the next sweep applies the late charge as normal.
- **Short settlement.** On a STORAGE settlement the financing becomes
  `CLOSED_BY_CLAIM` whatever the amount, as the user decided ("extinguishing
  the loan"). Any shortfall is recorded on the claim and raises a flag. The
  agent bears it, and the reconciliation summary shows it.
- **When cover attaches.** Storage cover attaches at the delivery code, under
  the auto-policy's declaration terms, even though the declaration is sent up
  to 24 hours later. A loss in that gap can be reported. It is filed once the
  declaration is accepted (`file_monvelo_insurance_claim` refuses while
  `declared_status = PENDING`). Counsel and the insurer confirm this (§12).
- **The storage declaration is rejected by the insurer.** The agent paid for
  cover that does not exist. The STORAGE payable is `CANCELLED` if unpaid. If
  it was already paid, the operator recovers it from the insurer, outside the
  system, with a flag to track it. A `monvelo_rebate_topups` row returns the
  premium to the agent, `declared_status = REJECTED`, and the agent and
  operator are notified at once. The financing continues **uncovered** and
  ends normally. `report_monvelo_loss` refuses STORAGE claims on it.
- **What a STORAGE claim is for.** `claimed_amount` is the principal still
  unpaid: `principal − repaid`, where repayments go to principal first (A6).
  The late charge is not insured. `CLOSED_BY_CLAIM` waives any late charge and
  sets `outstanding = 0`. The reconciliation summary shows the claim amount
  and the waived charge in separate columns.

## 7. Background jobs and the insurer integration

### 7.1 Policy expiry (pg_cron, daily 06:00 Lagos)

`monvelo_sweep_shop_policies()` (SQL, inside the database):

1. `VERIFIED` and `expires_on < today` → `EXPIRED` (audited, actor null).
2. `VERIFIED` and `expires_on = today + 15` and `expiry_notice_sent_at is
   null` → one `email_outbox` row per ACTIVE ZSA and ASA of the shop's area
   who has an email address, plus a `notifications` row (kind
   `MONVELO_SHOP_COVER_EXPIRING`, payload `{ policy_id, shop_id, expires_on }`).
   Set `expiry_notice_sent_at`.

`email_outbox` changes:

- `template` gains `MONVELO_SHOP_COVER_EXPIRING`;
- `source_table` gains `monvelo_shop_policies`.

The existing `email-outbox-send` sends it and needs one template added. The
email names the shop and the expiry date only: no policy number and no
sum insured.

### 7.2 Declarations outbox

`monvelo_insurance_declarations` is the outbox for every call to an insurer:

| column | notes |
|---|---|
| id, tenant_id | |
| kind | `GIT_DECLARE`, `STORAGE_DECLARE`, `STORAGE_CANCEL`, `CLAIM_FILE` |
| insurer_id | |
| subject_table, subject_id | the cover row or the claim |
| payload | jsonb, built by the database at enqueue time: references, amounts and dates, no shop-owner name or phone |
| status | `PENDING`, `SENDING`, `ACCEPTED`, `REJECTED`, `FAILED` |
| attempts, next_attempt_at, insurer_reference, last_error | the `email_outbox` pattern |

Enqueued by the RPCs in §6.2 and §6.3, inside their own transactions, so a
declaration exists if and only if the event committed.

**`monvelo-insurance-declare`** is a new Edge Function, a system function under
Ruling 46. It is called by pg_cron every minute with the cron secret, and
authenticates that secret before anything else. Each run:

1. `claim_monvelo_declarations(p_limit)` claims a batch (`FOR UPDATE SKIP
   LOCKED`, `PENDING → SENDING`).
2. It calls the insurer's adapter.
3. It reports each result through `complete_monvelo_declaration(id, outcome,
   insurer_reference, error)`.

Retries back off exponentially for 24 hours (the A7 schedule), then the row is
`FAILED`, which raises a flag. A storage declaration still pending after 24
hours also raises a flag: the agent's capital is unprotected while it waits.

### 7.3 Insurer webhook

**`monvelo-insurance-webhook`** is a public function under Ruling 46. It
authenticates the insurer with an HMAC signature checked per adapter, rejects
anything older than 5 minutes, and is idempotent on the insurer's event id
(`monvelo_insurer_events`, unique `(insurer_id, event_id)`). Events:

- `declaration.accepted` / `declaration.rejected` → `complete_monvelo_declaration`;
- `claim.under_review` / `claim.rejected`;
- `claim.settled { claim_ref, settled_amount, payout_reference }` →
  `settle_monvelo_insurance_claim` (service-only), which:
  - STORAGE: sets the claim `SETTLED` and the financing `CLOSED_BY_CLAIM`
    (`outstanding = 0`, `closed_at`); frees exposure; notifies the agent; and
    writes tenant-null audit;
  - GIT: sets the claim `SETTLED`, notifies the CSM and LOGISTICS_MANAGER, and
    adds no financing change.

The payout itself goes from the insurer to the payee, outside Teafair.

### 7.4 Adapters

`_shared/insurance/` holds one interface (`declare`, `cancel`, `fileClaim`,
`verifyWebhook`, `parseEvent`) and three adapters:

- `mock` for local and pgTAP-adjacent tests;
- `manual`: declarations land in an operator queue, and the operator records
  outcomes through RPCs;
- one real provider once a contract is signed.

**No real insurer API is written until a partner is signed and its API
documentation is in hand.** The provider's endpoints are not guessed.

```
 RPC commits ──▶ monvelo_insurance_declarations (PENDING)
                         │  pg_cron 1/min
                         ▼
             monvelo-insurance-declare ──adapter──▶ insurer / broker API
                                                          │
             monvelo-insurance-webhook ◀──HMAC event──────┘
                         │
                         ▼
   complete_monvelo_declaration / settle_monvelo_insurance_claim (DB decides)
```

## 8. API and screens

### 8.1 What the agent sees before funding

Read through `get_monvelo_offer_cover`, alongside the existing offer read
model:

```json
{
  "financing_reference": "MV-K3QZ7PLA",
  "principal": "200000.00",
  "cover": {
    "label": "AUTO_POLICY",
    "display": "Uninsured shop — protected by Monvelo auto-policy",
    "gross_rebate": "20000.00",
    "storage_premium": "2000.00",
    "net_rebate": "18000.00",
    "net_yield_bps": 900
  },
  "quote_valid_until": "2026-11-08T09:15:00+01:00"
}
```

Claiming (through the existing claim path) sends only identifiers and the
acknowledgement:

```json
{ "idempotency_key": "6f1c…", "financing_id": "…", "expected_net_yield_bps": 900 }
```

A changed quote returns `409 { "code": "COVER_CHANGED", "net_yield_bps": 1000 }`.

### 8.2 Screens (described here; built under Spec B, which is on hold)

- **Agent offer card:** a cover badge ("Verified shop cover" in green, "Auto-
  policy" in neutral) and the net yield as the headline number, with a
  breakdown of the rebate minus the premium.
- **ZSA/ASA shop page:** cover status, expiry date, and "Add shop's policy".
  That opens a camera upload of the certificate, the policy fields, and the
  shop owner's OTP, then shows "Pending review". It shows the shop owner what
  the shop is worth to agents: "Verified shops earn their agents the full
  rebate, so they get funded first."
- **Operator review queue:** the certificate image next to the fields, with
  the four §5.2 checks as required ticks.
- **Loss report:** a peril, a time, photos, and a description, then the claim
  timeline.

## 9. Tests (pgTAP, plus Deno tests for the two functions)

- Formulas: the worked example, rounding per line, a multi-brand financing,
  `blocks` for periods of 30, 31 and 60 days, and the shown yield never above
  the paid one.
- Exemption: no row, PENDING, VERIFIED, expired, sum insured too small,
  endorsement missing, and expiry before `p_through`.
- The claim refuses when the yield changed; the allow path (A6 §20) too.
- The claim locks terms: a brand term changed between claim and funding does
  not change the paid rebate.
- Funding writes the net rebate payable. Delivery writes the STORAGE payable.
  Net plus premium equals the A6 gross rebate to the cent.
- A refund leaves no STORAGE payable and keeps the GIT payable and ledger line.
- A rejected declaration produces a top-up and blocks STORAGE claims.
- `CLOSED_BY_CLAIM`: allowed transitions only, exposure freed, the
  reconciliation column, the late charge paused while a claim is open, and the
  short settlement flagged.
- Lender privacy: a tenant cannot read the STORAGE claim's payee; audit is
  tenant-null; an agent sees no policy fields.
- Expiry sweep: EXPIRED on the day after, one notice at 15 days and never twice.
- Webhook: a bad signature, a replay, an old timestamp, and an unknown claim.
- Guards: `service-role-guard` and `secret-scoping` cover the two new
  functions, and the A6 §15 boundary guard covers the new tables (no web
  function reads them).

## 10. Delivery

Branch `feature/addendum-a8-monvelo-cover`, built locally and not pushed (as
A6 and A7).

| Phase | Contents | Done when |
|---|---|---|
| 1. Schema | §5 tables, status and ledger CHECK changes, the bucket, RLS, grants | `db reset` clean; table, RLS and grant tests pass |
| 2. Logic | §6 helpers and RPCs, the changes to claim, funding, dispatch, delivery, refund and sweep, §7.1 | the full pgTAP suite passes, old and new |
| 3. Insurer integration | §7.2–7.4: the outbox, the two functions, the mock and manual adapters, the email template | Deno tests pass; the mock end-to-end (declare → accept → claim → settle → `CLOSED_BY_CLAIM`) passes locally |
| 4. Client | the §8 screens | under Spec B, when the user lifts the hold |

A real insurer adapter is its own task after a partner contract is signed.

## 11. Not in A8

- Verifying policies through an insurer's API, and WhatsApp notices to shop owners.
- Cover for the agent's float, cash in transit, or a shop's stock outside Monvelo.
- Pricing cover by risk (market, density, claims history). One approved rate applies to all.
- Changes to the exposure cap or the allowance because a financing is insured.
- Monvelo collecting or holding any premium or payout.

## 12. Open with counsel and the insurer (not blocking the build)

1. Whether a "technology facilitator" fee on premiums needs a NAICOM agent,
   broker or web-aggregator licence, or must be a flat platform fee.
2. Whether the blanket loss-payee endorsement (§5.2.1) is obtainable.
3. The auto-policy's deductible and sum-insured basis (A8 assumes the
   outstanding principal), and whether a post-loss claim during a late charge is covered.
4. Who holds the auto-policy: the agent as insured, or Teafair as master
   policyholder with the agents as loss payees.

## 13. Calls settled after the builder review (Claude's)

1. The rebate terms and the STORAGE product lock at **claim**, not funding
   (§6.2). This changes A6.
2. There is no storage-premium ledger line. `GIT_PREMIUM` is written on the
   dispatch day and kept on refund (§5.4).
3. The STORAGE payable is created at delivery, so refunds never touch it.
   Rebate top-ups are a separate table, because the A6 rebate payout (Step 5)
   is not built (§5.4).
4. Cover attaches at delivery. A rejected declaration leaves the financing
   uncovered and refunds the premium to the agent (§6.4).
5. The policy OTP reuses `monvelo_owner_challenges` with a new purpose,
   `SHOP_POLICY` (§6.3).
6. A STORAGE claim is for the unpaid principal. `CLOSED_BY_CLAIM` waives the
   late charge (§6.4).

## 14. Left to the builder

Migration split and names, index choices, the exact message wording, the
retry schedule constants, the bucket's size and MIME limits (follow
`contact-report-upload`), and the notification kinds' payload shapes beyond
what §7.1 fixes.
