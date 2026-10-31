// Addendum A6 §6.3 — an agent's member starts the Paystack bank transfer that
// funds a shop's trade order. The RPC runs first (it checks the member, the
// agent and the financing, and a replay returns the same reference); Paystack
// is initialised from the RPC's amount. No split and no callback URL: the app
// reads the financing status. The Paystack error text, the secret key and the
// access code never reach a log.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import type { InitializeTransaction } from "../_shared/payments/paystack.ts";

export type MonveloFundDeps = UserGatewayDeps & {
  initializeTransaction: InitializeTransaction;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  financing_id: z.string().uuid(),
  agent_id: z.string().uuid(),
});

type Started = { payment_id: string; reference: string; amount_minor: number | string; currency: string; claim_expires_at: string };

export function createMonveloFundHandler(deps: MonveloFundDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const started = await rpc<Started>("start_monvelo_funding", {
      p_idempotency_key: body.idempotency_key,
      p_financing_id: body.financing_id,
      p_agent_id: body.agent_id,
    });
    try {
      const tx = await deps.initializeTransaction({
        reference: started.reference,
        amountMinor: Number(started.amount_minor),
        currency: started.currency,
        email: `monvelo-${started.reference.toLowerCase()}@pay.teafairweb.com`,
        channels: ["bank_transfer"],
        metadata: { kind: "monvelo", financing_id: body.financing_id },
      });
      return { reference: tx.reference, authorization_url: tx.authorizationUrl, access_code: tx.accessCode };
    } catch (e) {
      console.error("Paystack initialize failed", e instanceof Error ? e.name : "error");
      throw new GatewayError(502, "PAYSTACK_UNAVAILABLE", "Payment could not be started. Please try again.");
    }
  }, deps);
}
