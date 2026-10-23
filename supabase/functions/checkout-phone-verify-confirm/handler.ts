// Addendum A5 §3.3 — confirm the WhatsApp code. On success the buyer gets a
// one-time bearer token; only its SHA-256 hex reaches the database, and
// place_web_order later hashes the presented token to match it.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { randomToken, sha256Hex } from "../_shared/support/secret.ts";

const schema = z.object({
  verification_id: z.string().uuid(),
  code: z.string().regex(/^\d{6}$/),
});

type Confirmed = { verified: boolean; error?: string; attempts_left?: number };

export function createCheckoutPhoneVerifyConfirmHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    const token = randomToken();
    const res = await rpc<Confirmed>("confirm_web_phone_verification", {
      p_verification_id: body.verification_id,
      p_code: body.code,
      p_token_hash: await sha256Hex(token),
    });
    // a wrong code returns (not raises) so the failed-attempt counter persists
    if (!res.verified) {
      throw new GatewayError(422, "BUSINESS_RULE", res.error ?? "That code is not right.", {
        attempts_left: res.attempts_left ?? null,
      });
    }
    return { verification_token: token };
  }, deps);
}
