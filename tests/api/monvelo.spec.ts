// Monvelo (Addendum A6) API tests against the local stack, as the seeded personas.
// The mutation under test is `monvelo-agent-register` (A6 §6.3): a street agent
// (ZSA or ASA) registers a POS agent, or asks to change its settlement account.
// Since 20261123120000 the gateway calls Paystack (/bank/resolve) last: first
// the read-only preflight RPC, on the caller's JWT, runs the role gate (and the
// recruiter check for a settlement change) and looks the idempotency key up.
// Paystack is faked on port 54399 (bound on 0.0.0.0: the edge runtime reaches it
// from Docker as host.docker.internal, the functions env's PAYSTACK_API_BASE),
// and every call to it is counted, so the tests prove which requests reach it.
//
// Personas (supabase/seed.ts): the TEAFAIR ASA and ZSA (the only roles that may
// register), the TM and ZSM, the Monvelo operator, a shop owner, a Monvelo
// "fintech agent" (staff of an ACTIVE POS agent), and LAGOSFMCG's TM and ASA
// (a tenant not opted in to Monvelo).
//
// Reads go through PostgREST under RLS, as the persona allowed to see them. One
// exception: the registration audit row is written tenant-null (A6 ruling R19:
// tenants never see lenders), so NO API role can read it. The tests prove that
// through PostgREST, then read the row as postgres; that is the only way to check it.
//
// Prerequisites: `supabase start`, `pnpm db:seed`, `pnpm functions:serve:api`.
// No token, password, account number or full phone number is ever printed.
import { randomInt, randomUUID } from "node:crypto";
import http from "node:http";
import path from "node:path";
import { config as loadEnv } from "dotenv";
import { expect, type APIRequestContext, test } from "@playwright/test";
import { openDb, PASSWORD, SEED } from "../../supabase/seed";

loadEnv({ path: path.join(__dirname, "..", "..", "supabase", ".env.test.local"), quiet: true });
const API_KEY = process.env.PUBLISHABLE_KEY || process.env.ANON_KEY || "";
const FAKE_PORT = Number(process.env.INTEGRATION_FAKE_PORT ?? "54399");

type Session = { token: string; userId: string; claims: Record<string, any> };

function decodeJwt(token: string): Record<string, any> {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
}

async function signIn(request: APIRequestContext, email: string, password = PASSWORD) {
  return request.post("/auth/v1/token?grant_type=password", {
    headers: { apikey: API_KEY, "Content-Type": "application/json" },
    data: { email, password },
  });
}

async function session(request: APIRequestContext, email: string): Promise<Session> {
  // wait out a stack still restarting after `supabase db reset` (5xx or refused), never a 4xx
  let res: Awaited<ReturnType<typeof signIn>> | undefined;
  for (const deadline = Date.now() + 45_000; ;) {
    try {
      res = await signIn(request, email);
      if (res.status() < 500) break;
    } catch {
      // stack still restarting
    }
    if (Date.now() > deadline) break;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  expect(res, `sign-in for ${email}: the local stack did not answer`).toBeDefined();
  expect(res!.status(), `sign-in for ${email}`).toBe(200);
  const token = (await res!.json()).access_token as string;
  const claims = decodeJwt(token);
  return { token, userId: claims.sub, claims };
}

const authHeaders = (s?: Session) => ({
  apikey: API_KEY,
  ...(s ? { Authorization: `Bearer ${s.token}` } : {}),
});

async function rows<T = any>(request: APIRequestContext, s: Session, query: string): Promise<T[]> {
  const res = await request.get(`/rest/v1/${query}`, { headers: authHeaders(s) });
  expect(res.status(), `GET ${query.split("?")[0]}`).toBe(200);
  return res.json();
}

const REGISTER = "monvelo-agent-register";

async function register(request: APIRequestContext, s: Session | undefined, body: unknown) {
  return request.post(`/functions/v1/${REGISTER}`, {
    headers: { ...authHeaders(s), "Content-Type": "application/json" },
    data: body,
  });
}

// ── fake Paystack /bank/resolve ─────────────────────────────────────────
// Answers with the holder name registered for an account number; "0000000000"
// does not resolve (Paystack's 422). Counts every call it receives.
const holders = new Map<string, string>();
const resolveCalls = new Map<string, number>();
let paystackCalls = 0;
let fake: http.Server;

function startFakePaystack(): Promise<void> {
  fake = http.createServer((req, res) => {
    paystackCalls++;
    const url = new URL(req.url ?? "/", "http://fake");
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.method !== "GET" || url.pathname !== "/bank/resolve") return reply(404, { status: false, message: "not faked" });
    const number = url.searchParams.get("account_number") ?? "";
    resolveCalls.set(number, (resolveCalls.get(number) ?? 0) + 1);
    if (number === "0000000000") {
      return reply(422, { status: false, message: "Could not resolve account name. Check parameters or try again." });
    }
    return reply(200, {
      status: true,
      message: "Account number resolved",
      data: { account_number: number, account_name: holders.get(number) ?? "UNREGISTERED HOLDER", bank_id: 9 },
    });
  });
  return new Promise((resolve, reject) => {
    fake.once("error", (e) => reject(new Error(
      `the fake Paystack could not bind port ${FAKE_PORT} (${(e as NodeJS.ErrnoException).code}); ` +
      "if Windows reserved it, set INTEGRATION_FAKE_PORT and the functions env PAYSTACK_API_BASE to a free port")));
    // 0.0.0.0, not 127.0.0.1: the edge runtime calls it from Docker as host.docker.internal
    fake.listen(FAKE_PORT, "0.0.0.0", () => resolve());
  });
}

