# Monvelo Market-Maker Allowance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A claim blocked only by the ₦100,000 open exposure cap is held for 15 minutes, exclusively, and a ZSM or ASA in scope (never the request's raiser) may allow it up to ₦300,000 of the agent's open exposure, without ever seeing the agent.

**Architecture:** All in Postgres, as the rest of Monvelo: one new status (`HELD`), one new table (`monvelo_claim_holds`), a changed claim refusal and claim RPC, three new market-maker RPCs, and the offers sweep and late route taught about holds. No gateway: the claim and the market-maker RPCs are called directly over PostgREST with the user's JWT, as `claim_monvelo_financing` is today.

**Tech Stack:** Supabase Postgres (plpgsql, SECURITY DEFINER RPCs, RLS), pgTAP.

**Spec:** `docs/superpowers/specs/2026-10-28-addendum-a6-monvelo-design.md` §20 (approved by the user 2026-11-02), read with §7.1, §16.2.2, §18.2 and §19.4.

## Global Constraints

- Every mutation is a `SECURITY DEFINER` RPC with `SET search_path = public, pg_temp`, taking `p_idempotency_key uuid` first (`idempotency_begin` / `idempotency_finish` as the existing Monvelo RPCs do). Reads take no key.
- The tenant is never a parameter. Market makers are checked live: `assert_tenant_role(array['ZSM','ASA'])` against the JWT's active tenant, re-verified against `tenant_users`.
- RLS is `FOR SELECT` only. `monvelo_claim_holds` has RLS on and **no policy**, and no column granted to `authenticated`.
- **The market maker never sees the agent** (§20.2 decision 3): no agent name, id, phone, network, location, or the agent's own figures (exposure, pledge) in any market-maker output or notification (§20.3 call 9).
- Audit rows naming an agent, a pledge or a payer are written with `tenant_id` null (R15).
- Money `numeric(15,2)`; timestamps `timestamptz`; Lagos dates through `at time zone 'Africa/Lagos'`. Monvelo rows are never deleted (`monvelo_no_delete()` triggers on the new table).
- The values: platform ceiling `monvelo_open_exposure_ceiling()` = `100000.00`; the market-maker limit **`300000.00`**, as a new IMMUTABLE ungranted function `monvelo_allowance_ceiling()`; the hold lasts **15 minutes**; an allow needs a reason of **at least 10 characters**.
- Only the ₦100,000 exposure cap is allowable. The daily cap, the per-financing cap and every other refusal are never lifted (§20.2 decision 7, §20.3 call 1).
- Commits stay on `feat/monvelo-step1`. No merge, push or deploy. Use `supabase migration up`; the user runs `npx supabase db reset` before each full suite run.

## Review Focus

1. **A held request at the end of its supply day:** the supply-day expiry that today moves OFFERED requests to EXPIRED must also end a HELD one (hold → LAPSED, financing → EXPIRED), or a hold could outlive its day. Test in Task 1.
2. **The stock sweep cancelling a HELD request's trade order** (unpaid PENDING order): the financing must leave HELD the same way it leaves OFFERED today, and the hold must end LAPSED. Test in Task 1.
3. **Two holds by one agent:** the second hold must see the first at its principal (call 4), so together they never pass ₦300,000. Test in Task 1.
4. **An allow after the world moved:** the agent was suspended, frozen, lost pledge or passed the daily cap after the hold was made; the allow is refused and the hold stays HELD until a decline or the lapse. Test in Task 2.
5. **The raiser who is also the only market maker in scope:** they see nothing actionable and cannot decide (42501); the hold lapses at 15 minutes. Test in Task 2.

---

### Task 1: The hold: status, table, refusal, claim, sweeps

**Files:**
- Create: `supabase/migrations/20261031120800_monvelo_claim_holds.sql`, `supabase/tests/database/066_monvelo_claim_holds.test.sql`
- Modify: `001` (`tables_are` gains `monvelo_claim_holds`), `003` (the no-policy table list gains it), `045` only if its Monvelo boundary guard needs the new names, and any 061/065 assertion that pins the old claim refusal behaviour

