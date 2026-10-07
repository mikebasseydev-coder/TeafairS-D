// The user-flavoured gateway pipeline (Spec A §3.1):
// POST only → verify JWT → validate body → handler (PIN, IO, one RPC) → §3.5 errors.
import type { z } from "./deps.ts";
import { authenticate, type Caller, supabaseTokenVerifier, type TokenVerifier } from "./jwt.ts";
import { type Rpc, userRpc } from "./db.ts";
import { errorResponse, GatewayError } from "./errors.ts";
import { json } from "./http.ts";
import { parseJsonBody } from "./validate.ts";

export type UserGatewayDeps = {
  verifyToken: TokenVerifier;
  rpcFor: (authorization: string) => Rpc;
};

export type UserContext<B> = { caller: Caller; body: B; rpc: Rpc };

export function userGateway<S extends z.ZodTypeAny>(
  schema: S,
  handle: (ctx: UserContext<z.infer<S>>) => Promise<unknown>,
  deps: UserGatewayDeps,
): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      const caller = await authenticate(req, deps.verifyToken);
      const body = await parseJsonBody(req, schema);
      return json(200, await handle({ caller, body, rpc: deps.rpcFor(caller.authorization) }));
    } catch (e) {
      return errorResponse(e);
    }
  };
}

export function liveUserGatewayDeps(): UserGatewayDeps {
  return { verifyToken: supabaseTokenVerifier(), rpcFor: userRpc };
}