/** Runs fn and returns how many requests the fake Paystack received meanwhile. */
async function paystackCallsDuring(fn: () => Promise<void>): Promise<number> {
  const before = paystackCalls;
  await fn();
  return paystackCalls - before;
}

// ── personas and the registrations under test ───────────────────────────
test.describe.configure({ mode: "serial" });

let asa: Session;          // ASA of Ojodu Central, TEAFAIR
let zsa: Session;          // ZSA of the zone, TEAFAIR
let rep1: Session;         // TM of Ojodu-Berger
let manager: Session;      // ZSM of the zone
let ops: Session;          // MONVELO_OPERATOR, no tenant
let shopOwner: Session;    // owner of the first Ojodu outlet, no tenant
let fintechAgent: Session; // staff of the seeded ACTIVE POS agent, no tenant
let lagosTm: Session;      // TM, LAGOSFMCG (not opted in)
let lagosAsa: Session;     // ASA, LAGOSFMCG (not opted in)

// unique per run: the network agent id is unique across all of Monvelo
const runTag = `${Date.now().toString(36)}${randomInt(1000, 9999)}`.toUpperCase();
const account = () => `9${String(randomInt(0, 1_000_000_000)).padStart(9, "0")}`;
const accountNumber = account();
const agentInput = {
  action: "register",
  business_name: `Ojodu Liquidity Hub ${runTag}`,
  pos_network: "MONIEPOINT",
  network_agent_id: `mp-${runTag}`,
  contact_phone: "08031234567",
  latitude: SEED.ojoduGps.lat,
  longitude: SEED.ojoduGps.lng,
  address_text: "7 Ojodu-Berger Road, Ojodu, Lagos",
  network_kyc_reference: `KYC-${runTag}`,
  settlement_account_number: accountNumber,
  settlement_bank_code: "058",
} as const;
const key = randomUUID();
let agentId: string;

const AGENT_COLS = "id,business_name,pos_network,network_agent_id,status,recruited_by,settlement_account_last4,settlement_account_name";

test.beforeAll(async ({ request }) => {
  expect(API_KEY, "supabase/.env.test.local must hold the local publishable/anon key").not.toBe("");
  await startFakePaystack();
  holders.set(accountNumber, agentInput.business_name.toUpperCase()); // the bank's name matches the business
  // one at a time: concurrent password sign-ins against local Auth were refused (422)
  asa = await session(request, SEED.users.asa.email);
  zsa = await session(request, SEED.users.zsa.email);
  rep1 = await session(request, SEED.users.rep1.email);
  manager = await session(request, SEED.users.manager.email);
  ops = await session(request, SEED.users.monveloOps.email);
  shopOwner = await session(request, SEED.users.shopOwner.email);
  fintechAgent = await session(request, SEED.users.fintechAgent.email);
  lagosTm = await session(request, SEED.users.lagosTm.email);
  lagosAsa = await session(request, SEED.users.lagosAsa.email);
});

test.afterAll(async () => {
  await new Promise<void>((r) => (fake ? fake.close(() => r()) : r()));
});