**Interfaces:**
- Consumes: `monvelo_claim_refusal(p_fin, p_agent, p_member, p_pledge, p_late)` (latest in `20261031120700`); `claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid) returns jsonb` (latest in `20261031120050`); `monvelo_sweep_offers()` (latest in `20261031120050`); `monvelo_financings_guard()` (latest in `20261031120000`); `monvelo_agent_open_exposure(uuid)` (latest in `20261031120700`); `monvelo_open_exposure_ceiling()`.
- Produces:
  - `monvelo_financings.status` gains `'HELD'`; guard transitions OFFERED → HELD and HELD → CLAIMED | OFFERED | CANCELLED | EXPIRED;
  - `monvelo_claim_holds(id uuid pk, tenant_id uuid, financing_id uuid, agent_id uuid, claimed_by uuid, blocks text[], exposure_before numeric(15,2), exposure_after numeric(15,2), pledge_remaining numeric(15,2), created_at timestamptz, expires_at timestamptz, status text check in ('HELD','ALLOWED','DECLINED','LAPSED'), decided_by uuid null, decided_at timestamptz null, reason text null)`, partial unique `(financing_id) where status = 'HELD'`, insert-only apart from the one HELD → final move (guard trigger), `monvelo_no_delete()` triggers, RLS on, no policy, nothing granted;
  - `monvelo_allowance_ceiling() returns numeric` IMMUTABLE → `300000.00`, ungranted;
  - `monvelo_claim_refusal` gains a trailing `p_exposure_ceiling numeric default null` (null = `monvelo_open_exposure_ceiling()`); it is dropped and recreated (a new parameter), callers unchanged;
  - `claim_monvelo_financing` returns `{held: true, hold_id, expires_at}` when the only refusal is the exposure cap and the claim passes at `monvelo_allowance_ceiling()`.

