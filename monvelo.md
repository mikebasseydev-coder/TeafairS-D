# Monvelo: B2B inventory financing, process by process

**Version 2, 29 October 2026.** This replaces the proposal of the same day,
which is kept as `monvelo.v1.md`.

**What this document is.** A plain description of how Monvelo works: who
does what, step by step, and what the backend does at each step. Every name
below is the real name in the database or the plan.

**What governs.** Spec A and Addendum A6 (with §15 and §16) in
`docs/superpowers/specs/` are the authority. If this file and A6 ever
disagree, A6 wins.

**Build status tags used below:**
- **[Built]** exists on branch `feat/monvelo-step1`, tested, local only;
- **[1c]**, **[Step 2]** … **[Step 8]** are planned, in that order (see §9).

Nothing is pushed or deployed.

---

## 1. Monvelo in one paragraph

A neighbourhood shop needs stock but has no cash. A registered POS agent
(Moniepoint, OPay or PalmPay) pays for the stock through Paystack. The shop
gets the stock the same day and repays the agent within **30 days at 0%
interest**. The **brand pays the agent a rebate** (for example 10%) as its
cost of sale. Teafair pays that rebate to the agent within 24 hours, then
deducts it, with its own fees, before paying the brand (the tenant) what it
is owed. Monvelo is strictly B2B trade financing. Web sales never touch it.

## 2. Where the money goes

```
 POS agent ──(principal, Paystack, from the agent's own account)──▶ Teafair
     ▲                                                              │
     │ rebate within 24 h, from Teafair's account on the            │ daily settlement:
     │ agent's own network (OPay / Moniepoint / PalmPay)            │ gross − rebates − fees
     │                                                              ▼
 Teafair finance ◀───────────────────────────────────────────── Tenant (brand)
                                                                  (remitted off-app)
 Shop ──(stock, same day)◀── Tenant's warehouse
 Shop ──(repayment within 30 days, 0%)──▶ POS agent
```

Rules that never bend:
- **Paystack only.** No cash handling.
- **No netting.** The funding and the rebate are two separate, traceable payments.
- **Nothing typed at the moment of a transaction.** No amount, rate or account is keyed in; all are derived.
- **Records are never deleted.** They are kept at least 5 years (Money Laundering Act 2022).

## 3. Who is who

| Person | Works for | Role in the schema | Does | Status |
|---|---|---|---|---|
| Monvelo operator | Teafair | `MONVELO_OPERATOR` (platform) | approves agents and their territories, sets agent caps, records Teafair's fee terms, reviews fraud flags | [Built] |
| Monvelo finance officer | Teafair | `MONVELO_FINANCE` (platform) | pays rebates, approves large payouts (second person), notes remittances to tenants | role [Built]; duties [Step 5] |
| **Client Service Manager (CSM)** | Teafair | `CLIENT_SERVICE_MANAGER` (tenant role, Teafair staff only) | represents the tenant in house; files contact reports; approves brand terms; sets Monvelo settings; keeps the catalogue | [1c] |
| Logistics manager | Teafair, reports to the CSM | `LOGISTICS_MANAGER` | dispatches stock, confirms courier deliveries, records stock movements | [1c] |
| Tenant admin | the brand | `TENANT_ADMIN` | **reads only**: contact reports, settlements, ledger, Monvelo book, reports | [1c] |
| Zonal Sales Manager | **Teafair**, oversees one or more zones (a zone is a state) across several brands | `ZSM` | reviews contact reports before their hard copy is uploaded; proposes brand terms; invites field staff | [Built] |
| Territory Manager | Teafair | `TM` | approves requests above a shop's limit; sets supply days; handles day-45 escalations | role [Built]; duties [Step 2]/[Step 4] |
| Zonal / Area Sales Agent | Teafair | `ZSA`, `ASA` | street level: recruits shops and agents, raises financing requests | [Built] |
| POS agent (lender) | their network | member of `monvelo_agents` via `monvelo_agent_members` | pledges, claims, funds, records repayments | [Built] (registration); lending [Step 2]+ |
| Shop owner | the shop | `RETAIL_SHOP_OWNER` | consents to enrolment; confirms delivery and each repayment by WhatsApp code | [Built] (consent); confirmations [Step 4] |

Tenants never choose, link to or approve agents. That is the operator's job alone.

