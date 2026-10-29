# Addendum A6 to Spec A: Monvelo, inventory financing for neighbourhood shops

**Date:** 2026-10-28
**Status:** approved by the user 2026-10-28; amended 2026-10-28 (§15) and 2026-10-29 (§16)
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
may switch on. It is strictly B2B trade financing: POS-agent liquidity
sponsoring and neighbourhood-shop inventory financing (user, 2026-10-28).
Every existing payment route stays exactly as built and outside Monvelo:
cash and bank sales, the web POS referral links (A1, D1; the `web_pos_*`
tables after §15), and teafairweb retail on Paystack. Web sales never move to
Monvelo (§15.3 draws the boundary).

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

**`monvelo_agents`** (platform-level; serves every opted-in tenant):
- `id`, `business_name`, `pos_network` (`pos_network_enum`), `network_agent_id` (the network's own agent id);
- `contact_phone`, `location` (geometry point), `address_text`;
- `settlement_account_number`, `settlement_bank_code`, `settlement_account_name` (Paystack account resolution, name-matched to `business_name`);
- `paystack_payer_ref` (whatever Paystack exposes to prove a funding came from this agent's account; see §11 F1);
- `network_kyc_reference` (the network already KYC'd the agent; user decision: Teafair does no duplicate KYC);
- `recruited_by` (ZSA/ASA profile), `status` (`PENDING`, `ACTIVE`, `SUSPENDED`), `approved_by`, `approved_at`;
- `daily_cap`, `per_financing_cap`.

Staff for a fintech agent sign in as profiles linked through
`monvelo_agent_members(agent_id, profile_id, status)`. That keeps them
out of `tenant_users`.

Changing a settlement account is its own audited RPC. It re-runs Paystack
resolution and needs MONVELO_OPERATOR approval before payouts use the new
account.

**`retail_shops`** (existing shared registry) gains:
- `shop_code` (unique, human-readable);
- `area_id` per tenant, through **`monvelo_shop_enrolments(shop_id, tenant_id, area_id, recruited_by, consent_at, status)`**;
- `photo_slot_id` (the A5 upload-slot mechanism);
- `preferred_agent_id → monvelo_agents`.

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

## 15. Amendment 2026-10-28: domain separation and renames

**Status:** user rulings 2026-10-28 (binding); Claude's calls below are open to change.
**Supersedes:** the earlier §15, "Monvelo replaces fintech partners", and its Step 1b plan. Step 1b Task 1 was reverted in `8075f6d`, and nothing else from it was built.
**Amends:** §1, which now says that the web referral links are not part of Monvelo. It also amends Spec A §6.7, A1 §4 and D1 wherever they name `fintech_partners`, `fintech_terminals`, `agent_codes`, `commission_records`, `fintech_advances` or the `FINTECH_AGENT` role. Spec A §9 still holds without exception.
**Plan:** `docs/superpowers/plans/2026-10-28-domain-separation-renames.md`.

### 15.1 Why

The `fintech_*` names date from Spec A's first idea, "POS agents as liquidity". A1 and D1 reused those tables for the web storefront's POS referral partners and venues. The web domain therefore wore fintech names, and the earlier §15 mistook it for part of Monvelo.

The frontend is modular, with separation of concerns. Teafairweb is the retail storefront on Vercel, and it has no backend relationship with Monvelo. The backend names now say the same thing.

### 15.2 Rulings (user, 2026-10-28; binding)

1. **"Monvelo is strictly B2B trade financing."** It covers two things: POS-agent liquidity sponsoring, and inventory financing for neighbourhood shops. **Web sales never move to Monvelo.**
2. Web objects are renamed into a `web_` domain, and the two Monvelo agent tables lose `fintech` from their names. The full mapping is in §15.4.
3. `fintech_advances` is dropped entirely. Monvelo financing (§4.4) replaces it.
4. The flat ₦500 web POS bounty (`tenant_settings.web_agent_bounty`) is replaced by `tenant_settings.web_agent_commission_bps`:
   - an `integer not null default 0`, with a check of 0–10000;
   - set by migration only;
   - **0 for every tenant until the user agrees rates.**

   The commission is paid **only** on orders that came through a POS referral link (§15.5).
5. Nothing is pushed or deployed. No Prisma.

### 15.3 The boundary

| Domain | Owns | Never |
|---|---|---|
| **Web** (A1, A2, D1, A5 web parts) | `web_pos_partners`, `web_pos_venues`, `web_referral_codes`, `web_commissions`; `tenant_settings.web_*`; the storefront and checkout RPCs; `web-checkout`, `web-commission-release`, `web-order-status`, `storefront-*` | reads or writes a `monvelo_` table; has an FK onto one |
| **Monvelo** (A6) | every `monvelo_` table, `areas`, the ZSA/ASA anchors, `MONVELO_*` platform roles; `monvelo-*` gateways | reads or writes a `web_` table; has an FK onto one; pays or splits through the web commission path |
| **Shared** | `payments` and the Paystack webhook (`process-payment`, `settle_paystack_payment`, `apply_paystack_refund`); `reconcile-funds`; `_shared/payments/` (the Paystack client, settlement, refunds); OTP (`issue_otp`, `verify_otp`, `otp-*`); the message router; `retail_shops`, `profiles`, `tenants`, `orders` | — |

- `payments` is shared because Monvelo funding (Step 3) also settles through the Paystack webhook. Today its only partner and venue columns are web columns (`web_pos_partner_id`, `web_pos_venue_id`). Monvelo will add its own `monvelo_`-named references in Step 3, never reusing the web columns.
- `retail_shops.preferred_agent_id → monvelo_agents` is Monvelo's column on the shared registry (Step 1). It stays.
- §4's rule now holds both ways. No non-Monvelo function writes Monvelo tables, and no Monvelo function reads web tables. The two settlement-account RPCs are renamed `request_monvelo_settlement_change` and `approve_monvelo_settlement_change` (user, 2026-10-28), so every Monvelo function carries the prefix.

### 15.4 Mapping (old → new)

Every rename is done with `ALTER … RENAME` in a new migration, so rows, grants, column privileges, RLS and dependent constraint definitions carry over. Applied migrations are never edited. PL/pgSQL and plain SQL bodies are not dependency-tracked, so every function whose body names an old identifier is recreated with the same signature (except the two renamed RPCs below).

**Enum values**

| Old | New | How |
|---|---|---|
| `tenant_role_enum` `FINTECH_AGENT` | `POS_AGENT` | `ALTER TYPE … RENAME VALUE`, as `FIELD_DSA` → `FIELD_SALES` (`20261028120000`). Rows and the `tenant_users_territory_roles_have_territory` CHECK follow automatically. Bodies holding the literal are recreated: `issue_otp`, `verify_otp`, `invite_tenant_user`, `set_terminal_venue` |

**Tables**

| Old | New |
|---|---|
| `fintech_partners` | `web_pos_partners` |
| `fintech_terminals` | `web_pos_venues` |
| `agent_codes` | `web_referral_codes` |
| `commission_records` | `web_commissions` |
| `fintech_advances` | **dropped** (§15.6) |
| `monvelo_fintech_agents` | `monvelo_agents` |
| `monvelo_fintech_members` | `monvelo_agent_members` |

The row types follow the tables. `web_price_cart(p_code public.agent_codes, …)` and `web_route_try(…, p_code public.agent_codes, …)` keep their identity: the parameter type is the same type under its new name.

**Columns**

| Old | New | Note |
|---|---|---|
| `payments.fintech_partner_id` | `payments.web_pos_partner_id` | the column grant to `authenticated` follows |
| `payments.fintech_terminal_id` | `payments.web_pos_venue_id` | the column grant follows |
| `commission_records.fintech_partner_id` | `web_commissions.web_pos_partner_id` | |
| `agent_codes.terminal_id` | `web_referral_codes.venue_id` | |
| `agent_codes.agent_id` | unchanged | the profile that holds the link (a DSA, DSM or POS_AGENT member) |
| `fintech_terminals.terminal_id` (the device id, text) | `web_pos_venues.network_terminal_id` | frees `terminal_id` for the guard |
| `fintech_terminals.partner_id`, `agent_id` | unchanged | inside `web_pos_venues` they are unambiguous |
| `orders.agent_code_id` | `orders.referral_code_id` | Claude's call: it names the old table |
| `orders.attributed_terminal_id` | `orders.attributed_venue_id` | |
| `orders.attributed_agent_id` | unchanged | |
| `fintech_partners.commission_bps` | **dropped** | superseded by the tenant rate |
| `tenant_settings.web_agent_bounty` | **dropped** | replaced by `web_agent_commission_bps` |
| — | `tenant_settings.web_agent_commission_bps` (new) | `integer not null default 0`, CHECK `tenant_settings_web_agent_commission_bps_check` (0–10000) |

**Constraints.** Each constraint is renamed by replacing its table prefix, with the column part following the column rename. Renaming a primary-key or unique constraint also renames its index.

| Old | New |
|---|---|
| `fintech_partners_{pkey, tenant_id_id_key, tenant_id_pos_network_business_name_key, tenant_id_fkey, tenant_id_territory_id_fkey, approved_by_fkey, active_is_approved, business_name_check, contact_phone_check, paystack_subaccount_code_check, status_check}` | `web_pos_partners_{same}` |
| `fintech_partners_commission_bps_check` | dropped with its column |
| `fintech_terminals_{pkey, tenant_id_id_key, tenant_id_fkey, tenant_id_partner_id_fkey, tenant_id_territory_id_fkey, agent_id_fkey, address_text_check, operating_hours_check, state_check, venue_complete, venue_name_check}` | `web_pos_venues_{same}` |
| `fintech_terminals_tenant_id_terminal_id_key`, `fintech_terminals_terminal_id_check` | `web_pos_venues_tenant_id_network_terminal_id_key`, `web_pos_venues_network_terminal_id_check` |
| `agent_codes_{pkey, code_key, tenant_id_id_key, tenant_id_fkey, agent_id_fkey, created_by_fkey, code_check, discount_pair, discount_type_check, fixed_positive, max_redemptions_check, percent_range}` | `web_referral_codes_{same}` |
| `agent_codes_tenant_id_terminal_id_fkey` | `web_referral_codes_tenant_id_venue_id_fkey` |
| `commission_records_{pkey, tenant_id_payment_id_key, tenant_id_fkey, tenant_id_order_id_fkey, tenant_id_payment_id_fkey, teafair_agent_id_fkey, amount_check, bps_applied_check, disputed_has_reason, paystack_subaccount_code_check, settled_has_time}` | `web_commissions_{same}` |
| `commission_records_tenant_id_fintech_partner_id_fkey` | `web_commissions_tenant_id_web_pos_partner_id_fkey` |
| `payments_tenant_id_fintech_partner_id_fkey`, `payments_tenant_id_fintech_terminal_id_fkey` | `payments_tenant_id_web_pos_partner_id_fkey`, `payments_tenant_id_web_pos_venue_id_fkey` |
| `payments_split_has_partner` | unchanged (its definition follows the column) |
| `orders_agent_code_fk`, `orders_attributed_terminal_fk` | `orders_referral_code_fk`, `orders_attributed_venue_fk` |
| `orders_codeless_pays_online`, `orders_web_attribution_complete` | unchanged (definitions follow the columns) |
| `tenant_settings_web_agent_bounty_check` | dropped with its column |
| `monvelo_fintech_agents_{pkey, pos_network_network_agent_id_key, approved_by_fkey, recruited_by_fkey, address_text_check, business_name_check, check, contact_phone_check, daily_cap_check, network_agent_id_check, network_kyc_reference_check, per_financing_cap_check, settlement_account_last4_check, settlement_account_name_check, settlement_account_number_check, settlement_bank_code_check, status_check}` | `monvelo_agents_{same}` |
| `monvelo_fintech_members_{pkey, agent_id_fkey, profile_id_fkey, status_check}` | `monvelo_agent_members_{same}` |
| `retail_shops_preferred_agent_id_fkey`, `monvelo_agent_nominations_recruited_agent_id_fkey` | unchanged (they now point at `monvelo_agents`) |

**Indexes** (not constraint-backed)

| Old | New |
|---|---|
| `idx_fintech_partners_approved_by`, `idx_fintech_partners_territory` | `idx_web_pos_partners_approved_by`, `idx_web_pos_partners_territory` |
| `idx_fintech_terminals_{agent, location, partner, territory}` | `idx_web_pos_venues_{agent, location, partner, territory}` |
| `idx_agent_codes_agent`, `idx_agent_codes_created_by`, `idx_agent_codes_terminal` | `idx_web_referral_codes_agent`, `idx_web_referral_codes_created_by`, `idx_web_referral_codes_venue` |
| `idx_commission_records_{order, partner, split, teafair_agent}` | `idx_web_commissions_{order, partner, split, teafair_agent}` |
| `idx_payments_partner`, `idx_payments_terminal` | `idx_payments_web_pos_partner`, `idx_payments_web_pos_venue` |
| `idx_orders_agent_code`, `idx_orders_attributed_terminal` | `idx_orders_referral_code`, `idx_orders_attributed_venue` |
| `idx_monvelo_fintech_agents_{approved_by, recruited_by, status}` | `idx_monvelo_agents_{approved_by, recruited_by, status}` |
| `idx_monvelo_fintech_members_profile` | `idx_monvelo_agent_members_profile` |
| `idx_fintech_advances_{agent, partner, status}` | dropped with the table |

**Policies** (all `FOR SELECT`; the predicates are unchanged)

| Old | New |
|---|---|
| `fintech_partners_select_tenant_member` | `web_pos_partners_select_tenant_member` |
| `fintech_terminals_select_tenant_member` | `web_pos_venues_select_tenant_member` |
| `agent_codes_select_tenant_member` | `web_referral_codes_select_tenant_member` |
| `commission_records_select_tenant_member` | `web_commissions_select_tenant_member` |
| `monvelo_fintech_agents_select` | `monvelo_agents_select` |
| `monvelo_fintech_members_select` | `monvelo_agent_members_select` |
| `fintech_advances_select_tenant_member` | dropped with the table |

**Triggers and trigger functions**

| Old | New |
|---|---|
| `fintech_partners_set_updated_at`, `fintech_terminals_set_updated_at`, `agent_codes_set_updated_at`, `commission_records_set_updated_at`, `monvelo_fintech_agents_set_updated_at` | `web_pos_partners_…`, `web_pos_venues_…`, `web_referral_codes_…`, `web_commissions_…`, `monvelo_agents_set_updated_at` |
| trigger `agent_codes_no_discount` and its function `agent_codes_no_discount()` | `web_referral_codes_no_discount`, both (`ALTER FUNCTION … RENAME`; body unchanged) |
| `commission_records_support_ticket_ins`, `commission_records_support_ticket_upd` | `web_commissions_support_ticket_ins`, `web_commissions_support_ticket_upd` (function `support_ticket_on_commission_disputed` keeps its name) |
| `fintech_advances_set_updated_at` | dropped with the table |

**Database functions**

| Function | Change |
|---|---|
| `upsert_agent_code(p_idempotency_key, p_code, p_agent_id, p_terminal_id, p_discount_type, p_discount_value, p_max_redemptions, p_expires_at, p_is_active)` | **renamed** `upsert_web_referral_code(…, p_venue_id uuid, …)`, otherwise the same arguments and rules; dropped and created, with the same grants (authenticated, service_role); idempotency op name `upsert_web_referral_code` |
| `set_terminal_venue(p_idempotency_key, p_terminal_id, p_venue_channel, …)` | **renamed** `set_web_pos_venue(p_idempotency_key, p_venue_id uuid, p_venue_channel, …)`; the same rules (ZSM, TM, or the venue's POS_AGENT); the same grants; op name `set_web_pos_venue` |
| `web_price_cart` | the new names; the split comes from the tenant rate (§15.5); the bounty branch goes |
| `web_resolve_code`, `web_route_try`, `web_storefront_code`, `storefront_catalogue`, `storefront_locations`, `quote_web_order`, `place_web_order`, `get_order_dispute_evidence` | the new names only; signatures unchanged |
| `settle_paystack_payment`, `apply_paystack_refund`, `release_commission`, `list_unsettled_subaccounts`, `expire_unsettled_commissions` | the new names only; the names and signatures are kept (call 7) |
| `issue_otp`, `verify_otp`, `invite_tenant_user` | `'FINTECH_AGENT'` → `'POS_AGENT'` only |
| `pos_order_lookup` | unchanged (its body names no old identifier) |
| `add_monvelo_member`, `approve_monvelo_agent`, `suspend_monvelo_agent`, `set_monvelo_agent_caps`, `register_monvelo_agent`, `request_settlement_change` → `request_monvelo_settlement_change`, `approve_settlement_change` → `approve_monvelo_settlement_change`, `close_monvelo_nomination`, `my_monvelo_agent_ids` | the new Monvelo table names only. `register_monvelo_agent` also matches the renamed constraint `monvelo_agents_pos_network_network_agent_id_key` in its 23505 handler |

Audit `entity_type` values written from now on use the new table names (`web_referral_codes`, `web_pos_venues`, `web_commissions`, `monvelo_agents`, `monvelo_agent_members`). Any older rows keep the old names; audit rows are never rewritten.

**Edge Functions and shared code**

| Old | New |
|---|---|
| `supabase/functions/fintech-commission-release/` | `supabase/functions/web-commission-release/` (handler unchanged; `observe("web-commission-release", …)`) |
| `[functions.fintech-commission-release]` in `config.toml` | `[functions.web-commission-release]` |
| cron job `fintech-commission-release` (`20261020130300`) | `web-commission-release`, the same schedule `0 6 * * *`, re-scheduled by a new migration that unschedules the old job |
| `supabase/functions/_shared/fintech-liquidity/` | `supabase/functions/_shared/payments/`, shared because Monvelo funding will use Paystack too. Importers: `process-payment`, `reconcile-funds`, `web-checkout`, `web-commission-release`, `_shared/monvelo/paystack-resolve.ts` |
| the quote's `split.fintech_partner_id` (internal; service-role quote only) | `split.web_pos_partner_id`; the `web-checkout` unit fixture is renamed in the same task |

**Kept on purpose**

- The D1 wire keys `subaccount_code`, `commission_bps` and `partner_share` are kept. Paystack and the database compare them.
- The Paystack transaction metadata key `agent_code` is kept, because Paystack reports and dashboards show it.
- The function names `release_commission`, `expire_unsettled_commissions`, `list_unsettled_subaccounts`, `settle_paystack_payment`, `apply_paystack_refund`, `issue_otp` and `verify_otp` are kept.
- The enum `commission_status_enum` and the system-ticket key `COMMISSION_DISPUTED:` are kept.
- Applied migration files keep their historical names. The `…_fintech_liquidity_*` files hold OTP, the Paystack webhook and D1 money. So do the pgTAP files `008`, `009` and `015`–`017`.

**HTTP responses**

- **Teafairweb's public responses do not change.** These responses name none of the renamed objects: `storefront-catalogue` (its `venue` is `{name, channel}`), `storefront-locations`, `web-checkout` (the `place_web_order` result) and `web-order-status`.
- **One staff response changes.** In `order-dispute-evidence` (authenticated, staff only), `order.agent_code_id` becomes `order.referral_code_id`. It has no consumer yet, since the Spec B app is unbuilt.
- The renamed RPCs `upsert_web_referral_code` and `set_web_pos_venue` are PostgREST calls for staff. No client calls them yet. Only the integration suite and pgTAP do. Their results and idempotency request keys change with the rename: `upsert_web_referral_code` returns `referral_code_id` (was `agent_code_id`) and `set_web_pos_venue` returns `venue_id` (was `terminal_id`).

### 15.5 The commission rule

1. A web order earns a commission **only** when its referral code is tied to a POS venue: `web_referral_codes.venue_id` is set, and the venue's partner is ACTIVE. `web_resolve_code` already refuses a code whose venue is inactive.
2. Codeless orders pay 0%, wherever they are routed or fulfilled, and remain PAYSTACK_WEB only (`orders_codeless_pays_online`). DSA and DSM staff links pay 0%; staff incentives are Spec C.
3. Share = `round(goods_total * web_agent_commission_bps / 10000, 2)`, on goods only and never on the transport fare. Discounts are off, so the goods total is the retail subtotal.
4. A rate of 0, or a share that rounds to 0, means **no split**: the quote's `split` is null, `payments.split_*` stay null, and no `web_commissions` row is written. As in D1, a share must also stay below the total.
5. When there is a split:
   - `commission_bps` is the tenant rate, `partner_share` is the share, and `subaccount_code` is the partner's subaccount;
   - `payments.split_bps`, `split_amount` and `split_subaccount_code` snapshot those values at quote time;
   - `web_commissions.bps_applied` copies `split_bps`.

   D1's check against Paystack's verified split, its 24-hour release and its 7-day expiry are unchanged.
6. **The interim rate is 0 for every tenant, TEAFAIR included.** So no order splits until a later migration sets a rate. This ends TEAFAIR's ₦500 bounty.

### 15.6 Dropped

- **Table `fintech_advances`**, with its policy, three indexes and trigger. No function body names it, and no FK points at it. It is dropped without CASCADE, so a dependency nobody noticed fails the migration loudly. Spec A's working-capital float is superseded by Monvelo financing.
- **Columns:**
  - `fintech_partners.commission_bps` (now `web_pos_partners`): one source, the tenant rate;
  - `tenant_settings.web_agent_bounty`, and the bounty branch of `web_price_cart`.
- **The old names themselves.** None survives as a view or an alias, and no compatibility shims are added.

### 15.7 The guard

`042_domain_separation_guard.test.sql` is created in the plan's first task and extended by each later one. It asserts the following.

1. No `public` function body (`pg_proc.prosrc`) matches any of these patterns (case-sensitive; one assertion per pattern, so a failure names it):
   - `fintech_partners`, `fintech_terminals`, `fintech_advances`;
   - `agent_codes`, `commission_records`;
   - `FINTECH_AGENT`, `web_agent_bounty`, `monvelo_fintech_`;
   - `fintech_partner_id`, `fintech_terminal_id`;
   - `agent_code_id`, `attributed_terminal_id`;
   - `upsert_agent_code`, `set_terminal_venue`;
   - `\.commission_bps` (a column access; the wire key `'commission_bps'` stays legal);
   - `terminal_id`, tested after `regexp_replace(prosrc, 'network_terminal_id', '', 'g')`.
2. No constraint, index, policy or trigger in `public` has a name matching `fintech|agent_code|commission_records|monvelo_fintech`.
3. The old tables, columns and functions are absent (`hasnt_table`, `hasnt_column`, `hasnt_function`), and the enum labels are as §15.4.
4. No `cron.job` is named `fintech-commission-release` or has a command that names it.

The boundary test is in `045`. No function body names both a `public.web_` table and a `public.monvelo_` table. No FK joins a `monvelo_` table to a `web_` table in either direction. Monvelo-table bodies in functions without `monvelo` in the name are limited to the two named in §15.3.

### 15.8 Remote deploy (user actions, later; nothing is done now)

The remote has the 29 migrations up to `20261015130200`. It therefore holds `fintech_partners`, `fintech_terminals`, `fintech_advances`, `agent_codes`, `commission_records` and `FINTECH_AGENT`, but none of D1–A6. The renames apply in order after everything before them, and `ALTER … RENAME` keeps rows.

**Pre-push checks** (run on the remote; any non-zero result needs a decision first):
1. `select count(*) from public.fintech_advances;` must be 0. Its rows would be lost.
2. `select count(*) from public.fintech_partners where commission_bps > 0;` Those per-partner rates are dropped. After the push every tenant's rate is 0 until the user sets one.
3. `select count(*) from public.tenant_users where role = 'FINTECH_AGENT';` is informational. Those memberships become `POS_AGENT` with no other change.

**Functions:**
- Every importer of `_shared/payments/` must be redeployed: `process-payment`, `reconcile-funds`, `web-checkout`, `web-commission-release` and `monvelo-agent-register`. Their bundles otherwise still hold the old code.
- Deploy `web-commission-release` in the same window as the migration push, outside the 06:00 UTC run. If the push and the deploy straddle 06:00, the job logs one 404 and runs again the next day.
- Idempotency keys logged under the old op names (`upsert_agent_code`, `set_terminal_venue`, `request_settlement_change`, `approve_settlement_change`) raise TF002 if replayed after the push; no client exists, so no action.
- `fintech-commission-release` is not on the remote: the 2026-10-15 record lists six functions. If it has been deployed by push time, delete it with `supabase functions delete fintech-commission-release`.

**Never** run `supabase config push`. The renamed `[functions.web-commission-release]` entry only affects local `verify_jwt`. Set it in the dashboard if the remote needs it.

### 15.9 Risks

| Risk | Mitigation |
|---|---|
| A function body still names an old identifier. The migration passes and the call fails at run time | The §15.7 guard; recreated bodies start from the live `pg_get_functiondef`, so no earlier edit is lost |
| A constraint name is matched as text (`register_monvelo_agent` maps a 23505 by constraint name) | Recreated with the new name, and covered by 045's duplicate-registration test, which expects the plain message, not a raw 23505 |
| An idempotency key used before the rename is replayed afterwards under the new op name (`upsert_web_referral_code`, `set_web_pos_venue`, `request_monvelo_settlement_change`, `approve_monvelo_settlement_change`) and gets TF002 | Accepted: no client exists yet; the Monvelo tables were never deployed and the only caller of the two Monvelo RPCs is the in-repo handler |
| Edge bundles on the remote still import `_shared/fintech-liquidity` | The redeploy list in §15.8; `deno check` of every `index.ts` in the plan's Edge Function task |
| Renaming `orders.agent_code_id` changes the staff evidence key | Listed in §15.4; there is no consumer yet |
| TEAFAIR POS partners stop earning the ₦500 bounty | Ruled by the user: 0 until rates are agreed |
| The tenant rate is readable by every member of the tenant (`tenant_settings` has a table-level SELECT) | Accepted: it is the tenant's own setting, as the fare is |

### 15.10 Questions answered (user, 2026-10-28)

1. **Renaming the two staff RPCs** (`upsert_agent_code` → `upsert_web_referral_code`, `set_terminal_venue` → `set_web_pos_venue`, with `p_terminal_id` → `p_venue_id`). **Answer: rename.**
2. **`orders.agent_code_id` → `referral_code_id`.** **Answer: rename**, along with the staff evidence key.
3. **Should `request_settlement_change` / `approve_settlement_change` get the `monvelo_` prefix?** **Answer: yes**: `request_monvelo_settlement_change` and `approve_monvelo_settlement_change`. They change a Monvelo agent's payout account (recruiter requests via `monvelo-agent-register`, operator approves); "settlement" alone collides with the web domain's Paystack settlements.

## 16. Amendment 2026-10-29: the `monvelo.md` proposal and two tenant roles

**Status:** user rulings 2026-10-29 (binding); Claude's calls are marked and open to change.
**Source:** the user's proposal `monvelo.md` (repository root, kept as received, not adopted) and Claude's review of it (2026-10-29).

### 16.1 The proposal

`monvelo.md` describes the same model as this addendum: the brand pays the
lender's return as a cost of sale, the shop pays 0% within the interest-free
window, the Monvelo operator approves agents, and agents are matched to shops
by distance. **Its SQL is not applied.** It recreates tables that exist
under other names, and it breaks Spec A §9 in several ways:
- it reads claims through `current_setting` and writes policies for every command;
- it uses `NUMERIC(12,2)` and enum workflow statuses;
- it puts `ON DELETE CASCADE` on financial rows and uses single-column tenant FKs.

Its RLS would either return no rows (restrictive policies only) or expose
tenant data (ten tables without RLS, and a balance view that bypasses RLS).

Its names map onto this addendum as follows:

| `monvelo.md` | This addendum |
|---|---|
| inventory loan (`inventory_loans`) | `monvelo_financings` + `monvelo_financing_lines` (§4.4) |
| interest subsidy (`interest_subsidies`) | the rebate: `monvelo_rebate_payables` (§4.4) |
| cost-of-sales ledger (`tenant_ledger_transactions`) | the tenant settlement ledger (§16.5) behind `monvelo_tenant_settlements` |
| `shops`, `tenant_shop_registrations` | `retail_shops`, `monvelo_shop_enrolments` |
| `products`, `warehouse_stock`, `deliveries` | `central_products`, `inventory_batches`, `order_fulfilments` |
| `monvelo_agents` | `monvelo_fintech_agents`, renamed `monvelo_agents` by the §15 rename plan (Task 5) |
| `fintech_partners`, `FINTECH_AGENT` | not used: `web_pos_partners` and `POS_AGENT` belong to the web domain (§15) |

### 16.2 Rulings (user, 2026-10-29; binding)

1. **The 10% is the brand-paid rebate.** It is the "interest subsidy" the manufacturer absorbs as a cost of sale, so the shop pays 0% for the interest-free days.
   - It stays a per-brand, dated `rebate_bps` (§4.2; Purerigin 10%).
   - "Interest subsidy" and "rebate" name one thing; the schema keeps *rebate*.
   - The late charge (§4.2, default 10% once after the window) is separate and unchanged.
2. **Tenants never choose, link to or approve agents.** This reaffirms 2026-10-28.
   - Agent registration, territory links and approvals belong to `MONVELO_OPERATOR` alone.
   - There is no agent–tenant link table.
3. **No prepaid pool.** §4.4 stands: Teafair pays the rebate, then deducts rebates and fees from the tenant's settlement. An insert-only ledger sits behind each settlement statement (§16.5).
4. **New tenant roles:** `TENANT_ADMIN` and `LOGISTICS_MANAGER`, and (user, later the same day) a Teafair `CLIENT_SERVICE_MANAGER` who represents the tenant in house. Contact reports are the source of truth (§16.3).
5. **Tenant billing is out of scope.** There is no subscription or trial status. This milestone covers B2B financing, inventory loans and settlements only.
6. **No credit score until legal and risk review.** The deterministic limit rules of §7.2 govern meanwhile.

### 16.3 The tenant's representation: CSM, contact reports, and two roles

**The model (user, 2026-10-29).** Teafair works with its tenants as an
agency works with a client:
- A Teafair **Client Service Manager (CSM)** represents the tenant in house and makes the tenant's changes in the app.
- After each meeting or call, the CSM files a **contact report**, with the tenant's contacts in copy.
- **The contact report is the source of truth.** Every change the CSM or the CSM's logistics staff make on the tenant's behalf cites the report that agreed it.
- The tenant reads its reports; it does not operate the app.

New values in `tenant_role_enum`: `CLIENT_SERVICE_MANAGER`, `TENANT_ADMIN`,
`LOGISTICS_MANAGER`. All three are **tenant-wide**: no zone, territory or
area anchor.

**`CLIENT_SERVICE_MANAGER`** (Teafair staff, in house):
- holds one `tenant_users` membership for each tenant they serve (`unique (tenant_id, profile_id)` already allows one per tenant); appointed only by a platform administrator, so the role is always Teafair's own staff;
- files the tenant's contact reports (§16.4);
- **approves brand terms that a ZSM proposed** (§4.2), citing the contact report in which the brand agreed them. This is the brand's approval required by §2 and §14 Q2, and it replaces the second-ZSM approval;
- sets `monvelo_tenant_settings` (enabled, opening limit, approval cap), citing a contact report;
- maintains the catalogue through new catalogue RPCs (products, prices, NAFDAC numbers, pack sizes), each change citing a contact report;
- invites the tenant's `LOGISTICS_MANAGER`s and `TENANT_ADMIN` logins.

**`TENANT_ADMIN`** (the tenant's own login, **read only**):

| Reads | Notes |
|---|---|
| Contact reports and their decisions | the source of truth |
| Settlement statements and the §16.5 ledger | `MONVELO_FINANCE` records payouts and remittances |
| The Monvelo book, daily and weekly reports | as A6 §4.4 |
| Brand terms, catalogue, Monvelo settings | as set by the CSM |

The `monvelo.md` definition ("manages cost-of-sales subsidy ledgers, product
catalogs, and custom brand financing terms") is carried out by the CSM on
the tenant's behalf. The `TENANT_ADMIN` reads the results.

**`LOGISTICS_MANAGER`** (Teafair staff in the CSM's purview: `reports_to_id` is the tenant's CSM):

| Duty | Today | With this amendment |
|---|---|---|
| Dispatch | `mark_order_dispatched` (A5): a ZSM or the warehouse's `manager_id` | Also any `LOGISTICS_MANAGER` of the tenant, for every warehouse |
| Delivery receipts | `mark_order_delivered` (A5, courier path with the delivery code) | Also `LOGISTICS_MANAGER`. **A Monvelo financing still becomes DELIVERED only on the shop owner's OTP (§4.4).** |
| Stock movements | `inventory_batches` changes only by migration | New stock-movement RPCs (receipt, transfer, adjustment), each citing the contact report that agreed it, with a movement record |
| Same-day supply | — | Reads FUNDED financings awaiting delivery, so stock leaves before the 23:59 REFUND_DUE sweep |

Warehouse managers named in `warehouses.manager_id` keep working as now.

**Claude's calls (open to change):**
- **Order dispatch and delivery do not cite a contact report.** They are proven by their own records: the A5 delivery code and photo, or the shop owner's OTP. Contact reports govern what was agreed with the tenant, not each order.
- **Bridging rule:** until a tenant has an active CSM, the §4.2 rule (two different ZSMs) and the ZSM's settings right continue, so TEAFAIR is not blocked.
- **Naming:** the catalogue, stock-movement and contact-report objects are RTM core, not Monvelo. They carry no `monvelo_` prefix, and §4's rule that Monvelo functions write only Monvelo tables still holds.
- **Buyer contacts:** A2 is unchanged. None of the three roles is added to the readers of `order_contacts`.

### 16.4 Contact reports (Claude's call; names open to change)

**`contact_reports`**: one row per meeting or call:
- **Columns:**
  - `id`, `reference` (`CR-…`), `tenant_id`;
  - `met_at`, `channel` (`text` + `CHECK`: `MEETING`, `CALL`, `VIDEO`, `MESSAGE`);
  - `attendees` (names and sides), `summary`;
  - `filed_by` (the CSM), `filed_at`;
  - `supersedes_id?` (a correction refers to the report it corrects).
- **Decisions:** one `contact_report_decisions(report_id, tenant_id, id, subject, text)` row per agreed decision. A change in the app cites a **decision**, not just a report:
  - `monvelo_brand_terms.approval_decision_id`;
  - the settings, catalogue and stock-movement records each carry `decision_id`.
- **Recipients:** `contact_report_recipients(report_id, name, channel, address)` lists the tenant's contacts in copy. They need no app login. Reports are sent through the A5 message router (WhatsApp now, email when Resend is live), and every send is logged.
- **Insert-only, and kept at least 5 years:** `UPDATE` and `DELETE` are revoked and refused by trigger. A mistake is corrected by a new report that supersedes the old one, and a superseded report's decisions can no longer be cited.
- **Readers:** the tenant's `TENANT_ADMIN`, CSM and ZSMs, and platform staff.
- **The signed hard copy (user, 2026-10-29; binding).** Every contact report has a hard copy, and it is uploaded.
  - The CSM scans or photographs the signed paper report and uploads it as a PDF, JPEG or PNG of up to 10 MB, into a private bucket.
  - Uploading follows the A5 pattern: a slot RPC, a gateway that signs a one-time upload URL, and a claim that checks the file is really there.
  - **A ZSM reviews the report first (user, 2026-10-29; binding).** Any ACTIVE ZSM of the tenant approves or rejects it, and a rejection says what must be corrected. The hard copy can be uploaded only after an approval. A rejected report is corrected by a superseding report, which is reviewed in turn. Each report has one review, which is insert-only.
  - **A report's decisions cannot be cited until it is ZSM-approved and its hard copy is attached.**
  - One hard copy per report. It is never replaced or deleted; a wrong copy means a correcting report with its own hard copy.
  - The report's readers can download the attached copy. Copies to the tenant's contacts are sent only once it is attached.
  - Claude's calls (open to change): the formats and size limit, and that the uploader is the CSM.

### 16.5 The tenant settlement ledger (Claude's call; names open to change)

**`monvelo_tenant_ledger_entries`**: one insert-only row per money event on a tenant's Monvelo account.
- **Columns:**
  - `id`, `tenant_id`, `business_date` (Africa/Lagos);
  - `entry_type` (`text` + `CHECK`: `FUNDED_GROSS`, `REBATE`, `FEE`, `REFUND`, `REMITTANCE`);
  - `financing_id?`, `rebate_payable_id?`;
  - `amount NUMERIC(15,2)`, `created_at`.
- **Sign rule, enforced by `CHECK`:** positive for what Teafair owes the tenant (`FUNDED_GROSS`), negative for every deduction or payment out (`REBATE`, `FEE`, `REFUND`, `REMITTANCE`).
- **Who writes it:** only the Monvelo transaction that causes the entry (funding webhook, rebate payout, refund, remittance note), never by hand.
- **Protection:** `UPDATE` and `DELETE` are revoked from every role, and a trigger refuses both. Rows are kept at least 5 years (§7.4).
- **Settlements:** each `monvelo_tenant_settlements` row equals the sum of that tenant's entries for its date, by type.
- **Readers:** the tenant's `TENANT_ADMIN`, CSM and ZSMs, and `MONVELO_FINANCE`.

### 16.6 Kept from the review (Claude's calls; open to change)

- **Agent proximity search:** an RPC for platform staff only. It searches the agent's registered location as `geography`, so the spatial index is used, and returns agent ids and distances, never phone numbers. It feeds supply-day notices (§5) and allocation (§7.1).
- **Per-shop limits:** the current limit and its history are stored on the enrolment, so §7.2's rules have somewhere to live.
- **Order financing status:** a read showing whether a trade order was paid in cash or financed, and where the financing stands. It is a `security_invoker` view or an RPC, not a second status column on `orders`.

**Not adopted:**
- the parallel tables of §16.1;
- a credit score (ruling 6);
- an agent's live location;
- cash collection (§2, §7.4);
- a prepaid pool (ruling 3);
- tenant subscriptions (ruling 5).

### 16.7 Effect on delivery

- **Step 2 plan additions:**
  - the three enum values, in their own migration (a new enum value cannot be used in the transaction that adds it);
  - `invite_tenant_user` rules: a platform administrator appoints a CSM; a CSM invites `LOGISTICS_MANAGER` (reporting to that CSM) and `TENANT_ADMIN`;
  - the §16.4 contact reports and their sending;
  - the CSM approval with a cited decision in the terms and settings RPCs;
  - the fulfilment helpers `fulfilment_can_dispatch` and `fulfilment_delivery_path`;
  - the catalogue and stock-movement RPCs, each citing a decision;
  - the §16.5 ledger and the §16.6 reads.
- **The §15 rename plan is unchanged.** Its Task 5 name `monvelo_agents` matches `monvelo.md`. Tasks 5–7 stay on hold until the user has finished the rename-map review.
- **Nothing is pushed or deployed.**