// ── a) the persona complement: claims and what each one reads ───────────
test.describe("Monvelo personas: claims and live membership", () => {
  test("the ASA signs in with TEAFAIR / ASA claims, anchored to the Ojodu Central area", async ({ request }) => {
    const app = asa.claims.app_metadata;
    expect(app.active_tenant_id).toBe(SEED.teafairTenantId);
    expect(app.tenant_role).toBe("ASA");
    expect(app.tenant_ids).toEqual([SEED.teafairTenantId]);
    const me = await rows(request, asa,
      `tenant_users?profile_id=eq.${asa.userId}&select=role,territory_id,area_id,status`);
    expect(me).toEqual([{ role: "ASA", territory_id: SEED.ojoduTerritoryId, area_id: SEED.ojoduAreaId, status: "ACTIVE" }]);
  });

  test("the ZSA signs in with TEAFAIR / ZSA claims, anchored to the zone and reporting to the ZSM", async ({ request }) => {
    const app = zsa.claims.app_metadata;
    expect(app.active_tenant_id).toBe(SEED.teafairTenantId);
    expect(app.tenant_role).toBe("ZSA");
    expect(app.tenant_ids).toEqual([SEED.teafairTenantId]);
    const [me] = await rows(request, zsa,
      `tenant_users?profile_id=eq.${zsa.userId}&select=role,zone_id,territory_id,area_id,reports_to_id,status`);
    expect(me).toMatchObject({ role: "ZSA", zone_id: SEED.zoneId, territory_id: null, area_id: null, status: "ACTIVE" });
    const [boss] = await rows(request, zsa, `tenant_users?id=eq.${me.reports_to_id}&select=profile_id,role`);
    expect(boss).toEqual({ profile_id: manager.userId, role: "ZSM" });
  });

  test("the ZSM and TM are TEAFAIR members whose roles Monvelo registration does not accept", () => {
    expect(manager.claims.app_metadata).toMatchObject({ active_tenant_id: SEED.teafairTenantId, tenant_role: "ZSM" });
    expect(rep1.claims.app_metadata).toMatchObject({ active_tenant_id: SEED.teafairTenantId, tenant_role: "TM" });
  });

  test("the operator is platform staff with no tenant", () => {
    const app = ops.claims.app_metadata;
    expect(app.platform_role).toBe("MONVELO_OPERATOR");
    expect(app.tenant_ids ?? []).toEqual([]);
  });

  test("the shop owner has no tenant or platform role and reads their own outlet", async ({ request }) => {
    const app = shopOwner.claims.app_metadata;
    expect(app.tenant_ids ?? []).toEqual([]);
    expect(app.platform_role ?? null).toBeNull();
    expect(await rows(request, shopOwner, `retail_shops?owner_id=eq.${shopOwner.userId}&select=id,owner_id`))
      .toEqual([{ id: SEED.ownedShopId, owner_id: shopOwner.userId }]);
    expect(await rows(request, shopOwner, `monvelo_agents?select=id`)).toHaveLength(0);
  });

  test("the fintech agent is staff of the ACTIVE POS agent and reads it and its own exposure", async ({ request }) => {
    const app = fintechAgent.claims.app_metadata;
    expect(app.tenant_ids ?? []).toEqual([]);
    expect(app.platform_role ?? null).toBeNull();
    expect(await rows(request, fintechAgent, `monvelo_agent_members?select=agent_id,profile_id,status`))
      .toEqual([{ agent_id: SEED.monveloAgentId, profile_id: fintechAgent.userId, status: "ACTIVE" }]);
    expect(await rows(request, fintechAgent, `monvelo_agents?select=id,status,network_agent_id,recruited_by`))
      .toEqual([{ id: SEED.monveloAgentId, status: "ACTIVE", network_agent_id: SEED.monveloAgentNetworkId, recruited_by: asa.userId }]);

    const res = await request.post("/rest/v1/rpc/get_monvelo_agent_exposure", {
      headers: { ...authHeaders(fintechAgent), "Content-Type": "application/json" }, data: {},
    });
    expect(res.status()).toBe(200);
    const body = await res.json();
    const meter = Array.isArray(body) ? body[0] : body;
    expect(meter).toMatchObject({ agent_id: SEED.monveloAgentId, agent_status: "ACTIVE" });
  });

  test("the exposure meter refuses every tenant role (A6 §21.3): the ZSM gets 403", async ({ request }) => {
    const res = await request.post("/rest/v1/rpc/get_monvelo_agent_exposure", {
      headers: { ...authHeaders(manager), "Content-Type": "application/json" },
      data: { p_agent_id: SEED.monveloAgentId },
    });
    expect(res.status()).toBe(403);
  });

  test("LAGOSFMCG's TM and ASA sign in to LAGOSFMCG only", async ({ request }) => {
    expect(lagosTm.claims.app_metadata).toMatchObject({ active_tenant_id: SEED.otherTenantId, tenant_role: "TM" });
    expect(lagosAsa.claims.app_metadata).toMatchObject({ active_tenant_id: SEED.otherTenantId, tenant_role: "ASA" });
    expect(lagosAsa.claims.app_metadata.tenant_ids).toEqual([SEED.otherTenantId]);
    const [me] = await rows(request, lagosAsa, `tenant_users?profile_id=eq.${lagosAsa.userId}&select=role,area_id,status`);
    expect(me).toEqual({ role: "ASA", area_id: SEED.otherAreaId, status: "ACTIVE" });
  });

  test("tenant isolation both ways: settings, areas and territories never cross", async ({ request }) => {
    expect(await rows(request, asa, `monvelo_tenant_settings?select=tenant_id,enabled`))
      .toEqual([{ tenant_id: SEED.teafairTenantId, enabled: true }]);
    for (const s of [asa, zsa, rep1, manager]) {
      expect(await rows(request, s, `monvelo_tenant_settings?tenant_id=eq.${SEED.otherTenantId}&select=tenant_id`)).toHaveLength(0);
      expect(await rows(request, s, `areas?tenant_id=eq.${SEED.otherTenantId}&select=id`)).toHaveLength(0);
    }
    for (const s of [lagosTm, lagosAsa]) {
      expect(await rows(request, s, `monvelo_tenant_settings?select=tenant_id`)).toHaveLength(0); // not opted in
      expect(await rows(request, s, `areas?tenant_id=eq.${SEED.teafairTenantId}&select=id`)).toHaveLength(0);
      expect(await rows(request, s, `territories?tenant_id=eq.${SEED.teafairTenantId}&select=id`)).toHaveLength(0);
    }
  });

  test("ACTIVE agents are visible to field agents of opted-in tenants only", async ({ request }) => {
    const q = `monvelo_agents?id=eq.${SEED.monveloAgentId}&select=id`;
    for (const s of [asa, zsa, ops]) expect(await rows(request, s, q)).toHaveLength(1);
    for (const s of [rep1, manager, shopOwner, lagosTm, lagosAsa]) expect(await rows(request, s, q)).toHaveLength(0);
  });
});

