# CLAUDE.md (supabase)

The entire backend. Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`) is
the authority; this file is the working summary.

## Status

| Phase (Spec A §14) | State |
|---|---|
| 1. Schema — extensions, enums, 33 tables | done |
| 2. Grants, RLS, write contract, foundation RPCs, brand tiers, escalation cron | done |
| 3. Edge Function gateway (`supabase/functions/`) | done |
| A1. Web storefront — agent codes, venues, public gateways | done |
| A2. Buyer contact privacy — `order_contacts`, till lookup | done |
| D1. Web money loop — routing, settlement, sweeps, refunds, commission release | done (local) |
| A3. Web chat & ticketing — support tables, buyer gateways, staff RPCs, system tickets | done (local) |
| A4. Internal staff messaging — chat channels, direct chats, team/zone rooms, announcements | done (local) |
| 4. Client offline queue | needs Spec B |

Linked to remote project `vwmjyfjdwrohfizljxrq`. Per the 2026-10-15 push
(GitHub `main` at `42dd15b`), the remote has the 29 migrations up to
`20261015130200` (Spec A plus addenda A1 and A2) and six Edge Functions:
`auth-verify-claims`, `otp-issue`, `otp-verify`, `process-payment`,
`storefront-catalogue` and `web-checkout`. Remote secrets must use the names
the code reads (see `functions/.env.example`): `otp-issue` needs
`SMS_PROVIDER` (+ `KUDISMS_TOKEN`, `KUDISMS_SENDER_ID` for `kudisms`) and
`auth-verify-claims` needs `AUTH_HOOK_SECRET`, or they fail at boot. Never
`supabase config push`: the hook URI in `config.toml` is local-only. **A1
never deploys without A2**: A1 alone exposes buyer contact details to every
tenant member, and audit rows cannot be scrubbed afterwards.

### Deploying Spec D1

The eight Spec D1 migrations (`20261020120000`–`20261020130300`) and the
functions `reconcile-funds`, `fintech-commission-release`,
`storefront-locations` and `web-order-status` (plus the changed
`process-payment`, `storefront-catalogue` and `web-checkout`) are local only.
**D1 never deploys without A1 and A2.** Nothing is pushed until explicitly
asked.

**Pre-push checks** (run on the remote first):

1. ONLINE orders that are not PENDING. The legacy cancel only covers PENDING,
   and before D1 the routing columns do not exist, so every such order lacks
   routing and any count above zero makes the `orders_online_routed`
   constraint fail the push:
   `select count(*) from public.orders where channel = 'ONLINE' and status not in ('PENDING', 'CANCELLED');`
2. Web orders already paid under A1 (v1) but still PENDING. The legacy cancel
   will cancel them even though the money was taken, so each needs a decision
   (ship, or refund in Paystack) before the push:
   `select count(*) from public.payments p join public.orders o on o.tenant_id = p.tenant_id and o.id = p.order_id where p.payment_status = 'SUCCESS' and o.channel = 'ONLINE' and o.status = 'PENDING';`

**Order.** Push the D1 migrations, then deploy the D1 functions immediately.
The D1 settlement and storefront migrations drop RPC signatures that the
deployed `process-payment` and `web-checkout` call, so checkout and webhooks
fail in between. Paystack retries webhooks, so a gap of a few minutes is
acceptable; a long one is not. Then create the Vault secrets (Cron jobs,
below).

**Post-deploy setup.** D1 routes every web order (§4). A coded link that works
under A1 refuses with "We don't deliver to this area yet." until its territory
has a `web_fulfilment_warehouse_id` (its own REGIONAL warehouse) or the tenant
has a CENTRAL `web_default_warehouse_id`. Codeless sales go to TEAFAIR and
need its coverage (state or LGA → territory), a warehouse, and an accountable
person: the territory's TM (else the zone's ZSM, else `web_default_agent_id`).
A ZSM of each tenant sets these with:

- `set_territory_web_warehouse(p_idempotency_key, p_territory_id, p_warehouse_id)`
- `set_web_defaults(p_idempotency_key, p_warehouse_id, p_agent_id)` (CENTRAL warehouse)
- `set_territory_coverage(p_idempotency_key, p_state_code, p_lga_id, p_territory_id)`
  (`p_lga_id` null covers the whole state)

Until Spec B exists there is no client: call them through PostgREST
(`POST /rest/v1/rpc/<name>`) with a ZSM's JWT whose active tenant is the one
being set up.

### Addendum A3 (web chat and ticketing)

Four migrations (`20261021120000`–`20261021120300`) and the functions
`support-ticket-open`, `support-ticket-read` and `support-ticket-message` are
local only. **A3 deploys after D1**: it depends on D1's routing (a ticket goes
to the territory's TM, else the zone's ZSM, else `web_default_agent_id`), and
its triggers watch D1's tables to raise system tickets from payment exceptions.

- **Public gateways** (`publicGateway`, service-role RPCs):
  `support-ticket-open` (Turnstile, then `open_support_ticket`; only the
  secret's hash is stored), `support-ticket-read` (`read_support_ticket`) and
  `support-ticket-message` (`add_ticket_message`). The pair
  `(public_reference, secret)` is the buyer's capability; any miss is 404.
  A closed conversation or a throttled buyer gets 422 with the database copy.
  All three need `verify_jwt = false`, already set in `config.toml`.
- **The ticket secret** is HMAC-SHA256(`SUPPORT_TICKET_SECRET_KEY`,
  idempotency key), base64url, so a retried open returns the same secret as
  the lost first reply. `support-ticket-open` needs `SUPPORT_TICKET_SECRET_KEY`
  (32+ random bytes, base64url), `TURNSTILE_SECRET_KEY` (the same secret as
  `web-checkout`; locally with `TURNSTILE_VERIFY_URL` pointing at the fake)
  and `WEB_ALLOWED_ORIGINS`. Without a usable key every open is 503. **Set
  `SUPPORT_TICKET_SECRET_KEY` as a remote Edge Function secret before
  deploying the open gateway.** Rotating it only breaks replays of opens
  still in flight; existing tickets keep their stored hashes.
- **Staff RPCs** (through PostgREST, `authenticated`): `claim_ticket`,
  `reply_ticket`, `update_ticket_status`, `set_ticket_priority`, and the
  ZSM-only `assign_ticket` (pre-purchase tickets that are not CLOSED; an
  IN_PROGRESS ticket goes back to OPEN) and `redact_ticket_customer_data`
  (repeating it with nothing new to redact writes no audit row).
  `close_resolved_support_tickets` is the cron sweep: pure SQL, so it needs
  no Vault secret. System tickets come from `raise_system_ticket`, called by
  triggers on D1's disputed commissions and payment exceptions; they do not
  count toward a buyer's three open tickets per order.
- **Ticket headers are visible to every tenant member**, and so are their
  Realtime events. They carry structure only, no personal data.
- **Handler RLS rule.** The tables are `SELECT`-only. Contacts and messages
  are readable by a ZSM of the tenant, the TM of the ticket's territory, and,
  on PRE_PURCHASE and SYSTEM tickets only, the ticket's accountable or
  assigned person (`my_support_ticket_ids()` for contacts; messages use the
  history helper below). Buyer contact details stay with each ticket's own
  handlers.
- **ORDER tickets follow A2** (user decision 2026-10-21): only the ZSM and the
  territory TM read or act on them. The order's selling agent stays
  `accountable_id` and gets the notification (`{ticket_id,
  public_reference}` only), but cannot read contacts or messages, claim,
  reply, or change status or priority.
- **Claimed tickets are locked.** Once `assigned_to` is set, only the assignee
  or a ZSM can claim, reply, change status or change priority. Everyone else
  gets 42501. Any permitted replier claims an unassigned ticket. The hold
  lapses when the assignee is no longer an ACTIVE member: the ticket is then
  treated as unassigned, and a permitted claim takes it (audited with
  `before.assigned_to`). Notifications likewise skip an inactive assignee or
  accountable person and fall back to every ZSM.
- **Repeat system facts.** A repeat on a RESOLVED system ticket reopens it. A
  repeat on a CLOSED one opens a new SYSTEM ticket whose `previous_ticket_id`
  points at the closed one. `system_key` is unique only among non-CLOSED
  tickets (partial index `support_tickets_open_system_key`).
- **Linked buyer tickets.** A buyer ORDER ticket links to the most recent
  CLOSED ORDER ticket on the same order.
- **Linked history.** Handlers read linked history through
  `my_support_history_ticket_ids()`, which covers the whole chain and gives
  messages only. Contacts stay with each ticket's own handlers through
  `my_support_ticket_ids()`.

### Addendum A4 (internal staff messaging)

Four migrations (`20261022120000`–`20261022120300`), local only. No Edge
Functions and no secrets: staff talk through PostgREST.

- **RPCs** (`authenticated`): `get_or_create_direct_channel`,
  `post_chat_message`, `mark_chat_read`, `hide_chat_message` (ZSM only), and
  the read-only inbox `list_my_chat_channels()`. The tables are `SELECT`-only.
  Team (territory), zone and announcement channels are created by trigger.
- **Access is live-derived.** `my_chat_channel_ids()` computes the caller's
  channels from `tenant_users` on every call; there is no member table, so a
  role or territory change takes effect at once. The internal helpers
  `chat_is_available`, `chat_staff_zone` and `chat_create_group_channel` have
  no grants.
- **Direct chats are private.** Only the two people can read them, and
  `hide_chat_message` refuses them (42501). Rooms are moderated by a ZSM of
  the room's zone; any ZSM of the tenant moderates announcements. A hidden
  message keeps its row with body `[removed]`, `hidden_at` and `hidden_by`;
  the `CHAT_MESSAGE_HIDDEN` audit holds ids and the reason, never the body.
  Hiding twice writes no second audit row.
- **Notifications** use fixed copy and ids only; rooms never notify.
- **Realtime.** The publication includes `chat_messages` and `chat_channels`;
  RLS decides who receives each event.

## Layout

```
supabase/
├── config.toml
├── migrations/        hand-written, ordered — Supabase CLI owns all DDL
├── tests/database/    pgTAP, run by `supabase test db`
└── functions/         Edge Functions — one flat directory per function
    └── _shared/       core/ (gateway kernel, public-gateway) · auth/ · commerce/ · fintech-liquidity/
