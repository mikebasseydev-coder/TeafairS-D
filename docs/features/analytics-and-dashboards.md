# Analytics & dashboards

**Spec:** §5.11, §8, §3.4

## Purpose

Every dashboard reads a **cache table** refreshed by `pg_cron`. No live views, no
aggregation over raw tables — this is the core cost lever.

## Cache tables

- `daily_sales_rollup` — `summary_date` × `market_zone_id?` × `warehouse_id?` ×
  `agent_id?`: `order_count`, `gross_revenue`, `cash_collected`,
  `financed_volume`. Unique grouping key with `COALESCE(dim, '00…0')`.
  `run_daily_rollup()` nightly + hourly for the current day.
- `zone_health` — PK `market_zone_id`: `warehouse_count`, `outlet_count`,
  `active_agents`, `stock_value`, `outlet_debt`, `debt_utilization_pct`,
  `consignment_owed`, `open_alerts`. `refresh_zone_health()` every 20 min.
- `fintech_program_health` — one row per zone + a global row: `active_agents`,
  `total_financed_volume`, `total_fees_paid`, `fees_due`,
  `fintech_outstanding_debt`, `default_rate`, `avg_repayment_days`,
  `disputes_open`. `refresh_fintech_stats()` every 30 min.
- `fintech_agent_stats`, `outlet_balances`, `consignment_balances`,
  `customer_credit_profile` — RPC-maintained caches also read by dashboards.

## Dashboards by role (spec §8 has the full screen tables)

| Role | Dashboard | Reads |
|---|---|---|
| FIELD_AGENT | "My Day" | `daily_sales_rollup` (agent), `alerts`, `outlet_balances` |
| INFORMAL_REP | "Depot & Field" | `consignment_balances`, `stock_balances`, `inventory_transfers` |
| WAREHOUSE_MANAGER | "Warehouse Overview" | `stock_balances`, `inventory_transfers`, `stock_counts`, `alerts` |
| FINTECH_AGENT | "Fees & Repayments" | `fintech_agent_stats` |
| REGIONAL_MANAGER | "Regional Health" | `zone_health`, `daily_sales_rollup`, `fintech_program_health` |
| ADMIN | "Company Overview" / "Fintech Program" / "Finance" | global cache tables + queues |
| COMPLIANCE_OFFICER | "Review Queue" | `*_verifications`, `alerts` |
| AUDITOR | "Reconciliation" / "Compliance" | ledger-vs-cache diffs, `audit_logs` |

HQ dashboards poll their cache tables on an interval.

## Rule

Adding a new metric follows the same pattern: a column on a cache table + logic
in the refresh job. Never compute it live on read.
