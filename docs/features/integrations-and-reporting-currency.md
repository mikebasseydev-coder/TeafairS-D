# Integrations & reporting currency

**Spec:** platform §5.15, §3.3, §3.4, §11; architecture §8

## Currency

**Internal money is NGN, single currency — the transactional schema does not
change.** USD is **reporting-only**, derived at report / sync time.

- `fx_rates` — `quote_currency` (`USD`), `rate` (NGN per 1 USD),
  `effective_date`, `source` (`CBN|MARKET`), `recorded_by`.
  `UNIQUE(quote_currency, effective_date, source)`.
- `set_fx_rate(quote_currency, rate, effective_date, source)` — `ADMIN`. An
  automated CBN/market pull is a fast-follow.
- HQ dashboards/reports carry an **NGN/USD display toggle** — multiply cache-table
  figures by the period rate. `integration_config` picks the source and
  period-end vs period-average.

## Outbound integration framework (in the launch schema)

RPCs that create financial events enqueue a sync record — same pattern as
`notifications_outbox`. The framework tables ship at launch even though the
connectors don't, because retrofitting an outbox across every financial RPC later
is painful.

- `integration_outbox` — INSERT-only. `target` (`FIRS|QUICKBOOKS|PAYROLL|…`),
  `entity_type`, `local_id`, `op` (`CREATE|UPDATE|VOID`), `payload` (jsonb
  snapshot), `status` (`PENDING|SENT|FAILED|SKIPPED`), `attempts`,
  `external_id?`, `error?`, `sent_at?`.
- `integration_entity_map` — `target`, `entity_type`, `local_id`, `external_id`,
  `synced_at`. `UNIQUE(target, entity_type, local_id)` — no double-create.
- `integration_config` — per target: enabled, endpoint/company, schedule, account
  & field mapping (jsonb), FX source + convention. `ADMIN`-editable.
- Credentials (OAuth tokens, API keys) → **Supabase Vault**, never a table.

RPCs: `upsert_integration_config` (`ADMIN`), `retry_integration_item(outbox_id)`
(`ADMIN`).

## Connectors (phased fast-follows)

| Connector | Edge Function | Phase | Notes |
|---|---|---|---|
| **FIRS e-invoicing** | `sync-firs` | 1 (regulatory) | drains `target = FIRS`; stores `firs_irn` / `firs_status` / `firs_qr_path` back on `orders` / `invoice_financings`. Gated on FIRS taxpayer + API onboarding. |
| **QuickBooks Online** | `sync-quickbooks` | 1.5 | OAuth in Vault; `integration_config` holds the chart-of-accounts mapping. Pushes NGN + rate; QBO multi-currency shows USD. |
| **Payroll** | `sync-payroll` | 2 | staff hours / commission out; PAYE / pension / NHF. |
| Fintech provider payment APIs | (per-provider) | 1.5+ | same framework, calls back into `record_fintech_funding` etc. |

Each connector: scheduled Edge Function, drains its `target`, maps via
`integration_entity_map`, calls the API, writes `external_id` + `status` back,
raises `alerts` on failure. `run_integration_connectors()` `pg_cron` job invokes
enabled connectors per `integration_config` schedule.

## BI / analytics — NOT a connector

A read-only **`reporting` schema** (curated views over cache + ledger tables)
exposed to Metabase / Power BI / Looker via a restricted Postgres role. No
outbox, no push. Phase 2.

## Entity mapping (QuickBooks example)

| TEFAIR | QBO |
|---|---|
| outlets | Customers |
| fintech agents | Vendors |
| products | Items |
| orders / invoices | Invoices / Sales Receipts |
| `payments`, `remittances` | Payments / Deposits |
| fintech funding | Deposits |
| fintech fees (≤10% / flat 10%) | Bills / Expenses |
| `daily_sales_rollup` | Journal entries |

## Open questions

Platform spec §13.10–13 — FIRS obligation & onboarding, QBO chart-of-accounts
owner + home currency, FX source & convention, the exact set of financial events
that sync.