```

Code is grouped by domain: `auth`, `rtm-core`, `commerce`,
`fintech-liquidity`. Migration and pgTAP file names carry the domain
(`…_auth_pin_verification.sql`, `008_fintech_liquidity_otp.test.sql`). A
domain gets a `_shared/<domain>/` folder once it has code.

Migrations are **hand-written**, not generated from declarative schemas: grants,
column privileges, comments and `cron.schedule` are outside what `db diff`
tracks, and grants are the security core (Spec A §13).

## Writing a migration

- Every new table: `enable row level security` in the same migration, a
  `FOR SELECT` policy, and nothing else. Never an INSERT/UPDATE/DELETE policy.
- Tenant-scoped tables carry `tenant_id uuid not null references
  tenants(id) on delete restrict`, a `unique (tenant_id, id)`, and reference
  other tenant rows through **composite** `(tenant_id, x)` foreign keys so a
  row can never point into another tenant.
- Index every foreign key and every column a policy filters on.
- Mutable tables get the `set_updated_at()` trigger.
- PostGIS lives in the `extensions` schema: write `extensions.geometry(...)`
  and `extensions.st_*` — function search paths do not include it.
- New functions get **no** EXECUTE for PUBLIC/anon/authenticated by default
  (grants migration). Grant explicitly, and only what the API may call.
- Buyer contact details live only in `order_contacts` (addendum A2), readable
  by the ZSM and the order's TM. Never put personal data on `orders` or in an
  audit payload; audit a redacted summary.
- `payments` and `tenant_users` are granted column by column. A new column on
  either is invisible to the app until added to the grant, and the app must
  name columns rather than `select *`.

## Writing an RPC

Follow the skeleton in `20261006130300_write_contract.sql`:

```sql
create or replace function public.<op>(p_idempotency_key uuid, ...)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, '<op>', <request jsonb>);
  if v_prior is not null then return v_prior; end if;
  -- validate (P0001), lock contended rows in primary-key order, write
  perform public.write_audit(v_me.tenant_id, '<op>', '<table>', <id>, <before>, <after>, p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, <response jsonb>);