**Teafair operates state by state.** A platform admin switches each state on for the Teafair app and for Teafairweb as Teafair becomes fully operational there; each brand then opts in to the platform-active states it distributes and lends in, through a cited `DISTRIBUTION` decision. New orders, enrolments, supply days, pledges and financing requests need both switches on; orders already placed always continue (A6 §18.4).

**The whole field force is Teafair staff** (A6 §17): ZSM, TM, ASM, ZSA and ASA. A person working on several brands holds one membership per brand. **Each zone is a Nigerian state**, and one ZSM can cover several zones, across brands (`zones.zsm_id`). The brand's own people only read (`TENANT_ADMIN`).

## 4. How the app talks to the backend

```
Android app ──▶ Edge Function (Deno) ──▶ Postgres RPC (SECURITY DEFINER) ──▶ tables
               JWT, input checks,        one transaction: idempotency key,
               Paystack / WhatsApp       live role check, writes, audit row
```

- **Reads** go straight to the tables. Row-level security lets each person read only their own rows.
- **Writes** go only through RPCs. Each takes a client-generated `p_idempotency_key`, so a retried request never runs twice.
- **The tenant** always comes from the signed-in user's token, re-checked against `tenant_users`. The app never sends it.
- **Messages** (WhatsApp now, email later) go through the A5 message router and are logged in `notification_logs`.

---

## 5. The processes, step by step

Each process lists: **who** → **what they do** → **what the backend does** →
**what changes**.

### P1. Setting up a tenant's service team [1c]

1. A Teafair platform administrator appoints the CSM for a tenant.
   - **Backend:** `appoint_client_service_manager` adds a `tenant_users` row (role `CLIENT_SERVICE_MANAGER`).
   - A CSM serving several brands has one membership in each.
2. The CSM invites the brand's `TENANT_ADMIN` login(s) and Teafair's `LOGISTICS_MANAGER` for that brand.
   - **Backend:** `invite_tenant_user`. The logistics manager's `reports_to_id` is the CSM.
3. ZSMs keep inviting their field teams (TM, ZSA, ASA, …) as today.
   - **Backend:** `invite_tenant_user` [Built].

### P2. A meeting with the brand: the contact report [1c]

The contact report is the **source of truth** for everything agreed with the brand.

1. After a meeting or call, the CSM files a report. It holds the date, channel, attendees, a summary, and one line per decision, each with a subject (brand terms, Monvelo settings, catalogue, stock, other).
   - **Backend:** `file_contact_report` writes `contact_reports`, `contact_report_decisions` and `contact_report_recipients`.
2. **A ZSM reviews the report.** Any active ZSM of the tenant approves it, or rejects it saying what must be corrected. If the tenant has no active ZSM, the Monvelo operator reviews instead.
   - **Backend:** `review_contact_report` writes `contact_report_reviews` (one per report, insert-only).
   - A rejected report is corrected by a new report that supersedes it, and is reviewed again.
3. **The signed hard copy, after the ZSM's approval.** The CSM scans or photographs the signed paper report and uploads it (PDF, JPEG or PNG, up to 10 MB).
   - **Backend:** the `contact-report-upload` gateway calls `request_contact_report_hard_copy` and returns a one-time upload URL.
   - The app uploads the file into the private `contact-reports` bucket, then `attach_contact_report_hard_copy` checks it is there.
   - **Until the report is ZSM-approved and its hard copy attached, none of its decisions can be cited.**
   - One copy per report; it is never replaced or deleted.
4. Each recipient gets one `contact_report_deliveries` row (PENDING). Copies go out only after the hard copy is attached.
   - The actual WhatsApp or email copy is sent from **[Step 6]**, once its template is approved.
5. The brand's `TENANT_ADMIN` reads the report, and downloads its hard copy, in the app.
6. A mistake is corrected by filing a new report that supersedes the old one.
   - Reports are insert-only: never edited or deleted.
   - The old report's decisions can no longer be cited.

### P3. Agreeing the brand's financing terms [Built]; CSM approval [1c]

1. In the meeting, the brand agrees its terms per brand: rebate (e.g. 10%), interest-free days (30) and late charge (10%), with start and end dates. The CSM records the decision (P2).
2. A ZSM proposes the terms.
   - **Backend:** `propose_monvelo_brand_terms` creates a `monvelo_brand_terms` row (PROPOSED).
