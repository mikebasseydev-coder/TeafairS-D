// Addendum A3 §4 — open a support ticket. Turnstile, normalise the phone,
// derive the secret from the idempotency key, then open_support_ticket with
// only the secret's hash. A retry with the same key gets the same secret. The
// secret is in the reply and never logged.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { clientIp } from "../_shared/commerce/client-ip.ts";
import { normalizePhone } from "../_shared/commerce/phone.ts";
import type { VerifyTurnstile } from "../_shared/commerce/turnstile.ts";
import { mapNotFound } from "../_shared/support/not-found.ts";
import { sha256Hex } from "../_shared/support/secret.ts";

export type SupportTicketOpenDeps = PublicGatewayDeps & {
  verifyTurnstile: VerifyTurnstile;
  // HMAC of the idempotency key under SUPPORT_TICKET_SECRET_KEY (see secret.ts)
  secretFor: (idempotencyKey: string) => Promise<string>;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  turnstile_token: z.string().min(1).max(2048),
  category: z.enum(["PAYMENT", "DELIVERY", "ORDER_CHANGE", "PRODUCT", "OTHER"]),
  message: z.string().trim().min(1).max(2000),
  customer: z.object({
    name: z.string().trim().min(2).max(120),
    phone: z.string().trim().min(7).max(24),
    email: z.string().trim().toLowerCase().email().max(254).optional(),
  }),
  order: z.object({
    public_reference: z.string().trim().toUpperCase().regex(/^TF-[0-9A-HJKMNP-TV-Z]{6}$/),
    paystack_reference: z.string().trim().regex(/^TFW-[0-9a-f-]{36}$/i),
  }).optional(),
  location: z.object({ lga_id: z.string().uuid() }).optional(),
}).refine((b) => (b.order === undefined) !== (b.location === undefined), {
  message: "Give either an order or a delivery area.",
  path: ["order"],
});

export function createSupportTicketOpenHandler(deps: SupportTicketOpenDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc, req }) => {
    // first, so a misconfigured key fails closed before Turnstile is spent
    let secret: string;
    try {
      secret = await deps.secretFor(body.idempotency_key);
    } catch (e) {
      console.error("Ticket secret derivation failed", e);
      throw new GatewayError(503, "RETRY", "Support is unavailable. Please try again.");
    }

    let human: boolean;
    try {
      human = await deps.verifyTurnstile(body.turnstile_token, clientIp(req));
    } catch (e) {
      console.error("Turnstile verification failed", e);
      throw new GatewayError(503, "RETRY", "The security check is unavailable. Please try again.");
    }
    if (!human) throw new GatewayError(403, "BOT_CHECK_FAILED", "Please complete the security check and try again.");

    const phone = normalizePhone(body.customer.phone);
    if (!phone) throw new GatewayError(400, "VALIDATION_FAILED", "Enter a valid phone number.");

    let opened: { public_reference: string; status: string };
    try {
      opened = await rpc("open_support_ticket", {
        p_idempotency_key: body.idempotency_key,
        p_kind: body.order ? "ORDER" : "PRE_PURCHASE",
        p_category: body.category,
        p_message: body.message,
        p_customer: { ...body.customer, phone },
        p_order_public_reference: body.order?.public_reference ?? null,
        p_order_paystack_reference: body.order?.paystack_reference ?? null,
        p_lga_id: body.location?.lga_id ?? null,
        p_secret_hash: await sha256Hex(secret),
      });
    } catch (e) {
      throw mapNotFound(e, "We couldn't find that order.");
    }
    return { public_reference: opened.public_reference, secret, status: opened.status };
  }, deps);
}