// ── b) refused callers never reach Paystack ─────────────────────────────
test.describe("monvelo-agent-register: refused callers cost no Paystack call", () => {
  // "0000000000" is the account the fake refuses with 422: a caller who reached
  // Paystack would see 422 ("no such account") instead of 401/403.
  const probe = () => ({ ...agentInput, idempotency_key: randomUUID(), settlement_account_number: "0000000000" });

  test("without a JWT: 401", async ({ request }) => {
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, undefined, probe());
      expect(res.status()).toBe(401);
    });
    expect(n).toBe(0);
  });

  test("with a garbage bearer token: 401", async ({ request }) => {
    const n = await paystackCallsDuring(async () => {
      const res = await request.post(`/functions/v1/${REGISTER}`, {
        headers: { apikey: API_KEY, Authorization: "Bearer not.a.jwt", "Content-Type": "application/json" },
        data: probe(),
      });
      expect(res.status()).toBe(401);
    });
    expect(n).toBe(0);
  });

  for (const [who, pick, why] of [
    ["the territory's TM", () => rep1, "a TM is not a street agent"],
    ["the zone's ZSM", () => manager, "a ZSM oversees, it does not recruit"],
    ["the Monvelo operator", () => ops, "platform staff hold no tenant role"],
    ["the shop owner", () => shopOwner, "no tenant membership"],
    ["the fintech agent", () => fintechAgent, "a POS agent's staff do not recruit"],
    ["LAGOSFMCG's TM", () => lagosTm, "wrong role, and a tenant not opted in"],
    ["LAGOSFMCG's ASA", () => lagosAsa, "the right role in a tenant not opted in"],
  ] as const) {
    test(`${who}: 403 FORBIDDEN, never 422, nothing written (${why})`, async ({ request }) => {
      const body = probe();
      const n = await paystackCallsDuring(async () => {
        const res = await register(request, pick(), body);
        expect(res.status()).toBe(403);
        expect((await res.json()).error.code).toBe("FORBIDDEN");
      });
      expect(n).toBe(0);
      expect(await rows(request, pick(), `idempotency_logs?key=eq.${body.idempotency_key}&select=key`)).toHaveLength(0);
    });
  }

  test("a client-sent tenant is stripped, never trusted (Spec A §9)", async ({ request }) => {
    // the LAGOSFMCG ASA names TEAFAIR (opted in); the gateway drops it and the JWT tenant decides
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, lagosAsa,
        { ...probe(), tenant_id: SEED.teafairTenantId, p_tenant_id: SEED.teafairTenantId });
      expect(res.status()).toBe(403);
    });
    expect(n).toBe(0);
  });
});

