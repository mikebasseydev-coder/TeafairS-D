// Document 2: Teafairweb (the public storefront) and the web consoles,
// audit and design specification.
import { baselineSection, rulesSection, errorSection, contractAppendix, enumAppendix } from './common.mjs';

export function buildWeb(r, s) {
  const naira = (n) => `₦${Number(n).toLocaleString('en-US')}`;
  const CAP = naira(s.constant('monvelo_open_exposure_ceiling'));
  const ALLOW = naira(s.constant('monvelo_allowance_ceiling'));
  const cronRows = [...s.cron.entries()].map(([k, v]) => [k, v.schedule, v.file]);

  // ── 1 ─────────────────────────────────────────────────────────────────
  r.h1('Executive Summary');
  r.p('Teafairweb (`teafairweb.com`) is Teafair\'s public retail storefront. It is hosted on Vercel in its own repository (A1) and sells to consumers at full retail price, with WhatsApp-verified checkout through Paystack. This document audits the backend contracts the web depends on and specifies three web surfaces: the storefront, a tenant operations console, and the settlement governance views. Monvelo oversight is covered too, with one structural correction.');
  r.callout('finding', 'Structural correction: three surfaces, two domains', [
    'The brief placed **lender capital tracking and liquidity health** inside the Teafairweb portal. That would break a binding ruling. **A6 §15 (owner, 2026-10-28): Monvelo is strictly B2B trade financing and web never touches it.** A guard test (045) fails the build if any function names both a `web_` and a `monvelo_` table. §16.2.2 adds that **tenants never see or steer lenders**.',
    '**Resolution:** the Monvelo oversight views are specified here (Section 6) as a separate **Monvelo console**: its own app or route group, signed in with the platform roles `MONVELO_OPERATOR` and `MONVELO_FINANCE`, sharing no code path with the storefront or the tenant console beyond the design system.',
  ]);
  r.table(['Surface', 'Users', 'Auth', 'Backend path'], [
    ['**Teafairweb storefront**', 'anonymous consumers', 'none; Turnstile and a WhatsApp phone check at checkout', 'public gateways → service_role RPCs'],
    ['**Tenant operations console**', 'ZSM, TM, CSM, LOGISTICS_MANAGER, TENANT_ADMIN (read-only), warehouse staff', 'Supabase Auth session, active tenant in the JWT', 'PostgREST `rpc()` and user gateways with the user\'s JWT'],
    ['**Monvelo console**', 'MONVELO_OPERATOR, MONVELO_FINANCE; PLATFORM_SUPER_ADMIN', 'Supabase Auth, platform role checked live', '`monvelo_*` RPCs only'],
  ], { widths: [0.22, 0.26, 0.26, 0.26], caption: 'Web surfaces and their trust boundaries.' });
  r.h2('Key audit findings');
  r.table(['#', 'The brief expected', 'The schema does', 'Resolution'], [
    ['W1', 'Location-based pricing from `commerce_ng_locations`.', '`20261020120000_commerce_ng_locations` is a **migration file**. It creates `ng_states` and `ng_lgas` (the 37 states and their LGAs). Location decides **deliverability and routing**, never the price. Prices are the product\'s retail `unit_price`, plus a **flat** per-tenant transport fare.', 'Specified as LGA routing + a flat fare (§3.3).'],
    ['W2', 'Break-bulk pricing and wholesale tiers on the web.', 'Web sales are **retail, single units, no discounts** (owner, 2026-10-24). Break-bulk applies only to app (trade) sales.', 'The console edits pack data in the catalogue; the storefront never shows it.'],
    ['W3', 'Purerigin coconut **and palm oil** dashboards.', 'Only **Purerigin Coconut Oil** (200 ml, 100 ml) is in the schema. No palm-oil product exists.', 'Dashboards are catalogue-driven; palm oil appears once a CSM loads it citing a CATALOGUE decision.'],
    ['W4', 'Lender capital and liquidity health in the web portal.', 'Monvelo is a separate domain (A6 §15); tenants never see lenders (§16.2.2).', 'Moved to the Monvelo console (Section 6).'],
    ['W5', 'Admin review of commission disputes.', 'Commissions move to DISPUTED automatically and ZSMs are notified. **Resolving** a dispute is D3, which is not built. Refunds are started in the Paystack dashboard.', 'Console shows and explains; actions wait for D3.'],
    ['W6', 'Next.js on Vercel.', 'Vercel is in A1. **No spec fixes the framework.** Next.js is a sound fit, but it is the brief\'s choice, not a recorded decision.', 'Recorded as a proposal for the owner to confirm.'],
  ], { widths: [0.05, 0.24, 0.43, 0.28], caption: 'Brief versus schema.' });

  // ── 2 ─────────────────────────────────────────────────────────────────
  r.h1('Audit Baseline and Method');
  baselineSection(r, s, { audience: 'Teafairweb engineers, console engineers, finance and operations leads, Spec B and D3 authors.' });
  rulesSection(r);
  r.h2('Public gateway rules (A1, D1, A3, A5)');
  r.bullets([
    '**Anonymous callers never touch PostgREST.** Public gateways call RPCs granted to `service_role` only, and resolve the tenant from the referral code, or TEAFAIR when there is none (codeless).',
    '**CORS** is limited to `WEB_ALLOWED_ORIGINS`. A request with no `Origin` (server-side rendering on Vercel) is served.',
    '**Turnstile** gates checkout, phone verification and ticket opening.',
    '**Client IP** is read only through `_shared/commerce/client-ip.ts` (`cf-connecting-ip`, else the first `x-forwarded-for` hop, and only if it parses as an IP literal). Which header to trust in production is a pre-deploy staging check (R19).',
  ]);
  errorSection(r);

  // ── 3 ─────────────────────────────────────────────────────────────────
  r.h1('Storefront and Public Routing');
  r.h2('Proposed stack (needs owner confirmation)');
  r.table(['Concern', 'Proposal', 'Why'], [
    ['Framework', 'Next.js (App Router) on Vercel', 'SSR for catalogue SEO; route handlers can proxy to gateways server-side; Vercel is already the host (A1).'],
    ['Data', 'Server Components fetch `storefront-catalogue` and `storefront-locations` with no Origin; the CDN caches by the gateway headers', 'The gateways already send `Cache-Control` (catalogue `max-age=60, s-maxage=300`; locations `max-age=3600`).'],
    ['Styling', 'Tailwind with the `teafair-*` tokens (FIGMA.md)', 'The same tokens as the app; never stock palette classes.'],
    ['Secrets', 'None in the browser bundle. Only the public Turnstile site key and the gateway base URL, from env', '.env stays gitignored; no Supabase key is needed for public gateways.'],
  ], { widths: [0.16, 0.44, 0.4] });

  r.h2('Codeless and coded storefronts');
  r.p('`storefront-catalogue` takes an optional `code`. **Codeless** (no code) sells TEAFAIR\'s catalogue directly. **Coded** (`?code=` from a referral link) resolves the tenant from `web_referral_codes`; a POS venue\'s code is how a POS agent earns a commission. The URL shape `/?code=ABC123` must survive navigation and checkout (keep it in a first-party cookie for the session).');
  r.table(['Gateway', 'Method', 'Purpose', 'Cache'], [
    ['storefront-catalogue', 'GET ?code=', 'Tenant, products, retail unit prices, NAFDAC fields, availability', 'max-age=60, s-maxage=300'],
    ['storefront-locations', 'GET ?code=', '37 states with LGAs; `deliverable` per LGA for the resolved tenant', 'max-age=3600'],
    ['storefront-refund-policy', 'GET', 'The active refund policy version and its text', '5 min'],
    ['checkout-phone-verify-start / -confirm', 'POST', 'Turnstile, then a WhatsApp code; returns the single-use verification token (30 min)', 'none'],
    ['web-checkout', 'POST', 'Quote, initialise Paystack, place the order; replay returns the original URL', 'none'],
    ['web-order-status', 'POST', 'Callback page status for a matching (public_reference, paystack_reference) pair', 'none'],
    ['support-ticket-open / -read / -message / -attachment', 'POST', 'Buyer support with a (public_reference, secret) capability', 'none'],
  ], { widths: [0.3, 0.12, 0.42, 0.16], mono: [0], caption: 'Public gateways the storefront calls.' });

  r.h2('Location: routing and the fare, not pricing');
  r.bullets([
    '**LGA picker.** States, then LGAs, from `storefront-locations`. Undeliverable LGAs are shown greyed out with "We don\'t deliver here yet", not hidden, so a buyer understands why.',
    '**`lga_id` is required on every checkout** (D1). The database routes the order to the territory covering the LGA (else the state), its warehouse, and an accountable person (the TM, else the ZSM, else `web_default_agent_id`). No territory, warehouse or person is ever named to the buyer.',
    '**Price** is the product\'s retail `unit_price`, the same in every LGA. **The transport fare** is a flat amount per order from `tenant_settings.web_transport_fare` (TEAFAIR ₦750, others ₦0), shown as its own line.',
    '**No discounts.** Web discounts are switched off by trigger, and the quote\'s `discount` is always 0. The UI must not render a discount field or a promo-code box.',
  ]);
  r.h3('The cart quote');
  r.p(`\`${s.sig('quote_web_order')}\` (service_role, called by the gateway) returns \`subtotal\`, \`discount\` (0), \`goods_total\`, \`transport_fare\` and \`total\` (goods plus fare). The page shows exactly these values; it never recomputes the total in the browser. \`place_web_order\` receives \`p_expected_total\`, so a stale cart is refused rather than charged.`);

  r.h2('NAFDAC compliance badges');
  r.table(['Rule', 'Storefront behaviour'], [
    ['`central_products.nafdac_number`: upper-case letters and digits in 2–6 hyphenated groups, at most 32 characters (`LG-IKJ-02-2134`)', 'Render "NAFDAC Reg. No. LG-IKJ-02-2134" on the product card and page, with a link to the regulator\'s public lookup.'],
    ['An active FOOD or COSMETICS product must have one (CHECK `central_products_nafdac_required`, NOT VALID for legacy rows)', 'If a legacy product arrives without a number, show no badge and never invent one; the console lists such products (§4.3).'],
    ['Sale categories per tenant (`tenant_allowed_categories`); TELECOM is Sureach\'s alone (NCC licence)', 'Category chips come from the catalogue; never hard-code a category list.'],
    ['Refund policy `v2.0-food-cosmetics` (placeholder text, legal review pending)', 'Show the category\'s refund copy on the product page and require the consent checkbox at checkout (`accept_refund_policy`, `policy_version_tag`).'],
  ], { widths: [0.5, 0.5], caption: 'Regulatory display rules.' });

  r.h2('Checkout flow');
  r.flow([
    ['Cart', 'quote: goods + fare'],
    ['LGA', 'deliverable only'],
    ['Phone check', 'WhatsApp code → token'],
    ['Consent', 'refund policy version'],
    ['web-checkout', 'Turnstile; Paystack'],
    ['Callback', 'poll status 3 s × 60 s'],
  ], { caption: 'Retail checkout (A1, D1, A5).' });
  r.bullets([
    '**Idempotency:** the checkout page generates one key per attempt and keeps it in sessionStorage, so a refresh replays and returns the same Paystack URL.',
    '**Callback page:** Paystack appends `reference`. Call `web-order-status` with both references every 3 s for up to 60 s while PENDING, then show "Your payment is being confirmed — keep your reference TF-XXXXXX". The 5-minute sweep completes the rest.',
    '**After delivery:** the buyer gets the delivery code by WhatsApp and reads it to the rider. Damage must be reported within 24 hours, with photos, through a support ticket.',
  ]);
  r.h2('Break-bulk and wholesale: not on the storefront');
  r.p('Trade buyers order through ZSAs and ASAs in the app, in whole packs at wholesale (see the mobile specification). The storefront sells single units at retail. Pack sizes (`carton_units`, `break_bulk_units`) and wholesale prices appear only in the tenant console\'s catalogue editor.');

  // ── 4 ─────────────────────────────────────────────────────────────────
  r.h1('Tenant and Brand Operations Console');
  r.h2('Isolation model');
  r.bullets([
    '**One session, one active tenant.** The console reads `active_tenant_id` from the JWT and switches with `set_active_tenant`, then refreshes the session. It never passes a tenant id to an RPC (the only exceptions are platform-admin calls such as `appoint_zone_manager`).',
    '**Reads** go through RLS `FOR SELECT` policies and `my_*_ids()` helpers. A ZSM sees the zones they cover (§18.3). TENANT_ADMIN is read-only: every write RPC refuses it with 42501, so the console hides write controls for that role and still handles the 42501.',
    '**Writes that change a tenant agreement cite a contact-report decision** ("zero backdoors", A6 §16): catalogue (`CATALOGUE`), stock (`STOCK`), brand terms, settings and fees, and operational state (`DISTRIBUTION`). Every such form has a required "Decision" picker listing citable decisions: current, ZSM-reviewed and hard-copied.',
  ]);
  r.h2('Contact reports (the source of truth)');
  r.table(['Step', 'Who', 'Call'], [
    ['File the report (attendees, decisions, recipients); corrections supersede', 'CSM', s.sig('file_contact_report')],
    ['Review', 'ZSM (MONVELO_OPERATOR only while the tenant has no ACTIVE ZSM)', s.sig('review_contact_report')],
    ['Upload the signed hard copy (PDF/JPEG/PNG ≤ 10 MB)', 'CSM', '`request_contact_report_hard_copy` → gateway `contact-report-upload` → `attach_contact_report_hard_copy`'],
  ], { widths: [0.38, 0.22, 0.4], mono: [2], size: 8.3 });
  r.h2('Catalogue and brand operations (Purerigin and beyond)');
  r.p(`\`${s.sig('upsert_catalogue_product')}\` (CSM) creates or edits a product from a JSON object and must cite a CATALOGUE decision. The editor exposes sku_code, product_name, brand, category, sale_category, unit_price (retail), wholesale_price, carton_units, break_bulk_units (must divide the carton), nafdac_number and is_active. Generated pack prices are shown read-only.`);
  r.table(['Brand view (per brand of the active tenant)', 'Source'], [
    ['Retail web sales: orders, revenue (goods) and fares by day', '`orders` (channel ONLINE) under the caller\'s RLS'],
    ['Trade sales: whole-pack orders by area and ZSA/ASA', '`orders` (FIELD_SALES), `order_items`'],
    ['Stock on hand, reserved and available per warehouse and batch', '`inventory_batches` (`quantity_reserved` is the stored sum), `stock_reservations`'],
    ['Monvelo-financed volume for **the tenant\'s own lines** (gross, fees; never the lender)', 'tenant ledger entries readable by the tenant'],
    ['Products missing a NAFDAC number (legacy rows)', '`central_products` where FOOD/COSMETICS and `nafdac_number` is null'],
  ], { widths: [0.6, 0.4], caption: 'A brand dashboard is a filter over shared views. Purerigin Coconut Oil is the seeded example; no product is hard-coded.' });
  r.h2('Inventory and stock movements');
  r.p('Every movement is one insert-only `stock_movements` row: kind ' + (s.checkValues('stock_movements.kind').join(' / ') || 'RECEIPT / TRANSFER / ADJUSTMENT') + ', warehouse, optional destination, SKU, batch, quantity (NUMERIC(14,3); positive except adjustments), reason, the decision cited and who recorded it. Dispatch writes `SALE_DISPATCH` consumption against reservations. Orders reserve stock at placement, first expiry first out.');
  r.table(['Action', 'Role', 'Call'], [
    ['Receive', 'CSM or LM', s.sig('record_stock_receipt')],
    ['Transfer', 'CSM or LM', s.sig('record_stock_transfer')],
    ['Adjust (signed delta, reason required)', 'CSM or LM', s.sig('record_stock_adjustment')],
    ['Return goods after dispatch (cites the order)', 'LM or CSM', s.sig('record_order_return')],
  ], { widths: [0.24, 0.14, 0.62], mono: [2], size: 8.2 });
  r.bullets([
    '**Movement ledger screen:** a filterable, append-only table (date, kind, SKU, batch, from → to, quantity, decision link, recorded by). There is no edit or delete; a correction is a new ADJUSTMENT.',
    '**Reservation sweep:** unpaid web orders are cancelled after `tenant_settings.web_reservation_hours` (24), and unpaid trade orders at the end of their Lagos supply day (`stock-reservation-sweep`, every 15 min). The console shows "reserved until" on each order.',
  ]);
  r.h2('Fulfilment of web orders');
  r.table(['Step', 'Who', 'Gateway → RPC'], [
    ['Dispatch (generates the 4-digit delivery PIN, sends it to the buyer)', 'warehouse manager or ZSM', '`order-dispatch` → `mark_order_dispatched`'],
    ['Resend the PIN (3 a day)', 'same', '`order-delivery-pin` → `resend_delivery_pin`'],
    ['Delivery photo slot', 'deliverer', '`order-delivery-photo`'],
    ['Confirm delivery (5 wrong codes: 30-min lock; 10 lifetime: ZSM)', 'deliverer', '`order-delivery-confirm` → `mark_order_delivered`'],
  ], { widths: [0.5, 0.18, 0.32], mono: [2], size: 8.3 });

  // ── 5 ─────────────────────────────────────────────────────────────────
  r.h1('Settlement Governance (Web Money)');
  r.p('Web money is collected by Paystack, settled by webhook and sweep, and split to POS partners\' subaccounts when a referral code earns. No human approves a commission (Spec A decision 14); the console is for **oversight**, and its actions are limited to what the backend allows today.');
  r.h2('Scheduled jobs');
  r.table(['Job', 'Schedule (UTC)', 'Defined in'], cronRows, { widths: [0.32, 0.18, 0.5], mono: [0, 1, 2], size: 8.2, caption: 'Active pg_cron jobs after every schedule and unschedule in the migrations.' });
  r.callout('note', 'How cron reaches the gateways', [
    '`pg_cron` calls `reconcile-funds` and `web-commission-release` through `pg_net` (`invoke_system_function`). The base URL and the shared secret come from Vault (`functions_base_url`, `cron_secret`). Without them each run logs "functions_base_url or cron_secret is missing from Vault" and posts nothing. **The console\'s first health check is therefore: did each job post today?**',
  ]);
  r.h2('Paystack webhook and settlement');
  r.p('`process-payment` accepts `charge.success` and `refund.processed`. It checks the signature and a replay window, then re-verifies with Paystack before writing. References matching `MV-…` route to Monvelo (`settle_monvelo_funding`, `apply_monvelo_refund`); web references go to `settle_paystack_payment`, which settles at most once per (event, reference).');
  r.table(['Verified status', '< 2 h', '2 h – 72 h', '> 72 h'], [
    ['success', 'SUCCESS', 'SUCCESS', 'SUCCESS'],
    ['failed, abandoned', 'not final', 'FAILED', 'FAILED'],
    ['ongoing, pending, processing, queued', 'not final', 'not final', 'FAILED (audit SWEEP_EXPIRED)'],
    ['reversed', 'full reversal via apply_paystack_refund', '', ''],
  ], { widths: [0.34, 0.22, 0.22, 0.22], caption: 'Status mapping (D1 §6.1). Exceptions write audit rows: PAYSTACK_MISMATCH, LATE_SUCCESS, PAID_AFTER_CANCEL.' });
  r.h2('Commission release');
  r.table(['Step', 'Behaviour'], [
    ['Daily run (06:00 UTC)', '`web-commission-release` lists subaccounts with SPLIT rows older than 24 h, pages Paystack List Settlements and Settlement Transactions, and calls `release_commission` per match.'],
    ['Match', 'share × 100 equals the subaccount share → **SETTLED**; otherwise → **DISPUTED** with SETTLEMENT_MISMATCH. At most once per (settlement, payment).'],
    ['Expiry', 'SPLIT older than 7 days → DISPUTED, NOT_SETTLED.'],
    ['Refund', 'A full refund moves SPLIT or SETTLED → DISPUTED, ORDER_REFUNDED. Paystack does not claw the share back.'],
    ['Notification', 'Every move to DISPUTED notifies the tenant\'s ZSMs (`COMMISSION_DISPUTED`) and raises a system ticket (A3).'],
  ], { widths: [0.2, 0.8] });
  r.callout('warn', 'Rates are zero today', [
    '`tenant_settings.web_agent_commission_bps` is 0 for every tenant, TEAFAIR included, until the owner agrees rates (written by migration only). No order splits yet. The commission views will be empty until then, and the console should say so rather than show an error. The release path has been proven only against the integration fake, because Paystack test mode produces no real settlements (F6).',
  ]);
  r.h2('Console views');
  r.table(['View', 'Content', 'Notes'], [
    ['Job health', 'Last run and outcome of each job; flags a missed day', 'Reads job audit rows (source CRON); cross-tenant job health is a platform view'],
    ['Payments and webhook log', 'Payments by status, with the audit trail for each (SUCCESS, FAILED, LATE_SUCCESS, PAYSTACK_MISMATCH, PAID_AFTER_CANCEL, PARTIAL_REFUND, REFUND_CONFLICT)', '`payments` is granted column by column; the console names columns and never `select *`'],
    ['Commission ledger', 'SPLIT / SETTLED / DISPUTED with reason, subaccount, settlement id', 'Statuses from `commission_status_enum`'],
    ['Refunds', 'Refunds received (`refund.processed`, the daily refund pass), partial refunds flagged', 'Refunds are **started in the Paystack dashboard**; a staff refund gateway with a PIN is D3'],
    ['Dispute evidence', 'Order header (goods total, discount, fare, total, referral code), lines with NAFDAC fields, payments with agent commission, delivery proof photos (signed 600 s)', '`order-dispute-evidence` → `get_order_dispute_evidence` (ZSM); every view audited DISPUTE_EVIDENCE_VIEWED'],
  ], { widths: [0.18, 0.5, 0.32], caption: 'Settlement governance screens for ZSMs and finance.' });

  // ── 6 ─────────────────────────────────────────────────────────────────
  r.h1('Monvelo Console (Separate Domain)');
  r.p('This is the brief\'s "system-wide liquidity health and lender capital tracking", placed where the rules allow it. It is a separate web application or route group, for platform roles only. It must not import storefront or tenant-console data code, mirroring guard test 045 on the backend.');
  r.table(['Role', 'Sees (A6 §8)', 'Does'], [
    ['MONVELO_OPERATOR', 'all Monvelo tables', 'approves and suspends agents, sets caps (`set_monvelo_agent_caps`), records fee terms, reviews flags (`review_monvelo_flag`), reviews contact reports while a tenant has no ZSM'],
    ['MONVELO_FINANCE', 'payables, payout accounts, tenant settlements, financings (read)', 'records rebate payouts and second approvals (Step 5, not built)'],
  ], { widths: [0.24, 0.3, 0.46] });
  r.h2('Liquidity health (proposal)');
  r.table(['Metric', 'Definition', 'Backend source today'], [
    ['Capital deployed', 'Σ principal FUNDED + DELIVERED + DEFAULTED (open)', '`monvelo_financings` (operator reads all)'],
    ['Open exposure by agent', `The §19.4 formula per agent; distribution against ${CAP} and ${ALLOW}`, '`get_monvelo_agent_exposure(p_agent_id)` serves Monvelo staff one agent at a time (mobile G1, resolved 2026-11-03). A fleet-wide distribution still **needs an operator list RPC**.'],
    ['Pledged vs used', 'Σ pledges.amount vs amount − remaining, by supply day and area', '`monvelo_pledges`'],
    ['Holds', 'HELD now; allowed, declined and lapsed rates; time to decision', '`monvelo_claim_holds` has no policy. **Needs an operator read RPC.**'],
    ['Refund exposure', 'REFUND_DUE count and principal; age of each', '`monvelo_financings`, the refund tickets'],
    ['Credit quality', 'Repaid within the window, repaid late, defaulted; PAR30 by raiser', '`monvelo_financings`, `monvelo_repayments`'],
    ['Flags', 'Open PAYER_MISMATCH, LATE_PAYMENT, AMOUNT_MISMATCH, REPAYMENT_REJECTED, REPAYMENT_UNCONFIRMED, FUNDING_REFUNDED', '`monvelo_flags`'],
    ['Unprovisioned agents', `ACTIVE agents whose \`daily_cap\` or \`per_financing_cap\` is ₦0.00 or below the ${CAP} ceiling`, '`monvelo_agents` (operator reads all); set with `set_monvelo_agent_caps`'],
    ['Lender reconciliation', 'Weekly capital funded, outstanding, repaid, refunded, rebates per agent', '`get_lender_reconciliation_summary` serves agents, ZSAs and ASAs only; operators **need their own RPC** (A6 §9 `monvelo_finance_overview`, not built)'],
  ], { widths: [0.2, 0.42, 0.38], caption: 'The A6 §9 finance dashboard RPCs (`monvelo_finance_overview`, `monvelo_payables`, `monvelo_tenant_settlement_statement`, `monvelo_exceptions`) are specified but not built.' });
  r.callout('warn', 'Provision agent caps at onboarding (A6 §21.2)', [
    `The platform ceiling is ${CAP} and the market-maker allowance ${ALLOW} (migration \`20261031121100\`). An agent's \`daily_cap\` and \`per_financing_cap\` start at ₦0.00 and bind first.`,
    'The operator console must show unprovisioned agents and set their caps with `set_monvelo_agent_caps`. A market maker cannot override a personal cap (rule 3A); only the exposure ceiling can be allowed past.',
  ]);

  // ── 7 ─────────────────────────────────────────────────────────────────
  r.h1('Design System and Quality Bar');
  r.table(['Token', 'Hex', 'Web use'], [
    ['teafair-emerald', '#4CAF50', 'Add to cart, Pay, primary console actions'],
    ['teafair-lime', '#8BC34A', 'Success states, the "Deliverable" chip'],
    ['teafair-forest', '#2E7D32', 'Header, footer, NAFDAC badge outline'],
    ['teafair-black', '#111111', 'Text'],
    ['teafair-surface', '#F5F7F6', 'Page and input backgrounds'],
  ], { widths: [0.25, 0.15, 0.6], mono: [0, 1], caption: 'FIGMA.md tokens (locked 2026-10-07). The brand gradient runs 135° forest → emerald → lime.' });
  r.bullets([
    '**Performance:** catalogue pages are server-rendered and CDN-cached. Product images are sized responsively. The aim is LCP under 2.5 s on a mid-range Android phone over 3G, the buyer\'s real device.',
    '**Accessibility:** WCAG 2.2 AA. Every status is shown with text as well as colour (deliverable, NAFDAC, commission status). Forms have labels; the code inputs use `autocomplete="one-time-code"`.',
    '**Privacy:** no third-party trackers on checkout pages. Buyer phone and address go only to the gateways; the storefront never stores them beyond the session.',
    '**Observability:** gateway calls carry `sentry-trace` and `baggage`, so traces join the backend\'s Sentry spans (off unless `SENTRY_DSN` is set).',
  ]);

  // ── 8 ─────────────────────────────────────────────────────────────────
  r.h1('Audit Findings and Gaps');
  r.table(['ID', 'Severity', 'Finding', 'Recommendation'], [
    ['W-G1', 'High', 'The brief put lender tracking in the web portal, against A6 §15 and §16.2.2.', 'A separate Monvelo console (Section 6).'],
    ['W-G2', 'High', 'The A6 §9 finance RPCs are not built, and there is no operator read path for exposure or holds.', 'A backend addendum before the Monvelo console.'],
    ['W-G3', 'Medium', 'Commission dispute resolution and a staff refund gateway are D3 (not built).', 'The console is read-only on disputes until D3.'],
    ['W-G4', 'Medium', 'Refund policy text is a placeholder pending legal review; versions are immutable (R20).', 'Counsel\'s text ships as a new version; the storefront reads whichever is active.'],
    ['W-G5', 'Medium', 'The trusted client-IP header is unconfirmed (R19).', 'Run the staging check before launch.'],
    ['W-G6', 'Low', 'The framework is not recorded in any spec.', 'Owner to confirm Next.js.'],
    ['W-G7', 'Low', 'No palm-oil product exists.', 'Load it through `upsert_catalogue_product` with a CATALOGUE decision and a NAFDAC number.'],
    ['W-G8', 'Info', 'Only A1/A2 are on the remote; D1 onwards is local.', 'Follow the deploy order in supabase/CLAUDE.md before launch.'],
  ], { widths: [0.08, 0.1, 0.44, 0.38], caption: 'Findings ranked by severity.' });

  // ── appendices ────────────────────────────────────────────────────────
  contractAppendix(r, s, 'Appendix A — Web RPC Contracts', [
    ['Storefront (service_role, behind public gateways)', ['storefront_catalogue', 'quote_web_order', 'place_web_order']],
    ['Tenant console', ['set_active_tenant', 'upsert_catalogue_product', 'record_stock_receipt', 'record_stock_transfer', 'record_stock_adjustment', 'record_order_return', 'file_contact_report', 'review_contact_report', 'upsert_web_referral_code', 'set_web_pos_venue', 'set_territory_web_warehouse', 'set_web_defaults', 'set_territory_coverage']],
    ['Fulfilment', ['mark_order_dispatched', 'resend_delivery_pin', 'mark_order_delivered', 'get_order_dispute_evidence']],
    ['Settlement (system)', ['settle_paystack_payment', 'apply_paystack_refund', 'release_commission']],
    ['Monvelo console', ['approve_monvelo_agent', 'suspend_monvelo_agent', 'set_monvelo_agent_caps', 'record_monvelo_fee_terms', 'review_monvelo_flag']],
  ]);
  r.h1('Appendix B — Enumerations and Statuses');
  enumAppendix(r, s, ['order_channel_enum', 'payment_status_enum', 'commission_status_enum', 'gateway_provider_enum', 'pos_network_enum', 'warehouse_kind_enum', 'venue_channel_enum', 'audit_source_enum'],
    ['orders.status', 'stock_movements.kind']);
  r.h2('Gateways in the repository');
  r.p(s.edgeFunctions.map((n) => `\`${n}\``).join(' · '));
}
