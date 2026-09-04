# Audit & reconciliation

**Spec:** §5.10, §6.1, §3.4

## Purpose

How HQ "sees through" to the field without being there: independent evidence
trails that would all have to be forged in concert to fake.

## Tables

- `audit_logs` — INSERT-only, written by a generic `SECURITY DEFINER` trigger on
  sensitive tables. `table_name`, `record_id`, `action`, `actor_id`, `diff`
  (jsonb), `occurred_at`. Read: `ADMIN`, `SUPER_ADMIN`, `AUDITOR`,
  `COMPLIANCE_OFFICER`. Writable by no one.
- The append-only ledgers are the spine: `inventory_movements`, `payments`,
  `remittances`, `customer_ledger`, `invoice_financing_events`,
  `*_verifications`. No UPDATE/DELETE policy — corrections are compensating rows.

## HQ assurance mechanisms

1. **The ledger is the source of truth** — dashboard numbers derive from it, not
   from anything typed. Prices/totals are server-computed; balances are
   `SUM(ledger)`; photos/GPS/signatures are captured artifacts.
2. **Reconciliation drift = tripwire** (AUDITOR "Reconciliation" dashboard):
   - `stock_balances` vs `SUM(inventory_movements)` — `reconcile_stock_balances()`
   - `outlet_balances` / `consignment_balances` vs `customer_ledger` +
     `remittances` — `reconcile_financials()`
   - `invoice_financing_events` sums vs `invoice_financings`
   - funding claimed vs verified
   Zero drift = books self-consistent and nothing touched outside an RPC.
3. **See-through bundle** — every field transaction has a `*_verifications` row:
   the actual photo, GPS distance, cell id, tier, signature. Dual-party where it
   matters (transfers: sender + receiver; `reconcile_transfer` compares qty).
4. **Confirmation gates** — value doesn't flow until an HQ user confirms with
   evidence: `verify_outlet` / `verify_guarantor` / `verify_fintech_agent`,
   `verify_fintech_funding`, `verify_payment` / `verify_remittance`,
   `review_stock_count`, `process_fintech_fee`.
5. **Anomalies come to HQ** — nightly scans + drift + SLA breaches write
   `alerts`; `audit_logs` catches anyone (including an admin) changing a row.

## Jobs

`reconcile_stock_balances()`, `reconcile_financials()`, `run_fraud_scans()` —
nightly.

## Note for the spec

Spec §2 (success criteria) covers this; a dedicated "§2.1 How HQ sees through"
section consolidating the five mechanisms was proposed and not yet added.
