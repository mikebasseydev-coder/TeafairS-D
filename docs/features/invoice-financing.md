# Invoice financing ("Micro / Invoice Discount")

**Spec:** §5.9, §3.4, §3.5

## Model — TEFAIR never carries principal

1. Field agent issues an invoice for **₦X** (an order's total) to a customer who
   is liable and has a named guarantor.
2. Fintech agent pays TEFAIR **₦X in full**, immediately; finance verifies it
   landed (`verify_fintech_funding`). TEFAIR is now out of the transaction.
3. Customer repays **the Fintech** ₦X on any schedule (proximity cash
   collection). TEFAIR only records repayment events.
4. **Successful repayment** → TEFAIR pays the Fintech a fee: the negotiated
   `fee_rate` % of ₦X, field-agent-negotiated, **capped at 10%**.
5. **Default** (Fintech declares bad debt) → TEFAIR pays the Fintech a flat
   **10%** of ₦X as compensation ("cost of money"). The Fintech absorbs the
   remaining ~90% and pursues customer + guarantor.
6. `fee_basis` on the invoice records `SUCCESS` or `DEFAULT`; the invoice ends
   `FEE_PAID`.

**Indemnity** (accepted at fintech signup) + **guarantor** (per credit order)
are what keep TEFAIR's loss to the capped fee.

## Tables

- `fintech_agents` / `fintech_agent_stats` — see
  [onboarding-and-verification](onboarding-and-verification.md).
- `invoice_financings` — `invoice_number` (unique), `order_id` (unique),
  `outlet_id`, `sales_agent_id`, `fintech_agent_id`, `market_zone_id`,
  `guarantor_id`, `invoice_total`, `fintech_funding_amount` (= total),
  `fee_rate` (`> 0 AND <= 10`), `success_fee_amount` (generated),
  `default_fee_amount` (generated, `total * 0.10`), `status` (`PENDING/FUNDED/
  COLLECTING/REPAID/FEE_PAID/DEFAULTED/DISPUTED/CANCELLED`), `invoice_date`,
  `expected_repayment_date` (`+45d`, soft), funding + repayment + default + fee
  timestamps/refs, `fee_basis?`, `fee_paid_amount?`.
- `invoice_financing_events` — INSERT-only ledger. `event_type`
  (`financing_event_type`), `amount?`, `reference?`, `actor_id`, `pin_verified`,
  `idempotency_key`. Parent `status` is derived by the RPC writing the event.
- `fintech_adjustments` — rare manual `CORRECTION`/`BONUS`/`REFUND` only.

## RPCs

`create_invoice_financing` (FIELD_AGENT, `fee_rate <= 10`) → `accept_invoice_financing`
(FINTECH, **requires in-app terms acknowledgement** — the app must show the
risk/terms panel and record the version) / `decline_invoice_financing` →
`record_fintech_funding` (amount must equal the full total) → `verify_fintech_funding`
(ADMIN/AUDITOR) → `record_customer_repayment` ×N (FINTECH, PIN) → `REPAID` →
`process_fintech_fee` (ADMIN — pays `success_fee_amount` or, from `DEFAULTED`,
`default_fee_amount`). Also `declare_default` (FINTECH; ADMIN override),
`dispute_invoice_financing`, `resolve_financing_dispute`, `post_fintech_adjustment`.

## Realtime & notifications

- The **one** realtime channel: FINTECH_AGENT ← their own `invoice_financings`
  rows (new offers, status changes).
- Notifications: offer received, funding verified, repayment milestone, fee paid,
  dispute — see [notifications](notifications.md).

## Jobs

- `flag_financing_fees_due()` — nightly: `REPAID`/`DEFAULTED` with no
  `fee_paid_at` → ADMIN fee queue.
- `flag_stale_financing()` — nightly: `COLLECTING` past
  `expected_repayment_date` → alert (the Fintech decides whether to default).

## Open questions

- §13.1 — default fee always flat 10%, or the negotiated rate?
- §13.2 — SLA / automation on `process_fintech_fee`?