end; $$;
grant execute on function public.<op>(...) to authenticated;
```

- No `p_tenant_id` parameter, ever (the only exception is `set_active_tenant`,
  which proposes a tenant and is checked against membership).
- Error codes (Spec A §3.5): `P0001` business 422 · `42501` forbidden 403 ·
  `23505` 409 · `TF001` insufficient stock 409 · `TF002` idempotency mismatch
  409 · `40001`/`55P03` retry 503. Do not use `P0002`: it is PL/pgSQL's
  `no_data_found`.
- Pure DB work is an RPC; scheduled pure-SQL work is a `pg_cron` job. Edge
  Functions are for HTTP, PINs and external IO only.
- **PIN-gated RPCs** call `public.consume_pin_pass()` right after
  `idempotency_begin`. The gateway's `requirePin` leaves a single-use pass
  that lasts 60 s, so a call that skips the gateway and goes straight through
  PostgREST still needs the PIN.
- **The one idempotency exception** is `verify_pin`. It returns a
  `pin_check` composite and takes no key: it is a guard, not a queued write,
  and a replayed key must never re-grant a pass.

## Writing an Edge Function

Each function is a self-contained directory. `index.ts` only wires live
dependencies, `handler.ts` exports `create…Handler(deps)`, and tests sit
beside it. Code used by two or more functions goes in `_shared/<domain>/`,
one responsibility per file. Third-party versions appear only in
`_shared/core/deps.ts`.

- **User gateways** use `userGateway(schema, handle, liveUserGatewayDeps())`.
  The pipeline: POST only → JWT (`auth.getClaims`) → tenant keys stripped →
  Zod → handler → §3.5 error mapping. The handler's `rpc` forwards the
  caller's JWT. Never import `serviceRpc` into a user gateway.
- **PIN-gated operations** call `requirePin(rpc, body.pin)` (from
  `_shared/auth/pin.ts`) before their RPC.
- **System functions** use `serviceRpc()` and authenticate the caller
  themselves: `auth-verify-claims` and `process-payment` (`charge.success`,
  `refund.processed`) by signature; the cron-invoked `reconcile-funds`
  (`{mode: "sweep" | "refunds"}`) and `fintech-commission-release` (`{}`;
  Spec D1) by the `x-cron-secret` header, compared in constant time against
  `CRON_SECRET` (`_shared/core/cron.ts`). The sweep takes its batch from
  `claim_unconfirmed_payments(50)`, which stamps `last_swept_at` on every row
  it hands out, so a row whose Verify fails still moves to the back. Paystack
  GETs time out after 15 s; `pg_net` waits up to 120 s for a cron call.
- **Public gateways** (`storefront-catalogue`, `web-checkout`; addendum A1;
  `support-ticket-open`, `support-ticket-read`, `support-ticket-message`;
  addendum A3; `storefront-locations`, `web-order-status`; Spec D1) use
  `publicGateway(route, handle, deps)` from `_shared/core/public-gateway.ts`.
  Callers are anonymous, so their RPCs are granted to `service_role` only and
  resolve the tenant from the agent code, or TEAFAIR when there is none
  (codeless). CORS is limited to `WEB_ALLOWED_ORIGINS`; checkout is gated by
  Turnstile. `web-order-status` answers only for a matching
  `(public_reference, paystack_reference)` pair; any miss is 404.
- **`verify_jwt = false`** is set for every function in `config.toml`; each
  one verifies its caller itself.

```bash
supabase functions serve --env-file supabase/functions/.env     # serve locally
deno test --allow-env supabase/functions/                       # unit tests
supabase status -o env > supabase/.env.test.local               # then:
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

