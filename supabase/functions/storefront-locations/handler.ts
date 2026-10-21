// Spec D1 §8.3 — the states and LGAs the storefront can deliver to, for one
// agent code or (no code) the codeless catalogue. Public, cached for an hour:
// GET with `code` in the query string, because CDNs never cache POST replies.
import { z } from "../_shared/core/deps.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({ code: z.string().trim().min(4).max(32).optional() });

export function createStorefrontLocationsHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway(
    { method: "GET", schema, cacheControl: "public, max-age=3600" },
    ({ body, rpc }) => rpc("storefront_locations", { p_code: body.code ?? null }),
    deps,
  );
}
