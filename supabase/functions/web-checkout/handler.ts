// Addendum A1 §5.3 — web checkout. Turnstile → normalise the phone → quote
// (server pricing) → on PAYSTACK_WEB, Initialize → place_web_order.
//
// Initialize runs BEFORE the write. A retry whose earlier attempt committed
// gets the original order and checkout URL back from place_web_order's
// idempotency replay; the transaction the retry initialised is never shown
// and expires unpaid. The other order would leave a committed order with no
// checkout URL whenever Paystack failed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { clientIp } from "../_shared/commerce/client-ip.ts";
import { normalizePhone } from "../_shared/commerce/phone.ts";
import type { VerifyTurnstile } from "../_shared/commerce/turnstile.ts";
import type { InitializeTransaction } from "../_shared/payments/paystack.ts";

export type WebCheckoutDeps = PublicGatewayDeps & {
  verifyTurnstile: VerifyTurnstile;
  initializeTransaction: InitializeTransaction;
  newReference: () => string;
  callbackUrl: string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  code: z.string().trim().min(4).max(32).optional(),
  lga_id: z.string().uuid(),
  items: z.array(z.object({
    sku_code: z.string().min(1).max(64),
    qty: z.number().int().min(1).max(1000),
  })).min(1).max(50),
  customer: z.object({
    name: z.string().trim().min(2).max(120),
    phone: z.string().trim().min(7).max(24),
    email: z.string().trim().toLowerCase().email().max(254).optional(),
    delivery_address: z.string().trim().min(5).max(500),
  }),
  utm: z.object({
    source: z.string().max(100).optional(),
    medium: z.string().max(100).optional(),
    campaign: z.string().max(100).optional(),
  }).optional(),
  payment_route: z.enum(["PAYSTACK_WEB", "POS_AGENT"]),
  turnstile_token: z.string().min(1).max(2048),
  // A5 §3.5. Checked in the handler (not z.literal) so a missing or false
  // value gets the consent copy rather than the generic validation message.
  accept_refund_policy: z.boolean().optional(),
  policy_version_tag: z.string().min(1).max(64),
  phone_verification_token: z.string().length(43),
}).refine((b) => b.code !== undefined || b.payment_route === "PAYSTACK_WEB", {
  message: "A link is required to pay an agent.",
  path: ["payment_route"],
});

type Quote = {
  total: number | string;
  currency: string;
  split: { subaccount_code: string; commission_bps: number | string; partner_share: number | string } | null;
};

const toMinor = (amount: number | string) => Math.round(Number(amount) * 100);

export function createWebCheckoutHandler(deps: WebCheckoutDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc, req }) => {
    if (body.accept_refund_policy !== true) {
      throw new GatewayError(400, "VALIDATION_FAILED", "You must accept the refund policy to place an order.");
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
    const customer = { ...body.customer, phone };

    const quote = await rpc<Quote>("quote_web_order", { p_code: body.code ?? null, p_items: body.items, p_lga_id: body.lga_id });

    let checkout: { reference: string; access_code: string; authorization_url: string } | null = null;
    if (body.payment_route === "PAYSTACK_WEB") {
      const reference = deps.newReference();
      const amountMinor = toMinor(quote.total);
      try {
        const tx = await deps.initializeTransaction({
          reference,
          amountMinor,
          currency: quote.currency,
          email: customer.email ?? `order-${reference.toLowerCase()}@pay.teafairweb.com`,
          callbackUrl: deps.callbackUrl,
          metadata: { agent_code: body.code?.toUpperCase() ?? null, payment_route: body.payment_route },
          split: quote.split
            ? { subaccount: quote.split.subaccount_code, transactionChargeMinor: amountMinor - toMinor(quote.split.partner_share) }
            : undefined,
        });
        checkout = { reference: tx.reference, access_code: tx.accessCode, authorization_url: tx.authorizationUrl };
      } catch (e) {
        console.error("Paystack initialize failed", e);
        throw new GatewayError(502, "PAYMENT_PROVIDER_UNAVAILABLE", "Payment could not be started. Please try again.");
      }
    }

    // Exactly the three keys the database compares; values copied unchanged.
    const split = quote.split
      ? {
        subaccount_code: quote.split.subaccount_code,
        commission_bps: quote.split.commission_bps,
        partner_share: quote.split.partner_share,
      }
      : null;

    return await rpc("place_web_order", {
      p_idempotency_key: body.idempotency_key,
      p_code: body.code ?? null,
      p_lga_id: body.lga_id,
      p_items: body.items,
      p_customer: customer,
      p_utm: body.utm ?? {},
      p_payment_route: body.payment_route,
      p_expected_total: quote.total,
      p_accepted_refund_policy: true,
      p_policy_version_tag: body.policy_version_tag,
      p_client_ip: clientIp(req),
      p_phone_verification_token: body.phone_verification_token,
      p_checkout: checkout && { ...checkout, split },
    });
  }, deps);
}
