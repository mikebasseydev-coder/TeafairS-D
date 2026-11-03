// Document 1: the Teafair mobile app (React Native / Expo) audit and
// front-end specification. Facts come from Spec A, addenda A1–A6, the
// supabase working summary and, for every contract, the parsed migrations.
import { baselineSection, rulesSection, errorSection, contractAppendix, enumAppendix } from './common.mjs';

export function headingCount() { return 60; }

export function buildMobile(r, s) {
  const naira = (n) => `₦${Number(n).toLocaleString('en-US')}`;
  const CAP = naira(s.constant('monvelo_open_exposure_ceiling'));
  const ALLOW = naira(s.constant('monvelo_allowance_ceiling'));
  const holdCols = s.returnCols('list_monvelo_claim_holds');
  const sumCols = s.returnCols('get_lender_reconciliation_summary');
  const expCols = s.returnCols('get_monvelo_agent_exposure');

  // ── 1 ─────────────────────────────────────────────────────────────────
  r.h1('Executive Summary');
  r.p(`This document audits the Teafair backend as it stands in the local migrations and turns it into a front-end specification for the Teafair mobile app: the React Native (Expo) client that ZSMs, TMs, ZSAs, ASAs, shop owners and Monvelo agents will carry. The backend is complete through Monvelo Step 3, the ${CAP} open exposure cap and the market-maker allowance (A6 §19.4 and §20). No client exists yet.`);
  r.callout('rule', 'Status of this document', [
    '**This is an input to Spec B, not Spec B.** Spec B (the app shell) is on hold until the owner asks for it, and no front-end code or scaffolding is written before it is approved. Everything here marked **Proposal** is a recommendation for Spec B to accept, change or reject. Everything marked as backend fact is quoted from the migrations or the approved specs.',
    '**Platforms:** Android and iOS (the owner\'s 2026-10-08 decision, which amends Spec A §2 item 11, "Android only at launch").',
  ]);
  r.h2('What the app must do');
  r.bullets([
    '**Sign people in on their verified phone** with a WhatsApp code, select the active tenant, and keep the session in secure storage.',
    '**Queue every write offline** with an idempotency key fixed when the user acts, and drain it in order when the signal returns (Spec A §7).',
    '**Give each role its own workspace:** field managers (ZSM, TM, ASM), street agents (ZSA, ASA), shop owners, and the members of Monvelo financing agents.',
    '**Run Monvelo end to end on the phone:** shop consent, supply days, pledges, trade orders and financing requests, claims, funding over Paystack bank transfer, the delivery and repayment codes the shop owner reads out, and the 15-minute market-maker hold.',
    `**Show money accurately and never stale:** the agent's open exposure against the ${CAP} cap, and the weekly lender reconciliation grouped by Lagos week.`,
  ]);
  r.h2('Key audit findings');
  r.p('The brief behind this document set out several expectations. Six of them differ from what the schema actually does. The app must follow the schema, so each difference is resolved below and in Section 10.');
  r.table(['#', 'The brief expected', 'The schema does', 'Resolution'], [
    ['F1', 'ZSA and ASA as the Monvelo deciders.', 'Market makers are the **ZSM and the ASA** (A6 §20.2 decision 1). The ZSA recruits and raises requests, and reads the lender summary, but cannot allow a hold.', 'The ZSA build gets no hold queue.'],
    ['F2', 'Client-side four-eyes enforcement.', 'Four eyes is enforced **in the database**: the raiser and any member of the held agent get 42501 and never see the hold (decision 6, R78).', 'The client only reflects the rule; it is never the control.'],
    ['F3', 'A live exposure meter.', '`monvelo_agent_open_exposure` and both ceilings stay **ungranted**; since 2026-11-03 the read-only `get_monvelo_agent_exposure` returns them to the agent\'s members.', '**G1 resolved** (migration `20261031121200`): the meter reads that one RPC (§7.3).'],
    ['F4', 'Password login for field roles, PIN login for shop owners and agents.', 'The only sign-in route built is the **phone + WhatsApp code** for everyone. Email serves recovery and invites; passwords are at least 12 characters. The 4-digit PIN is a **transaction control**, not a login.', 'Proposal in §4.2; the login method is an open Spec B decision.'],
    ['F5', 'Break-bulk pricing on the web.', 'Break-bulk applies only to **app (trade) sales**, at the wholesale price; the web sells single units at retail.', 'Covered here in §8.'],
    ['F6', 'One "POS agent" persona.', 'There are two: the web `POS_AGENT` tenant role (referral links, no Monvelo) and the **Monvelo agent**, a platform entity whose members are people.', 'They get separate workspaces, and web never touches Monvelo (A6 §15).'],
  ], { widths: [0.05, 0.25, 0.42, 0.28], caption: 'Brief versus schema: the differences this specification resolves.' });

  // ── 2 ─────────────────────────────────────────────────────────────────
  r.h1('Audit Baseline and Method');
  baselineSection(r, s, { audience: 'Spec B authors, mobile engineers, QA, product owners for Monvelo and field sales.' });
  r.h2('Method');
  r.bullets([
    '**Contracts** were parsed from the migrations by the generator (`docs/reports/generator/lib/schema.mjs`): the latest `create or replace function` per name, EXECUTE grants net of revokes and drops, enums with added and renamed values, CHECK status sets and pg_cron jobs.',
    '**Behaviour** was taken from Spec A, addenda A1–A6 and the rulings recorded in `supabase/CLAUDE.md` (R1–R78), which the pgTAP suite tests.',
    '**Front-end proposals** follow the locked decisions: React Native + Expo + TypeScript, NativeWind with the `teafair-*` tokens from `FIGMA.md`, Zustand, an MMKV queue and read cache.',
  ]);
  rulesSection(r);

  // ── 3 ─────────────────────────────────────────────────────────────────
  r.h1('Client Architecture');
  r.h2('The request path');
  r.flow([
    ['App (Expo)', 'Zod-validated mutation, key fixed at enqueue'],
    ['MMKV queue', 'FIFO per dependsOn chain, backoff 2 s → 5 min'],
    ['Edge gateway or PostgREST rpc()', 'Bearer user JWT; PIN, codes, Paystack IO at the gateway'],
    ['SECURITY DEFINER RPC', 'idempotency, live role and scope, writes, audit'],
  ], { caption: 'Every write takes this path. The tenant is never a parameter.' });
  r.p('Two transports reach the database. **Gateways** (`/functions/v1/<name>`) are used whenever the operation needs a PIN, a one-time code, Paystack, WhatsApp or Storage. **Direct RPCs** (`supabase.rpc()`) are used for pure database work, such as `claim_monvelo_financing`, `decide_monvelo_claim_hold` and `get_lender_reconciliation_summary`. Both carry the user\'s JWT.');
  r.h2('Offline queue (Spec A §7, locked)');
  r.code(`type QueuedMutation = {
  id: string            // UUIDv4: IS the idempotency_key, generated at enqueue
  operation: string     // gateway function or RPC name
  payload: unknown      // Zod-validated at enqueue, before it ever leaves
  dependsOn?: string    // ordering within a causal chain
  attempts: number
  nextAttemptAt: number
  lastError?: { code: string; message: string; terminal: boolean }
  status: "PENDING" | "IN_FLIGHT" | "TERMINAL" | "DONE"
}`);
  r.bullets([
    '**Retry** on 503 and network failure with the same key. **Stop** on 409 and 422, and move the entry to a visible "Needs attention" list.',
    '**Online-only operations** must not be queued. These are PIN-gated calls, code entry (delivery and repayment codes, consent codes), funding (`monvelo-fund`), hold decisions and claims. A claim or a decision that lands after its 15-minute window is worthless, so the UI disables these actions offline and says why.',
    '**One exception, by design:** `log_retail_pickup` lands as PENDING_CONFIRMATION with no PIN, and the shop owner confirms it later (Spec A §7.4).',
  ]);
  r.h2('Read cache');
  r.table(['Class', 'Examples', 'TTL', 'Refresh'], [
    ['Master data', 'products, territories, areas, shops on my beat', 'long', 'on app foreground'],
    ['Operational lists', 'my trade orders, open offers, hold list', 'short', 'on screen focus; pull to refresh'],
    ['Money', 'exposure, pledges, outstanding, reconciliation', 'never served stale', 'spinner, or an explicitly stale-marked value with its time'],
    ['Countdowns', 'hold, claim and payment windows', 'not cached', 'derived from server `expires_at` (§6.3)'],
  ], { widths: [0.18, 0.37, 0.17, 0.28], caption: 'Read-cache classes (Spec A §7.5) with the Monvelo additions.' });
  errorSection(r);

  // ── 4 ─────────────────────────────────────────────────────────────────
  r.h1('Authentication and Security Stack');
  r.h2('What the backend provides today');
  r.table(['Mechanism', 'Backend fact', 'Where'], [
    ['Phone sign-in', 'Supabase Auth phone OTP. The **Send SMS hook** (`send-auth-sms`) sends the code over **WhatsApp only** (`teafair_otp` template), and only when `auth_sms_allowed` holds: the account\'s own verified profile phone, plus a platform role or an ACTIVE or INVITED membership. Twilio is never used. An optional KudiSMS fallback is controlled by `AUTH_OTP_SMS_FALLBACK`.', 'M1, `20261024170000_auth_hooks`'],
    ['Account creation', 'Self-serve sign-up is **off**. Accounts are created through the Admin API with a confirmed phone. `invite_tenant_user` finds only confirmed phones (H1).', '`20261024150000`'],
    ['Email', 'The **Send Email hook** (`send-auth-email`, Resend) sends recovery, signup, invite and email-change mail. Magic links, email OTP and reauthentication are refused. Passwords are at least 12 characters, and the reset page is `/reset-password`.', 'auth hardening'],
    ['Tenant claims', 'The Custom Access Token Hook (`auth-verify-claims`) puts `active_tenant_id` and the roles in `app_metadata`. `set_active_tenant(p_idempotency_key, p_tenant_id)` proposes a switch; the database checks membership live.', 'Spec A §5'],
    ['Transaction PIN', 'A 4-digit PIN, bcrypt-hashed in `tenant_users.pin_hash`, verified **at the gateway** (`requirePin`). Five failures lock it for 15 minutes. A single-use pass lasts 60 s, so calling the RPC directly still needs the PIN.', 'Spec A §5.5'],
    ['Owner codes', '6-digit codes drawn by the database (`issue_otp`, rejection-sampled, bcrypt-stored). They are sent over WhatsApp to the owner\'s verified phone and never returned to the client. Monvelo delivery and repayment codes follow the same pattern.', 'H2; A6 §19'],
  ], { widths: [0.16, 0.6, 0.24], caption: 'Authentication building blocks in the backend.' });

  r.h2('Proposal: two sign-in experiences on one mechanism');
  r.p('The brief asked for passwordless login for shop owners and POS agents and password login for internal field roles. Spec A leaves the login method open, so this is a Spec B decision. The recommendation keeps **one server mechanism** (phone + WhatsApp code), already hardened and tested, and changes only how often each persona must sign in again and what guards each action.');
  r.table(['Persona', 'Sign-in', 'Re-authentication', 'Action guard'], [
    ['Shop owner (RETAIL_SHOP_OWNER)', 'Phone + WhatsApp code', 'Long session; biometric unlock of the stored session', 'Owner codes read out to the deliverer or recorder; PIN where Spec A requires it (`record_dsa_stock_issue`)'],
    ['Monvelo agent member', 'Phone + WhatsApp code', 'Biometric unlock; code again after 7 days idle (proposal)', 'Funding is bank transfer from the bound account (payer binding F1)'],
    ['Street agents (ZSA, ASA), DSA', 'Phone + WhatsApp code', 'Biometric unlock; code again daily (proposal)', 'PIN for deferred pickups and PIN-gated calls'],
    ['Managers (ZSM, TM, ASM, DSM), CSM, LM, TENANT_ADMIN', 'Phone + WhatsApp code; **optional email + password (≥ 12 characters) as a second factor** if Spec B adopts it', 'Session no longer than one working day', 'PIN for `approve_requisition` at TM/ZSM, `set_brand_approval_policy`, `adjust_inventory`'],
  ], { widths: [0.22, 0.24, 0.27, 0.27], caption: 'Proposal for Spec B. The password column needs an owner decision: today email is a recovery and invite channel, not a sign-in route.' });
  r.callout('warn', 'Decision needed before Spec B', [
    'A password login for field roles would make email a sign-in route. Today the backend deliberately refuses email OTP and magic links. Enabling passwords means accepting email + password at the Auth layer and writing a rule for who may use it. If the goal is a stronger factor for managers, the recommended route is the existing transaction PIN plus a short session, not a second login path.',
  ]);

  r.h2('Secure storage');
  r.table(['Data', 'Store', 'Rule'], [
    ['Supabase session (access and refresh token)', '**Expo SecureStore** (Keychain / Android Keystore), as the supabase-js `storage` adapter', 'Never in MMKV, AsyncStorage or logs. Cleared on sign-out and on a 401 that refresh cannot fix.'],
    ['MMKV encryption key', 'SecureStore, generated on first launch', 'MMKV opened with `encryptionKey`. The queue holds business payloads, so it is encrypted at rest.'],
    ['Offline queue and read cache', '**MMKV** (`src/store/mmkvStorage.ts`, Spec A §7.1)', 'Bounded: a few thousand rows. Money is never served stale.'],
    ['PIN, owner codes, consent codes', '**Nowhere**', 'Typed, sent once, cleared from state. Never cached (Spec A §7.4: caching a verifier defeats the control).'],
    ['Other people\'s contact details', '**Nowhere**', 'Buyer contacts and owner phones never reach the app, except where an RPC returns them to the ZSM or TM.'],
    ['Device registration', '`register_device(p_idempotency_key, p_hardware_id, p_device_model, p_push_token)`', 'Called after sign-in and on push-token rotation.'],
  ], { widths: [0.25, 0.33, 0.42], caption: 'Where each class of secret lives on the device.' });
  r.bullets([
    '**Sign-out** wipes SecureStore, the MMKV cache and Zustand state. Queued entries are kept but parked until the same profile signs in again. They are never replayed under another user.',
    '**Tenant switch** drains or parks the queue first, because each entry was enqueued under a tenant claim.',
    '**Screenshots:** block them (Android `FLAG_SECURE`, iOS overlay on background) on the code-entry, funding and reconciliation screens.',
  ]);

  // ── 5 ─────────────────────────────────────────────────────────────────
  r.h1('Roles, Navigation and Persona Workflows');
  r.h2('Roles in the schema');
  r.table(['Enum', 'Values'], [
    ['tenant_role_enum', s.enumValues('tenant_role_enum').join(', ')],
    ['platform_role_enum', s.enumValues('platform_role_enum').join(', ')],
  ], { widths: [0.25, 0.75], mono: [0] });
  r.p('The field force is Teafair staff (A6 §17.2). A ZSM is a Teafair official covering one or more zones (zones are states), with one membership per tenant served. The active tenant decides which brand\'s book a screen shows. Navigation is built from the **live** role list in the JWT, re-read after each `set_active_tenant`.');
  r.h2('Workspaces');
  r.table(['Workspace', 'Roles', 'Primary tabs (proposal)'], [
    ['Field management', 'ZSM, TM, ASM', 'Today · Approvals (requisitions, financing above limit) · **Holds** (ZSM, §6) · Team · Inbox (A4 chat)'],
    ['Street sales', 'ZSA, ASA', 'Beat (shops in my area or zone) · Trade orders · Monvelo (consent, supply days, requests) · **Holds** (ASA only) · Lenders (summary, §7.4)'],
    ['Direct sales', 'DSM, DSA', 'Pickups · Orders · Links (A1 referral links). Not part of Monvelo.'],
    ['Shop owner', 'RETAIL_SHOP_OWNER', 'My shop · Deliveries (read the code out) · Repayments · Credit (limits, consent, withdraw)'],
    ['Monvelo agent', 'members of a `monvelo_agents` row (no tenant role)', 'Offers · My claims · Fund · Repayments · Exposure (§7) · Reconciliation'],
    ['Tenant representation', 'CLIENT_SERVICE_MANAGER, LOGISTICS_MANAGER, TENANT_ADMIN', 'Contact reports · Catalogue · Stock · Dispatch (LM) · read-only book (TENANT_ADMIN). Mostly a web console concern.'],
  ], { widths: [0.18, 0.27, 0.55], caption: 'Role-based workspaces. A person can hold several; the switcher lists them.' });

  r.h2('Street recruitment and Monvelo initialisation (ZSA and ASA)');
  r.p('ZSAs and ASAs load Monvelo once per shop and per agent, then raise requests on supply days. Each step is one RPC or gateway. The consent and delivery codes go to the owner\'s verified phone, never to the street agent.');
  r.flow([
    ['Nominate agent', '`nominate_monvelo_agent`'],
    ['Agent registers', '`monvelo-agent-register` (Paystack account resolve)'],
    ['Shop consent', '`monvelo-shop-consent` → `enrol_monvelo_shop`'],
    ['Supply day', '`set_monvelo_supply_day`'],
    ['Trade order', '`place_trade_order` (whole packs, wholesale)'],
    ['Request', '`request_monvelo_financing`'],
  ], { caption: 'Initialisation and request sequence for a ZSA or ASA.' });
  r.table(['Step', 'Call', 'Screen behaviour'], [
    ['Nominate a POS agent the shop trusts', s.sig('nominate_monvelo_agent'), 'Store only the last four digits of the phone in local state after submit; the RPC keeps four digits too.'],
    ['Owner consent (MV-SHARE-2026-10)', 'gateway `monvelo-shop-consent` → ' + s.sig('enrol_monvelo_shop'), 'Show the consent text in full (the WhatsApp template carries none). The owner reads the code to the agent, who types it in. A wrong code is a 422.'],
    ['Supply day for an area', s.sig('set_monvelo_supply_day'), 'A weekday toggle per area (`p_day_of_week`, `p_active`), limited to the caller\'s areas. Show the next supply dates in Lagos time.'],
    ['Trade order', s.sig('place_trade_order'), 'Quantity steppers move in **break-bulk packs** (§8). Prices are wholesale and read-only.'],
    ['Financing request', s.sig('request_monvelo_financing'), 'Result OFFERED (within the shop\'s limit) or AWAITING_APPROVAL (the TM approves). A raiser whose PAR30 is above 10% is refused, with a message.'],
  ], { widths: [0.22, 0.43, 0.35], mono: [1], size: 8.3 });

  // ── 6 ─────────────────────────────────────────────────────────────────
  r.h1('Monvelo Market-Maker Allowance UI');
  r.p(`A claim blocked **only** by the ${CAP} open exposure cap is held for 15 minutes instead of being refused, provided the agent's open exposure including this financing stays within ${ALLOW}. During the hold no other agent can claim the request. A market maker in scope (a ZSM whose reach covers the zone, or the area's ASA) may allow it with a reason or decline it. Approved 2026-11-02 (A6 §20; decisions 1A, 2A, 3A).`);
  r.flow([
    ['Agent claims', 'OFFERED request'],
    ['Only the exposure cap blocks', `≤ ${ALLOW} incl. this one`],
    ['HELD 15 min', 'exclusive; market makers notified'],
    ['ALLOW (reason ≥ 10)', 'every check re-run; CLAIMED, new 15-min payment window'],
    ['Agent funds', '`monvelo-fund`, bank transfer'],
  ], { caption: 'Hold lifecycle on the happy path. DECLINED returns OFFERED; no decision in 15 minutes is LAPSED (OFFERED).' });

  r.h2('Who sees what');
  r.table(['Actor', 'Sees', 'Never sees'], [
    ['Agent member (claimant)', 'Claim reply `{held: true, hold_id, expires_at, financing_id, reference, status, principal}`; then a `MONVELO_HOLD_DECIDED` notice (allowed, declined or lapsed).', 'Who decided.'],
    ['Market maker: ZSM in reach, or the area\'s ASA', 'The hold list and detail: the request, the shop\'s record and limits **in this tenant**, the blocks, `within_limit`, `ready`, and once decided their own name, time and reason.', 'The agent\'s name, id, phone, network, location and own figures (exposure, pledge left).'],
    ['The request\'s raiser; any member of the held agent (R78)', 'Nothing. The hold is not listed, no notice is sent, and get or decide returns 42501.', 'The hold.'],
    ['ZSA, TM, CSM, TENANT_ADMIN, LM', 'Nothing (42501 on the three RPCs).', 'The hold.'],
  ], { widths: [0.24, 0.48, 0.28], caption: 'Visibility (A6 §20.6, call 9, R78).' });

  r.h2('Component: HoldCard and the countdown');
  r.bullets([
    '**Source of time.** The countdown runs to the server\'s `expires_at` (timestamptz). The app computes a clock offset from the HTTP `Date` header of the list call (`offset = serverNow − Date.now()`) and renders `expires_at − (Date.now() + offset)`, so a phone with a wrong clock still shows the right time left. It never extends locally.',
    '**Display.** `mm:ss`, monospaced digits, ticking each second. Amber below 5:00, red below 1:00. At 0:00 the card turns **Lapsed (awaiting sweep)**, the Allow and Decline buttons are disabled, and the list refreshes. The sweep runs every minute, and an allow after `expires_at` is refused as lapsed anyway (R69).',
    '**Status chips** from `monvelo_claim_holds.status`: ' + s.checkValues('monvelo_claim_holds.status').join(' · ') + '. HELD cards sort first, then decided cards from the last 7 days (the RPC\'s order).',
    '**Lagos time** for every absolute time ("expires 14:32"), matching the WhatsApp notice text.',
    '**Accessibility.** Announce the remaining time at 5:00, 1:00 and lapse through an accessibility live region, not every second.',
  ]);
  r.h2('Component: readiness and credit badges');
  r.p('The view is pass or fail by design (call 9). It never shows the agent\'s raw exposure. Badges map one to one onto the returned fields.');
  r.table(['Badge', 'Field', 'States', 'Copy (proposal)'], [
    ['Funding side ready', '`ready boolean`', 'false while HELD; true once allowed', '"Waiting for a market maker" / "Ready to fund"'],
    ['Block', '`blocks text[]`', '`EXPOSURE_CAP` (the only value the CHECK allows)', `"Over the ${CAP} open exposure cap"`],
    ['Within the allowance', '`within_limit boolean`', 'pass (green) / fail (red); live while HELD, frozen once decided (R72)', `"Within ${ALLOW}: yes" / "no — cannot be allowed"`],
    ['Daily cap', 'none: never a hold', 'A daily-cap block is refused at claim time, so it never reaches this screen (decision 3A)', 'Explain in a help sheet: "The agent\'s own daily cap is set by Monvelo staff and is never overridden."'],
    ['Shop record', '`shop_repaid_in_window`, `shop_repaid_late`, `shop_defaulted`, `shop_open`, `shop_limits`', 'counts in this tenant; limits per brand', '"Repaid on time 6 · late 1 · defaulted 0 · open 1"'],
  ], { widths: [0.17, 0.27, 0.28, 0.28], caption: 'Readiness badges against the hold result columns.' });
  r.callout('note', 'Protecting the personal daily cap (choice 3A)', [
    `Only the ${CAP} exposure cap can be lifted. The agent's \`daily_cap\` and per-financing cap are set by Monvelo staff (\`set_monvelo_agent_caps\`) and stand. If \`within_limit\` is true but an allow is refused, the database re-ran every check (the daily cap included) under the agent's advisory lock and found a new block. The app then shows the P0001 text verbatim, and the hold stays HELD.`,
  ]);
  r.h2('Component: the decision sheet');
  r.table(['Control', 'Rule', 'Source'], [
    ['Reason text box', 'Required to **Allow**; trimmed length ≥ 10 and ≤ 1000 characters. Live counter "7 / 10 minimum". Allow stays disabled until valid. Optional for **Decline**.', '22023 "give a reason of at least 10 characters to allow"; R77'],
    ['Allow', 'Confirm sheet: "You are allowing this agent to fund ₦X for <shop>. You are accountable for this decision." Single tap, then a spinner. No retry on 422.', '`decide_monvelo_claim_hold(…, p_allow => true, p_reason)`'],
    ['Decline', 'Confirm sheet. The declined agent can never reclaim this request.', 'call 8'],
    ['Idempotency', 'Generate the key when the sheet opens; reuse it for retries of that same decision only.', 'Spec A §7.2'],
    ['Online only', 'Disabled offline with "Decisions need a connection: the hold expires in mm:ss".', 'the 15-minute window'],
  ], { widths: [0.18, 0.55, 0.27], caption: 'Decision sheet rules.' });
  r.h3('Outcomes the sheet must handle');
  r.table(['Response', 'Meaning', 'UI'], [
    ['`{status: CLAIMED, hold_status: ALLOWED …}`', 'Allowed. The agent now has 15 minutes to pay.', 'Card → Allowed; toast "Allowed. The agent has been told to pay."'],
    ['`{status: OFFERED, hold_status: DECLINED …}`', 'Declined; the request is open to other agents.', 'Card → Declined.'],
    ['P0001 "this hold has already been decided"', 'Another market maker acted first.', 'Refresh; show who decided only if it was you.'],
    ['P0001 "this hold has lapsed"', '15 minutes passed.', 'Card → Lapsed.'],
    ['P0001 with a refusal sentence', 'A re-run check failed (daily cap, pledge, freeze …).', 'Show the sentence; the hold stays HELD.'],
    ['42501 "this hold is not yours to decide"', 'Out of scope, the raiser, or a member of the agent.', 'Remove the card; neutral message.'],
  ], { widths: [0.36, 0.32, 0.32], mono: [0], size: 8.3 });
  r.h2('Four-eyes segregation of duties (choice 2A)');
  r.p('The rule: **whoever raised the request (`monvelo_financings.raised_by`) can never allow or decline its hold**, and neither can anyone with a membership row in the held agent, ACTIVE or REVOKED (R78). The database enforces it three times. The raiser is excluded from the market makers notified (`monvelo_hold_market_makers`), excluded from the list (`monvelo_claim_hold_rows`), and refused by `decide_monvelo_claim_hold` with 42501.');
  r.bullets([
    '**The client mirrors the rule and never replaces it.** The hold list comes from the server already filtered, so the app never needs to know who the raiser was, and must not try to compute it.',
    '**Raiser-side UX.** An ASA who raised a request that is now held sees on their own request: "Waiting for another market maker (you raised this request)". The status comes from `monvelo_order_financing_status`; no hold id is exposed.',
    '**When nobody else is in scope**, the hold can only lapse. The app does not offer an escalation that would bypass this.',
    '**Testing.** Keep a UI test that signs in as the raiser and asserts the hold is absent, alongside pgTAP 066, which proves the server side.',
  ]);
  r.h2('Hold result contract');
  r.table(['Column', 'Type'], holdCols, { widths: [0.4, 0.6], mono: [0, 1], size: 8.2, caption: '`list_monvelo_claim_holds()` and `get_monvelo_claim_hold(p_hold_id)` return these columns (parsed from the migrations).' });

  // ── 7 ─────────────────────────────────────────────────────────────────
  r.h1('Agent Exposure and Reconciliation Views');
  r.h2('How open exposure is computed (A6 §19.4.1, §20 call 4)');
  r.table(['Financing status', 'Counts toward exposure', 'Why'], [
    ['HELD', 'principal', `Two holds cannot together pass ${ALLOW} (call 4).`],
    ['CLAIMED (by `claimed_by_agent_id`)', 'principal', 'The agent has committed to pay.'],
    ['FUNDED (by `funder_agent_id`)', 'principal', 'Money is out, stock not yet delivered.'],
    ['DELIVERED, DEFAULTED_WITH_LATE_CHARGE', '**least(outstanding, principal)**', 'Part repayments free room; the late charge never consumes room.'],
    ['REFUND_DUE', 'nothing', 'R63: "the central truth is funded order fulfilment". Room frees at the sweep; only the pledge waits for the refund.'],
    ['OFFERED, REPAID_*, EXPIRED, CANCELLED', 'nothing', 'No agent owns it, or it is closed.'],
  ], { widths: [0.32, 0.25, 0.43], caption: 'Exposure is summed across every tenant the agent funds.' });
  r.p(`The ceiling is one platform constant (\`monvelo_open_exposure_ceiling()\` = ${CAP}); the allowance ceiling is \`monvelo_allowance_ceiling()\` = ${ALLOW}. Both are changed by migration only. The claim refusal text is built from the constant: "this request would take your open exposure above ${CAP}".`);
  r.callout('warn', 'The agent\'s own caps bind first (A6 §21.2)', [
    `From 2026-11-03 the platform ceiling is ${CAP} and the allowance ceiling ${ALLOW} (migration \`20261031121100\`, ten times the original limits, keeping the 1:3 ratio).`,
    'An agent\'s `daily_cap` and `per_financing_cap` start at ₦0.00 (`monvelo_agents` defaults) and are provisioned per agent by Monvelo staff with `set_monvelo_agent_caps`. Until they are raised, an agent hits its personal limit long before the platform ceiling.',
    'A market maker cannot lift a personal cap (rule 3A, A6 §20.2 decision 7): only the exposure ceiling can be allowed past. Provisioning caps is therefore part of onboarding every agent, not an optional tuning step.',
  ]);
  r.h2('The exposure meter (component spec)');
  r.bullets([
    '**Audience:** members of a Monvelo agent, for their own agent only. Never market makers, tenants or ZSAs.',
    `**Visual:** a horizontal meter from ₦0 to ${CAP}, with a marker for the ${ALLOW} allowance zone shown as a dashed extension. Segments are stacked by status (HELD, CLAIMED, FUNDED, DELIVERED/DEFAULTED at the least of outstanding and principal), each with a legend and amount.`,
    `**Headroom line:** "₦X left under the cap". At or above the cap: "New claims above this need a market maker's allowance, up to ${ALLOW}".`,
    '**Daily cap:** a second, separate meter for today\'s funding against `daily_cap` (Lagos day, REFUND_DUE excluded). It is never merged with exposure, because it can never be allowed past.',
    '**Unprovisioned caps:** while `daily_cap` or `per_financing_cap` is ₦0.00, show an empty state instead of the meters: "Your funding limits have not been set yet. Monvelo will set them before you can claim." Never suggest asking a market maker.',
    '**Freshness:** money class, never stale. Refresh on focus and after every claim, funding, repayment or notice. Show "as of hh:mm" on any cached value.',
  ]);
  r.h2('The meter\'s read path: get_monvelo_agent_exposure (G1, resolved)');
  r.p(`\`${s.sig('get_monvelo_agent_exposure')}\` is read-only (STABLE, SECURITY DEFINER), granted to ${s.callers('get_monvelo_agent_exposure')} only (migration \`${s.fn('get_monvelo_agent_exposure').file}\`, pgTAP 067). \`p_agent_id\` is a \`monvelo_agents.id\`; null means the caller\'s only agent, and a member of several agents must name one (22023). It returns one row:`);
  r.table(['Column', 'Type'], expCols, { widths: [0.4, 0.6], mono: [0, 1], size: 8.2 });
  r.bullets([
    '**Who may call:** an ACTIVE member of the agent, or Monvelo staff (MONVELO_OPERATOR, MONVELO_FINANCE). Everyone else, a ZSM, ASA, ZSA, TM, CSM or TENANT_ADMIN included, and an unknown agent alike, gets 42501 "Unauthorized access to agent exposure metrics". A market maker never sees the agent (§20.2 decision 3) and a tenant never sees a lender (§16.2.2).',
    '**Figures:** `open_exposure` is `monvelo_agent_open_exposure` (REFUND_DUE counts nothing, R63); the ceilings are read from the constants; `personal_daily_limit` and `per_financing_limit` are the agent\'s own caps, 0.00 until Monvelo staff set them (§21.2); `today_utilized_limit` is the claim\'s check 8 (claimed and held now, plus funded this Lagos day unless REFUND_DUE). Both remaining figures floor at 0.00.',
    '**The app** shows these numbers as given and never recomputes a limit. A claim can still be refused after a fresh read, because the database re-checks every limit under the agent\'s lock.',
  ]);
  r.callout('note', 'Finding G1 as first raised (kept for the record)', [
    '`monvelo_agent_open_exposure(p_agent_id)`, `monvelo_open_exposure_ceiling()` and `monvelo_allowance_ceiling()` hold no EXECUTE grant for `authenticated` (verified from the grants), and no granted RPC returns them. The agent\'s members cannot compute it client-side either: the lender columns of `monvelo_financings` are outside the column grant (R9), and HELD holds are unreadable (`monvelo_claim_holds` has no policy).',
    '**Recommendation (done 2026-11-03):** a read-only SECURITY DEFINER RPC, `get_monvelo_agent_exposure(p_agent_id uuid)`, granted to `authenticated`, checking live that the caller is an ACTIVE member of the agent. Built as migration `20261031121200` with pgTAP 067; Monvelo staff may call it too. The per-status breakdown was left out: `active_commitments_count` gives the count, and the status list is the agent\'s own financings.',
  ]);
  r.h2('Weekly lender reconciliation (get_lender_reconciliation_summary)');
  r.p('`get_lender_reconciliation_summary(p_weeks integer default 12)` returns one row per agent and **Lagos week of `funded_at`**. Weeks are `date_trunc(\'week\', funded_at at time zone \'Africa/Lagos\')`, so each week starts on a **Monday** in Lagos. The window runs from this week back `p_weeks − 1` weeks; a `p_weeks` outside 1–52 is 22023. Every figure belongs to its funding week.');
  r.table(['Column', 'Type'], sumCols, { widths: [0.4, 0.6], mono: [0, 1], size: 8.2 });
  r.table(['Reader', 'Rows', 'App surface'], [
    ['ACTIVE member of an agent', 'that agent\'s rows across every tenant (wins over any ZSA/ASA role)', 'Agent workspace → Reconciliation'],
    ['ZSA (active tenant)', 'financings in the tenant whose area lies in the ZSA\'s zone', 'Street sales → Lenders'],
    ['ASA (active tenant)', 'financings in the tenant in the ASA\'s area', 'Street sales → Lenders'],
    ['Everyone else (TM, ZSM, CSM, TENANT_ADMIN, LM, anon)', '42501', 'Hidden'],
  ], { widths: [0.3, 0.42, 0.28], caption: 'Readers, checked live. The ZSA/ASA reading is a deliberate exception to §16.2.2 (owner, 2026-11-02).' });
  r.h3('Screen spec');
  r.bullets([
    '**Week selector:** 4, 12 (default) or 26 weeks. Week labels read "Mon 26 Oct – Sun 1 Nov".',
    '**Per-week card:** capital funded, outstanding, repaid, refunded, rebates owed and paid. `rebates_paid` reads ₦0 until Step 5 ships payouts, so label it "pending payout run".',
    '**MV references** in a collapsible list (`MV-XXXXXXXX-n`), copyable, for matching bank statements.',
    '**Anonymised by contract:** the output never names a shop, owner, phone, brand, tenant or place, and the app adds nothing from other sources. For ZSA/ASA readers, `agent_name` is the registered business name; group by agent within each week.',
    '**Totals row** computed client-side with decimal arithmetic from the string values; never floats.',
  ]);

  // ── 8 ─────────────────────────────────────────────────────────────────
  r.h1('Trade Orders, Packs and Owner Codes');
  r.h2('Break-bulk in the app');
  r.p('Prices are stored **per unit**: `unit_price` is retail and `wholesale_price` is wholesale. `carton_units` and `break_bulk_units` define the packs; the generated columns `carton_wholesale_price` and `break_bulk_wholesale_price` give pack prices. **Every app sale (FIELD_SALES, RETAIL, pickups) is wholesale and in whole packs**. The table triggers refuse anything else with P0001, so the UI should make the wrong quantity impossible rather than wait for the refusal.');
  r.table(['SKU', 'Carton', 'Break-bulk pack', 'Wholesale / unit', 'Pack price', 'Carton price'], [
    ['PURERIGIN-COCONUT-OIL-200ML', '12', '3 (quarter)', '₦4,000', '₦12,000', '₦48,000'],
    ['PURERIGIN-COCONUT-OIL-100ML', '24', '6 (quarter)', '₦2,500', '₦15,000', '₦60,000'],
  ], { widths: [0.3, 0.1, 0.16, 0.15, 0.14, 0.15], mono: [0], caption: 'Teafair\'s house brand as seeded (COSMETICS, NAFDAC LG-IKJ-02-2134).' });
  r.bullets([
    '**Stepper:** steps by `break_bulk_units` (else `carton_units`, else 1). It shows "3 packs × 3 = 9 bottles" and the line total at `break_bulk_wholesale_price`.',
    '**Stock:** a TF001 reply carries `{sku_code, available, requested}`. Offer "reduce to N packs".',
  ]);
  r.h2('Delivery and repayment codes');
  r.p('The shop owner\'s 6-digit codes go over WhatsApp to the owner\'s verified phone. The deliverer (a holder of a `fulfilment_delivery_path`) or the recording agent member types in the code the owner reads out. A wrong, expired or locked code is a 422. Delivery is refused from `funded_at + 23 h`; the money sweep moves the financing to REFUND_DUE at that same instant.');
  r.table(['Flow', 'Start', 'Confirm', 'UI notes'], [
    ['Delivery', 'gateway `monvelo-confirm-delivery` → `start_monvelo_delivery`', s.sig('confirm_monvelo_delivery'), 'Show the 23-hour cutoff as a countdown from `funded_at`; a fresh idempotency key for every code entry.'],
    ['Repayment', 'gateway `monvelo-confirm-repayment` → `record_monvelo_repayment`', s.sig('confirm_monvelo_repayment'), 'The amount is capped at `outstanding`. Only the recording member may confirm. A PENDING repayment expires at 24 h.'],
    ['Owner rejects', '—', s.sig('reject_monvelo_repayment'), 'Owner workspace: "This payment did not happen". Raises a flag and a HIGH ticket.'],
  ], { widths: [0.13, 0.27, 0.33, 0.27], mono: [2], size: 8.2 });

  // ── 9 ─────────────────────────────────────────────────────────────────
  r.h1('Design System and Accessibility');
  r.p('The app uses NativeWind with the `teafair-*` tokens from `FIGMA.md` (locked 2026-10-07). Stock palette classes are never used for brand elements. The slate, teal and navy palette of this PDF is a documentation palette only; it is not the app\'s.');
  r.table(['Token', 'Hex', 'Use in the Monvelo screens'], [
    ['teafair-emerald', '#4CAF50', 'Primary actions (Allow, Fund, Confirm code)'],
    ['teafair-lime', '#8BC34A', `Pass badges ("within ${ALLOW}: yes", "Ready to fund")`],
    ['teafair-forest', '#2E7D32', 'Headers, the meter\'s funded segment'],
    ['teafair-black', '#111111', 'Primary text'],
    ['teafair-surface', '#F5F7F6', 'Cards, inputs'],
    ['teafair-darkSurfaceEnd', '#1A2E1B', 'Dark-mode surface gradient end'],
  ], { widths: [0.25, 0.15, 0.6], mono: [0, 1], caption: 'Brand tokens (FIGMA.md). Warning and error tones need tokens added in Spec B; none exist yet.' });
  r.bullets([
    '**Gap G6:** FIGMA.md defines no warning or error colours. The countdown\'s amber and red, and the fail badge, need `teafair-*` tokens agreed in Spec B. Until then they must not fall back to stock classes.',
    '**Touch targets** at least 48 dp. Money in tabular figures. The naira sign is rendered as text, not an icon.',
    '**Language:** plain English first. Pidgin and Yoruba copy are a later localisation pass; server messages arrive in English.',
  ]);

  // ── 10 ────────────────────────────────────────────────────────────────
  r.h1('Audit Findings and Gaps');
  r.table(['ID', 'Severity', 'Finding', 'Recommendation'], [
    ['G1', 'High (resolved)', 'No granted RPC returned an agent\'s open exposure, the ceilings or today\'s funding against `daily_cap`.', '**Resolved 2026-11-03:** `get_monvelo_agent_exposure` (read-only; members and Monvelo staff; migration `20261031121200`, pgTAP 067).'],
    ['G2', 'High', 'The login method is unspecified in Spec A; the brief\'s password login for field roles conflicts with the hardened phone-only route.', 'Decide in Spec B (§4.2 proposal).'],
    ['G3', 'Medium', 'The claim is a direct RPC; A6 §20.9 left open whether the held reply needs a gateway. The app must branch on `held` in the RPC result.', 'Keep it direct; document `held` in the Spec B API layer.'],
    ['G4', 'Medium', 'Notices (`MONVELO_HOLD`, `MONVELO_HOLD_DECIDED`) are `notifications` rows. Push delivery needs `register_device` push tokens and a sender, which do not exist yet.', 'Spec B: Realtime on `notifications` while foregrounded; push sender in a later addendum.'],
    ['G5', 'Medium', 'Step 5 (rebate payouts) is not built; `rebates_paid` is always 0.', 'Label it in the UI; no client workaround.'],
    ['G6', 'Low', 'No warning or error colour tokens in FIGMA.md.', 'Add them with Spec B.'],
    ['G7', 'Low', 'Nothing after 20261015130200 is on the remote; a client built now runs against the local stack only.', 'Plan the deploy order (D1 → A3/A4 → A5 → pricing → auth → A6) before any device testing against the remote.'],
  ], { widths: [0.06, 0.1, 0.46, 0.38], caption: 'Findings ranked by severity.' });

  // ── appendices ────────────────────────────────────────────────────────
  contractAppendix(r, s, 'Appendix A — Mobile RPC Contracts', [
    ['Session and identity', ['set_active_tenant', 'register_device', 'verify_pin']],
    ['Street agents and recruitment', ['nominate_monvelo_agent', 'start_monvelo_consent', 'enrol_monvelo_shop', 'withdraw_monvelo_shop_consent', 'set_monvelo_supply_day', 'place_trade_order', 'request_monvelo_financing', 'approve_monvelo_financing', 'cancel_monvelo_financing', 'monvelo_order_financing_status']],
    ['Monvelo agents', ['pledge_monvelo_funds', 'monvelo_supply_days_near', 'monvelo_open_offers', 'claim_monvelo_financing', 'start_monvelo_funding', 'record_monvelo_repayment', 'confirm_monvelo_repayment']],
    ['Market makers', ['list_monvelo_claim_holds', 'get_monvelo_claim_hold', 'decide_monvelo_claim_hold']],
    ['Delivery and owners', ['dispatch_monvelo_financing', 'start_monvelo_delivery', 'confirm_monvelo_delivery', 'reject_monvelo_repayment']],
    ['Reconciliation', ['get_lender_reconciliation_summary']],
  ]);
  r.h1('Appendix B — Enumerations, Statuses and Jobs');
  enumAppendix(r, s, ['tenant_role_enum', 'platform_role_enum', 'order_channel_enum', 'pos_network_enum', 'kyc_status_enum'],
    ['monvelo_financings.status', 'monvelo_claim_holds.status', 'monvelo_repayments.status', 'monvelo_tenant_ledger_entries.entry_type']);
  r.h2('Scheduled jobs the app depends on');
  r.table(['Job', 'Schedule (UTC)', 'Defined in'], [...s.cron.entries()].filter(([k]) => /monvelo|stock/.test(k)).map(([k, v]) => [k, v.schedule, v.file]),
    { widths: [0.3, 0.2, 0.5], mono: [0, 1, 2], size: 8.2, caption: 'The hold lapses within a minute of expires_at; REFUND_DUE and expired repayments within five.' });
  r.h2('Gateways used by the app');
  r.p(s.edgeFunctions.filter((n) => /monvelo|order-|otp|contact|support-staff|auth-verify/.test(n)).map((n) => `\`${n}\``).join(' · '));
}
