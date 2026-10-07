import { assertEquals } from "jsr:@std/assert@1";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { userGateway, type UserGatewayDeps } from "./gateway.ts";
import type { Rpc } from "./db.ts";

const claims = { sub: "u1", role: "authenticated", app_metadata: {} };
function deps(rpc: Rpc, seen: string[] = []): UserGatewayDeps {
  return {
    verifyToken: () => Promise.resolve(claims),
    rpcFor: (authorization) => {
      seen.push(authorization);
      return rpc;
    },
  };
}
const okRpc: Rpc = <T>() => Promise.resolve({ done: true } as T);
const call = (handler: (r: Request) => Promise<Response>, method = "POST", body = '{"n":1}') =>
  handler(new Request("http://x", { method, body: method === "GET" ? undefined : body, headers: { Authorization: "Bearer tok" } }));

Deno.test("only POST is accepted", async () => {
  const res = await call(userGateway(z.object({}), () => Promise.resolve({}), deps(okRpc)), "GET");
  assertEquals(res.status, 405);
});

Deno.test("the handler gets the caller's own JWT for its RPC client (§3.2)", async () => {
  const seen: string[] = [];
  const handler = userGateway(z.object({ n: z.number() }), async ({ body, rpc }) => ({ n: body.n, r: await rpc("x", {}) }), deps(okRpc, seen));
  const res = await call(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { n: 1, r: { done: true } });
  assertEquals(seen, ["Bearer tok"]);
});

Deno.test("a mapped database error keeps its status", async () => {
  const failing: Rpc = () => Promise.reject(new GatewayError(409, "IDEMPOTENCY_MISMATCH", "reused"));
  const handler = userGateway(z.object({ n: z.number() }), ({ rpc }) => rpc("x", {}), deps(failing));
  const res = await call(handler);
  assertEquals(res.status, 409);
});

Deno.test("validation runs before any RPC client is created", async () => {
  const seen: string[] = [];
  const handler = userGateway(z.object({ n: z.string() }), () => Promise.resolve({}), deps(okRpc, seen));
  const res = await call(handler);
  assertEquals(res.status, 400);
  assertEquals(seen, []);
});
