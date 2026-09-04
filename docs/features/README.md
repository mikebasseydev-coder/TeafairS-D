# TEFAIR feature docs

One reference per feature, derived from
`docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md` (the
authority on cross-feature rules). Each doc lists the feature's tables, RPCs,
screens by role, invariants, scheduled jobs, and open questions, with the spec
section it derives from.

Use these as the brief when writing an implementation plan for a feature. The
spec still governs anything that spans features.

| Doc | Spec § | Summary |
|---|---|---|
| [roles-and-access](roles-and-access.md) | §4, §9 | 9 roles, `profiles` = `auth.users.id`, RLS helper pattern, MFA |
| [onboarding-and-verification](onboarding-and-verification.md) | §5.3, §7 | register + HQ-verify outlets, guarantors, fintech agents, staff |
| [catalog-and-pricing](catalog-and-pricing.md) | §5.3 | `products`, server-owned prices |
| [inventory](inventory.md) | §5.4, §5.7 | append-only `inventory_movements` + `stock_balances` / `consignment_balances` caches, counts, adjustments |
| [orders](orders.md) | §5.5 | two-stage orders, `order_items`, delivery |
| [transfers](transfers.md) | §5.6 | dual-party transfers, verification, disputes, reconcile |
| [invoice-financing](invoice-financing.md) | §5.9 | fintech agents, financing deals, funding, repayment, fee, indemnity |
| [payments-debt-remittances](payments-debt-remittances.md) | §5.8 | `payments`, `remittances`, `outlet_balances`, `customer_ledger`, guarantors |
| [location-delivery-verification](location-delivery-verification.md) | §6.3, §5.13 | tier ladder, signal bundles, depot check-ins, cell learning, review queue |
| [alerts-and-fraud](alerts-and-fraud.md) | §5.10, §6.2 | `alerts`, the fraud rules, nightly scans |
| [notifications](notifications.md) | §5.12 | polled in-app inbox, SMS escalation, push fast-follow |
| [analytics-and-dashboards](analytics-and-dashboards.md) | §5.11, §8 | cache tables, per-role dashboards |
| [audit-and-reconciliation](audit-and-reconciliation.md) | §5.10, §6.1 | `audit_logs` trigger, nightly reconciliation, HQ see-through |

## Conventions every feature follows

- Writes are `SECURITY DEFINER` RPCs, idempotent on `p_idempotency_key`. Tables
  grant `authenticated` SELECT only.
- Ledgers are INSERT-only; balances are RPC-maintained caches reconciled nightly.
- Dashboards read cache tables; no live views.
- RLS uses `(select auth.uid())` + `private.*` helpers.
- Workflow statuses are `text` + `CHECK`; stable sets are enums.