// ── c) RLS: the Monvelo tables cannot be written around the gateway ────
test.describe("Monvelo write protection (no direct client writes)", () => {
  const minimal = (s: Session) => ({ ...authHeaders(s), "Content-Type": "application/json", Prefer: "return=minimal" });

  test("the ASA cannot insert an agent, a member or an area through PostgREST", async ({ request }) => {
    const agent = await request.post("/rest/v1/monvelo_agents", {
      headers: minimal(asa),
      data: {
        business_name: "Bypass Ventures", pos_network: "OPAY", network_agent_id: `OP-${runTag}`,
        contact_phone: "+2348031230000", address_text: "x", network_kyc_reference: "K",
        settlement_account_number: "1234567890", settlement_account_last4: "7890",
        settlement_bank_code: "058", settlement_account_name: "BYPASS", status: "ACTIVE", recruited_by: asa.userId,
      },
    });
    expect(agent.status()).toBe(403);

    const member = await request.post("/rest/v1/monvelo_agent_members", {
      headers: minimal(asa), data: { agent_id: SEED.monveloAgentId, profile_id: asa.userId, status: "ACTIVE" },
    });
    expect(member.status()).toBe(403);

    const area = await request.post("/rest/v1/areas", {
      headers: minimal(asa),
      data: { tenant_id: SEED.teafairTenantId, territory_id: SEED.ojoduTerritoryId, area_name: "Bypass Area" },
    });
    expect(area.status()).toBe(403);
  });

  test("the fintech agent cannot raise its own caps or approve itself", async ({ request }) => {
    const res = await request.patch(`/rest/v1/monvelo_agents?id=eq.${SEED.monveloAgentId}`, {
      headers: minimal(fintechAgent), data: { daily_cap: 99999999, per_financing_cap: 99999999 },
    });
    expect(res.status()).toBe(403);
  });

  test("the TM and ZSM cannot switch Monvelo off or change the limits directly", async ({ request }) => {
    for (const s of [rep1, manager]) {
      const res = await request.patch(`/rest/v1/monvelo_tenant_settings?tenant_id=eq.${SEED.teafairTenantId}`, {
        headers: minimal(s), data: { enabled: false, opening_limit: 999999 },
      });
      expect(res.status()).toBe(403);
    }
    const [st] = await rows(request, asa, `monvelo_tenant_settings?select=enabled`);
    expect(st.enabled).toBe(true);
  });

  test("LAGOSFMCG's TM cannot opt its tenant in by writing the settings row", async ({ request }) => {
    const res = await request.post("/rest/v1/monvelo_tenant_settings", {
      headers: minimal(lagosTm), data: { tenant_id: SEED.otherTenantId, enabled: true },
    });
    expect(res.status()).toBe(403);
    expect(await rows(request, lagosTm, `monvelo_tenant_settings?select=tenant_id`)).toHaveLength(0);
  });

  test("calling register_monvelo_agent straight through PostgREST fails the gateway proof", async ({ request }) => {
    const res = await request.post("/rest/v1/rpc/register_monvelo_agent", {
      headers: { ...authHeaders(asa), "Content-Type": "application/json" },
      data: {
        p_idempotency_key: randomUUID(), p_gateway_proof: "guessed",
        p_agent: {
          ...agentInput, network_agent_id: `BYPASS-${runTag}`, contact_phone: "+2348031234567",
          settlement_account_name: "ANY NAME I LIKE", // the gateway, not the client, supplies the bank's name
        },
      },
    });
    expect(res.status()).toBe(403);
    expect(await rows(request, ops, `monvelo_agents?network_agent_id=eq.BYPASS-${runTag}&select=id`)).toHaveLength(0);
  });
});

// ── d) request validation: all 400s, none reaches Paystack ──────────────
test.describe("monvelo-agent-register: request validation", () => {
  const rejected = async (request: APIRequestContext, body: unknown, headers: Record<string, string> = {}) => {
    const n = await paystackCallsDuring(async () => {
      const res = await request.post(`/functions/v1/${REGISTER}`, {
        headers: { ...authHeaders(asa), "Content-Type": "application/json", ...headers }, data: body,
      });
      expect(res.status()).toBe(400);
      expect((await res.json()).error.code).toBe("VALIDATION_FAILED");
    });
    expect(n).toBe(0);
  };

  test("the key travels in the body: a header alone is 400", async ({ request }) => {
    await rejected(request, agentInput, { "x-idempotency-key": randomUUID() });
  });

  test("a valid UUID v1 key is 400: only v4 is accepted", async ({ request }) => {
    await rejected(request, { ...agentInput, idempotency_key: "6ba7b810-9dad-11d1-80b4-00c04fd430c8" });
  });

  test("a valid UUID v7 key is 400", async ({ request }) => {
    await rejected(request, { ...agentInput, idempotency_key: "01890a5d-ac96-774b-bcce-b302099a8057" });
  });

  test("a version-4 key with a non-RFC 4122 variant, the nil UUID and junk are 400", async ({ request }) => {
    const v4 = randomUUID();
    for (const bad of [`${v4.slice(0, 19)}c${v4.slice(20)}`, "00000000-0000-0000-0000-000000000000", "not-a-uuid"]) {
      await rejected(request, { ...agentInput, idempotency_key: bad });
    }
  });

  test("an unknown POS network and a short account number are 400", async ({ request }) => {
    await rejected(request, { ...agentInput, idempotency_key: randomUUID(), pos_network: "MPESA" });
    await rejected(request, { ...agentInput, idempotency_key: randomUUID(), settlement_account_number: "12345" });
  });

  test("an allowed caller with an account Paystack cannot resolve gets 422 and nothing is written", async ({ request }) => {
    const k = randomUUID();
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, { ...agentInput, idempotency_key: k, settlement_account_number: "0000000000" });
      expect(res.status()).toBe(422);
      expect((await res.json()).error.code).toBe("ACCOUNT_NOT_RESOLVED");
    });
    expect(n).toBe(1); // only an authorised street agent learns this
    expect(await rows(request, asa, `idempotency_logs?key=eq.${k}&select=key`)).toHaveLength(0);
  });
});

