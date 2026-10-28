# Addendum A6 to Spec A: Monvelo, inventory financing for neighbourhood shops

**Date:** 2026-10-28
**Status:** approved by the user 2026-10-28
**Authority:** Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`) still governs. Its §9 rules hold without exception. Where this addendum changes an earlier decision, it says so.

## 1. Intent

Neighbourhood shops run out of stock because they have no cash, and street
credit is expensive. Nigerian POS agents (OPay, Moniepoint and PalmPay agents)
hold idle float. **Monvelo** connects the two:

- the agent pays for the shop's stock up front;
- the brand pays the agent a rebate as its cost of sale;
- the shop repays the agent within an interest-free period.

Brands move more product, shops stay stocked, and agents earn on idle money.

Monvelo is an **alternate trade-financing flow** that a tenant (brand owner)
may switch on. Every existing payment route stays exactly as built: cash and
bank sales, the fintech-partner web links (A1, D1), and teafairweb retail on
Paystack.

**Monvelo is a platform service, not a tenant feature** (user, 2026-10-28):

- If Monvelo succeeds, it is spun off in partnership with the participating fintechs.
- Tenants opt in and set their brands' terms.
- Tenants never choose the lender. Monvelo matches the funder, and that matching is the service.

## 2. Goals, non-goals, anti-goals

**Goals**
- A ZSA or ASA can raise a credit request for a shop on their beat. A nearby registered fintech agent funds it through Paystack. The shop gets the stock without paying cash.
- The funding agent learns about their rebate the moment the funding is confirmed. Teafair pays the rebate from its own account on the agent's network within 24 hours.
- Liquidity comes from competition: many agents near each shop, notice of supply days in advance, pledges, and a fair allocation rule.
- Each brand's contractual terms (rebate rate, interest-free period, late charge) are approved, dated, and locked into each financing when it is funded.
- A dedicated backend for the Monvelo finance officer's dashboard.
- Clean boundaries, so Monvelo can be lifted out into its own company later.

**Non-goals (this addendum)**
- Client screens (Spec B). This addendum supplies the RPCs, gateways and read models the screens will use.
- Distributors or stockists as a Monvelo party. They stay internally operated (Spec A).
- Credit scoring beyond the rules in §7.2.
- Teafair lending its own money, or holding fintech float.
- Collecting repayments through Teafair or Paystack. The shop repays the agent directly.

**Anti-goals (a failure even if it works)**
- A request or form carrying an amount, a rate or a bank account. Each of these is derived from stored records.
- Netting the rebate off the funding (user, 2026-10-28: netting opens a gap for fraud and muddies anti-money-laundering records). The funding and the rebate are two separate, traceable movements.
- Fintech agents seeing shop owners' personal data beyond what the transaction needs.
- A tenant steering which fintech funds its sales.
- The same request funded twice, or a rebate paid twice.

## 3. Personas and the trade sales team

User decisions 2026-10-28 (with the Director-of-Sales structure the user asked for):

| Code | Who | Reports to | Monvelo |
|---|---|---|---|
| ZSM | Zonal Sales Manager, owns a zone | platform | proposes and approves the tenant's brand terms (two different ZSMs); sees the tenant's Monvelo book |
| TM | Territory Manager, owns a territory | ZSM | approves requests above a shop's limit; handles disputes and day-45 escalations |
| ASM | Area Sales Manager (optional; added once a territory has about 10 ASAs) | TM | supervises ASAs; does not sell |
| **ASA** (new) | Area Sales Agent, street level, owns a beat (about 40–60 shops visited weekly) in one area | ASM, else TM | recruits shops and fintech agents; raises requests |
| **ZSA** (new) | Zonal Sales Agent, street level, roams the whole zone: bigger accounts, new areas, beats with no ASA | ZSM | recruits; raises requests |
| DSM / DSA | Direct sales (web, events, churches, schools, offices) via A1 links | — | **not part of Monvelo** |
| RETAIL_SHOP_OWNER | shop owner ("SHOP_OWNER") | — | confirms delivery and each repayment |
| Monvelo fintech agent (new, platform) | a registered POS agent | — | pledges, claims, funds, records repayments |
| MONVELO_OPERATOR (new platform role) | Monvelo operations | — | approves fintech agents; records Teafair's fee terms; reviews flags |
| MONVELO_FINANCE (new platform role) | Teafair's Monvelo finance officer | — | records rebate payouts; dashboard |

New values: `ZSA` and `ASA` in `tenant_role_enum`;
`MONVELO_OPERATOR` and `MONVELO_FINANCE` in `platform_role_enum`. Persona
codes follow the existing abbreviations. "FSO" is never used.

**Correction to 2026-10-24.** The app-sales channel `FIELD_DSA` and its
wholesale rules assumed DSAs sell to shops. Trade sales belong to ZSAs and
ASAs. Rename `order_channel_enum` value `FIELD_DSA` to `FIELD_SALES`
(`ALTER TYPE … RENAME VALUE`; existing rows follow). The wholesale-price and
whole-pack triggers stay as they are.

**Geography:** add **areas** (zone → territory → area). `areas(tenant_id,
id, territory_id, name, asa_id?)` follows the same composite-FK pattern as
`territories`. A shop belongs to an area through its beat.

## 4. Data model

All new tables follow the `supabase/CLAUDE.md` migration rules:
- RLS enabled, with `FOR SELECT` policies only;
- writes go through SECURITY DEFINER RPCs;
- composite tenant FKs where rows are tenant-scoped;
- every FK and policy column indexed;
- money `NUMERIC(15,2)`, statuses `text` + `CHECK`.

Monvelo's own tables are prefixed `monvelo_`. They link to the rest of
Teafair only by id (shop, tenant, order, product, profile). No non-Monvelo
function writes them, and Monvelo functions write only Monvelo tables plus
the trade order they create (§6.1).

### 4.1 Recruitment data (loaded once by ZSAs and ASAs)

**`monvelo_fintech_agents`** (platform-level; serves every opted-in tenant):
- `id`, `business_name`, `pos_network` (`pos_network_enum`), `network_agent_id` (the network's own agent id);
- `contact_phone`, `location` (geometry point), `address_text`;
- `settlement_account_number`, `settlement_bank_code`, `settlement_account_name` (Paystack account resolution, name-matched to `business_name`);
- `paystack_payer_ref` (whatever Paystack exposes to prove a funding came from this agent's account; see §11 F1);
- `network_kyc_reference` (the network already KYC'd the agent; user decision: Teafair does no duplicate KYC);
- `recruited_by` (ZSA/ASA profile), `status` (`PENDING`, `ACTIVE`, `SUSPENDED`), `approved_by`, `approved_at`;
- `daily_cap`, `per_financing_cap`.

Staff for a fintech agent sign in as profiles linked through
`monvelo_fintech_members(agent_id, profile_id, status)`. That keeps them
out of `tenant_users`.

Changing a settlement account is its own audited RPC. It re-runs Paystack
resolution and needs MONVELO_OPERATOR approval before payouts use the new
account.

**`retail_shops`** (existing shared registry) gains:
- `shop_code` (unique, human-readable);
- `area_id` per tenant, through **`monvelo_shop_enrolments(shop_id, tenant_id, area_id, recruited_by, consent_at, status)`**;
- `photo_slot_id` (the A5 upload-slot mechanism);
- `preferred_agent_id → monvelo_fintech_agents`.

Enrolment records the owner's consent, captured with the owner's OTP, to
share the shop's name, code and location with registered fintech agents
(NDPA 2023; see §10). Each enrolment carries the shop's credit limit for
each brand (`monvelo_shop_limits(shop_id, tenant_id, brand, limit_amount)`,
starting at the brand's opening limit).

**`monvelo_agent_nominations(shop_id, nominated_name, nominated_phone, pos_network, raised_by, status)`**:
a shop owner's request to recruit a POS agent they trust. It is a lead for
the street agent. Once recruited, that agent becomes the shop's
`preferred_agent_id`.

### 4.2 Brand terms (contract terms, per brand)

**`monvelo_tenant_settings(tenant_id, enabled, opening_limit, approval_cap)`**:
the tenant's opt-in.

**`monvelo_brand_terms`**:
- `tenant_id`, `brand` (matched case-insensitively, like brand tiers);
- `rebate_bps`, `interest_free_days` (default 30), `late_charge_bps` (default 1000, i.e. 10%);
- `valid_from`, `valid_to`;
- `proposed_by` (a tenant ZSM), `approved_by` (a second tenant ZSM), `status` (`PROPOSED`, `APPROVED`, `WITHDRAWN`).

The brand's own approval is the gate (user, 2026-10-28: "brands must
approve before we sell"). Monvelo does not countersign.

**`monvelo_tenant_fee_terms(tenant_id, fee_bps, valid_from, valid_to, recorded_by)`**:
Teafair's fees under the distribution contract, recorded by MONVELO_OPERATOR
and readable by the tenant. They are dated and immutable, like brand terms.

Rows are immutable once approved. A new rate is a new row; overlapping
APPROVED rows for one brand are refused. A launch promotion (Purerigin at
10%) is a row with a `valid_to`.

A brand with no APPROVED, currently-valid row cannot be financed.

### 4.3 Supply days and pledges

- **`monvelo_supply_days(tenant_id, area_id, day_of_week)`**: the beat's route day.
- **`monvelo_pledges(agent_id, area_id, supply_date, amount, remaining, created_at)`**: an agent's promise of funds for that area on that date. `remaining` drops as the agent wins requests.

### 4.4 The financing ledger

**`monvelo_financings`**:
- `id`, `reference` (`MV-…`), `tenant_id`, `shop_id`, `order_id` (the trade order, §6.1), `raised_by` (ZSA/ASA);
- `principal` (sum of the order lines at wholesale);
- `status`;
- `funder_agent_id`, `claimed_by_agent_id`, `claim_expires_at`, `preferred_window_ends_at`;
- `paystack_reference`, `funded_at`;
- `delivered_at` (shop-owner OTP), `due_at` (delivery + locked interest-free days);
- `late_charge_amount`, `outstanding`;
- `closed_at`.

**`monvelo_financing_lines(financing_id, brand, amount, rebate_bps, interest_free_days, late_charge_bps)`**:
one row per brand in the order. The terms are copied from the APPROVED
`monvelo_brand_terms` row at funding time, and never change after.

**Status machine** (`text` + `CHECK`):

```
REQUESTED ──(within limit)──────────▶ OFFERED
REQUESTED ──(above limit)─▶ AWAITING_APPROVAL ──TM approves──▶ OFFERED
OFFERED ──agent claims──▶ CLAIMED ──Paystack verified──▶ FUNDED
CLAIMED ──15 min, no payment──▶ OFFERED (next agent)
OFFERED ──no claim by end of supply day──▶ EXPIRED
FUNDED ──shop-owner OTP──▶ DELIVERED ──repaid in full by due_at──▶ REPAID_WITHIN_WINDOW
DELIVERED ──due_at passes with outstanding > 0──▶ DEFAULTED_WITH_LATE_CHARGE ──repaid in full──▶ REPAID_LATE
REQUESTED / AWAITING_APPROVAL / OFFERED ──raiser or TM cancels──▶ CANCELLED
```

Supply is same day (user, 2026-10-28). A financing FUNDED but not
DELIVERED by 23:59 Africa/Lagos on its funding day becomes `REFUND_DUE`
(the cron sweep), as does stock refused or lost.
Teafair refunds the agent through Paystack (D1's refund path) and no rebate
is owed. If the rebate was already paid, it is offset against the agent's
next rebate, never clawed back by hand.

**`monvelo_repayments(financing_id, amount, recorded_by_agent_member, recorded_at, shop_confirmed_at, otp_challenge_id, status)`**:
each part payment. The agent records it, and the shop owner confirms it
with a code (Spec A's dual validation). A recorded payment that is not
confirmed within 24 hours, or that the owner rejects, opens a dispute ticket
for the TM (A3 system tickets).

**`monvelo_rebate_payables`**, created in the same transaction that marks
the financing FUNDED:
- `financing_id` (unique: one per financing), `agent_id`, `amount` (Σ line amount × rebate_bps), and the per-brand split in `monvelo_rebate_payable_lines`;
- `payout_account_id` (Teafair's account on the agent's network);
- `due_at` (= funded_at + 24 h);
- `status` (`DUE`, `AWAITING_SECOND_APPROVAL`, `PAID`, `OVERDUE`);
- `paid_reference` (bank or network transfer reference), `paid_by`, `second_approved_by`, `paid_at`.

**`monvelo_payout_accounts(id, pos_network, account_number, account_name, status)`**:
Teafair's own account on each network (user, 2026-10-28: "Teafair shall
open accounts with all participating fintechs; rebates are paid from
these"). Changes go through a migration, or a MONVELO_OPERATOR RPC with
audit.

**`monvelo_tenant_settlements(tenant_id, business_date, gross, rebates, fees, net, remitted_reference?, remitted_at?)`**:
the tenant is Teafair's client (user, 2026-10-28). Teafair collects the
funding, deducts every Teafair fee and the rebates it paid on the tenant's
brands, and owes the tenant the rest. For each day, from the tenant's lines
only:
- `gross` = principal funded and delivered;
- `rebates` = rebates paid;
- `fees` = gross × the fee terms valid that day;
- `net` = gross − rebates − fees.

The transfer to the tenant happens outside the app (the user: "this may not
be an issue for the app"). MONVELO_FINANCE may note its reference. TEAFAIR's
own brands get a row too, as internal accounting.

**`monvelo_flags(kind, subject, details, status, reviewed_by)`**: pattern
flags for the operator (§7.4).

## 5. The lifecycle (the Ikeja example)

A shop on the Allen Avenue beat in Ikeja wants a ₦48,000 carton of Purerigin
200 ml (12 × ₦4,000 wholesale). Purerigin's approved terms are 10%, 30
days and 10%.

1. **The evening before Thursday's supply day,** Monvelo sends the agents
   near that beat's shops a WhatsApp message with totals only: "Thursday:
   12 shops on Allen Ave, expected demand about ₦480,000." The figure comes
   from the beat's recent financed volume.
2. **Agent Bisi** (OPay, 400 m away, the shop's preferred agent) pledges ₦150,000 for Thursday.
3. **Thursday 10:02.** ASA Kunle raises the request: the shop code, plus the
   order lines in whole packs at wholesale. The database derives everything
   else: the ₦48,000 principal and the shop's limit check (within limit, so
   OFFERED).
4. **The preferred window (10 min):** Bisi has a pledge, so she gets first
   claim. She claims at 10:05, and the request is CLAIMED, expiring at 10:20.
5. **Bisi pays ₦48,000 through Paystack** (§6.3) from her registered
   account. The webhook verifies it server-side. In one transaction:
   - the financing becomes FUNDED;
   - the line terms lock;
   - the pledge's remaining drops to ₦102,000;
   - a rebate payable is created: ₦4,800, due by 10:14 Friday, from Teafair OPay.
6. **Straight away,** Bisi gets WhatsApp: "Monvelo MV-…: ₦4,800 rebate
   confirmed, paid from Teafair OPay to your account ending 4821 by 10:14
   tomorrow."
7. **The stock reaches the shop the same day.** The shop owner confirms
   receipt with the shop-owner OTP, so the financing is DELIVERED and due 30
   days after delivery. Not delivered by 23:59 means REFUND_DUE.
8. **Before Friday 10:14,** the finance officer pays ₦4,800 from Teafair's
   OPay account and records the transfer reference. Bisi gets "Paid, ref …".
   ₦4,800 goes into TEAFAIR's settlement for the day as rebates (Purerigin is Teafair's own brand).
9. **Over the next weeks,** the shop repays Bisi at her terminal in part payments. Each one is recorded by Bisi and confirmed by the owner.
10. **On full repayment by the due date,** the financing is
    REPAID_WITHIN_WINDOW and the shop's Purerigin limit grows (§7.2). If it
    isn't repaid in full by day 30 after delivery:
    - from day 31, a 10% late charge is added once, on the outstanding amount;
    - the status becomes DEFAULTED_WITH_LATE_CHARGE;
    - the shop can't get new Purerigin credit;
    - on day 45 the case escalates to the TM.

## 6. Interfaces

### 6.1 Trade orders

Spec C's field-sales RPCs are not built, so this addendum adds the one it
needs: **`place_trade_order(p_idempotency_key, p_shop_id, p_lines)`**,
callable by ZSA and ASA (and TM). It creates a `FIELD_SALES` order:
- lines at `wholesale_price`, in whole packs (the existing triggers enforce both);
- the warehouse is the shop's territory's REGIONAL warehouse, as in D1 routing;
- `teafair_agent_id` is the raiser (Spec A rule).

When Spec C lands, it extends this RPC rather than replacing it.

### 6.2 RPCs (callers' JWTs; the tenant is never a parameter)

| RPC | Caller | Notes |
|---|---|---|
| `enrol_monvelo_shop` | ZSA, ASA | owner consent OTP; sets area, photo slot, code |
| `register_monvelo_agent` | ZSA, ASA | status PENDING; Paystack account resolution happens in the gateway |
| `approve_monvelo_agent`, `suspend_monvelo_agent`, `change_agent_settlement_account` | MONVELO_OPERATOR | audited |
| `nominate_monvelo_agent` | shop owner, or ZSA/ASA on their behalf | a lead |
| `propose_monvelo_brand_terms` | tenant ZSM | |
| `approve_monvelo_brand_terms` / `withdraw_…` | a different tenant ZSM | the brand's approval is the gate |
| `record_monvelo_fee_terms` | MONVELO_OPERATOR | Teafair's contract fees per tenant |
| `record_tenant_remittance(p_idempotency_key, p_settlement_id, p_reference)` | MONVELO_FINANCE | optional: notes the off-app transfer to the tenant |
| `set_monvelo_supply_day` | TM | |
| `pledge_monvelo_funds` | fintech member | |
| `request_monvelo_financing(p_idempotency_key, p_order_id)` | the order's raiser | principal derived; limit check |
| `approve_monvelo_financing` | TM of the shop's territory | above limit only |
| `claim_monvelo_financing` | fintech member | allocation rule §7.1; row lock |
| `confirm_monvelo_delivery` | via gateway (OTP) | starts the clock |
| `record_monvelo_repayment` | the funder's member | amount ≤ outstanding |
| `confirm_monvelo_repayment` | via gateway (owner OTP) | |
| `record_rebate_payout(p_idempotency_key, p_payable_id, p_reference)` | MONVELO_FINANCE | exact amount, from the payable's account; above `approval_cap` → AWAITING_SECOND_APPROVAL |
| `approve_rebate_payout` | MONVELO_FINANCE, not the recorder | |
| `review_monvelo_flag` | MONVELO_OPERATOR | |

`settle_monvelo_funding(p_reference, p_verified jsonb)` is service-role only,
called by the webhook gateway (D1 pattern). It is what moves a financing to
FUNDED and creates the payable.

### 6.3 Gateways (Edge Functions)

- **`monvelo-fund`** (user gateway; fintech member). Initialises a Paystack transaction for the CLAIMED financing:
  - amount = principal;
  - reference `MV-<financing>-<n>`;
  - metadata `{kind: "monvelo"}`;
  - it refuses if the claim has expired.
- **`process-payment`** (existing). A `charge.success` whose reference starts
  `MV-` is routed to Monvelo:
  - **Verify** server-side;
  - check the payer against the agent's `paystack_payer_ref` (§11 F1);
  - call `settle_monvelo_funding`;
  - send the rebate-confirmed WhatsApp.

  A payer mismatch leaves the financing CLAIMED, raises a flag, and refunds through D1's refund path.
- **`monvelo-confirm-delivery`, `monvelo-confirm-repayment`**: issue and verify the shop-owner OTP. The code is drawn by the database with the gateway proof (auth audit H2 pattern).
- **`monvelo-agent-register`**: Paystack account resolution (name match), then `register_monvelo_agent`.

All gateways use `observe(...)` (Sentry) and the A5 message router.

### 6.4 Notifications (WhatsApp, A5 router; new Meta utility templates)

| Template | To | When |
|---|---|---|
| `monvelo_supply_day` | agents near the beat | 18:00 the evening before a supply day (totals only) |
| `monvelo_offer` | the preferred agent, then pledged agents | on OFFERED (shop name and code, area, amount; no owner data) |
| `monvelo_rebate_confirmed` | funder | in the webhook transaction's aftermath, immediately |
| `monvelo_rebate_paid` | funder | on PAID |
| `monvelo_daily_summary` | each active agent | 19:00 daily: funded, rebates pending and paid, repayments, shops due within 7 days |
| `monvelo_weekly_statement` | each active agent | Monday 08:00 |
| `monvelo_repayment_reminder` | shop owner | day 25 and day 30 after delivery |
| `monvelo_late_charge` | shop owner and funder | day 31 |
| `monvelo_tenant_daily` | each tenant's ZSMs | 19:30 daily: the tenant's own brands only: funded and delivered, value financed, rebates paid, fees, net owed, repayments, overdue shops |
| `monvelo_tenant_weekly` | each tenant's ZSMs | Monday 08:30: the week's totals and trends, and the settlements |

Each send is logged in `notification_logs` under new purposes, with the
last four phone digits only. Agent statements and tenant reports are also
stored (`monvelo_agent_statements`, `monvelo_tenant_reports`) so the app can
show them. Tenant reports follow the mixed-order rule in §8: other tenants'
lines never appear.

Scheduled work (pg_cron, Africa/Lagos dates):
- supply-day announcements;
- a claim-window sweep every minute (moves expired CLAIMED and preferred windows on);
- the daily summary and the weekly statement;
- reminders;
- the day-31 late charge;
- day-45 escalation;
- payables passing 24 h → OVERDUE, with a ZSM and finance alert.

## 7. Rules

### 7.1 Allocation (user-confirmed 2026-10-28)

1. On OFFERED, if the shop has a `preferred_agent_id` with a pledge of at
   least the principal remaining for that area and date, only that agent may
   claim for **10 minutes**.
2. After that, any ACTIVE agent within the shop's radius (default 1 km; a
   setting) holding such a pledge may claim. **First claim wins.**
3. A claim lasts **15 minutes**. If no verified payment arrives, the claim
   lapses and the request returns to OFFERED (step 2). The lapsed agent may
   not reclaim that financing.
4. One claim at a time, enforced by a row lock in `claim_monvelo_financing`.
   A request can never be funded twice; a second `charge.success` on a
   settled financing is refunded.
5. A claim also checks the agent's `daily_cap` and `per_financing_cap`.

### 7.2 Eligibility and limits (Claude's call; settings)

- **Who can get credit:** a shop that is enrolled, has a verified owner phone
  and a GPS pin, and has at least 3 cash orders in 6 weeks for that brand.
- **Opening limit:** the tenant's `opening_limit` per brand.
- **Repaid within the window:** the limit rises by 25% (capped by the tenant).
- **Default:** the limit freezes until the financing is cleared, then drops back to the opening limit.
- **Above the limit:** the TM approves.

### 7.3 Field incentives (Claude's call)

- A ZSA or ASA earns commission on a Monvelo sale only once it is REPAID_WITHIN_WINDOW or REPAID_LATE.
- An agent whose overdue share (PAR30: overdue outstanding ÷ outstanding, on financings they raised) passes 10% cannot raise new requests until it drops.

### 7.4 Controls (user and Claude, 2026-10-28)

- **Nothing typed at the transaction:** no amount, rate or account. All are derived.
- **Funding comes from the agent's own account (§11 F1).** Anything else is refused and flagged.
- **One payable per financing,** paid only from the matching network's
  Teafair account to the agent's verified settlement account, for the exact
  amount. Above the cap, a second MONVELO_FINANCE person approves.
- **Pattern flags** go to the operator; nothing is blocked silently. Examples:
  - a shop financed and repaid within hours, repeatedly;
  - one agent winning more than 80% of a shop's financings while that shop defaults;
  - an agent funding far above their 30-day average;
  - a repayment the owner rejects.
- **Records:** Monvelo rows are never deleted. They are kept at least 5 years (Money Laundering (Prevention and Prohibition) Act 2022).

## 8. Access (RLS, SELECT only)

| Who | Sees |
|---|---|
| Shop owner | their shop's financings, lines, repayments, limits and nominations |
| Fintech member | their agent's pledges, claims, funded financings, repayments, payables and statements; open offers available to them (shop name and code, area, amount, distance; never the owner's name or phone) |
| ZSA / ASA | financings they raised; enrolments and shops on their beat |
| TM / ASM | their territory's financings for their tenant |
| ZSM | the tenant's Monvelo book: financings with lines of its brands, its brand terms, its fee terms, its settlements and reports |
| MONVELO_OPERATOR | all Monvelo tables |
| MONVELO_FINANCE | payables, payout accounts, tenant settlements, financings (read) |

**Tenant isolation:** a tenant sees only financings whose lines carry its brands, never another tenant's lines in a mixed order.

Helpers follow the `my_*_ids()` pattern. Policies use `(select auth.uid())`
and never a per-row correlated subquery.

## 9. The Monvelo finance dashboard (backend)

Read RPCs for MONVELO_FINANCE (the screens come with Spec B):

- `monvelo_finance_overview(p_from, p_to)`:
  - payables due within 24 h, overdue and paid;
  - totals per payout account (owed, paid, for reconciliation against each network statement);
  - funding received through Paystack versus principal financed;
  - refunds due.
- `monvelo_payables(p_status, p_network, p_limit, p_after)`: the work queue, oldest due first.
- `monvelo_tenant_settlement_statement(p_from, p_to)`: per tenant, gross, rebates, fees, net owed, and remitted or not.
- `monvelo_exceptions()`: payer mismatches, refunds due, open flags, notification failures, payouts awaiting second approval.
- Actions: `record_rebate_payout`, `approve_rebate_payout`.

These are SECURITY DEFINER functions granted to `authenticated`, which check the platform role live.

## 10. Legal and regulatory (must be cleared before launch; not decided by the system)

- **Lender of record:** set by the Monvelo partnership contract. Counsel confirms whether that is the network (OPay, Moniepoint, PalmPay) or the individual agent, and what licence applies (state moneylender laws; FCCPC's 2025 digital lending regulations if they apply). Until then the system only records who funded each financing.
- **The late charge:** counsel confirms the wording (late fee or interest) and the 10% default.
- **Data sharing with agents (NDPA 2023):** the shop owner's consent is captured at enrolment; offers carry the minimum data.
- **Teafair's own anti-money-laundering duties** as payer of rebates: counsel confirms them.
- **Meta approval** of the eight templates.

## 11. Facts the builder must establish first

- **F1:** what a Paystack `charge.success` / Verify response exposes about the payer for the channels an agent will use (bank transfer, Pay with Transfer, card). Can it prove the money came from the agent's registered account? If not, choose the strongest available binding and record the gap; for example, a per-agent Paystack customer plus a dedicated virtual account.
- **F2:** each network's transfer reference format, for validating `p_reference` on payouts.
- **F3:** whether `ALTER TYPE … RENAME VALUE` on `FIELD_DSA` is safe on the remote (no client code exists yet; check functions and RPCs for the literal).

## 12. Delivery and deploy

This addendum deploys after the auth hardening (local main `db13f55`).

**Suggested build order:**
1. Roles, area and the channel rename.
2. Recruitment and brand terms.
3. Trade order and financing ledger with allocation.
4. Funding through Paystack.
5. Delivery and repayment OTPs.
6. Payables and payouts.
7. Notifications and cron.
8. The finance dashboard.

**Tests:** pgTAP for every RPC, policy and state transition; unit tests per gateway; an integration run of the whole Ikeja lifecycle against the fakes, including a lapsed claim, a payer mismatch and a default.

**New secrets:** none beyond existing Paystack and WhatsApp, plus the template names.

## 13. Decisions log

**User (2026-10-28):**
- Monvelo is an optional alternate flow; existing routes stay.
- It is a platform service with a future spin-off; tenants never choose the lender.
- ZSA and ASA are street level (zone versus area); DSA and DSM are the web/events channel.
- The fintech funds the full principal through Paystack; no netting.
- Teafair pays rebates within 24 h from its own accounts on each network.
- The agent is told of the rebate immediately.
- Teafair sends agents periodic sales updates.
- Rebates, the interest-free period and the late charge are per-brand contract terms; the field picks the brand and the approved rate fills in.
- Agents are already KYC'd by their networks; Teafair does no duplicate KYC.
- Recruiting shops and agents is the street team's job.
- Competition: many agents per shop, supply-day notices, pledges, shop nominations.
- Allocation: preferred agent first for 10 min, then first pledged claim, 15 min to pay.
- A dedicated finance dashboard.
- Supply is same day.
- Brands approve their terms before any sale.
- The tenant is Teafair's client: fees and rebates are deducted before remitting.
- Daily and weekly reports go to each tenant.

**Claude's calls (open to change):**
- the ASM is optional above about 10 ASAs; the ZSA reports to the ZSM;
- new platform roles MONVELO_OPERATOR and MONVELO_FINANCE;
- fintech members outside `tenant_users`;
- the 1 km radius;
- the eligibility and limit rules;
- the incentives and PAR30 rule;
- repayment by dual confirmation;
- the day-25/30 reminders and day-45 escalation;
- the second approval above a cap;
- REFUND_DUE with offset;
- `place_trade_order` in this addendum;
- the `FIELD_SALES` rename;
- the `monvelo_` prefix for extraction;
- tenant reports on WhatsApp to the ZSMs (email later);
- the 23:59 same-day refund cut-off;
- the fee as basis points on gross.

## 14. Questions answered (2026-10-28)

- **Q1, stock:** supply is same day. The clock starts at the owner's delivery confirmation; not delivered by 23:59 Lagos time means REFUND_DUE.
- **Q2, terms:** brands must approve before any sale. The brand's approval is the gate, with no Monvelo countersignature.
- **The tenant is Teafair's client:** Teafair deducts all its fees and the rebates paid before remitting to the tenant. Daily and weekly reports go to each tenant.

## 15. Amendment 2026-10-28: Monvelo replaces fintech partners

**Status:** user decisions 2026-10-28; Claude's calls below are open to change.
**Amends:** §1 (the fintech-partner web links no longer "stay exactly as
built"), §4 (the boundary rule), §4.1 (the agent registry gains a Paystack
subaccount, terminals and tenant links), and Spec A §6.7, A1 §4 and D1 where
they name `fintech_partners`, `fintech_terminals`, `fintech_advances` or the
`FINTECH_AGENT` role. Spec A §9 still holds without exception.
**Plan:** `docs/superpowers/plans/2026-10-28-monvelo-step1b-fintech-replacement.md`.

### 15.1 Decisions (user, 2026-10-28; binding)

1. Every legacy fintech-partner concept is replaced by the Monvelo registry
   (`monvelo_fintech_agents`, `monvelo_fintech_members`). The legacy partner,
   terminal and advance tables are dropped.
2. There is no production data anywhere. The remote holds the old tables
   (and none of D1–A6), but no rows to migrate. Nothing is copied.
3. `fintech_advances` is dropped entirely. Monvelo financing (§4.4) replaces it.
4. The flat ₦500 web POS bounty (`tenant_settings.web_agent_bounty`) is removed.
   - Web sales pay a **percentage** commission, and **only** on direct
     referral-link orders, that is, orders that carry an agent code.
   - A codeless web order pays agents 0%, wherever it is routed or fulfilled.
   - The interim rate is **0%** for every tenant until the user agrees a figure.
5. Nothing is pushed or deployed. Monvelo tables keep the `monvelo_` prefix. No Prisma.

### 15.2 The model after the change

- **One registry.** `monvelo_fintech_agents` stays the single, platform-level
  registry of POS agents. A MONVELO_OPERATOR approves and suspends an agent
  there (Step 1), and now also sets its **Paystack subaccount**.
- **Tenant links.** `monvelo_agent_tenants(tenant_id, agent_id, territory_id,
  status, linked_by, …)`, primary key `(tenant_id, agent_id)`, takes the
  tenant-scoped role `fintech_partners` had. Every tenant-scoped row that names
  an agent (payments, commission records, agent codes, orders) references
  `(tenant_id, agent_id)` on this table by composite FK. A row can therefore
  never name an agent that is not linked to its own tenant, so the
  composite-FK discipline of `supabase/CLAUDE.md` survives.
- **Terminals.** `monvelo_agent_terminals` replaces `fintech_terminals`. It is
  platform-level: one physical terminal serves every tenant the agent is
  linked to. It carries the network terminal id, the A1 venue fields, an
  active flag and the operating member's profile. Tenant-scoped rows reference
  it as `(agent_id, terminal_id)`, so a terminal always belongs to the agent
  the same row names.
- **POS staff** are `monvelo_fintech_members`, never `tenant_users`.

### 15.3 Mapping (old → new)

**Tables and columns**

| Old | New | Note |
|---|---|---|
| `fintech_partners` | **dropped** | identity → `monvelo_fintech_agents`; tenant scope → `monvelo_agent_tenants` |
| `fintech_partners.business_name`, `pos_network`, `contact_phone` | the same columns on `monvelo_fintech_agents` | already built (Step 1) |
| `fintech_partners.status`, `approved_by`, `approved_at` | `monvelo_fintech_agents` (platform approval) + `monvelo_agent_tenants.status` (per tenant) | |
| `fintech_partners.territory_id` | `monvelo_agent_tenants.territory_id` (NOT NULL) | §15.4 call D |
| `fintech_partners.paystack_subaccount_code` | `monvelo_fintech_agents.paystack_subaccount_code` (nullable, `^ACCT_…`, no column grant) + generated `has_paystack_subaccount` (granted) | call B |
| `fintech_partners.commission_bps` | `tenant_settings.web_agent_commission_bps` (integer, NOT NULL, default 0, 0–10000) | call C |
| `fintech_terminals` | `monvelo_agent_terminals` | platform-level |
| `fintech_terminals.partner_id` | `monvelo_agent_terminals.agent_id` | |
| `fintech_terminals.agent_id` (a FINTECH_AGENT profile) | `monvelo_agent_terminals.operator_profile_id` | FK `(agent_id, operator_profile_id)` → `monvelo_fintech_members` |
| `fintech_terminals.terminal_id` | `monvelo_agent_terminals.network_terminal_id` | unique per agent |
| `fintech_terminals.territory_id` | moved to the link | |
| `fintech_terminals.tenant_id` | none | platform-level |
| `fintech_terminals` venue fields (A1) | the same names on `monvelo_agent_terminals` | `venue_channel`, `venue_name`, `address_text`, `state`, `lga`, `location`, `operating_hours` |
| `fintech_advances` | **dropped** | decision 3 |
| `payments.fintech_partner_id` | `payments.monvelo_agent_id` (renamed) | the column grant follows the rename |
| `payments.fintech_terminal_id` | `payments.monvelo_terminal_id` (renamed) | |
| `payments.split_subaccount_code`, `split_bps`, `split_amount` | unchanged | now filled from the tenant rate |
| `commission_records.fintech_partner_id` | `commission_records.monvelo_agent_id` (renamed, NOT NULL) | |
| `commission_records.bps_applied`, `paystack_subaccount_code` | unchanged | copied from the payment's snapshot, as in D1 |
| `agent_codes.agent_id` | unchanged meaning, now **nullable**: the tenant staff member (DSA, DSM, …) who holds a staff link | call E |
| — | `agent_codes.monvelo_agent_id` (new) | the Monvelo agent that holds a POS link |
| `agent_codes.terminal_id` | unchanged name, now → `monvelo_agent_terminals` | |
| `orders.attributed_agent_id` | unchanged meaning: staff-link orders only | |
| — | `orders.attributed_monvelo_agent_id` (new) | POS-link orders |
| `orders.attributed_terminal_id` | unchanged name, now → `monvelo_agent_terminals` | |
| `orders.agent_id` | unchanged | the field agent of a field order (Spec A); web orders never set it |
| `tenant_settings.web_agent_bounty` | **dropped** | decision 4 |
| `tenant_users.role = 'FINTECH_AGENT'` | the enum label stays; a CHECK forbids it | call E |

**Foreign keys**

| Old | New |
|---|---|
| `payments (tenant_id, fintech_partner_id) → fintech_partners` | `payments (tenant_id, monvelo_agent_id) → monvelo_agent_tenants (tenant_id, agent_id)` |
| `payments (tenant_id, fintech_terminal_id) → fintech_terminals` | `payments (monvelo_agent_id, monvelo_terminal_id) → monvelo_agent_terminals (agent_id, id)`, plus CHECK: a terminal needs an agent |
| `fintech_terminals (tenant_id, partner_id) → fintech_partners` | `monvelo_agent_terminals.agent_id → monvelo_fintech_agents` |
| `commission_records (tenant_id, fintech_partner_id) → fintech_partners` | `commission_records (tenant_id, monvelo_agent_id) → monvelo_agent_tenants` |
| `fintech_advances (tenant_id, partner_id) → fintech_partners` | dropped with the table |
| `agent_codes (tenant_id, terminal_id) → fintech_terminals` | `agent_codes (tenant_id, monvelo_agent_id) → monvelo_agent_tenants` and `agent_codes (monvelo_agent_id, terminal_id) → monvelo_agent_terminals (agent_id, id)` |
| `orders_attributed_terminal_fk (tenant_id, attributed_terminal_id) → fintech_terminals` | `orders (tenant_id, attributed_monvelo_agent_id) → monvelo_agent_tenants` and `orders_attributed_terminal_fk (attributed_monvelo_agent_id, attributed_terminal_id) → monvelo_agent_terminals (agent_id, id)` |

**Database functions**

| Function | Change |
|---|---|
| `web_price_cart` | the split comes from the code's Monvelo agent (ACTIVE link, ACTIVE agent, a subaccount) and the tenant rate; no bounty (§15.5) |
| `web_resolve_code` | a staff link needs its holder to be an ACTIVE tenant member (as today); a POS link needs an ACTIVE link, an ACTIVE agent and an active terminal |
| `web_route_try` | a POS link's territory is the link's `territory_id`; its accountable person is that territory's TM (as for FINTECH_AGENT holders before) |
| `storefront_catalogue` | the venue comes from `monvelo_agent_terminals` |
| `place_web_order` | writes `attributed_agent_id` or `attributed_monvelo_agent_id`, and `payments.monvelo_agent_id` / `monvelo_terminal_id`; signature unchanged |
| `upsert_agent_code` | signature unchanged. A POS link names the terminal and leaves `p_agent_id` null (the agent is the terminal's); a staff link names the staff member and no terminal |
| `set_terminal_venue` | signature unchanged; the caller is an ACTIVE member of the terminal's agent, or a MONVELO_OPERATOR (call D) |
| `pos_order_lookup` | the caller is an ACTIVE member of the order's `attributed_monvelo_agent_id`; the tenant comes from the order and is re-verified against an ACTIVE link |
| `settle_paystack_payment` | writes `commission_records.monvelo_agent_id`; signature unchanged |
| `issue_otp`, `verify_otp` | DSA only (call E) |
| `invite_tenant_user` | refuses `FINTECH_AGENT` |
| `auth_sms_allowed` | also allows an ACTIVE Monvelo member to receive a sign-in code (without it, POS staff could not sign in at all once they leave `tenant_users`) |
| `monvelo_agent_audit` | also strips `paystack_subaccount_code` |
| `apply_paystack_refund`, `release_commission`, `list_unsettled_subaccounts`, `expire_unsettled_commissions`, `get_order_dispute_evidence`, `storefront_locations`, `quote_web_order`, `web_storefront_code` | unchanged: checked against the local database 2026-10-28, none reads a dropped or renamed column (they read `commission_records.paystack_subaccount_code`, `amount` and `status`, and the payment's `split_*`) |
| **new** `link_monvelo_agent`, `set_monvelo_agent_link_status` | tenant ZSM (§15.4 call A) |
| **new** `upsert_monvelo_terminal`, `set_monvelo_agent_subaccount` | MONVELO_OPERATOR |
| **new** `assert_monvelo_member(p_agent_id)`, `my_linked_monvelo_agent_ids()`, `monvelo_agent_link_active(p_tenant_id, p_agent_id)` | helpers |

**Edge Functions**

| Function | Change |
|---|---|
| `web-checkout` | none to the handler. The quote's split keeps the three wire keys D1 Decision 6 compares (`subaccount_code`, `commission_bps`, `partner_share`); only the informational key `fintech_partner_id` becomes `monvelo_agent_id`. The unit-test fixture is renamed |
| `process-payment` | none: it calls `settle_paystack_payment` with the same arguments |
| `fintech-commission-release`, `reconcile-funds` | none: they work from `commission_records` and `payments`, whose kept columns are unchanged. The names stay: "fintech" names the D1 domain, not the dropped table, and the cron jobs call them by name |
| `otp-issue`, `otp-verify` | none: they already serve the DSA |
| `storefront-catalogue`, `storefront-locations` | none |
| `_tests/gateway.integration.ts` | the fixtures create a Monvelo agent, member, terminal, subaccount and tenant link instead of a partner and a FINTECH_AGENT membership; the IT tenant's rate is set to 150 bps for the split flow |

### 15.4 Claude's calls

**A. Who links an agent to a tenant: a tenant ZSM, alone.** `link_monvelo_agent`
takes the agent's `(pos_network, network_agent_id)` (what the ZSM reads off the
agent's terminal or receipt), never a list of the registry, and a territory of
the ZSM's own tenant. The agent must be ACTIVE. The link is ACTIVE at once.
- Why no operator approval: the operator has already vetted the agent once for
  the whole platform (approval, KYC by the network, settlement account), and
  sets the subaccount the commission is paid to. A tenant cannot redirect money
  by linking, only allow a vetted agent's terminals to carry its own links. A
  second approval would add a queue without adding a control.
- The ZSM suspends or reactivates the link (`set_monvelo_agent_link_status`).
  The operator's `suspend_monvelo_agent` stops the agent for every tenant.
- **The link is for referral links only.** Monvelo financing (§7.1) never
  reads `monvelo_agent_tenants`, so this does not let a tenant steer which
  agent funds its sales (§2 anti-goal).
- A tenant need not have Monvelo financing enabled to link agents.

**B. The Paystack subaccount lives on the agent**, set by MONVELO_OPERATOR
(`set_monvelo_agent_subaccount`). It has no column grant, is stripped from
audit rows, and leaves the database only in the service-role quote that
`web-checkout` hands to Paystack. Tenants see `has_paystack_subaccount`. An
agent without one simply gets no split.

**C. The commission rate is per tenant**:
`tenant_settings.web_agent_commission_bps`, default 0. Like the fare and the
old bounty, it is written by migration only. §15.5 gives the rule.

**D. Territory lives on the link, not the terminal.** Terminals are
platform-level and territories are tenant-scoped, and one agent serves
different tenants in different territories. So the link holds the territory,
and routing and the TM's code rights read it there.
- **Venues are set by the agent's members or the operator, no longer by
  tenant ZSMs or TMs.** A terminal row is shared by every linked tenant's
  storefront. Letting one tenant's staff rewrite it would let tenant A change
  what tenant B's buyers see.
- The venue must lie inside the boundary of every ACTIVE linked territory that
  has a boundary. Likewise, a link is refused if one of the agent's existing
  venues lies outside the territory's boundary.

**E. FINTECH_AGENT is retired as an identity.**
- **Enum label.** It stays in `tenant_role_enum`, because dropping an enum
  value means rebuilding the type. `invite_tenant_user` refuses it (P0001), and
  CHECK `tenant_users_no_fintech_agent` refuses any row holding it (23514). A
  CHECK, not a trigger: it is simpler, it also catches an UPDATE, and on push
  it validates existing rows, which doubles as the pre-push check.
- **Member-facing RPCs** call `assert_monvelo_member(p_agent_id)` (an ACTIVE
  member of an ACTIVE agent; 42501 otherwise). This covers `set_terminal_venue`
  and `pos_order_lookup`.
- **Platform-actor exception** (like the operator's `p_tenant_id` in
  `record_monvelo_fee_terms`). A member has no tenant in their JWT. An RPC that
  serves a member takes the tenant from the record it touches (the order), and
  re-verifies live that the `(tenant, agent)` link is ACTIVE and the agent is
  ACTIVE. No member RPC accepts a tenant id.
- **Departure, for `issue_otp` and `verify_otp`.** The call was to give them a
  member branch. They have no record to take the tenant from: the subject is a
  shop owner who may trade with several linked tenants. Their only consumer is
  Spec D's unbuilt POS-backed order, and the advance flow is gone. So they
  become DSA-only. A POS shop-owner code returns with Spec D2, bound to an order
  (tenant from the order), and Monvelo's own owner codes come in Step 4 (§6.3).
- **What `agent_id` means now.** `agent_codes.agent_id` and
  `orders.attributed_agent_id` keep their meaning (a tenant staff profile) and
  are used for staff links only. POS links use the new `monvelo_agent_id` /
  `attributed_monvelo_agent_id`. Reasons:
  - the commission belongs to the agent business, not to whichever employee
    is at the till;
  - a member profile is not a tenant member, so `agent_id` would lose its
    composite meaning;
  - the composite FK onto the link is what keeps a POS link inside its tenant.

  A code has exactly one holder (CHECK), and it has a terminal exactly when its
  holder is a Monvelo agent (CHECK).

**F. Edge Functions change only where a name crosses the wire**, which in
practice means none of the handlers (§15.3). The unit fixtures are renamed, and
the integration suite moves to Monvelo fixtures and gains tests for the till
lookup by a member, the 0% codeless case and a suspended link.

**G. The Monvelo boundary moves (amends §4).** §4 said "no non-Monvelo
function writes [Monvelo tables]". From this amendment:
- non-Monvelo functions **read** Monvelo tables: `web_price_cart`,
  `web_resolve_code`, `web_route_try`, `storefront_catalogue`,
  `place_web_order`, `upsert_agent_code` and `pos_order_lookup` read the
  agents, links and terminals;
- `set_terminal_venue` (A1) **writes** `monvelo_agent_terminals`, and
  `upsert_agent_code` writes `agent_codes` rows that reference Monvelo rows;
- `payments`, `commission_records`, `agent_codes` and `orders` hold
  composite FKs onto `monvelo_agent_tenants` and `monvelo_agent_terminals`.

Lifting Monvelo out later therefore takes the agent registry, terminals and
links with it, and the web storefront keeps a read dependency on them.

### 15.5 The commission rule

1. A web order earns a commission only when it carries an agent code **held
   by a Monvelo agent** (a POS link): the link and the agent are ACTIVE, the
   terminal is active, and the agent has a Paystack subaccount.
2. Share = round(goods total × `web_agent_commission_bps` ÷ 10,000, 2 dp).
   The goods total excludes the transport fare, which is never commissioned
   (as before). Discounts are off, so the goods total is the retail subtotal.
3. When the share is 0 (rate 0, rounding to 0, no subaccount, a staff link, or
   no link at all), there is **no split**: `split` is null, `payments.split_*`
   are null, and no `commission_records` row is written. This is exactly what
   codeless orders get today. A share must also stay below the total, as D1
   requires.
4. `payments.split_bps` = the rate, `split_amount` = the share,
   `split_subaccount_code` = the agent's subaccount, all snapshotted at quote
   time. `commission_records.bps_applied` copies `split_bps`. D1's settlement
   check against Paystack's verified split, its 24-hour release and its 7-day
   expiry are unchanged.
5. Codeless orders pay 0%. They remain PAYSTACK_WEB only
   (`orders_codeless_pays_online`), however and wherever they are routed or
   fulfilled.
6. Staff links (DSA/DSM) earn no web split. Staff have no subaccount, and
   their incentives belong to Spec C (open question 2).
7. Interim: every tenant's rate is 0 until the user agrees a figure. A new
   migration sets it.

### 15.6 Dropped

- Tables `fintech_partners`, `fintech_terminals` and `fintech_advances`, with
  their policies, indexes and triggers. The migration drops them without
  CASCADE, so a forgotten dependency fails the migration loudly.
- Column `tenant_settings.web_agent_bounty`, and the bounty branch of
  `web_price_cart`.
- The FINTECH_AGENT paths in `issue_otp`, `verify_otp`, `set_terminal_venue`
  and `pos_order_lookup`, and FINTECH_AGENT invites.
- ZSM/TM venue editing (call D).
- Spec A's `fintech_advances` working-capital float, superseded by Monvelo
  financing.

### 15.7 Risks

| Risk | Mitigation |
|---|---|
| PL/pgSQL bodies are not dependency-tracked, so a function still naming a dropped table fails only when called | A pgTAP guard asserts that no `public` function body names `fintech_partners`, `fintech_terminals`, `fintech_advances` or `web_agent_bounty`, and that only `invite_tenant_user` names `FINTECH_AGENT` |
| A wrong subaccount code typed by the operator sends commission to the wrong account | Format check only, for now. D1 still compares Paystack's verified split subaccount with the snapshot. Verifying the code with Paystack's Fetch Subaccount is open question 5 |
| A member acting without a tenant reaches another tenant's data | Member RPCs take the tenant from the record and re-check the link live; composite FKs make cross-tenant rows impossible; pgTAP covers a member of agent X against agent Y's order and terminal |
| POS staff lose sign-in once they leave `tenant_users` | `auth_sms_allowed` admits ACTIVE members; pgTAP covers it |
| The remote push meets real rows despite "no data" | Pre-push checks (all must be 0) in `supabase/CLAUDE.md`: rows in the three legacy tables; `commission_records`; payments with a partner or terminal; codes with a terminal; orders with an attributed terminal; FINTECH_AGENT memberships. The new CHECK and FKs also fail the push rather than corrupt data |
| A shared venue edited by an agent's member changes every linked tenant's storefront | Accepted: it is the agent's own physical venue; the edit is audited, and every ACTIVE linked territory's boundary must contain it |
| Renaming split wire keys would break the web-checkout ↔ database contract | The wire keys are kept unchanged |

### 15.8 Open questions for the user

1. **The commission figure.** The interim rate is 0 bps for every tenant. What
   rate, per tenant, once agreed?
2. **Staff links.** Should DSA/DSM-held links also earn the web percentage?
   Default: no. They have no Paystack subaccount, and staff incentives are
   Spec C.
3. **Link authority.** Is a ZSM linking a vetted agent alone acceptable, or do
   you want MONVELO_OPERATOR approval of each link? Default: the ZSM alone.
4. **POS shop-owner codes.** Is it acceptable that a POS member cannot issue
   PICKUP_CONFIRM / POS_SETTLEMENT codes until Spec D2 binds them to an order?
   Default: yes.
5. **Subaccount verification.** Should `set_monvelo_agent_subaccount` go
   through a gateway that fetches the subaccount from Paystack and matches its
   settlement account to the agent's? Default: not in Step 1b; revisit with
   Step 3 (F1).
