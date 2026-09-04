# Alerts & fraud

**Spec:** §5.10, §6.2, §3.4

## Purpose

Anomalies are pushed to HQ as `alerts` by nightly batch jobs and by RPCs —
nothing runs per-write. HQ works exceptions, not everything.

## Table

- `alerts` — `alert_type`, `severity` (`alert_severity` enum:
  `INFO/WARNING/CRITICAL/EMERGENCY`), `market_zone_id?`, `warehouse_id?`,
  `fintech_agent_id?`, `outlet_id?`, `title`, `message`, `context` (small jsonb),
  `status` (`OPEN/ACKNOWLEDGED/RESOLVED`), `acknowledged_by?`, `resolved_by?`,
  `auto_resolved`.

## RPCs

`acknowledge_alert(alert_id)` / `resolve_alert(alert_id, note)` — role-appropriate
to the alert's scope.

## Fraud rules (nightly `run_fraud_scans()` → `alerts`)

| Rule | Trigger |
|---|---|
| Default rate | fintech agent's rolling default rate > 5% |
| Volume cap | fintech agent > 10 new financing deals in a day |
| Repayment pattern | repayment events clustered unnaturally |
| Zone match | deal's outlet / fintech / agent not all in one zone |
| Collusion | same (fintech agent, outlet) pair above a frequency threshold |
| Self-dealing | fintech agent's phone/name matches an outlet contact or guarantor on a deal they financed |
| Depot silent | no `depot_checkins` for a consignment depot in `heartbeat_grace_hours` |
| Cell drift | verification/checkin `cell_id` not in `location_cell_observations` after warm-up |
| GPS spoof pattern | verification GPS identical to the pre-registered point to > 5 decimals, repeatedly |

## Other alert sources

Reconciliation drift jobs (`reconcile_stock_balances`, `reconcile_financials`),
`flag_consignment_overexposure`, `flag_stale_financing`,
`expire_pending_verifications` (SLA breach), low-stock.

## Screens

- COMPLIANCE_OFFICER "Review Queue" dashboard groups fraud alerts by agent/pair
  alongside `NEEDS_REVIEW` verifications.
- REGIONAL_MANAGER / ADMIN alert centres, scoped.
- Field roles: their own scoped alerts, acknowledge only.

## Config

Thresholds live in an `alert_config` table + per-zone `verification_config`,
ADMIN-editable.