// ── e) the happy path, side effects and idempotency ─────────────────────
test.describe("monvelo-agent-register: registration by the ASA, audit and idempotency", () => {
  // The tests after the registration read its agent and key. Run on their own
  // (one test picked in the UI, or a -g filter) they register first with the
  // same key, so each one stands alone; in a full run the first test has.
  const ensureRegistered = async (request: APIRequestContext) => {
    if (agentId) return;
    const res = await register(request, asa, { ...agentInput, idempotency_key: key });
    expect(res.status(), "setup: the ASA registers the POS agent").toBe(200);
    agentId = (await res.json()).agent_id;
  };

  test("the ASA registers the POS agent: 200, PENDING, one Paystack call, no account number back", async ({ request }) => {
    let body: any;
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, { ...agentInput, idempotency_key: key });
      expect(res.status()).toBe(200);
      body = await res.json();
    });
    expect(n).toBe(1);
    expect(body).toMatchObject({ status: "PENDING", name_matches: true, settlement_account_last4: accountNumber.slice(-4) });
    expect(body.agent_id).toMatch(/^[0-9a-f-]{36}$/);
    const text = JSON.stringify(body);
    expect(text).not.toContain(accountNumber);
    expect(text).not.toContain("8031234567");
    agentId = body.agent_id;
  });

  test("the operator reads the new agent as recorded: the resolved name, the ASA as recruiter", async ({ request }) => {
    await ensureRegistered(request);
    const [a] = await rows(request, ops, `monvelo_agents?id=eq.${agentId}&select=${AGENT_COLS}`);
    expect(a).toEqual({
      id: agentId,
      business_name: agentInput.business_name,
      pos_network: "MONIEPOINT",
      network_agent_id: agentInput.network_agent_id.toUpperCase(), // the RPC upper-cases it
      status: "PENDING",
      recruited_by: asa.userId,
      settlement_account_last4: accountNumber.slice(-4),
      settlement_account_name: agentInput.business_name.toUpperCase(), // Paystack's name, not a client one
    });
  });

  test("the full settlement account number is readable by no API role, not even Monvelo staff", async ({ request }) => {
    await ensureRegistered(request);
    const res = await request.get(`/rest/v1/monvelo_agents?id=eq.${agentId}&select=settlement_account_number`,
      { headers: authHeaders(ops) });
    expect(res.status()).not.toBe(200);
    expect(await res.text()).not.toContain(accountNumber);
  });

  test("a PENDING agent is invisible to the tenant and to field agents", async ({ request }) => {
    await ensureRegistered(request);
    for (const s of [asa, zsa, rep1, manager, fintechAgent, lagosAsa]) {
      expect(await rows(request, s, `monvelo_agents?id=eq.${agentId}&select=id`)).toHaveLength(0);
    }
  });

  test("the caller's idempotency log is COMPLETED with the agent id; nobody else reads it", async ({ request }) => {
    await ensureRegistered(request);
    const log = await rows(request, asa,
      `idempotency_logs?key=eq.${key}&select=key,operation,status,actor_id,tenant_id,response`);
    expect(log).toHaveLength(1);
    expect(log[0]).toMatchObject({
      key, operation: "register_monvelo_agent", status: "COMPLETED",
      actor_id: asa.userId, tenant_id: SEED.teafairTenantId,
    });
    expect(log[0].response).toMatchObject({ agent_id: agentId, status: "PENDING", name_matches: true });
    for (const s of [zsa, rep1, manager, ops]) {
      expect(await rows(request, s, `idempotency_logs?key=eq.${key}&select=key`)).toHaveLength(0);
    }
  });

  test("the audit row is tenant-null (R19): no API role reads it", async ({ request }) => {
    await ensureRegistered(request);
    const q = `audit_logs?entity_type=eq.monvelo_agents&entity_id=eq.${agentId}&select=id`;
    for (const s of [asa, rep1, manager, ops]) expect(await rows(request, s, q)).toHaveLength(0);
  });

  test("the audit row records the key, the ASA and a redacted agent (read as postgres)", async ({ request }) => {
    await ensureRegistered(request);
    const sql = openDb();
    try {
      const audit = await sql<any[]>`
        select tenant_id, actor_id, operation, idempotency_key, source, before, after
          from public.audit_logs
         where entity_type = 'monvelo_agents' and entity_id = ${agentId}`;
      expect(audit).toHaveLength(1);
      const a = audit[0];
      expect(a).toMatchObject({
        tenant_id: null, actor_id: asa.userId, operation: "register_monvelo_agent",
        idempotency_key: key, source: "USER", before: null,
      });
      expect(a.after).toMatchObject({ id: agentId, status: "PENDING", recruited_by: asa.userId,
        settlement_account_last4: accountNumber.slice(-4) });
      // the redaction (monvelo_agent_audit): no account number, bank code, phone or location
      for (const k of ["settlement_account_number", "settlement_bank_code", "contact_phone", "location"]) {
        expect(a.after, k).not.toHaveProperty(k);
      }
      expect(JSON.stringify(a.after)).not.toContain(accountNumber);
    } finally {
      await sql.end();
    }
  });

  test("an identical retry replays the cached 200 with 0 Paystack calls, even if the bank's name changed", async ({ request }) => {
    await ensureRegistered(request);
    holders.set(accountNumber, "SOMEBODY ELSE ENTIRELY"); // would have broken the old replay (TF002)
    try {
      const n = await paystackCallsDuring(async () => {
        const res = await register(request, asa, { ...agentInput, idempotency_key: key });
        expect(res.status()).toBe(200);
        expect(await res.json()).toEqual({
          agent_id: agentId, status: "PENDING", name_matches: true, settlement_account_last4: accountNumber.slice(-4),
        });
      });
      expect(n).toBe(0);
    } finally {
      holders.set(accountNumber, agentInput.business_name.toUpperCase());
    }

    expect(await rows(request, ops,
      `monvelo_agents?network_agent_id=eq.${agentInput.network_agent_id.toUpperCase()}&select=id`)).toEqual([{ id: agentId }]);
    expect(await rows(request, asa, `idempotency_logs?key=eq.${key}&select=key`)).toHaveLength(1);
    const sql = openDb();
    try {
      const [{ n }] = await sql<{ n: number }[]>`
        select count(*)::int as n from public.audit_logs where entity_type = 'monvelo_agents' and entity_id = ${agentId}`;
      expect(n).toBe(1);
    } finally {
      await sql.end();
    }
  });

  test("the same key with a changed payload is 409 IDEMPOTENCY_MISMATCH with 0 Paystack calls", async ({ request }) => {
    await ensureRegistered(request);
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa,
        { ...agentInput, idempotency_key: key, business_name: `${agentInput.business_name} Changed` });
      expect(res.status()).toBe(409);
      expect((await res.json()).error.code).toBe("IDEMPOTENCY_MISMATCH");
    });
    expect(n).toBe(0);
    const [a] = await rows(request, ops, `monvelo_agents?id=eq.${agentId}&select=business_name`);
    expect(a.business_name).toBe(agentInput.business_name);
  });

  test("the ZSA replaying the ASA's key is 409 IDEMPOTENCY_MISMATCH, never the ASA's answer", async ({ request }) => {
    await ensureRegistered(request);
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, zsa, { ...agentInput, idempotency_key: key });
      expect(res.status()).toBe(409);
      const text = await res.text();
      expect(JSON.parse(text).error.code).toBe("IDEMPOTENCY_MISMATCH");
      expect(text).not.toContain(agentId);
    });
    expect(n).toBe(0);
  });

  test("a refused persona replaying the ASA's key gets 403, never the ASA's answer", async ({ request }) => {
    await ensureRegistered(request);
    const res = await register(request, rep1, { ...agentInput, idempotency_key: key });
    expect(res.status()).toBe(403);
    expect(JSON.stringify(await res.json())).not.toContain(agentId);
  });

  test("a fresh key cannot register the same network agent twice: 409 CONFLICT, still one agent", async ({ request }) => {
    await ensureRegistered(request);
    const k = randomUUID();
    const res = await register(request, asa, { ...agentInput, idempotency_key: k });
    expect(res.status()).toBe(409);
    expect((await res.json()).error.code).toBe("CONFLICT");
    expect(await rows(request, ops,
      `monvelo_agents?network_agent_id=eq.${agentInput.network_agent_id.toUpperCase()}&select=id`)).toHaveLength(1);
    // the refused attempt rolled back with its IN_PROGRESS log, so the key stays usable
    expect(await rows(request, asa, `idempotency_logs?key=eq.${k}&select=key`)).toHaveLength(0);
  });
});

