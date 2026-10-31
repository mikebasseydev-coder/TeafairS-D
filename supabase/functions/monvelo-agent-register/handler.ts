// Addendum A6 §6.3 — a street agent (ZSA/ASA) registers a POS agent, or asks
// to change its settlement account. Teafair does no duplicate KYC: the only
// check here is that the bank account exists (Paystack /bank/resolve). The
// resolved name, never a client-sent one, goes to the database. The full
// account number and the phone are never returned or logged.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { normalizePhone } from "../_shared/core/phone.ts";

export type MonveloAgentRegisterDeps = UserGatewayDeps & {
  resolve: (accountNumber: string, bankCode: string) => Promise<{ accountName: string }>;
  gatewaySecret: string;
};

const account = {
  settlement_account_number: z.string().regex(/^\d{10}$/),
  settlement_bank_code: z.string().trim().min(1).max(16),
};

const schema = z.discriminatedUnion("action", [
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("register"),
    business_name: z.string().trim().min(1).max(200),
    pos_network: z.enum(["MONIEPOINT", "OPAY", "PALMPAY"]),
    network_agent_id: z.string().trim().min(1).max(64),
    contact_phone: z.string().trim().min(7).max(24),
    latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180),
    address_text: z.string().trim().min(1).max(500),
    network_kyc_reference: z.string().trim().min(1).max(100),
    ...account,
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("change_settlement"),
    agent_id: z.string().uuid(),
    ...account,
  }),
]);

type RegisterReply = { agent_id: string; status: string; name_matches: boolean };
type ChangeReply = { agent_id: string; status: string; last4: string };

export function createMonveloAgentRegisterHandler(deps: MonveloAgentRegisterDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const last4 = body.settlement_account_number.slice(-4);

    if (body.action === "change_settlement") {
      const { accountName } = await deps.resolve(body.settlement_account_number, body.settlement_bank_code);
      const r = await rpc<ChangeReply>("request_monvelo_settlement_change", {
        p_idempotency_key: body.idempotency_key,
        p_gateway_proof: deps.gatewaySecret,
        p_agent_id: body.agent_id,
        p_account: {
          settlement_account_number: body.settlement_account_number,
          settlement_bank_code: body.settlement_bank_code,
          settlement_account_name: accountName,
        },
      });
      return { agent_id: r.agent_id, status: r.status, settlement_account_last4: r.last4 };
    }

    const phone = normalizePhone(body.contact_phone);
    if (!phone) throw new GatewayError(400, "VALIDATION_FAILED", "Enter a valid phone number.");
    const { accountName } = await deps.resolve(body.settlement_account_number, body.settlement_bank_code);
    const r = await rpc<RegisterReply>("register_monvelo_agent", {
      p_idempotency_key: body.idempotency_key,
      p_gateway_proof: deps.gatewaySecret,
      p_agent: {
        business_name: body.business_name,
        pos_network: body.pos_network,
        network_agent_id: body.network_agent_id,
        contact_phone: phone,
        latitude: body.latitude,
        longitude: body.longitude,
        address_text: body.address_text,
        settlement_account_number: body.settlement_account_number,
        settlement_bank_code: body.settlement_bank_code,
        settlement_account_name: accountName,
        network_kyc_reference: body.network_kyc_reference,
      },
    });
    return { agent_id: r.agent_id, status: r.status, name_matches: r.name_matches, settlement_account_last4: last4 };
  }, deps);
}
