# Catalog & pricing

**Spec:** §5.3, §6.1

## Purpose

The product catalogue and the single source of price. Clients never send a price
or a line total.

## Table

- `products` — `sku` (unique), `barcode?` (unique), `name`, `category`,
  `description`, `unit_price`, `wholesale_price`, `cost_price`, `weight_kg`,
  `is_perishable`, `shelf_life_days`, `reorder_point`, `is_active`.

## Rules

- The order RPC sends `product_id` + `quantity`; it reads `unit_price` from
  `products` and snapshots it onto `order_items.unit_price`. `line_total` is a
  **generated column** (`quantity * unit_price`).
- Same for `wholesale_price` / custody-based pricing decisions — server-side.
- Clients read `products` directly (reference data, RLS: all authenticated).

## RPCs

`upsert_product(...)` — ADMIN/SUPER_ADMIN.

## Fast-follow

Zone- and custody-type-scoped **price lists** (spec §11.3) — a `price_lists`
table read by the same pricing helper the order RPC already uses. Out of scope
at launch.

## Screens

- ADMIN: Master data → products (CRUD).
- FIELD_AGENT / WAREHOUSE_MANAGER: product pickers in order / transfer / count
  flows (read-only).