// ── f) the ZSA registers too, and concurrent requests stay consistent ───
test.describe("monvelo-agent-register: registration by the ZSA and races", () => {
  const zsaInput = (tag: string, acct: string) => ({
    ...agentInput,
    business_name: `Omole POS Point ${tag}`,
    pos_network: "OPAY",
    network_agent_id: `op-${tag}`,
    network_kyc_reference: `KYC-OP-${tag}`,
    settlement_account_number: acct,
  });

  test("the ZSA registers a POS agent end to end: 200, PENDING, the ZSA as recruiter", async ({ request }) => {
    const acct = account();
    const input = zsaInput(`${runTag}Z`, acct);
    holders.set(acct, input.business_name.toUpperCase());
    const res = await register(request, zsa, { ...input, idempotency_key: randomUUID() });
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ status: "PENDING", name_matches: true, settlement_account_last4: acct.slice(-4) });
    const [a] = await rows(request, ops, `monvelo_agents?id=eq.${body.agent_id}&select=recruited_by,pos_network,network_agent_id,status`);
    expect(a).toEqual({ recruited_by: zsa.userId, pos_network: "OPAY", network_agent_id: input.network_agent_id.toUpperCase(), status: "PENDING" });
  });

  test("two concurrent sends of the same key create one agent and answer with it", async ({ request }) => {
    const acct = account();
    const input = { ...zsaInput(`${runTag}R`, acct), idempotency_key: randomUUID() };
    holders.set(acct, input.business_name.toUpperCase());
    const replies = await Promise.all([register(request, zsa, input), register(request, zsa, input)]);
    const statuses = replies.map((r) => r.status());
    // the second waits on the first's key; a 503 RETRY is the only other acceptable answer
    for (const s of statuses) expect([200, 503]).toContain(s);
    const ok = await Promise.all(replies.filter((r) => r.status() === 200).map((r) => r.json()));
    expect(ok.length).toBeGreaterThan(0);
    expect(new Set(ok.map((b) => b.agent_id)).size).toBe(1);
    expect(await rows(request, ops,
      `monvelo_agents?network_agent_id=eq.${input.network_agent_id.toUpperCase()}&select=id`)).toEqual([{ id: ok[0].agent_id }]);
  });

  test("two concurrent registrations of one network agent under different keys: one 200, one 409 CONFLICT", async ({ request }) => {
    const acct = account();
    const input = zsaInput(`${runTag}C`, acct);
    holders.set(acct, input.business_name.toUpperCase());
    const replies = await Promise.all([
      register(request, zsa, { ...input, idempotency_key: randomUUID() }),
      register(request, asa, { ...input, idempotency_key: randomUUID() }),
    ]);
    expect(replies.map((r) => r.status()).sort()).toEqual([200, 409]);
    const loser = replies.find((r) => r.status() === 409)!;
    expect((await loser.json()).error.code).toBe("CONFLICT");
    expect(await rows(request, ops,
      `monvelo_agents?network_agent_id=eq.${input.network_agent_id.toUpperCase()}&select=id`)).toHaveLength(1);
  });
});

