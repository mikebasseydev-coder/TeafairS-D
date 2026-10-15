// Addendum A1 §5.2 — the storefront's catalogue for one agent code. Cached at
// the Vercel CDN for 5 minutes (browsers 1 minute), so the function sees about
// one call per code per five minutes. No agent PII is in the RPC's reply.
import { z } from "../_shared/core/deps.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({ code: z.string().trim().min(4).max(32) });

export function createStorefrontCatalogueHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway(
    { method: "GET", schema, cacheControl: "public, max-age=60, s-maxage=300" },
    ({ body, rpc }) => rpc("storefront_catalogue", { p_code: body.code }),
    deps,
  );
}