- [ ] **Step 1: Write the failing tests in `066`** (section A, about 35 assertions; scope every count to the file's own fixtures):
  - `held_when_only_the_exposure_cap_blocks`: an agent at 90,000 open claims a 20,000 request → reply `held = true`, financing `HELD`, one hold `HELD` with `blocks = '{EXPOSURE_CAP}'`, `exposure_before = 90000.00`, `exposure_after = 110000.00`, `expires_at = now() + interval '15 minutes'`;
  - `refused_above_300000`: an agent at 290,000 open claims 20,000 → P0001 with the exposure message, no hold;
  - `daily_cap_is_never_held`: the daily cap blocks (exposure fine) → P0001 as today, no hold; both caps block → P0001 (daily-cap message), no hold;
  - `other_refusals_are_never_held`: a short pledge, a suspended agent, the default freeze → P0001 as today, no hold;
  - `the_hold_is_exclusive`: a second agent claiming the HELD request → P0001 `this request is no longer open`; `monvelo_open_offers` does not list it;
  - `two_holds_respect_300000` (Review Focus 3): agent at 100,000 holds 150,000 (→ 250,000), then claims another 60,000 → refused, no second hold;
  - `held_counts_toward_exposure`: `monvelo_agent_open_exposure` includes the HELD principal;
  - `a_hold_lapses_at_15_minutes`: move `expires_at` into the past as postgres, run `monvelo_sweep_offers()` → hold `LAPSED`, financing `OFFERED`, one tenant-null audit row; the same agent claiming again while the cap still blocks → P0001 `this request was already held for you` (call 8: no second hold), and with the cap now passing → CLAIMED;
  - `a_declined_agent_is_barred` (insert a DECLINED hold as postgres): that agent's claim → P0001 `a market maker declined your claim on this request`;
  - `supply_day_end_lapses_the_hold` (Review Focus 1) and `stock_sweep_ends_the_hold` (Review Focus 2): financing leaves HELD as an OFFERED one would, hold `LAPSED`;
  - `holds_are_private`: TENANT_ADMIN, CSM, ZSM, TM, LM, ASA, ZSA and the agent member read 0 rows / 42501 from `monvelo_claim_holds`; no audit row naming the agent carries a tenant id;
  - `the_hold_row_is_insert_only`: an update other than the final move and a delete are refused.
- [ ] **Step 2: Run `066` and see it fail.** Run: `supabase test db supabase/tests/database/066_monvelo_claim_holds.test.sql` (or the focused form the earlier tasks used). Expected: FAIL (`monvelo_claim_holds` does not exist).
- [ ] **Step 3: Write the migration.** Recreate each consumed function from its latest definition, changing only:
  - `monvelo_claim_refusal`: check 1 is unchanged (it requires `OFFERED`; Task 2's allow path passes the row with `status` read as `OFFERED`, so a HELD request is never claimable by anyone else); check 4 also refuses an agent with a DECLINED hold on the request (`a market maker declined your claim on this request`); check 7's committed pledge and check 8's daily "claimed now" count `HELD` financings held for the agent like `CLAIMED`; the exposure check uses `coalesce(p_exposure_ceiling, monvelo_open_exposure_ceiling())`. The exposure check stays the **last** check, so "the refusal equals the exposure message" means nothing else failed.
  - `monvelo_agent_open_exposure`: counts the agent's HELD financings (agent from the open hold) at `principal`.
  - `claim_monvelo_financing`: after taking its existing locks, if the refusal is the exposure message, run the refusal again with `monvelo_allowance_ceiling()`; if that passes and the agent has no LAPSED hold on this request, insert the hold, move the financing OFFERED → HELD, audit (tenant-null), notify the market makers (Task 2 adds the notice; leave a single call site `monvelo_notify_hold(hold_id)` stubbed as a no-op here) and return `{held, hold_id, expires_at}` through the idempotency reply. Otherwise raise the refusal as today.
  - `monvelo_sweep_offers`: a HELD financing whose hold passed `expires_at` → hold `LAPSED`, financing `OFFERED`, tenant-null audit; existing claim lapses unchanged.
  - The supply-day expiry and the stock sweep's cancellation path: wherever they act on `OFFERED`, act on `HELD` too and end the hold `LAPSED`.
- [ ] **Step 4: Run `066`, then 001, 003, 045, 058, 061–065.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): Monvelo claim holds: a claim blocked only by the ₦100,000 cap is held 15 minutes (A6 §20)`

### Task 2: The market makers: list, view, decide, the late route, notices, docs

**Files:**
- Create: `supabase/migrations/20261031120900_monvelo_market_maker_decisions.sql`
- Modify: `066` (section B), `supabase/CLAUDE.md` (§20 moves from "designed" to built), A6 §20 status line, root `CLAUDE.md` counts

**Interfaces:**
- Consumes: Task 1's `monvelo_claim_holds`, `HELD`, `monvelo_allowance_ceiling()`, `monvelo_claim_refusal(..., p_exposure_ceiling)`, the `monvelo_notify_hold(hold_id)` call site; `settle_monvelo_funding` (latest in `20261031120500`); `notify_tenant_zsms`-style inserts into `public.notifications`.
- Produces:
  - `list_monvelo_claim_holds() returns table(hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text, principal numeric(15,2), brand_lines jsonb, expires_at timestamptz, ready boolean, blocks text[], within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer, shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamptz, reason text)`: the caller's scope (ZSM: areas in `my_zsm_zone_ids()`; ASA: their `area_id`), active tenant, HELD first then the last 7 days; holds whose financing the caller raised are omitted;
  - `get_monvelo_claim_hold(p_hold_id uuid)` returns the same columns for one hold (42501 out of scope or the raiser);
  - `decide_monvelo_claim_hold(p_idempotency_key uuid, p_hold_id uuid, p_allow boolean, p_reason text) returns jsonb` → `{status: 'ALLOWED', claim_expires_at}` or `{status: 'DECLINED'}`;
  - `monvelo_notify_hold(p_hold_id uuid)` (internal): one `notifications` row per ZSM in the zone and the area's ASA, kind `MONVELO_HOLD`, payload `{hold_id, financing_reference, expires_at}`, never the raiser, no agent identity; and the agent's members get `MONVELO_HOLD_DECIDED` on allow, decline or lapse.

- [ ] **Step 1: Write the failing tests in `066` section B** (about 35 assertions):
  - `zsm_and_asa_see_the_hold_anonymously`: the ZSM of the zone and the ASA of the area list it; a JSON scan of every column finds no agent id, member id, business name, phone or the agent's exposure/pledge figures; `within_limit = true`, `blocks = '{EXPOSURE_CAP}'`; the shop's record counts match the fixtures;
  - `out_of_scope_and_other_roles_refused`: a ZSM of another zone and an ASA of another area see 0 rows and get 42501 on `get`/`decide`; TM, CSM, TENANT_ADMIN, LM, ZSA and the agent member get 42501 on all three;
  - `four_eyes` (Review Focus 5): the ASA who raised the request does not see it in the list and gets 42501 on `get` and `decide`; a ZSM who raised one likewise; with the raiser the only market maker in scope, the hold lapses at the sweep;
  - `allow_needs_a_reason`: `p_reason` null or under 10 characters → 22023; a decline with null reason succeeds;
  - `allow_claims_for_the_agent`: allow → hold `ALLOWED`, financing `CLAIMED` for that agent, a claim row with a fresh 15-minute window, one tenant-null audit row; the agent can then `start_monvelo_funding`;
  - `allow_rechecks` (Review Focus 4): suspend the agent / raise its daily use past the daily cap / drain its pledge / push exposure past ₦300,000 after the hold → allow refused with the refusal text, hold still `HELD`;
  - `decline_bars_the_agent`: decline → hold `DECLINED`, financing `OFFERED`, the agent's next claim refused;
  - `decide_is_idempotent_and_final`: the same key replays; a second decision on a decided hold → P0001;
  - `the_allowance_survives_a_late_payment` (§20.3 call 7): an allowed claim lapses; the agent's payment arrives on the late route with exposure above ₦100,000 and within ₦300,000 → FUNDED, not `late_payment`; without an ALLOWED hold the same payment → `late_payment` as today;
  - `notices`: one `MONVELO_HOLD` notice per in-scope market maker except the raiser, payload holds no agent identity; one `MONVELO_HOLD_DECIDED` to the agent's members on allow, decline and lapse.
- [ ] **Step 2: Run `066` and see section B fail.** Expected: FAIL (functions do not exist).
- [ ] **Step 3: Write the migration.** The three RPCs and `monvelo_notify_hold` as in Interfaces. `decide_monvelo_claim_hold` locks the hold, takes the agent's advisory lock (R13) **before** any row lock as `claim_monvelo_financing` does, locks the financing, re-runs `monvelo_claim_refusal` with the financing's status read as `OFFERED` and `p_exposure_ceiling = monvelo_allowance_ceiling()`, and on success moves HELD → CLAIMED exactly as a claim does (claim row, `claimed_by_agent_id`, `claimed_by` = the hold's member, the 15-minute window). Recreate `settle_monvelo_funding` from its latest definition, changing only the late route: when an ALLOWED hold exists for this agent and financing, call the refusal with `monvelo_allowance_ceiling()`. Replace Task 1's `monvelo_notify_hold` stub; add the decided notice to the decide path and the sweep's lapse.
- [ ] **Step 4: Run `066`, 001, 003, 045, 058, 061–065.** Expected: PASS.
- [ ] **Step 5: Update the docs.** A6 §20 status: built locally, not pushed (migrations 120800, 120900; pgTAP 066). `supabase/CLAUDE.md`: replace the "designed, not built" bullet with the built summary and the readers. Root `CLAUDE.md`: migration and pgTAP counts after the gate.
- [ ] **Step 6: The gate.** Stop and ask the user for `npx supabase db reset`; then the controller restores the vault secret and runs `supabase test db` (Result: PASS) and `deno test --allow-all supabase/functions/` (0 failed). No gateway changes, so no integration run.
- [ ] **Step 7: Commit.** `feat(db): Monvelo market makers: anonymous hold view, four-eyes allow and decline, allowances survive late payment (A6 §20)`