// ── g) a settlement change: the recruiter only, replayed without Paystack ─
test.describe("monvelo-agent-register: change_settlement", () => {
  const changeAcct = account();
  const changeKey = randomUUID();
  const change = (over: Record<string, unknown> = {}) => ({
    idempotency_key: changeKey, action: "change_settlement", agent_id: SEED.monveloAgentId,
    settlement_account_number: changeAcct, settlement_bank_code: "044", ...over,
  });
  let changeRequested = false;

  // The replay tests need the ASA's change under changeKey; run on their own
  // they request it first, as the full run's third test does.
  const ensureChangeRequested = async (request: APIRequestContext) => {
    if (changeRequested) return;
    holders.set(changeAcct, "OJODU LIQUIDITY POINT");
    const res = await register(request, asa, change());
    expect(res.status(), "setup: the recruiting ASA requests the change").toBe(200);
    changeRequested = true;
  };

  test("the ZSA, who did not recruit the agent, is refused with 0 Paystack calls", async ({ request }) => {
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, zsa, change({ idempotency_key: randomUUID() }));
      expect(res.status()).toBe(403);
    });
    expect(n).toBe(0);
  });

  test("an unknown agent is refused with 0 Paystack calls", async ({ request }) => {
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, change({ idempotency_key: randomUUID(), agent_id: randomUUID() }));
      expect(res.status()).toBe(422);
      expect((await res.json()).error.code).toBe("BUSINESS_RULE");
    });
    expect(n).toBe(0);
  });

  test("the recruiting ASA requests the change: 200 PENDING_APPROVAL, last four only, one Paystack call", async ({ request }) => {
    holders.set(changeAcct, "OJODU LIQUIDITY POINT");
    let text = "";
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, change());
      expect(res.status()).toBe(200);
      text = await res.text();
    });
    expect(n).toBe(1);
    changeRequested = true;
    expect(JSON.parse(text)).toEqual({
      agent_id: SEED.monveloAgentId, status: "PENDING_APPROVAL", settlement_account_last4: changeAcct.slice(-4),
    });
    expect(text).not.toContain(changeAcct);
  });

  test("an identical retry replays the cached 200 with 0 Paystack calls", async ({ request }) => {
    await ensureChangeRequested(request);
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, change());
      expect(res.status()).toBe(200);
      expect(await res.json()).toEqual({
        agent_id: SEED.monveloAgentId, status: "PENDING_APPROVAL", settlement_account_last4: changeAcct.slice(-4),
      });
    });
    expect(n).toBe(0);
  });

  test("the same key for a different account is 409 IDEMPOTENCY_MISMATCH with 0 Paystack calls", async ({ request }) => {
    await ensureChangeRequested(request);
    const n = await paystackCallsDuring(async () => {
      const res = await register(request, asa, change({ settlement_account_number: account() }));
      expect(res.status()).toBe(409);
      expect((await res.json()).error.code).toBe("IDEMPOTENCY_MISMATCH");
    });
    expect(n).toBe(0);
  });
});