**Secrets:** copy `supabase/.env.example` and
`supabase/functions/.env.example`; `AUTH_HOOK_SECRET` must match in both. Set
`SMS_PROVIDER=log` locally, and `kudisms` (with `KUDISMS_TOKEN` and
`KUDISMS_SENDER_ID`) anywhere real. `web-checkout` also needs
`TURNSTILE_SECRET_KEY`, `WEB_ALLOWED_ORIGINS` and `WEB_CHECKOUT_CALLBACK_URL`
(see `functions/.env.example`). `reconcile-funds` and
`fintech-commission-release` need `CRON_SECRET` or they fail at boot.
`support-ticket-open` needs `SUPPORT_TICKET_SECRET_KEY` (addendum A3, above).

The integration test runs its own fake Paystack (Initialize, Verify, List
Refunds, Fetch Subaccount, List Settlements, Settlement Transactions) and
Turnstile on host port 54399, reached from the edge runtime at
`host.docker.internal:54399` (`PAYSTACK_API_BASE`, `TURNSTILE_VERIFY_URL`).
It needs no Vault secrets: it calls the cron functions directly.

### Cron jobs (Spec D1 §10)

`pg_cron` calls `reconcile-funds` (sweep every 5 min, refunds 05:00 UTC) and
`fintech-commission-release` (06:00 UTC) through `pg_net`
(`public.invoke_system_function`). It reads the base URL and the shared secret
from Vault; the migrations hold no secret values. Create both once **per
environment** (SQL editor or `psql`):

