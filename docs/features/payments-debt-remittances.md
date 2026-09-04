# Payments, debt & remittances

**Spec:** §5.8, §3.4

## Purpose

Customer debt to TEFAIR, informal-rep consignment cash owed to TEFAIR, and
guarantor capture for credit stock.

## Tables

- `outlet_guarantors` — see
  [onboarding-and-verification](onboarding-and-verification.md). At least one
  `ACTIVE` guarantor is required before any `CASH_AGENT` / `FINTECH_FINANCED`
  order (integrity layer 6). The customer is liable for stock collected; the
  guarantor backs that liability.
- `payments` — INSERT-only. `outlet_id`, `order_id?`, `amount` (`> 0`), `channel`
  (`payment_channel`), `method`, `reference`, `received_by`, `verified_by?`,
  `occurred_at`, `idempotency_key` (unique).
- `remittances` — INSERT-only. Informal-rep depot cash paid to TEFAIR.
  `warehouse_id`, `amount` (`> 0`), `method`, `reference`, `recorded_by`,
  `verified_by?`, `idempotency_key`.
- `outlet_balances` — cache, PK `outlet_id`. `total_invoiced`, `total_paid`,
  `balance` (generated), `open_invoice_count`. **A `FINTECH_FINANCED` order does
  not raise this** — the customer's debt is to the Fintech.
- `consignment_balances` — cache, PK `warehouse_id`. `stock_value_held`,
  `cash_owed`, `remitted_to_date`, `debt_limit`.
- `customer_ledger` — INSERT-only. `entry_type` (`INVOICE|PAYMENT|DEFAULT|
  ADJUSTMENT|FINANCED`), signed `amount`, `reference_type`/`reference_id`.
- `customer_credit_profile` — cache. `credit_limit` (manual), `outstanding_balance`,
  open/completed/defaulted invoice counts, `on_time_rate`. **No algorithmic score
  at launch.**

## RPCs

- `record_payment(outlet_id, order_id, amount, channel, method, reference, idempotency_key)`
  — FIELD_AGENT/WAREHOUSE_MANAGER; `payments` + `customer_ledger` `PAYMENT` +
  `outlet_balances`.
- `verify_payment(payment_id)` — ADMIN/AUDITOR (against the bank statement).
- `record_remittance(warehouse_id, amount, method, reference, idempotency_key)` —
  INFORMAL_REP/WAREHOUSE_MANAGER; `remittances` + reduces
  `consignment_balances.cash_owed`.
- `verify_remittance(remittance_id)` — ADMIN/AUDITOR.

## Jobs

- `reconcile_financials()` — nightly: ledger vs `outlet_balances` /
  `consignment_balances` / `customer_credit_profile`, alert on drift.
- `flag_consignment_overexposure()` — reps near/over `debt_limit` → alert.

## Screens

- INFORMAL_REP dashboard leads with the **cash-owed-vs-limit gauge**;
  Remittances screen records payments to TEFAIR.
- FIELD_AGENT: Record payment, Payment history; Outlet detail shows balance +
  guarantors.
- ADMIN Finance dashboard: payment + remittance verification queues.
