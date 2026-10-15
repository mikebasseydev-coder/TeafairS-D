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
import { normalizePhone } from "../_shared/commerce/phone.ts";
import type { VerifyTurnstile } from "../_shared/commerce/turnstile.ts";
import type { InitializeTransaction } from "../_shared/fintech-liquidity/paystack.ts";

export type WebCheckoutDeps = PublicGatewayDeps & {
  verifyTurnstile: VerifyTurnstile;
  initializeTransaction: InitializeTransaction;
  newReference: () => string;
  callbackUrl: string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  code: z.string().trim().min(4).max(32),
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
});

type Quote = {
  total: number | string;
  currency: string;
  split: { subaccount_code: string; partner_share: number | string } | null;
};

const toMinor = (amount: number | string) => Math.round(Number(amount) * 100);

function clientIp(req: Request): string | null {
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? null;
}

export function createWebCheckoutHandler(deps: WebCheckoutDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc, req }) => {
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

    const quote = await rpc<Quote>("quote_web_order", { p_code: body.code, p_items: body.items });

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
          metadata: { agent_code: body.code.toUpperCase(), payment_route: body.payment_route },
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

    return await rpc("place_web_order", {
      p_idempotency_key: body.idempotency_key,
      p_code: body.code,
      p_items: body.items,
      p_customer: customer,
      p_utm: body.utm ?? {},
      p_payment_route: body.payment_route,
      p_expected_total: quote.total,
      p_checkout: checkout,
    });
  }, deps);
}
