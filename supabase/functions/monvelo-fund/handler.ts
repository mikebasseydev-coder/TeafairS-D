// Addendum A6 §6.3 — an agent's member starts the Paystack bank transfer that
// funds a shop's trade order. The RPC runs first (it checks the member, the
// agent and the financing, and a replay returns the same reference); Paystack
// is initialised from the RPC's amount. No split and no callback URL: the app
// reads the financing status. The Paystack error text, the secret key and the
// access code never reach a log.
//
// R53: the reference is drawn by the database, so a retried key must not ask
// Paystack to initialise it again (Paystack refuses a duplicate reference).
// After Initialize succeeds, the checkout is stored on the payment
// (record_monvelo_checkout, service_role only; the columns are granted to no
// API role), and a replay of start_monvelo_funding hands it back: the gateway
// returns it without calling Paystack. A replay that finds nothing stored (the
// first Initialize failed, or its store did) initialises again; if Paystack
// refuses that as a duplicate, the checkout is lost: 409 MONVELO_CHECKOUT_LOST,
// and the client starts again with a new idempotency key (a new payment and
// reference). This is the one service-role write in a user gateway outside R22:
// the user's work still runs on the caller's JWT.
import { z } from "../_shared/core/deps.ts";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { type InitializeTransaction, PaystackDuplicateReference } from "../_shared/payments/paystack.ts";

export type StoredCheckout = { authorizationUrl: string; accessCode: string };
export type RecordCheckout = (paymentId: string, checkout: StoredCheckout) => Promise<void>;

export type MonveloFundDeps = UserGatewayDeps & {
  initializeTransaction: InitializeTransaction;
  /** Stores the checkout on the payment: service_role, record_monvelo_checkout. */
  recordCheckout: RecordCheckout;
};

/** record_monvelo_checkout over a service-role client (index.ts wires serviceRpc()). */
export function monveloCheckoutRecorder(rpc: Rpc): RecordCheckout {
  return async (paymentId, checkout) => {
    await rpc("record_monvelo_checkout", {
      p_payment_id: paymentId,
      p_authorization_url: checkout.authorizationUrl,
      p_access_code: checkout.accessCode,
    });
  };
}

const schema = z.object({
  idempotency_key: idempotencyKey,
  financing_id: z.string().uuid(),
  agent_id: z.string().uuid(),
});

type Started = {
  payment_id: string;
  reference: string;
  amount_minor: number | string;
  currency: string;
  claim_expires_at: string;
  replayed?: boolean;
  /** On a replay only, once the first call stored them. */
  authorization_url?: string | null;
  access_code?: string | null;
};

export function createMonveloFundHandler(deps: MonveloFundDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const started = await rpc<Started>("start_monvelo_funding", {
      p_idempotency_key: body.idempotency_key,
      p_financing_id: body.financing_id,
      p_agent_id: body.agent_id,
    });
    if (started.replayed && started.authorization_url && started.access_code) {
      return { reference: started.reference, authorization_url: started.authorization_url, access_code: started.access_code };
    }

    let tx;
    try {
      tx = await deps.initializeTransaction({
        reference: started.reference,
        amountMinor: Number(started.amount_minor),
        currency: started.currency,
        email: `monvelo-${started.reference.toLowerCase()}@pay.teafairweb.com`,
        channels: ["bank_transfer"],
        metadata: { kind: "monvelo", financing_id: body.financing_id },
      });
    } catch (e) {
      console.error("Paystack initialize failed", e instanceof Error ? e.name : "error");
      if (started.replayed && e instanceof PaystackDuplicateReference) {
        throw new GatewayError(409, "MONVELO_CHECKOUT_LOST",
          "This payment was started but its link was lost. Start the funding again.");
      }
      throw new GatewayError(502, "PAYSTACK_UNAVAILABLE", "Payment could not be started. Please try again.");
    }

    try {
      await deps.recordCheckout(started.payment_id, { authorizationUrl: tx.authorizationUrl, accessCode: tx.accessCode });
    } catch (e) {
      // the payer still gets the link; a later replay would find nothing stored
      console.error("Monvelo checkout not stored", e instanceof Error ? e.name : "error");
    }
    return { reference: tx.reference, authorization_url: tx.authorizationUrl, access_code: tx.accessCode };
  }, deps);
}