3. The CSM approves them, citing the contact-report decision.
   - **Backend:** `approve_monvelo_brand_terms(…, p_decision_id)` sets the row to APPROVED.
   - No sale can use a brand until its terms are APPROVED.
   - *Bridging rule:* while a tenant has no CSM, a second, different ZSM approves. **Every approval, bridging included, must cite a ZSM-approved contact-report decision with its signed hard copy**, so the brand's agreement is always on record.
4. The CSM (or a ZSM while the tenant has no CSM) sets the tenant's Monvelo switches: enabled, opening limit, maximum limit, approval cap. **Each change must cite a ZSM-approved, hard-copied decision.**
   - **Backend:** `set_monvelo_tenant_settings` writes `monvelo_tenant_settings`.
5. Teafair's own fee for the tenant is recorded by the operator, citing the `FEES` decision of the contact report that agreed it.
   - **Backend:** `record_monvelo_fee_terms` writes `monvelo_tenant_fee_terms` [Built; the citation comes in 1c].
6. Withdrawing brand terms also cites a decision.

**No backdoors.** No risk, financial or commercial setting of a brand (terms, limits, late charge, fees, catalogue, stock) changes without a cited decision from a ZSM-approved contact report with its signed hard copy. A test scans the database to keep it that way.

### P4. Catalogue and stock [1c]

1. Product changes agreed with the brand: the CSM updates the catalogue, citing a decision.
   - **Backend:** `upsert_catalogue_product` writes `central_products`.
2. Stock arrives, moves or is corrected: the logistics manager records a receipt, a transfer or an adjustment, citing a decision.
   - **Backend:** `record_stock_receipt`, `record_stock_transfer` and `record_stock_adjustment` write `inventory_batches`, plus an insert-only `stock_movements` row.
   - Stock can never go negative.

### P5. Recruiting a POS agent [Built]

1. A ZSA or ASA meets a POS agent and registers the business: name, network, network agent id, location, and settlement bank account.
   - **Backend:** the `monvelo-agent-register` gateway asks Paystack to resolve the account name, then calls `register_monvelo_agent`.
   - This creates a `monvelo_agents` row (PENDING), holding only the account's last 4 digits for reading.
   - The same network agent cannot be registered twice.
2. The operator checks and approves the agent, and sets daily and per-financing caps.
   - **Backend:** `approve_monvelo_agent` and `set_monvelo_agent_caps`.
   - `suspend_monvelo_agent` stops an agent.
3. The agent's staff get logins.
   - **Backend:** `add_monvelo_member` writes `monvelo_agent_members`.
4. A payout account change is requested by the recruiter and approved by the operator.
   - **Backend:** `request_monvelo_settlement_change` and `approve_monvelo_settlement_change`.

The networks have already done KYC on their agents, so Teafair does no duplicate KYC.

### P6. Enrolling a shop, with the owner's consent [Built]

1. A ZSA or ASA starts the enrolment for a shop in their area.
   - **Backend:** the `monvelo-shop-consent` gateway calls `start_monvelo_consent`.
   - A code goes by WhatsApp to the owner's **verified** phone.
2. The owner reads the consent text (version `MV-SHARE-2026-10`) and gives the code to the agent.
   - **Backend:** `enrol_monvelo_shop` writes `monvelo_shop_enrolments` (ACTIVE).
   - The enrolment records the consent version and challenge, and the shop gets its code (`monvelo_assign_shop_code`).
3. The owner may name a preferred POS agent.
   - **Backend:** `nominate_monvelo_agent` writes `monvelo_agent_nominations`.
   - When the agent is recruited, `close_monvelo_nomination` closes the nomination.
4. The owner can withdraw at any time.
   - **Backend:** `withdraw_monvelo_shop_consent` sets the enrolment to WITHDRAWN.

### P7. The supply day and pledges [Step 2]

1. The TM sets which days are supply days for an area.
   - **Backend:** `set_monvelo_supply_day` writes `monvelo_supply_days`.
2. The evening before, agents near the area see totals only: number of shops and expected demand.
   - **Backend:** `monvelo_supply_days_near` (a read). The WhatsApp notice follows in [Step 6].