```sql
select vault.create_secret('<functions base url>', 'functions_base_url');
select vault.create_secret('<secret>', 'cron_secret');
```

Locally the URL is `http://host.docker.internal:54321/functions/v1`, and the
secret is the `CRON_SECRET` in `functions/.env`. On the remote it is
`https://<project-ref>.supabase.co/functions/v1`, and the secret must equal the
function secret `CRON_SECRET`. Without them each job logs
`functions_base_url or cron_secret is missing from Vault` and posts nothing.
`supabase db reset` wipes Vault, so recreate them after a reset if you want
the jobs to run locally.

**Paystack test mode (D1 plan, fact F6).** The Paystack account is in test
mode. Transactions, Verify and refunds behave as they do live, but test mode
is not expected to produce real subaccount settlements. The commission release
path (List Settlements, Settlement Transactions) has therefore been proven only
against the integration fake. Its first real check comes after go-live:
watch the first `fintech-commission-release` runs and the `release_commission`
audit rows (`share_verified`).

## Testing

```bash
supabase test db                 # all files; look for "Result: PASS"
psql -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
     -qAt -f supabase/tests/database/003_rls.test.sql   # one file, every assertion
```

Act as a user the way PostgREST does: `set_config('role','authenticated',true)`
plus `request.jwt.claims` JSON with `sub` and `app_metadata.active_tenant_id`.
Test helpers created with `create function pg_temp.*` need an explicit
`grant execute … to authenticated`. Write the test first and watch it fail.

If `supabase start` / `db reset` fails with `LegacyDbSetupError` and a realtime
`nxdomain` message, Docker's internal DNS hiccuped; restart Docker Desktop and
retry. `supabase migration up` applies new migrations without a full reset.

If it fails with `HealthCheckTimeoutError … unhealthy`, the host is CPU-starved:
the CLI's 2s probes are not configurable. `[analytics]` is off in
`config.toml` for this reason; keep it off, and stop other heavy containers
before starting.
