// Addendum A5 §3.1 — the active refund policy the checkout shows and the
// buyer accepts. No personal data; cached for 5 minutes.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

export function createStorefrontRefundPolicyHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway(
    { method: "GET", schema: z.object({}), cacheControl: "public, max-age=300" },
    async ({ rpc }) => {
      const policy = await rpc<unknown | null>("web_active_refund_policy", {});
      if (!policy) throw new GatewayError(404, "NOT_FOUND", "No refund policy is published.");
      return policy;
    },
    deps,
  );
}