3. Agents pledge how much they are ready to fund that day.
   - **Backend:** `pledge_monvelo_funds` writes `monvelo_pledges`.

### P8. A shop asks for stock on credit [Step 2]

1. The ZSA or ASA places the trade order: shop code, plus lines in whole packs at wholesale price. **The stock is reserved at once** in the fulfilment warehouse; if there isn't enough, the order is refused.
   - **Backend:** `place_trade_order` creates an `orders` row (channel `FIELD_SALES`) and its `order_items`, fulfilled from the territory's regional warehouse.
2. They ask for Monvelo financing on that order.
   - **Backend:** `request_monvelo_financing` creates `monvelo_financings` and one `monvelo_financing_lines` row per brand.
   - **Checks** (A6 §7.2): the shop is enrolled; the owner's phone is verified; the shop has a GPS pin; today is a supply day; the brand's terms are APPROVED; the amount fits the shop's limit for that brand (`monvelo_shop_limits`).
   - **Result:** within the limit, the status becomes **OFFERED**. Above it, **AWAITING_APPROVAL**.
3. Above the limit, the TM of the shop's territory approves.
   - **Backend:** `approve_monvelo_financing` moves it to OFFERED.
   - The raiser or the TM can cancel before funding: `cancel_monvelo_financing`.

### P9. An agent claims the offer [Step 2]

1. **The first 10 minutes** belong to the shop's preferred agent.
2. **After that**, the first agent with a pledge who claims gets it. The agent must be within the radius and within their caps and remaining pledge.
   - **Backend:** `claim_monvelo_financing` locks the row and writes `monvelo_financing_claims`. The financing becomes **CLAIMED**, with **15 minutes to pay**.
   - Agents see what is open through `monvelo_open_offers`.
3. **An unpaid claim lapses** back to OFFERED, and that agent cannot reclaim it.
   - At the end of the supply day, anything unclaimed becomes **EXPIRED**.
   - **Backend:** `monvelo_sweep_offers`, run every minute by the cron job `monvelo-offer-sweep`.

Staff can find agents near a shop with `monvelo_agents_near`. It returns distances, never phone numbers.

### P10. The agent pays [Step 3]

1. The agent pays the principal through Paystack, from their own registered account.
   - **Backend:** the `monvelo-fund` gateway starts the payment (reference `MV-…`).
2. Paystack confirms the payment.
   - **Backend:** `process-payment` verifies it server-side and checks that the payer is the agent's own account. It then calls `settle_monvelo_funding`, which in one transaction:
     - makes the financing **FUNDED**;
     - locks each line's terms;
     - reduces the pledge;
     - creates the rebate payable (due within 24 h) [Step 5];
     - writes the ledger entry `FUNDED_GROSS` [Step 5].
3. The agent is told straight away: "₦4,800 rebate confirmed".
4. Payment from someone else's account is not accepted.
   - The financing stays CLAIMED, a fraud flag is raised, and the money is refunded through the D1 refund path.

### P11. Getting the stock to the shop [1c] / [Step 4]

1. The logistics manager (or a ZSM or the warehouse's manager) dispatches the order. **The reserved stock is deducted** from the warehouse at that moment. A cancelled order releases its reservation; goods that come back after dispatch are restored with `record_order_return`.
   - **Backend:** the `order-dispatch` gateway calls `mark_order_dispatched` (A5).
2. The shop owner confirms receipt with a WhatsApp code. That makes the financing **DELIVERED**, and the 30 days start.
   - **Backend:** `monvelo-confirm-delivery` calls `confirm_monvelo_delivery` [Step 4].
3. **Not delivered by 23:59 the same day** means **REFUND_DUE**. Teafair refunds the agent and no rebate is owed.
   - If the rebate was already paid, it is taken off the agent's next rebate.

### P12. Repayment [Step 4]

1. The shop repays the agent at their terminal, in parts if it likes.
   - The agent records each payment: `record_monvelo_repayment`.
   - The owner confirms each one by code: `monvelo-confirm-repayment` calls `confirm_monvelo_repayment`.
2. **Reminders** go out on day 25 and day 30.
3. **Repaid in full by the due date:** the financing is **REPAID_WITHIN_WINDOW**, and the shop's limit for that brand rises by the brand's own growth rate (if it has set one), up to its maximum (`monvelo_shop_limit_events` records the change).
4. **Not repaid by day 30:** a 10% late charge is added once, on day 31, and the financing is **DEFAULTED_WITH_LATE_CHARGE**.
   - **The shop gets no new Monvelo credit from any brand on the platform** until it clears the default (platform hard freeze).
   - After it clears, each brand's own cure period and post-default limit apply.
   - On day 45 the case goes to the TM.
   - Paying in full afterwards gives **REPAID_LATE**.
5. **An owner who rejects a recorded repayment** opens a dispute ticket in the support system (A3, `support_tickets`).

### P13. Paying the agent's rebate [Step 5]

1. The finance officer pays the rebate from Teafair's account on the agent's own network, for the exact amount, and records the transfer reference.
   - **Backend:** `record_rebate_payout` updates `monvelo_rebate_payables`.
   - **Above the approval cap**, a second finance officer must approve: `approve_rebate_payout`.
   - The ledger gets a `REBATE` entry.
2. The agent is told "Paid, ref …".
3. **Not paid within 24 hours:** the payable becomes OVERDUE and shows on the finance dashboard.

### P14. Settling with the brand [Step 5]

1. Each day, for each tenant, Teafair works out:
   - **gross**: principal funded and delivered;
   - **rebates**: rebates paid;
   - **fees**: gross × the fee terms valid that day;
   - **net** = gross − rebates − fees.
2. **Backend:**
   - every money event has already written an insert-only row in `monvelo_tenant_ledger_entries`: `FUNDED_GROSS` (+), and `REBATE`, `FEE`, `REFUND`, `REMITTANCE` (−);
   - `monvelo_tenant_settlements` holds the daily totals and must equal the ledger.
3. Teafair transfers the net to the brand off-app. The finance officer notes the reference.
   - **Backend:** `record_tenant_remittance`.
4. The brand's `TENANT_ADMIN` and the CSM read the statement and the ledger behind it.

### P15. Reports [Step 6]

| Report | To | When |
|---|---|---|
| Supply-day notice (totals only) | agents near the area | 18:00 the evening before |
| New offer | preferred agent, then pledged agents | when a request is OFFERED |
| Rebate confirmed / paid | the funding agent | at funding / at payout |
| Daily summary, weekly statement | each active agent | 19:00 daily; Monday 08:00 |
| Repayment reminder, late charge | shop owner (and funder for the late charge) | day 25, 30, 31 |
| Tenant daily and weekly reports | the tenant's ZSMs and CSM; the tenant's contacts in copy | 19:30 daily; Monday 08:30 |
| Contact-report copies | the tenant's contacts | when filed (P2) |

### P16. Support and problem handling

| Problem | Who handles it | How | Status |
|---|---|---|---|
| A question from the brand, or a change it wants | CSM | a meeting or call, then a contact report (P2); the change cites the decision | [1c] |
| Agent registration, caps, suspension, payout account | Monvelo operator | P5 RPCs | [Built] |
| Payment from the wrong account, double payment | system, then operator | automatic refund and a fraud flag (P10) | [Step 3] |
| Stock not delivered the same day | system, then logistics | REFUND_DUE sweep at 23:59 (P11) | [Step 4] |
| Owner disputes a repayment | TM, via the support desk | A3 support ticket (P12) | [Step 4] |
| Overdue shop | TM | reminders, late charge, day-45 escalation (P12) | [Step 4] |
| Rebate late | finance officer | OVERDUE payables on the dashboard (P13) | [Step 5] |
| Suspicious patterns | Monvelo operator | `review_monvelo_flag`, for example an agent winning 80% of a defaulting shop's financings, or very fast repeat financings | [Step 8] |
| Owner withdraws consent | system | `withdraw_monvelo_shop_consent` (P6) | [Built] |

---

## 6. The financing's life

```
REQUESTED ──(within limit)──────────────▶ OFFERED
REQUESTED ──(above limit)─▶ AWAITING_APPROVAL ──TM approves──▶ OFFERED
OFFERED ──agent claims──▶ CLAIMED ──Paystack verified──▶ FUNDED
CLAIMED ──15 min, no payment──▶ OFFERED (next agent)
OFFERED / AWAITING_APPROVAL ──end of supply day──▶ EXPIRED
FUNDED ──owner's code──▶ DELIVERED ──repaid by due date──▶ REPAID_WITHIN_WINDOW
DELIVERED ──due date passes, money owed──▶ DEFAULTED_WITH_LATE_CHARGE ──repaid──▶ REPAID_LATE
FUNDED ──not delivered by 23:59──▶ REFUND_DUE
REQUESTED / AWAITING_APPROVAL / OFFERED ──cancelled──▶ CANCELLED
```

Anyone allowed to see an order can ask where its financing stands through
`monvelo_order_financing_status` [Step 2].

## 7. Who can see what

| Person | Can read |
|---|---|
| ZSA / ASA | their own area's enrolments and requests; agent business details (no bank account numbers) |
| TM / ZSM | their territory's / zone's Monvelo book |
| CSM | everything for the tenants they serve: contact reports, terms, settlements, ledger |
| TENANT_ADMIN | the tenant's contact reports, settlements, ledger, Monvelo book, reports |
| LOGISTICS_MANAGER | FUNDED financings awaiting delivery; warehouses and stock |
| POS agent members | their own agent, pledges, claims, financings |
| Shop owner | their own shop and enrolment |
| Monvelo operator / finance | everything Monvelo |

Nobody else reads buyer contact details (A2). No tenant role sees agents' pledges or claims.

## 8. From the v1 proposal to the real schema

| v1 name | Real name | Why |
|---|---|---|
| `shops`, `is_monvelo_enabled` | `retail_shops`, `monvelo_shop_enrolments` | one shared shop registry; enrolment is per tenant and records consent |
| `tenant_shop_registrations` | `monvelo_shop_limits` (+ `_events`) | limits per brand; no credit score until legal review |
| `products`, `warehouse_stock`, `deliveries` | `central_products`, `inventory_batches` + `stock_movements`, `order_fulfilments` | existing tables |
| `inventory_loans` | `monvelo_financings` + `monvelo_financing_lines` | terms locked per brand |
| `interest_subsidies` | `monvelo_rebate_payables` | the subsidy *is* the rebate |
| `tenant_ledger_transactions` | `monvelo_tenant_ledger_entries` | no prepaid pool; deduct before remitting |
| `fintech_partners`, `monvelo_agent_tenants` | none | agents carry their network; only the operator links agents |
| `SALES_REP` / `FIELD_ZSM` | ZSA, ASA (street); ZSM, TM (approve) | the existing sales structure |
| `FINTECH_AGENT` | POS agent member of `monvelo_agents` | `POS_AGENT` is the web role |
| subscription status | none | out of scope |

## 9. Build order

| Step | Delivers | State |
|---|---|---|
| Step 1 | roles ZSA/ASA, areas, agent recruitment, shop enrolment and consent, nominations, tenant settings, brand terms, fee terms | **[Built]** |
| Renames | web and Monvelo domains separated; `monvelo_agents`, `monvelo_agent_members` | Tasks 1–6 **[Built]**; Task 7 (docs, full check) in progress |
| 1c | CSM, TENANT_ADMIN, LOGISTICS_MANAGER; contact reports with ZSM review and signed hard copy; CSM approvals; catalogue and stock movements | planned (`docs/superpowers/plans/2026-10-29-monvelo-step1c-step2.md`) |
| 1d | zones are states; a Teafair ZSM covers several zones across brands (A6 §17) | planned (same plan) |
| 2 | supply days, pledges, trade orders, financings, limits, request, approval, claim, sweep, status read, proximity, ledger table | planned (same plan) |
| 3 | funding through Paystack | planned |
| 4 | delivery and repayment codes, disputes, refunds, late charge, escalation | planned |
| 5 | rebate payables and payouts, tenant settlements, ledger writers | planned |
| 6 | WhatsApp templates and scheduled jobs (incl. contact-report copies) | planned |
| 7 | finance dashboard | planned |
| 8 | fraud flags, PAR30 rule, field incentives, full end-to-end run, deploy notes | planned |

## 10. Open before launch

- **Shops' credit** is the brand's own rule: its opening limit, maximum limit, approval cap and limit growth, set through cited contact-report decisions. Teafair imposes no cash-order threshold (user, 2026-10-30).
- **Legal review:** lender of record, the late charge, the consent wording (NDPA), AML record keeping, and any credit score.
- **Templates:** Meta approval of the WhatsApp templates, and Resend live for email.
